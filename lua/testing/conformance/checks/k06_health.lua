---@module 'testing.conformance.checks.k06_health'
---@brief K6: `:checkhealth <plugin>` runs without an error (REL-16, UI-57).
---@description
--- The child runs `:checkhealth <plugin>` after `setup()` and the report buffer is parsed: a line of the
--- form `- <icon> ERROR ...` is an ERROR finding (an error is a health check that says the plugin is
--- broken, or a `health.lua` that raises), `- <icon> WARNING ...` a warning. Whether a missing OPTIONAL
--- tool should warn at all is UI-57's "one-sentence test", a judgement the suite leaves to the author.
--- A plugin without `lua/<plugin>/health.lua` is not applicable here: the missing file is K15's
--- finding (NEW-10, REL-16).

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K6",
  title = ":checkhealth <plugin> runs without an error",
  rules = { "REL-16", "NEW-10", "UI-57" },
  kind = "runtime",
  level = "error",
}

---Classify one line of the `:checkhealth` buffer.
---@param line string
---@return "error"|"warn"|nil
function M.classify(line)
  if line:match("^%s*%-%s+%S+%s+ERROR%f[%A]") or line:match("^%s*%-%s+ERROR:") then
    return "error"
  end
  if line:match("^%s*%-%s+%S+%s+WARNING%f[%A]") or line:match("^%s*%-%s+WARNING:") then
    return "warn"
  end
  return nil
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  local health = data.health
  if not health then
    return { na = ("no lua/%s/health.lua (REL-16 is reported by K15)"):format(ctx.plugin) }
  end
  if health.err and health.ok == nil then
    return { error = "the child editor could not run :checkhealth: " .. tostring(health.err) }
  end
  local findings = {}
  -- a declared dependency that this machine does not have makes a correct health check report an error: that is
  -- the environment, not the plugin (K1 treats the same case as a warning)
  local missing = ctx.missing_deps or {}
  local level = #missing > 0 and "warn" or "error"
  local why_level = #missing > 0
      and (" (dependency not installed here: %s)"):format(table.concat(missing, ", "))
    or ""
  if health.ok == false then
    findings[#findings + 1] = util.finding(
      "K6",
      "REL-16",
      level,
      (":checkhealth %s failed: %s"):format(
        ctx.plugin,
        util.relativize(health.err or "?", ctx.root)
      )
    )
    return { findings = findings }
  end
  local errors, warnings = 0, 0
  for _, line in ipairs(health.lines or {}) do
    local kind = M.classify(line)
    if kind == "error" then
      errors = errors + 1
      findings[#findings + 1] = util.finding(
        "K6",
        "REL-16",
        level,
        "health: "
          .. util.relativize((vim.trim(line):gsub("^%-%s+%S+%s+", "")), ctx.root)
          .. why_level
      )
    elseif kind == "warn" then
      warnings = warnings + 1
      findings[#findings + 1] = util.finding(
        "K6",
        "UI-57",
        "warn",
        "health: " .. util.relativize((vim.trim(line):gsub("^%-%s+%S+%s+", "")), ctx.root)
      )
    end
  end
  if #(health.lines or {}) == 0 then
    findings[#findings + 1] = util.finding(
      "K6",
      "REL-16",
      "error",
      (":checkhealth %s produced no report (is lua/%s/health.lua's check() missing?)"):format(
        ctx.plugin,
        ctx.plugin
      )
    )
  end
  return {
    findings = findings,
    notes = {
      ("%d error(s), %d warning(s) in %d line(s)"):format(errors, warnings, #(health.lines or {})),
    },
  }
end

return M
