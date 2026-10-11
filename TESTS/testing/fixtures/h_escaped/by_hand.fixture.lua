-- Fixture (never a spec of this repository): an error that reads like a failed check of the convention but did not come
-- through a wrapped helper, after a failed check the spec had asked about and got its answer to. It is an error of the
-- file, not a failure of the check that was answered.
return function(H)
  local asked = pcall(function()
    H.eq(1, 2, "asked and answered")
  end)
  H.ok(not asked, "answered")
  error("FAIL raised by hand") -- MARK:e4
end
