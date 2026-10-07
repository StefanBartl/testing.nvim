---@module 'testing.surface.coverage'
---@brief Pure functions: surface x hits -> coverage, thresholds, baseline and diff, IR and sink input.
---@description
--- Nothing here touches the editor state (only `ids.norm_lhs` asks `nvim_replace_termcodes` to compare
--- two spellings of one key), so every function is testable with plain tables.
---
--- Hits (`Testing.Surface.Hits`) come from
---   * the Result-IR: `cases[].surface = { hit = { id, ... } }` (`from_ir`), and
---   * the sink of a tracked run: JSON lines `{ k = "case"|"run", id?, file?, hit, counts?, wrapped? }`
---     (`from_sink_text`, `from_sink`).
---
--- Status of an entry:
---   hit        exercised by at least one case
---   missing    trackable, tracked, never exercised
---   untracked  trackable, but no run ever wrapped its handler (it was created before the tracker was
---              installed, or its handler is a string): NOT in the ratio, never "missing"
---   ignored    matches an `ignore` pattern: NOT in the ratio
---   listed     a kind that cannot be observed at runtime (`config`, `health`): NOT in the ratio
---
--- The ratio is `hit / (hit + missing)` over the kinds asked for (default binding, command, autocmd).

local ids = require("testing.surface.ids")

local M = {}

---@class Testing.Surface.Hits
---@field counts table<string, integer> id -> number of executions (indicative)
---@field hit table<string, true> every id that was exercised
---@field wrapped? table<string, true> ids whose handler carried a wrapper in some run (nil = unknown)
---@field exact? boolean Every run that reported said that nothing existed before its tracker was installed: a handler that no run wrapped was then never created, so it is `missing`, not `untracked`.
---@field not_tracked? boolean The source holds no tracked run at all (an IR without `cases[].surface`): nothing is `missing`, everything is `untracked`.
---@field cases { id?: string, file?: string, hit: string[] }[] per case, when the source says so
---@field notes string[]

---@return Testing.Surface.Hits
function M.new_hits()
  return { counts = {}, hit = {}, cases = {}, notes = {} }
end

