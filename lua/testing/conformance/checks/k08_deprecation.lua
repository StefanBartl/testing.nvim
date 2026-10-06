---@module 'testing.conformance.checks.k08_deprecation'
---@brief K8: no `vim.deprecate` message while the plugin loads and sets up.
---@description
--- The deprecation guard (`testing.guard.deprecation`) is on in the child while `plugin/` is sourced, the
--- plugin is required and `setup()` runs once. Every `vim.deprecate` call it saw is a finding with the
--- message the editor would have shown the user.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K8",
  title = "no vim.deprecate message on load and setup",
  rules = { "DEP-01" },
  kind = "runtime",
  level = "error",
}

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  if not (data.guard and data.guard.available) then
    -- nothing was observed: that is not "nothing happened"
    return {
      blocked = "the guards did not run in the child editor (" .. tostring(
        data.guard and data.guard.err or "no guard module"
      ) .. "): nothing was observed",
    }
  end
  local findings = {}
  for _, f in ipairs(data.guard and data.guard.findings or {}) do
    if f.guard == "deprecation" or tostring(f.id):sub(1, 12) == "deprecation." then
      findings[#findings + 1] =
        util.finding("K8", "DEP-01", "error", util.relativize(tostring(f.message), ctx.root))
    end
  end
  return { findings = findings }
end

return M
