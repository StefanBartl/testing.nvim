-- Fixture (never a spec of this repository): a runtime error of the spec stays an error of the file.
return function(H)
  H.eq(1, 1, "holds")
  local nothing = H.missing_on_purpose
  return nothing.field
end
