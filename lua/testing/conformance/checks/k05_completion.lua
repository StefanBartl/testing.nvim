---@module 'testing.conformance.checks.k05_completion'
---@brief K5: every user command has completion (REL-22, UI-22, NEW-26).
---@description
--- Two sources, the editor and lib.nvim:
---
---   * `nvim_get_commands`: a user command that takes arguments (`nargs` other than `0`) and declares no
---     `-complete` is reported. The suite cannot tell a closed value set from free text (UI-26 allows
---     only free text to go without), so this is a WARNING: the author decides, or waives it with a reason.
---   * `composer.check_all()`: a route of a compound command (`:Cmd sub ...`) whose pre-flight check
---     fails (its `run` cannot be resolved, its `check()` says no) is an ERROR.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K5",
  title = "every user command has completion",
  rules = { "REL-22", "UI-22", "NEW-26" },
  kind = "runtime",
  level = "warn",
}

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  local cmds = (data.facts1 and data.facts1.commands) or {}
  local audit = data.audit or {}
  local routes = type(audit.composer) == "table" and audit.composer or {}
  if #cmds == 0 and #routes == 0 then
    return { na = "the plugin defines no user command" }
  end
  local findings = {}
  for _, c in ipairs(cmds) do
    if c.nargs ~= "0" and (c.complete == nil or c.complete == vim.NIL or c.complete == "") then
      findings[#findings + 1] = util.finding(
        "K5",
        "UI-22",
        "warn",
        (":%s takes arguments (nargs=%s) and has no -complete (UI-26: only free text may go without)"):format(
          c.name,
          c.nargs
        )
      )
    end
  end
  local failed = 0
  for _, r in ipairs(routes) do
    if not r.ok then
      failed = failed + 1
      findings[#findings + 1] = util.finding(
        "K5",
        "REL-22",
        "error",
        (":%s %s fails its pre-flight check: %s"):format(r.verb, r.path, r.err or "?")
      )
    end
  end
  return {
    findings = findings,
    notes = {
      ("%d user command(s), %d composer route(s) (%d failing)"):format(#cmds, #routes, failed),
    },
  }
end

return M
