-- .testing.lua -- configuration of testing.nvim for this project.
-- Loading this file executes it (same trust as running the specs). Every key is optional;
-- run `nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua doctor .` to
-- see the effective configuration.
return {
  -- Lua module root of the project.
  plugin = @@PLUGIN|lua@@,
  -- Dependencies (directory names) that are put on the runtimepath for the run.
  -- Each is looked up in: $<NAME>_DIR, .deps/<name>, ../<name>, stdpath('data')/lazy/<name>.
  deps = @@DEPS|lua@@,
  -- A new project starts strict, as the fleet runs: a leak (a file written outside the temp dir,
  -- state a spec leaves behind, an error in a scheduled callback, a prompt, a deprecation) fails
  -- the case. Lower one to "warn" only with a comment that says why.
  -- Spawned processes and network connections are only reported (warn); list the expected ones in
  -- guard_allow and set process_net = "error" to fail on anything else.
  guards = {
    fs = "error",
    state = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    process_net = "warn",
  },
  -- Legitimate writers and spawns, one line each with a sentence why (docs/GUARDS.md of testing.nvim).
  guard_allow = { fs = {}, spawn = {}, network = {} },
}
