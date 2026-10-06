---@module 'testing.rpc'
---@brief RPC child driver: an embedded, headless, isolated Neovim that a spec drives like a user would.
---@description
--- `require("testing.rpc").spawn(opts)` starts
---
---   nvim --embed --headless --clean -n -i NONE -u <testing/child/rpc_init.lua>
---
--- in a private sandbox (XDG and temp directories, `testing.child.env`) with an allowlisted
--- environment (`$NVIM`, `$NVIM_LISTEN_ADDRESS` and secrets never reach it) plus determinism variables
--- (`LANG`/`LC_ALL=C.UTF-8`, `TZ=UTC`), talks msgpack-rpc over its stdio (`testing.rpc.wire`) and
--- returns a handle with the surface documented in `docs/CHILD.md`.
---
--- DECISIONS
---   * Own libuv client instead of `jobstart({ rpc = true })` (the concept sketch): `vim.rpcrequest`
---     blocks without a timeout (a child in an endless loop would hang the run) and an `rpc = true` job
---     may call the PARENT's API. Here every call has a timeout and a request from the child is
---     refused. The process is started by `testing.child.spawn` (the same code that runs the per-file
---     children: process-tree kill, drain, abandon).
---   * No `--listen`. nvim still opens its own default server (a named pipe on Windows, a socket in the
---     private `XDG_RUNTIME_DIR` elsewhere); nothing here uses it.
---   * Calls are SYNCHRONOUS from the spec's point of view: the caller waits with `vim.wait` (the event
---     loop keeps running), so a spec reads like straight-line code.
---   * A call that times out kills the child (`kill_on_timeout`, default true): after a timeout the
---     state of the child is unknowable and every later call would queue behind the stuck one.
---   * Handles (buffer, window, tab) travel as plain integers and are never cached here: the child
---     validates them when the call EXECUTES (`E5555: Invalid buffer id`), and `b`/`w`/`bo`/`wo` always
---     mean the CURRENT buffer/window at that moment (ERR-33).
---
--- A dead child is never a hang: the next call (and `ensure_alive`) raises `child died: <exit code or
--- signal>; stderr: <tail>`, and, with a `trace_dir`, the failing call has written the trace file
--- (`testing.rpc.trace`).

local child_mod = require("testing.child")
local wire_mod = require("testing.rpc.wire")
local trace_mod = require("testing.rpc.trace")

local M = {}
local uv = vim.uv or vim.loop

---Default timeout of one RPC call (ms).
M.CALL_TIMEOUT_MS = 10000
---Default time the editor may take to start and run the project's init (ms).
M.BOOT_TIMEOUT_MS = 20000
---How long `kill` waits for the process to end before it is abandoned (ms).
M.REAP_MS = 10000

---@class Testing.Rpc.Opts
---@field root? string Working directory and base of `<REPO>` (default: the current directory).
---@field minit? string Absolute path of the project's minimal init (run as the `-u` init).
---@field rtp_prepend? string[] Directories put first on the child's runtimepath (default: this checkout and lib.nvim).
---@field rtp? string[] Directories appended to the child's runtimepath.
---@field env_allow? string[] Extra environment names (see `testing.child.env`).
---@field extra_env? table<string, string> Variables set by the driver (default adds `TESTING_NVIM_DIR`, `LIB_NVIM_DIR`).
---@field parent_env? table<string, string> Replaces `vim.fn.environ()` (specs).
---@field nvim? string Executable (default `vim.v.progpath`).
---@field base? string Directory below which the sandbox is created.
---@field name? string Sandbox directory name (default unique).
---@field deterministic? boolean `LANG`/`LC_ALL=C.UTF-8`, `TZ=UTC` (default true; false passes the parent's through).
---@field disable_first_run? boolean lib.nvim first-run opt-out (default true).
---@field defer_plugins? boolean The runtimepath of `rtp_prepend`/`rtp`/`minit` is applied AFTER the editor sourced its `plugin/` files (default false: a real session, plugins of the project load at start). The warm pool sets it: a per-file child never has the project's `plugin/` files sourced either.
---@field call_timeout_ms? integer Timeout of one call (default `M.CALL_TIMEOUT_MS`); adjustable later: `child.call_timeout_ms = n`.
---@field boot_timeout_ms? integer Default `M.BOOT_TIMEOUT_MS`.
---@field kill_on_timeout? boolean Kill the child when a call times out (default true).
---@field size? { rows: integer, cols: integer } Screen size for `screen()` (default 24x80).
---@field prompts? "cancel"|"real" `input()`/`confirm()` answer "cancelled" (default) or are left alone.
---@field notify_passthrough? boolean Also run the original `vim.notify` (default true).
---@field track_schedule? boolean Count scheduled callbacks for `settle` (default true).
---@field guard? table|false Config for `testing.guard.install` (default `{}`; false: none).
---@field trace_dir? string Where a trace file goes on timeout/crash (default `<tmp>/testing-traces`).
---@field run_dir? string Run directory: a trace below it is reported as `<RUN>/...`.
---@field trace_name? string File name stem of the trace (default `child`).

---@class Testing.Rpc.State
---@field opts Testing.Rpc.Opts
---@field root string
---@field proc Testing.Child.Handle Set by `start` (before the first call).
---@field plan Testing.Child.Plan
---@field wire Testing.Rpc.Wire
---@field trace Testing.Rpc.Trace
---@field notifies table[]
---@field prompts table[]
---@field kill_reason? "kill"|"timeout"|"protocol"
---@field trace_artifact? { kind: string, path: string }
---@field api_params? table<string, string[]>
---@field ui boolean
---@field boot? table
---@field generation integer
---@field async table<integer, fun(message: string)> Asynchronous calls waiting for an answer (failed when the process ends).
---@field stdin_closed? boolean
---@field death_output? string What the child left behind, read when its process ended (the sandbox is removed then).

---Children that are alive (or not yet cleaned up); the editor quitting kills them.
---@type table<Testing.Rpc.State, boolean>
local registry = {}
local leave_hooked = false

---@return table<integer, string>
local function level_names()
  local names = {}
  for name, value in pairs(vim.log.levels) do
    names[value] = name
  end
  return names
end

---Last `n` bytes of a file ("" when it does not exist).
---@param path string
---@param n integer
---@return string
local function file_tail(path, n)
  local f = io.open(path, "rb")
  if not f then
    return ""
  end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - n))
  local text = f:read("*a") or ""
  f:close()
  return text