---Merge `b` into `a`.
---@param a Testing.Surface.Hits
---@param b Testing.Surface.Hits
---@return Testing.Surface.Hits a
function M.merge(a, b)
  for id, n in pairs(b.counts) do
    a.counts[id] = (a.counts[id] or 0) + n
  end
  for id in pairs(b.hit) do
    a.hit[id] = true
  end
  if b.exact ~= nil then
    a.exact = (a.exact ~= false) and b.exact
  end
  -- untracked only while EVERY source is: one tracked run is evidence
  if a.not_tracked == nil then
    a.not_tracked = b.not_tracked == true
  else
    a.not_tracked = a.not_tracked and b.not_tracked == true
  end
  if b.wrapped then
    a.wrapped = a.wrapped or {}
    for id in pairs(b.wrapped) do
      a.wrapped[id] = true
    end
  end
  for _, c in ipairs(b.cases) do
    a.cases[#a.cases + 1] = c
  end
  for _, n in ipairs(b.notes) do
    a.notes[#a.notes + 1] = n
  end
  return a
end

---@param v any
---@return string[]
local function string_list(v)
  local out = {}
  if type(v) == "table" then
    for _, s in ipairs(v) do
      if type(s) == "string" then
        out[#out + 1] = s
      end
    end
  end
  return out
end

---Hits of a Result-IR: every `cases[].surface.hit` (and `ir.surface.wrapped` when the run said so).
---@param ir table
---@return Testing.Surface.Hits
function M.from_ir(ir)
  local hits = M.new_hits()
  if type(ir) ~= "table" then
    return hits
  end
  local saw = false
  for _, c in ipairs(type(ir.cases) == "table" and ir.cases or {}) do
    local s = type(c) == "table" and c.surface or nil
    if type(s) == "table" then
      saw = true
      local list = string_list(s.hit)
      for _, id in ipairs(list) do
        hits.hit[id] = true
        hits.counts[id] = (hits.counts[id] or 0) + 1
      end
      hits.cases[#hits.cases + 1] = { id = c.id, file = c.file, hit = list }
    end
  end
  if not saw then
    hits.not_tracked = true
    hits.notes[#hits.notes + 1] =
      "the IR has no cases[].surface: the run was not tracked (surface.track = true); no entry is counted as missing"
  end
  local top = type(ir.surface) == "table" and ir.surface or nil
  if top and top.exact ~= nil then
    hits.exact = top.exact == true
  end
  if top and type(top.wrapped) == "table" then
    hits.wrapped = {}
    for _, id in ipairs(string_list(top.wrapped)) do
      hits.wrapped[id] = true
    end
  end
  return hits
end

---Hits of a sink (JSON lines written by `testing.surface.track`).
---@param text string
---@return Testing.Surface.Hits
function M.from_sink_text(text)
  local hits = M.new_hits()
  local case_counts, run_counts = {}, {}
  local bad, runs, dirty = 0, 0, 0
  for line in tostring(text):gmatch("[^\r\n]+") do
    local ok, rec = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(rec) == "table" then
      local list = string_list(rec.hit)
      if rec.k == "case" then
        for _, id in ipairs(list) do
          hits.hit[id] = true
          local n = type(rec.counts) == "table" and tonumber(rec.counts[id]) or 1
          case_counts[id] = (case_counts[id] or 0) + (n or 1)
        end
        hits.cases[#hits.cases + 1] = { id = rec.id, file = rec.file, hit = list }
      elseif rec.k == "run" then
        runs = runs + 1
        local ex = type(rec.existing) == "table" and rec.existing or {}
        if (tonumber(ex.commands) or 0) > 0 or (tonumber(ex.autocmds) or 0) > 0 then
          dirty = dirty + 1
        end
        for _, id in ipairs(list) do
          hits.hit[id] = true
          local n = type(rec.counts) == "table" and tonumber(rec.counts[id]) or 1
          run_counts[id] = (run_counts[id] or 0) + (n or 1)
        end
        if rec.file or #list > 0 then
          hits.cases[#hits.cases + 1] = { id = nil, file = rec.file, hit = list, run = true }
        end
        if type(rec.wrapped) == "table" then
          hits.wrapped = hits.wrapped or {}
          for _, id in ipairs(string_list(rec.wrapped)) do
            hits.wrapped[id] = true
          end
        end
      end
    else
      bad = bad + 1
    end
  end
  for id, n in pairs(run_counts) do
    hits.counts[id] = case_counts[id] or n
  end
  for id, n in pairs(case_counts) do
    hits.counts[id] = n
  end
  if runs > 0 then
    hits.exact = dirty == 0
  end
  if bad > 0 then
    hits.notes[#hits.notes + 1] = ("%d line(s) of the sink are not JSON and were skipped"):format(
      bad
    )
  end
  return hits
end

---Most bytes of an input file (a Result-IR, a sink, a baseline) that is read: a file is data from a run
---and must not be able to exhaust the editor.
M.MAX_BYTES = 64 * 1024 * 1024

---Read a whole file, refusing one that is larger than `MAX_BYTES`.
---@param path string
---@return string|nil text
---@return string|nil err
function M.read_bounded(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local size = f:seek("end")
  if size and size > M.MAX_BYTES then
    f:close()
    return nil, ("%s is larger than %d bytes"):format(path, M.MAX_BYTES)
  end
  f:seek("set", 0)
  local text = f:read("*a")
  f:close()
  return text
end

---@param path string
---@return Testing.Surface.Hits|nil
---@return string|nil err
function M.from_sink(path)
  local text, err = M.read_bounded(path)
  if not text then
    return nil, err
  end
  return M.from_sink_text(text)
end

-- ===========================================================
-- coverage
-- ===========================================================

---@param id string
---@param patterns string[]|nil
---@return boolean
local function ignored(id, patterns)
  for _, p in ipairs(patterns or {}) do
    local ok, found = pcall(string.find, id, p)
    if ok and found then
      return true
    end
  end
  return false
end

---Does a hit on a binding with another spelling / mode set belong to this entry?
---@param entry Testing.Surface.Entry
---@param by_lhs table<string, string[]> normalized lhs -> hit ids
---@return boolean
local function binding_hit(entry, by_lhs)
  local d = entry.detail or {}
  if not d.lhs then
    return false
  end
  for _, hid in ipairs(by_lhs[ids.norm_lhs(d.lhs)] or {}) do
    local _, modes = ids.parse_binding(hid)
    for _, m in ipairs(modes or {}) do
      if vim.tbl_contains(d.modes or { "n" }, m) then
        return true
      end
    end
  end
  return false
end

---@param set table<string, true>|nil
---@return table<string, string[]>
local function binding_index(set)
  local by_lhs = {}
  for id in pairs(set or {}) do
    local lhs = ids.parse_binding(id)
    if lhs then
      local k = ids.norm_lhs(lhs)
      by_lhs[k] = by_lhs[k] or {}
      by_lhs[k][#by_lhs[k] + 1] = id
    end
  end
  return by_lhs
end

---@param ratio_total integer
---@param n integer
---@return number|nil
local function ratio(n, ratio_total)
  if ratio_total == 0 then
    return nil
  end
  return n / ratio_total
end

---@class Testing.Surface.CoverageOpts
---@field kinds? string[] Kinds that make up the ratio (default `ids.COVERAGE_KINDS`).
---@field ignore? string[] Lua patterns on ids that are left out of the ratio.

---@class Testing.Surface.CoverageEntry
---@field id string
---@field kind string
---@field name string
---@field src? string
---@field desc? string
---@field status "hit"|"missing"|"untracked"|"ignored"|"listed"
---@field count integer

---@class Testing.Surface.Coverage
---@field plugin string
---@field kinds string[]
---@field total integer hit + missing
---@field hit integer
---@field ratio number|nil nil when there is nothing to cover
---@field missing string[]
---@field untracked string[]
---@field extra string[] hit ids of the asked kinds that are not in the surface
---@field by_kind table<string, { total: integer, hit: integer, ratio: number|nil, missing: string[], untracked: integer }>
---@field entries Testing.Surface.CoverageEntry[]

---Coverage of a surface by a set of hits.
---@param surface Testing.Surface.Surface
---@param hits Testing.Surface.Hits
---@param opts? Testing.Surface.CoverageOpts
---@return Testing.Surface.Coverage
function M.compute(surface, hits, opts)
  opts = opts or {}
  local kinds = opts.kinds or ids.COVERAGE_KINDS
  local want = {}
  for _, k in ipairs(kinds) do
    want[k] = true
  end
  local alias_of = {}
  for _, e in ipairs(surface.entries) do
    for _, alias in ipairs(e.aliases or {}) do
      alias_of[alias] = e.id
    end
  end
  local function entry_hit(e)
    if hits.hit[e.id] then
      return true
    end
    for _, alias in ipairs(e.aliases or {}) do
      if hits.hit[alias] then
        return true
      end
    end
    return false
  end
  local function entry_wrapped(e)
    if not hits.wrapped then
      return nil
    end
    if hits.wrapped[e.id] then
      return true
    end
    for _, alias in ipairs(e.aliases or {}) do
      if hits.wrapped[alias] then
        return true
      end
    end
    return false
  end
  local hit_lhs = binding_index(hits.hit)
  local wrapped_lhs = binding_index(hits.wrapped)
  local cov = {
    plugin = surface.plugin,
    kinds = vim.deepcopy(kinds),
    total = 0,
    hit = 0,
    missing = {},
    untracked = {},
    extra = {},
    by_kind = {},
    entries = {},
  }
  for _, k in ipairs(kinds) do
    cov.by_kind[k] = { total = 0, hit = 0, missing = {}, untracked = 0 }
  end
  local known = {}
  for _, e in ipairs(surface.entries) do
    known[e.id] = true
    local status
    if not ids.TRACKABLE[e.kind] then
      status = "listed"
    elseif want[e.kind] and ignored(e.id, opts.ignore) then
      status = "ignored"
    elseif entry_hit(e) or (e.kind == "binding" and binding_hit(e, hit_lhs)) then
      status = "hit"
    elseif (e.detail and e.detail.untrackable) or hits.not_tracked then
      -- a run that was not tracked at all (an IR without `cases[].surface`) measured nothing: "missing" would be
      -- a claim about a spec that never had the chance to hit anything
      status = "untracked"
    else
      local wrapped = entry_wrapped(e)
      if
        wrapped == false
        and not hits.exact
        and not (e.kind == "binding" and binding_hit(e, wrapped_lhs))
      then
        status = "untracked"
      else
        status = "missing"
      end
    end
    cov.entries[#cov.entries + 1] = {
      id = e.id,
      kind = e.kind,
      name = e.name,
      src = e.src,
      desc = e.desc,
      status = status,
      count = hits.counts[e.id] or 0,
    }
    local bk = cov.by_kind[e.kind]
    if bk then
      if status == "hit" then
        bk.total = bk.total + 1
        bk.hit = bk.hit + 1
        cov.total = cov.total + 1
        cov.hit = cov.hit + 1
      elseif status == "missing" then
        bk.total = bk.total + 1
        bk.missing[#bk.missing + 1] = e.id
        cov.total = cov.total + 1
        cov.missing[#cov.missing + 1] = e.id
      elseif status == "untracked" then
        bk.untracked = bk.untracked + 1
        cov.untracked[#cov.untracked + 1] = e.id
      end
    end
  end
  for _, bk in pairs(cov.by_kind) do
    bk.ratio = ratio(bk.hit, bk.total)
  end
  cov.ratio = ratio(cov.hit, cov.total)
  for id in pairs(hits.hit) do
    local kind = ids.kind_of(id)
    if kind and want[kind] and not known[id] and not alias_of[id] then
      -- a binding hit under another spelling of an entry is no stranger
      local lhs, modes = ids.parse_binding(id)
      local matched = false
      if lhs then
        local k = ids.norm_lhs(lhs)
        for _, e in ipairs(surface.entries) do
          if
            e.kind == "binding"
            and e.detail
            and e.detail.lhs
            and ids.norm_lhs(e.detail.lhs) == k
          then
            for _, m in ipairs(modes or {}) do
              if vim.tbl_contains(e.detail.modes or { "n" }, m) then
                matched = true
              end
            end
          end
        end
      end
      if not matched then
        cov.extra[#cov.extra + 1] = id
      end
    end
  end
  table.sort(cov.extra)
  return cov
end

---Per spec file: how much of the surface its cases exercised.
---@param cov Testing.Surface.Coverage
---@param hits Testing.Surface.Hits
---@return table<string, { hit: integer, total: integer, ratio: number|nil, missing: string[] }>
function M.by_file(cov, hits)
  local counted = {}
  local asked = {}
  for _, k in ipairs(cov.kinds) do
    asked[k] = true
  end
  for _, e in ipairs(cov.entries) do
    if asked[e.kind] and (e.status == "hit" or e.status == "missing") then
      counted[e.id] = e
    end
  end
  local per = {}
  for _, c in ipairs(hits.cases) do
    if type(c.file) == "string" then
      per[c.file] = per[c.file] or {}
      for _, id in ipairs(c.hit) do
        per[c.file][id] = true
      end
    end
  end
  local out = {}
  for file, set in pairs(per) do
    local n, missing = 0, {}
    for id in pairs(counted) do
      if set[id] then
        n = n + 1
      else
        missing[#missing + 1] = id
      end
    end
    table.sort(missing)
    local total = n + #missing
    out[file] = { hit = n, total = total, ratio = ratio(n, total), missing = missing }
  end
  return out
end

-- ===========================================================
-- thresholds
-- ===========================================================

---The thresholds of a run: `coverage.bindings` / `coverage.commands` of `.testing.lua`, the
---`surface.threshold` and the command line (later wins). 0 means report only.
---@param project_cov? table `{ bindings?: number, commands?: number }` (`.testing.lua` `coverage`)
---@param surface_cfg? table `{ threshold?: number }` (`.testing.lua` `surface`)
---@param cli? { overall?: number, kinds?: table<string, number> }
---@return { overall: number, kinds: table<string, number>, problems: string[] }
function M.thresholds(project_cov, surface_cfg, cli)
  local out = { overall = 0, kinds = {}, problems = {} }
  ---A ratio between 0 and 1; anything else (NaN passes every comparison, 7 can never be met) is refused.
  ---@param value any
  ---@param what string
  ---@return number|nil
  local function ratio_of(value, what)
    if type(value) ~= "number" then
      return nil
    end
    if value ~= value or value < 0 or value > 1 then
      out.problems[#out.problems + 1] = ("%s must be a number between 0 and 1, got %s: ignored"):format(
        what,
        tostring(value)
      )
      return nil
    end
    return value
  end
  project_cov = project_cov or {}
  out.kinds.binding = ratio_of(project_cov.bindings, "coverage.bindings")
  out.kinds.command = ratio_of(project_cov.commands, "coverage.commands")
  out.kinds.autocmd = ratio_of(project_cov.autocmds, "coverage.autocmds")
  if surface_cfg then
    out.overall = ratio_of(surface_cfg.threshold, "surface.threshold") or 0
  end
  if cli then
    out.overall = ratio_of(cli.overall, "--threshold") or out.overall
    for k, v in pairs(cli.kinds or {}) do
      out.kinds[k] = ratio_of(v, "the threshold of " .. tostring(k)) or out.kinds[k]
    end
  end
  return out
end

---@class Testing.Surface.Failure
---@field scope string `overall` or a kind
---@field ratio number|nil
---@field threshold number
---@field total integer
---@field reason? string Why a threshold failed without a ratio ("not measurable").

---Which thresholds are not met. A threshold of 0 never fails. A scope with nothing measured does not pass by
---default: when its entries are all `untracked` (the tracking was installed too late, or the script dialect is not
---tracked) or the surface holds no entry at all, the ratio does not exist, and "no ratio" is not "above the
---threshold": it FAILS with the reason. Only a scope whose surface really is empty (a kind the plugin does not
---have) passes.
---@param cov Testing.Surface.Coverage
---@param thresholds { overall: number, kinds: table<string, number> }
---@return Testing.Surface.Failure[]
function M.check(cov, thresholds)
  local failures = {}
  local overall = thresholds.overall or 0
  if overall > 0 then
    if cov.ratio then
      if cov.ratio + 1e-9 < overall then
        failures[#failures + 1] =
          { scope = "overall", ratio = cov.ratio, threshold = overall, total = cov.total }
      end
    elseif #cov.untracked > 0 then
      failures[#failures + 1] = {
        scope = "overall",
        threshold = overall,
        total = 0,
        reason = ("not measurable: %d entr%s untracked"):format(
          #cov.untracked,
          #cov.untracked == 1 and "y is" or "ies are"
        ),
      }
    elseif #cov.entries == 0 then
      failures[#failures + 1] = {
        scope = "overall",
        threshold = overall,
        total = 0,
        reason = "not measurable: no entry of the surface was read",
      }
    end
  end
  local kinds = vim.tbl_keys(thresholds.kinds or {})
  table.sort(kinds)
  for _, k in ipairs(kinds) do
    local t = thresholds.kinds[k]
    local bk = cov.by_kind[k]
    if t > 0 and bk then
      if bk.ratio then
        if bk.ratio + 1e-9 < t then
          failures[#failures + 1] = { scope = k, ratio = bk.ratio, threshold = t, total = bk.total }
        end
      elseif bk.untracked > 0 then
        failures[#failures + 1] = {
          scope = k,
          threshold = t,
          total = 0,
          reason = ("not measurable: %d entr%s untracked"):format(
            bk.untracked,
            bk.untracked == 1 and "y is" or "ies are"
          ),
        }
      end
    end
  end
  return failures
end

-- ===========================================================
-- baseline
-- ===========================================================

---Digest of the entries of a baseline: `sha256` over the sorted `id=status` lines. A run writes it next to the
---entries; a reader that finds a different one knows the file was edited since (by hand or by another tool).
---@param entries table<string, string>
---@return string
function M.baseline_digest(entries)
  local names = vim.tbl_keys(entries)
  table.sort(names)
  local lines = {}
  for _, id in ipairs(names) do
    lines[#lines + 1] = id .. "=" .. tostring(entries[id])
  end
  return vim.fn.sha256(table.concat(lines, "\n"))
end

---What a reader can say about a parsed baseline: `signed` (the digest matches the entries), `edited` (it does
---not), `unsigned` (the file has no digest: an older version, or written by hand).
---@param base table
---@return "signed"|"edited"|"unsigned"
function M.baseline_state(base)
  if type(base.digest) ~= "string" then
    return "unsigned"
  end
  return base.digest == M.baseline_digest(base.entries) and "signed" or "edited"
end

---The baseline of a coverage: the status of every entry that counts.
---@param cov Testing.Surface.Coverage
---@return table
function M.baseline(cov)
  local statuses = {}
  for _, e in ipairs(cov.entries) do
    if e.status == "hit" or e.status == "missing" then
      statuses[e.id] = e.status
    end
  end
  return {
    version = 1,
    plugin = cov.plugin,
    ratio = cov.ratio,
    total = cov.total,
    digest = M.baseline_digest(statuses),
    entries = statuses,
  }
end

---@param text string
---@return table|nil baseline
---@return string|nil err
function M.parse_baseline(text)
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" or type(data.entries) ~= "table" then
    return nil, "the baseline is not a surface baseline (no `entries`)"
  end
  if data.version ~= 1 then
    return nil, ("the baseline has version %s, expected 1"):format(tostring(data.version))
  end
  return data
end

---@class Testing.Surface.Diff
---@field regressions string[] hit in the baseline, not hit now (the entry still exists)
---@field removed string[] hit in the baseline, gone from the surface
---@field new_missing string[] not in the baseline and not hit now
---@field fixed string[] missing in the baseline, hit now
---@field new_hit string[] not in the baseline, hit now
---@field ratio_before number|nil
---@field ratio_after number|nil

---Compare a coverage with a baseline.
---@param base table from `parse_baseline`
---@param cov Testing.Surface.Coverage
---@return Testing.Surface.Diff
function M.diff(base, cov)
  local now, exists = {}, {}
  for _, e in ipairs(cov.entries) do
    exists[e.id] = true
    now[e.id] = e.status
  end
  local d = {
    regressions = {},
    removed = {},
    new_missing = {},
    fixed = {},
    new_hit = {},
    ratio_before = base.ratio,
    ratio_after = cov.ratio,
  }
  for id, status in pairs(base.entries) do
    if status == "hit" then
      if not exists[id] then
        d.removed[#d.removed + 1] = id
      elseif now[id] ~= "hit" then
        d.regressions[#d.regressions + 1] = id
      end
    elseif status == "missing" and now[id] == "hit" then
      d.fixed[#d.fixed + 1] = id
    end
  end
  for id, status in pairs(now) do
    if base.entries[id] == nil then
      if status == "missing" then
        d.new_missing[#d.new_missing + 1] = id
      elseif status == "hit" then
        d.new_hit[#d.new_hit + 1] = id
      end
    end
  end
  for _, list in pairs({ d.regressions, d.removed, d.new_missing, d.fixed, d.new_hit }) do
    table.sort(list)
  end
  return d
end

-- ===========================================================
-- IR
-- ===========================================================

---Put the aggregate into a Result-IR: `ir.surface = { plugin, total, hit, ratio, missing, kinds, files }`.
---Per case, `cases[].surface = { hit = {...} }` is written by the run itself; this adds the aggregate.
---@param ir table
---@param cov Testing.Surface.Coverage
---@param files? table from `by_file`
---@param hits? Testing.Surface.Hits adds `exact` and `wrapped`, which `from_ir` reads back
---@return table ir
function M.annotate_ir(ir, cov, files, hits)
  local kinds = {}
  for k, bk in pairs(cov.by_kind) do
    kinds[k] = { total = bk.total, hit = bk.hit, ratio = bk.ratio, untracked = bk.untracked }
  end
  ir.surface = {
    plugin = cov.plugin,
    total = cov.total,
    hit = cov.hit,
    ratio = cov.ratio,
    missing = cov.missing,
    untracked = cov.untracked,
    kinds = kinds,
    files = files,
  }
  if hits then
    ir.surface.exact = hits.exact
    if hits.wrapped then
      local wrapped = vim.tbl_keys(hits.wrapped)
      table.sort(wrapped)
      ir.surface.wrapped = wrapped
    end
  end
  return ir
end

return M
