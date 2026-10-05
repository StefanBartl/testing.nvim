-- Fixture (never a spec of this repo: no `_spec.lua` suffix). Dialect A, copying lib.nvim's calling
-- convention. Two of four checks fail; a runner that stops at the first failure sees only one.
-- Lines marked `MARK:<name>` are looked up by the specs that run this file.

return function(H)
  H.eq(1, 2, "first wrong") -- MARK:a1
  H.eq("same", "same", "holds")
  H.ok(false, "second wrong") -- MARK:a2
  H.ok(true, "holds too")
end
