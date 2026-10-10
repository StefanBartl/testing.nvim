-- Fixture (never a spec of this repository): the failure of the inner check belongs to the outer assertion.
return function(H)
  H.pair({ 1, 2 }, { 2, 2 }, "delegating") -- MARK:n1
  H.eq(1, 1, "holds")
end
