---@module 'testing.run.profile'
---@brief `--profile`: where the time of a run went (phases, files, cases, histogram, spawn cost, pool use).
---@description
--- Cheap measurement, no sampling: the profile is computed from numbers the run has anyway (the case
--- durations of the IR, the pool statistics, the phase marks of the caller) and costs one `hrtime` per
--- phase edge. It never changes a verdict.
---
--- WHAT IT HOLDS (`Testing.Profile`, also `run.profile` of the IR: additive, the schema stays 1)
---   * `phases`: wall milliseconds of `discovery`, `select`, `run`, `report` and `total`. `report` (reporters,
---     history, everything after the run) is only known after the IR was written, so it is in the text
---     report and NOT in the IR; a phase nobody marked is absent, never zero;
---   * `files`: the slowest files (most `MAX_FILES` = 50): wall milliseconds, number of cases and, when
---     the driver reports them (`report.file_timings`: `spawn_ms`, `load_ms`, `run_ms`), the per-phase
---     split; without that `ms` is the sum of the case durations and `source = "cases"`;
---   * `cases`: the slowest cases (most `MAX_CASES` = 50) with id, status and ms;
---   * `histogram`: how many cases fell into each duration class (`edges_ms` are the upper bounds, the last
---     class is open);
---   * `spawn`: how many child editors were started and what they cost (pool members: `boot_ms` of the
---     pool statistics; a child per file: the `spawn_ms` the driver reports). Absent when the run started
---     no child, or the driver does not measure it (it says `measured = false`);
---   * `pool`: `jobs`, members started, files that reused a member, members discarded and the utilisation
---     (busy time of all files divided by `jobs` times the wall time of the run phase; `approx = true`
---     when the busy time is the sum of case durations, which leaves out the process overhead).
---
--- INSTRUMENTATION IS NEVER NEUTRAL (PRIN-36): the profile of a run with `--profile` is the profile of a
--- run that measures; the overhead is a handful of `hrtime` calls and one pass over the cases.

local M = {}

---Slowest files kept.
M.MAX_FILES = 50
---Slowest cases kept.
M.MAX_CASES = 50
---Upper bounds (ms) of the histogram classes; the last class is open (`>` the last edge).
M.EDGES_MS = { 1, 5, 10, 50, 100, 500, 1000, 5000 }
---Current layout of `Testing.Profile`.
M.VERSION = 1

---@class Testing.Profile.File
---@field file string
---@field ms number
---@field cases integer
---@field source "cases"|"driver"
---@field spawn_ms? number
---@field load_ms? number
---@field run_ms? number

---@class Testing.Profile.Case
---@field id string
---@field ms number
---@field status string

---@class Testing.Profile.Pool
---@field jobs integer
---@field spawned? integer
---@field reused? integer
---@field discarded? integer
---@field boot_ms? number Time spent starting members, summed over members (they start in parallel).
---@field finish_ms? number Time spent restoring and verifying members after files, summed.
---@field utilisation number 0..1 (may exceed 1 by rounding noise only)
---@field approx boolean

---@class Testing.Profile
---@field version integer
---@field phases table<string, number> Wall ms per phase (`discovery`, `select`, `run`, `report`, `total`).
---@field files Testing.Profile.File[]
---@field cases Testing.Profile.Case[]
---@field histogram { edges_ms: number[], counts: integer[] }
---@field spawn? { measured: boolean, count?: integer, total_ms?: number, mean_ms?: number }
---@field pool? Testing.Profile.Pool

---@class Testing.Profile.Collector
---@field clock fun(): number Milliseconds.
---@field marks table<string, { started: number, ms?: number, open?: boolean }>
---@field t0 number
---@field order string[]
local Collector = {}
Collector.__index = Collector

---A collector with an injectable clock (specs).
---@param opts? { clock?: fun(): number } Milliseconds; default `vim.uv.hrtime() / 1e6`.
---@return Testing.Profile.Collector
function M.new(opts)
  local clock = (opts and opts.clock) or function()
    return vim.uv.hrtime() / 1e6
  end
  return setmetatable({ clock = clock, marks = {}, order = {}, t0 = clock() }, Collector)
end

