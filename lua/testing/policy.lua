---@module 'testing.policy'
---@brief What a case WITHOUT assertions means: an error, a warning, or a skip.
---@description
--- Problem P4 of the old runners: a case that asserts nothing proves nothing. `testing.core.result`
--- finishes such a case as `fail` with one synthetic assertion of kind `no_assertions`. The fleet
--- shows two honest ways out of that verdict, and this module is where they live (pure functions, the
--- driver and the dialects call them; nothing here knows a dialect):
---
---   1. The SKIP convention. A spec that cannot run its checks here (git missing, an optional sibling
---      plugin not checked out) prints a line starting with `skip` and returns without asserting:
---      `print("skip  git_spec.lua: git not usable")`. Such a case is `skip`, never green (and red
---      under `--strict`), instead of "case made no assertions". Only a case with NO assertion at all
---      and a skip line qualifies: a spec that asserts before it skips keeps its verdict, and a case
---      that fails or raises is never turned into a skip.
---
---   2. The `assertions` policy of `.testing.lua`:
---        "error"  (default) a case without assertions is a failure (P4);
---        "warn"   a case without assertions is a PASS that carries a warning: the case keeps one
---                 passing synthetic assertion (kind `no_assertions`, so the IR stays valid) and the
---                 note `warning: case made no assertions`; the run lists it in its findings. The
---                 migration config of an existing repository sets it, because plenary and the old
---                 runners let such cases pass (12 cases of the fleet only "do not throw" or return
---                 early) while a fresh project should keep "error".
---
--- `apply` works on a FINISHED case (the kernel has computed its status). `capture` collects what
--- `print`, `io.write` and the stdout/stderr writers produced while a case ran: the skip line and
--- the failure lines of a project's own harness come from there.
---
--- No editor API except the output functions `capture` hooks.

local M = {}

---Message of the passing synthetic assertion of policy `warn`.
---@type string
M.WARN_MSG = 'case made no assertions (allowed: assertions = "warn")'

---Most lines and bytes per line a capture keeps.
M.MAX_LINES = 2000
M.MAX_LINE_BYTES = 300

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Is `line` a skip notice? It starts (after blanks and an optional `[`) with `skip`, `skipped` or
---`skipping`, in any letter case, and the word ends there (`skipper` is not one).
---@param line any
---@return boolean
function M.is_skip_line(line)
  if type(line) ~= "string" then
    return false
  end
  local word = trim(line):lower():match("^%[?(%a+)")
  return word == "skip" or word == "skipped" or word == "skipping"
end

---The first skip line of `lines`, trimmed and shortened, or nil.
---@param lines? string[]
---@return string|nil reason
function M.skip_reason(lines)
  for _, line in ipairs(lines or {}) do
    if M.is_skip_line(line) then
      return trim(line):sub(1, M.MAX_LINE_BYTES)
    end
  end
  return nil
end

---@class Testing.Policy.Opts
---@field assertions? "error"|"warn" Policy of a case without assertions (default `error`).
---@field printed? string[] Lines the case printed (see `M.capture`); only the skip convention reads them.

---Does the case consist of nothing but the synthetic `no_assertions` failure of the kernel?
---@param case Testing.Result.Case
---@return boolean
local function only_no_assertions(case)
  return case.status == "fail"
    and case.error == nil
    and #case.assertions == 1
    and case.assertions[1].kind == "no_assertions"
    and case.assertions[1].ok == false
end

