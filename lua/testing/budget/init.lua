---@module 'testing.budget'
---@brief `testing budget`: measure the hot paths, compare them with a stored baseline, fail on a regression.
---@description
--- The D.7 performance budgets are estimates until they are measured on the machine that matters. This
--- module measures a fixed set of cases (`testing.budget.cases`) with a plain `hrtime` harness
--- (`testing.budget.harness`: warm-up, N runs, median), stores the result as a JSON baseline, and checks a
--- later measurement against it:
---
---   measured median > baseline median * factor   AND   measured - baseline > slack_ms   -> exceeded
---
--- `factor` is `budget.factor` of `.testing.lua` (default 2.0), `--factor` overrides it. The absolute
--- `slack_ms` (1 ms) keeps a 0.3 ms case from failing at 0.7 ms: below a millisecond the clock, the GC and
--- the scheduler dominate, and a gate that cries wolf is switched off by the first person it annoys.
--- It is a literal because it describes the measuring instrument, not a preference (LUA-84).
---
--- EXIT CODES (the CLI): 0 every case within its limit (or `--update` wrote the baseline), 1 at least one
--- case exceeded, 2 usage (no baseline and no `--update`, unreadable baseline), 3 a case could not be
--- measured at all (a raise in its setup or body: a case that fails measures nothing and is never green).
---
--- BASELINE FILE (JSON, `budget.baseline`, default `TESTS/bench/baseline.json`):
---   { "version": 1, "date": "<UTC>", "machine": { os, arch, cpu, cpus, nvim, ... },
---     "method": { "warmup": n, "runs": n },
---     "cases": { "<name>": { "median_ms": x, "min_ms": x, "max_ms": x, "runs": n }, ... } }
--- It is UNTRUSTED input when read back (size cap, `pcall(decode)`, every number validated); a case
--- without a usable entry counts as "new", not as a pass.
---
--- A baseline is only comparable to measurements of the same machine: `machine` is recorded and a
--- different one is reported (a note, not a failure: a CI runner is a different machine on purpose, and the
--- check there is a nightly job with its own baseline, never a merge gate).

local harness = require("testing.budget.harness")

local M = {}

M.VERSION = 1
---Absolute slack (ms) below which a case never fails (see the module header).
M.SLACK_MS = 1
---Largest accepted baseline file (bytes).
M.MAX_BYTES = 262144

M.EXIT_OK = 0
M.EXIT_EXCEEDED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

---@class Testing.Budget.Result
---@field name string
---@field desc? string
---@field measure? Testing.Budget.Measure
---@field error? string Setup or body raised: nothing was measured.

---@class Testing.Budget.Row
---@field name string
---@field measured_ms number
---@field baseline_ms? number
---@field limit_ms? number
---@field ratio? number measured / baseline
---@field status "ok"|"exceeded"|"new"

