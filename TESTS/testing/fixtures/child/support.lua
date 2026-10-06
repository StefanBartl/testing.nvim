-- TESTS/testing/fixtures/child/support.lua -- helpers of the RPC child specs (not a spec itself).

local S = {}

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
---testing.nvim checkout.
S.repo = vim.fs.dirname(
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here)))))
)
S.fixtures = vim.fs.dirname(vim.fs.normalize(here))
S.minit = S.fixtures .. "/plugin_fixture.lua"

---@type table[]
local children = {}
---@type string[]
local dirs = {}

---Spawn an RPC child for a spec (killed by `S.cleanup`). The guard is off unless the test names one: these
---specs test the driver, not the guards of another module.
---@param over? table
---@return table child
function S.spawn(over)
  local opts = vim.tbl_extend("force", {
    root = S.repo,
    guard = false,
    call_timeout_ms = 20000,
    trace_dir = S.new_dir(),
  }, over or {})
  local child, err = require("testing.rpc").spawn(opts)
  assert(child, "spawn failed: " .. tostring(err))
  children[#children + 1] = child
  return child
end

---A scratch directory (removed by `S.cleanup`).
---@return string
function S.new_dir()
  local d = vim.fs.normalize(vim.fn.tempname()) .. "-rpc"
  vim.fn.mkdir(d, "p")
  dirs[#dirs + 1] = d
  return d
end

function S.cleanup()
  for _, c in ipairs(children) do
    pcall(c.kill)
  end
  children = {}
  for _, d in ipairs(dirs) do
    pcall(vim.fn.delete, d, "rf")
  end
  dirs = {}
end

---Run `body`, then clean up whatever happened; a failure of the body is re-raised.
---@param body fun()
function S.run(body)
  local ok, err = xpcall(body, debug.traceback)
  S.cleanup()
  if not ok then
    error(err, 0)
  end
end

---Is a process alive?
---@param pid integer
---@return boolean
function S.alive(pid)
  return require("testing.child").alive(pid)
end

---Wait (event loop running) until `pred()` is true.
---@param ms integer
---@param pred fun(): boolean
---@return boolean
function S.wait(ms, pred)
  return vim.wait(ms, pred, 10)
end

---@param path string
---@return string|nil
function S.slurp(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

return S
