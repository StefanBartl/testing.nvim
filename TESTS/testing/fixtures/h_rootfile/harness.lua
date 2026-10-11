-- Fixture harness at the ROOT of a project (never a spec): the code under test, `emit.lua`, is a single file in the same
-- directory and is exported as `H.sut`. Only the harness file and the files below a test directory are the harness: a
-- file in the root may be the plugin.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.sut = dofile(here .. "/emit.lua")

return H
