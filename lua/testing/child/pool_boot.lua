---@module 'testing.child.pool_boot'
---@brief Runs INSIDE a warm pool member (`testing.run.pool`): runs one spec file, then puts the editor back and proves it.
---@description
--- A pool member is an RPC child (`testing.rpc`, `rpc_boot` installed) that stays alive from file to
--- file. The parent makes two requests per file, so that the editor returns to its main loop in between
--- (callbacks the file scheduled run, the editor's own idle hooks fire):
---
---   `run(job)`   soft isolation takes its snapshot, the file runs through the shared
---                `testing.child.runner` (selector, guards, timeouts, fragment), the output of `:messages`
---                is kept;
---   `finish()`   what makes the NEXT file see a clean editor, in this order:
---     1. the editor gets a moment to become idle (`SETTLE_MS`);
---     2. SOFT ISOLATION (`testing.isolation`): modules loaded, globals, autocmds, keymaps, user commands,
---        `vim.g`, environment ... that the file changed are restored, then the state is captured AGAIN
---        and compared with the one before the file: a difference that is still there is "not
---        restored" and named. Buffers, windows and tabs are NOT its business here (see 4);
---     3. OPTIONS of every scope are put back (soft isolation covers the global-scoped ones; a
---        buffer- or window-local option set with `:set` also changes its global default);
---     4. `rpc_boot.reset()` wipes buffers, windows, floats and tabs and puts back mode, command line
---        and working directory; the result is CHECKED (one tab, one window, one empty unnamed buffer);
---        what `reset` still finds different (active libuv handles, callbacks that did not run) counts;
---     5. the sandbox directories (`stdpath('config'|'data'|'state'|'cache')`) lose everything that did
---        not exist when the member started (a respawned child loses its whole sandbox).
---
--- The answer of `finish` carries what could not be put back. A member is reused only when ALL of it is
--- empty: anything else is a leak the reset could not undo, and the parent throws the member away and
--- starts a new one, naming the reason in a finding. This is the honest rule: a reset that cannot prove
--- it left nothing behind is not a reset (D.3.5).
---
--- Limits (documented in docs/CHILD.md): state that lives in a C library or in a closure the snapshot
--- does not see, and `vim.v.vim_did_enter` (an embedded member has entered; a per-file child started
--- with `-c` has not) are not detected or not reproduced.

local M = {}

---@class Testing.PoolBoot.State
---@field session? Testing.Isolation.Session
---@field dirs table<string, string> Sandbox directories to keep clean.
---@field baseline table<string, table<string, string>> Per directory: relative path -> type at the start.
---@field options? table<string, { scope: string, all: any, win: any }> Option values at the start (`all`: the global value).
---@field registries? table The editor's own registries at the start (`registries_capture`).
---@field extras? { regs: table<string, table|false>, abbrev: string } Registers and abbreviations at the start (`extras_capture`).
---@field keep_dirs table<string, table<string, true>> Per directory: relative directories that stay (the editor's own `stdpath` directories and their parents).
local state = { dirs = {}, baseline = {}, keep_dirs = {} }

---Files the editor and the runtime write themselves (the LSP log, shada, swap files): never a leak of a
---spec, never removed (the fs guard ignores the same names).
local RUNTIME_FILES = { "%.log$", "%.shada$", "%.swp$" }

---@param rel string
---@return boolean
local function runtime_file(rel)
  for _, pat in ipairs(RUNTIME_FILES) do
    if rel:find(pat) then
      return true
    end
  end
  return false
end

---Value of option `name` or `nil` (an option can be unreadable in a scope).
---@param name string
---@param o table `nvim_get_option_value` options
---@return any
local function get_option(name, o)
  local ok, v = pcall(vim.api.nvim_get_option_value, name, o)
  if ok then
    return v
  end
  return nil
end

---The values of every option at the start of the member: its global value and, for a window-local
---option, the value in the first window. Soft isolation covers the global-scoped options; a
---buffer- or window-local option set with `:set` or `vim.o` ALSO changes its global value (the
---default of every new buffer and window), and that stays in a member.
---@return table<string, { scope: string, all: any, win: any }>
local function option_baseline()
  local out = {}
  local ok, info = pcall(vim.api.nvim_get_all_options_info)
  if not ok then
    return out
  end
  local win = vim.api.nvim_get_current_win()
  for name, i in pairs(info) do
    out[name] = {
      scope = i.scope,
      all = get_option(name, { scope = "global" }),
      win = i.scope == "win" and get_option(name, { scope = "local", win = win }) or nil,
    }
  end
  return out
end

---Put every option back to its value at the start of the member (the global value of all of them, the
---local value of the current window for the window-local ones; buffers are fresh after the reset).
---@return string[] failed Options that could not be put back.
local function option_reconcile()
  local failed = {}
  local base = state.options
  if not base then
    return failed
  end
  local win = vim.api.nvim_get_current_win()
  for name, b in pairs(base) do
    if b.all ~= nil and not vim.deep_equal(get_option(name, { scope = "global" }), b.all) then
      pcall(vim.api.nvim_set_option_value, name, b.all, { scope = "global" })
      if not vim.deep_equal(get_option(name, { scope = "global" }), b.all) then
        failed[#failed + 1] = ("option '%s' (global)"):format(name)
      end
    end
    if
      b.scope == "win"
      and b.win ~= nil
      and not vim.deep_equal(get_option(name, { scope = "local", win = win }), b.win)
    then
      pcall(vim.api.nvim_set_option_value, name, b.win, { scope = "local", win = win })
      if not vim.deep_equal(get_option(name, { scope = "local", win = win }), b.win) then
        failed[#failed + 1] = ("option '%s' (window)"):format(name)
      end
    end
  end
  table.sort(failed)
  return failed
end

---The editor's own registries a spec can fill and the snapshot of `package.loaded`/`_G` cannot see,
---because they live in modules that must stay loaded (`vim.lsp`, `vim.diagnostic`): the servers
---registered with `vim.lsp.config(...)`, the ones switched on with `vim.lsp.enable(...)`, and the global
---`vim.diagnostic.config()`. A server another spec registered shows up in the completion of the next
---one's `:Lsp start`. Names and tables by identity; restored and verified like everything else.
---@return table
local function registries_capture()
  local snap = { lsp_configs = {}, lsp_enabled = {}, diagnostic = nil }
  -- `vim.lsp` loads on first use, and plugin code asks `rawget(vim, "lsp")` whether that already
  -- happened (ui.nvim's statusline renders "" without it): the member must not load it on its own
  -- account. Not loaded = nothing registered yet = an empty baseline.
  local lsp_loaded = rawget(vim, "lsp") ~= nil
  local ok, configs = pcall(function()
    return lsp_loaded and rawget(vim.lsp.config, "_configs") or nil
  end)
  if ok and type(configs) == "table" then
    for k, v in pairs(configs) do
      snap.lsp_configs[k] = v
    end
  end
  local eok, enabled = pcall(function()
    return lsp_loaded and vim.lsp._enabled_configs or nil
  end)
  if eok and type(enabled) == "table" then
    for k, v in pairs(enabled) do
      snap.lsp_enabled[k] = v
    end
  end
  local dok, diag = pcall(function()
    -- (loaded on purpose: its configuration has no "unset", so the default has to be read before a
    -- file changes it; nothing asks `rawget(vim, "diagnostic")`, unlike `vim.lsp`)
    return vim.diagnostic.config()
  end)
  if dok and type(diag) == "table" then
    snap.diagnostic = vim.deepcopy(diag)
  end
  return snap
end

---Tables whose function-valued fields a spec could replace for ever (a stub that is never put back):
---the editor API, the standard library, the string metatable. A replaced function is invisible to the
---snapshot of `package.loaded` and `_G` (the table is the same), and the next file would fail for a
---reason nobody can see.
---`vim.fn` is lazy (a function appears the first time it is called), so only a function that was
---already there and CHANGED counts; everywhere else a new function counts too.
---@return table<string, table> paths name -> table
local function identity_tables()
  local out = {}
  ---@param name string
  ---@param get fun(): any
  local function add(name, get)
    local ok, t = pcall(get)
    if ok and type(t) == "table" then
      out[name] = t
    end
  end
  add("vim", function()
    return vim
  end)
  for _, sub in ipairs({
    "api",
    "fn",
    "fs",
    "json",
    "uv",
    "ui",
    "lsp",
    "diagnostic",
    "keymap",
    "treesitter",
  }) do
    -- only what is loaded already: the member must not load `vim.lsp` & co. on its own account (see
    -- `registries_capture`); a module a file loads later has no baseline to compare with
    add("vim." .. sub, function()
      return rawget(vim, sub)
    end)
  end
  add("string", function()
    return string
  end)
  add("table", function()
    return table
  end)
  add("os", function()
    return os
  end)
  add("io", function()
    return io
  end)
  add("string metatable __index", function()
    local idx = getmetatable("").__index
    return type(idx) == "table" and idx ~= string and idx or nil -- usually `string` itself
  end)
  return out
end

---@type table<string, table<any, function>>|nil
local identities

---Where the functions that `vim.fn` creates by itself on first use are defined (`vim/_editor.lua`): a
---`vim.fn.x` that is new since the start and was NOT made there is a stub a spec assigned.
---@type string|nil
local fn_source

---The function-valued raw fields of the watched tables right now.
---@return table<string, table<any, function>>
local function identity_capture()
  local snap = {}
  for name, t in pairs(identity_tables()) do
    local fields = {}
    local ok = pcall(function()
      for k, v in next, t do
        if type(v) == "function" then
          fields[k] = v
        end
      end
    end)
    if ok then
      snap[name] = fields
    end
  end
  return snap
end

---Names of the functions that differ from the snapshot of the start (replaced, removed, added).
---@return string[]
local function identity_diff()
  local out = {}
  local base = identities
  if not base then
    return out
  end
  local now = identity_capture()
  for name, fields in pairs(base) do
    local cur = now[name] or {}
    -- `vim` and `vim.fn` create functions by themselves on first use (`vim.uri_*`, `vim.fn.x`): a new
    -- function there is a stub only when it was NOT defined by the runtime
    local lazy = name == "vim.fn" or name == "vim"
    if lazy then
      for k, v in pairs(cur) do
        if fields[k] == nil then
          local info = debug.getinfo(v, "S")
          local src = info and info.source or ""
          local runtime = src == "=[C]"
            or src == fn_source
            or src:find("/lua/vim/", 1, true) ~= nil
            or src:find("lua\vim\\", 1, true) ~= nil
            or src:find("^@vim[/]") ~= nil
          if info and not runtime then
            out[#out + 1] = ("%s.%s was replaced"):format(name, tostring(k))
          end
        end
      end
    end
    for k, v in pairs(fields) do
      if cur[k] == nil then
        out[#out + 1] = ("%s.%s was removed"):format(name, tostring(k))
      elseif cur[k] ~= v then
        out[#out + 1] = ("%s.%s was replaced"):format(name, tostring(k))
      end
    end
    if not lazy then
      for k in pairs(cur) do
        if fields[k] == nil then
          out[#out + 1] = ("%s.%s was added"):format(name, tostring(k))
        end
      end
    end
  end
  table.sort(out)
  return out
end

---Registers a spec can fill (`setreg`, a yank): the named, numbered and small-delete ones, the unnamed
---register and the last search pattern. The read-only ones (`:`, `.`, `%`, `#`) are the editor's own.
local REGISTERS = (function()
  local out = {}
  for c in ("abcdefghijklmnopqrstuvwxyz0123456789-/"):gmatch(".") do
    out[#out + 1] = c
  end
  out[#out + 1] = '"'
  return out
end)()

---What a register holds, in a form that compares: contents and type, or `false` for an empty one.
---@param name string
---@return table|false
local function register_value(name)
  local ok, info = pcall(vim.fn.getreginfo, name)
  if not ok or type(info) ~= "table" or type(info.regcontents) ~= "table" then
    return false
  end
  local empty = true
  for _, line in ipairs(info.regcontents) do
    if line ~= "" then
      empty = false
      break
    end
  end
  if empty then
    return false
  end
  return { regcontents = info.regcontents, regtype = info.regtype }
end

---Registers at the start, and the global abbreviations (`:abbreviate` is not part of the keymap
---snapshot of soft isolation).
---@return { regs: table<string, table|false>, abbrev: string }
local function extras_capture()
  local regs = {}
  for _, name in ipairs(REGISTERS) do
    regs[name] = register_value(name)
  end
  local ok, text = pcall(vim.fn.execute, "abbreviate")
  return { regs = regs, abbrev = ok and tostring(text) or "" }
end

---Put registers and abbreviations back to the start of the member and verify it.
---@return string[] failed
local function extras_reconcile()
  local failed = {}
  local base = state.extras
  if not base then
    return failed
  end
  -- the unnamed register points at another one: set it last
  local order = vim.deepcopy(REGISTERS)
  table.sort(order, function(a, b)
    if a == '"' or b == '"' then
      return b == '"' and a ~= '"'
    end
    return a < b
  end)
  for _, name in ipairs(order) do
    local want = base.regs[name]
    if not vim.deep_equal(register_value(name), want) then
      if want then
        pcall(vim.fn.setreg, name, want.regcontents, want.regtype)
      else
        pcall(vim.fn.setreg, name, "")
      end
      if not vim.deep_equal(register_value(name), want) then
        failed[#failed + 1] = ("register '%s'"):format(name)
      end
    end
  end
  local ok, text = pcall(vim.fn.execute, "abbreviate")
  if ok and tostring(text) ~= base.abbrev then
    if base.abbrev:find("No abbreviation found", 1, true) then
      pcall(vim.api.nvim_command, "abclear")
    end
    local ok2, again = pcall(vim.fn.execute, "abbreviate")
    if not (ok2 and tostring(again) == base.abbrev) then
      failed[#failed + 1] = "abbreviations"
    end
  end
  return failed
end

---@param tbl table
---@param base table
local function restore_keys(tbl, base)
  for k in pairs(tbl) do
    if base[k] == nil then
      tbl[k] = nil
    end
  end
  for k, v in pairs(base) do
    tbl[k] = v
  end
end

---Put the registries back to the snapshot of the start.
---@return string[] failed What could not be put back.
local function registries_reconcile()
  local failed = {}
  local base = state.registries
  if not base then
    return failed
  end
  local lsp_loaded = rawget(vim, "lsp") ~= nil
  local ok, configs = pcall(function()
    return lsp_loaded and rawget(vim.lsp.config, "_configs") or nil
  end)
  if ok and type(configs) == "table" then
    pcall(restore_keys, configs, base.lsp_configs)
  end
  local eok, enabled = pcall(function()
    return lsp_loaded and vim.lsp._enabled_configs or nil
  end)
  if eok and type(enabled) == "table" then
    pcall(restore_keys, enabled, base.lsp_enabled)
  end
  if base.diagnostic then
    pcall(vim.diagnostic.config, vim.deepcopy(base.diagnostic))
  end
  local now = registries_capture()
  for _, which in ipairs({ "lsp_configs", "lsp_enabled" }) do
    for k, v in pairs(now[which]) do
      if base[which][k] ~= v then
        failed[#failed + 1] = ("%s `%s`"):format(
          which == "lsp_configs" and "vim.lsp.config" or "vim.lsp.enable",
          k
        )
      end
    end
    for k in pairs(base[which]) do
      if now[which][k] == nil then
        failed[#failed + 1] = ("%s `%s` is gone"):format(
          which == "lsp_configs" and "vim.lsp.config" or "vim.lsp.enable",
          k
        )
      end
    end
  end
  if base.diagnostic and not vim.deep_equal(now.diagnostic, base.diagnostic) then
    failed[#failed + 1] = "vim.diagnostic.config()"
  end
  table.sort(failed)
  return failed
end

---Most entries of a sandbox directory that are looked at (a member that grows past it is discarded).
M.MAX_ENTRIES = 2000

---Entries of a directory: relative path -> type.
---@param dir string
---@return table<string, string> entries
---@return boolean truncated
local function list(dir)
  local out, n = {}, 0
  if vim.fn.isdirectory(dir) ~= 1 then
    return out, false
  end
  for name, typ in vim.fs.dir(dir, { depth = 12 }) do
    n = n + 1
    if n > M.MAX_ENTRIES then
      return out, true
    end
    out[name] = typ
  end
  return out, false
end

---@class Testing.PoolBoot.InitOpts
---@field filetype? boolean `filetype plugin indent on` (default true), like a per-file child.
---@field keep? string[] Modules soft isolation never unloads (`soft_keep`).
---@field severity? "warn"|"error" Severity of what could not be restored (nil: reported in the answer only).
---@field dirs? table<string, string> Sandbox directories (`config`, `data`, `state`, `cache`) to keep clean.

---Set the member up once, right after `rpc_boot.install`.
---@param opts? Testing.PoolBoot.InitOpts
---@return boolean ok
function M.init(opts)
  opts = opts or {}
  -- a headless child has no screen to page: a long message (`:Testing config`) would wait for a key
  -- ("-- More --") and block the request that printed it for ever
  vim.o.more = false
  if opts.filetype == false then
    vim.cmd("filetype plugin indent off")
  else
    vim.cmd("filetype plugin indent on")
  end
  state.session = require("testing.isolation").new({
    keep = opts.keep or {},
    severity = opts.severity,
    -- what was restored is the reset doing its job (a respawned child would have died with it);
    -- only what could NOT be restored is a finding
    report_restored = false,
    -- buffers, windows and tabs are put back by `rpc_boot.reset()` (wipe everything, one window, one
    -- tab) and verified by `structure` below: the soft isolation cannot recreate a wiped buffer or
    -- close the last window, and would call every file that wipes the first buffer a leak
    skip_kinds = { "buffer", "window", "tab" },
    -- `lib.*` is NOT kept (as it is when the runner restores its own editor): a lib.nvim module that
    -- registered an autocmd when it loaded would stay loaded while the autocmd is restored away, and
    -- never register it again (lib.nvim's `buffer.context` BufDelete cleanup stopped working)
    keep_prefixes = { "vim", "jit", "testing", "ffi", "bit", "luv", "uv", "libluv", "string" },
  })
  state.options = option_baseline()
  state.registries = registries_capture()
  pcall(function()
    local getpid = vim.fn.getpid -- materializes one lazy function to learn where they come from
    fn_source = debug.getinfo(getpid, "S").source
  end)
  identities = identity_capture()
  state.extras = extras_capture()
  state.dirs = {}
  state.baseline = {}
  state.keep_dirs = {}
  -- the directories the runtime itself creates once and assumes to exist afterwards (`vim.lsp.log` makes
  -- its directory when the module loads): the paths of `stdpath()` and every parent stay
  local stdpaths = {}
  for _, kind in ipairs({ "config", "data", "state", "cache", "log" }) do
    local ok, p = pcall(vim.fn.stdpath, kind)
    if ok and type(p) == "string" then
      stdpaths[#stdpaths + 1] = vim.fs.normalize(p)
    end
  end
  for name, dir in pairs(opts.dirs or {}) do
    state.dirs[name] = dir
    state.baseline[name] = (list(dir))
    local keep = {}
    local base = vim.fs.normalize(dir):gsub("/+$", "")
    for _, p in ipairs(stdpaths) do
      if p:sub(1, #base + 1) == base .. "/" then
        local rel = p:sub(#base + 2)
        while rel ~= "" and rel ~= "." do
          keep[rel] = true
          rel = rel:match("^(.*)/[^/]+$") or ""
        end
      end
    end
    state.keep_dirs[name] = keep
  end
  return true
end

---Remove what the file wrote below the sandbox directories.
---@return integer removed
---@return string[] failed Paths that could not be removed (or a directory that grew too large).
local function wipe_sandbox()
  local removed, failed = 0, {}
  for name, dir in pairs(state.dirs) do
    local now, truncated = list(dir)
    local base = state.baseline[name] or {}
    local keep = state.keep_dirs[name] or {}
    local fresh = {}
    for rel in pairs(now) do
      if base[rel] == nil and not keep[rel] and not runtime_file(rel) then
        fresh[#fresh + 1] = rel
      end
    end
    -- children before parents, so a directory is empty when it is removed
    table.sort(fresh, function(a, b)
      return #a > #b
    end)
    for _, rel in ipairs(fresh) do
      local path = dir .. "/" .. rel
      if vim.uv.fs_stat(path) then
        if vim.fn.delete(path, "rf") == 0 then
          removed = removed + 1
        else
          failed[#failed + 1] = ("%s/%s"):format(name, rel)
        end
      end
    end
    if truncated then
      failed[#failed + 1] = ("%s: more than %d entries"):format(name, M.MAX_ENTRIES)
    end
  end
  return removed, failed
end

---What must be true after `rpc_boot.reset()`: ONE tab, ONE window (not floating), ONE buffer that is
---empty, unnamed and unmodified, normal mode, nothing typed waiting.
---@return string[] problems
function M.structure()
  local problems = {}
  local tabs, wins = vim.api.nvim_list_tabpages(), vim.api.nvim_list_wins()
  if #tabs ~= 1 then
    problems[#problems + 1] = ("%d tab pages are open"):format(#tabs)
  end
  if #wins ~= 1 then
    problems[#problems + 1] = ("%d windows are open"):format(#wins)
  end
  local bufs = vim.api.nvim_list_bufs()
  if #bufs ~= 1 then
    problems[#problems + 1] = ("%d buffers exist"):format(#bufs)
  else
    local b = bufs[1]
    if
      vim.api.nvim_buf_get_name(b) ~= ""
      or vim.bo[b].modified
      or vim.api.nvim_buf_line_count(b) > 1
      or #(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or "") > 0
    then
      problems[#problems + 1] = "the remaining buffer is not empty and unnamed"
    end
  end
  if vim.api.nvim_get_mode().mode ~= "n" then
    problems[#problems + 1] = "the editor is not in normal mode"
  end
  return problems
end

---`rpc_boot.reset()` compares with the state of the editor at INSTALL time; the soft isolation of
---`finish` compares with the state before THIS file and verifies its own restore. For autocmds, global
---mappings and `vim.g` keys the second is the better judge: the editor's runtime initializes variables
---and autocmds lazily the first time a filetype or a syntax is used (`vim.g.lua_version`,
---`markdown_minlines`, ...), which would make the first file that opens a markdown buffer look like a
---leak for ever. What only the reset can see (active handles, callbacks that did not run) still counts.
---@param line string One entry of `rpc_boot.reset()`.
---@return boolean
local function covered_by_soft(line)
  return line:find("^autocmd ") ~= nil
    or line:find("^global keymap ") ~= nil
    or line:find("^vim%.g%.") ~= nil
end

---@class Testing.PoolBoot.Answer
---@field ok boolean The driver ran (a red case is still `ok`).
---@field err? string
---@field output string `:messages` of the file (what `print` and `:echo` wrote).

---@class Testing.PoolBoot.Finish
---@field leaks string[] What `rpc_boot.reset()` found still different.
---@field unrestored string[] What soft isolation could not restore.
---@field removed integer Entries removed from the sandbox directories.
---@field sandbox string[] What could not be removed from them.
---@field ms table<string, number> What each step cost (milliseconds): settle, soft, options, reset, sandbox.

---What `run` left for `finish`.
---@type { rel: string, frame: table|nil }|nil
local pending

---PHASE 1 of a file: snapshot, run the file, collect its output. Never raises: a failure is part of
---the answer. The editor goes back to its main loop after this returns (callbacks scheduled by the
---file run, `SafeState` autocmds fire); `finish` then judges the state.
---@param job table See `testing.child.runner`.
---@return Testing.PoolBoot.Answer
function M.run(job)
  ---@type Testing.PoolBoot.Answer
  local answer = { ok = false, output = "" }
  local rel = job.entry and job.entry.rel
  pcall(vim.api.nvim_command, "silent! messages clear")
  local ok, err = pcall(function()
    pending = { rel = rel, frame = state.session and state.session:enter(rel) or nil }
    local ran = require("testing.child.runner").run(job, {})
    answer.ok, answer.err = ran.ok, ran.err
  end)
  if not ok then
    answer.ok, answer.err = false, "the pool member failed: " .. tostring(err)
  end
  local mok, lines = pcall(function()
    return require("testing.child.rpc_boot").messages()
  end)
  if mok and type(lines) == "table" then
    answer.output = table.concat(lines, "\n")
  end
  return answer
end

---Time `finish` gives the editor to become idle before it judges (ms).
M.SETTLE_MS = 100

---PHASE 2 of a file: let pending callbacks run, restore and verify what the file changed (soft
---isolation), reset buffers/windows/tabs/cwd, empty the sandbox. The caller reuses the member only
---when every list of the answer is empty. Never raises.
---@return Testing.PoolBoot.Finish
function M.finish()
  ---@type Testing.PoolBoot.Finish
  local answer = { leaks = {}, unrestored = {}, removed = 0, sandbox = {}, ms = {} }
  local clock = vim.uv.hrtime
  local t = clock()
  ---Milliseconds since the last `lap`, stored under `name` (what `finish` costs, step by step).
  local function lap(name)
    local now = clock()
    answer.ms[name] = math.floor((now - t) / 1e4) / 100
    t = now
  end
  local rb = require("testing.child.rpc_boot")
  local frame, rel = pending and pending.frame, pending and pending.rel
  pending = nil
  -- the editor is idle again (the request ended): what the file scheduled had its chance to run
  pcall(vim.wait, M.SETTLE_MS, function()
    local ok, busy = pcall(rb.settle_state)
    return ok and next(busy) == nil
  end, 5)
  lap("settle")
  if state.session and frame then
    local lok, lerr = pcall(function()
      return state.session:leave(frame)
    end)
    if lok then
      for _, item in ipairs(lerr.items) do
        if not item.restored then
          answer.unrestored[#answer.unrestored + 1] = ("%s: %s%s"):format(
            item.kind,
            item.name,
            item.why and (" (" .. item.why .. ")") or ""
          )
        end
      end
    else
      answer.unrestored[1] = "soft isolation failed for " .. tostring(rel) .. ": " .. tostring(lerr)
    end
  elseif state.session then
    answer.unrestored[1] = "soft isolation could not take its snapshot before " .. tostring(rel)
  end
  lap("soft")
  -- options first: the buffer `reset` leaves behind starts from the GLOBAL values; checked again after
  pcall(option_reconcile)
  local rgok, rgfailed = pcall(registries_reconcile)
  lap("options")
  local rok, leaks = pcall(rb.reset)
  if rok then
    for _, l in ipairs(leaks) do
      if not covered_by_soft(l) then
        answer.leaks[#answer.leaks + 1] = l
      end
    end
    if rgok then
      vim.list_extend(answer.leaks, rgfailed)
    else
      answer.leaks[#answer.leaks + 1] = "registry reset failed: " .. tostring(rgfailed)
    end
    local ook, failed = pcall(option_reconcile)
    if ook then
      vim.list_extend(answer.leaks, failed)
    else
      answer.leaks[#answer.leaks + 1] = "option reset failed: " .. tostring(failed)
    end
    local eok, efailed = pcall(extras_reconcile)
    if eok then
      vim.list_extend(answer.leaks, efailed)
    else
      answer.leaks[#answer.leaks + 1] = "register reset failed: " .. tostring(efailed)
    end
    local iok, changed = pcall(identity_diff)
    if iok then
      for i, l in ipairs(changed) do
        if i > 6 then
          answer.leaks[#answer.leaks + 1] = ("... and %d more replaced function(s)"):format(
            #changed - 6
          )
          break
        end
        answer.leaks[#answer.leaks + 1] = l
      end
    else
      answer.leaks[#answer.leaks + 1] = "function identity check failed: " .. tostring(changed)
    end
    local gok, live = pcall(function()
      local g = package.loaded["testing.guard"]
      return g and g.live_count and g.live_count() or 0
    end)
    if gok and live > 0 then
      answer.leaks[#answer.leaks + 1] = ("the guard layer is still installed (%d handle(s)): the next file would wrap its wrappers"):format(
        live
      )
    end
    -- a patch of the guard layer that could not be put back: the file stubbed (or replaced) the very
    -- function the guard had wrapped, on top of the wrapper, and never restored it
    local uok, left = pcall(function()
      local g = package.loaded["testing.guard"]
      return g and g.take_unrestored and g.take_unrestored() or {}
    end)
    if uok then
      for _, label in ipairs(left) do
        answer.leaks[#answer.leaks + 1] = ("guard patch not restored: %s (%s replaced or wrapped it and did not put it back)"):format(
          tostring(label),
          tostring(rel or "the file")
        )
      end
    end
    local sok, problems = pcall(M.structure)
    for _, p in ipairs(sok and problems or { "structure check failed: " .. tostring(problems) }) do
      answer.leaks[#answer.leaks + 1] = p
    end
  else
    answer.leaks = { "reset failed: " .. tostring(leaks) }
  end
  lap("reset")
  local wok, removed, failed = pcall(wipe_sandbox)
  if wok then
    answer.removed, answer.sandbox = removed, failed
  else
    answer.sandbox = { "cleanup failed: " .. tostring(removed) }
  end
  lap("sandbox")
  return answer
end

return M
