-- Fixture (never a spec of this repository): the real check inside the cleanup helper fails and the helper throws
-- the error away; the check must be recorded.
return function(H)
  H.try(function()
    H.eq(1, 2, "a real check inside the cleanup helper") -- MARK:c1
  end)
  H.eq(1, 1, "the file goes on")
end
