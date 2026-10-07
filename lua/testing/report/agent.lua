---@module 'testing.report.agent'
---@brief Compact reporter for coding agents: the verdict first, then only what is red, fewest tokens possible.
---@description
--- Pure like every reporter: `render(result, opts)` returns the lines, it reads the Result-IR and nothing
--- else (and the facts the caller passes as options), it never prints.
---
--- Shape (`--reporter agent`):
---
---   RED | 3 fail, 1 error, 412 pass | 380 from cache, 32 ran, 0 skipped on purpose | 4.1 s | exit 1
---   last green run: 2026-10-07 12:00:03Z at 3f2a1b9; 2 file(s) changed since: lua/a.lua, TESTS/a_spec.lua
---   FAIL TESTS/cfg_spec.lua:42  cfg::parses nested keys
---     values differ
---     at line 3 of 7:
---        c = 2,
---     - expected: c = 2,
---     + actual:   c = 3,
---     rerun: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . --file TESTS/cfg_spec.lua --filter "parses nested keys"
---   FAIL x40 module 'lib.nvim.foo' not found  (first: TESTS/a_spec.lua  a::b; 39 more: --json <file>)
---   GUARD TESTS/b_spec.lua  [state] leaves autocmd BufEnter in group G
---   more: 12 failure group(s) (30 case(s)) not shown (budget 4000 chars); all of them: --json <file> or --agent-budget <n>
---
--- * The FIRST line is the verdict (`GREEN`, `PARTIAL`, `RED`), computed from the whole run before anything
---   is cut: a shortened report can never read as green. A `PARTIAL` run names its reasons on the second line.
--- * Only failures: a green file, a passing case and the output of a green spec do not appear. Paths are
---   relative to the project root.
--- * Failures with the same status, message and top frame are ONE entry with a counter; the first case is
---   shown, the rest is in the `--json` file.
--- * A character budget (`budget`, `--agent-budget`) bounds the failure part. An entry that does not fit in
---   full is tried in short form (head line and rerun command); what still does not fit is counted in the
---   `more:` line, never dropped silently.
--- * The order is the order of the IR (file order, the same for any `--jobs`).
--- * `format = "jsonl"`: the same data, one JSON object per line (`verdict`, `failure`, `guard`, `omitted`).
---
--- Everything that came from the code under test (case names, messages, values, paths) passes
--- `testing.report.util.clean` with C1 and bidi escaping, is cut to one line, and a line that would start with
--- `::` (a GitHub workflow command) is written with `\x3A:` so that no runner executes it.

local util = require("testing.report.util")
local verdict_mod = require("testing.report.verdict")

local M = {}

---@class Testing.Report.AgentOpts
---@field budget? integer Characters of the failure part (default `DEFAULTS.budget`).
---@field format? "text"|"jsonl"
---@field command? string The command a `rerun:` line starts with (default `DEFAULTS.command`).
---@field line_max? integer Longest value / message line in characters (default 160).

---@type { budget: integer, format: "text"|"jsonl", command: string, line_max: integer }
M.DEFAULTS = {
  budget = 4000,
  format = "text",
  command = "nvim -n -i NONE --headless -u NONE -l scripts/testing.lua",
  line_max = 160,
}

---Reserved for the `more:` line when something has to be left out.
local TRAILER = 200

local LABEL = {
  fail = "FAIL",
  error = "ERROR",
  timeout = "TIMEOUT",
  crash = "CRASH",
  xpass = "XPASS",
}

---@param s string
---@return string
local function guard_command(s)
  -- a workflow command must not survive at the start of a line, whatever indentation a reader adds later
  return (s:gsub("^(%s*)::", "%1\\x3A:"))
end

---One printable line: control characters, C1 and bidi escaped, whitespace collapsed, at most `max` characters.
---@param s any
---@param max integer
---@return string
local function oneline(s, max)
  s = util.clean(tostring(s), { c1 = true, bidi = true })
  s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s > max then
    s = util.cap(s, max - 3) .. "..."
  end
  return s
end

