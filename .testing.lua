-- .testing.lua -- testing.nvim's own project configuration (it runs its own specs, no other runner).
--
-- Loaded (executed) by `scripts/testing.lua` from the project root. Every key is optional; what is
-- not named here keeps the default of lua/testing/config/DEFAULTS.lua (`project`).
-- Documented in docs/CONFIG.md.

return {
  -- Lua module root of this project.
  plugin = "testing",
  -- Where the specs live (relative to this directory).
  roots = { "TESTS" },
  -- Sniff the dialect per file. The specs of this repo are `return function(H)` files on
  -- TESTS/harness.lua.
  dialect = "auto",
  -- Entry for isolated child runs: puts this checkout and lib.nvim on the runtimepath.
  minit = "TESTS/minimal_init.lua",
  -- lib.nvim is resolved by the runner itself (it cannot run without it), so `deps` stays empty.
  deps = {},
}
