-- Fixture harness at the ROOT of a project (never a spec): the code under test, `vendor/emit.lua`, lives below the
-- harness directory and is exported as `H.sut`. A function of `H` that comes from below a directory that is not a test directory is the
-- code under test, not the harness, however the directory is spelled.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))

local H = {}

function H.eq(a, b, msg)
  if a ~= b then
    error(("FAIL %s: expected %q, got %q"):format(msg or "", tostring(b), tostring(a)), 2)
  end
end

H.sut = dofile(here .. "/vendor/emit.lua")

return H
