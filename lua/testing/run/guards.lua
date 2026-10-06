---@module 'testing.run.guards'
---@brief The runner's side of the guard layer: install it, open and close its window around a case, put what it found into the IR.
---@description
--- The guards themselves (`testing.guard`: fs, state, scheduled-error, prompt, deprecation,
--- process/net, clock) are another module's business. This one is the SEAM the runner uses, so that the
--- drivers do not know the guard layer's API and a run without the guard layer still works:
---
---   * `install(cfg)` soft-requires `testing.guard` and calls `install(cfg)` (the configuration comes
---     from `testing.run.options.guard_config`, the one adapter). No such module = no guards, silently
---     (the layer is optional); a module that is there but raises is NOT silent: `session.error` says why.
---   * the handle it returns is used through four calls, each optional, each under `pcall`:
---       handle:begin_case(ctx, { heavy })   open the window of a case (`ctx = { id?, file }`)
---       handle:end_case() -> { findings, effects }   close it and take what the case did
---       handle:collect() -> { notes }       the guards' own diagnostics (a snapshot that failed)
---       handle:uninstall() -> string[]      undo every monkeypatch; the labels of those that could not be undone
---   * `attach(cases, findings, effects)` puts findings and effects into IR cases
---     (`result.add_guard_finding`, `result.merge_effects`): a finding of severity `error` fails the case,
---     `warn` and `info` are recorded.
---
--- THE WINDOW. Between cases the runner spawns processes and writes files itself (the fragment of a
--- child, `git` for the header); those must never reach a ledger. So `open`/`close` bracket exactly
--- what a case does. A dialect with one case per file opens ONE window before the file and closes it
--- when the case is reported. Busted opens one window per `it`: the dialect asks the runner's
--- selector (`accept(id)`) right before it runs the body, which is the one moment a case starts and
--- carries its id (so `@network` in a title works) and the shim's globals are installed already; the
--- window closes when the case is reported (`on_case`), before the runner's own hooks. What happens
--- outside any window (describe bodies, the gap between cases) is not seen.
---
--- Soft isolation findings (`testing.isolation`) use the same `attach`, with the guard name `state`.

local result = require("testing.core.result")

local M = {}

---@class Testing.Run.GuardSession
---@field active boolean A guard layer is installed.
---@field handle any What `testing.guard.install` returned.
---@field error? string Why the guard layer could not be installed or failed later (nil when absent or fine).
---@field notes string[] The guard layer's own diagnostics.
---@field is_open boolean A case window is open.
local Session = {}
Session.__index = Session

---Is there a guard layer in this checkout (`testing.guard` with an `install` function)? Without it
---nothing measures effects, and the cases say so.
---@return boolean
function M.available()
  local ok, g = pcall(require, "testing.guard")
  return ok and type(g) == "table" and type(g.install) == "function"
end

