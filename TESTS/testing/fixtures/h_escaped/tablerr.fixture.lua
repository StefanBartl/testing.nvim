-- Fixture (never a spec of this repository): the file ends with an error value that is no string.
return function(H)
  H.eq(1, 1, "holds")
  error({ code = 1 })
end
