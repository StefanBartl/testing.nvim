-- An assertion helper that calls another assertion: recorded once, a failure inside is one failure.

return function(H)
  H.check("nested helper holds", function()
    H.eq_twice(2, 2, "twice")
  end)
  H.check("nested helper fails", function()
    H.eq_twice(2, 3, "twice wrong")
  end)
end