---Notes for the cases of a run: what the effects ledger does NOT measure under this configuration.
---The ledger is filled by the guards: with `process_net = "off"` no spawn and no connection is seen, with
---`fs = "off"` no write outside the run folder, and an EMPTY list then means "not measured", never
---"nothing happened" (a consumer of the IR must be able to tell the two apart).
---@param cfg table|nil The guard layer's configuration (`options.guard_config`).
---@return string[]
function M.unmeasured_notes(cfg)
  local out = {}
  local g = type(cfg) == "table" and type(cfg.guards) == "table" and cfg.guards or {}
  if type(g.process_net) == "table" and g.process_net.mode == "off" then
    out[#out + 1] =
      "effects: spawned and network are not measured (guards.process_net is off); an empty list there is not a measurement"
  end
  if type(g.state) == "table" and g.state.mode == "off" then
    out[#out + 1] =
      "state: leaks (autocmds, buffers, globals, ...) are not measured (guards.state is off, or this editor ends with its one case)"
  end
  if type(g.fs) == "table" and g.fs.mode == "off" then
    out[#out + 1] =
      "effects: fs_outside_tmp is not measured (guards.fs is off); an empty list there is not a measurement"
  end
  return out
end

---Install the guard layer for a run (or a child).
---@param cfg table|nil The guard layer's configuration (`options.guard_config`); nil = no guards wanted.
---@param guard_module? table Replaces `require("testing.guard")` (specs).
---@return Testing.Run.GuardSession
function M.install(cfg, guard_module)
  local self = setmetatable({ active = false, notes = {}, is_open = false }, Session)
  if cfg == nil then
    return self
  end
  local g = guard_module
  if g == nil then
    local ok, mod = pcall(require, "testing.guard")
    if not ok then
      -- "module not found" = the layer is not part of this checkout: fine. Anything else is a bug.
      if not tostring(mod):find("module 'testing.guard' not found", 1, true) then
        self.error = "the guard layer failed to load: " .. tostring(mod)
      end
      return self
    end
    g = mod
  end
  if type(g) ~= "table" or type(g.install) ~= "function" then
    return self
  end
  local ok, handle = pcall(g.install, cfg)
  if not ok then
    self.error = "the guard layer failed to install: " .. tostring(handle)
    return self
  end
  self.active = true
  self.handle = handle
  return self
end

---@param name string
---@return fun(...)|nil
function Session:method(name)
  local h = self.handle
  if type(h) == "table" and type(h[name]) == "function" then
    return h[name]
  end
  return nil
end

---Open the window of a case.
---@param ctx { id?: string, file?: string }
---@param opts? { heavy?: boolean } `heavy`: also the per-file snapshots (the first window of a file)
function Session:open(ctx, opts)
  if not self.active or self.is_open then
    return
  end
  local fn = self:method("begin_case")
  if not fn then
    return
  end
  local ok, err = pcall(fn, self.handle, ctx, opts)
  if ok then
    self.is_open = true
  else
    self.error = "the guard layer failed in begin_case(): " .. tostring(err)
  end
end

---@param f table A finding of the guard layer (`{ id, guard, severity, message, case?, count? }`).
---@return Testing.Result.GuardFinding
local function to_finding(f)
  local message = tostring(f.message or "")
  if type(f.count) == "number" and f.count > 1 then
    message = ("%s (x%d)"):format(message, f.count)
  end
  return {
    guard = tostring(f.guard or "guard"),
    severity = f.severity,
    message = message,
    id = type(f.id) == "string" and f.id or nil,
    case = type(f.case) == "string" and f.case or nil,
    stack = type(f.stack) == "string" and f.stack or nil,
  }
end

---Close the window of the open case and take what the guards saw.
---@return Testing.Result.GuardFinding[] findings
---@return table|nil effects `{ spawned, network, fs_outside_tmp }`
function Session:close()
  if not self.active or not self.is_open then
    return {}, nil
  end
  self.is_open = false
  local fn = self:method("end_case")
  if not fn then
    return {}, nil
  end
  local ok, got = pcall(fn, self.handle)
  if not ok then
    self.error = "the guard layer failed in end_case(): " .. tostring(got)
    return {}, nil
  end
  if type(got) ~= "table" then
    return {}, nil
  end
  local findings = {}
  for _, f in ipairs(type(got.findings) == "table" and got.findings or {}) do
    if type(f) == "table" then
      findings[#findings + 1] = to_finding(f)
    end
  end
  return findings, got.effects
end

---Undo the guards (every path of a run: it is called from a protected tail). Collects the guard
---layer's own diagnostics into `self.notes` first.
function Session:uninstall()
  if not self.active then
    return
  end
  if self.is_open then
    self:close()
  end
  self.active = false
  local collect = self:method("collect")
  if collect then
    local ok, got = pcall(collect, self.handle)
    if ok and type(got) == "table" and type(got.notes) == "table" then
      for _, n in ipairs(got.notes) do
        self.notes[#self.notes + 1] = tostring(n)
      end
    end
  end
  local fn = self:method("uninstall")
  if fn then
    local ok, left = pcall(fn, self.handle)
    if not ok then
      self.error = "the guard layer failed to uninstall: " .. tostring(left)
    elseif type(left) == "table" and #left > 0 then
      self.notes[#self.notes + 1] = "guard patches that could not be undone: "
        .. table.concat(left, ", ")
    end
  end
end

---@param effects table
---@return boolean
local function is_flat_effects(effects)
  return effects.spawned ~= nil or effects.network ~= nil or effects.fs_outside_tmp ~= nil
end

---Put findings and effects into the cases of ONE file.
---@param cases Testing.Result.Case[] The cases they belong to, in order.
---@param findings Testing.Result.GuardFinding[]
---@param effects? table `{ spawned, network, fs_outside_tmp }` or `case id -> that`
---@return Testing.Result.GuardFinding[] unattached Findings that had no case to land on.
function M.attach(cases, findings, effects)
  local by_id = {}
  for _, c in ipairs(cases) do
    by_id[c.id] = c
  end
  local last = cases[#cases]
  local unattached = {}
  for _, f in ipairs(findings or {}) do
    if type(f) == "table" then
      local target = (type(f.case) == "string" and by_id[f.case]) or last
      if target then
        result.add_guard_finding(target, f)
      else
        unattached[#unattached + 1] = f
      end
    end
  end
  if type(effects) == "table" then
    if is_flat_effects(effects) then
      if last then
        result.merge_effects(last, effects)
      end
    else
      for id, e in pairs(effects) do
        if by_id[id] then
          result.merge_effects(by_id[id], e)
        end
      end
    end
  end
  return unattached
end

return M
