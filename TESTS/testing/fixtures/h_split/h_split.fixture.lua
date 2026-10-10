-- Fixture (never a spec of this repo). The spec asks "does this fail?" through a harness helper that sits in
-- another file than harness.lua (also one that is only reachable through a table of `H`): the check must raise
-- into the spec's pcall. All four checks of the file hold.

return function(H)
  local ok, err = pcall(H.guarded, function()
    H.eq(1, 2, "asked through the split harness")
  end)
  H.eq(
    ok,
    false,
    "a failed check inside the spec's pcall raises through the helper of the second file"
  )
  H.eq(tostring(err):find("FAIL asked through", 1, true) ~= nil, true, "and carries its message")
  local ok2 = pcall(H.util.guarded, function()
    H.eq(1, 2, "asked through a table of the harness")
  end)
  H.eq(ok2, false, "also through a helper that sits in a table of the harness")
  H.eq(type(H.util), "table", "the table is the harness's own")
end