---A path relative to the project root with forward slashes (a path that is not below it stays).
---@param root any
---@param p any
---@return string
local function relpath(root, p)
  p = tostring(p or ""):gsub("\\", "/")
  if type(root) == "string" and root ~= "" then
    local r = root:gsub("\\", "/"):gsub("/+$", "")
    if r ~= "" and r ~= "<REPO>" and p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
      p = p:sub(#r + 2)
    end
  end
  return (p:gsub("^%./", ""):gsub("^<REPO>/", ""))
end

---The first line of a text.
---@param s any
---@return string
local function first_line(s)
  return tostring(s or ""):match("^[^\r\n]*") or ""
end

---Take the project root off every path of a text: a message that names `<root>/TESTS/x.lua:3:` reads
---`TESTS/x.lua:3:` (an absolute path is tokens and says nothing the root does not).
---@param root any
---@param s string
---@return string
local function strip_root(root, s)
  if type(root) ~= "string" or root == "" or root == "<REPO>" then
    return s
  end
  local prefix = (root:gsub("\\", "/"):gsub("/+$", "")) .. "/"
  local low, want = s:gsub("\\", "/"):lower(), prefix:lower()
  local out, pos = {}, 1
  while true do
    local i, j = low:find(want, pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = j + 1
  end
  return table.concat(out)
end

---Is `path:line` a place of the project (relative after `strip_root`), not of the runner or a library?
---@param loc string
---@return boolean
local function in_project(loc)
  local p = loc:gsub("\\", "/")
  return not (p:match("^%a:/") or p:match("^/") or p:match("^%.%.%."))
end

---Lua shortens a long chunk name to `...` and its last characters; when that tail is the end of the case's own
---file (or the file the end of the tail) the position is that file.
---@param loc string `path:line`
---@param file any The case's file.
---@return string loc
---@return boolean resolved
local function resolve_short(loc, file)
  local path, line = loc:match("^(.-):(%d+)$")
  if not path or path:sub(1, 3) ~= "..." or type(file) ~= "string" or file == "" then
    return loc, false
  end
  local tail, f = path:sub(4):gsub("\\", "/"), file:gsub("\\", "/")
  local same
  if #tail >= #f then
    same = tail:sub(-#f) == f
  else
    same = f:sub(-#tail) == tail
  end
  if same then
    return f .. ":" .. line, true
  end
  return loc, false
end

---Where an error happened: the position its message starts with, else the first frame of its traceback that
---lies in the project, else the first frame (`path:line`); nil when there is none.
---@param root any
---@param message string
---@param trace any
---@param file any The case's file (resolves a position Lua shortened).
---@return string|nil
local function error_location(root, message, trace, file)
  local at = strip_root(root, message):match("^([^%s:][^%s]-:%d+):")
  if at then
    local loc, resolved = resolve_short(at, file)
    if resolved or in_project(loc) then
      return loc
    end
  end
  if type(trace) ~= "string" then
    return nil
  end
  local first
  local after = strip_root(root, trace:match("stack traceback:%s*(.*)$") or trace)
  for frame in after:gmatch("([^%s:][^%s]-:%d+):") do
    local loc, resolved = resolve_short(frame, file)
    first = first or loc
    if resolved or in_project(loc) then
      return loc
    end
  end
  return first
end

---@class Testing.Report.AgentGroup
---@field status string
---@field message string
---@field where string `path:line` of the first case.
---@field count integer
---@field case Testing.Result.Case The first case of the group.
---@field assertion? Testing.Result.Assertion Its first failed assertion.
---@field more_assertions integer Further failed assertions of that case.
---@field key string

---Group the red cases by status, message and top frame, in first-seen order.
---@param result Testing.Result
---@param o table
---@return Testing.Report.AgentGroup[] groups
---@return integer cases Red cases altogether.
local function failure_groups(result, o)
  local root = result.run and result.run.root
  local groups, by_key, cases = {}, {}, 0
  for _, c in ipairs(result.cases or {}) do
    if util.class_of(c.status) == "bad" then
      cases = cases + 1
      local failed = {}
      for _, a in ipairs(c.assertions or {}) do
        if a.ok == false then
          failed[#failed + 1] = a
        end
      end
      local a = failed[1]
      local message, where, about
      if
        a
        and (c.status == "fail" or c.status == "xpass" or c.status == "error")
        and not c.error
      then
        about = a
        message = a.msg or a.kind or "failed"
        local file = a.file or c.file
        local line = a.line or c.line
        where = relpath(root, file) .. (line and (":" .. line) or "")
      elseif c.status == "xpass" then
        message = "unexpectedly passed (expected failure)"
        where = relpath(root, c.file) .. (c.line and (":" .. c.line) or "")
      else
        message = c.error and c.error.message or c.status
        local frame = c.error and error_location(root, tostring(message), c.error.traceback, c.file)
        where = frame and relpath(root, frame)
          or (relpath(root, c.file) .. (c.line and (":" .. c.line) or ""))
      end
      message = oneline(strip_root(root, first_line(message)), o.line_max)
      where = oneline(where, o.line_max)
      local key = c.status .. "\0" .. message .. "\0" .. where
      local g = by_key[key]
      if g then
        g.count = g.count + 1
      else
        g = {
          status = c.status,
          message = message,
          where = where,
          count = 1,
          case = c,
          assertion = about,
          more_assertions = about and math.max(0, #failed - 1) or 0,
          key = key,
        }
        by_key[key] = g
        groups[#groups + 1] = g
      end
    end
  end
  return groups, cases
end

---The value part of a failed assertion: one line each, or, for multi-line values, the first line that differs
---with one line of context before it.
---@param a Testing.Result.Assertion
---@param o table
---@return string[] lines Without indentation.
local function value_lines(a, o)
  local exp, act = a.expected, a.actual
  if exp == nil and act == nil then
    return {}
  end
  if
    (exp == "truthy" and (act == "false" or act == "nil")) or (exp == "falsy" and act == "true")
  then
    return {} -- a plain `ok(cond)`: the message says what was meant, these two words say nothing
  end
  local multi = (exp and exp:find("[\r\n]")) or (act and act:find("[\r\n]"))
  if not multi then
    local out = {}
    if exp ~= nil then
      out[#out + 1] = "expected: " .. oneline(exp, o.line_max)
    end
    if act ~= nil then
      out[#out + 1] = "actual: " .. oneline(act, o.line_max)
    end
    return out
  end
  local ea, aa = util.split_lines(exp or ""), util.split_lines(act or "")
  local at = 1
  while at <= #ea and at <= #aa and ea[at] == aa[at] do
    at = at + 1
  end
  local out = { ("differs at line %d of %d/%d:"):format(at, #ea, #aa) }
  if at > 1 then
    out[#out + 1] = "   " .. oneline(ea[at - 1], o.line_max)
  end
  out[#out + 1] = "- " .. oneline(ea[at] or "(missing)", o.line_max)
  out[#out + 1] = "+ " .. oneline(aa[at] or "(missing)", o.line_max)
  return out
end

---@param s string
---@return string
local function quote(s)
  if s ~= "" and not s:find("[^%w_%.%-/:=,@+%%]") then
    return s
  end
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---The command that repeats one failed case: the arguments of the run without what selects or shows
---(`args.repeat_argv`), then `--file` and, for a case inside a file, `--filter`.
---@param result Testing.Result
---@param c Testing.Result.Case
---@param o table
---@return string
local function rerun_command(result, c, o)
  local argv = (result.run and result.run.argv) or {}
  local parts = { o.command }
  for _, a in ipairs(require("testing.args").repeat_argv(argv)) do
    parts[#parts + 1] = quote(oneline(a, 200))
  end
  parts[#parts + 1] = "--file " .. quote(oneline(c.file or "", 200))
  local name = util.short_name(c)
  local own = name ~= "" and name ~= (c.file or ""):match("([^/]+)$")
  if own and not name:find('[\r\n"\\$`]') then
    parts[#parts + 1] = "--filter " .. quote(oneline(name, 200))
  end
  return table.concat(parts, " ")
end

---@param result Testing.Result
---@return table<string, integer> counts
---@return integer cached_cases
local function count_cases(result)
  local counts, cached = {}, 0
  for _, c in ipairs(result.cases or {}) do
    counts[c.status] = (counts[c.status] or 0) + 1
    if c.cached then
      cached = cached + 1
    end
  end
  return counts, cached
end

---The verdict line: kind, case counts, file counts, duration, exit code.
---@param result Testing.Result
---@param v Testing.Verdict
---@return string
local function verdict_line(result, v)
  local counts = count_cases(result)
  local bad, rest = {}, {}
  for _, status in ipairs(require("testing.core.result").STATUSES) do
    local n = counts[status] or 0
    if n > 0 or status == "pass" then
      local text = ("%d %s"):format(n, status)
      if util.class_of(status) == "bad" then
        bad[#bad + 1] = text
      else
        rest[#rest + 1] = text
      end
    end
  end
  local cases = table.concat(vim.list_extend(bad, rest), ", ")
  local run = result.run or {}
  local kind = v.kind == "green" and "GREEN" or v.kind == "green-partial" and "PARTIAL" or "RED"
  return ("%s | %s | %s | %s s | exit %d"):format(
    kind,
    cases,
    verdict_mod.counts(v),
    ("%.1f"):format((run.duration_ms or 0) / 1000):gsub(",", "."),
    v.exit_code or 0
  )
end

---@class Testing.Report.AgentGuard
---@field text string
---@field count integer Findings of this file and guard.
---@field file string
---@field guard string
---@field severity string
---@field messages string[] The distinct messages, at most `MAX_GUARD_MESSAGES`.
---@field more integer Distinct messages that are not listed.

---Distinct messages one GUARD line names (a file that leaks twenty things is one line, not twenty).
local MAX_GUARD_MESSAGES = 3

---One GUARD line per file and guard: the findings are grouped, the message loses the `spec <case id> ` prefix
---(the file is on the line already) and names at most `MAX_GUARD_MESSAGES` distinct things.
---@param result Testing.Result
---@param o table
---@return Testing.Report.AgentGuard[]
local function guard_entries(result, o)
  local root = result.run and result.run.root
  local out, by_key = {}, {}
  for _, f in ipairs(util.guard_findings(result)) do
    if f.severity == "warn" or f.severity == "error" then
      local file = relpath(root, f.case.file)
      local text = tostring(f.message)
      local prefix = "spec " .. tostring(f.case.id) .. " "
      if text:sub(1, #prefix) == prefix then
        text = text:sub(#prefix + 1)
      end
      local msg = oneline(strip_root(root, text), o.line_max)
      local key = file .. "\0" .. f.guard .. "\0" .. f.severity
      local e = by_key[key]
      if not e then
        e = {
          text = "",
          count = 0,
          file = oneline(file, o.line_max),
          guard = oneline(f.guard, 40),
          severity = f.severity,
          messages = {},
          more = 0,
          seen = {},
        }
        by_key[key] = e
        out[#out + 1] = e
      end
      e.count = e.count + 1
      if not e.seen[msg] then
        e.seen[msg] = true
        if #e.messages < MAX_GUARD_MESSAGES then
          e.messages[#e.messages + 1] = msg
        else
          e.more = e.more + 1
        end
      end
    end
  end
  for _, e in ipairs(out) do
    e.seen = nil
    e.text = ("GUARD%s %s  [%s%s] %s%s"):format(
      e.count > 1 and (" x" .. e.count) or "",
      e.file,
      e.guard,
      e.severity == "warn" and " warn" or "",
      table.concat(e.messages, "; "),
      e.more > 0 and ("; +%d more"):format(e.more) or ""
    )
  end
  return out
end

---The text entry of a failure group: full (`short = false`) or head and rerun only.
---@param g Testing.Report.AgentGroup
---@param result Testing.Result
---@param o table
---@param short boolean
---@return string[]
local function text_entry(g, result, o, short)
  local label = LABEL[g.status] or g.status:upper()
  local lines = {}
  local name = oneline(util.short_name(g.case), o.line_max)
  if g.count > 1 then
    lines[1] = ("%s x%d %s  (first: %s  %s; %d more: --json <file>)"):format(
      label,
      g.count,
      g.message,
      g.where,
      name,
      g.count - 1
    )
  else
    lines[1] = ("%s %s  %s"):format(label, g.where, name)
    lines[#lines + 1] = "  " .. g.message
  end
  if not short then
    if g.assertion then
      for _, l in ipairs(value_lines(g.assertion, o)) do
        lines[#lines + 1] = "  " .. l
      end
      if
        g.assertion.diff
        and g.assertion.diff ~= ""
        and not (g.assertion.expected or g.assertion.actual)
      then
        lines[#lines + 1] = "  diff: " .. oneline(g.assertion.diff, o.line_max)
      end
    end
    if g.more_assertions > 0 then
      lines[#lines + 1] = ("  (+%d more failed assertion(s) in this case)"):format(
        g.more_assertions
      )
    end
  end
  lines[#lines + 1] = "  rerun: " .. rerun_command(result, g.case, o)
  for i, l in ipairs(lines) do
    lines[i] = guard_command(l)
  end
  return lines
end

---@param lines string[]
---@return integer
local function size_of(lines)
  local n = 0
  for _, l in ipairs(lines) do
    n = n + #l + 1
  end
  return n
end

---@param result Testing.Result
---@param v Testing.Verdict
---@param groups Testing.Report.AgentGroup[]
---@param guards table[]
---@param o table
---@return string[]
local function render_text(result, v, groups, guards, o)
  local lines = { guard_command(verdict_line(result, v)) }
  if v.kind == "green-partial" then
    lines[#lines + 1] =
      guard_command("partial: " .. table.concat(v.reasons or {}, "; ") .. "; no sentinel")
  end
  for _, l in ipairs(verdict_mod.red_lines(v)) do
    lines[#lines + 1] = guard_command(oneline(l, 400))
  end
  local used = size_of(lines)
  local budget = o.budget - TRAILER
  local left_groups, left_cases, left_guards = 0, 0, 0
  for _, g in ipairs(groups) do
    local entry = text_entry(g, result, o, false)
    if used + size_of(entry) > budget then
      entry = text_entry(g, result, o, true)
    end
    if used + size_of(entry) <= budget then
      vim.list_extend(lines, entry)
      used = used + size_of(entry)
    else
      left_groups = left_groups + 1
      left_cases = left_cases + g.count
    end
  end
  for _, e in ipairs(guards) do
    local text = guard_command(e.text)
    if used + #text + 1 <= budget then
      lines[#lines + 1] = text
      used = used + #text + 1
    else
      left_guards = left_guards + 1
    end
  end
  if left_groups > 0 or left_guards > 0 then
    local what = {}
    if left_groups > 0 then
      what[#what + 1] = ("%d failure group(s) (%d case(s))"):format(left_groups, left_cases)
    end
    if left_guards > 0 then
      what[#what + 1] = ("%d guard finding(s)"):format(left_guards)
    end
    lines[#lines + 1] = ("more: %s not shown (budget %d chars); all of them: --json <file> or --agent-budget <n>"):format(
      table.concat(what, " and "),
      o.budget
    )
  end
  return lines
end

---@param t table
---@return string
local function json_line(t)
  local text = require("lib.nvim.json").encode(t)
  return guard_command(text or "{}")
end

---@param result Testing.Result
---@param v Testing.Verdict
---@param groups Testing.Report.AgentGroup[]
---@param guards table[]
---@param o table
---@return string[]
local function render_jsonl(result, v, groups, guards, o)
  local run = result.run or {}
  local head = {
    kind = "verdict",
    verdict = v.kind,
    exit_code = v.exit_code or 0,
    duration_ms = run.duration_ms or 0,
    files = v.files,
    cases = v.cases,
    status = count_cases(result),
    reasons = v.reasons,
    last_green = v.last_green,
    changed_since = v.changed_since,
  }
  local lines = { json_line(head) }
  local used = size_of(lines)
  local budget = o.budget - TRAILER
  local left_groups, left_cases, left_guards = 0, 0, 0
  for _, g in ipairs(groups) do
    local a = g.assertion
    local entry = json_line({
      kind = "failure",
      status = g.status,
      count = g.count,
      where = g.where,
      case = oneline(util.short_name(g.case), o.line_max),
      message = g.message,
      expected = a and a.expected and oneline(a.expected, o.line_max) or nil,
      actual = a and a.actual and oneline(a.actual, o.line_max) or nil,
      rerun = rerun_command(result, g.case, o),
    })
    if used + #entry + 1 <= budget then
      lines[#lines + 1] = entry
      used = used + #entry + 1
    else
      left_groups = left_groups + 1
      left_cases = left_cases + g.count
    end
  end
  for _, e in ipairs(guards) do
    local entry = json_line({
      kind = "guard",
      count = e.count,
      file = e.file,
      guard = e.guard,
      severity = e.severity,
      messages = e.messages,
      more_messages = e.more > 0 and e.more or nil,
    })
    if used + #entry + 1 <= budget then
      lines[#lines + 1] = entry
      used = used + #entry + 1
    else
      left_guards = left_guards + 1
    end
  end
  if left_groups > 0 or left_guards > 0 then
    lines[#lines + 1] = json_line({
      kind = "omitted",
      groups = left_groups,
      cases = left_cases,
      guards = left_guards,
      budget = o.budget,
    })
  end
  return lines
end

-- =========================================================
-- Which reporter a run uses
-- =========================================================

---Environment variables that say "a coding agent runs this". OBSERVED, not documented: `CLAUDECODE=1` and
---`AI_AGENT=<agent name>` are set in the shell of a Claude Code session (checked on 2026-10-07 in such a
---session; the agent harness sets them, no vendor page promises them). Other agents set other variables and
---none is listed without having been seen; a tool that is not on this list sets `TESTING_AGENT=1` or passes
---`--reporter agent`.
---@type { name: string, test: fun(v: string): boolean }[]
M.AGENT_ENV = {
  {
    name = "AI_AGENT",
    test = function(v)
      return v ~= ""
    end,
  },
  {
    name = "CLAUDECODE",
    test = function(v)
      return v == "1"
    end,
  },
}

---@param v any
---@return boolean|nil
local function truthy(v)
  if type(v) ~= "string" then
    return nil
  end
  v = v:lower()
  if v == "1" or v == "on" or v == "true" or v == "yes" then
    return true
  end
  if v == "0" or v == "off" or v == "false" or v == "no" then
    return false
  end
  return nil
end

---Which stdout reporter a run uses. Order: `--reporter`, `TESTING_REPORTER`, `TESTING_AGENT` (on/off), a
---recognised agent environment (`AGENT_ENV`), else none (the caller's default, `term`). Pure: the
---environment is an argument. Only the entry point (`scripts/testing.lua`) hands the real environment
---down, so a spec that calls the CLI is never switched by the environment it happens to run in.
---@param explicit string|nil `--reporter`
---@param env table<string, string|nil>|nil
---@return string|nil reporter
---@return string|nil err A usage error (an unknown `TESTING_REPORTER`).
---@return string|nil how Where the choice came from.
function M.choose(explicit, env)
  if explicit then
    return explicit, nil, "--reporter"
  end
  env = env or {}
  local named = env.TESTING_REPORTER
  if type(named) == "string" and named ~= "" then
    if not vim.tbl_contains(require("testing.args").REPORTERS, named) then
      return nil,
        ("TESTING_REPORTER: unknown reporter '%s' (one of: %s)"):format(
          util.clean(named),
          table.concat(require("testing.args").REPORTERS, ", ")
        )
    end
    return named, nil, "TESTING_REPORTER"
  end
  local on = truthy(env.TESTING_AGENT)
  if on == true then
    return "agent", nil, "TESTING_AGENT"
  elseif on == false then
    return nil, nil, "TESTING_AGENT=0"
  end
  for _, e in ipairs(M.AGENT_ENV) do
    local v = env[e.name]
    if type(v) == "string" and e.test(v) then
      return "agent", nil, "the agent environment (" .. e.name .. ")"
    end
  end
  return nil, nil, nil
end

---Render a result for an agent.
---@param result Testing.Result
---@param opts? Testing.Report.AgentOpts
---@return string[] lines No trailing newlines, none containing one.
function M.render(result, opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts or {})
  if type(o.budget) ~= "number" or o.budget < 1 then
    o.budget = M.DEFAULTS.budget
  end
  local v = verdict_mod.of(result)
  local groups = failure_groups(result, o)
  local guards = guard_entries(result, o)
  if o.format == "jsonl" then
    return render_jsonl(result, v, groups, guards, o)
  end
  return render_text(result, v, groups, guards, o)
end

return M
