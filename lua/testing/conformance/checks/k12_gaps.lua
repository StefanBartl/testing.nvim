---@module 'testing.conformance.checks.k12_gaps'
---@brief K12: a keymap action without a command counterpart (REL-22 candidate). Report only.
---@description
--- `lib.nvim.bindings.audit.gaps()` holds the keymap registry next to the command routes and lists the
--- actions that have no plausible `:command`. It is a candidate list, not a verdict (a route with a typed
--- argument can cover many actions without naming them), so the check only ever warns and is
--- report-only: it can never fail the gate. It needs actions registered through
--- `lib.nvim.bindings.keymap.register`; a plugin that maps with raw `vim.keymap.set` has none.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K12",
  title = "keymap actions have a command counterpart",
  rules = { "REL-22" },
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
  local audit = data.audit or {}
  if audit.lib == false then
    return { na = "lib.nvim.bindings.audit is not available in the child editor" }
  end
  if type(audit.actions) ~= "table" or #audit.actions == 0 then
    return {
      na = "no keymap action is registered through lib.nvim (nothing to compare with the commands)",
    }
  end
  local findings = {}
  for _, a in ipairs(audit.gaps or {}) do
    findings[#findings + 1] = util.finding(
      "K12",
      "REL-22",
      "warn",
      ("keymap action %s.%s%s has no obvious command counterpart"):format(
        a.surface,
        a.name,
        a.lhs and (" (" .. a.lhs .. ")") or ""
      )
    )
  end
  return {
    findings = findings,
    notes = {
      ("%d keymap action(s), %d command route(s)"):format(#audit.actions, #(audit.routes or {})),
    },
  }
end

return M
