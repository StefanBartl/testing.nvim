-- Fixture guard module for TESTS/testing/child_rpc_*_spec.lua: stands in for `testing.guard` so the
-- hook of the RPC child (`install(cfg)` once, `collect()` on demand) is tested without the real guards.
-- It is found first because the spec puts this directory in front of the checkout on the runtimepath.

local M = {}

local installed

---@param cfg table
function M.install(cfg)
  installed = cfg
  vim.g.fixture_guard_marker = cfg.marker or "no-marker"
  vim.g.fixture_guard_installs = (vim.g.fixture_guard_installs or 0) + 1
end

---@return table
function M.collect()
  return {
    spawned = { "fixture-spawn" },
    network = {},
    fs_outside_tmp = {},
    cfg_marker = installed and installed.marker or nil,
  }
end

return M
