-- Fixture harness of the check-collector convention (gopath.nvim's shape): assertions raise PLAIN
-- errors, `H.check(name, fn)` pcalls `fn`, prints `[ OK ]` / `[FAIL]` and collects the name.

local H = {}

H.failures = {}
H.checks = 0
H.assertions = 0

function H.check(name, fn)
  H.checks = H.checks + 1
  local ok, err = pcall(fn)
  if ok then
    print(("[ OK ] %s"):format(name))
  else
    print(("[FAIL] %s: %s"):format(name, err))
    H.failures[#H.failures + 1] = name
  end
end

function H.eq(actual, expected, msg)
  H.assertions = H.assertions + 1
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(msg or "eq", tostring(expected), tostring(actual)), 2)
  end
end

function H.truthy(v, msg)
  H.assertions = H.assertions + 1
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

---A helper that is no assertion and never touches a counter.
function H.double(n)
  return n * 2
end

---Prints a failure line without recording it anywhere.
function H.shout(name)
  print("[FAIL] " .. name .. ": shouted")
end

---Calls an assertion inside a helper (so the assertion is not at the top of the stack).
function H.eq_twice(actual, expected, msg)
  H.eq(actual, expected, msg)
  H.eq(actual, expected, msg .. " (again)")
end

return H
