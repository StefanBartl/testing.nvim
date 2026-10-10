-- Harness of a fixture (never a spec of this repository): an assertion that delegates to another assertion.
local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %s, got %s"):format(msg, tostring(b), tostring(a)), 2)
  end
end

function H.pair(x, y, msg)
  H.eq(x[1], y[1], msg .. " (first)")
  if x[2] ~= y[2] then
    error("FAIL " .. msg .. " (second)", 2)
  end
end

return H