---Apply the policy to a finished case, in place.
---@param case Testing.Result.Case
---@param opts? Testing.Policy.Opts
---@return Testing.Result.Case case The same table.
---@return "skip"|"warn"|nil changed What was done; nil when the case was left alone.
function M.apply(case, opts)
  opts = opts or {}
  if not only_no_assertions(case) then
    return case, nil
  end
  local reason = M.skip_reason(opts.printed)
  if reason then
    case.assertions = {}
    case.status = "skip"
    case.reason = reason
    case.notes[#case.notes + 1] = "skip convention: no assertions and a printed skip line: "
      .. reason
    return case, "skip"
  end
  if opts.assertions == "warn" then
    case.assertions[1] = { ok = true, kind = "no_assertions", msg = M.WARN_MSG }
    case.status = "pass"
    case.notes[#case.notes + 1] = "warning: case made no assertions"
    return case, "warn"
  end
  return case, nil
end

---@class Testing.Policy.Capture
---@field lines string[] Everything printed since `capture()` (capped), whole lines only until `flush`.
---@field flush fun() Turn a trailing partial line (written without its newline) into a line.
---@field stop fun(): string[] Restore the hooks and return the lines.

---Collect what a case writes until `stop()`: `print`, `io.write`, `io.stdout:write`, `io.stderr:write`
---and `vim.api.nvim_out_write` / `nvim_err_write` (a project harness prints its `FAIL` lines with
---whichever it likes). The text still reaches the original function. Text without a newline is held
---until the line ends (`io.write("FAIL x")` then `io.write("\n")` is ONE line). Captures nest (stop
---the inner one first); a `stop` that finds another function installed leaves it alone.
---@return Testing.Policy.Capture
function M.capture()
  local lines = {}
  local pending = ""
  local function add_line(line)
    if #lines < M.MAX_LINES then
      lines[#lines + 1] = line:sub(1, M.MAX_LINE_BYTES)
    end
  end
  ---@param text string
  local function feed(text)
    pending = pending .. text
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      add_line((pending:sub(1, nl - 1):gsub("\r$", "")))
      pending = pending:sub(nl + 1)
    end
    if #pending > 4 * M.MAX_LINE_BYTES then
      add_line(pending)
      pending = ""
    end
  end

  local original_print = print
  local function capturing_print(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    feed(table.concat(parts, "\t") .. "\n")
    return original_print(...)
  end
  _G.print = capturing_print

  ---@type { restore: fun() }[]
  local hooks = {}
  ---Replace `tbl[key]` by a function that feeds `text_of(...)` first; undone by `stop`.
  ---@param tbl table|nil
  ---@param key string
  ---@param text_of fun(...): string|nil
  local function hook(tbl, key, text_of)
    if type(tbl) ~= "table" then
      return
    end
    local original = rawget(tbl, key)
    if type(original) ~= "function" then
      return
    end
    local function hooked(...)
      local ok, text = pcall(text_of, ...)
      if ok and text then
        feed(text)
      end
      return original(...)
    end
    tbl[key] = hooked
    hooks[#hooks + 1] = {
      restore = function()
        if rawget(tbl, key) == hooked then
          tbl[key] = original
        end
      end,
    }
  end
  ---@param ... any
  ---@return string
  local function joined(...)
    local parts = {}
    for i = 1, select("#", ...) do
      local v = (select(i, ...))
      if type(v) == "string" or type(v) == "number" then
        parts[#parts + 1] = tostring(v)
      end
    end
    return table.concat(parts)
  end
  hook(io, "write", joined)
  local file_methods = (getmetatable(io.stdout) or {}).__index
  if type(file_methods) == "table" then
    -- the shared file methods: only the process' own stdout / stderr count, a spec's own files do not
    hook(file_methods, "write", function(self, ...)
      if self == io.stdout or self == io.stderr then
        return joined(...)
      end
    end)
  end
  if vim and vim.api then
    hook(vim.api, "nvim_out_write", joined)
    hook(vim.api, "nvim_err_write", joined)
  end

  local stopped = false
  local function flush()
    if pending ~= "" then
      add_line(pending)
      pending = ""
    end
  end
  return {
    lines = lines,
    flush = flush,
    stop = function()
      if not stopped then
        stopped = true
        flush()
        if _G.print == capturing_print then
          _G.print = original_print
        end
        for i = #hooks, 1, -1 do
          hooks[i].restore()
        end
      end
      return lines
    end,
  }
end

---Run one case under the policy: `print` is captured while `run` executes, then `apply` is called on
---the finished case it returned. The dialects wrap their `a.run_case(...)` in this.
---@param opts? { assertions?: "error"|"warn" }
---@param run fun(capture: Testing.Policy.Capture): Testing.Result.Case Runs the case and returns it finished.
---@return Testing.Result.Case case
function M.guard(opts, run)
  local capture = M.capture()
  local ok, case = pcall(run, capture)
  local printed = capture.stop()
  if not ok then
    error(case, 0)
  end
  M.apply(case, { assertions = opts and opts.assertions, printed = printed })
  return case
end

return M
