-- Fixture (never a spec of this repository): no check at all, only the cleanup helper is called.
return function(H)
  H.try(function()
    local _ = 1 + 1
  end)
end
