---@module 'testing.conformance.checks.k09_effects'
---@brief K9: no write outside the temp directory, no process, no network while the plugin loads and sets up (SEC-22).
---@description
--- The guards (`process_net`, `fs`) are on in the child, in observing mode, while `plugin/` is sourced,
--- the plugin is required and `setup()` runs twice. What the effects ledger recorded is a finding:
---
---   * a process that was started (`vim.system`, `jobstart`, `io.popen`, ...: the redacted argv),
---   * a network connection (host),
---   * a write outside the allowed roots (the temp directory and the child's own sandbox).
---
--- The child's working directory is a temporary directory, never the repository, and its XDG
--- directories are a sandbox: a plugin that writes to `stdpath("data")` writes there, which is allowed.
--- Starting a tool on purpose (`git` for a status line) is a decision: waive it with a reason.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K9",
  title = "no write outside tmp, no process, no network on load and setup",
  rules = { "SEC-22", "SEC-47" },
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
  local g = data.guard or { effects = {}, findings = {} }
  local findings = {}
  local function add(rule, text)
    findings[#findings + 1] = util.finding("K9", rule, "error", util.relativize(text, ctx.root))
  end
  for _, entry in ipairs(g.effects.spawned or {}) do
    add("SEC-22", "starts a process while loading/setting up: " .. entry)
  end
  for _, entry in ipairs(g.effects.network or {}) do
    add("SEC-22", "opens a network connection while loading/setting up: " .. entry)
  end
  for _, entry in ipairs(g.effects.fs_outside_tmp or {}) do
    add("SEC-47", "writes outside the temp directory while loading/setting up: " .. entry)
  end
  if #findings == 0 then
    -- an effect the ledger did not list but a guard named
    for _, f in ipairs(g.findings or {}) do
      if
        f.id == "fs.write_outside"
        or f.id == "process.spawn_blocked"
        or f.id == "network.blocked"
      then
        add(f.id == "fs.write_outside" and "SEC-47" or "SEC-22", tostring(f.message))
      end
    end
  end
  return { findings = findings }
end

return M
