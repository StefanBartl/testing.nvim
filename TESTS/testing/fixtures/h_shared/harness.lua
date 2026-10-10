-- Fixture harness (never a spec) whose table outlives the file: every run of a spec gets the same `H`, with
-- whatever an earlier run left in it (a retry, a watch run). The functions of `H` are wrapped in place, so
-- the second run wraps what the first one wrapped.

local KEY = "__testing_h_shared_fixture"

local H = rawget(_G, KEY)
if H then
  return H
end

H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

rawset(_G, KEY, H)

return H
