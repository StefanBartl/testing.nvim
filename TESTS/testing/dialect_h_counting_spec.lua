-- TESTS/testing/dialect_h_counting_spec.lua -- dialect h counts what the project's own counter counts: a
-- helper that only RUNS a callback (`H.notifications(fn)`, `H.notices(fn)`) is not an assertion, even
-- though the assertions inside the callback raise the project's counter. They are recorded one by one,
-- the same way on the first call and on every later one; the helper itself is never counted, and a
-- failure inside the callback stays a failure.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local assert_mod = require("testing.core.assert")
  local dialect = require("testing.dialect")

  local dir = vim.fs.normalize(vim.fn.tempname()) .. "-count"
  vim.fn.mkdir(dir, "p")
  local function write(name, text)
    local f = assert(io.open(dir .. "/" .. name, "wb"))
    f:write(text)
    f:close()
  end
  write(
    "harness.lua",
    [=[
local H = { checks = 0 }
function H.eq(a, b, msg)
  H.checks = H.checks + 1
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end
-- runs `fn` and returns what it saw; the assertions inside `fn` raise H.checks, the helper does not
function H.capture(fn)
  local ok, err = pcall(fn)
  if not ok then
    error(err, 0)
  end
  return {}
end
return H
]=]
  )
  write(
    "green_spec.lua",
    [=[
return function(H)
  H.eq(1, 1, "plain")
  H.capture(function()
    H.eq(1, 1, "first call, one")
    H.eq(2, 2, "first call, two")
  end)
  H.capture(function()
    H.eq(3, 3, "second call, one")
    H.eq(4, 4, "second call, two")
    H.eq(5, 5, "second call, three")
  end)
  H.capture(function() end)
  H.eq(6, 6, "plain again")
  _G.__counting_checks = H.checks
end
]=]
  )
  write(
    "red_spec.lua",
    [=[
return function(H)
  H.capture(function()
    H.eq(1, 1, "fine")
    H.eq(1, 2, "broken inside the callback")
  end)
  H.eq(3, 3, "after")
end
]=]
  )

  ---@param name string
  ---@return Testing.Result.Case
  local function run(name)
    local called, cases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = dir .. "/" .. name,
      rel = "TESTS/" .. name,
      harness = dir .. "/harness.lua",
    })
    assert(called, cases)
    return cases[1]
  end

  local green = run("green_spec.lua")
  eq(green.status, "pass", "green: passes")
  local kinds = {}
  for _, rec in ipairs(green.assertions) do
    kinds[rec.kind] = (kinds[rec.kind] or 0) + 1
  end
  eq(kinds, { eq = 7 }, "green: only the assertions are recorded, not the callback helper")
  eq(#green.assertions, _G.__counting_checks, "green: as many as the project's own counter says")
  _G.__counting_checks = nil

  local red = run("red_spec.lua")
  eq(red.status, "fail", "red: the failure inside the callback is still a failure")
  local failed = 0
  for _, rec in ipairs(red.assertions) do
    failed = failed + (rec.ok and 0 or 1)
  end
  eq(failed, 1, "red: exactly the broken assertion failed")
  eq(#red.assertions, 3, "red: fine, broken, after")

  vim.fn.delete(dir, "rf")
end
