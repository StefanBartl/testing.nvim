---@module 'testing.surface.render'
---@brief Text, markdown and JSON views of a surface report (pure: report in, lines out).
---@description
--- A report (`testing.surface.report`) is
--- `{ plugin, root, surface, coverage?, failures, thresholds, diff?, notes, sources }`; without
--- `coverage` (no tracked run was given) the views list the entries and say so: a status of "missing"
--- would be a claim nobody measured.
---
--- Everything that came from the plugin (names, descriptions, source paths) is data for a terminal and
--- a markdown file: control characters are replaced and a `|` is escaped in a table cell.

local M = {}

---@param s any
---@return string
local function clean(s)
  s = tostring(s == nil and "" or s)
  s = s:gsub("[%c\127]", "?")
  -- bidi controls (U+202A..U+202E, U+2066..U+2069) reorder what a terminal shows
  s = s:gsub("\226\128[\170-\174]", "?"):gsub("\226\129[\166-\169]", "?")
  return s
end

---@param s string
---@return string
local function cell(s)
  return (clean(s):gsub("|", "\\|"))
end

---@param r number|nil
---@return string
local function pct(r)
  if r == nil then
    return "-"
  end
  return ("%.1f%%"):format(r * 100)
end

---@param s string
---@param w integer
---@return string
local function pad(s, w)
  local n = vim.fn.strdisplaywidth(s)
  if n >= w then
    return s
  end
  return s .. string.rep(" ", w - n)
end

