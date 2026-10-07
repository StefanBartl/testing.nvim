---@module 'testing.report.verdict'
---@brief The three-valued verdict of a run: `green`, `green-partial`, `red`, and the one line every reporter shares.
---@description
--- A run is `green` when every spec file ran green in this run or has a valid cache hit (exactly the
--- run that prints the sentinel), `green-partial` when it exited 0 but did not look at everything (a
--- selection, a case filter, a skipped case: no sentinel), and `red` when the exit code is not 0.
--- The exit code itself is not touched by any of this (0 green and partial, 1 red, 2 and 3 as before).
---
--- `build` is pure. The run driver fills the facts and stores the result as `run.verdict` of the IR, so
--- every reporter (and the `--json` file) reads the same data; a reporter handed an IR without it
--- derives a smaller verdict from the cases with `from_result`.
---
--- Rule of thumb for the reader: `green` is the only value that may be taken as "everything is fine"; a
--- shortened report (a reporter budget) never changes the kind, which is decided before any cut.

local util = require("testing.report.util")

local M = {}

---@alias Testing.Verdict.Kind "green"|"green-partial"|"red"

---@type Testing.Verdict.Kind[]
M.KINDS = { "green", "green-partial", "red" }

---Most changed files a red verdict names (the count is always complete).
M.MAX_CHANGED = 12

---@class Testing.Verdict.Facts
---@field exit_code integer Exit code of the run (0 or 1 here).
---@field files_total integer Spec files the discovery found.
---@field files_selected integer Spec files that were selected for this run.
---@field files_cached integer Selected files whose result came from the cache.
---@field files_unrun? integer Selected files a `--maxfail` stop left unrun.
---@field cases_total integer
---@field cases_skipped integer
---@field selection? string What narrowed the files (`--changed`, `--since <rev>`, `--shard 1/2`, a path), for the reason text.
---@field case_selection? boolean A case selection (`--filter`, `--tags`, `--lf`) applied.
---@field last_green? { ts: integer, sha?: string } The last full green run (red only).
---@field changed_since? { count: integer, files: string[] } What changed since then (red only).

---@class Testing.Verdict
---@field kind Testing.Verdict.Kind
---@field exit_code integer
---@field files { total: integer, selected: integer, cached: integer, ran: integer, skipped: integer, unrun: integer }
---@field cases { total: integer, skipped: integer }
---@field reasons? string[] Why a run is not `green` (partial only).
---@field last_green? { ts: integer, sha?: string }
---@field changed_since? { count: integer, files: string[] }
---@field derived? boolean Built from the cases alone (`from_result`), not by the run driver.

---@param n any
---@return integer
local function int(n)
  n = tonumber(n) or 0
  if n ~= n or n < 0 then
    return 0
  end
  return math.floor(n)
end

