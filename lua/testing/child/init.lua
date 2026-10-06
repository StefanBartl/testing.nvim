---@module 'testing.child'
---@brief Driver of ONE child editor that runs ONE spec file: argv, sandbox, environment, start, hard kill.
---@description
--- `testing.child` is the process half of per-file isolation (concept D.3 / D.9, `host = "c"|"l"`).
--- The pool that runs many children and merges what they report is `testing.run.isolated`; the code
--- that runs inside the child is `testing.child.boot`.
---
--- WHAT A CHILD IS
---   nvim -n -i NONE --headless -u NORC -c "lua ...dofile(boot)"      host "c" (the default)
---   nvim -n -i NONE --headless -u NORC -l <boot.lua>                 host "l"
---
---   `-u NORC`: no init file, but the editor's own runtime plugins load (netrw, matchit, ...) as
---   they do under plenary's `-u minimal_init` and under `--clean`; `-u NONE` would leave a spec
---   that calls `:Explore` or relies on `filetype plugin indent on` alone with a different editor.
---
---   * started with an argv LIST by `vim.uv.spawn` (never a shell string: SEC-01) and an explicit working
---     directory, the project root (SEC-02). `lib.nvim.system.job` has no `cwd`/`env`/`kill` options,
---     and `vim.system` only completes when the pipes reach end-of-file (an orphan of the spec can
---     hold them for ever), so this is the one place that talks to libuv directly: the child is done
---     when its PROCESS ended plus a short drain (`DRAIN_MS`);
---   * host `c` starts the way plenary's `PlenaryBustedFile` host does: the spec runs from a `-c`
---     command, so `v:vim_did_enter` is 0, `expand('<cword>')` and `expand('<cfile>')` work and a
---     buffer context exists. Host `l` is `nvim -l` (`vim_did_enter` is 1, no buffer context). The
---     command line is CONSTANT: the variable parts travel in `$TESTING_CHILD_JOB` (a JSON file) and
---     `$TESTING_CHILD_BOOT`, so no user text is ever parsed as a command;
---   * stdin is the null device: a spec that asks a question never blocks the run (`boot` also
---     answers `input()`/`inputlist()`/`confirm()` with "cancelled");
---   * the environment is an allowlist (`testing.child.env`) plus the sandbox: `XDG_*` and the temp
---     variables point into one directory below the parent's temp dir, so `stdpath('data'|'state'|
---     'cache'|'config')` and `tempname()` of a spec never touch the user's real ones. The sandbox
---     is deleted when the child is done;
---   * the run's dependencies are on the child's runtimepath (`rtp`, `rtp_prepend` of the job).
---
--- KILLING. A timeout kills the whole process TREE: a spec that spawned helpers (language servers,
--- `nvim --headless` workers) must not leave them behind. Windows: `taskkill /PID <pid> /T /F` (an argv
--- call; killing the root first would hide the tree from `/T`). POSIX: the child is started
--- detached (own process group) and the group gets SIGKILL. If the OS call fails the root is killed
--- directly. A parent that is itself killed cannot clean up after itself (documented limit).
--- A grandchild a spec left behind AFTER the child ended normally is killed on POSIX (the process
--- group outlives its leader); on Windows it is not (no job objects from Lua; documented limit), but
--- it can no longer delay the run or turn a green file into a timeout. A process that is still there
--- `REAP_MS` after the kill is abandoned (`abandon`): reported as ended, never waited for again.

local env_mod = require("testing.child.env")

local M = {}

local is_windows = vim.fn.has("win32") == 1

---Directory of this checkout's boot file.
---@return string
function M.boot_path()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.normalize(here)) .. "/boot.lua"
end

---Constant `-c` command of host `c`: runs the boot file named by `$TESTING_CHILD_BOOT`; a raise
---before the boot's own error handling ends the child with exit code 4 instead of leaving the editor
---waiting for input.
---@type string
M.HOST_C_COMMAND =
  "lua local ok, e = pcall(dofile, vim.env.TESTING_CHILD_BOOT); if not ok then io.stderr:write('testing child: ' .. tostring(e) .. '\\n'); os.exit(4) end"

---@class Testing.Child.Timeouts
---@field case_ms? integer
---@field file_ms? integer

---@class Testing.Child.Spec
---@field entry table The discovered file (`path`, `rel`, `dialect`, ...); serialized into the job.
---@field root string Project root: the working directory and the base of `entry.rel`.
---@field kind? "cases"|"script" Default "cases".
---@field host? "c"|"l" Default "c".
---@field rtp_prepend? string[] Directories put first on the child's runtimepath.
---@field rtp? string[] Directories appended to the child's runtimepath.
---@field filetype? boolean `filetype plugin indent on` (default true).
---@field disable_first_run? boolean Set lib.nvim's first-run opt-out in the child before `minit` (default true).
---@field minit? string Absolute path of the project's minimal init, run in the child before the spec.
---@field assertions? "error"|"warn" What a case without assertions is (`testing.policy`).
---@field selector? { filter?: string[], tags?: string[], exclude_tags?: string[] }
---@field lf_ids? string[] `--lf`: the only case ids of this file that may run.
---@field timeouts? Testing.Child.Timeouts Soft (in-child) timeouts.
---@field seed? integer
---@field script_args? string[]
---@field env_allow? string[] Extra environment names (see `testing.child.env`).
---@field extra_env? table<string, string> Variables the driver sets itself (the `$<NAME>_DIR` of the resolved dependencies: a spec that starts an editor of its own finds them too).
---@field parent_env? table<string, string> Replaces `vim.fn.environ()` (specs).
---@field nvim? string Executable (default `vim.v.progpath`).
---@field base? string Directory below which the sandbox is created (default: the parent's temp dir).
---@field name? string Sandbox directory name (default unique).

---@class Testing.Child.Plan
---@field argv string[]
---@field cwd string
---@field env table<string, string>
---@field dropped_env string[] Names of the parent environment that were not passed on.
---@field sandbox string Absolute directory that holds everything of this child.
---@field dirs table<string, string> Sandbox sub-directories (`config`, `data`, `state`, `cache`, `run`, `tmp`).
---@field job_file string
---@field fragment string
---@field job table The job table (what `job_file` will contain).
---@field host "c"|"l"
---@field detached boolean POSIX: started as a process-group leader (killed as a group).

local seq = 0

---@param s string
---@return string
local function native(s)
  if is_windows then
    return (s:gsub("/", "\\"))
  end
  return s
end

---Parent's temp directory: the dirname of `tempname()`. It is the parent's own (and is removed with
---it); the IR's `<TMP>` placeholder is that same directory, so sandbox paths in a message are
---normalized like any other temp path.
---@return string
local function parent_tmp()
  return (vim.fs.normalize(vim.fs.dirname(vim.fn.tempname())):gsub("/+$", ""))
end

---Build the plan of a child. Pure apart from reading the environment and a counter: nothing is
---created and nothing is started, so a spec can inspect the argv, the environment and the job.
---@param spec Testing.Child.Spec
---@return Testing.Child.Plan
function M.build(spec)
  local host = spec.host or "c"
  assert(host == "c" or host == "l", "testing.child: host must be 'c' or 'l'")
  seq = seq + 1
  local base = spec.base or parent_tmp()
  local name = spec.name or ("testing-child-%d-%d"):format(vim.fn.getpid(), seq)
  local sandbox = (base:gsub("\\", "/"):gsub("/+$", "")) .. "/" .. name
  local dirs, sandbox_vars = env_mod.sandbox_env(sandbox)

  local clean = env_mod.sanitize(spec.parent_env or vim.fn.environ(), { allow = spec.env_allow })
  local env = clean.env
  -- the sandbox variables replace whatever case the parent spelled them in (`Temp` vs `TEMP`)
  for key, value in pairs(sandbox_vars) do
    for existing in pairs(env) do
      if existing:upper() == key then
        env[existing] = nil
      end
    end
    env[key] = native(value)
  end

  for key, value in pairs(spec.extra_env or {}) do
    env[key] = native(value)
  end

  local job_file = sandbox .. "/job.json"
  local fragment = sandbox .. "/result.ndjson"
  local boot = M.boot_path()
  env.TESTING_CHILD_JOB = native(job_file)
  local argv = { spec.nvim or vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NORC" }
  if host == "c" then
    env.TESTING_CHILD_BOOT = native(boot)
    vim.list_extend(argv, { "-c", M.HOST_C_COMMAND })
  else
    vim.list_extend(argv, { "-l", native(boot) })
  end

  local job = {
    version = 1,
    kind = spec.kind or "cases",
    entry = spec.entry,
    root = spec.root,
    rtp_prepend = spec.rtp_prepend or {},
    rtp = spec.rtp or {},
    filetype = spec.filetype ~= false,
    minit = spec.minit,
    disable_first_run = spec.disable_first_run ~= false,
    assertions = spec.assertions,
    fragment = fragment,
    selector = spec.selector or {},
    lf_ids = spec.lf_ids,
    timeouts = spec.timeouts or {},
    seed = spec.seed,
    script_args = spec.script_args,
  }
  return {
    argv = argv,
    cwd = native(spec.root),
    env = env,
    dropped_env = clean.dropped,
    sandbox = sandbox,
    dirs = dirs,
    job_file = job_file,
    fragment = fragment,
    job = job,
    host = host,
    detached = not is_windows,
  }
end

---Create the sandbox directories and write the job file.
---@param plan Testing.Child.Plan
---@return boolean ok
---@return string|nil err
function M.prepare(plan)
  local mkdirp = require("lib.nvim.fs.mkdirp")
  for _, dir in pairs(plan.dirs) do
    local ok, err = mkdirp(dir)
    if not ok then
      return false, ("cannot create %s: %s"):format(dir, tostring(err))
    end
  end
  local text, err = require("lib.nvim.json").encode(plan.job)
  if not text then
    return false, "cannot encode the job: " .. tostring(err)
  end
  local f, oerr = io.open(plan.job_file, "wb")
  if not f then
    return false, ("cannot write %s: %s"):format(plan.job_file, tostring(oerr))
  end
  f:write(text)
  f:close()
  return true, nil
end

---Remove the sandbox of a child. Refuses anything that is not a `testing-child-*` directory
---directly below the parent's temp dir or the `base` it was built with.
---@param plan Testing.Child.Plan
---@return boolean removed
function M.cleanup(plan)
  local name = plan.sandbox:match("([^/]+)$") or ""
  if not name:match("^testing%-child%-") then
    return false
  end
  if vim.fn.isdirectory(plan.sandbox) ~= 1 then
    return true
  end
  return vim.fn.delete(plan.sandbox, "rf") == 0
end

---@class Testing.Child.Buffer
---@field chunks string[]
---@field bytes integer
---@field truncated boolean Older output was dropped (the cap).

---@class Testing.Child.Handle
---@field plan Testing.Child.Plan
---@field uv_handle? uv.uv_process_t The process handle (nil once closed).
---@field pid integer
---@field started_ms number Monotonic clock at the start.
---@field exited boolean The child is finished (process ended and drained, or abandoned).
---@field ended? boolean The process itself ended (the pipes may still be drained).
---@field abandoned? boolean The process did not end after the kill; the pool stopped waiting.
---@field finish? fun() Internal: completes the handle once.
---@field exit? { code?: integer, signal?: integer } Set when the process ended (`{}` when abandoned).
---@field kill_requested_ms? number
---@field first_kill_ms? number Monotonic ms of the FIRST kill request (the pool's upper bound counts from it).
---@field reason? "file"|"stall"|"cancel" Why the pool killed it (set by the supervisor).
---@field deadline? number Monotonic ms of the hard file deadline.
---@field stall_limit? number ms without a new record that count as a stuck case (busted).
---@field progress_ms? number Monotonic ms of the last new record.
---@field frag_size? integer Size of the fragment at `progress_ms`.
---@field out Testing.Child.Buffer Everything the child printed (stdout and stderr, arrival order).
---@field stdout Testing.Child.Buffer What it wrote to stdout.
---@field err Testing.Child.Buffer What it wrote to stderr.

---Cap of the captured output per stream and child (bytes); the newest output is kept.
M.OUTPUT_CAP = 256 * 1024

---@return Testing.Child.Buffer
local function new_buffer()
  return { chunks = {}, bytes = 0, truncated = false }
end

---@param buf Testing.Child.Buffer
---@param chunk string
local function keep(buf, chunk)
  buf.chunks[#buf.chunks + 1] = chunk
  buf.bytes = buf.bytes + #chunk
  while buf.bytes > M.OUTPUT_CAP and #buf.chunks > 1 do
    buf.bytes = buf.bytes - #table.remove(buf.chunks, 1)
    buf.truncated = true
  end
end

---The captured text of a buffer (CRLF folded to LF).
---@param buf Testing.Child.Buffer
---@return string
function M.text(buf)
  return (table.concat(buf.chunks):gsub("\r\n", "\n"))
end

---Children that are running, by pid; the editor quitting kills what is left (`VimLeavePre`).
---@type table<integer, Testing.Child.Handle>
local live = {}
local leave_hooked = false

---Kill the process trees of all children that are still running.
function M.kill_all()
  for _, h in pairs(live) do
    M.kill_tree(h)
  end
end

local function hook_leave()
  if leave_hooked then
    return
  end
  leave_hooked = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("TestingChildReaper", { clear = true }),
    callback = function()
      M.kill_all()
    end,
  })
end

---How long after the PROCESS ended the pipes are still read (ms). A spec that left a grandchild
---behind (a language server, a `start /b` helper) leaves it holding the inherited ends of the pipes:
---waiting for end-of-file would wait for that orphan, not for the child.
M.DRAIN_MS = 200

---Start a prepared child. The child is finished when its PROCESS has exited (plus a short drain of
---what is still in the pipes), never when the pipes reach end-of-file (`vim.system` waits for that,
---which an orphan can delay for ever).
---@param plan Testing.Child.Plan
---@param on_exit fun(h: Testing.Child.Handle) Called ON THE MAIN LOOP (scheduled) when the process ended.
---@return Testing.Child.Handle|nil handle
---@return string|nil err
function M.spawn(plan, on_exit)
  local uv = vim.uv
  ---@diagnostic disable-next-line: missing-fields
  local h = {
    plan = plan,
    pid = 0,
    started_ms = uv.hrtime() / 1e6,
    exited = false,
    out = new_buffer(),
    stdout = new_buffer(),
    err = new_buffer(),
  } --[[@as Testing.Child.Handle]]

  local out_pipe, err_pipe = uv.new_pipe(false), uv.new_pipe(false)
  if not out_pipe or not err_pipe then
    if out_pipe then
      out_pipe:close()
    end
    if err_pipe then
      err_pipe:close()
    end
    return nil, "cannot create the pipes of the child"
  end
  local env = {}
  for name, value in pairs(plan.env) do
    env[#env + 1] = name .. "=" .. value
  end
  table.sort(env)
  local args = vim.list_slice(plan.argv, 2)

  local finished = false
  local timer
  local eof = 0
  local function close(handle)
    if handle and not handle:is_closing() then
      handle:close()
    end
  end
  ---Runs once: the pipes are closed (the orphan's writes now fail, they do not block it), the handle
  ---is `exited` and the owner is told on the main loop.
  local function finish()
    if finished then
      return
    end
    finished = true
    close(timer)
    close(out_pipe)
    close(err_pipe)
    h.exited = true
    if h.ended then
      live[h.pid] = nil
    end
    vim.schedule(function()
      on_exit(h)
    end)
  end
  h.finish = finish

  local handle, pid = uv.spawn(plan.argv[1], {
    args = args,
    cwd = plan.cwd,
    env = env,
    stdio = { nil, out_pipe, err_pipe },
    detached = plan.detached,
    hide = true,
  }, function(code, signal)
    h.ended = true
    h.exit = { code = code, signal = signal }
    live[h.pid] = nil
    close(h.uv_handle)
    if not is_windows then
      -- what the child left in its process group (the group outlives its leader)
      pcall(uv.kill, -h.pid, "sigkill")
    end
    if eof >= 2 then
      finish()
      return
    end
    timer = uv.new_timer()
    if timer then
      timer:start(M.DRAIN_MS, 0, finish)
    else
      finish()
    end
  end)
  if not handle then
    close(out_pipe)
    close(err_pipe)
    return nil, ("cannot start %s: %s"):format(tostring(plan.argv[1]), tostring(pid))
  end
  h.uv_handle = handle
  h.pid = pid
  live[h.pid] = h
  hook_leave()

  ---@param pipe uv.uv_pipe_t
  ---@param sinks Testing.Child.Buffer[]
  local function read(pipe, sinks)
    pipe:read_start(function(_, data)
      if data then
        for _, sink in ipairs(sinks) do
          keep(sink, data)
        end
      else
        eof = eof + 1
        if not pipe:is_closing() then
          pipe:read_stop()
        end
        if h.ended and eof >= 2 then
          finish() -- everything the child wrote has arrived: no need to wait out the drain
        end
      end
    end)
  end
  read(out_pipe, { h.out, h.stdout })
  read(err_pipe, { h.err, h.out })
  return h, nil
end

---Give up on a child whose process did not end after the kill: it is reported as ended (its exit
---is unknown) so that one stubborn process can never keep a run waiting.
---@param h Testing.Child.Handle
function M.abandon(h)
  if h.exited then
    return
  end
  h.abandoned = true
  h.exit = h.exit or {}
  if h.finish then
    h.finish()
  else
    h.exited = true
  end
end

---Kill the process tree of a child (see the module header). Idempotent; never raises.
---@param h Testing.Child.Handle
function M.kill_tree(h)
  if h.ended then
    return -- the process is gone (an abandoned one is not: it can still be killed when the editor quits)
  end
  local first = h.kill_requested_ms == nil
  h.kill_requested_ms = h.kill_requested_ms or (vim.uv.hrtime() / 1e6)
  local function root_kill()
    if h.uv_handle and not h.uv_handle:is_closing() then
      pcall(vim.uv.process_kill, h.uv_handle, 9)
    end
  end
  if is_windows then
    if first then
      local ok = pcall(
        vim.system,
        { "taskkill", "/PID", tostring(h.pid), "/T", "/F" },
        { text = true },
        function() end
      )
      if ok then
        return
      end
    end
    root_kill()
  else
    if not pcall(vim.uv.kill, -h.pid, "sigkill") then
      root_kill()
    end
    root_kill()
  end
end

---Does a process exist? (`kill(pid, 0)`: no signal is sent.)
---@param pid integer
---@return boolean
function M.alive(pid)
  local r, _, name = vim.uv.kill(pid, 0)
  return r == 0 or name == "EPERM"
end

---Names of signals worth naming in a crash message.
local SIGNALS = {
  [1] = "SIGHUP",
  [2] = "SIGINT",
  [3] = "SIGQUIT",
  [4] = "SIGILL",
  [6] = "SIGABRT",
  [7] = "SIGBUS",
  [8] = "SIGFPE",
  [9] = "SIGKILL",
  [11] = "SIGSEGV",
  [13] = "SIGPIPE",
  [15] = "SIGTERM",
}

---Describe how a process ended, for a crash message.
---@param exit { code?: integer, signal?: integer }
---@return string
function M.describe_exit(exit)
  local parts = { ("exit code %d"):format(exit.code or -1) }
  if exit.signal and exit.signal ~= 0 then
    parts[#parts + 1] = ("signal %d (%s)"):format(exit.signal, SIGNALS[exit.signal] or "?")
  elseif exit.code and exit.code >= 128 and exit.code < 160 and not is_windows then
    parts[#parts + 1] = ("= 128 + signal %d (%s)"):format(
      exit.code - 128,
      SIGNALS[exit.code - 128] or "?"
    )
  elseif exit.code and exit.code >= 0xC0000000 then
    parts[#parts + 1] = ("= NTSTATUS 0x%08X"):format(exit.code)
  end
  return table.concat(parts, ", ")
end

return M