end

---What the child left behind that explains its end: its stderr (an embedded editor forwards none
---in practice), the reason of a failed start (`rpc_init`) and the tail of its own log.
---@param S Testing.Rpc.State
---@return string
local function stderr_tail(S)
  if not S.proc then
    return ""
  end
  if S.death_output then
    return S.death_output
  end
  local parts = {}
  local text = child_mod.text(S.proc.err)
  if #text > 2000 then
    text = "..." .. text:sub(-2000)
  end
  parts[#parts + 1] = text
  if S.plan then
    parts[#parts + 1] = file_tail(S.plan.sandbox .. "/boot-error.txt", 2000)
    parts[#parts + 1] = file_tail(S.plan.sandbox .. "/nvim.log", 1500)
  end
  local out = {}
  for _, t in ipairs(parts) do
    t = t:gsub("%s+$", "")
    if t ~= "" then
      out[#out + 1] = t
    end
  end
  return table.concat(out, "\n")
end

---Describe a dead child.
---@param S Testing.Rpc.State
---@param during? string The call that was running.
---@return string
local function death_message(S, during)
  local h = S.proc
  local how
  if S.kill_reason == "kill" then
    how = "it was killed by kill()"
  elseif S.kill_reason == "timeout" then
    how = "it was killed after a call timed out"
  elseif S.kill_reason == "protocol" then
    how = "it was killed after an rpc protocol error"
  elseif h and h.exit and (h.exit.code or h.exit.signal) then
    how = "it ended with " .. child_mod.describe_exit(h.exit)
  else
    how = "its process ended"
  end
  local msg = "child died"
  if during then
    msg = msg .. " during " .. during
  end
  msg = msg .. ": " .. how
  local tail = stderr_tail(S)
  if tail ~= "" then
    msg = msg .. "\nchild stderr:\n" .. tail
  end
  return msg
end

---Write the trace file (once per process).
---@param S Testing.Rpc.State
---@param reason string
---@return string|nil path
local function write_trace(S, reason)
  if S.trace_artifact then
    return S.trace_artifact.path
  end
  local dir = S.opts.trace_dir
  if not dir then
    dir = vim.fs.normalize(vim.fs.dirname(vim.fn.tempname())) .. "/testing-traces"
  end
  local pid = S.proc and S.proc.pid or 0
  local path = ("%s/%s-%d-%d.trace.json"):format(
    dir,
    S.opts.trace_name or "child",
    pid,
    S.generation
  )
  local snap = S.trace:snapshot({
    reason = reason,
    child = {
      pid = pid,
      exit = S.proc and S.proc.exit or nil,
      exit_text = S.proc and S.proc.exit and child_mod.describe_exit(S.proc.exit) or nil,
      kill_reason = S.kill_reason,
      argv = S.plan and S.plan.argv or nil,
      bytes_in = S.wire and S.wire.bytes_in or 0,
      bytes_out = S.wire and S.wire.bytes_out or 0,
    },
    stderr = stderr_tail(S),
  })
  local artifact = trace_mod.write(snap, { path = path, root = S.root, run_dir = S.opts.run_dir })
  if artifact then
    S.trace_artifact = artifact
    return artifact.path
  end
  return nil
end

---Kill the process tree and wait until the process is gone (never longer than `REAP_MS`).
---@param S Testing.Rpc.State
---@param reason "kill"|"timeout"|"protocol"
local function kill_process(S, reason)
  local h = S.proc
  if not h then
    return
  end
  if not h.ended then
    S.kill_reason = S.kill_reason or reason
    child_mod.kill_tree(h)
  end
  local t0 = uv.hrtime() / 1e6
  local last = t0
  vim.wait(M.REAP_MS, function()
    local t = uv.hrtime() / 1e6
    if not h.ended and t - last > 1000 then
      last = t
      child_mod.kill_tree(h)
    end
    return h.exited == true
  end, 5)
  if not h.exited then
    child_mod.abandon(h)
  end
end

---@param S Testing.Rpc.State
local function remove_sandbox(S)
  if S.plan and S.plan.sandbox then
    ---@diagnostic disable-next-line: missing-fields
    pcall(child_mod.cleanup, { sandbox = S.plan.sandbox })
  end
end

---Is the process usable (running, pipes open)?
---@param S Testing.Rpc.State
---@return boolean
local function running(S)
  return S.proc ~= nil and not S.proc.ended and not S.proc.exited
end

---`vim.NIL` at the top of a result is `nil` for the caller.
---@param v any
---@return any
local function denil(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---One RPC call.
---@param S Testing.Rpc.State
---@param method string
---@param args any[]
---@param timeout_ms? integer
---@return any
local function call(S, method, args, timeout_ms)
  if not running(S) then
    error(death_message(S, method), 0)
  end
  local tc = S.trace:start(method, args)
  local id, werr = S.wire:request(method, args)
  if not id then
    S.trace:finish(tc, "error", werr)
    error(("testing.rpc: %s"):format(werr), 0)
  end
  local timeout = timeout_ms or S.opts.call_timeout_ms or M.CALL_TIMEOUT_MS
  local proc, wire = S.proc, S.wire
  vim.wait(timeout, function()
    local slot = wire.pending[id]
    return slot == nil or slot.done or proc.exited or wire.broken ~= nil
  end, 1)
  local slot = wire.pending[id]
  if slot and slot.done then
    wire:take(id)
    if slot.ok then
      S.trace:finish(tc, "ok")
      return denil(slot.result)
    end
    local e = slot.err or { message = "unknown error" }
    S.trace:finish(tc, "error", e.message)
    error(("child error in %s: %s"):format(method, e.message), 0)
  end
  wire:forget(id)
  if wire.broken then
    S.trace:finish(tc, "died", "rpc protocol error: " .. wire.broken)
    kill_process(S, "protocol")
    error(
      ("testing.rpc: rpc protocol error: %s\n%s"):format(wire.broken, death_message(S, method)),
      0
    )
  end
  if proc.exited then
    S.trace:finish(tc, "died", "child died")
    local path = write_trace(S, S.kill_reason or "crash")
    local msg = death_message(S, method)
    if path then
      msg = msg .. "\ntrace: " .. path
    end
    error(msg, 0)
  end
  -- timed out
  S.trace:finish(tc, "timeout")
  local killed = S.opts.kill_on_timeout ~= false
  if killed then
    kill_process(S, "timeout")
  end
  local path = write_trace(S, "timeout")
  local msg = ("RPC call %s timed out after %d ms (child pid %d %s)"):format(
    method,
    timeout,
    proc.pid,
    killed and "was killed" or "is still running"
  )
  if path then
    msg = msg .. "\ntrace: " .. path
  end
  error(msg, 0)
end

---One RPC call that does not block: `cb(ok, result_or_message)` runs ONCE on the main loop, when the
---answer arrived or the process ended (whichever is first). There is no timeout of its own: the caller
---supervises its deadline and kills the process (`testing.child.kill_tree`), which ends the call with
---`ok = false` and the death message. Used by the warm pool (`testing.run.pool`), whose supervisor
---must go on while a spec file runs.
---@param S Testing.Rpc.State
---@param method string
---@param args any[]
---@param cb fun(ok: boolean, result: any)
local function request_async(S, method, args, cb)
  if not running(S) then
    vim.schedule(function()
      cb(false, death_message(S, method))
    end)
    return
  end
  local tc = S.trace:start(method, args)
  local finished = false
  local id
  local function finish(ok, result)
    if finished then
      return
    end
    finished = true
    if id then
      S.async[id] = nil
      S.wire.pending[id] = nil
    end
    cb(ok, result)
  end
  local werr
  id, werr = S.wire:request(method, args, function(slot)
    -- libuv callback (fast context): the callback of the caller runs on the main loop
    vim.schedule(function()
      if slot.ok then
        S.trace:finish(tc, "ok")
        finish(true, denil(slot.result))
      else
        local e = slot.err or { message = "unknown error" }
        S.trace:finish(tc, "error", e.message)
        finish(false, ("child error in %s: %s"):format(method, e.message))
      end
    end)
  end)
  if not id then
    S.trace:finish(tc, "error", werr)
    vim.schedule(function()
      finish(false, ("testing.rpc: %s"):format(tostring(werr)))
    end)
    return
  end
  S.async[id] = function(message)
    S.trace:finish(tc, "died", "child died")
    finish(false, message)
  end
end

---@param args table
---@param n integer
---@return any[]
local function pack_args(args, n)
  local out = {}
  for i = 1, n do
    local v = args[i]
    if v == nil then
      v = vim.NIL
    end
    out[i] = v
  end
  return out
end

---Metadata of the API (parameter types), fetched once per child, to turn `{}` into an empty dictionary where nvim wants one.
---@param S Testing.Rpc.State
---@return table<string, string[]>
local function api_params(S)
  if S.api_params then
    return S.api_params
  end
  local info = call(S, "nvim_get_api_info", {})
  local map = {}
  local meta = type(info) == "table" and info[2] or nil
  for _, fn in ipairs(type(meta) == "table" and meta.functions or {}) do
    local types = {}
    for i, p in ipairs(fn.parameters or {}) do
      types[i] = p[1]
    end
    map[fn.name] = types
  end
  S.api_params = map
  return map
end

---@param S Testing.Rpc.State
---@param name string
---@param args any[]
local function coerce_dicts(S, name, args)
  local needs = false
  for _, a in ipairs(args) do
    if type(a) == "table" and next(a) == nil then
      needs = true
    end
  end
  if not needs then
    return
  end
  local types = api_params(S)[name] or {}
  for i, a in ipairs(args) do
    if
      type(a) == "table"
      and next(a) == nil
      and (types[i] == "Dict" or types[i] == "Dictionary")
    then
      args[i] = vim.empty_dict()
    end
  end
end

local BOOT = "require('testing.child.rpc_boot')"

---The `VimLeavePre` reaper exists only while a child does (a spec that drives children must not leave
---an autocmd behind, and an idle editor needs none).
local function hook_leave()
  if leave_hooked then
    return
  end
  leave_hooked = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("TestingRpcReaper", { clear = true }),
    callback = function()
      for S in pairs(registry) do
        if S.proc and not S.proc.ended then
          pcall(child_mod.kill_tree, S.proc)
        end
        remove_sandbox(S)
      end
    end,
  })
end

---@param S Testing.Rpc.State
local function unregister(S)
  registry[S] = nil
  if leave_hooked and next(registry) == nil then
    leave_hooked = false
    pcall(vim.api.nvim_del_augroup_by_name, "TestingRpcReaper")
  end
end

---Start (or restart) the process of `S`.
---@param S Testing.Rpc.State
---@param async_cb? fun(ok: boolean, err: string|nil) Do not wait for the boot request: report to this callback (main loop) instead.
---@return boolean ok
---@return string|nil err
local function start(S, async_cb)
  local opts = S.opts
  S.generation = S.generation + 1
  S.kill_reason, S.trace_artifact, S.api_params, S.ui, S.boot = nil, nil, nil, false, nil
  S.stdin_closed, S.death_output = nil, nil
  S.async = {}
  S.notifies, S.prompts = {}, {}
  S.trace = trace_mod.new()

  local deps = require("testing.deps")
  local self_dir = deps.self_dir()
  local prepend = opts.rtp_prepend
  local extra_env = vim.deepcopy(opts.extra_env or {})
  if not prepend then
    prepend = { self_dir }
    local lib = deps.resolve("lib.nvim", S.root)
    if lib then
      prepend[#prepend + 1] = lib.dir
      extra_env[deps.env_name("lib.nvim")] = extra_env[deps.env_name("lib.nvim")] or lib.dir
    end
    extra_env[deps.env_name("testing.nvim")] = extra_env[deps.env_name("testing.nvim")] or self_dir
  end

  local e = child_mod.environment({
    parent_env = opts.parent_env,
    env_allow = opts.env_allow,
    extra_env = extra_env,
    deterministic = opts.deterministic,
    base = opts.base,
    name = opts.name,
  })
  local mkdirp = require("lib.nvim.fs.mkdirp")
  for _, dir in pairs(e.dirs) do
    local ok, err = mkdirp(dir)
    if not ok then
      return false, ("cannot create %s: %s"):format(dir, tostring(err))
    end
  end
  local job_file = e.sandbox .. "/job.json"
  local text, jerr = require("lib.nvim.json").encode({
    version = 1,
    rtp_prepend = prepend,
    rtp = opts.rtp or {},
    minit = opts.minit,
    disable_first_run = opts.disable_first_run ~= false,
    defer_plugins = opts.defer_plugins == true,
    error_file = e.sandbox .. "/boot-error.txt",
  })
  if not text then
    return false, "cannot encode the job: " .. tostring(jerr)
  end
  local f, oerr = io.open(job_file, "wb")
  if not f then
    return false, ("cannot write %s: %s"):format(job_file, tostring(oerr))
  end
  f:write(text)
  f:close()
  local is_windows = vim.fn.has("win32") == 1
  local function native(s)
    return is_windows and (s:gsub("/", "\\")) or s
  end
  e.env.TESTING_CHILD_JOB = native(job_file)
  -- the editor's own log lives in the sandbox (the default place is below XDG_STATE_HOME as well)
  e.env.NVIM_LOG_FILE = native(e.sandbox .. "/nvim.log")

  local init = vim.fs.normalize(self_dir) .. "/lua/testing/child/rpc_init.lua"
  ---@diagnostic disable-next-line: missing-fields
  local plan = {
    argv = {
      opts.nvim or vim.v.progpath,
      "--embed",
      "--headless",
      "--clean",
      "-n",
      "-i",
      "NONE",
      "-u",
      native(init),
    },
    cwd = native(S.root),
    env = e.env,
    detached = not is_windows,
    sandbox = e.sandbox,
    dirs = e.dirs,
    dropped_env = e.dropped_env,
  } --[[@as Testing.Child.Plan]]
  S.plan = plan

  local levels = level_names()
  local wire
  wire = wire_mod.new({
    write = function(bytes)
      local h = S.proc
      local pipe = h and h.stdin
      if not pipe or pipe:is_closing() then
        return false
      end
      local ok, req = pcall(pipe.write, pipe, bytes, function() end)
      return ok and req ~= nil
    end,
    -- libuv callback (fast context): tables only
    on_notify = function(method, args)
      if method ~= "testing:event" then
        return -- `redraw` of an attached UI and the like
      end
      local kind, payload = args[1], args[2]
      if type(payload) ~= "table" then
        return
      end
      if kind == "notify" then
        local level = tonumber(payload.level) or 2
        local n = { msg = tostring(payload.msg), level = level, level_name = levels[level] or "?" }
        S.notifies[#S.notifies + 1] = n
        if #S.notifies > 500 then
          table.remove(S.notifies, 1)
        end
        S.trace:event("notify", n.msg, n.level_name)
      elseif kind == "prompt" then
        local p = { fn = tostring(payload.fn), text = tostring(payload.text or "") }
        S.prompts[#S.prompts + 1] = p
        if #S.prompts > 200 then
          table.remove(S.prompts, 1)
        end
        S.trace:event("prompt", p.fn .. ": " .. p.text)
      end
    end,
  })
  S.wire = wire

  local proc, serr = child_mod.spawn(plan, function(h)
    -- the process ended (main loop): keep what explains it, then the sandbox and the reaper are not needed
    if h ~= S.proc then
      return
    end
    S.death_output = stderr_tail(S)
    remove_sandbox(S)
    unregister(S)
    -- an asynchronous call that was waiting for an answer that will never come
    local message = death_message(S)
    for _, fail in pairs(vim.deepcopy(S.async, true)) do
      pcall(fail, message)
    end
  end, {
    on_stdout = function(data)
      local ok, err = pcall(wire.feed, wire, data)
      if not ok then
        wire.broken = tostring(err)
      end
    end,
  })
  if not proc then
    remove_sandbox(S)
    return false, serr
  end
  S.proc = proc
  registry[S] = true
  hook_leave()

  -- boot: runtimepath is in order (rpc_init), install the captures
  local boot_args = {
    -- a deferred runtimepath (`defer_plugins`) is put in place before anything is required
    "local r = _G.__testing_final_rtp; if r then vim.o.rtp = r; _G.__testing_final_rtp = nil end; return "
      .. BOOT
      .. ".install(...)",
    {
      {
        prompts = opts.prompts,
        notify_passthrough = opts.notify_passthrough,
        track_schedule = opts.track_schedule,
        guard = opts.guard == nil and { repo = S.root } or opts.guard,
      },
    },
  }
  if async_cb then
    local boot_ms = opts.boot_timeout_ms or M.BOOT_TIMEOUT_MS
    local settled = false
    local gen = S.generation
    local function settle(ok, res)
      if settled then
        return
      end
      settled = true
      if ok then
        S.boot = res
        async_cb(true, nil)
        return
      end
      pcall(child_mod.kill_tree, S.proc)
      kill_process(S, "kill")
      remove_sandbox(S)
      unregister(S)
      async_cb(false, "the child did not start: " .. tostring(res))
    end
    request_async(S, "nvim_exec_lua", boot_args, settle)
    vim.defer_fn(function()
      if not settled and S.generation == gen then
        settle(false, ("no answer within %d ms"):format(boot_ms))
      end
    end, boot_ms)
    return true, nil
  end
  local ok, res =
    pcall(call, S, "nvim_exec_lua", boot_args, opts.boot_timeout_ms or M.BOOT_TIMEOUT_MS)
  if not ok then
    local msg = tostring(res)
    kill_process(S, "kill")
    remove_sandbox(S)
    unregister(S)
    return false, "the child did not start: " .. msg
  end
  S.boot = res
  return true, nil
end

---@param S Testing.Rpc.State
---@param scope string
---@return table
local function scope_proxy(S, scope)
  return setmetatable({}, {
    __index = function(_, key)
      return call(S, "nvim_exec_lua", {
        "local scope, key = ...; return vim[scope][key]",
        { scope, key },
      })
    end,
    __newindex = function(_, key, value)
      if value == nil then
        value = vim.NIL
      end
      call(S, "nvim_exec_lua", {
        "local scope, key, value = ...; if value == vim.NIL then value = nil end; vim[scope][key] = value",
        { scope, key, value },
      })
    end,
  })
end

---@class Testing.Rpc.Child
---@field pid integer
---@field sandbox string Private directory of this child (removed by `kill`).
---@field dirs table<string, string> `config`, `data`, `state`, `cache`, `run`, `tmp`.
---@field call_timeout_ms integer Timeout of one call; may be changed.
---@field api table<string, fun(...): any> `child.api.nvim_*(...)` (the `nvim_` prefix is optional).
---@field fn table<string, fun(...): any> `child.fn.<vimfunction>(...)`.
---@field o table Options (`vim.o`): `child.o.lines`, `child.o.lines = 10`.
---@field bo table Buffer options of the CURRENT buffer.
---@field wo table Window options of the CURRENT window.
---@field g table `vim.g`.
---@field b table `vim.b` of the CURRENT buffer.
---@field w table `vim.w` of the CURRENT window.
---@field t table `vim.t` of the CURRENT tab.
---@field v table `vim.v`.
---@field env table `vim.env` of the child.
---@field request fun(method: string, args?: any[], timeout_ms?: integer): any
---@field lua fun(code: string, ...: any): any
---@field lua_get fun(expr: string, ...: any): any
---@field cmd fun(command: string)
---@field cmd_capture fun(command: string): string
---@field input fun(keys: string): integer
---@field feed fun(keys: string, feed_opts?: { remap?: boolean, typed?: boolean })
---@field mouse fun(button: string, action: string, mods: string, row: integer, col: integer, grid?: integer)
---@field settle fun(timeout_ms?: integer, settle_opts?: { interval_ms?: integer, rounds?: integer, raise?: boolean }): boolean, string|nil
---@field screen fun(): table
---@field notifies fun(nopts?: { clear?: boolean }): table[]
---@field prompts fun(nopts?: { clear?: boolean }): table[]
---@field messages fun(): string[]
---@field guard table<string, fun(...: any): any> Forwards to the guard handle in the child.
---@field effects fun(): table
---@field boot_info fun(): table
---@field rebaseline fun()
---@field alive fun(): boolean
---@field ensure_alive fun(): true
---@field status fun(): table
---@field stderr fun(): string
---@field trace fun(): table
---@field write_trace fun(reason?: string): { kind: string, path: string }|nil
---@field trace_artifact fun(): { kind: string, path: string }|nil
---@field close_stdin fun()
---@field reset fun(): string[]
---@field restart fun(): true
---@field kill fun(): true
---@field exec_async fun(code: string, args: any[], cb: fun(ok: boolean, result: any)) Run Lua code without blocking (see the function).
---@field proc fun(): Testing.Child.Handle The process handle (`testing.child`).
---@field death_text fun(): string What explains the end of the process.

---The state of a child that is about to start.
---@param opts Testing.Rpc.Opts
---@return Testing.Rpc.State
local function new_state(opts)
  ---@diagnostic disable-next-line: missing-fields
  return {
    opts = opts,
    root = vim.fs.normalize(opts.root or vim.fn.getcwd()),
    trace = trace_mod.new(),
    notifies = {},
    prompts = {},
    async = {},
    ui = false,
    generation = 0,
  } --[[@as Testing.Rpc.State]]
end

---The handle a started child is driven through.
---@param S Testing.Rpc.State
---@param opts Testing.Rpc.Opts
---@return Testing.Rpc.Child
local function build_child(S, opts)
  -- a loose table: the members are assigned below (the class above documents them)
  ---@type table<string, any>
  local child = {
    pid = S.proc.pid,
    sandbox = S.plan.sandbox,
    dirs = S.plan.dirs,
    call_timeout_ms = opts.call_timeout_ms or M.CALL_TIMEOUT_MS,
  }

  ---Keep the user-visible timeout field in sync with the state the calls read.
  local function sync()
    S.opts.call_timeout_ms = child.call_timeout_ms
  end

  ---Raw request. `timeout_ms` overrides the default of this call.
  ---@param method string
  ---@param args? any[]
  ---@param timeout_ms? integer
  ---@return any
  function child.request(method, args, timeout_ms)
    sync()
    return call(S, method, args or {}, timeout_ms)
  end

  ---Run Lua code in the child (`nvim_exec_lua`); `...` are the arguments of the chunk (a `nil` arrives as `vim.NIL`).
  ---@param code string
  ---@param ... any
  ---@return any
  function child.lua(code, ...)
    sync()
    return call(S, "nvim_exec_lua", { code, pack_args({ ... }, select("#", ...)) })
  end

  ---Value of a Lua expression in the child: `child.lua_get("vim.fn.line('.')")`.
  ---@param expr string
  ---@param ... any
  ---@return any
  function child.lua_get(expr, ...)
    sync()
    return call(
      S,
      "nvim_exec_lua",
      { "return (" .. expr .. ")", pack_args({ ... }, select("#", ...)) }
    )
  end

  child.api = setmetatable({}, {
    __index = function(_, name)
      local full = name:sub(1, 5) == "nvim_" and name or ("nvim_" .. name)
      return function(...)
        sync()
        local args = pack_args({ ... }, select("#", ...))
        coerce_dicts(S, full, args)
        return call(S, full, args)
      end
    end,
  })
  child.fn = setmetatable({}, {
    __index = function(_, name)
      return function(...)
        sync()
        -- through `vim.fn` (not `nvim_call_function`): the prompt capture replaces `vim.fn.input` & co
        return call(S, "nvim_exec_lua", {
          "local name, args = ...; return vim.fn[name](unpack(args))",
          { name, pack_args({ ... }, select("#", ...)) },
        })
      end
    end,
  })

  ---Ex command(s).
  ---@param command string
  function child.cmd(command)
    sync()
    call(S, "nvim_command", { command })
  end

  ---Ex command with its output.
  ---@param command string
  ---@return string
  function child.cmd_capture(command)
    sync()
    local r = call(S, "nvim_exec2", { command, { output = true } })
    return type(r) == "table" and r.output or ""
  end

  for _, scope in ipairs({ "o", "bo", "wo", "g", "b", "w", "t", "v", "env" }) do
    child[scope] = scope_proxy(S, scope)
  end

  ---Type keys like a user (`nvim_input`): queued, NOT processed when this returns (use `settle`).
  ---@param keys string
  ---@return integer bytes
  function child.input(keys)
    sync()
    return call(S, "nvim_input", { keys })
  end

  ---Run keys to completion (`nvim_feedkeys` with the `x` flag: the typeahead is drained before this
  ---returns). `<Esc>`-style names are translated. Mappings apply (`remap`, default true); the keys are
  ---handled as typed (`t`).
  ---@param keys string
  ---@param feed_opts? { remap?: boolean, typed?: boolean }
  function child.feed(keys, feed_opts)
    sync()
    feed_opts = feed_opts or {}
    local mode = (feed_opts.remap == false and "n" or "m")
      .. (feed_opts.typed == false and "" or "t")
      .. "x"
    local codes = call(S, "nvim_replace_termcodes", { keys, true, false, true })
    call(S, "nvim_feedkeys", { codes, mode, false })
  end

  ---Mouse event (`nvim_input_mouse`). `button`: "left", "right", "middle", "wheel", "move", "x1", "x2";
  ---`action`: "press", "drag", "release", "up", "down", "left", "right"; `mods`: "" or letters "SCAD";
  ---`row`/`col` are 0-based screen cells of `grid` (default 0 = the whole screen).
  ---@param button string
  ---@param action string
  ---@param mods string
  ---@param row integer
  ---@param col integer
  ---@param grid? integer
  function child.mouse(button, action, mods, row, col, grid)
    sync()
    call(S, "nvim_input_mouse", { button, action, mods or "", grid or 0, row, col })
  end

  ---Wait until the editor is idle: nothing typed is waiting, no mode waits for the user, no callback
  ---scheduled with `vim.schedule` is pending and no more libuv handles (timers, jobs, pipes, fs
  ---watchers) are active than at the baseline, in two probes in a row. See
  ---`testing.child.rpc_boot` `settle_state` for the heuristic and what it cannot know.
  ---@param timeout_ms? integer Default 1000.
  ---@param settle_opts? { interval_ms?: integer, rounds?: integer, raise?: boolean }
  ---@return boolean settled
  ---@return string|nil why What was still busy.
  function child.settle(timeout_ms, settle_opts)
    sync()
    settle_opts = settle_opts or {}
    local limit = timeout_ms or 1000
    local rounds = settle_opts.rounds or 2
    local t_end = uv.hrtime() / 1e6 + limit
    local quiet, last = 0, nil
    while true do
      local remaining = math.max(100, t_end - uv.hrtime() / 1e6)
      local busy =
        call(S, "nvim_exec_lua", { "return " .. BOOT .. ".settle_state()", {} }, remaining + 1000)
      if type(busy) == "table" and next(busy) == nil then
        quiet = quiet + 1
      elseif type(busy) == "table" then
        quiet, last = 0, busy
      else
        quiet = quiet + 1 -- an empty table arrives as nil
      end
      if quiet >= rounds then
        return true, nil
      end
      if uv.hrtime() / 1e6 >= t_end then
        local parts = {}
        for key, value in pairs(last or {}) do
          if type(value) == "table" then
            local items = {}
            for k, n in pairs(value) do
              items[#items + 1] = ("%s=%s"):format(k, tostring(n))
            end
            table.sort(items)
            parts[#parts + 1] = key .. " (" .. table.concat(items, ", ") .. ")"
          else
            parts[#parts + 1] = key .. (value == true and "" or (" " .. tostring(value)))
          end
        end
        table.sort(parts)
        local why = ("not idle after %d ms: %s"):format(limit, table.concat(parts, "; "))
        if settle_opts.raise then
          error(why, 0)
        end
        return false, why
      end
      vim.wait(settle_opts.interval_ms or 5)
    end
  end

  ---Text grid of the screen: `{ size, cursor, mode, lines, attrs, text }` (`testing.child.rpc_boot` `screen`).
  ---@return table
  function child.screen()
    sync()
    if not S.ui then
      local size = opts.size or {}
      call(S, "nvim_ui_attach", { size.cols or 80, size.rows or 24, vim.empty_dict() })
      S.ui = true
    end
    return call(S, "nvim_exec_lua", { "return " .. BOOT .. ".screen()", {} })
  end

  ---`vim.notify` calls the child made, oldest first: `{ msg, level, level_name }`. Kept by the parent:
  ---still there when the child died.
  ---@param nopts? { clear?: boolean }
  ---@return table[]
  function child.notifies(nopts)
    local out = vim.deepcopy(S.notifies)
    if nopts and nopts.clear then
      S.notifies = {}
    end
    return out
  end

  ---Prompts the child answered with "cancelled": `{ fn, text }`.
  ---@param nopts? { clear?: boolean }
  ---@return table[]
  function child.prompts(nopts)
    local out = vim.deepcopy(S.prompts)
    if nopts and nopts.clear then
      S.prompts = {}
    end
    return out
  end

  ---The lines of `:messages`.
  ---@return string[]
  function child.messages()
    sync()
    return call(S, "nvim_exec_lua", { "return " .. BOOT .. ".messages()", {} }) or {}
  end

  ---Forward a call to the guard handle that was installed in the child (`testing.guard.install`
  ---returns it): `child.guard.begin_case({ id = ... })`, `child.guard.end_case()`,
  ---`child.guard.collect()`, `child.guard.answer_prompts({ ... })`. Arguments and results must be
  ---plain data. Raises when no guard handle is installed.
  child.guard = setmetatable({}, {
    __index = function(_, method)
      return function(...)
        sync()
        return call(S, "nvim_exec_lua", {
          "return " .. BOOT .. ".guard_call(...)",
          { method, pack_args({ ... }, select("#", ...)) },
        })
      end
    end,
  })

  ---What the guard collected: the ledger `{ spawned, network, fs_outside_tmp }` (empty without a guard).
  ---@return table
  function child.effects()
    sync()
    return call(S, "nvim_exec_lua", { "return " .. BOOT .. ".effects()", {} }) or {}
  end

  ---Boot facts: `{ guard = "absent"|"installed", nvim = "0.12.2", chan }`.
  ---@return table
  function child.boot_info()
    return vim.deepcopy(S.boot or {})
  end

  ---Take the handle baseline again after something long-lived was started on purpose.
  function child.rebaseline()
    sync()
    call(S, "nvim_exec_lua", { BOOT .. ".rebaseline()", {} })
  end

  ---Is the process running? (never raises)
  ---@return boolean
  function child.alive()
    return running(S)
  end

  ---Raise `child died: ...` when the process is gone.
  ---@return true
  function child.ensure_alive()
    if not running(S) then
      local path = write_trace(S, S.kill_reason or "crash")
      local msg = death_message(S)
      if path then
        msg = msg .. "\ntrace: " .. path
      end
      error(msg, 0)
    end
    return true
  end

  ---`{ state, exit?, exit_text?, kill_reason? }`; `state` is "running", "exited" (ended by itself),
  ---"killed" or "crashed" (ended with a signal or a non-zero exit code on its own).
  ---@return table
  function child.status()
    local h = S.proc
    if running(S) then
      return { state = "running" }
    end
    local st = "exited"
    if S.kill_reason then
      st = "killed"
    elseif S.stdin_closed then
      st = "exited" -- an editor whose client went away quits with exit code 1: expected here
    elseif h and h.exit and ((h.exit.signal or 0) ~= 0 or (h.exit.code or 0) ~= 0) then
      st = "crashed"
    end
    return {
      state = st,
      exit = h and h.exit,
      exit_text = h and h.exit and child_mod.describe_exit(h.exit) or nil,
      kill_reason = S.kill_reason,
    }
  end

  ---Tail of the child's stderr.
  ---@return string
  function child.stderr()
    return S.proc and child_mod.text(S.proc.err) or ""
  end

  ---The trace (recent calls, events, stderr) as a table.
  ---@return table
  function child.trace()
    return S.trace:snapshot({
      reason = "snapshot",
      stderr = S.proc and child_mod.text(S.proc.err) or "",
    })
  end

  ---Write the trace file now (it is written by itself on timeout and crash).
  ---@param reason? string
  ---@return { kind: string, path: string }|nil artifact For `case.artifacts`.
  function child.write_trace(reason)
    S.trace_artifact = nil
    write_trace(S, reason or "requested")
    return S.trace_artifact and vim.deepcopy(S.trace_artifact) or nil
  end

  ---The artifact record of the trace file that was written (nil if none).
  ---@return { kind: string, path: string }|nil
  function child.trace_artifact()
    return S.trace_artifact and vim.deepcopy(S.trace_artifact) or nil
  end

  ---Close the child's stdin: an embedded editor quits when its client goes away (no hang).
  function child.close_stdin()
    local pipe = S.proc and S.proc.stdin
    if pipe and not pipe:is_closing() then
      S.stdin_closed = true
      pipe:close()
    end
  end

  ---Warm reset: buffers, windows, tabs, mode, command line, cwd back to the baseline; the
  ---captures are cleared. Returns what is still different (autocmds, global mappings, `vim.g` keys,
  ---handles): empty = clean; otherwise `restart()` is the honest answer.
  ---@return string[] leaks
  function child.reset()
    sync()
    S.notifies, S.prompts = {}, {}
    return call(S, "nvim_exec_lua", { "return " .. BOOT .. ".reset()", {} }) or {}
  end

  ---Kill the child (whole process tree) and start a new one with the same options; the handle stays
  ---the same, `pid`, `sandbox` and `dirs` change.
  ---@return true
  function child.restart()
    kill_process(S, "kill")
    remove_sandbox(S)
    unregister(S)
    local rok, rerr = start(S)
    if not rok then
      error("testing.rpc: restart failed: " .. tostring(rerr), 0)
    end
    child.pid, child.sandbox, child.dirs = S.proc.pid, S.plan.sandbox, S.plan.dirs
    return true
  end

  ---Kill the child and its whole process tree (`taskkill /T /F` on Windows, the process group
  ---elsewhere), wait until it is gone and remove its sandbox. Idempotent.
  function child.kill()
    kill_process(S, "kill")
    remove_sandbox(S)
    unregister(S)
    return true
  end

  ---Run Lua code in the child WITHOUT waiting: `cb(ok, result_or_message)` runs once on the main
  ---loop, when the answer arrived or the process ended. No timeout of its own: whoever calls this
  ---supervises the deadline and kills the process (`testing.child.kill_tree(child.proc())`), which
  ---completes the call with `ok = false` and the death message. `code` and `args` as in `lua`.
  ---@param code string
  ---@param args any[]
  ---@param cb fun(ok: boolean, result: any)
  function child.exec_async(code, args, cb)
    sync()
    request_async(S, "nvim_exec_lua", { code, pack_args(args, #args) }, cb)
  end

  ---The process handle (`testing.child`): what a supervisor needs to kill the tree or read the exit.
  ---@return Testing.Child.Handle
  function child.proc()
    return S.proc
  end

  ---What explains the end of the process (stderr tail, reason of a failed start, log tail).
  ---@return string
  function child.death_text()
    return stderr_tail(S)
  end

  return child --[[@as Testing.Rpc.Child]]
end

---Start a child.
---@param opts? Testing.Rpc.Opts
---@return Testing.Rpc.Child|nil child
---@return string|nil err
function M.spawn(opts)
  opts = vim.deepcopy(opts or {})
  local S = new_state(opts)
  local ok, err = start(S)
  if not ok then
    unregister(S)
    return nil, err
  end
  return build_child(S, opts), nil
end

---Start a child without blocking: `cb(child)` or `cb(nil, err)` runs on the main loop once the
---editor answered its boot request (a parallel pool starts several at once).
---@param opts? Testing.Rpc.Opts
---@param cb fun(child: Testing.Rpc.Child|nil, err: string|nil)
function M.spawn_async(opts, cb)
  opts = vim.deepcopy(opts or {})
  local S = new_state(opts)
  local ok, err = start(S, function(started, serr)
    if not started then
      unregister(S)
      cb(nil, serr)
      return
    end
    cb(build_child(S, opts), nil)
  end)
  if not ok then
    unregister(S)
    vim.schedule(function()
      cb(nil, err)
    end)
  end
end

return M
