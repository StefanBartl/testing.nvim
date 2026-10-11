-- Fixture harness: the harness of this directory with a failure left in its list by a spec file that ran before (a
-- harness module that outlives a file).
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
local H = dofile(here .. "/harness.lua")
H.failures[1] = "left behind by an earlier file"
return H
