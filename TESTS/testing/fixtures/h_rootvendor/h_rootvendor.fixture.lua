-- Fixture (never a spec of this repo). The harness sits in the root of the project and exports the plugin under
-- test (in `vendor/`) as `H.sut`; the plugin protects its callback and keeps the error. The spec's own pcall
-- around the call must not take over: the failed check is recorded. One check fails, two hold.

return function(H)
  local ok = pcall(function()
    H.sut.emit(function()
      H.eq(1, 2, "swallowed by the plugin in vendor/") -- MARK:r1
    end)
  end)
  H.eq(ok, true, "the spec's pcall saw no error")
  H.eq(1, 1, "the file goes on")
end
