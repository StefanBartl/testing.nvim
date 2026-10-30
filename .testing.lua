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
  -- Every spec file runs in a child editor of its own, four at a time. `auto` would run all files one after the other
  -- in ONE editor, where `--jobs` changes nothing: 8 minutes against 2 for this suite (187 files, many of which
  -- start editors themselves), and nothing leaks from one file into the next.
  isolated = "file",
  jobs = 4,
  -- Entry for isolated child runs: puts this checkout and lib.nvim on the runtimepath.
  minit = "TESTS/minimal_init.lua",
  -- lib.nvim is resolved by the runner itself (it cannot run without it), so `deps` stays empty.
  deps = {},
  -- Specs that start the runner on fixture projects of their own (`scripts/testing.lua <tmp>`) inherit the trust
  -- decision of `scripts/test.sh` (`TESTING_TRUST=1`); on CI the built-in `CI` does the same (docs/CONFIG.md).
  env_allow = { "TESTING_TRUST" },
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
    -- gated (pilot of conformance-gate-per-repo): a failed check makes `scripts/test.sh conformance` exit 1
    gate = true,
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
  -- `scripts/test.sh ci` (docs/CI.md): the pipeline of this repository, run locally. `full` checks what the CI
  -- workflow checks (stylua, luacheck with the workflow's paths, the specs, the conformance gate); `fast` is the
  -- quick check before a push. `strict` adds the LuaLS diagnostics (`luals`, held at zero, measured with the library
  -- the editor gives LuaLS: docs/CI.md): about a minute more, so not in `full`, which the pre-push hook and the
  -- proofs run.
  ci = {
    profiles = {
      fast = { "stylua", "luacheck" },
      full = { "fast", "suite", "conformance" },
      strict = { "full", "luals" },
    },
    steps = {
      luacheck = { preset = "luacheck", args = { "lua", "TESTS", "scripts", "plugin" } },
    },
  },
  -- What the specs of this repository start ON PURPOSE (their subject is the process driver): real child
  -- editors (`nvim`), the process-tree kill of the driver (`taskkill`, `powershell` for the Windows process table), `git` for the run header,
  -- `stylua` for the migrate writer, `bash` for the generated test script and `cmd` for the 8.3 short name of a directory
  -- (the sandbox-long-temp spec); `luacheck` and `lua-language-server` for `testing lint` and the lint
  -- tools of `:checkhealth testing`.
  guard_allow = {
    -- `does-not-exist*`: specs of the start-failure path start an executable that is not there
    spawn = {
      "nvim",
      "git",
      "taskkill",
      "powershell",
      "stylua",
      "luacheck",
      "lua-language-server",
      "bash",
      "cmd",
      "ps",
      "does-not-exist",
      "does-not-exist-nvim",
    },
  },
}
