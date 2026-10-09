-- Fixture (never a spec of this repo). An assertion that fails INSIDE a protected call the spec wrote
-- raises (the spec asks "does this fail?"); outside of one it is recorded. One check fails, three hold.

return function(H)
  local ok, err = pcall(function()
    H.eq(1, 2, "demo")
  end)
  H.ok(
    not ok and tostring(err):find("FAIL demo", 1, true) ~= nil,
    "a failed check raises inside the spec's pcall"
  )
  local ok2, err2 = pcall(H.guarded, function()
    H.eq(1, 2, "guarded")
  end)
  H.ok(
    not ok2 and tostring(err2):find("FAIL guarded", 1, true) ~= nil,
    "and through a harness helper that guards"
  )
  H.guarded(function()
    H.eq(1, 2, "recorded") -- MARK:p1
  end)
  H.eq(1, 1, "the file goes on")
end
