-- TESTS/testing/fixtures/state_parallel_worker.lua -- one of several editors that write the state files of one
-- project at the same time (state_parallel_spec.lua). Run as
--   nvim --headless -u NONE -l state_parallel_worker.lua <id> <state dir> <go file> <repo> <lib.nvim root> <rounds>
-- It waits for the go file, then records `rounds` runs into every state file and prints the failures.

local id, state, go, repo, lib, rounds = arg[1], arg[2], arg[3], arg[4], arg[5], tonumber(arg[6])
package.path = table.concat({
  lib .. "/lua/?.lua",
  lib .. "/lua/?/init.lua",
  repo .. "/lua/?.lua",
  repo .. "/lua/?/init.lua",
  package.path,
}, ";")

local uv = vim.uv
local waited = 0
while not uv.fs_stat(go) and waited < 20000 do
  uv.sleep(2)
  waited = waited + 2
end

local timings = require("testing.run.timings")
local order = require("testing.run.order")
local shard = require("testing.run.shard")
local history = require("testing.history")
local green = require("testing.run.green")

local failures = {}
for k = 1, rounds do
  local file = ("w%s_%d_spec.lua"):format(id, k)
  local opts = { state_dir = state }
  local res = {
    cases = { { file = file, duration_ms = 3, status = "fail", id = file .. "::c" } },
    summary = { fail = 1 },
    run = { id = ("r%s_%d"):format(id, k) },
  }
  local steps = {
    function()
      return timings.record(repo, {}, { [file] = 3 }, opts)
    end,
    function()
      return order.record_state(repo, res, { state_dir = state, time = 1000 + k })
    end,
    function()
      return shard.record_durations(repo, res, nil, opts)
    end,
    function()
      return history.record(repo, res, {}, opts)
    end,
    function()
      return green.record(repo, res, { state_dir = state, time = 1000 + tonumber(id) * 100 + k })
    end,
  }
  for i, step in ipairs(steps) do
    local ok, a, b = pcall(step)
    if not ok or a == false then
      failures[#failures + 1] = ("step %d: %s"):format(i, tostring(ok and b or a))
    end
  end
end
io.stdout:write(table.concat(failures, "|"))
vim.cmd("qa!")
