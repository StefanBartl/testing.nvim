---@module 'testing.child.boot'
---@brief Runs INSIDE a child editor: reads the job, sets the editor up, runs one spec file, reports.
---@description
--- Started by `testing.child` with a constant command (`-c "lua ...dofile(boot)"` for host `c`, or
--- `-l <this file>` for host `l`); everything variable arrives through the job file named by
--- `$TESTING_CHILD_JOB`, so no user text is ever part of a command line (SEC-34/35). The job is a JSON
--- table written by the parent:
---
---   kind        "cases" (a dialect runs the file, one record per case), "script" (the file is a
---               self-running script: it is `dofile`d, its own `os.exit` or error is the verdict) or
---               "list" (the describe bodies run and the case ids are written as ONE `list` record:
---               what `isolated = "case"` needs, in a throwaway editor and not in the runner's)
---   entry       the discovered file (`path`, `rel`, `dialect`, `harness`, ...)
---   root        project root (also the working directory)
---   rtp_prepend / rtp   directories for the runtimepath (this checkout and lib.nvim first)
---   filetype    run `filetype plugin indent on` (what plenary's minimal init does)
---   assertions  "error" | "warn": what a case without assertions is (`testing.policy`)
---   disable_first_run  set `vim.g.lib_nvim_deps_disable_first_run` before the minit (default true)
---   minit       absolute path of the project's minimal init, `dofile`d before the spec
---   fragment    where the result records go (`testing.child.fragment`)
---   selector    { filter, tags, exclude_tags }, lf_ids (list|nil), timeouts { case_ms, file_ms }
---   script_args arguments of a `script` (`arg[1..]`)
---   guard       configuration of the guard layer (`testing.guard`), installed for the file by
---               `testing.child.runner`; absent = no guards
---   trace       the parent writes a trace artifact when this child times out or dies (informational)
---
--- Interactive prompts cannot be answered in a child (stdin is closed): `input`, `inputlist`,
--- `inputdialog`, `inputsecret` and `confirm` answer with "cancelled" and the case that was running
--- gets a note, so a spec that asks a question (lua_ls offers an `inputlist`) fails or goes on
--- deterministically instead of hanging or ending the editor.
---
--- Exit codes: 0 the file ran and the records are written (a red case is still 0: the verdict is the
--- IR); 3 the job or the driver itself failed; for a script: its own code, 1 on an uncaught error.

local real_exit = os.exit

---@param code integer
---@param msg string|nil
local function finish(code, msg)
  if msg then
    io.stderr:write("testing child: ", msg, "\n")
  end
  io.stdout:flush()
  io.stderr:flush()
  real_exit(code)
end

local job_path = vim.env.TESTING_CHILD_JOB
if type(job_path) ~= "string" or job_path == "" then
  finish(3, "$TESTING_CHILD_JOB is not set")
end
local jf = io.open(job_path --[[@as string]], "rb")
if not jf then
  finish(3, "cannot read the job file " .. tostring(job_path))
  return
end
local job_text = jf:read("*a")
jf:close()
local jok, job = pcall(vim.json.decode, job_text, { luanil = { object = true, array = true } })
if not jok or type(job) ~= "table" then
  finish(3, "the job file is not valid JSON: " .. tostring(job))
end

-- the spec must not see how it was started (lib.nvim audits the environment)
pcall(vim.fn.setenv, "TESTING_CHILD_JOB", vim.NIL)
pcall(vim.fn.setenv, "TESTING_CHILD_BOOT", vim.NIL)

for _, dir in ipairs(job.rtp_prepend or {}) do
  vim.opt.rtp:prepend(dir)
end
for _, dir in ipairs(job.rtp or {}) do
  vim.opt.rtp:append(dir)
end

-- prompts: cancelled, counted
---@type string[]
local prompts = {}
for name, answer in pairs({
  input = "",
  inputdialog = "",
  inputsecret = "",
  inputlist = 0,
  confirm = 0,
}) do
  vim.fn[name] = function()
    prompts[#prompts + 1] = name
    return answer
  end
end

if job.filetype ~= false then
  vim.cmd("filetype plugin indent on")
else
  -- `-u NORC` enables it by default; the project asked for the bare editor
  vim.cmd("filetype plugin indent off")
end

-- test-environment default: lib.nvim's one-time "missing tools" float must not open inside a spec
-- (a fresh sandbox cache is always "first run"); set before the minit, unless the job turned it off
if job.disable_first_run ~= false and vim.g.lib_nvim_deps_disable_first_run == nil then
  vim.g.lib_nvim_deps_disable_first_run = true
end

-- surface tracking (`surface.track = true`): the layer goes in BEFORE the minit, which may call the plugin's
-- `setup()`; it follows the runner's case windows and the cases carry `surface.hit` (docs/SURFACE.md)
if type(job.guard) == "table" and type(job.guard.surface) == "table" then
  local tok, track = pcall(require, "testing.surface.track")
  if tok then
    local hok, herr = pcall(track.hook_runner, job.guard.surface)
    if not hok then
      io.stderr:write("testing child: surface tracking failed to install: ", tostring(herr), "\n")
    end
  else
    io.stderr:write("testing child: surface tracking is not available: ", tostring(track), "\n")
  end
end

-- the project's own minimal init, as plenary's `-u minimal_init` would have run it
if type(job.minit) == "string" then
  local mok, merr = pcall(dofile, job.minit)
  if not mok then
    finish(3, ("minit %s failed: %s"):format(job.minit, tostring(merr)))
  end
end

local entry = job.entry or {}

if job.kind == "script" then
  _G.arg = { [0] = entry.path }
  for i, a in ipairs(job.script_args or {}) do
    _G.arg[i] = a
  end
  local ok, err = xpcall(dofile, debug.traceback, entry.path)
  if not ok then
    -- the very shape `nvim -l` prints for an uncaught error (testing.dialect.script reads it)
    io.stderr:write("E5113: Error while calling lua chunk: ", tostring(err), "\n")
    finish(1)
  end
  finish(0)
end

-- kind == "list" (the cases of a file for `isolated = "case"`) or "cases"
local okm, runner = pcall(require, "testing.child.runner")
if not okm then
  finish(3, "cannot load testing.child.runner: " .. tostring(runner))
  return
end

local ran
if job.kind == "list" then
  ran = runner.list(job)
else
  ran = runner.run(job, { prompts = prompts })
end
if not ran.ok then
  finish(3, ran.err)
end
finish(0)
