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
}
