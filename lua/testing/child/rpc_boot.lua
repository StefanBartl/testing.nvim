---@module 'testing.child.rpc_boot'
---@brief Runs INSIDE an RPC child (`testing.rpc`): captures, baselines, probes. Not a script: a module.
---@description
--- The driver (`testing.rpc`) starts `nvim --embed` and, as its first request, puts this checkout on
--- the child's runtimepath and calls `install(opts)`. Everything below is driven by later requests
--- (`require("testing.child.rpc_boot").settle_state()`, ...); nothing here runs on its own.
---
--- WHAT IT DOES
---   * `vim.notify` capture: every call is pushed to the parent as a `testing:event` notification
---     (`notify`, `{ msg, level }`) and, by default, passed on to the original `vim.notify`. The parent
---     keeps its own copy, so the notifications of a child that died are still there for the trace.
---     Limit: a plugin that cached `vim.notify` in a local BEFORE `install` ran bypasses the capture.
---   * prompt capture: `input`, `inputlist`, `inputdialog`, `inputsecret`, `confirm` answer with
---     "cancelled" and are reported (`prompt`), so a spec that asks a question fails or goes on
---     deterministically instead of blocking the RPC request for ever. `prompts = "real"` leaves them
---     alone (a spec that answers them through `child.input`). When the guard module
---     (`testing.guard`) is present it owns the prompt guard (answers, stack traces); the capture here
---     is then off.
---   * the guard hook: if `testing.guard` exists, `guard.install(cfg)` is called ONCE (a missing module
---     is fine, an install that raises is an error of the spawn). What it returns is kept as the guard
---     handle: `guard_call(method, args)` forwards to it (`begin_case`, `end_case`, `collect`,
---     `answer_prompts`, ...) and `effects()` returns what `handle:collect()` gathered (its `effects`
---     field: `{ spawned, network, fs_outside_tmp }`). A guard module whose `install` returns nothing
---     but which has a module-level `collect()` works as well.
---   * `settle` state: a baseline of the active libuv handles by type plus a counter of scheduled
---     callbacks that have not run (`vim.schedule` is wrapped to count). See `settle_state`.
---   * `reset`: wipes buffers, windows, tabs, the command line and the cwd, then names what the
---     baseline says is still different.
---   * `screen`: a text grid of the screen.

local M = {}

local uv = vim.uv or vim.loop

---@class Testing.RpcBoot.State
---@field chan? integer Channel of the parent (stdio).
---@field handles table<string, integer> Baseline of active handles by type.
---@field jobs integer Baseline of running jobs (`jobstart`, `termopen`: libuv hides these from `uv.walk`).
---@field pending integer Scheduled callbacks that have not run yet.
---@field cwd? string
---@field snap? table Baseline of autocmds, keymaps and globals.
---@field guard "absent"|"installed"
---@field guard_handle? table What `testing.guard.install` returned.
---@field prompts "cancel"|"real"
---@field notify_passthrough boolean
local state = {
  handles = {},
  jobs = 0,
  pending = 0,
  guard = "absent",
  prompts = "cancel",
  notify_passthrough = true,
}

---Handle types that nvim itself starts and stops all the time: never part of a settle decision.
local IGNORED_TYPES =
  { signal = true, async = true, tty = true, check = true, prepare = true, idle = true }

---Tell the parent something. Never raises: a child without a parent channel just records nothing.
---@param kind string
---@param payload table
local function emit(kind, payload)
  if state.chan then
    pcall(vim.rpcnotify, state.chan, "testing:event", kind, payload)
  end
end

---The channel the parent is connected on (the one on our stdio).
---@return integer|nil
local function parent_channel()
  for _, c in ipairs(vim.api.nvim_list_chans()) do
    if c.stream == "stdio" and c.mode == "rpc" then
      return c.id
    end
  end
  return nil
end

---Active libuv handles by type.
---@return table<string, integer>
local function handle_counts()
  local counts = {}
  uv.walk(function(h)
    if uv.is_closing(h) or not uv.is_active(h) then
      return
    end
    local t = uv.handle_get_type(h)
    if t and not IGNORED_TYPES[t] then
      counts[t] = (counts[t] or 0) + 1
    end
  end)
  return counts
end

