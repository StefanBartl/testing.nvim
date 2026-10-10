-- Fixture (never a spec of this repo). A spec that tests the harness: an EXPECTED failure is taken back out of the
-- failure list, so the run is green; the failure after it is real and must still be seen.
return function(H)
  H.check("expected to fail", function()
    H.eq(1, 2, "on purpose")
  end)
  table.remove(H.failures)
  H.check("holds", function()
    H.eq(1, 1, "holds")
  end)
end