---Build the verdict from the facts of a run.
---@param f Testing.Verdict.Facts
---@return Testing.Verdict
function M.build(f)
  local total, selected = int(f.files_total), int(f.files_selected)
  local cached, unrun = int(f.files_cached), int(f.files_unrun)
  if selected > total then
    total = selected
  end
  local skipped = total - selected
  local v = {
    kind = "green",
    exit_code = int(f.exit_code),
    files = {
      total = total,
      selected = selected,
      cached = cached,
      ran = math.max(0, selected - cached - unrun),
      skipped = skipped,
      unrun = unrun,
    },
    cases = { total = int(f.cases_total), skipped = int(f.cases_skipped) },
  }
  if v.exit_code ~= 0 then
    v.kind = "red"
    v.last_green = f.last_green
    v.changed_since = f.changed_since
    return v
  end
  local reasons = {}
  if skipped > 0 then
    reasons[#reasons + 1] = ("%d spec file(s) not selected%s"):format(
      skipped,
      f.selection and (" (" .. f.selection .. ")") or ""
    )
  end
  if unrun > 0 then
    reasons[#reasons + 1] = ("%d spec file(s) not run (stopped)"):format(unrun)
  end
  if f.case_selection then
    reasons[#reasons + 1] = "a case selection (--filter, --tags, --exclude-tags, --lf) applied"
  end
  if v.cases.skipped > 0 then
    reasons[#reasons + 1] = ("%d case(s) skipped: a skip is never green"):format(v.cases.skipped)
  end
  if #reasons > 0 then
    v.kind = "green-partial"
    v.reasons = reasons
  end
  return v
end

---A verdict from the cases alone, for an IR that carries none (a file read back, a hand-built IR). It cannot
---know about files the run never saw, so it never claims what only the driver knows (`skipped` stays 0).
---@param result Testing.Result
---@return Testing.Verdict
function M.from_result(result)
  local files, cached_files = {}, {}
  local nfiles, ncached = 0, 0
  local bad, skipped = 0, 0
  for _, c in ipairs(result.cases or {}) do
    local file = c.file or "?"
    if not files[file] then
      files[file] = true
      cached_files[file] = true
      nfiles = nfiles + 1
    end
    if not c.cached then
      cached_files[file] = false
    end
    local cls = util.class_of(c.status)
    if cls == "bad" then
      bad = bad + 1
    elseif cls == "skip" then
      skipped = skipped + 1
    end
  end
  for _, is_cached in pairs(cached_files) do
    if is_cached then
      ncached = ncached + 1
    end
  end
  local v = M.build({
    exit_code = bad > 0 and 1 or 0,
    files_total = nfiles,
    files_selected = nfiles,
    files_cached = ncached,
    cases_total = #(result.cases or {}),
    cases_skipped = skipped,
  })
  v.derived = true -- the driver's facts (last green run, what was not selected) are not known here
  return v
end

---The verdict of an IR: the one the driver stored, else one derived from the cases.
---@param result Testing.Result
---@return Testing.Verdict
function M.of(result)
  local v = result.run and result.run.verdict
  if type(v) == "table" and (v.kind == "green" or v.kind == "green-partial" or v.kind == "red") then
    return v
  end
  return M.from_result(result)
end

---`n from cache, m ran, k skipped on purpose`
---@param v Testing.Verdict
---@return string
function M.counts(v)
  return ("%d from cache, %d ran, %d skipped on purpose"):format(
    int(v.files and v.files.cached),
    int(v.files and v.files.ran),
    int(v.files and v.files.skipped)
  )
end

---UTC time as `2026-10-07 12:00:03Z` (UTC: the line is the same on every machine).
---@param ts integer
---@return string
local function stamp(ts)
  return os.date("!%Y-%m-%d %H:%M:%SZ", ts) --[[@as string]]
end

---The line that names the verdict, shared by the reporters. All of it is data of the run driver; the file
---names in `changed_since` come from git and are cleaned.
---@param v Testing.Verdict
---@return string
function M.line(v)
  local line = ("verdict: %s (%s; %d spec file(s))"):format(
    v.kind,
    M.counts(v),
    int(v.files and v.files.total)
  )
  if v.kind == "green-partial" then
    line = line .. ": " .. table.concat(v.reasons or {}, "; ") .. "; no sentinel"
  end
  return line
end

---`last green run: <time> at <sha>` and the files that changed since, for a red verdict; empty otherwise.
---@param v Testing.Verdict
---@return string[]
function M.red_lines(v)
  if v.kind ~= "red" or v.derived then
    return {}
  end
  local g = v.last_green
  if type(g) ~= "table" or type(g.ts) ~= "number" then
    return { "last green run: none recorded for this project" }
  end
  local head = "last green run: " .. stamp(g.ts)
  if type(g.sha) == "string" and g.sha ~= "" then
    head = head .. " at " .. util.clean(g.sha:sub(1, 40))
  end
  local c = v.changed_since
  if type(c) ~= "table" then
    return { head .. "; what changed since is unknown (no git facts)" }
  end
  if int(c.count) == 0 then
    return { head .. "; nothing changed since (not even an untracked file)" }
  end
  local names = {}
  for i, name in ipairs(c.files or {}) do
    if i > M.MAX_CHANGED then
      break
    end
    names[#names + 1] = util.clean(tostring(name), { bidi = true, c1 = true })
  end
  local more = int(c.count) - #names
  return {
    ("%s; %d file(s) changed since: %s%s"):format(
      head,
      int(c.count),
      table.concat(names, ", "),
      more > 0 and (", ... %d more"):format(more) or ""
    ),
  }
end

---Cut a changed-file list to what a verdict stores (the count stays complete).
---@param files string[]
---@return { count: integer, files: string[] }
function M.changed_since_of(files)
  local kept = {}
  for i = 1, math.min(#files, M.MAX_CHANGED) do
    kept[i] = files[i]
  end
  return { count = #files, files = kept }
end

return M
