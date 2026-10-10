-- Fixture (never a spec of this repo). The harness exports the plugin under test as `H.plug`, loaded by a
-- path with a `..` in it; the plugin protects its callback and keeps the error. The spec's own pcall around the
-- call must not take over: the failed check is recorded. One check fails, two hold.

return function(H)
  local ok = pcall(function()
    H.plug.emit(function()
      H.eq(1, 2, "swallowed by the plugin behind a dot-dot path") -- MARK:d1
    end)
  end)
  H.eq(ok, true, "the spec's pcall saw no error")
  H.eq(1, 1, "the file goes on")
end
