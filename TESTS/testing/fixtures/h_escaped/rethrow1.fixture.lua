-- Fixture (never a spec of this repository): like rethrow0, but the error is raised again with a position in front
-- (`error(err)` puts `file:line: ` before the text).
return function(H)
  local ok, err = pcall(function()
    H.eq(1, 2, "the check that fails") -- MARK:e2
  end)
  if not ok then
    error(err)
  end
end
