---@module 'testing.report.github'
---@brief GitHub Actions reporter: workflow-command annotations and the step summary.
---@description
--- `render` returns one `::error file=...,line=...,title=...::message` line per failed assertion (or
--- per erroring case). Workflow commands are parsed from stdout by the runner, so the text that goes
--- in is an injection surface (D.8): a case name or a message holding `\n::set-output ...` must
--- never become a second command. The escaping follows the runner's own rules (`@actions/core`):
---
---   * data (the message):   `%` -> `%25`, CR -> `%0D`, LF -> `%0A`
---   * properties (`file`, `title`): additionally `:` -> `%3A` and `,` -> `%2C`
---
--- Other control characters (ESC, NUL, ...) are neutralized first by `util.clean`. GitHub shows at
--- most ten annotations per type per step, so `max_annotations` caps the list and one warning names
--- how many were left out.
---
--- `summary_markdown` / `write_summary` produce the `$GITHUB_STEP_SUMMARY` table; every cell is
--- escaped for Markdown and HTML, and the file is appended to (other steps write to it too), never
--- replaced.

local util = require("testing.report.util")
local result_mod = require("testing.core.result")

local M = {}

---@class Testing.Report.GithubOpts
---@field max_annotations? integer Annotations emitted at most (default 10).
---@field annotate_skips? boolean Also emit `::warning` for skipped cases (default false).
---@field summary? boolean Let the registry write the step summary (default true).
---@field summary_path? string Step summary file; default `$GITHUB_STEP_SUMMARY`.
---@field env? table<string, string|nil> Environment to read instead of the real one (tests).
---@field summary_max_bytes? integer Cap of what is appended (default 900000; GitHub allows 1 MiB).

---@type Testing.Report.GithubOpts
M.DEFAULTS =
  { max_annotations = 10, annotate_skips = false, summary = true, summary_max_bytes = 900000 }

