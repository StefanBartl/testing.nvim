-- Fixture (never a spec of this repository): like rethrow0, with `assert(ok, err)`.
return function(H)
  local ok, err = pcall(function()
    H.eq(1, 2, "the check that fails") -- MARK:e3
  end)
  assert(ok, err)
end
