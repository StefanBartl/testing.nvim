-- Fixture (never a spec of this repo). Two expected failures, the newest taken back out of the list, and a failure line
-- that is printed and recorded nowhere: the line of the failure that is gone is taken back with it, the other one is
-- still a failure line the adapter did not record.
return function(H)
  H.check("first fails", function()
    H.eq(1, 2, "first")
  end)
  H.check("second fails", function()
    H.eq(3, 4, "second")
  end)
  H.shout("lost")
  table.remove(H.failures)
end
