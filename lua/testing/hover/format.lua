---@module 'testing.hover.format'
---@brief The text of a hover: pure functions from a loaded state to a few plain lines.
---@description
--- Nothing here touches the editor or the file system. `describe_case`, `describe_group` and `describe_file`
--- turn state entries into `{ lines, title, highlight? }`; `fit` cuts that to the configured height and width.
---
--- **Never a stale green.** A spec file that changed (or vanished) since its result was recorded gets the
--- title `(outdated)` and its status is worded in the past tense ("was pass"): the case may not exist any
--- more or may behave differently. A file or a case the store knows nothing about says "not run yet"
--- instead of staying silent.
---
--- **Hostile text (SEC-32/45, UI-34).** Titles, messages and values come from the code under test. They went
--- through `testing.state` already and pass `testing.report.util.clean` once more here; every line is cut to a
--- byte cap and `fit` cuts to display columns, so nothing reaches a float that a terminal could interpret.
--- The result is plain text: it is never evaluated as markup.

local M = {}

---@class Testing.Hover.Limits
---@field width integer   Longest line, in display columns.
---@field height integer  Most lines.
---@field diff integer    Lines of a failure diff.

---@type Testing.Hover.Limits
M.DEFAULT_LIMITS = { width = 80, height = 20, diff = 12 }

---Longest single text taken from a project (bytes), before `fit` cuts to columns.
---@type integer
M.MAX_LINE = 200

---Failing assertions listed for a whole-file case.
---@type integer
M.MAX_FAILS = 8

---Highlight groups of the first line (`Testing.Hover.Content.highlight`). `HoverError` is one hover.nvim defines
---itself (linked to `DiagnosticError`); hover.nvim has no warning group, so `TestingHoverWarn` is this plugin's own
---(linked to `DiagnosticWarn`). `testing.hover.float.ensure_highlight` defines both, `default = true`.
M.HL_ERROR = "HoverError"
M.HL_WARN = "TestingHoverWarn"

local BAD = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---@param s any
---@return string
local function safe(s)
  local util = require("testing.report.util")
  local text = util.clean(tostring(s or ""), { bidi = true })
  local cut, truncated = util.cap(text, M.MAX_LINE)
  return truncated and (cut .. "...") or cut
end
M.safe = safe

---"3 min ago", from two epoch seconds.
---@param ts? number
---@param now number
---@return string
function M.ago(ts, now)
  if type(ts) ~= "number" or ts <= 0 then
    return "at an unknown time"
  end
  local d = now - ts
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%d min ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%d h ago"):format(math.floor(d / 3600))
  end
  return ("%d d ago"):format(math.floor(d / 86400))
end

---@param ms number
---@return string
local function duration(ms)
  if ms >= 1000 then
    return ("%.2f s"):format(ms / 1000)
  end
  return ("%d ms"):format(math.floor(ms + 0.5))
end

---The words for a stale reason.
---@type table<string, string>
local WHY = {
  changed = "the file changed since the run",
  gone = "the file is gone",
  ["no result"] = "no result recorded",
  ["unsaved changes"] = "the buffer has unsaved changes",
}

---@param limits? Testing.Hover.Limits
---@return Testing.Hover.Limits
local function lim(limits)
  return vim.tbl_extend("force", M.DEFAULT_LIMITS, limits or {})
end

---@class Testing.Hover.Content
---@field lines string[]
---@field title string
---@field highlight? string

