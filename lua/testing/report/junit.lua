---@module 'testing.report.junit'
---@brief JUnit XML reporter: one testsuite per spec file, one testcase per case.
---@description
--- Consumed by CI test-report viewers, which parse the file with a real XML parser and show its
--- strings to humans: the document must be well-formed whatever the code under test put in a case
--- name or a message (D.8, injection in reports). Rules this module keeps:
---
---   * all text passes `util.clean` first: invalid UTF-8 becomes U+FFFD and characters that XML 1.0
---     forbids (C0 controls except TAB/LF/CR, U+FFFE/U+FFFF) become a visible `\xNN`;
---   * attribute values escape `& < > " '` and TAB/LF/CR as character references (a parser would
---     otherwise normalize a raw newline in an attribute to a space);
---   * element bodies are CDATA with `]]>` split over two sections, so nothing in a body can close
---     the section or open an element;
---   * bodies are capped (`max_body_bytes`) so one runaway message cannot make a multi-megabyte file.
---
--- Mapping: `fail`/`xpass` -> `<failure>`, `error`/`timeout`/`crash` -> `<error>`, `skip` and
--- `xfail` -> `<skipped>` (xfail with the message "expected failure"). Counters per suite and for
--- the whole document are derived from those elements, so they always add up. Output is
--- deterministic: no timestamp, no host name, attributes in a fixed order, cases in IR order.

local util = require("testing.report.util")

local M = {}

---@class Testing.Report.JunitOpts
---@field max_body_bytes? integer Cap of one element body in bytes (default 16384).
---@field suite_name? string `name` of the root `<testsuites>` (default `testing.nvim`).

---@type Testing.Report.JunitOpts
M.DEFAULTS = { max_body_bytes = 16384, suite_name = "testing.nvim" }

local TEXT_KEEP = { [9] = true, [10] = true, [13] = true }

---Escape an attribute value.
---@param s any
---@return string
function M.attr(s)
  -- TAB/LF/CR are not kept: they become a visible `\x09` etc. (a parser would normalize a raw
  -- newline in an attribute value to a space and the information would be lost silently).
  s = util.clean(tostring(s), { bidi = true })
  s =
    s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
  return s
end

---Escape element text with entities (for short bodies; long ones use `cdata`).
---@param s any
---@return string
function M.text(s)
  s = util.clean(tostring(s), { keep = TEXT_KEEP, bidi = true })
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\r", "&#13;")
  return s
end

---A CDATA section; `]]>` inside the text is split so it can never end the section early.
---@param s any
---@return string
function M.cdata(s)
  s = util.clean(tostring(s), { keep = TEXT_KEEP, bidi = true })
  s = s:gsub("]]>", "]]]]><![CDATA[>")
  -- CR would be normalized to LF by a parser; keep the information visible instead
  s = s:gsub("\r", "\\r")
  return "<![CDATA[" .. s .. "]]>"
end

