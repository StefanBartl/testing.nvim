-- Fixture harness split over several files (never a spec): `H.eq` lives here, `H.guarded` comes from
-- guard.lua, `H.util.guarded` from guard_nested.lua. The protected call of a helper is the harness's when its file
-- sits below the directory of this harness.lua (also one table level down).

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local guard = dofile(here .. "/guard.lua")
local nested = dofile(here .. "/guard_nested.lua")

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.guarded = guard.guarded
H.util = { guarded = nested.guarded }

return H
