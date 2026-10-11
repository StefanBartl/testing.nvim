-- Fixture (never a spec of this repo). A check inside a check: both fail, so the list holds two failures and the outer
-- call of the collector sees both come in. One of them is taken back out of the list: the other one is still a failure
-- of the file, the one that stays in the list.
return function(H)
  H.check("outer", function()
    H.check("inner", function()
      H.eq(1, 2, "in")
    end)
    H.eq(3, 4, "out")
  end)
  table.remove(H.failures)
end
