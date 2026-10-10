-- Harness of a fixture (never a spec of this repository): a cleanup helper that throws the error of its callback
-- away, followed by the doc comment of the NEXT function, which says what an assertion does.
local H = {}

---Cleanup helper: runs fn and ignores whatever it raises.
function H.try(fn)
  pcall(fn)
end

---Assert equality; a mismatch raises "FAIL ..." through error() so the runner sees it.
function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %s, got %s"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

return H
