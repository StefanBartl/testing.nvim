---@module 'testing.dialect.script'
---@brief Dialect `script`: a self-running spec file (`nvim -l TESTS/x.lua`) judged by its exit code and its output.
---@description
--- Some specs are not run by a framework at all: pickers.nvim, cmdlog.nvim and filetree.nvim ship
--- scripts that keep their own counters, print `ok ...` / `FAIL ...` lines, print a summary and end
--- with `os.exit(failed == 0 and 0 or 1)`. Such a file cannot run in the driver's process (it would
--- end it), so discovery classifies it `script` and the child driver runs it in its OWN process, as
--- CI does. This module turns what that process produced into a case of the IR. It runs nothing and
--- touches no process: the driver hands in `{ code, stdout, stderr, timed_out, crashed }`.
---
--- The verdict follows the same rule as everywhere else, "never greener than the project":
---
---   timeout      the driver killed it                                   -> `timeout`
---   crash        a signal/native crash (exit 139, 0xC0000005, `crashed`) -> `crash`
---   exit != 0    failure lines (`[FAIL]`, `FAIL ...`, `not ok`) become failed assertions; without
---                any, stderr with a Lua error is an `error`, else one failed assertion "exit code N"
---   exit == 0    still `fail` when the output holds failure lines or a summary `... N failed` with
---                N > 0 (a script that forgot its `os.exit`), else `pass`: a summary
---                `N passed, 0 failed` is N passed assertions (recorded as one), no summary at all is
---                the single assertion "exit code 0"; a summary of 0 passed is "no assertions" and
---                follows the assertion policy (and the skip convention, `testing.policy`)
---
--- Pure Lua apart from the assertion context it is given.

local conventions = require("testing.dialect.harness_conventions")
local policy = require("testing.policy")

local M = {}

---Exit codes that mean the process died of a native fault (segfault, access violation, abort).
---@type table<integer, true>
M.CRASH_CODES = {
  [134] = true, -- SIGABRT
  [139] = true, -- SIGSEGV
  [-1073741819] = true, -- 0xC0000005 access violation, as a signed 32-bit code
  [3221225477] = true, -- the same, unsigned
}

---Longest message kept per failed assertion.
M.MAX_MSG = 300

---Most failure lines recorded individually.
M.MAX_FAILURES = 200

---@class Testing.Script.Run
---@field code? integer Exit code (nil when the process was killed).
---@field stdout? string
---@field stderr? string
---@field timed_out? boolean The driver killed the process on the file deadline.
---@field crashed? boolean The driver saw a native crash (signal).
---@field timeout_ms? integer For the message.

---@class Testing.Script.Summary
---@field passed? integer
---@field failed? integer
---@field skipped? integer

---Parse the last `N passed, M failed[, K skipped]` summary of the output (the form of the fleet's
---scripts; `"1001 passed"`, `"494 passed, 0 failed"`, `"... 380 passed, 0 failed, 1 skipped"`).
---@param text string
---@return Testing.Script.Summary summary Empty when no such line exists.
function M.parse_summary(text)
  local summary = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local passed = line:match("(%d+)%s+passed")
    if passed then
      summary = { passed = tonumber(passed) }
      summary.failed = tonumber(line:match("(%d+)%s+failed") or "")
      summary.skipped = tonumber(line:match("(%d+)%s+skipped") or "")
    end
  end
  return summary
end

---The failure lines of the output, trimmed, in order.
---@param text string
---@return string[] lines
function M.failure_lines(text)
  local is_fail = conventions.resolve({}, "").fail_line
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if is_fail(line) and #out < M.MAX_FAILURES then
      out[#out + 1] = (line:gsub("^%s+", ""):gsub("%s+$", "")):sub(1, M.MAX_MSG)
    end
  end
  return out
end

---@param text string
---@return string[]
local function lines_of(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    out[#out + 1] = line
  end
  return out
end

---The first line of stderr that reads like a Lua/Neovim error.
---@param stderr string
---@return string|nil
local function lua_error_line(stderr)
  for line in (stderr .. "\n"):gmatch("(.-)\r?\n") do
    if
      line:find("E5113", 1, true)
      or line:find("stack traceback", 1, true)
      or line:find("^lua:")
    then
      return line:sub(1, M.MAX_MSG)
    end
  end
  return nil
end

---Build the finished case of one script run.
---@param a Testing.Assert.Context
---@param rel string Project-relative path of the script.
---@param run Testing.Script.Run
---@param opts? { assertions?: "error"|"warn", on_case?: fun(case: Testing.Result.Case) }
---@return Testing.Result.Case case
function M.build_case(a, rel, run, opts)
  local stdout, stderr = run.stdout or "", run.stderr or ""
  local all = stdout .. "\n" .. stderr
  local code = run.code
  a.begin_case({ file = rel, name = vim.fs.basename(rel) })
  local case = a.current() --[[@as Testing.Result.Case]]
  local summary = M.parse_summary(all)
  local fails = M.failure_lines(all)

  ---@param status Testing.Status
  ---@param message string
  local function terminal(status, message)
    case.status = status
    case.error = { message = message, traceback = message }
  end

  if run.timed_out then
    terminal(
      "timeout",
      ("the script exceeded the file timeout%s and was killed: %s"):format(
        run.timeout_ms and (" of " .. run.timeout_ms .. " ms") or "",
        rel
      )
    )
  elseif run.crashed or (code and M.CRASH_CODES[code]) then
    terminal(
      "crash",
      ("the script's process crashed (exit code %s): %s"):format(tostring(code), rel)
    )
  elseif code == nil then
    terminal("error", ("the script's process has no exit code: %s"):format(rel))
  else
    for _, line in ipairs(fails) do
      case.assertions[#case.assertions + 1] = { ok = false, kind = "script", msg = line }
    end
    if code ~= 0 and #fails == 0 then
      local err = lua_error_line(stderr)
      if err then
        terminal("error", err)
      else
        case.assertions[#case.assertions + 1] = {
          ok = false,
          kind = "exit",
          msg = ("exit code %d%s"):format(
            code,
            stderr ~= "" and (": " .. (lines_of(stderr)[1] or ""):sub(1, M.MAX_MSG)) or ""
          ),
        }
      end
    elseif code ~= 0 then
      case.notes[#case.notes + 1] = ("exit code %d"):format(code)
    end
    if case.status == "pass" then
      if (summary.failed or 0) > 0 and #fails == 0 then
        case.assertions[#case.assertions + 1] = {
          ok = false,
          kind = "script",
          msg = ("the script's summary says %d failed (exit code %d)"):format(summary.failed, code),
        }
      end
      if #fails == 0 and (summary.failed or 0) == 0 then
        if summary.passed ~= nil then
          if summary.passed > 0 then
            case.assertions[#case.assertions + 1] = {
              ok = true,
              kind = "script",
              msg = ("%d checks passed (script summary)"):format(summary.passed),
            }
          end
        elseif code == 0 then
          case.assertions[#case.assertions + 1] = { ok = true, kind = "exit", msg = "exit code 0" }
        end
      end
      if summary.skipped and summary.skipped > 0 then
        case.notes[#case.notes + 1] = ("the script skipped %d check(s)"):format(summary.skipped)
      end
    end
  end
  local done = a.end_case()
  policy.apply(done, { assertions = opts and opts.assertions, printed = lines_of(stdout) })
  if opts and opts.on_case then
    opts.on_case(done)
  end
  return done
end

return M
