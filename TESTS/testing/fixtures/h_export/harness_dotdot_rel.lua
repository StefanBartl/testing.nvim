-- Fixture harness (never a spec): like harness.lua, but the exported code under test is loaded through a path
-- RELATIVE to the working directory that goes up with `..` (the chunk name is `@../h_export_plugin/emit.lua`).
-- The test sets the working directory to the directory of this file.

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.plug = dofile("../h_export_plugin/emit.lua")

return H
