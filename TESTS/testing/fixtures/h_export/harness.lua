-- Fixture harness (never a spec): it exports the code under test, `H.plug`, from a file OUTSIDE its own directory
-- (fixtures/h_export_plugin/emit.lua stands for the plugin; its directory name starts with this one's). A function
-- of `H` that comes from there is not the harness.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.plug = dofile(vim.fs.normalize(here .. "/../h_export_plugin/emit.lua"))

return H
