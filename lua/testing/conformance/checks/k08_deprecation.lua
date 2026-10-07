---@module 'testing.conformance.checks.k08_deprecation'
---@brief K8: no `vim.deprecate` message and no scheduled error while the plugin loads and sets up.
---@description
--- The deprecation guard (`testing.guard.deprecation`) is on in the child while `plugin/` is sourced, the
--- plugin is required and `setup()` runs twice. Every `vim.deprecate` call it saw is a finding with the
--- message the editor would have shown the user. The scheduled-error guard of the same window adds the error of a
--- `vim.schedule`/luv callback that the plugin started during load or `setup()`: the editor prints it and goes
--- on, so a plugin that throws there looks healthy (`ERR-01`).

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K8",
  title = "no vim.deprecate message and no scheduled error on load and setup",
  rules = { "DEP-01", "ERR-01" },
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
  for _, f in ipairs(data.guard and data.guard.findings or {}) do
    local id = tostring(f.id)
    if
      id == "scheduled.schedule_callback"
      or id == "scheduled.luv_callback"
      or id == "scheduled.error_message"
    then
      findings[#findings + 1] = util.finding(
        "K8",
        "ERR-01",
        "error",
        "a scheduled callback raised while loading/setting up: "
          .. util.relativize(tostring(f.message), ctx.root)
      )
    end
  end
  return { findings = findings }
end

return M
