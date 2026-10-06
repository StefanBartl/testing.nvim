-- A helper of the project prints a failure line and records nothing: still red.

return function(H)
  H.eq(1, 1, "a normal pass")
  H.shout("lost")
end
