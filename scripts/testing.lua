-- scripts/testing.lua -- command-line entry of testing.nvim.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|init|list|doctor] <root> [options]
--
-- Run `... -l scripts/testing.lua --help` for the options. Exit codes: 0 green, 1 failures,
-- 2 usage/config error, 3 infrastructure error.
--
-- A thin entry: puts this checkout on the runtimepath, resolves the hard dependency lib.nvim by
-- `testing.deps` (NEW-40: $LIB_NVIM_DIR, <repo>/.deps/lib.nvim, <repo>/../lib.nvim,
-- stdpath('data')/lazy/lib.nvim) and hands over to `testing.cli`. Without lib.nvim nothing can
-- run: the message names all four places and the exit code is 3.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

---@param msg string
local function die(msg)
  io.stderr:write(msg, "\n")
  os.exit(3)
end

vim.opt.rtp:prepend(repo)

local ok_deps, deps = pcall(require, "testing.deps")
if not ok_deps then
  die("testing: cannot load testing.deps from " .. repo .. ": " .. tostring(deps))
end

local lib, why = deps.resolve("lib.nvim", repo)
if not lib then
  die(why or "testing: lib.nvim was not found")
  return -- not reached (`die` exits); tells the type checker that `lib` is set below
end
local too_old = deps.lib_problem(lib)
if too_old then
  die(too_old)
end
vim.opt.rtp:append(lib.dir)

local ok_cli, cli = pcall(require, "testing.cli")
if not ok_cli then
  die("testing: cannot load testing.cli: " .. tostring(cli))
end

-- `cli.main` never raises; the pcall is the belt to its braces: an internal failure is exit 3, never a
-- raw Lua error with whatever exit code the editor picks.
-- The environment that chooses the reporter (`TESTING_REPORTER`, `TESTING_AGENT`, an agent harness) is read HERE
-- and handed down: the library itself never looks at it, so a spec that calls `cli.main` is not switched by the
-- environment it runs in (testing.report.agent.choose).
local env = {}
for _, name in ipairs({
  "TESTING_REPORTER",
  "TESTING_AGENT",
  "AI_AGENT",
  "CLAUDECODE",
  "TESTING_CACHE_HOME",
}) do
  env[name] = os.getenv(name)
end
local ok_run, code = pcall(cli.main, arg or {}, { env = env, script = this })
if not ok_run then
  die("testing: internal error: " .. tostring(code))
end
os.exit(code)
