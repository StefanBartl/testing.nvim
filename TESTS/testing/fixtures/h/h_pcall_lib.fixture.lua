-- Fixture (never a spec of this repo). A failed check inside a callback that the PLUGIN protects is
-- recorded: its pcall would swallow a raise and the case would pass. One check fails, two hold.

return function(H)
  local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local plugin = dofile(here .. "/pcall_lib.lua")
  local emitted = plugin.emit(function()
    H.eq(1, 2, "swallowed by the plugin") -- MARK:p2
  end)
  H.ok(emitted, "the plugin saw no error")
  -- a pcall of the spec INSIDE the callback is the one that answers
  plugin.emit(function()
    local ok, err = pcall(function()
      H.eq(1, 2, "asked")
    end)
    H.ok(
      not ok and tostring(err):find("FAIL asked", 1, true) ~= nil,
      "the spec's own pcall answers"
    )
  end)
end
