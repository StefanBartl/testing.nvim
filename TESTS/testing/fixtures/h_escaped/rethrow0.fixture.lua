-- Fixture (never a spec of this repository): the body is wrapped in a pcall of the spec's own, the spec cleans up and
-- raises the error again as it is. The first failed check ends the file: a failure of THAT check, with its line.
return function(H)
  H.eq(1, 1, "holds before")
  local ok, err = pcall(function()
    H.eq(1, 2, "the check that fails") -- MARK:e1
    H.eq(2, 2, "never reached")
  end)
  if not ok then
    error(err, 0)
  end
end
