---@module 'testing.guard'
---@brief Guards v2 (M2, D.3.5) and the effects ledger: safety nets around a spec, installable in ANY Neovim.
---@description
--- ```lua
--- local guard = require("testing.guard")
--- local h = guard.install({ repo = root, guards = { process_net = { allow_exec = { "git" } } } })
--- h:begin_case({ id = "a_spec.lua::x::y", file = "a_spec.lua", tags = { "spawn" } })
--- -- ... the spec body runs ...
--- local res = h:end_case()          -- { findings, effects, ledger, restored }
--- local run = h:collect()           -- { effects, findings, ledger, notes } over everything so far
--- h:uninstall()                     -- every patch undone
--- ```
---
--- The child bootstrap (agent P) and the in-process driver call exactly this. `snapshot` / `check`
--- are the two halves of `begin_case` / `end_case` for callers that want to place them themselves;
--- `enter` / `leave` open and close the window in which the wrapping guards are active.
---
--- The window: process / network / prompt / filesystem wrappers do nothing (one boolean test)
--- unless a case is open. The runner and lib.nvim helpers spawn processes and write files between
--- cases; those never reach the ledger. `handle:suspended(fn)` runs a function (e.g. a harness
--- helper that must call `git` inside a case) outside the guards.
---
--- HONEST LIMIT: these are safety nets for accidents, not a sandbox. Lua can bypass any monkeypatch
--- (`rawget(_G, ...)`, `package.loaded` tricks, a saved reference to the original function, a C
--- module); `:call input()` and Vimscript do not see the Lua wrappers. The real boundary is the
--- process plus the operating system (container, VM). See docs/GUARDS.md.
---
--- Finding: `{ id, guard, severity = "error"|"warn"|"info", message, case, file, detail?, stack? }`;
--- the ids are stable and documented in docs/GUARDS.md.

local config = require("testing.guard.config")
local ledger = require("testing.core.ledger")
local patch = require("testing.guard.patch")

local M = {}

---Answer of a prompt that stands for "the user cancelled" (`vim.ui.select` -> `nil`, `input()` -> "").
M.CANCEL = setmetatable({}, {
  __tostring = function()
    return "<testing.guard.CANCEL>"
  end,
})

---Tags written into a test name: `it("fetches @network", ...)` -> `{ network = true }`.
---@param s any
---@return table<string, boolean>
function M.tags_from_name(s)
  local set = {}
  if type(s) == "string" then
    for tag in s:gmatch("@([%w][%w_%-]*)") do
      set[tag:lower()] = true
    end
  end
  return set
end

---Handles that are installed right now (a layer that stays installed after its run is a leak: the next
---file of a pool member would wrap the wrappers).
---@type table<Testing.Guard.Handle, true>
local LIVE = {}

---Number of guard layers that are installed (and not yet uninstalled) in this editor.
---@return integer
function M.live_count()
  local n = 0
  for _ in pairs(LIVE) do
    n = n + 1
  end
  return n
end

local GUARD_MODULES = {
  scheduled_error = "testing.guard.scheduled_error",
  prompt = "testing.guard.prompt",
  deprecation = "testing.guard.deprecation",
  process_net = "testing.guard.process_net",
  fs = "testing.guard.fs",
  state = "testing.guard.state",
  clock = "testing.guard.clock",
}

local IS_WIN = vim.fn.has("win32") == 1
local IS_MAC = vim.fn.has("mac") == 1

---@class Testing.Guard.Finding
---@field id string Stable id, e.g. `state.autocmd`.
---@field guard string
---@field severity "error"|"warn"|"info"
---@field message string
---@field case? string
---@field file? string
---@field detail? table
---@field stack? string
---@field count integer

---@class Testing.Guard.CaseCtx
---@field id? string
---@field file? string
---@field name? string
---@field tags? string[]|table<string, boolean> `network`, `@spawn`, ...
---@field settle_ms? number

