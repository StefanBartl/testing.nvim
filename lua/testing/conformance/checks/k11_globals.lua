---@module 'testing.conformance.checks.k11_globals'
---@brief K11: loading and setting up the plugin creates no new global (PRIN-10).
---@description
--- A key that is in `_G` after `plugin/` was sourced, the plugin required and `setup()` run twice and was
--- not there before. State belongs in a module (getter and setter), not in a global (PRIN-10; the
--- state guard's `lua_globals` category, here as an exact `_G` difference). `vim.g` variables are
--- not globals in this sense.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K11",
  title = "no new global",
  rules = { "PRIN-10" },
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
  local facts = data.facts2 or data.facts1
  if type(facts) ~= "table" or facts.err then
    return { error = "the child editor reported no facts" }
  end
  local findings = {}
  for _, name in ipairs(facts.globals or {}) do
    findings[#findings + 1] = util.finding(
      "K11",
      "PRIN-10",
      "error",
      ("the plugin created the global `_G.%s`"):format(name)
    )
  end
  return { findings = findings }
end

return M
