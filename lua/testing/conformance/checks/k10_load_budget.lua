---@module 'testing.conformance.checks.k10_load_budget'
---@brief K10: `require` + `setup()` stay within `load_budget_ms` (PERF-*).
---@description
--- The child measures `require(plugin)` plus `setup()` three times with `vim.uv.hrtime`: once for real
--- and twice after the plugin's modules were unloaded (so the file cache is warm for those). The MEDIAN
--- is compared with the budget (`conformance.load_budget_ms` of `.testing.lua`, default 40). A time is
--- noisy (a CI runner, an antivirus scan of a cold file), so the check is report-only: it warns, it
--- never fails the gate.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K10",
  title = "require + setup() within the load budget",
  rules = { "PERF-01" },
  kind = "runtime",
  level = "warn",
  report_only = true,
}

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  local timings = data.timings
  if type(timings) ~= "table" or #timings == 0 then
    return { na = "nothing was measured" }
  end
  local budget = ctx.settings.load_budget_ms
  local median = util.median(timings)
  local shown = {}
  for _, t in ipairs(timings) do
    shown[#shown + 1] = ("%.1f"):format(t)
  end
  local findings = {}
  if median > budget then
    findings[#findings + 1] = util.finding(
      "K10",
      "PERF-01",
      "warn",
      ("require + setup() took a median of %.1f ms, the budget is %s ms (runs: %s ms)"):format(
        median,
        tostring(budget),
        table.concat(shown, ", ")
      )
    )
  end
  return {
    findings = findings,
    volatile = {
      ("median %.1f ms of %d run(s) (%s ms), budget %s ms"):format(
        median,
        #timings,
        table.concat(shown, ", "),
        tostring(budget)
      ),
    },
  }
end

return M
