---@module 'testing.conformance.rules_bridge'
---@brief Optional, soft bridge to rules.nvim: the same rule families run by their source, merged into the report.
---@description
--- rules.nvim owns the rules (fenced `rule` blocks of the gates) and their `check` predicates;
--- testing.nvim implements the decidable ones itself (K15) so that it runs anywhere. The bridge runs
--- rules.nvim's own `check_family_json` for the configured families (default `NEW`, `REL`) and
---
---   * lists the rules that have NO `check` in rules.nvim as `manual` (source `rules.nvim`), next to the
---     manual rules of `testing.conformance.catalog`;
---   * reports DRIFT: a rule both sides decide, with a different verdict (testing.nvim's predicate or the
---     rule in rules.nvim has gone stale);
---   * never changes the verdict of K1 .. K15 and never the exit code.
---
--- Soft: without rules.nvim (not installed, no ruleset configured) the bridge answers
--- `{ available = false, status = "n/a", reason = ... }`, a clear "n/a" and nothing else. The predicates of a
--- ruleset are Lua that rules.nvim executes with the rights of this editor (its `lua_predicates` switch):
--- the same trust as loading `.testing.lua`. They read the repository; the ones of the gates here do not
--- write. Never runs a network call.

local M = {}

---@class Testing.Conformance.BridgeOpts
---@field rulesets? string[] Files or directories of rule blocks (default: what rules.nvim has configured).
---@field families? string[] Rule family prefixes (default `NEW`, `REL`).
---@field checks? Testing.Conformance.CheckResult[] The results to compare with (K15's `rule_status`).
---@field loader? fun(root: string, families: string[], rulesets: string[]|nil): table[]|nil, string|nil Replaces rules.nvim (specs).

---Make `require("rules")` possible: when it is not on the runtimepath, look for a checkout the way
---dependencies are found.
---@param root string
---@return boolean ok
local function ensure_rules(root)
  -- `rules` is rules.nvim's module; LuaLS also resolves the name to conformance/rules/init.lua
  ---@diagnostic disable-next-line: different-requires
  if pcall(require, "rules") then
    return true
  end
  local ok_deps, deps = pcall(require, "testing.deps")
  if not ok_deps then
    return false
  end
  local found = deps.resolve("rules.nvim", root) or deps.resolve("rules.nvim", deps.self_dir())
  if not found then
    return false
  end
  deps.add_to_rtp(found.dir)
  return pcall(require, "rules")
end

---Entries (`{ id, severity, status, findings }`) of rules.nvim for the families.
---@param root string
---@param families string[]
---@param rulesets string[]|nil
---@return table[]|nil entries
---@return string|nil reason
local function load_entries(root, families, rulesets)
  if not ensure_rules(root) then
    return nil,
      "rules.nvim is not installed (a soft dependency: put a checkout beside the repository or on the runtimepath)"
  end
  local ok_config, config = pcall(require, "rules.config")
  if not ok_config then
    return nil, "rules.nvim has no rules.config module (an incompatible version)"
  end
  local current = config.get and config.get() or {}
  if (not current.rulesets or #current.rulesets == 0) and rulesets and #rulesets > 0 then
    local ok, err = pcall(config.setup, { rulesets = rulesets } --[[@as table]])
    if not ok then
      return nil, "rules.nvim rejected the rulesets: " .. tostring(err):match("^[^\n]*")
    end
    current = config.get()
  end
  if not current.rulesets or #current.rulesets == 0 then
    return nil,
      "rules.nvim has no ruleset configured (set `conformance.rules_bridge.rulesets` in .testing.lua)"
  end
  local rules = require("rules")
  local entries = {}
  for _, family in ipairs(families) do
    local ok, json = pcall(rules.check_family_json, family, root)
    if not ok then
      return nil,
        ("rules.nvim failed on family %s: %s"):format(family, tostring(json):match("^[^\n]*"))
    end
    local dok, decoded = pcall(vim.json.decode, json)
    if not dok or type(decoded) ~= "table" then
      return nil, ("rules.nvim returned unreadable JSON for family %s"):format(family)
    end
    for _, e in ipairs(decoded) do
      entries[#entries + 1] = e
    end
  end
  return entries
end

---Map the status of rules.nvim to a comparable one (`pass`, `fail`, nil = not comparable).
---@param status string
---@return string|nil
local function theirs(status)
  if status == "pass" then
    return "pass"
  elseif status == "fail" then
    return "fail"
  end
  return nil
end

---Verdict of testing.nvim per rule id (K15's `rule_status`, also under the `also` ids).
---@param checks Testing.Conformance.CheckResult[]|nil
---@return table<string, string>
local function ours(checks)
  local by_id = {}
  local index = require("testing.conformance.rules").index()
  for _, check in ipairs(checks or {}) do
    for id, st in pairs(check.rule_status or {}) do
      local status
      if st.status == "pass" then
        status = "pass"
      elseif st.status == "fail" or st.status == "warn" then
        status = "fail"
      end
      if status then
        by_id[id] = status
        local rule = index[id]
        for _, alias in ipairs(rule and rule.also or {}) do
          by_id[alias] = status
        end
      end
    end
  end
  return by_id
end

---Run the bridge.
---@param root string
---@param opts? Testing.Conformance.BridgeOpts
---@return table bridge
function M.run(root, opts)
  opts = opts or {}
  local families = opts.families or { "NEW", "REL" }
  local entries, reason
  if opts.loader then
    entries, reason = opts.loader(root, families, opts.rulesets)
  else
    entries, reason = load_entries(root, families, opts.rulesets)
  end
  if not entries then
    return {
      available = false,
      status = "n/a",
      reason = reason or "unavailable",
      families = families,
    }
  end

  local bridge = {
    available = true,
    status = "pass",
    families = families,
    results = {},
    manual = {},
    drift = {},
  }
  local mine = ours(opts.checks)
  local seen = {}
  for _, e in ipairs(entries) do
    if type(e) == "table" and type(e.id) == "string" and not seen[e.id] then
      seen[e.id] = true
      bridge.results[#bridge.results + 1] = {
        id = e.id,
        severity = e.severity,
        status = e.status,
        findings = type(e.findings) == "table" and #e.findings or 0,
      }
      if e.status == "manual" then
        bridge.manual[#bridge.manual + 1] = {
          id = e.id,
          title = "(see the ruleset)",
          gate = e.id:match("^(%a+)") or "?",
          severity = e.severity or "recommended",
          status = "manual",
          reason = "no check in rules.nvim: decided by a reader",
          source = "rules.nvim",
        }
      else
        local them, us = theirs(e.status), mine[e.id]
        if them and us and them ~= us then
          bridge.drift[#bridge.drift + 1] = { rule = e.id, testing = us, rules_nvim = them }
        end
      end
    end
  end
  table.sort(bridge.results, function(a, b)
    return a.id < b.id
  end)
  table.sort(bridge.manual, function(a, b)
    return a.id < b.id
  end)
  table.sort(bridge.drift, function(a, b)
    return a.rule < b.rule
  end)
  if #bridge.drift > 0 then
    bridge.status = "warn"
  end
  return bridge
end

return M