---Compare measurements with a baseline.
---@param baseline table<string, { median_ms: number }> Cases of the baseline file.
---@param measured table<string, number> name -> median ms
---@param opts? { factor?: number, slack_ms?: number }
---@return Testing.Budget.Row[] rows In the order of the names, sorted.
---@return integer exceeded
function M.check(baseline, measured, opts)
  opts = opts or {}
  local factor = opts.factor or 2.0
  local slack = opts.slack_ms or M.SLACK_MS
  local names = vim.tbl_keys(measured)
  table.sort(names)
  local rows, exceeded = {}, 0
  for _, name in ipairs(names) do
    local got = measured[name]
    local base = baseline[name] and baseline[name].median_ms
    ---@type Testing.Budget.Row
    local row = { name = name, measured_ms = got, status = "new" }
    if type(base) == "number" then
      row.baseline_ms = base
      row.limit_ms = base * factor
      row.ratio = base > 0 and got / base or nil
      if got > row.limit_ms and got - base > slack then
        row.status = "exceeded"
        exceeded = exceeded + 1
      else
        row.status = "ok"
      end
    end
    rows[#rows + 1] = row
  end
  return rows, exceeded
end

---What identifies the machine of a measurement (no host name, no user name: the file is committed).
---@return table<string, any>
function M.machine()
  local uname = vim.uv.os_uname() or {}
  local cpus = vim.uv.cpu_info() or {}
  local v = vim.version() --[[@as vim.Version]]
  return {
    os = uname.sysname,
    release = uname.release,
    arch = uname.machine,
    cpu = cpus[1] and cpus[1].model or "unknown",
    cpus = #cpus,
    memory_gb = math.floor((vim.uv.get_total_memory() or 0) / 2 ^ 30 + 0.5),
    nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
  }
end

---@param value any
---@return boolean
local function is_ms(value)
  return type(value) == "number" and value == value and value >= 0 and value < 1e9
end

---The machine description of a baseline file, as plain bounded text: the file is committed and a pull request
---can edit it, and the value is printed in a note (a control character or a `::error::` line would reach the log).
---@param raw any
---@return table<string, string|number>|nil
function M.clean_machine(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local clean = require("testing.report.util").clean
  local out = {}
  for _, key in ipairs({ "os", "release", "arch", "cpu", "nvim" }) do
    local v = raw[key]
    if type(v) == "string" then
      out[key] = clean(v:sub(1, 100), { bidi = true, c1 = true })
    end
  end
  for _, key in ipairs({ "cpus", "memory_gb" }) do
    local v = raw[key]
    if type(v) == "number" and v == v and v >= 0 and v < 1e9 then
      out[key] = v
    end
  end
  return out
end

---Validate a decoded baseline; never raises.
---@param raw any
---@return { cases: table<string, { median_ms: number, min_ms?: number, max_ms?: number, runs?: integer }>, machine?: table, date?: string, method?: table }|nil baseline
---@return string|nil problem
function M.validate_baseline(raw)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  if raw.version ~= M.VERSION then
    return nil,
      ("unknown version %s (this runner writes %d)"):format(tostring(raw.version), M.VERSION)
  end
  if type(raw.cases) ~= "table" then
    return nil, "no `cases` object"
  end
  local cases = {}
  for name, entry in pairs(raw.cases) do
    if
      type(name) == "string"
      and #name <= 100
      and type(entry) == "table"
      and is_ms(entry.median_ms)
    then
      cases[name] = {
        median_ms = entry.median_ms,
        min_ms = is_ms(entry.min_ms) and entry.min_ms or nil,
        max_ms = is_ms(entry.max_ms) and entry.max_ms or nil,
        runs = type(entry.runs) == "number" and entry.runs or nil,
      }
    end
  end
  return {
    cases = cases,
    machine = M.clean_machine(raw.machine),
    date = type(raw.date) == "string" and raw.date:sub(1, 40) or nil,
    method = type(raw.method) == "table" and raw.method or nil,
  },
    nil
end

---Read and validate the baseline file.
---@param path string
---@return table|nil baseline
---@return string|nil problem
function M.read_baseline(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, ("no baseline at %s"):format(path)
  end
  if stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return nil,
      ("baseline %s is not a regular file or larger than %d bytes"):format(path, M.MAX_BYTES)
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, ("cannot read %s: %s"):format(path, tostring(err))
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok or decoded == nil then
    return nil, ("%s is not valid JSON"):format(path)
  end
  local baseline, why = M.validate_baseline(decoded)
  if not baseline then
    return nil, ("%s: %s"):format(path, why)
  end
  return baseline, nil
end

---Write the measurements as the new baseline (atomic).
---@param path string
---@param results Testing.Budget.Result[]
---@param opts? { warmup?: integer, runs?: integer, now?: integer, machine?: table, keep?: table<string, table> } `keep`: cases of the old baseline that were not measured this time.
---@return boolean ok
---@return string|nil err
function M.write_baseline(path, results, opts)
  opts = opts or {}
  local cases = {}
  for name, entry in pairs(opts.keep or {}) do
    cases[name] = entry
  end
  for _, r in ipairs(results) do
    if r.measure then
      cases[r.name] = {
        median_ms = math.floor(r.measure.median_ms * 1000 + 0.5) / 1000,
        min_ms = math.floor(r.measure.min_ms * 1000 + 0.5) / 1000,
        max_ms = math.floor(r.measure.max_ms * 1000 + 0.5) / 1000,
        runs = r.measure.runs,
      }
    end
  end
  local doc = {
    version = M.VERSION,
    date = os.date("!%Y-%m-%dT%H:%M:%SZ", opts.now or os.time()),
    machine = opts.machine or M.machine(),
    method = { warmup = opts.warmup or harness.WARMUP, runs = opts.runs or harness.RUNS },
    cases = cases,
  }
  local text, err = require("lib.nvim.json").encode(doc, { indent = 2 })
  if not text then
    return false, "cannot encode the baseline: " .. tostring(err)
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, text .. "\n", { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

---@class Testing.Budget.RunOpts
---@field cases? Testing.Budget.Case[] Default: `testing.budget.cases.ALL`.
---@field filter? string[] Keep the cases whose name contains one of these (plain substring).
---@field runs? integer Timed runs per case (default: 3 for a process case, 5 otherwise).
---@field warmup? integer
---@field clock? fun(): number
---@field self_dir? string
---@field sizes? Testing.Budget.Sizes
---@field progress? fun(line: string)

---Measure the cases. Scratch directories are removed afterwards, also when a case raises.
---@param opts? Testing.Budget.RunOpts
---@return Testing.Budget.Result[]
function M.run(opts)
  opts = opts or {}
  local cases_mod = require("testing.budget.cases")
  local list = opts.cases or cases_mod.ALL
  local made = {}
  ---@type Testing.Budget.Ctx
  local ctx = {
    calls = 0,
    self_dir = opts.self_dir or require("testing.deps").self_dir(),
    sizes = vim.tbl_extend("force", cases_mod.SIZES, opts.sizes or {}),
    tmp = function(name)
      local dir = vim.fs.normalize(vim.fn.tempname()) .. "-budget-" .. name
      vim.fn.mkdir(dir, "p")
      made[#made + 1] = dir
      return dir
    end,
  }
  local results = {}
  for _, case in ipairs(list) do
    local wanted = true
    if opts.filter and #opts.filter > 0 then
      wanted = false
      for _, text in ipairs(opts.filter) do
        if case.name:find(text, 1, true) then
          wanted = true
        end
      end
    end
    if wanted then
      if opts.progress then
        opts.progress(("measuring %s ..."):format(case.name))
      end
      ---@type Testing.Budget.Result
      local result = { name = case.name, desc = case.desc }
      local runs = opts.runs or (case.kind == "process" and 3 or harness.RUNS)
      local warmup = opts.warmup or harness.WARMUP
      ctx.calls = warmup + runs
      local ok, fn, teardown = pcall(case.setup, ctx)
      if not ok then
        result.error = "setup failed: " .. tostring(fn)
      else
        local m, err = harness.measure(fn, {
          clock = opts.clock,
          warmup = warmup,
          runs = runs,
        })
        result.measure, result.error = m, err
        if teardown then
          pcall(teardown)
        end
      end
      results[#results + 1] = result
    end
  end
  for _, dir in ipairs(made) do
    pcall(vim.fn.delete, dir, "rf")
  end
  return results
end

---@param ms number
---@return string
local function fmt(ms)
  if ms >= 1000 then
    return ("%.2f s"):format(ms / 1000)
  end
  return ("%.2f ms"):format(ms)
end

---The report as lines.
---@param rows Testing.Budget.Row[]
---@param results Testing.Budget.Result[]
---@param opts { factor: number, baseline_path?: string, notes?: string[] }
---@return string[]
function M.lines(rows, results, opts)
  local out = {
    ("budget (median of runs; a case fails above baseline x %g and %g ms):"):format(
      opts.factor,
      M.SLACK_MS
    ),
  }
  for _, row in ipairs(rows) do
    local base = row.baseline_ms
        and ("baseline %s, limit %s, x%.2f"):format(
          fmt(row.baseline_ms),
          fmt(row.limit_ms),
          row.ratio or 0
        )
      or "no baseline yet"
    out[#out + 1] = ("  %-9s %-18s %10s  %s"):format(
      row.status:upper(),
      row.name,
      fmt(row.measured_ms),
      base
    )
  end
  for _, r in ipairs(results) do
    if r.error then
      out[#out + 1] = ("  ERROR     %-18s %s"):format(r.name, r.error)
    end
  end
  for _, note in ipairs(opts.notes or {}) do
    out[#out + 1] = "  note: " .. note
  end
  return out
end

---`testing budget`: measure, then write or check the baseline. Returns the exit code.
---@param plan Testing.Cli.RunPlan
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param over? { run?: (fun(opts: Testing.Budget.RunOpts): Testing.Budget.Result[]), machine?: table } Seams (specs).
---@return integer exit_code
function M.main(plan, sv, over)
  over = over or {}
  local args, cfg = plan.args, plan.project
  local factor = args.factor or cfg.budget.factor
  local path = vim.fs.normalize(
    args.baseline and vim.fn.fnamemodify(args.baseline, ":p")
      or (plan.root .. "/" .. cfg.budget.baseline)
  )

  local results = (over.run or M.run)({
    filter = args.filter,
    runs = args.budget_runs,
    progress = function(line)
      sv.err(line)
    end,
  })
  local measured, failed = {}, 0
  for _, r in ipairs(results) do
    if r.measure then
      measured[r.name] = r.measure.median_ms
    else
      failed = failed + 1
    end
  end
  if #results == 0 then
    sv.err("testing: budget: no case matches --filter")
    return M.EXIT_USAGE
  end

  local old, why = M.read_baseline(path)
  if args.budget_update then
    if failed > 0 then
      for _, r in ipairs(results) do
        if r.error then
          sv.err(("testing: budget: %s: %s"):format(r.name, r.error))
        end
      end
      sv.err("testing: budget: the baseline was NOT written: a case could not be measured")
      return M.EXIT_INFRA
    end
    local ok, err = M.write_baseline(path, results, {
      runs = args.budget_runs,
      machine = over.machine,
      keep = old and old.cases or nil,
    })
    if not ok then
      sv.err("testing: budget: " .. tostring(err))
      return M.EXIT_INFRA
    end
    -- the rows compare with the baseline that is being replaced: a rewrite that hides a regression shows it
    local rows = M.check(old and old.cases or {}, measured, { factor = factor })
    for _, line in ipairs(M.lines(rows, results, { factor = factor })) do
      sv.out(line)
    end
    sv.out(("baseline written: %s"):format(path))
    return M.EXIT_OK
  end

  if not old then
    sv.err(
      ("testing: budget: %s; write one with `testing budget --update`"):format(why or "no baseline")
    )
    return M.EXIT_USAGE
  end
  local rows, exceeded = M.check(old.cases, measured, { factor = factor })
  local notes = {}
  -- a gate that compared nothing must not look green: a case without a usable baseline entry (renamed, a
  -- corrupted entry, a new case) and a baseline entry nobody measures any more are said, and the first is an error
  local new_cases = {}
  for _, row in ipairs(rows) do
    if row.status == "new" then
      new_cases[#new_cases + 1] = row.name
    end
  end
  local unmeasured = {}
  if not args.filter or #args.filter == 0 then
    for name in pairs(old.cases) do
      if measured[name] == nil then
        unmeasured[#unmeasured + 1] = name
      end
    end
    table.sort(unmeasured)
  end
  if #new_cases > 0 then
    notes[#notes + 1] = ("%d case(s) have no baseline entry, so the gate compared nothing for them (%s); `testing budget --update` writes one%s"):format(
      #new_cases,
      table.concat(vim.list_slice(new_cases, 1, 5), ", "),
      args.budget_allow_new and "" or ", `--allow-new` accepts it"
    )
  end
  if #unmeasured > 0 then
    notes[#notes + 1] = ("%d baseline entr%s nobody measures any more (%s)"):format(
      #unmeasured,
      #unmeasured == 1 and "y is" or "ies are",
      table.concat(vim.list_slice(unmeasured, 1, 5), ", ")
    )
  end
  local here = over.machine or M.machine()
  if old.machine and (old.machine.cpu ~= here.cpu or old.machine.os ~= here.os) then
    notes[#notes + 1] = ("the baseline was measured on another machine (%s, %s); compare with care"):format(
      tostring(old.machine.cpu),
      tostring(old.machine.os)
    )
  end
  local clean = require("testing.report.util").clean
  for _, line in ipairs(M.lines(rows, results, { factor = factor, notes = notes })) do
    sv.out(clean(line, { bidi = true, c1 = true }))
  end
  if failed > 0 then
    return M.EXIT_INFRA
  end
  if exceeded > 0 then
    sv.out(("%d case(s) exceeded their budget"):format(exceeded))
    return M.EXIT_EXCEEDED
  end
  if #new_cases > 0 and not args.budget_allow_new then
    sv.err(
      ("testing: budget: %d measured case(s) have no baseline entry: nothing was compared (--allow-new accepts this)"):format(
        #new_cases
      )
    )
    return M.EXIT_USAGE
  end
  return M.EXIT_OK
end

return M
