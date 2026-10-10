-- Fixture harness (never a spec) that is split over several files AND whose table outlives the file: every run
-- gets the same `H`, its functions wrapped in place by the run before. The helper's chunk must stay part of the
-- harness (and no wrapper may pile up on a wrapper).

local KEY = "__testing_h_split_shared_fixture"

local H = rawget(_G, KEY)
if H then
  return H
end

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local guard = dofile(here .. "/guard.lua")
local nested = dofile(here .. "/guard_nested.lua")

H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.guarded = guard.guarded
H.util = { guarded = nested.guarded }

rawset(_G, KEY, H)

return H