---@param s string
---@param o Testing.Report.JunitOpts
---@return string
local function body(s, o)
  local cut, truncated = util.cap(s, o.max_body_bytes)
  if truncated then
    cut = cut .. ("\n... (truncated, %d more byte(s))"):format(#s - #cut)
  end
  return M.cdata(cut)
end

---The text of a failed assertion: message, expected, actual.
---@param a Testing.Result.Assertion
---@return string
local function assertion_text(a)
  local parts = {}
  local where = a.file and (a.file .. (a.line and (":" .. a.line) or "")) or nil
  parts[#parts + 1] = (where and (where .. "  ") or "") .. (a.msg or a.kind or "failed")
  if a.expected ~= nil then
    parts[#parts + 1] = "expected: " .. tostring(a.expected)
  end
  if a.actual ~= nil then
    parts[#parts + 1] = "actual: " .. tostring(a.actual)
  end
  if a.diff and a.diff ~= "" then
    parts[#parts + 1] = a.diff
  end
  return table.concat(parts, "\n")
end

---@param c Testing.Result.Case
---@return string element `failure`, `error` or `skipped` (or "" for a green case)
---@return string|nil message
---@return string|nil type
---@return string|nil text
local function problem(c)
  local status = c.status
  if status == "pass" then
    return ""
  end
  if status == "skip" then
    return "skipped", c.reason or "skipped", nil, nil
  end
  if status == "xfail" then
    return "skipped", "expected failure", nil, nil
  end
  local texts, first = {}, nil
  for _, a in ipairs(c.assertions or {}) do
    if a.ok == false then
      first = first or a.msg or a.kind
      texts[#texts + 1] = assertion_text(a)
    end
  end
  if c.error then
    first = first or c.error.message
    local trace = c.error.traceback
    -- a Lua traceback starts with the message: do not print it twice
    if
      type(trace) ~= "string"
      or trace == ""
      or trace:sub(1, #tostring(c.error.message)) ~= tostring(c.error.message)
    then
      texts[#texts + 1] = tostring(c.error.message)
    end
    if type(trace) == "string" and trace ~= "" then
      texts[#texts + 1] = trace
    end
  end
  if status == "xpass" then
    first = first or "unexpectedly passed (expected failure)"
    texts[#texts + 1] = "unexpectedly passed (expected failure)"
  end
  local element = (status == "fail" or status == "xpass") and "failure" or "error"
  -- the type of a failure is the status unless the first failed assertion's kind names it better
  local kind = status
  if status == "fail" then
    for _, a in ipairs(c.assertions or {}) do
      if a.ok == false then
        kind = a.kind
        break
      end
    end
  end
  return element, first or status, kind, table.concat(texts, "\n")
end

---The guard findings of a case as text (a `warn` of a green case is only visible here; the `error`
---ones also failed the case, which `problem` already reports), or nil when there are none.
---@param c Testing.Result.Case
---@return string|nil
local function guard_out(c)
  if type(c.guards) ~= "table" or #c.guards == 0 then
    return nil
  end
  local lines = {}
  for _, g in ipairs(c.guards) do
    -- `info` findings are listed in the IR only (a CI viewer would show one line per loaded module)
    if g.severity ~= "info" then
      lines[#lines + 1] = ("guard [%s %s] %s"):format(g.guard, g.severity, g.message)
    end
  end
  return #lines > 0 and table.concat(lines, "\n") or nil
end

---@class Testing.Report.JunitSuite
---@field tests integer
---@field failures integer
---@field errors integer
---@field skipped integer
---@field time number

---Render the document as lines.
---@param result Testing.Result
---@param opts? Testing.Report.JunitOpts
---@return string[] lines
function M.render(result, opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts or {})
  local run = result.run or {}
  local blocks, total = {}, { tests = 0, failures = 0, errors = 0, skipped = 0, time = 0 }

  for _, g in ipairs(util.group_by_file(result)) do
    local suite = { tests = 0, failures = 0, errors = 0, skipped = 0, time = 0 }
    local cases = {}
    for _, c in ipairs(g.cases) do
      suite.tests = suite.tests + 1
      suite.time = suite.time + (c.duration_ms or 0)
      local element, message, kind, text = problem(c)
      local guard_text = guard_out(c)
      local attrs = ('classname="%s" name="%s"'):format(M.attr(g.file), M.attr(util.short_name(c)))
      if c.line then
        attrs = attrs .. (' line="%d"'):format(c.line)
      end
      attrs = attrs .. (' time="%s"'):format(util.seconds(c.duration_ms))
      if element == "" and guard_text == nil then
        cases[#cases + 1] = ("    <testcase %s/>"):format(attrs)
      elseif element == "" then
        cases[#cases + 1] = ("    <testcase %s>"):format(attrs)
        cases[#cases + 1] = "      <system-out>" .. body(guard_text or "", o) .. "</system-out>"
        cases[#cases + 1] = "    </testcase>"
      else
        if element == "failure" then
          suite.failures = suite.failures + 1
        elseif element == "error" then
          suite.errors = suite.errors + 1
        else
          suite.skipped = suite.skipped + 1
        end
        local inner = ('<%s message="%s"'):format(element, M.attr(message or ""))
        if kind then
          inner = inner .. (' type="%s"'):format(M.attr(kind))
        end
        if text and text ~= "" then
          inner = inner .. ">" .. body(text, o) .. ("</%s>"):format(element)
        else
          inner = inner .. "/>"
        end
        cases[#cases + 1] = ("    <testcase %s>"):format(attrs)
        cases[#cases + 1] = "      " .. inner
        if guard_text then
          cases[#cases + 1] = "      <system-out>" .. body(guard_text, o) .. "</system-out>"
        end
        cases[#cases + 1] = "    </testcase>"
      end
    end
    for k, v in pairs(suite) do
      total[k] = total[k] + v
    end
    local head = ('  <testsuite name="%s" tests="%d" failures="%d" errors="%d" skipped="%d" time="%s">'):format(
      M.attr(g.file),
      suite.tests,
      suite.failures,
      suite.errors,
      suite.skipped,
      util.seconds(suite.time)
    )
    blocks[#blocks + 1] = head
    local props = {}
    for _, kv in ipairs({
      { "nvim", run.nvim },
      { "os", run.os },
      { "seed", run.seed },
    }) do
      if kv[2] ~= nil then
        props[#props + 1] = ('      <property name="%s" value="%s"/>'):format(kv[1], M.attr(kv[2]))
      end
    end
    if #props > 0 then
      blocks[#blocks + 1] = "    <properties>"
      for _, p in ipairs(props) do
        blocks[#blocks + 1] = p
      end
      blocks[#blocks + 1] = "    </properties>"
    end
    for _, l in ipairs(cases) do
      blocks[#blocks + 1] = l
    end
    blocks[#blocks + 1] = "  </testsuite>"
  end

  local lines = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    ('<testsuites name="%s" tests="%d" failures="%d" errors="%d" skipped="%d" time="%s">'):format(
      M.attr(o.suite_name),
      total.tests,
      total.failures,
      total.errors,
      total.skipped,
      util.seconds(total.time)
    ),
  }
  for _, l in ipairs(blocks) do
    lines[#lines + 1] = l
  end
  lines[#lines + 1] = "</testsuites>"
  return lines
end

return M
