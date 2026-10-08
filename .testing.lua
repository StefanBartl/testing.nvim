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
  -- The cache folder is named after this key, not after the absolute path of the checkout, so a cache restored
  -- on a CI runner with another checkout path is found (docs/CI-CACHE.md). It is a name only: every entry still
  -- carries its full spec key.
  cache = { project_key = "testing-nvim" },
  -- The pool_run_*_spec files run real warm-pool children, about a minute each on a loaded machine (one file did
  -- all of it and used 171 s of this deadline there; Windows is the slow system): the deadline is a safety net
  -- against a hang, not a performance gate.
  timeouts = { file_ms = 180000 },
  -- Dogfood: every guard is an ERROR here. A spec of this repository that leaves an autocmd, a buffer,
  -- a stub in package.preload or a runtimepath entry behind fails its own case, named precisely.
  -- Guards are safety nets for accidents, not a sandbox (docs/GUARDS.md).
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "error",
  },
  -- `testing conformance .` on this repository: the two entry scripts of the child editor end the editor when they
  -- are required (that is what an entry script of a child is), which K1 reports as a module that cannot be required.
  conformance = {
    waivers = {
      {
        check = "K1",
        file = "lua/testing/child/boot.lua",
        reason = "an entry script of the child editor: it ends the editor on purpose when it is required",
      },
      {
        check = "K1",
        file = "lua/testing/child/rpc_init.lua",
        reason = "an entry script of the RPC child editor: it ends the editor on purpose when it is required",
      },
    },
  },
  -- What the specs of this repository start ON PURPOSE (their subject is the process driver): real child
  -- editors (`nvim`), the process-tree kill of the driver (`taskkill`, `powershell` for the Windows process table), `git` for the run header,
  -- `stylua` for the migrate writer and `bash` for the generated test script.
  guard_allow = {
    -- `does-not-exist*`: specs of the start-failure path start an executable that is not there
    spawn = {
      "nvim",
      "git",
      "taskkill",
      "powershell",
      "stylua",
      "bash",
      "ps",
      "does-not-exist",
      "does-not-exist-nvim",
    },
  },
}
