-- Fixture (never a spec of this repo). The spec is started by a framework of another file and asks "does this
-- fail?" with a pcall of its own: the question is answered. Both checks hold.

local support = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/h_wrap_support.lua")

return support.spec(function(H)
  local ok = pcall(function()
    H.eq(1, 2, "asked through a framework")
  end)
  H.eq(ok, false, "answered, though a framework of another file started the spec")
  H.eq(1, 1, "the file goes on")
end)