---Rows of the entry table: `{ kind, status, count, id, src }`.
---@param report table
---@return string[][]
local function rows(report)
  local out = {}
  if report.coverage then
    for _, e in ipairs(report.coverage.entries) do
      out[#out + 1] = {
        clean(e.kind),
        e.status,
        e.count > 0 and tostring(e.count) or "",
        clean(e.id),
        clean(e.src or ""),
      }
    end
  else
    for _, e in ipairs(report.surface.entries) do
      out[#out + 1] = { clean(e.kind), "-", "", clean(e.id), clean(e.src or "") }
    end
  end
  return out
end

---The summary lines (one per kind and the overall ratio).
---@param report table
---@return string[]
local function summary(report)
  local lines = {}
  local cov = report.coverage
  if not cov then
    local kinds = vim.tbl_keys(report.surface.counts or {})
    table.sort(kinds)
    for _, k in ipairs(kinds) do
      lines[#lines + 1] = ("%-8s %d entries"):format(k, report.surface.counts[k])
    end
    lines[#lines + 1] =
      "no tracked run was given (--from <ir.json> or --hits <file>): nothing is measured"
    return lines
  end
  for _, k in ipairs(cov.kinds) do
    local bk = cov.by_kind[k]
    lines[#lines + 1] = ("%-8s %d/%d  %s%s"):format(
      k,
      bk.hit,
      bk.total,
      pct(bk.ratio),
      bk.untracked > 0 and ("  (%d untracked)"):format(bk.untracked) or ""
    )
  end
  lines[#lines + 1] = ("overall  %d/%d  %s"):format(cov.hit, cov.total, pct(cov.ratio))
  return lines
end

---@param f table
---@return string
local function failure_line(f)
  if f.reason then
    return ("threshold not met: %s needs %s, %s"):format(f.scope, pct(f.threshold), f.reason)
  end
  return ("below threshold: %s %s < %s (%d entries)"):format(
    f.scope,
    pct(f.ratio),
    pct(f.threshold),
    f.total
  )
end

---@param report table
---@return string[]
local function diff_lines(report)
  local d = report.diff
  local out = {}
  if not d then
    return out
  end
  out[#out + 1] = ("baseline: %s -> %s"):format(pct(d.ratio_before), pct(d.ratio_after))
  local function list(title, ids)
    if #ids > 0 then
      out[#out + 1] = ("  %s (%d):"):format(title, #ids)
      for _, id in ipairs(ids) do
        out[#out + 1] = "    " .. clean(id)
      end
    end
  end
  list("regressions: hit before, not hit now", d.regressions)
  list("removed from the surface", d.removed)
  list("new and not exercised", d.new_missing)
  list("now exercised", d.fixed)
  list("new and exercised", d.new_hit)
  if #d.regressions == 0 and #d.removed == 0 and #d.new_missing == 0 then
    out[#out + 1] = "  no regressions"
  end
  return out
end

---The aligned text table.
---@param report table
---@return string
function M.text(report)
  local lines = {}
  lines[#lines + 1] = ("surface: %s (%d entries)"):format(
    clean(report.plugin),
    #report.surface.entries
  )
  local header = { "KIND", "STATUS", "HITS", "ID", "SRC" }
  local data = rows(report)
  local widths = {}
  for i, h in ipairs(header) do
    widths[i] = #h
  end
  for _, r in ipairs(data) do
    for i = 1, 4 do
      widths[i] = math.min(math.max(widths[i], vim.fn.strdisplaywidth(r[i])), 64)
    end
  end
  local function fmt(r)
    return (
      pad(r[1], widths[1])
      .. "  "
      .. pad(r[2], widths[2])
      .. "  "
      .. pad(r[3], widths[3])
      .. "  "
      .. pad(r[4], widths[4])
      .. "  "
      .. r[5]
    ):gsub("%s+$", "")
  end
  lines[#lines + 1] = fmt(header)
  for _, r in ipairs(data) do
    lines[#lines + 1] = fmt(r)
  end
  lines[#lines + 1] = ""
  vim.list_extend(lines, summary(report))
  for _, f in ipairs(report.failures or {}) do
    lines[#lines + 1] = failure_line(f)
  end
  vim.list_extend(lines, diff_lines(report))
  if report.coverage and #report.coverage.extra > 0 then
    local shown = vim.list_slice(report.coverage.extra, 1, 8)
    local more = #report.coverage.extra - #shown
    lines[#lines + 1] = ("exercised but not in the surface (%d): %s%s"):format(
      #report.coverage.extra,
      clean(table.concat(shown, ", ")),
      more > 0 and (", ... +%d"):format(more) or ""
    )
  end
  for _, n in ipairs(report.notes or {}) do
    lines[#lines + 1] = "note: " .. clean(n)
  end
  return table.concat(lines, "\n") .. "\n"
end

---A markdown document: summary table, entry table, regressions.
---@param report table
---@return string
function M.markdown(report)
  local out = {}
  out[#out + 1] = ("# Surface of `%s`"):format(clean(report.plugin))
  out[#out + 1] = ""
  local cov = report.coverage
  if cov then
    out[#out + 1] = "| kind | hit | total | ratio | untracked |"
    out[#out + 1] = "| --- | ---: | ---: | ---: | ---: |"
    for _, k in ipairs(cov.kinds) do
      local bk = cov.by_kind[k]
      out[#out + 1] = ("| %s | %d | %d | %s | %d |"):format(
        k,
        bk.hit,
        bk.total,
        pct(bk.ratio),
        bk.untracked
      )
    end
    out[#out + 1] = ("| **overall** | %d | %d | %s | %d |"):format(
      cov.hit,
      cov.total,
      pct(cov.ratio),
      #cov.untracked
    )
  else
    for _, line in ipairs(summary(report)) do
      out[#out + 1] = "* " .. clean(line)
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = "| status | kind | id | hits | source |"
  out[#out + 1] = "| --- | --- | --- | ---: | --- |"
  for _, r in ipairs(rows(report)) do
    out[#out + 1] = ("| %s | %s | `%s` | %s | %s |"):format(
      cell(r[2]),
      cell(r[1]),
      cell(r[4]),
      r[3],
      cell(r[5])
    )
  end
  local extra = {}
  for _, f in ipairs(report.failures or {}) do
    extra[#extra + 1] = "* " .. failure_line(f)
  end
  for _, l in ipairs(diff_lines(report)) do
    extra[#extra + 1] = l:match("^  ") and ("  * " .. vim.trim(l)) or ("* " .. l)
  end
  for _, n in ipairs(report.notes or {}) do
    extra[#extra + 1] = "* note: " .. clean(n)
  end
  if #extra > 0 then
    out[#out + 1] = ""
    vim.list_extend(out, extra)
  end
  return table.concat(out, "\n") .. "\n"
end

---@param value any
---@return string
local function encode(value)
  local ok, text = pcall(vim.json.encode, value, { sort_keys = true })
  if not ok then
    ok, text = pcall(vim.json.encode, value)
  end
  return ok and text or "{}"
end

---The report as JSON (the entries with their status when a tracked run was given).
---@param report table
---@return string
function M.json(report)
  local cov = report.coverage
  local doc = {
    version = 1,
    plugin = report.plugin,
    entries = cov and cov.entries or report.surface.entries,
    counts = report.surface.counts,
    coverage = cov and {
      total = cov.total,
      hit = cov.hit,
      ratio = cov.ratio,
      missing = cov.missing,
      untracked = cov.untracked,
      extra = cov.extra,
      kinds = cov.by_kind,
    } or nil,
    thresholds = report.thresholds,
    failures = report.failures,
    diff = report.diff,
    notes = report.notes,
    exit_code = report.exit_code,
  }
  return encode(doc) .. "\n"
end

---@param report table
---@param format? "text"|"markdown"|"json"
---@return string
function M.render(report, format)
  if format == "json" then
    return M.json(report)
  elseif format == "markdown" then
    return M.markdown(report)
  end
  return M.text(report)
end

return M
