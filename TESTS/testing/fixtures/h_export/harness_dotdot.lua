-- Fixture harness (never a spec): like harness.lua, but the chunk name of the exported code under test is spelled
-- with `..` and not normalized (`<dir of this file>/../h_export_plugin/emit.lua`): textually it starts with the
-- directory of this file, in fact it is outside.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.plug = dofile(here .. "/../h_export_plugin/emit.lua")

return H
