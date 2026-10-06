---@module 'testing.conformance.checks.k13_key_risks'
---@brief K13: fragile keys and command-name prefix collisions. Report only.
---@description
--- Two lists from `lib.nvim.bindings.audit`, both candidates and never a verdict:
---
---   * `key_risks()`: an action whose keys include none that every terminal delivers (`fragile`: needs
---     "CSI u" or a GUI; `common`: layout- or terminal-dependent). Fragile is a warning, common is info.
---   * `prefix_ambiguities()`: a command name that is a strict prefix of another (`<Tab>` after the short
---     name also offers the longer one). Only the pairs that involve a command of THIS plugin are reported.
---
--- Report-only: it can never fail the gate.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K13",
  title = "no fragile keys, no command-name prefix collisions",
  rules = { "UI-22" },
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
  local own = {}
  for _, c in ipairs((data.facts1 and data.facts1.commands) or {}) do
    own[c.name] = true
  end
  local risks = type(audit.key_risks) == "table" and audit.key_risks or {}
  local prefix = type(audit.prefix) == "table" and audit.prefix or {}
  if #risks == 0 and next(own) == nil and #(audit.actions or {}) == 0 then
    return { na = "the plugin registers no keymap action and no user command" }
  end
  local findings = {}
  for _, r in ipairs(risks) do
    local keys = {}
    for _, k in ipairs(r.keys) do
      keys[#keys + 1] = k.lhs
    end
    findings[#findings + 1] = util.finding(
      "K13",
      "UI-22",
      r.best == "fragile" and "warn" or "info",
      ("keymap action %s.%s (%s) has no portable key (%s)"):format(
        r.surface,
        r.name,
        table.concat(keys, " "),
        r.best
      )
    )
  end
  for _, p in ipairs(prefix) do
    local involved = own[p.short]
    for _, longer in ipairs(p.longer or {}) do
      involved = involved or own[longer]
    end
    if involved then
      local shown = {}
      for _, n in ipairs(p.longer) do
        shown[#shown + 1] = ":" .. n
      end
      findings[#findings + 1] = util.finding(
        "K13",
        "UI-22",
        "warn",
        (":%s is a prefix of %s (abbreviation and <Tab> are ambiguous)"):format(
          p.short,
          table.concat(shown, ", ")
        )
      )
    end
  end
  return { findings = findings }
end

return M
