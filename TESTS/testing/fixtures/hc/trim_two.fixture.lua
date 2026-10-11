-- Fixture (never a spec of this repo). Two expected failures, the NEWEST taken back out of the list: the first one is
-- still a failure of the file and the run must say so.
return function(H)
  H.check("first fails", function()
    H.eq(1, 2, "first")
  end)
  H.check("second fails", function()
    H.eq(3, 4, "second")
  end)
  table.remove(H.failures)
end