---@class Testing.Guard.Handle
---@field cfg table Normalized config.
---@field ledger Testing.Ledger Everything since install (or the last `collect{ reset = true }`).
---@field case_ledger Testing.Ledger The open (or last) case.
---@field findings Testing.Guard.Finding[] Everything since install / reset.
---@field active boolean
---@field busy integer Re-entrancy depth (a guard's own original call).
---@field ctx Testing.Guard.CaseCtx
---@field patcher Testing.Guard.Patcher
---@field guards table<string, table>
---@field redact fun(s: string): string
---@field lopts table ledger options
---@field notes string[]
---@field tags table<string, boolean>
---@field dyn_allow table<string, table<string, boolean>>
---@field case_keys table<string, Testing.Guard.Finding>
---@field case_findings Testing.Guard.Finding[]
---@field snaps table<string, any>
---@field installed boolean
---@field findings_dropped? integer
local Handle = {}
Handle.__index = Handle

-- =========================================================
-- Install
-- =========================================================

---Install the guards. Raises on an invalid configuration (a typo must not switch a net off).
---@param cfg? table see `testing.guard.config` (`DEFAULTS`)
---@return Testing.Guard.Handle
function M.install(cfg)
  local conf, problems = config.normalize(cfg)
  if #problems > 0 then
    error("testing.guard: invalid config: " .. table.concat(problems, "; "), 2)
  end
  local uv = vim.uv or vim.loop
  local roots = conf.roots
  if roots == nil then
    roots = {
      repo = conf.repo,
      home = uv.os_homedir(),
      tmp = uv.os_tmpdir(),
      state = vim.fn.stdpath("state"),
    }
    for k, v in pairs(roots) do
      if type(v) ~= "string" or v == "" then
        roots[k] = nil
      end
    end
  end
  local redact = ledger.redactor(roots, { case_insensitive = IS_WIN or IS_MAC })
  local lopts =
    { max_entries = conf.ledger.max_entries, max_text = conf.ledger.max_text, redact = redact }
  local h = setmetatable({
    cfg = conf,
    redact = redact,
    ledger = ledger.new(lopts),
    case_ledger = ledger.new(lopts),
    lopts = lopts,
    findings = {},
    notes = {},
    active = false,
    busy = 0,
    ctx = {},
    tags = {},
    dyn_allow = { spawn = {}, network = {} },
    case_keys = {},
    case_findings = {},
    snaps = {},
    patcher = patch.new(),
    guards = {},
    installed = true,
  }, Handle)
  LIVE[h] = true
  -- one guard that cannot be built or installed (a changed Neovim API, a missing module) must not leave
  -- the patches of the ones before it behind with no handle to undo them: everything is rolled back and
  -- the error goes on (a pool member would stack wrappers file after file otherwise)
  local current = "?"
  local built, err = pcall(function()
    for _, name in ipairs(config.ORDER) do
      local gcfg = conf.guards[name]
      if gcfg.mode ~= "off" then
        current = name
        local g = require(GUARD_MODULES[name]).new(h, gcfg)
        h.guards[name] = g
        if g.install then
          g:install()
        end
      end
    end
  end)
  if not built then
    pcall(h.uninstall, h)
    error(("testing.guard: installing the '%s' guard failed: %s"):format(current, tostring(err)), 0)
  end
  return h
end

-- =========================================================
-- Helpers for the guards
-- =========================================================

---Is a case open and no guard-internal call running? The wrappers ask this on every call.
---@return boolean
function Handle:is_active()
  return self.active and self.busy == 0
end

---Run `fn` with the wrappers silenced (the harness' own spawns / writes, a guard's original call).
---@param fn function
---@return any ...
function Handle:suspended(fn)
  self.busy = self.busy + 1
  local ok, a, b, c = pcall(fn)
  self.busy = self.busy - 1
  if not ok then
    error(a, 0)
  end
  return a, b, c
end

---Severity of a guard mode (strict promotes `warn`).
---@param mode string
---@return string
function Handle:severity(mode)
  if mode == "warn" and self.cfg.strict then
    return "error"
  end
  return mode
end

---The label findings use for the current case: `spec <id or file>`.
---@param ctx? Testing.Guard.CaseCtx
---@return string
function Handle:label(ctx)
  ctx = ctx or self.ctx
  return "spec " .. tostring(ctx.id or ctx.file or ctx.name or "<unnamed>")
end

---Is `tag` set on the open case (`tags` list or `@tag` in its name/id), or allowed dynamically?
---@param tag string
---@return boolean
function Handle:has_tag(tag)
  return self.tags[tag] == true
end

---Allow (for the open case) a spawn of an executable or a network host without a tag.
---@param kind "spawn"|"network"
---@param what string executable basename or host
function Handle:allow(kind, what)
  assert(self.dyn_allow[kind], "kind must be 'spawn' or 'network'")
  self.dyn_allow[kind][what:lower()] = true
end

---Record an effect (in the case ledger and in the run ledger).
---@param kind string
---@param text string
---@param meta? { blocked?: boolean, allowed?: string }
function Handle:log(kind, text, meta)
  self.case_ledger:add(kind, text, meta)
  self.ledger:add(kind, text, meta)
end

---Add a finding to the open case. The same id+message is stored once (`count` goes up).
---@param guard string
---@param id string
---@param message string
---@param opts? { mode?: string, detail?: table, stack?: string }
---@return Testing.Guard.Finding|nil
function Handle:finding(guard, id, message, opts)
  opts = opts or {}
  local mode = opts.mode or (self.cfg.guards[guard] and self.cfg.guards[guard].mode) or "error"
  if mode == "off" then
    return nil
  end
  local severity = self:severity(mode)
  message = self.redact(message)
  local key = id .. "\0" .. message
  local existing = self.case_keys[key]
  if existing then
    existing.count = existing.count + 1
    return existing
  end
  local ctx = self.ctx
  ---@type Testing.Guard.Finding
  local f = {
    id = id,
    guard = guard,
    severity = severity,
    message = message,
    case = ctx.id,
    file = ctx.file,
    detail = opts.detail,
    stack = opts.stack and self.redact(opts.stack) or nil,
    count = 1,
  }
  self.case_keys[key] = f
  if #self.case_findings < 200 then
    self.case_findings[#self.case_findings + 1] = f
  end
  if #self.findings < self.cfg.max_findings then
    self.findings[#self.findings + 1] = f
  else
    self.findings_dropped = (self.findings_dropped or 0) + 1
  end
  return f
end

---A bounded traceback of the caller of a wrapper (the spec's stack), newline separated.
---@param level? integer
---@return string
function Handle:stack(level)
  local tb = debug.traceback("", (level or 2) + 1)
  local lines = vim.split(tb, "\n", { plain = true })
  local out = {}
  for i = 2, math.min(#lines, 14) do
    if
      not lines[i]:find("testing/guard/", 1, true)
      and not lines[i]:find("testing\\guard\\", 1, true)
    then
      out[#out + 1] = lines[i]
    end
  end
  return table.concat(out, "\n")
end

-- =========================================================
-- Case window
-- =========================================================

---@private
---@param ctx Testing.Guard.CaseCtx
local function compute_tags(ctx)
  local set = {}
  if type(ctx.tags) == "table" then
    for k, v in pairs(ctx.tags) do
      if type(k) == "number" and type(v) == "string" then
        set[(v:gsub("^@", "")):lower()] = true
      elseif type(k) == "string" and v == true then
        set[(k:gsub("^@", "")):lower()] = true
      end
    end
  end
  for tag in pairs(M.tags_from_name(ctx.name)) do
    set[tag] = true
  end
  for tag in pairs(M.tags_from_name(ctx.id)) do
    set[tag] = true
  end
  return set
end

---Open the guard window for a case: answers and dynamic allows reset, the wrappers become active.
---@param ctx? Testing.Guard.CaseCtx
function Handle:enter(ctx)
  self.ctx = ctx or {}
  self.tags = compute_tags(self.ctx)
  self.dyn_allow = { spawn = {}, network = {} }
  self.case_keys = {}
  self.case_findings = {}
  self.case_ledger = ledger.new(self.lopts)
  for _, g in pairs(self.guards) do
    if g.begin then
      g:begin(self.ctx)
    end
  end
  self.active = true
end

---Close the window (the wrappers become inert); the case data stays for `check`.
function Handle:leave()
  self.active = false
  for _, g in pairs(self.guards) do
    if g.finish then
      g:finish(self.ctx)
    end
  end
end

---Take the before-snapshot of every guard that compares before/after.
---@param opts? { heavy?: boolean } `heavy`: also the file-tree snapshot of the fs guard (per file, not per case)
function Handle:snapshot(opts)
  self.busy = self.busy + 1
  local snaps = {}
  for name, g in pairs(self.guards) do
    if g.snapshot then
      local ok, snap = pcall(g.snapshot, g, opts or {})
      if ok then
        snaps[name] = snap
      else
        self.notes[#self.notes + 1] = ("guard %s: snapshot failed: %s"):format(name, tostring(snap))
      end
    end
  end
  self.busy = self.busy - 1
  self.snaps = snaps
end

---Compare the current state with the snapshot and collect what the guards found. Idempotent: the
---same finding is stored once. Returns every finding of the case so far (live and compared).
---@param ctx? Testing.Guard.CaseCtx
---@return Testing.Guard.Finding[]
function Handle:check(ctx)
  if ctx and ctx ~= self.ctx then
    self.ctx = ctx
  end
  ctx = self.ctx
  self.busy = self.busy + 1
  local settle = ctx.settle_ms or self.cfg.settle_ms
  pcall(vim.wait, settle)
  for _, name in ipairs(config.ORDER) do
    local g = self.guards[name]
    if g and g.check then
      local ok, err = pcall(g.check, g, self.snaps[name], ctx)
      if not ok then
        self.notes[#self.notes + 1] = ("guard %s: check failed: %s"):format(name, tostring(err))
      end
    end
  end
  self.busy = self.busy - 1
  return vim.list_slice(self.case_findings, 1, #self.case_findings)
end

---`snapshot` + `enter`.
---@param ctx? Testing.Guard.CaseCtx
---@param opts? { heavy?: boolean }
function Handle:begin_case(ctx, opts)
  self.ctx = ctx or {}
  self:snapshot(opts)
  self:enter(ctx)
end

---`leave` + `check` + optional soft isolation. The result is what the runner puts into the IR case.
---@param opts? { restore?: boolean|string[] } default from the config (`restore`)
---@return { findings: Testing.Guard.Finding[], effects: table, ledger: Testing.Ledger, ledger_data: table, restored: table<string, integer> }
function Handle:end_case(opts)
  opts = opts or {}
  self:leave()
  local findings = self:check()
  local restored = {}
  local which = opts.restore
  if which == nil then
    which = self.cfg.restore
  end
  if which and self.guards.state then
    self.busy = self.busy + 1
    restored = self.guards.state:restore(self.snaps.state, which)
    self.busy = self.busy - 1
  end
  return {
    findings = findings,
    effects = self.case_ledger:to_effects(),
    ledger = self.case_ledger,
    ledger_data = self.case_ledger:serialize(),
    restored = restored,
  }
end

---Soft isolation on demand: put back what the case left behind (see the state guard).
---@param which? boolean|string[] categories, default every restorable one
---@return table<string, integer> restored counts per category
function Handle:restore(which)
  if not self.guards.state then
    return {}
  end
  self.busy = self.busy + 1
  local r = self.guards.state:restore(self.snaps.state, which == nil and true or which)
  self.busy = self.busy - 1
  return r
end

---Everything seen since install (or the last reset).
---@param opts? { reset?: boolean }
---@return { effects: table, findings: Testing.Guard.Finding[], ledger: Testing.Ledger, ledger_data: table, notes: string[] }
function Handle:collect(opts)
  local out = {
    effects = self.ledger:to_effects({ extra = true }),
    findings = vim.list_slice(self.findings, 1, #self.findings),
    ledger = self.ledger,
    ledger_data = self.ledger:serialize(),
    notes = vim.list_slice(self.notes, 1, #self.notes),
  }
  if self.findings_dropped then
    out.notes[#out.notes + 1] = ("%d findings dropped (max_findings bound)"):format(
      self.findings_dropped
    )
  end
  if opts and opts.reset then
    self.ledger = ledger.new(self.lopts)
    self.findings = {}
    self.notes = {}
    self.findings_dropped = nil
  end
  return out
end

-- =========================================================
-- Guard front doors
-- =========================================================

---Queue / set scripted answers for prompts (prompt guard). `nil` clears every answer.
---Keys: `input`, `select`, `confirm`, `getchar`. A scalar answers every such prompt, a list is
---consumed in order, a function is called with the prompt arguments.
---@param answers? table
function Handle:answer_prompts(answers)
  local g = self.guards.prompt
  if not g then
    error("testing.guard: the prompt guard is off", 2)
  end
  g:set_answers(answers)
end

---The fake clock (clock guard); `nil` when the guard is off.
---@return table|nil
function Handle:clock()
  local g = self.guards.clock
  return g and g.clock or nil
end

---Undo everything: patches, hooks. Idempotent. Returns the labels of patches that could not be
---undone because something else wrapped over them.
---@return string[]
function Handle:uninstall()
  if not self.installed then
    return self.patcher.unrestored
  end
  self.active = false
  for _, g in pairs(self.guards) do
    if g.uninstall then
      pcall(g.uninstall, g)
    end
  end
  self.patcher:restore()
  self.installed = false
  LIVE[self] = nil
  return self.patcher.unrestored
end

return M
