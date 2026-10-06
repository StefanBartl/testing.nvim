-- TESTS/testing/fixtures/cache/project.lua -- the files of a small fixture project for the cache and
-- the affected selection. A table `relative path -> content`; the specs write it into a temporary
-- directory (the spec files below are written there as `*_spec.lua`, they are not specs of THIS repo).
--
--   lua/proj/init.lua   requires proj.a
--   lua/proj/a.lua      requires proj.b
--   lua/proj/b.lua      leaf
--   lua/proj/c.lua      leaf, unrelated to a and b
--   lua/proj/lazy.lua   requires proj.sub.<computed>
--   lua/proj/sub/x.lua  leaf below the computed prefix
--   TESTS/proj/*_spec.lua   one spec per situation (name tells which)

return {
  [".testing.lua"] = "return { roots = { 'TESTS' } }\n",
  ["README.md"] = "# proj\n",
  ["docs/x.md"] = "docs\n",
  ["docs/data.txt"] = "data v1\n",
  [".github/workflows/ci.yml"] = "name: ci\n",
  ["plugin/proj.lua"] = "-- plugin entry\n",
  ["lua/proj/init.lua"] = 'local M = {}\nM.a = require("proj.a")\nreturn M\n',
  ["lua/proj/a.lua"] = 'local b = require("proj.b")\nreturn { v = b.v }\n',
  ["lua/proj/b.lua"] = "return { v = 1 }\n",
  ["lua/proj/c.lua"] = "return { c = 1 }\n",
  ["lua/proj/lazy.lua"] = 'return setmetatable({}, { __index = function(_, k) return require("proj.sub." .. k) end })\n',
  ["lua/proj/sub/x.lua"] = "return { x = 1 }\n",
  ["TESTS/harness.lua"] = "return {}\n",
  ["TESTS/proj/helper.lua"] = "return { helper = 1 }\n",
  ["TESTS/proj/a_spec.lua"] = 'local a = require("proj.a")\nreturn function(H) H.eq(a.v, 1, "a") end\n',
  ["TESTS/proj/c_spec.lua"] = 'local c = require("proj.c")\nreturn function(H) H.eq(c.c, 1, "c") end\n',
  ["TESTS/proj/init_spec.lua"] = 'local p = require("proj")\nreturn function(H) H.ok(p.a, "init") end\n',
  ["TESTS/proj/lazy_spec.lua"] = 'local l = require("proj.lazy")\nreturn function(H) H.eq(l.x.x, 1, "lazy") end\n',
  ["TESTS/proj/pure_spec.lua"] = "return function(H) H.eq(1 + 1, 2, 'pure') end\n",
  ["TESTS/proj/proc_spec.lua"] = 'return function(H) local r = vim.system({ "nvim", "--version" }):wait() H.ok(r.code == 0, "proc") end\n',
  ["TESTS/proj/time_spec.lua"] = 'return function(H) H.ok(os.time() > 0, "time") end\n',
  ["TESTS/proj/random_spec.lua"] = 'return function(H) H.ok(math.random() >= 0, "random") end\n',
  ["TESTS/proj/env_spec.lua"] = 'return function(H) H.ok(os.getenv("PROJ_TOKEN") ~= "x", "env") end\n',
  ["TESTS/proj/envdyn_spec.lua"] = 'local name = "PROJ_" .. "TOKEN"\nreturn function(H) H.ok(os.getenv(name) ~= "x", "env") end\n',
  ["TESTS/proj/unresolved_spec.lua"] = 'local m = require("nonexistent.mod")\nreturn function(H) H.ok(m, "m") end\n',
  ["TESTS/proj/off_spec.lua"] = "-- @cache off\nreturn function(H) H.ok(true, 'off') end\n",
  ["TESTS/proj/reads_spec.lua"] = 'return function(H)\n  local f = io.open(H.root .. "/README.md", "rb")\n  H.ok(f, "reads")\nend\n',
  ["TESTS/proj/inputs_spec.lua"] = "-- @cache-inputs docs/data.txt\nreturn function(H) H.ok(true, 'inputs') end\n",
  ["TESTS/proj/escape_spec.lua"] = "-- @cache-inputs ../outside.txt\nreturn function(H) H.ok(true, 'escape') end\n",
}
