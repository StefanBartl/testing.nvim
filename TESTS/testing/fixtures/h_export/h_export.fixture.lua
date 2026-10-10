-- Fixture (never a spec of this repo). The harness exports the plugin under test as `H.plug`; the plugin
-- protects its callback and keeps the error. The spec cleans up with a pcall of its own around the call, and
-- that pcall must not take over: the failed check is recorded. One check fails, two hold.

return function(H)
  local ok = pcall(function()
    H.plug.emit(function()
      H.eq(1, 2, "swallowed by the plugin the harness exports") -- MARK:x1
    end)
  end)
  H.eq(ok, true, "the spec's pcall saw no error")
  H.eq(1, 1, "the file goes on")
end
