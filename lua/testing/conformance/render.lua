---@module 'testing.conformance.render'
---@brief The report as JSON, terminal lines, Markdown and Result-IR (for the JUnit / GitHub reporters).
---@description
--- All four forms are made from the one report table (`Testing.Conformance.Report`) and are pure: the same
--- report is the same bytes. Text that came out of the checked repository (a file name, a line of its
--- code) was made printable by the checks (`util.show`); the renderers clean once more anyway
--- (`testing.report.util.clean`), because a report is also written to files and CI summaries.

local clean = require("testing.report.util").clean

local M = {}

---Status words as printed in the terminal (fixed width 5).
local WORD = {
  pass = "ok",
  fail = "FAIL",
  warn = "warn",
  ["n/a"] = "n/a",
  error = "ERROR",
  manual = "manual",
}

---@param s any
---@return string
local function c(s)
  return clean(tostring(s), { c1 = true, bidi = true })
end

---JSON text of the report (sorted keys, indented, newline at the end).
---@param report Testing.Conformance.Report
---@return string|nil json
---@return string|nil err
function M.json(report)
  local text, err = require("lib.nvim.json").encode(report, { indent = 2 })
  if not text then
    return nil, err
  end
  return text .. "\n"
end

---`file:line` of a finding.
---@param f Testing.Conformance.Finding
---@return string
local function where(f)
  if not f.file then
    return ""
  end
  return f.line and ("%s:%d"):format(c(f.file), f.line) or c(f.file)
end