---Running jobs of the editor (`jobstart`, `termopen`, `vim.fn.system` in flight). `uv.walk` only sees the
---handles luv itself made: a job's process and pipes are invisible to it, its channel is not.
---@return integer
local function job_count()
  local n = 0
  for _, c in ipairs(vim.api.nvim_list_chans()) do
    if c.stream == "job" then
      n = n + 1
    end
  end
  return n
end

---Count the scheduled callbacks that have not run yet. Callbacks scheduled through a reference to
---`vim.schedule` taken before `install` are not counted (documented limit of `settle`).
local function track_schedule()
  local orig = vim.schedule
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.schedule = function(fn)
    state.pending = state.pending + 1
    return orig(function()
      state.pending = state.pending - 1
      return fn()
    end)
  end
end

local PROMPTS = { input = "", inputdialog = "", inputsecret = "", inputlist = 0, confirm = 0 }

local function capture_prompts()
  for name, answer in pairs(PROMPTS) do
    vim.fn[name] = function(...)
      local first = select(1, ...)
      emit("prompt", { fn = name, text = type(first) == "string" and first or "" })
      return answer
    end
  end
end

---Does a module of this checkout/runtimepath exist? (without loading it)
---@param name string
---@return boolean
local function module_exists(name)
  local rel = name:gsub("%.", "/")
  return #vim.api.nvim_get_runtime_file("lua/" .. rel .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/" .. rel .. "/init.lua", false) > 0
end

---@return table
local function snapshot()
  local autocmds = {}
  for _, a in ipairs(vim.api.nvim_get_autocmds({})) do
    -- the editor's own groups (`nvim.treesitter.query_cache_reset`, ...) appear lazily: not the spec's
    if not tostring(a.group_name or ""):find("^nvim%.") then
      autocmds[a.id or 0] = ("%s in group %s (pattern %s)"):format(
        a.event,
        a.group_name or "<none>",
        a.pattern or "*"
      )
    end
  end
  local keymaps = {}
  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o", "c", "t", "l" }) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      keymaps[mode .. " " .. m.lhs] = true
    end
  end
  local globals = {}
  -- `pairs(vim.g)` iterates nothing (a proxy); `g:` as a dictionary lists every global variable
  for k in pairs(vim.api.nvim_eval("g:")) do
    globals[k] = true
  end
  return { autocmds = autocmds, keymaps = keymaps, globals = globals }
end

---@class Testing.RpcBoot.Opts
---@field prompts? "cancel"|"real" Default "cancel".
---@field notify_passthrough? boolean Also call the original `vim.notify` (default true).
---@field track_schedule? boolean Wrap `vim.schedule` to count pending callbacks (default true).
---@field guard? table|false Config handed to `testing.guard.install` (default `{}`; `false`: no guard).

---Install the captures and take the baselines. Call once, after the project's minimal init ran.
---@param opts? Testing.RpcBoot.Opts
---@return { guard: string, nvim: string, chan?: integer }
function M.install(opts)
  opts = opts or {}
  state.chan = parent_channel()
  state.prompts = opts.prompts == "real" and "real" or "cancel"
  state.notify_passthrough = opts.notify_passthrough ~= false

  local orig_notify = vim.notify --[[@as function]]
  vim.notify = function(msg, level, o)
    emit("notify", { msg = tostring(msg), level = tonumber(level) or vim.log.levels.INFO })
    if state.notify_passthrough then
      return orig_notify(msg, level, o)
    end
  end

  if opts.guard ~= false and module_exists("testing.guard") then
    local g = require("testing.guard") --[[@as table]]
    if type(g.install) == "function" then
      local handle = g.install(type(opts.guard) == "table" and opts.guard or {})
      state.guard_handle = type(handle) == "table" and handle or nil
      state.guard = "installed"
    end
  end
  if state.prompts == "cancel" and state.guard ~= "installed" then
    capture_prompts()
  end
  if opts.track_schedule ~= false then
    track_schedule()
  end

  state.cwd = uv.cwd()
  state.snap = snapshot()
  state.handles = handle_counts()
  state.jobs = job_count()
  local v = vim.version()
  return {
    guard = state.guard,
    nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    chan = state.chan,
  }
end

---Take the handle baseline again (after the caller deliberately started something long-lived).
function M.rebaseline()
  state.handles = handle_counts()
  state.jobs = job_count()
  state.pending = 0
end