---Content of one case.
---@param c Testing.State.Case
---@param file_ts? number
---@param stale boolean
---@param why? string
---@param now number
---@param limits? Testing.Hover.Limits
---@return Testing.Hover.Content
function M.describe_case(c, file_ts, stale, why, now, limits)
  limits = lim(limits)
  local verb = stale and "was" or "is"
  local lines = {
    ("%s %s - %s, %s"):format(verb, safe(c.status), duration(c.duration_ms), M.ago(file_ts, now)),
  }
  if stale then
    lines[#lines + 1] = ("outdated: %s"):format(WHY[why or ""] or safe(why or "unknown"))
  end
  if c.flaky then
    lines[#lines + 1] = "flaky: passed on a retry"
  end
  if BAD[c.status] or c.status == "skip" then
    if c.message and c.message ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = safe(c.message)
    end
    if BAD[c.status] and c.expected and c.actual and c.expected ~= c.actual then
      local diff = require("testing.report.term").diff_lines(c.expected, c.actual, {
        width = M.MAX_LINE,
        diff_context = 1,
      }, function(_, s)
        return s
      end)
      lines[#lines + 1] = ""
      if diff then
        for i, l in ipairs(diff) do
          if i > limits.diff then
            lines[#lines + 1] = "..."
            break
          end
          lines[#lines + 1] = safe(l)
        end
      else
        lines[#lines + 1] = "expected: " .. safe(c.expected:match("[^\n]*"))
        lines[#lines + 1] = "actual:   " .. safe(c.actual:match("[^\n]*"))
      end
    end
  end
  -- A case that is a whole file (dialect A and the like): every failing assertion with its line.
  if c.line == nil and c.fails and #c.fails > 0 then
    -- the store keeps the first assertions only; `fails_total` is the real count when there were more
    local total = math.max(c.fails_total or 0, #c.fails)
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%d failing assertion(s):"):format(total)
    local shown = math.min(#c.fails, M.MAX_FAILS)
    for i = 1, shown do
      local f = c.fails[i]
      local where = f.line and ("%s:%d"):format(safe(c.file), f.line) or safe(c.file)
      lines[#lines + 1] = ("  %s %s"):format(where, safe(f.msg or ""))
    end
    if total > shown then
      lines[#lines + 1] = ("... and %d more"):format(total - shown)
    end
  end
  local name = c.name and c.name ~= "" and c.name or c.id
  local title = safe(name)
  if stale then
    title = title .. " (outdated)"
  end
  local highlight
  if stale then
    highlight = M.HL_WARN
  elseif BAD[c.status] then
    highlight = M.HL_ERROR
  end
  return { lines = lines, title = title, highlight = highlight }
end

---Counts by status as "2 pass, 1 fail".
---@param counts table<string, integer>
---@return string
local function count_words(counts)
  local parts = {}
  for _, status in ipairs({ "pass", "fail", "error", "timeout", "crash", "xpass", "xfail", "skip" }) do
    local n = counts[status]
    if n and n > 0 then
      parts[#parts + 1] = ("%d %s"):format(n, status)
    end
  end
  return table.concat(parts, ", ")
end

---Summary lines of a set of cases (a spec file or one describe block).
---@param title string
---@param cases Testing.State.Case[]
---@param ts? number
---@param stale boolean
---@param why? string
---@param now number
---@return Testing.Hover.Content
local function describe_cases(title, cases, ts, stale, why, now)
  local counts, failed, total_ms = {}, {}, 0
  local slow
  for _, c in ipairs(cases) do
    counts[c.status] = (counts[c.status] or 0) + 1
    total_ms = total_ms + c.duration_ms
    if BAD[c.status] then
      failed[#failed + 1] = c.id
    end
    if not slow or c.duration_ms > slow.duration_ms then
      slow = c
    end
  end
  local verb = stale and "was" or "is"
  local lines = {
    ("%d case(s) %s: %s - %s, %s"):format(
      #cases,
      verb,
      count_words(counts),
      duration(total_ms),
      M.ago(ts, now)
    ),
  }
  if stale then
    lines[#lines + 1] = ("outdated: %s"):format(WHY[why or ""] or "unknown")
  end
  if slow and #cases > 1 then
    lines[#lines + 1] = ("slowest: %s (%s)"):format(
      safe(slow.name or slow.id),
      duration(slow.duration_ms)
    )
  end
  for i, id in ipairs(failed) do
    if i > 8 then
      lines[#lines + 1] = ("... and %d more"):format(#failed - 8)
      break
    end
    lines[#lines + 1] = "red: " .. safe(id)
  end
  local highlight
  if stale then
    highlight = M.HL_WARN
  elseif #failed > 0 then
    highlight = M.HL_ERROR
  end
  return {
    lines = lines,
    title = safe(title) .. (stale and " (outdated)" or ""),
    highlight = highlight,
  }
end

---Content of one spec file.
---@param file string
---@param sum Testing.State.FileSummary|nil
---@param now number
---@param cases? Testing.State.Case[]  The cases of the file (for the slowest one).
---@return Testing.Hover.Content
function M.describe_file(file, sum, now, cases)
  if not sum then
    return M.not_run(file)
  end
  if cases and #cases > 0 then
    return describe_cases(file, cases, sum.ts, sum.stale, sum.stale_reason, now)
  end
  -- A summary without the cases (kept for callers that only have the summary).
  local parts = count_words(sum.counts)
  local lines = {
    ("%d case(s) %s: %s - %s, %s"):format(
      sum.total,
      sum.stale and "was" or "is",
      parts,
      duration(sum.duration_ms),
      M.ago(sum.ts, now)
    ),
  }
  if sum.stale then
    lines[#lines + 1] = ("outdated: %s"):format(WHY[sum.stale_reason or ""] or "unknown")
  end
  for i, id in ipairs(sum.failed) do
    if i > 8 then
      lines[#lines + 1] = ("... and %d more"):format(#sum.failed - 8)
      break
    end
    lines[#lines + 1] = "red: " .. safe(id)
  end
  return {
    lines = lines,
    title = safe(file) .. (sum.stale and " (outdated)" or ""),
    highlight = sum.stale and M.HL_WARN or (#sum.failed > 0 and M.HL_ERROR or nil),
  }
end

---Content of a describe block: the cases below it.
---@param name string  Describe path joined for the title.
---@param cases Testing.State.Case[]
---@param file_ts? number
---@param stale boolean
---@param why? string
---@param now number
---@return Testing.Hover.Content
function M.describe_group(name, cases, file_ts, stale, why, now)
  return describe_cases(name, cases, file_ts, stale, why, now)
end

---A spec file or a case without a recorded result: said, not silent.
---@param what string  Path or case name.
---@param hint? string
---@return Testing.Hover.Content
function M.not_run(what, hint)
  return {
    lines = { "not run yet - " .. (hint or "run :Testing file") },
    title = safe(what),
    highlight = M.HL_WARN,
  }
end

---`s` cut to at most `width` display columns, "..." marking the cut.
---@param s string
---@param width integer
---@return string
local function cut_to(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local n = vim.fn.strchars(s)
  while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, n) .. "...") > width do
    n = n - 1
  end
  return vim.fn.strcharpart(s, 0, n) .. "..."
end

---Cut the content to the configured height and width (display columns).
---@param content Testing.Hover.Content
---@param limits? Testing.Hover.Limits
---@return Testing.Hover.Content
function M.fit(content, limits)
  limits = lim(limits)
  local out = {}
  for i, l in ipairs(content.lines) do
    if i > limits.height then
      out[#out] = "..."
      break
    end
    out[#out + 1] = cut_to((l:gsub("[\r\n]", " ")), limits.width)
  end
  return {
    lines = out,
    title = cut_to(content.title, math.max(8, limits.width - 2)),
    highlight = content.highlight,
  }
end

return M
