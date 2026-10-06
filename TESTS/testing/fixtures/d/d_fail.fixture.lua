-- Fixture (never a spec of this repo). Dialect D: `M.run()` with the plugin's own harness module.
-- Three checks pass, three fail (one inside a helper that calls the assertions itself).
---@diagnostic disable: param-type-mismatch, redundant-parameter

local t = require("harness")

local M = {}

function M.run()
  t.ok("passes", true)
  t.eq("eq fails", 1, 2) -- MARK:d1
  t.with_modules({}, function()
    t.ok("inside the helper passes", true)
    t.ok("inside the helper fails", false, "custom reason") -- MARK:d2
  end)
  t.contains("contains passes", "haystack", "hay")
  t.contains("contains fails", "haystack", "needle") -- MARK:d3
  local n = t.fixture({ "a", "b" })
  t.eq("a non-assertion helper returns its value", n, 2)
end

return M
