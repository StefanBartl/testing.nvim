-- Fixture (never a spec of this repo). A framework of another file runs the spec under a pcall of its own and
-- keeps the error: that pcall is not the spec's, so the failed check is recorded. One check fails, two hold.

local support = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/h_wrap_support.lua")

return support.spec_swallow(function(H)
  H.eq(1, 1, "holds")
  H.eq(1, 2, "swallowed by the framework's pcall") -- MARK:w1
  H.eq(2, 2, "holds as well")
end)
