---@module 'testing.ci.report'
---@brief The reporters of `testing ci` at step level: findings from an error format, terminal summary, agent, JUnit.
---@description
--- A process step's output is read with the error format of its preset (`efm`): Vim's `errorformat` items `%f`
--- (file, no blanks: Vim's isfname), `%l` (line), `%c` (column), `%m` (message) and `%%`, everything else literal,
--- one pattern per line, several alternatives per preset; any other `%` item is an error. Not `:cexpr`: this runs
--- headless and the result is data (the `findings` of each step in `testing-ci/1`), which the editor turns into a
--- quickfix list and an agent reads directly. The suite's findings come from its Result-IR (`M.ir_findings`), not
--- from text.
---
--- Formats, all pure functions of the document (golden-tested):
---   * terminal: one row per step (name, state, duration, reason), the verdict line, the sentinel only after a
---     complete green run;
---   * agent: the first line is the verdict (`ci GREEN full 4/4`, `ci RED luacheck (2 findings) exit 1`,
---     `ci PARTIAL ...` for anything less than a complete run of the tested commit), then only what needs a look;
---   * JUnit: one `testsuite` per step, its findings as failed `testcase`s (one testcase when there are none).

local junit = require("testing.report.junit")
local util = require("testing.report.util")

local M = {}

---Most findings kept per step (a formatter on a whole tree can report thousands); the total is still counted.
M.MAX_FINDINGS = 200

---@class Testing.Ci.Finding
---@field file string
---@field line? integer
---@field col? integer
---@field text string

---@type table<string, true>
local MAGIC = {}
for c in ("^$()%.[]*+-?"):gmatch(".") do
  MAGIC[c] = true
end

---Compile one errorformat item into a Lua pattern and the order of its captures. Raises on an item it does not
---support (a format that silently never matches would hide every finding).
---@param efm string
---@return string pattern
---@return string[] fields
function M.compile(efm)
  local pat, fields, i = { "^" }, {}, 1
  while i <= #efm do
    local c = efm:sub(i, i)
    if c == "%" and i < #efm then
      local k = efm:sub(i + 1, i + 1)
      i = i + 2
      if k == "f" then
        -- no blanks (a grouped report line is no file name); non-greedy for the drive colon of a Windows path
        pat[#pat + 1] = "(%S-)"
        fields[#fields + 1] = "file"
      elseif k == "l" then
        pat[#pat + 1] = "(%d+)"
        fields[#fields + 1] = "line"
      elseif k == "c" then
        pat[#pat + 1] = "(%d+)"
        fields[#fields + 1] = "col"
      elseif k == "m" then
        pat[#pat + 1] = "(.*)"
        fields[#fields + 1] = "text"
      elseif k == "%" then
        pat[#pat + 1] = "%%"
      else
        error(
          ("errorformat %q: %%%s is not supported (only %%f %%l %%c %%m %%%%)"):format(efm, k),
          2
        )
      end
    else
      pat[#pat + 1] = MAGIC[c] and ("%" .. c) or c
      i = i + 1
    end
  end
  pat[#pat + 1] = "$"
  return table.concat(pat), fields
end

---@class Testing.Ci.Matcher
---@field feed fun(line: string) Match one output line.
---@field list Testing.Ci.Finding[] The findings so far (at most `MAX_FINDINGS`).
---@field total fun(): integer Every line that matched.

---A matcher for an error format (one item or a list of alternatives), fed line by line as the output arrives:
---nothing but the findings is kept, and the total counts every match.
---@param efm string|string[]|nil
---@return Testing.Ci.Matcher
function M.matcher(efm)
  local compiled = {}
  for _, item in ipairs(type(efm) == "table" and efm or (efm and { efm } or {})) do
    local pat, fields = M.compile(item)
    compiled[#compiled + 1] = { pat = pat, fields = fields }
  end
  local list, total = {}, 0
  local function feed(line)
    for _, c in ipairs(compiled) do
      local caps = { line:match(c.pat) }
      if #caps > 0 then
        local f = { text = "" }
        for k, name in ipairs(c.fields) do
          f[name] = (name == "line" or name == "col") and tonumber(caps[k]) or caps[k]
        end
        if f.file and f.file ~= "" then
          total = total + 1
          if #list < M.MAX_FINDINGS then
            list[#list + 1] = f --[[@as Testing.Ci.Finding]]
          end
          return
        end
      end
    end
  end
  return {
    feed = feed,
    list = list,
    total = function()
      return total
    end,
  }
end

---Parse output lines with an error format (a matcher fed with all of them).
---@param efm string|string[]|nil
---@param lines string[]
---@return Testing.Ci.Finding[] findings
---@return integer total
function M.findings(efm, lines)
  local m = M.matcher(efm)
  for _, line in ipairs(lines) do
    m.feed(line)
  end
  return m.list, m.total()
end

local RED_STATUS = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---The findings of a suite run, from its Result-IR: one per case that is not green, at the failed assertion (else
---the case), the text naming the case and the first line of what went wrong.
---@param ir table|nil The decoded IR.
---@return Testing.Ci.Finding[] findings
---@return integer total
function M.ir_findings(ir)
  local list, total = {}, 0
  for _, case in ipairs(type(ir) == "table" and type(ir.cases) == "table" and ir.cases or {}) do
    if RED_STATUS[case.status] then
      total = total + 1
      if #list < M.MAX_FINDINGS then
        local failed
        for _, a in ipairs(case.assertions or {}) do
          if a.ok == false then
            failed = a
            break
          end
        end
        local why = failed and (failed.msg or failed.kind)
          or (type(case.error) == "table" and case.error.message)
          or case.status
        local name = case.name or case.id or "?"
        -- the IR normalizes the repository to `<REPO>`; a finding is relative to the root
        local file = tostring(failed and failed.file or case.file or "?"):gsub("^<REPO>[/\\]", "")
        list[#list + 1] = {
          file = file,
          line = failed and failed.line or case.line,
          text = ("%s %s: %s"):format(case.status, name, (tostring(why):match("[^\n]*"))),
        }
      end
    end
  end
  return list, total
end

---@param v any
---@return any|nil
local function val(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param s any
---@return string
local function clean(s)
  return util.clean(tostring(s))
end

---@param f Testing.Ci.Finding|table A finding, also one read back from the document (`vim.NIL` for a missing line).
---@return string
function M.finding_line(f)
  local loc = clean(f.file)
  local line, col = val(f.line), val(f.col)
  if line then
    loc = loc .. ":" .. line
    if col then
      loc = loc .. ":" .. col
    end
  end
  local text = val(f.text)
  return (text and text ~= "") and (loc .. ": " .. clean(text)) or loc
end

---@param ms integer
---@return string
local function seconds(ms)
  return ("%.1f s"):format(ms / 1000)
end

---@param doc table testing-ci/1
---@return integer green
local function count_green(doc)
  local n = 0
  for _, s in ipairs(doc.steps) do
    if s.state == "green" then
      n = n + 1
    end
  end
  return n
end

---Why a green exit is not a complete proof of the tested commit, or nil.
---@param doc table
---@return string|nil
local function less_than_complete(doc)
  local why = {}
  if doc.partial then
    why[#why + 1] = "partial: " .. tostring(val(doc.partial_why) or "?")
  end
  if doc.head_moved then
    why[#why + 1] = "HEAD moved during the run"
  end
  return #why > 0 and table.concat(why, "; ") or nil
end

---The summary after the step output: one row per step, the verdict, the sentinel after a complete green run.
---@param doc table testing-ci/1
---@param sentinel string
---@return string[]
function M.term(doc, sentinel)
  local lines = {}
  for _, s in ipairs(doc.steps) do
    local reason = val(s.reason)
    local found = (s.findings_total or 0) > 0 and ("  %d finding(s)"):format(s.findings_total) or ""
    lines[#lines + 1] = ("  %-14s %-8s %8s%s%s"):format(
      s.name,
      s.state,
      seconds(s.ms),
      reason and ("  " .. clean(reason)) or "",
      found
    )
  end
  if doc.exit == 0 then
    local less = less_than_complete(doc)
    lines[#lines + 1] = ("ci: GREEN %s %d/%d%s"):format(
      doc.profile,
      count_green(doc),
      #doc.steps,
      less and (" (" .. less .. ")") or ""
    )
    if not less then
      lines[#lines + 1] = sentinel
    end
  else
    local word = doc.exit == 1 and "RED" or doc.exit == 2 and "ERROR" or "INFRA"
    lines[#lines + 1] = ("ci: %s %s (exit %d)"):format(word, val(doc.first_red) or "?", doc.exit)
  end
  return lines
end

---The agent report: the verdict first, then only what needs a look. Anything less than a complete run of the
---tested commit is `PARTIAL`, never `GREEN` (a reader keying on the first word must not take it as a proof).
---@param doc table testing-ci/1
---@return string[]
function M.agent(doc)
  local lines = {}
  if doc.exit == 0 then
    local less = less_than_complete(doc)
    lines[1] = ("ci %s %s %d/%d%s"):format(
      less and "PARTIAL" or "GREEN",
      doc.profile,
      count_green(doc),
      #doc.steps,
      less and (" (" .. less .. ")") or ""
    )
    return lines
  end
  local word = doc.exit == 1 and "RED" or doc.exit == 2 and "ERROR" or "INFRA"
  local total = 0
  for _, s in ipairs(doc.steps) do
    total = total + (s.findings_total or 0)
  end
  lines[1] = ("ci %s %s (%d finding%s) exit %d"):format(
    word,
    val(doc.first_red) or "?",
    total,
    total == 1 and "" or "s",
    doc.exit
  )
  for _, s in ipairs(doc.steps) do
    if s.state ~= "green" and s.state ~= "skipped" then
      local reason = val(s.reason)
      lines[#lines + 1] = ("[%s] %s%s"):format(
        s.name,
        s.state,
        reason and (": " .. clean(reason)) or ""
      )
      local findings = s.findings or {}
      for _, f in ipairs(findings) do
        lines[#lines + 1] = "  " .. M.finding_line(f)
      end
      if (s.findings_total or 0) > #findings then
        lines[#lines + 1] = ("  ... %d more"):format(s.findings_total - #findings)
      end
      if #findings == 0 then
        for _, e in ipairs(s.errors or {}) do
          lines[#lines + 1] = "  " .. clean(e)
        end
      end
    end
  end
  return lines
end

---JUnit XML: one testsuite per step.
---@param doc table testing-ci/1
---@return string
function M.junit(doc)
  local suites, total, failures, errors, skipped = {}, 0, 0, 0, 0
  for _, s in ipairs(doc.steps) do
    local cases, n = {}, 0
    ---@param name string
    ---@param kind? "failure"|"error"|"skipped"
    ---@param message? string
    ---@param body? string
    local function case(name, kind, message, body)
      n = n + 1
      local head = ('    <testcase name="%s" classname="%s" time="%.3f"'):format(
        junit.attr(name),
        junit.attr("ci." .. s.name),
        (n == 1 and s.ms or 0) / 1000
      )
      if not kind then
        cases[#cases + 1] = head .. "/>"
        return
      end
      cases[#cases + 1] = head .. ">"
      if kind == "skipped" then
        cases[#cases + 1] = ('      <skipped message="%s"/>'):format(junit.attr(message))
      else
        cases[#cases + 1] = ('      <%s message="%s">%s</%s>'):format(
          kind,
          junit.attr(message),
          junit.cdata(body or ""),
          kind
        )
      end
      cases[#cases + 1] = "    </testcase>"
    end
    local reason = val(s.reason)
    local n_fail, n_err, n_skip = 0, 0, 0
    local findings = s.findings or {}
    if s.state == "skipped" then
      case(s.name, "skipped", reason or "skipped")
      n_skip = 1
    elseif s.state == "green" then
      case(s.name)
    else
      local kind = s.state == "red" and "failure" or "error"
      local why = reason and ("\n(" .. s.name .. ": " .. reason .. ")") or ""
      if #findings > 0 then
        for _, f in ipairs(findings) do
          local text = val(f.text)
          case(
            M.finding_line(f),
            kind,
            (text and text ~= "") and text or s.state,
            M.finding_line(f) .. why
          )
        end
        local more = (s.findings_total or 0) - #findings
        if more > 0 then
          case(("%d more finding(s)"):format(more), kind, "not listed (cap)", why)
        end
      else
        case(s.name, kind, reason or s.state, table.concat(s.errors or {}, "\n"))
      end
      if kind == "failure" then
        n_fail = n
      else
        n_err = n
      end
    end
    total, failures, errors, skipped =
      total + n, failures + n_fail, errors + n_err, skipped + n_skip
    suites[#suites + 1] = ('  <testsuite name="%s" tests="%d" failures="%d" errors="%d" skipped="%d" time="%.3f">'):format(
      junit.attr(s.name),
      n,
      n_fail,
      n_err,
      n_skip,
      s.ms / 1000
    )
    vim.list_extend(suites, cases)
    suites[#suites + 1] = "  </testsuite>"
  end
  local out = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    ('<testsuites name="%s" tests="%d" failures="%d" errors="%d" skipped="%d">'):format(
      junit.attr("testing ci " .. tostring(doc.profile)),
      total,
      failures,
      errors,
      skipped
    ),
  }
  vim.list_extend(out, suites)
  out[#out + 1] = "</testsuites>"
  return table.concat(out, "\n") .. "\n"
end

return M
