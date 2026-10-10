-- Fixture harness split over several files (never a spec), the helper files found through a path that is
-- RELATIVE to the working directory (`dofile("fixtures/...")`, `dofile("./fixtures/...")`, a `./?.lua` entry
-- of `package.path`): their chunk names are relative, and they are still the harness. The test sets the
-- working directory to TESTS/testing.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local relative = vim.fn.fnamemodify(here, ":.")
assert(not relative:find("^/"), "the working directory must be above this fixture")

local guard = dofile("./" .. relative .. "/guard.lua")
local nested = dofile(relative .. "/guard_nested.lua")

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.guarded = guard.guarded
H.util = { guarded = nested.guarded }

return H
