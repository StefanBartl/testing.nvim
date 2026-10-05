-- Fixture (never a spec of this repo). `return function(H)` with `H.match` and `H.LIMIT`, which only
-- the project's own harness provides. Three checks fail, two hold.

return function(H)
  H.eq(1, 2, "first wrong") -- MARK:h1
  H.eq(H.LIMIT, 3, "a non-function field is copied")
  H.match("abc", "^a", "match holds")
  H.match("abc", "^z", "match fails") -- MARK:h2
  local a, b, c = H.id(1, nil, 3)
  H.ok(a == 1 and b == nil and c == 3, "return values survive the wrapper, holes included")
  H.ok(false, "third wrong") -- MARK:h3
end