---What keeps the editor busy right now. Empty table = quiet. One probe; the parent
---(`testing.rpc` `settle`) polls it until it is quiet twice in a row.
---
---HEURISTIC AND ITS LIMITS. "Quiet" means: no typed key waiting (`getchar(1)`), no mode that
---waits for the user (`nvim_get_mode().blocking`), no scheduled callback that has not run (counted
---through the wrapped `vim.schedule`), and no more active libuv handles per type than at the
---baseline (timers started by `vim.defer_fn`/`vim.uv`, jobs, pipes, fs watchers). It does NOT know:
---a callback scheduled through a reference to `vim.schedule` taken before `install`; work a plugin
---has not started YET (a debounce that arms its timer only on the next event); a plugin that keeps a
---periodic timer for ever (that never settles: the parent reports the handle type; call
---`rebaseline` after the plugin was set up to accept it); work in other processes.
---@return table busy
function M.settle_state()
  local busy = {}
  local ok, ta = pcall(vim.fn.getchar, 1)
  if ok and ta ~= 0 then
    busy.typeahead = true
  end
  local mode = vim.api.nvim_get_mode()
  if mode.blocking then
    busy.blocking = mode.mode
  end
  if state.pending > 0 then
    busy.scheduled = state.pending
  end
  local over = {}
  for t, n in pairs(handle_counts()) do
    local extra = n - (state.handles[t] or 0)
    if extra > 0 then
      over[t] = extra
    end
  end
  if next(over) then
    busy.handles = over
  end
  local jobs = job_count() - state.jobs
  if jobs > 0 then
    busy.jobs = jobs
  end
  return busy
end