---Terminal lines: one line per check, its findings below, a summary.
---@param report Testing.Conformance.Report
---@param opts? { verbose?: boolean, manual?: boolean }
---@return string[]
function M.terminal(report, opts)
  opts = opts or {}
  local lines = {}
  local head = ("conformance: %s"):format(c(report.name))
  if report.plugin then
    head = head .. (" (plugin %s)"):format(c(report.plugin))
  end
  lines[#lines + 1] = head .. ("  [%s]"):format(report.mode)
  for _, r in ipairs(report.checks) do
    local suffix = r.reason and ("  (%s)"):format(c(r.reason)) or ""
    lines[#lines + 1] = ("%-6s %-4s %s%s"):format(
      WORD[r.status] or r.status,
      r.id,
      c(r.title),
      suffix
    )
    local shown = 0
    for _, f in ipairs(r.findings) do
      if f.waived then
        if opts.verbose then
          lines[#lines + 1] = ("         waived %s  %s  (%s)"):format(
            c(f.rule),
            c(f.message),
            c(f.waiver_reason)
          )
        end
      else
        shown = shown + 1
        local place = where(f)
        lines[#lines + 1] = ("       %-5s %s%s  [%s]"):format(
          f.level,
          place ~= "" and (place .. "  ") or "",
          c(f.message),
          c(f.rule)
        )
      end
    end
    if opts.verbose then
      for _, n in ipairs(r.notes) do
        lines[#lines + 1] = "       note  " .. c(n)
      end
    end
  end
  for _, p in ipairs(report.problems) do
    lines[#lines + 1] = "problem: " .. c(p)
  end
  if opts.manual then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("manual rules (%d): nothing decides them from the repository"):format(
      #report.manual
    )
    for _, m in ipairs(report.manual) do
      lines[#lines + 1] = ("  %-9s %s  [%s]"):format(c(m.id), c(m.title), c(m.severity))
    end
  end
  local s = report.summary
  lines[#lines + 1] = ""
  lines[#lines + 1] = (
    "summary: %d check(s): %d ok, %d fail, %d warn, %d n/a, %d error; "
    .. "%d error / %d warn / %d info finding(s), %d waived; %d manual rule(s); verdict %s"
  ):format(
    s.checks or 0,
    s.pass or 0,
    s.fail or 0,
    s.warn or 0,
    s["n/a"] or 0,
    s.error or 0,
    s.findings and s.findings.error or 0,
    s.findings and s.findings.warn or 0,
    s.findings and s.findings.info or 0,
    s.waived or 0,
    s.manual or 0,
    report.verdict
  )
  return lines
end

---Escape a table cell.
---@param s any
---@return string
local function md(s)
  -- text out of the checked repository (a description, a group name, a directory name) is data in a document
  -- that GitHub renders: no link, no image, no HTML, no heading, no table cell break
  local text = c(s):gsub("&", "&amp;"):gsub("[\\`*_{}%[%]()#+!|<>~]", "\\%0")
  return text
end

---A code span that the text cannot leave: the fence is longer than any run of backticks inside.
---@param s any
---@return string
local function md_code(s)
  local text = c(s)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", longest + 1)
  return fence .. " " .. text .. " " .. fence
end

---@param s any
---@return string
local function cell(s)
  return md(s)
end

---Markdown: a table of the checks, the findings, the manual rules.
---@param report Testing.Conformance.Report
---@return string
function M.markdown(report)
  local out = {}
  local function add(line)
    out[#out + 1] = line
  end
  add(("# Conformance: %s"):format(md(report.name)))
  add("")
  add(
    ("Mode `%s`, verdict **%s**%s."):format(
      report.mode,
      report.verdict,
      report.plugin and (", plugin " .. md_code(report.plugin)) or ""
    )
  )
  add("")
  add("| Check | Status | What | Rules | Findings |")
  add("| --- | --- | --- | --- | --- |")
  for _, r in ipairs(report.checks) do
    local open = 0
    for _, f in ipairs(r.findings) do
      if not f.waived then
        open = open + 1
      end
    end
    add(
      ("| %s | %s | %s | %s | %s |"):format(
        r.id,
        r.status,
        cell(r.title .. (r.reason and (" (" .. r.reason .. ")") or "")),
        cell(table.concat(r.rules, ", ")),
        open
      )
    )
  end
  for _, r in ipairs(report.checks) do
    if #r.findings > 0 then
      add("")
      add(("## %s: %s"):format(r.id, cell(r.title)))
      add("")
      for _, f in ipairs(r.findings) do
        local place = where(f)
        add(
          ("- **%s** %s%s %s%s"):format(
            f.waived and "waived" or f.level,
            md_code(f.rule),
            place ~= "" and (" " .. md_code(place)) or "",
            md(f.message),
            f.waived and (" (reason: " .. md(f.waiver_reason) .. ")") or ""
          )
        )
      end
    end
  end
  if #report.problems > 0 then
    add("")
    add("## Problems")
    add("")
    for _, p in ipairs(report.problems) do
      add("- " .. md(p))
    end
  end
  add("")
  add("## Manual rules")
  add("")
  add("No tool decides these from the repository; they are listed so that a green report is not")
  add('read as "every rule holds".')
  add("")
  add("| Rule | Severity | Gate | What | Why manual |")
  add("| --- | --- | --- | --- | --- |")
  for _, m in ipairs(report.manual) do
    add(
      ("| %s | %s | %s | %s | %s |"):format(m.id, m.severity, m.gate, cell(m.title), cell(m.reason))
    )
  end
  return table.concat(out, "\n") .. "\n"
end

---The report as a Result-IR, so that the JUnit and GitHub reporters can render it: one case per check
---(file `conformance/<id>`), a failed assertion per error finding, a pass with a warning note per
---warning, `skip` for a check that does not apply and `error` for one that could not run.
---@param report Testing.Conformance.Report
---@return Testing.Result
function M.to_result(report)
  local result_mod = require("testing.core.result")
  local result = result_mod.new({ root = "<REPO>", project_key = report.name })
  for _, r in ipairs(report.checks) do
    local case = result_mod.new_case({
      file = "conformance/" .. r.id,
      name = r.title,
      tags = vim.list_extend({ "conformance", r.kind }, vim.deepcopy(r.rules)),
    })
    if r.status == "n/a" then
      case.status = "skip"
      case.notes[#case.notes + 1] = c(r.reason or "not applicable")
    elseif r.status == "error" then
      case.status = "error"
      case.notes[#case.notes + 1] = c(r.reason or "the check could not run")
    else
      for _, f in ipairs(r.findings) do
        local text = ("[%s] %s"):format(f.rule, c(f.message))
        if f.waived then
          case.notes[#case.notes + 1] = "waived: " .. text .. " (" .. c(f.waiver_reason) .. ")"
        elseif f.level == "error" then
          case.assertions[#case.assertions + 1] = {
            ok = false,
            kind = "conformance",
            msg = text,
            file = f.file,
            line = f.line,
          }
        else
          case.notes[#case.notes + 1] = f.level .. ": " .. text
        end
      end
      if #case.assertions == 0 then
        case.assertions[1] = { ok = true, kind = "conformance", msg = "no error finding" }
      end
      result_mod.finish_case(case)
    end
    result_mod.add_case(result, case)
  end
  return result_mod.finalize(result)
end

return M
