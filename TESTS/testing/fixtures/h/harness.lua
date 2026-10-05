-- Fixture harness of dialect h: the convention of the fleet's own TESTS/harness.lua files
-- (a failed check raises `error("FAIL ...", 2)`) with helpers no fixed shim knows.

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

function H.ok(v, msg)
  if not v then
    error(("FAIL %s: expected truthy, got %q"):format(msg or "", tostring(v)), 2)
  end
end

function H.match(s, pat, msg)
  if not tostring(s):find(pat) then
    error(("FAIL %s: %q does not match %q"):format(msg or "", tostring(s), pat), 2)
  end
end

---A helper's own bug: not an assertion failure.
function H.boom()
  error("helper bug", 0)
end

---Returns every argument, holes included.
function H.id(...)
  return ...
end

H.LIMIT = 3

return H