---Escape the data part of a workflow command (the message).
---@param s any
---@return string
function M.escape_data(s)
  s = util.clean(tostring(s), { keep = { [10] = true, [13] = true }, c1 = true, bidi = true })
  return (s:gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A"))
end

---Escape a property value (`file`, `line`, `title`): data escaping plus `:` and `,`.
---@param s any
---@return string
function M.escape_property(s)
  return (M.escape_data(s):gsub(":", "%%3A"):gsub(",", "%%2C"))
end

---One workflow command line.
---@param level "error"|"warning"|"notice"
---@param props { file?: string, line?: integer, title?: string }
---@param message string
---@return string
function M.command(level, props, message)
  local parts = {}
  if props.file and props.file ~= "" then
    parts[#parts + 1] = "file=" .. M.escape_property(props.file)
  end
  if props.line and props.line >= 1 then
    parts[#parts + 1] = "line=" .. M.escape_property(tostring(math.floor(props.line)))
  end
  if props.title and props.title ~= "" then
    parts[#parts + 1] = "title=" .. M.escape_property(props.title)
  end
  return "::"
    .. level
    .. (#parts > 0 and (" " .. table.concat(parts, ",")) or "")
    .. "::"
    .. M.escape_data(message)
end

---Repo-relative forward-slash path: a `<REPO>/` placeholder or a `./` prefix is dropped.
---@param path string|nil
---@return string|nil
local function annotation_path(path)
  if not path then
    return nil
  end
  path = path:gsub("\\", "/"):gsub("^<REPO>/", ""):gsub("^%./", "")
  return path
end

---@param a Testing.Result.Assertion
---@return string
local function assertion_message(a)
  local msg = a.msg or ("assertion failed (" .. tostring(a.kind) .. ")")
  if a.expected ~= nil or a.actual ~= nil then
    local function cap(v)
      return (util.cap(tostring(v), 500))
    end
    if a.expected ~= nil then
      msg = msg .. "\nexpected: " .. cap(a.expected)
    end
    if a.actual ~= nil then
      msg = msg .. "\nactual: " .. cap(a.actual)
    end
  end
  return msg
end

---The annotation lines for a result.
---@param result Testing.Result
---@param opts? Testing.Report.GithubOpts
---@return string[] lines
function M.render(result, opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts or {})
  local entries = {}
  for _, c in ipairs(result.cases or {}) do
    local cls = util.class_of(c.status)
    local title = c.id or c.file or "case"
    if cls == "bad" then
      local before = #entries
      if c.status == "fail" or c.status == "xpass" then
        for _, a in ipairs(c.assertions or {}) do
          if a.ok == false then
            entries[#entries + 1] = {
              level = "error",
              props = {
                file = annotation_path(a.file or c.file),
                line = a.line or c.line,
                title = title,
              },
              message = assertion_message(a),
            }
          end
        end
        if c.status == "xpass" and #entries == before then
          entries[#entries + 1] = {
            level = "error",
            props = { file = annotation_path(c.file), line = c.line, title = title },
            message = "unexpectedly passed (expected failure)",
          }
        end
      end
      if #entries == before then
        local msg = c.status .. (c.error and (": " .. tostring(c.error.message)) or "")
        entries[#entries + 1] = {
          level = "error",
          props = { file = annotation_path(c.file), line = c.line, title = title },
          message = msg,
        }
      end
    elseif c.status == "skip" and o.annotate_skips then
      entries[#entries + 1] = {
        level = "warning",
        props = { file = annotation_path(c.file), line = c.line, title = title },
        message = "skipped" .. (c.reason and (": " .. c.reason) or ""),
      }
    end
  end
  -- guard findings: a `warn` is a warning annotation on the case's file; an `error` already failed the
  -- case (its failed `guard` assertion is an error annotation above), so it is not repeated
  for _, f in ipairs(util.guard_findings(result)) do
    if f.severity == "warn" then
      entries[#entries + 1] = {
        level = "warning",
        props = {
          file = annotation_path(f.case.file),
          line = f.case.line,
          title = ("%s [%s]"):format(f.case.id or "case", f.guard),
        },
        message = f.message,
      }
    end
  end
  local lines = {}
  local max = o.max_annotations
  for i, e in ipairs(entries) do
    if i > max then
      lines[#lines + 1] = M.command(
        "warning",
        { title = "testing" },
        ("%d more annotation(s) not shown (limit %d)"):format(#entries - max, max)
      )
      break
    end
    lines[#lines + 1] = M.command(e.level, e.props, e.message)
  end
  return lines
end

-- =========================================================
-- Step summary
-- =========================================================

---Escape a value for a Markdown table cell: HTML-significant characters become entities (a test
---name must not become a tag), Markdown punctuation is backslash-escaped, line breaks become spaces.
---@param s any
---@return string
function M.md_escape(s)
  s = util.clean(
    tostring(s),
    { keep = { [9] = true, [10] = true, [13] = true }, c1 = true, bidi = true }
  )
  s = s:gsub("[\t\r\n]+", " ")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  s = s:gsub("[\\`*_%[%]|~$]", "\\%0")
  return s
end

---The step summary as Markdown lines.
---@param result Testing.Result
---@return string[]
function M.summary_markdown(result)
  local counts = result_mod.summarize(result.cases or {})
  local bad = 0
  for status, n in pairs(counts) do
    if util.class_of(status) == "bad" then
      bad = bad + n
    end
  end
  local run = result.run or {}
  local lines = {
    "## testing.nvim: " .. (bad > 0 and "FAILED" or "passed"),
    "",
    "| Status | Cases |",
    "|---|---:|",
  }
  for _, status in ipairs(result_mod.STATUSES) do
    if counts[status] > 0 or status == "pass" then
      lines[#lines + 1] = ("| %s | %d |"):format(status, counts[status])
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "| File | Result | Cases | Time (s) |"
  lines[#lines + 1] = "|---|---|---:|---:|"
  for _, g in ipairs(util.group_by_file(result)) do
    local g_bad, g_skip, ms = 0, 0, 0
    for _, c in ipairs(g.cases) do
      if util.class_of(c.status) == "bad" then
        g_bad = g_bad + 1
      elseif c.status == "skip" then
        g_skip = g_skip + 1
      end
      ms = ms + (c.duration_ms or 0)
    end
    lines[#lines + 1] = ("| %s | %s | %d | %s |"):format(
      M.md_escape(g.file),
      (g_bad > 0 and ("FAIL (" .. g_bad .. ")")) or (g_skip == #g.cases and "skip") or "ok",
      #g.cases,
      util.seconds(ms)
    )
  end
  local failures = {}
  for _, c in ipairs(result.cases or {}) do
    if util.class_of(c.status) == "bad" then
      failures[#failures + 1] = c
    end
  end
  if #failures > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Failures"
    lines[#lines + 1] = ""
    for i, c in ipairs(failures) do
      if i > 25 then
        lines[#lines + 1] = ("- ... %d more"):format(#failures - 25)
        break
      end
      local detail = c.error and c.error.message
      if not detail then
        for _, a in ipairs(c.assertions or {}) do
          if a.ok == false then
            detail = a.msg or a.kind
            break
          end
        end
      end
      lines[#lines + 1] = ("- %s (%s): %s"):format(
        M.md_escape(c.id or "?"),
        c.status,
        M.md_escape(util.cap(tostring(detail or "no detail recorded"), 300))
      )
    end
  end
  local guards = {}
  for _, f in ipairs(util.guard_findings(result)) do
    if f.severity ~= "info" then
      guards[#guards + 1] = f
    end
  end
  if #guards > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "### Guard findings"
    lines[#lines + 1] = ""
    for i, f in ipairs(guards) do
      if i > 25 then
        lines[#lines + 1] = ("- ... %d more"):format(#guards - 25)
        break
      end
      lines[#lines + 1] = ("- %s [%s] %s: %s"):format(
        f.severity == "error" and "FAIL" or "warn",
        M.md_escape(f.guard),
        M.md_escape(f.case.id or "?"),
        M.md_escape(util.cap(tostring(f.message), 300))
      )
    end
  end
  if run.seed ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Seed: `%d`"):format(run.seed)
  end
  return lines
end

---Where the step summary goes: explicit option, else the (injected or real) environment.
---@param o Testing.Report.GithubOpts
---@return string|nil
local function summary_path(o)
  local p = o.summary_path
  if p == nil then
    p = o.env and o.env.GITHUB_STEP_SUMMARY
      or (not o.env and os.getenv("GITHUB_STEP_SUMMARY"))
      or nil
  end
  if type(p) == "string" and p ~= "" then
    return p
  end
  return nil
end

---Append the summary to the step summary file. Appends (other steps share the file) through
---`lib.nvim.fs.write.append`; refuses a path with a NUL byte; caps the size.
---@param result Testing.Result
---@param opts? Testing.Report.GithubOpts
---@return boolean ok
---@return string|nil err Not an error condition when the variable is unset: `false, "..."` names it.
function M.write_summary(result, opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts or {})
  local path = summary_path(o)
  if not path then
    return false, "GITHUB_STEP_SUMMARY is not set"
  end
  if path:find("\0", 1, true) or path:find("[\r\n]") then
    return false, "GITHUB_STEP_SUMMARY is not a valid path"
  end
  local text = table.concat(M.summary_markdown(result), "\n") .. "\n"
  local capped, truncated = util.cap(text, o.summary_max_bytes)
  if truncated then
    capped = capped .. "\n\n_(summary truncated)_\n"
  end
  return require("lib.nvim.fs.write.append")(path, "\n" .. capped)
end

---Registry hook: runs after `render`, writes the step summary when asked and possible.
---@param result Testing.Result
---@param opts? Testing.Report.GithubOpts
---@return boolean|nil ok Nil when not applicable (summary disabled or no variable).
---@return string|nil err
function M.finish(result, opts)
  local o = opts or {}
  if o.summary == false then
    return nil, nil
  end
  if not summary_path(o) then
    return nil, nil
  end
  return M.write_summary(result, opts)
end

return M
