---@module 'testing.budget.harness'
---@brief The measuring harness of `testing budget`: warm-up, N timed runs, median. `vim.uv.hrtime` only.
---@description
--- No dependency on lib.nvim, on the runner or on a test framework: a function in, numbers out. The clock
--- is injectable so that the specs measure a fake slow function without sleeping.
---
--- Method (the same for every case, so that the numbers are comparable):
---   * `warmup` untimed calls first (module loading, JIT, file-system cache, the first process start);
---   * `runs` timed calls; the MEDIAN is the number that counts (robust against one antivirus scan or one
---     GC pause), minimum and maximum are kept so that a noisy run is visible;
---   * each sample is wall time (`hrtime` difference in milliseconds), not CPU time: what a user waits for.

local M = {}

---Default untimed calls before the measurement.
M.WARMUP = 1
---Default timed calls (an odd number: the median is a real sample).
M.RUNS = 5

---@class Testing.Budget.Measure
---@field median_ms number
---@field min_ms number
---@field max_ms number
---@field runs integer
---@field samples number[] In call order.

---@class Testing.Budget.MeasureOpts
---@field warmup? integer
---@field runs? integer >= 1
---@field clock? fun(): number Milliseconds (default `vim.uv.hrtime() / 1e6`).

---@param samples number[]
---@return number
function M.median(samples)
  local sorted = vim.list_slice(samples, 1, #samples)
  table.sort(sorted)
  local n = #sorted
  if n == 0 then
    return 0
  end
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

---Time `fn`. A raise in `fn` ends the measurement and is returned as the error (never swallowed into a
---number: a case that fails measures nothing).
---@param fn fun()
---@param opts? Testing.Budget.MeasureOpts
---@return Testing.Budget.Measure|nil measure
---@return string|nil err
function M.measure(fn, opts)
  opts = opts or {}
  local clock = opts.clock or function()
    return vim.uv.hrtime() / 1e6
  end
  local warmup = opts.warmup or M.WARMUP
  local runs = math.max(1, opts.runs or M.RUNS)
  for _ = 1, warmup do
    local ok, err = pcall(fn)
    if not ok then
      return nil, tostring(err)
    end
  end
  local samples = {}
  for i = 1, runs do
    local t0 = clock()
    local ok, err = pcall(fn)
    local dt = clock() - t0
    if not ok then
      return nil, tostring(err)
    end
    samples[i] = dt
  end
  local lo, hi = samples[1], samples[1]
  for _, s in ipairs(samples) do
    lo, hi = math.min(lo, s), math.max(hi, s)
  end
  return {
    median_ms = M.median(samples),
    min_ms = lo,
    max_ms = hi,
    runs = runs,
    samples = samples,
  }
end

return M