---Start a phase. Starting a phase twice adds up (a watch run, a phase of two parts).
---@param name string
function Collector:begin(name)
  local mark = self.marks[name]
  if not mark then
    mark = { started = 0 }
    self.marks[name] = mark
    self.order[#self.order + 1] = name
  end
  mark.started = self.clock()
  mark.open = true
end

---End a phase; ending one that was never begun is a no-op.
---@param name string
function Collector:finish(name)
  local mark = self.marks[name]
  if not mark or not mark.open then
    return
  end
  mark.open = false
  mark.ms = (mark.ms or 0) + (self.clock() - mark.started)
end

---Time `fn(...)` as phase `name` (closed on error too) and return what it returns.
---@param name string
---@param fn function
---@return any ...
function Collector:time(name, fn, ...)
  self:begin(name)
  local function done(ok, ...)
    self:finish(name)
    if not ok then
      error((...), 0)
    end
    return ...
  end
  return done(pcall(fn, ...))
end

---Milliseconds of a finished phase.
---@param name string
---@return number|nil
function Collector:ms(name)
  local mark = self.marks[name]
  return mark and mark.ms or nil
end

---@param ms number
---@return integer class 1-based class of `EDGES_MS`
local function class_of(ms)
  for i, edge in ipairs(M.EDGES_MS) do
    if ms <= edge then
      return i
    end
  end
  return #M.EDGES_MS + 1
end

---@param x number
---@return number
local function round(x)
  return math.floor(x * 1000 + 0.5) / 1000
end

---Histogram of case durations.
---@param cases Testing.Result.Case[]
---@return { edges_ms: number[], counts: integer[] }
function M.histogram(cases)
  local counts = {}
  for i = 1, #M.EDGES_MS + 1 do
    counts[i] = 0
  end
  for _, c in ipairs(cases) do
    local k = class_of(type(c.duration_ms) == "number" and c.duration_ms or 0)
    counts[k] = counts[k] + 1
  end
  return { edges_ms = vim.list_slice(M.EDGES_MS, 1, #M.EDGES_MS), counts = counts }
end

---Build the profile of a finished run.
---@param res Testing.Result The run (its cases carry the durations).
---@param opts? { phases?: table<string, number>, jobs?: integer, file_timings?: table<string, table>, pool?: table, run_ms?: number }
---@return Testing.Profile
function M.build(res, opts)
  opts = opts or {}
  local per_file, file_order = {}, {}
  for _, c in ipairs(res.cases) do
    local f = per_file[c.file]
    if not f then
      f = { file = c.file, ms = 0, cases = 0, source = "cases" }
      per_file[c.file] = f
      file_order[#file_order + 1] = c.file
    end
    f.ms = f.ms + (type(c.duration_ms) == "number" and c.duration_ms or 0)
    f.cases = f.cases + 1
  end
  local timings = opts.file_timings or {}
  local busy_ms, busy_from_driver = 0, true
  for _, rel in ipairs(file_order) do
    local f = per_file[rel]
    local t = timings[rel]
    if type(t) == "table" then
      for _, key in ipairs({ "spawn_ms", "load_ms", "run_ms" }) do
        if type(t[key]) == "number" then
          f[key] = round(t[key])
        end
      end
      if type(t.wall_ms) == "number" then
        f.ms = t.wall_ms
        f.source = "driver"
      end
    end
    if f.source ~= "driver" then
      busy_from_driver = false
    end
    f.ms = round(f.ms)
    busy_ms = busy_ms + f.ms
  end

  local files = {}
  for _, rel in ipairs(file_order) do
    files[#files + 1] = per_file[rel]
  end
  table.sort(files, function(a, b)
    if a.ms ~= b.ms then
      return a.ms > b.ms
    end
    return a.file < b.file
  end)
  files = vim.list_slice(files, 1, M.MAX_FILES)

  local cases = {}
  for _, c in ipairs(res.cases) do
    cases[#cases + 1] = {
      id = c.id,
      ms = round(type(c.duration_ms) == "number" and c.duration_ms or 0),
      status = c.status,
    }
  end
  table.sort(cases, function(a, b)
    if a.ms ~= b.ms then
      return a.ms > b.ms
    end
    return a.id < b.id
  end)
  cases = vim.list_slice(cases, 1, M.MAX_CASES)

  local phases = {}
  for name, ms in pairs(opts.phases or {}) do
    if type(ms) == "number" then
      phases[name] = round(ms)
    end
  end

  ---@type Testing.Profile
  local profile = {
    version = M.VERSION,
    phases = phases,
    files = files,
    cases = cases,
    histogram = M.histogram(res.cases),
  }

  -- child editors: what starting them cost
  local pool_stats = opts.pool
  local spawn_total, spawn_count, spawn_measured = 0, 0, false
  if type(pool_stats) == "table" and type(pool_stats.boot_ms) == "number" then
    spawn_total = spawn_total + pool_stats.boot_ms
    spawn_count = spawn_count + (pool_stats.spawned or 0)
    spawn_measured = true
  end
  for _, rel in ipairs(file_order) do
    local t = timings[rel]
    if type(t) == "table" and type(t.spawn_ms) == "number" then
      spawn_total = spawn_total + t.spawn_ms
      spawn_count = spawn_count + 1
      spawn_measured = true
    end
  end
  local isolated = (res.run.jobs or 1) > 1 or pool_stats ~= nil or next(timings) ~= nil
  if spawn_measured then
    profile.spawn = {
      measured = true,
      count = spawn_count,
      total_ms = round(spawn_total),
      mean_ms = spawn_count > 0 and round(spawn_total / spawn_count) or 0,
    }
  elseif isolated then
    profile.spawn = { measured = false }
  end

  -- pool use
  local finish_ms
  if type(pool_stats) == "table" and type(pool_stats.finish_ms) == "table" then
    finish_ms = 0
    for _, v in pairs(pool_stats.finish_ms) do
      if type(v) == "number" then
        finish_ms = finish_ms + v
      end
    end
    finish_ms = round(finish_ms)
  end
  local jobs = opts.jobs or res.run.jobs or 1
  local run_ms = opts.run_ms or (opts.phases or {}).run
  if isolated and type(run_ms) == "number" and run_ms > 0 then
    profile.pool = {
      jobs = jobs,
      spawned = pool_stats and pool_stats.spawned or nil,
      reused = pool_stats and pool_stats.reused or nil,
      discarded = pool_stats and pool_stats.discarded or nil,
      boot_ms = pool_stats and type(pool_stats.boot_ms) == "number" and round(pool_stats.boot_ms)
        or nil,
      finish_ms = finish_ms,
      utilisation = round(busy_ms / (jobs * run_ms)),
      approx = not busy_from_driver,
    }
  end
  return profile
end

---Attach a profile to the IR (`run.profile`, additive). Returns the profile.
---@param res Testing.Result
---@param profile Testing.Profile
---@return Testing.Profile
function M.attach(res, profile)
  (res.run --[[@as table]]).profile = profile
  return profile
end

---@param n number
---@return string
local function fmt_ms(n)
  if n >= 1000 then
    return ("%.2f s"):format(n / 1000)
  end
  return ("%.1f ms"):format(n)
end

---The text report, as lines (no I/O).
---@param profile Testing.Profile
---@param opts? { top?: integer } Rows of the file and case tables (default 10).
---@return string[]
function M.lines(profile, opts)
  local top = (opts and opts.top) or 10
  local out = { "profile:" }
  local order = { "discovery", "select", "run", "report", "total" }
  local phase_parts = {}
  for _, name in ipairs(order) do
    local ms = profile.phases[name]
    if ms then
      phase_parts[#phase_parts + 1] = ("%s %s"):format(name, fmt_ms(ms))
    end
  end
  for name, ms in pairs(profile.phases) do
    if not vim.tbl_contains(order, name) then
      phase_parts[#phase_parts + 1] = ("%s %s"):format(name, fmt_ms(ms))
    end
  end
  if #phase_parts > 0 then
    out[#out + 1] = "  phases: " .. table.concat(phase_parts, ", ")
  end
  if profile.spawn then
    if profile.spawn.measured then
      out[#out + 1] = ("  child editors: %d started, %s in total, %s each"):format(
        profile.spawn.count or 0,
        fmt_ms(profile.spawn.total_ms or 0),
        fmt_ms(profile.spawn.mean_ms or 0)
      )
    else
      out[#out + 1] = "  child editors: the driver does not measure their start"
    end
  end
  local p = profile.pool
  if p then
    local members = ""
    if p.spawned then
      members = (", %d member(s) started, %d file(s) reused one, %d discarded"):format(
        p.spawned,
        p.reused or 0,
        p.discarded or 0
      )
    end
    if p.boot_ms and p.finish_ms then
      members = members
        .. (" (starting members %s, verifying files %s, summed over members)"):format(
          fmt_ms(p.boot_ms),
          fmt_ms(p.finish_ms)
        )
    end
    out[#out + 1] = ("  pool: %d job(s), utilisation %d%%%s%s"):format(
      p.jobs,
      math.floor(p.utilisation * 100 + 0.5),
      p.approx and " (approximate: case time only)" or "",
      members
    )
  end
  if #profile.files > 0 then
    out[#out + 1] = "  slowest files:"
    for i = 1, math.min(top, #profile.files) do
      local f = profile.files[i]
      local split = ""
      if f.spawn_ms or f.load_ms or f.run_ms then
        split = (" (spawn %s, load %s, run %s)"):format(
          fmt_ms(f.spawn_ms or 0),
          fmt_ms(f.load_ms or 0),
          fmt_ms(f.run_ms or 0)
        )
      end
      out[#out + 1] = ("    %10s  %s (%d case(s))%s"):format(fmt_ms(f.ms), f.file, f.cases, split)
    end
  end
  if #profile.cases > 0 then
    out[#out + 1] = "  slowest cases:"
    for i = 1, math.min(top, #profile.cases) do
      local c = profile.cases[i]
      out[#out + 1] = ("    %10s  %s [%s]"):format(fmt_ms(c.ms), c.id, c.status)
    end
  end
  local h = profile.histogram
  local total = 0
  local peak = 0
  for _, n in ipairs(h.counts) do
    total = total + n
    peak = math.max(peak, n)
  end
  if total > 0 then
    out[#out + 1] = "  case durations:"
    for i, n in ipairs(h.counts) do
      local label
      if i == 1 then
        label = ("<= %g ms"):format(h.edges_ms[1])
      elseif i <= #h.edges_ms then
        label = ("<= %g ms"):format(h.edges_ms[i])
      else
        label = ("> %g ms"):format(h.edges_ms[#h.edges_ms])
      end
      local bar = string.rep("#", peak > 0 and math.floor(n / peak * 30 + 0.5) or 0)
      out[#out + 1] = ("    %-12s %6d  %s"):format(label, n, bar)
    end
  end
  return out
end

return M
