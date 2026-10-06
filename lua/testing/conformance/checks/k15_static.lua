---@module 'testing.conformance.checks.k15_static'
---@brief K15: the static rules of the gates that can be decided from the files of the repository.
---@description
--- Runs `testing.conformance.rules` (NEW-36/37/38/50, NEW-45, NEW-48, NEW-49, REL-16 and the rest of the
--- gates' file and folder rules). The predicates follow the `check` blocks of rules.nvim, the source of
--- the rules; `testing.conformance.rules_bridge` compares the verdicts with rules.nvim's own run when it
--- is available. Each rule yields one verdict in `rule_status` (`pass`, `fail`, `warn`, `n/a`), and
--- the check as a whole fails when a rule of severity `critical` or an item with level `error` is
--- violated: `critical` is an error, `recommended` a warning, `nice-to-have` info. A heuristic rule
--- (a grep) marks its items `level = "warn"` itself.
---
--- Reads files by literal path only (`ctx.fs`, XP-01), never writes, starts nothing.

local util = require("testing.conformance.util")

local M = {
  id = "K15",
  title = "static gate rules (NEW-36/45/48/49, REL-16 and the file rules)",
  rules = { "NEW-36", "NEW-45", "NEW-48", "NEW-49", "REL-16" },
  kind = "static",
  level = "error",
}

---@type table<string, Testing.Conformance.Level>
local LEVEL = { critical = "error", recommended = "warn", ["nice-to-have"] = "info" }

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local findings, rule_status, failures = {}, {}, {}
  for _, rule in ipairs(require("testing.conformance.rules").rules) do
    local ok, items, why = pcall(rule.run, ctx)
    if not ok then
      failures[#failures + 1] = ("%s raised: %s"):format(
        rule.id,
        (tostring(items):match("^[^\n]*") or "?")
      )
      rule_status[rule.id] = { status = "error", count = 0 }
    elseif items == nil then
      rule_status[rule.id] = { status = "n/a", count = 0, reason = why }
    else
      local level_of_rule = LEVEL[rule.severity] or "warn"
      local worst = "pass"
      for _, item in ipairs(items) do
        local level = item.level or level_of_rule
        findings[#findings + 1] =
          util.finding("K15", rule.id, level, item.message, item.file, item.line)
        if level == "error" then
          worst = "fail"
        elseif level == "warn" and worst == "pass" then
          worst = "warn"
        end
      end
      rule_status[rule.id] = { status = worst, count = #items }
    end
  end
  local outcome = { findings = findings, rules = rule_status }
  if #failures > 0 then
    outcome.error = table.concat(failures, "; ")
  end
  return outcome
end

return M
