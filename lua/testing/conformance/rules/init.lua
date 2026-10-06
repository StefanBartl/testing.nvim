---@module 'testing.conformance.rules'
---@brief The static rules K15 runs, in a stable order.
---@description
--- A rule is `{ id, also?, title, gate, severity, run }` (see `testing.conformance.rules.tooling`).
--- `id` is the id of the gate rule (`NEW-36`); `also` names the rules that say the same thing in another
--- gate (`LLS-01`, `REL-05`), so that a report line for either id finds the verdict.

local M = {}

---@class Testing.Conformance.Rule
---@field id string
---@field also? string[]
---@field title string
---@field gate string `NEW_PROJECT`, `RELEASE` or `REVIEW`.
---@field severity "critical"|"recommended"|"nice-to-have"
---@field run fun(ctx: Testing.Conformance.Ctx): table[]|nil, string|nil

---@type Testing.Conformance.Rule[]
M.rules = {}
for _, name in ipairs({ "tooling", "layout", "hygiene" }) do
  for _, rule in ipairs(require("testing.conformance.rules." .. name).rules) do
    M.rules[#M.rules + 1] = rule
  end
end

---Ids a rule answers for (its own and `also`), as a set.
---@return table<string, Testing.Conformance.Rule>
function M.index()
  local out = {}
  for _, rule in ipairs(M.rules) do
    out[rule.id] = rule
    for _, id in ipairs(rule.also or {}) do
      out[id] = rule
    end
  end
  return out
end

return M