---Differences to the baseline, as readable sentences ("spec leaves autocmd X in group Y").
---@return string[]
function M.leaks()
  local out = {}
  if not state.snap then
    return out
  end
  local now = snapshot()
  local added = {}
  for id, text in pairs(now.autocmds) do
    if not state.snap.autocmds[id] then
      added[#added + 1] = text
    end
  end
  table.sort(added)
  for _, text in ipairs(added) do
    out[#out + 1] = "autocmd " .. text
  end
  local keys = {}
  for k in pairs(now.keymaps) do
    if not state.snap.keymaps[k] then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = "global keymap " .. k
  end
  local globals = {}
  for k in pairs(now.globals) do
    if not state.snap.globals[k] then
      globals[#globals + 1] = k
    end
  end
  table.sort(globals)
  for _, k in ipairs(globals) do
    out[#out + 1] = "vim.g." .. k
  end
  local busy = M.settle_state()
  for t, n in pairs(busy.handles or {}) do
    out[#out + 1] = ("%d active %s handle(s)"):format(n, t)
  end
  if busy.jobs then
    out[#out + 1] = ("%d running job(s)"):format(busy.jobs)
  end
  if busy.scheduled then
    out[#out + 1] = ("%d scheduled callback(s) that have not run"):format(busy.scheduled)
  end
  return out
end

---Delete every `t:` and `w:` variable of the one tab and window that are left, and the diagnostics of
---every namespace. Buffers are wiped (their `b:` variables with them), but the first tab page and window
---stay, and a plugin's bookkeeping in `vim.t` (a list of buffer numbers that no longer exist) or
---`vim.w` made the next file fail with "E86: Buffer N does not exist".
local function clear_scoped_state()
  local tok, tvars = pcall(vim.fn.gettabvar, vim.fn.tabpagenr(), "")
  if tok and type(tvars) == "table" then
    for name in pairs(tvars) do
      pcall(vim.api.nvim_tabpage_del_var, 0, name)
    end
  end
  local wok, wvars = pcall(vim.fn.getwinvar, 0, "")
  if wok and type(wvars) == "table" then
    for name in pairs(wvars) do
      pcall(vim.api.nvim_win_del_var, 0, name)
    end
  end
  -- (only when the module is loaded: nothing can have set a diagnostic otherwise, and a member must not
  -- load `vim.diagnostic` on its own account)
  if rawget(vim, "diagnostic") ~= nil then
    pcall(vim.diagnostic.reset)
  end
end

---Bring the editor back to a plain state: no buffers, one window, one tab, normal mode, empty
---command line, the working directory of the baseline. Then name what is still different.
---Autocmds, mappings, globals and `package.loaded` are NOT undone (an honest reset cannot); they are
---reported, and the caller restarts the child when the list is not empty.
---@return string[] leaks
function M.reset()
  for _, ex in ipairs({
    "stopinsert",
    "silent! tabonly!",
    "silent! only!",
    "silent! %bwipeout!",
    "silent! messages clear",
  }) do
    pcall(vim.api.nvim_command, ex)
    if ex == "stopinsert" then
      pcall(vim.api.nvim_feedkeys, vim.keycode("<Esc><Esc>"), "nx", false)
    end
  end
  clear_scoped_state()
  if state.cwd then
    pcall(vim.api.nvim_set_current_dir, state.cwd)
  end
  return M.leaks()
end

---A copy of `v` that can travel over msgpack: functions, userdata and threads are dropped, cycles
---and deep nesting are cut. A guard's result may hold closures or handles of its own.
---@param v any
---@param depth? integer
---@param seen? table
---@return any
local function plain(v, depth, seen)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" or v == vim.NIL then
    return v
  end
  if t ~= "table" then
    return nil
  end
  depth, seen = depth or 0, seen or {}
  if depth > 12 or seen[v] then
    return nil
  end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" or type(k) == "number" then
      out[k] = plain(x, depth + 1, seen)
    end
  end
  seen[v] = nil
  return out
end

---Call a method of the guard handle (`begin_case`, `end_case`, `collect`, `answer_prompts`, ...).
---@param method string
---@param args any[]
---@return any
function M.guard_call(method, args)
  local h = state.guard_handle
  if not h then
    error(
      "no guard handle in this child (guard = false, no testing.guard module, or its install returned no handle)",
      0
    )
  end
  local f = h[method]
  if type(f) ~= "function" then
    error(("the guard handle has no method %q"):format(tostring(method)), 0)
  end
  return plain(f(h, unpack(args or {})))
end

---What the guard collected, or the empty ledger when there is no guard. The ledger shape is
---`{ spawned, network, fs_outside_tmp }`; a guard whose `collect()` returns a wrapper with an
---`effects` field (`testing.guard`) is unwrapped.
---@return table
function M.effects()
  local collected
  if state.guard_handle and type(state.guard_handle.collect) == "function" then
    collected = state.guard_handle:collect()
  elseif state.guard == "installed" then
    local g = require("testing.guard")
    if type(g.collect) == "function" then
      collected = g.collect()
    end
  end
  if type(collected) == "table" then
    return plain(type(collected.effects) == "table" and collected.effects or collected)
  end
  return { spawned = {}, network = {}, fs_outside_tmp = {} }
end

---The lines of `:messages`.
---@return string[]
function M.messages()
  local out = vim.api.nvim_exec2("messages", { output = true }).output or ""
  if out == "" then
    return {}
  end
  return vim.split(out, "\n", { plain = true })
end

local ATTR_LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

---A text grid of the screen. `lines[r]` is row r with one character per cell (a wide character's
---second cell is skipped); `attrs[r]` has one letter per cell: ' ' = no highlight, otherwise a letter
---per DISTINCT attribute in order of first appearance (attributes are comparable, not resolvable to a
---group: `vim.inspect_pos` names the groups of a buffer position).
---Needs an attached UI (the parent attaches one before the first call): without a UI nvim does not
---draw and `screenstring()` is empty.
---@return table screen
function M.screen()
  vim.cmd("redraw")
  local rows, cols = vim.o.lines, vim.o.columns
  local lines, attrs, letters, nletters = {}, {}, {}, 0
  for r = 1, rows do
    local cells, marks = {}, {}
    for c = 1, cols do
      local s = vim.fn.screenstring(r, c)
      local a = vim.fn.screenattr(r, c)
      local mark = " "
      if a ~= 0 then
        if not letters[a] then
          nletters = nletters + 1
          letters[a] = ATTR_LETTERS:sub(nletters, nletters)
          if letters[a] == "" then
            letters[a] = "?"
          end
        end
        mark = letters[a]
      end
      if s ~= "" then
        cells[#cells + 1] = s
        marks[#marks + 1] = mark
      end
    end
    lines[r] = table.concat(cells)
    attrs[r] = table.concat(marks)
  end
  local trimmed = {}
  for r, l in ipairs(lines) do
    trimmed[r] = (l:gsub("%s+$", ""))
  end
  return {
    size = { rows = rows, cols = cols },
    cursor = { row = vim.fn.screenrow(), col = vim.fn.screencol() },
    mode = vim.api.nvim_get_mode().mode,
    lines = lines,
    attrs = attrs,
    text = table.concat(trimmed, "\n"),
  }
end

return M
