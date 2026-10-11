-- Fixture (never a spec of this repository): an error that is no failed check stays an error of the file.
return function(H)
  H.eq(1, 1, "holds")
  local ok, err = pcall(function()
    error("boom")
  end)
  if not ok then
    error(err, 0)
  end
end
