-- Fixture harness (never a spec): it exports the code under test, `H.plug`, from a file outside its own directory
-- but reaches it by a path that is not normalized (`<this directory>/../h_export_plugin/emit.lua`), as a
-- `package.path` entry built from the harness location does. Textually that path starts with this directory;
-- the file is not below it.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.plug = dofile(here .. "/../h_export_plugin/emit.lua")

return H
