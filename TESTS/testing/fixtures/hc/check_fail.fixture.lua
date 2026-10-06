-- Spec of the check-collector convention: two checks fail (inside H.check, so the harness swallows the
-- error), one holds, and one direct H.eq outside any check holds.

return function(H)
  H.check("holds", function()
    H.eq(1, 1, "one") -- MARK:c0
  end)
  H.check("fails first", function()
    H.eq(1, 2, "first wrong") -- MARK:c1
    H.eq(3, 3, "never reached")
  end)
  H.check("fails by raise", function()
    error("callback blew up", 0) -- MARK:c2
  end)
  H.eq(H.double(2), 4, "outside a check") -- MARK:c3
end
