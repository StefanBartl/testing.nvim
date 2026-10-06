---@brief The `-u` file of an RPC child (`testing.rpc`): puts the runtimepath in order, then runs the project's minimal init.
---@description
--- A CONSTANT command line starts `nvim --embed --headless --clean -n -i NONE -u <this file>`; the
--- variable parts arrive in the JSON job file named by `$TESTING_CHILD_JOB` (SEC-34/35: no user text
--- is ever part of a command line). The job:
---
---   rtp_prepend / rtp   directories for the runtimepath (`rtp_prepend`: the first entry wins)
---   disable_first_run   set lib.nvim's one-time "missing tools" float opt-out before the minit
---   minit               absolute path of the project's minimal init, `dofile`d here
---   error_file          where the reason of a failed start is written (stderr does not reach the parent)
---
--- `--clean` alone would leave a project's `-u TESTS/minimal_init.lua` without the checkout on the
--- runtimepath; the minit of this repo and of the fleet expects to find `testing`/`lib.nvim` through
--- `$TESTING_NVIM_DIR`/`$LIB_NVIM_DIR` or its own `rtp:prepend`, both of which work from here.
--- A failing minit ends the child with exit code 3 (an embedded editor would otherwise go on with a
--- half-configured state and the failure would surface much later as a puzzling RPC error).

local error_file

---An embedded editor does not forward its stderr to the parent (measured: nothing arrives on
---either Windows or Linux), so the reason of a failed start goes to a file the parent reads.
local function die(msg)
  io.stderr:write("testing child: ", msg, "\n")
  io.stderr:flush()
  if error_file then
    local f = io.open(error_file, "wb")
    if f then
      f:write("testing child: ", msg, "\n")
      f:close()
    end
  end
  os.exit(3)
end

local job_path = vim.env.TESTING_CHILD_JOB
if type(job_path) ~= "string" or job_path == "" then
  die("$TESTING_CHILD_JOB is not set")
end
local f = io.open(job_path --[[@as string]], "rb")
if not f then
  die("cannot read the job file " .. tostring(job_path))
  return
end
local text = f:read("*a")
f:close()
local ok, job = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
if not ok or type(job) ~= "table" then
  die("the job file is not valid JSON: " .. tostring(job))
  return
end
pcall(vim.fn.setenv, "TESTING_CHILD_JOB", vim.NIL)
error_file = type(job.error_file) == "string" and job.error_file or nil

-- DEFERRED PLUGINS (`job.defer_plugins`, the warm pool): the runtimepath the project's minit builds must
-- not be the one the editor sources `plugin/` files from after this file. A per-file child (started
-- with `-c`, like plenary's host) never has the project on the runtimepath while the editor loads its
-- plugins; a pool member must behave the same, or the project's own `plugin/*.lua` would run at start
-- (defining commands, autocmds and globals a spec expects NOT to exist before its own `setup()`).
-- So the runtimepath is built here (the minit needs it), then put back, and `testing.rpc` applies the
-- built one with its first request (`_G.__testing_final_rtp`), when the editor is up.
local rtp_before = vim.o.rtp

-- the FIRST entry of `rtp_prepend` ends up first on the runtimepath (the list is read from its end)
local prepend = job.rtp_prepend or {}
for i = #prepend, 1, -1 do
  vim.opt.rtp:prepend(prepend[i])
end
for _, dir in ipairs(job.rtp or {}) do
  vim.opt.rtp:append(dir)
end

if job.disable_first_run ~= false and vim.g.lib_nvim_deps_disable_first_run == nil then
  vim.g.lib_nvim_deps_disable_first_run = true
end

if type(job.minit) == "string" and job.minit ~= "" then
  local mok, merr = pcall(dofile, job.minit)
  if not mok then
    die(("minit %s failed: %s"):format(job.minit, tostring(merr)))
  end
end

if job.defer_plugins then
  _G.__testing_final_rtp = vim.o.rtp
  vim.o.rtp = rtp_before
end
