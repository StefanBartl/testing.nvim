-- TESTS/testing/surface_support.lua -- helpers of the surface_* specs (not a spec itself): the fixture plugin
-- copied into a temp directory, real RPC children that have testing.nvim and lib.nvim on the runtimepath.

local S = {}

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
---testing.nvim checkout.
S.repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))
S.fixture_src = vim.fs.dirname(vim.fs.normalize(this)) .. "/fixtures/surface/plugin"

---@type table[]
local children = {}
---@type string[]
local dirs = {}

---@param src string
---@param dst string
local function copy_tree(src, dst)
  vim.fn.mkdir(dst, "p")
  for name, kind in vim.fs.dir(src) do
    if kind == "directory" then
      copy_tree(src .. "/" .. name, dst .. "/" .. name)
    else
      local f = assert(io.open(src .. "/" .. name, "rb"))
      local text = f:read("*a")
      f:close()
      local o = assert(io.open(dst .. "/" .. name, "wb"))
      o:write(text)
      o:close()
    end
  end
end

---A scratch directory (removed by `S.cleanup`).
---@return string
function S.new_dir()
  local d = vim.fs.normalize(vim.fn.tempname()) .. "-surface"
  vim.fn.mkdir(d, "p")
  dirs[#dirs + 1] = d
  return d
end

---The fixture plugin copied to a fresh temp directory.
---@return string root
function S.fixture()
  local root = S.new_dir() .. "/fxsurf.nvim"
  copy_tree(S.fixture_src, root)
  return root
end

---Directories testing.nvim and lib.nvim are loaded from (the checkouts that run the spec).
---@return string[]
function S.rtp_prepend()
  local deps = require("testing.deps")
  local lib, why = deps.resolve("lib.nvim", deps.self_dir())
  assert(lib, why)
  return { deps.self_dir(), lib.dir }
end

---An RPC child on a project root (killed by `S.cleanup`).
---@param root string
---@param over? table
---@return table child
function S.spawn(root, over)
  local opts = vim.tbl_extend("force", {
    root = root,
    minit = root .. "/TESTS/minimal_init.lua",
    rtp = { root },
    rtp_prepend = S.rtp_prepend(),
    guard = false,
    call_timeout_ms = 20000,
    trace_dir = S.new_dir(),
  }, over or {})
  local child, err = require("testing.rpc").spawn(opts)
  assert(child, "spawn failed: " .. tostring(err))
  children[#children + 1] = child
  return child
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

---Entries of a surface by id.
---@param surface table
---@return table<string, table>
function S.by_id(surface)
  local out = {}
  for _, e in ipairs(surface.entries) do
    out[e.id] = e
  end
  return out
end

---Ids of a surface, in order.
---@param surface table
---@param kind? string
---@return string[]
function S.ids(surface, kind)
  local out = {}
  for _, e in ipairs(surface.entries) do
    if kind == nil or e.kind == kind then
      out[#out + 1] = e.id
    end
  end
  return out
end

return S
