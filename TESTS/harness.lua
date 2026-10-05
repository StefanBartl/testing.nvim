-- TESTS/harness.lua -- tiny assertion helpers shared by the specs (returned to each spec by run.lua).

local H = {}

---Assert equality; tables are compared deeply. Raises on mismatch.
---@param actual any
---@param expected any
---@param msg string
function H.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      ("FAIL %s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

---Assert a truthy value.
---@param v any
---@param msg string
function H.ok(v, msg)
  if not v then
    error(("FAIL %s: expected truthy, got %s"):format(msg, vim.inspect(v)), 2)
  end
end

---Assert that a string contains a plain substring.
---@param haystack any
---@param needle string
---@param msg string
function H.has(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error(("FAIL %s: expected %s to contain %q"):format(msg, vim.inspect(haystack), needle), 2)
  end
end

return H
