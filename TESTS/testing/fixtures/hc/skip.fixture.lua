-- The skip convention: an optional dependency is missing, the spec says so and returns.

return function(H)
  if not H.LIMIT then
    print("skip  skip.fixture.lua: optional dependency not found")
    return
  end
end
