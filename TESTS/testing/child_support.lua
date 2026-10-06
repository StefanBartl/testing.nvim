-- TESTS/testing/child_support.lua -- helpers shared by the specs of the isolated runner (child_*, pool_*,
-- run_isolated_*): temp projects, real children through `testing.run.isolated`, process probes.
-- Loaded with dofile by the specs; it is not a spec itself (no `_spec` suffix).

local S = {}

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
---testing.nvim checkout.
S.repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))

local made = {}

---@param path string
---@param text string
function S.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
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

---A fresh project directory (removed by `S.cleanup`).
---@return string root
function S.new_root()
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-iso"
  vim.fn.mkdir(root .. "/TESTS", "p")
  made[#made + 1] = root
  return root
end

function S.cleanup()
  for _, dir in ipairs(made) do
    pcall(vim.fn.delete, dir, "rf")
  end
  made = {}
end

---@param root string
---@param rel string
---@param dialect? string
---@return table
function S.entry(root, rel, dialect)
  return { path = root .. "/" .. rel, rel = rel, dialect = dialect or "a" }
end

---Write `files` (rel -> text) into `root` and return their entries in the order of `order`.
---@param root string
---@param files table<string, string>
---@param order string[]
---@param dialect? string
---@return table[]
function S.project(root, files, order, dialect)
  local entries = {}
  for _, rel in ipairs(order) do
    S.write(root .. "/" .. rel, files[rel])
    entries[#entries + 1] = S.entry(root, rel, dialect)
  end
  return entries
end

---Default run options of a child run (what `options.of` would give).
---@param over? table
---@return table
function S.options(over)
  return vim.tbl_extend("force", {
    isolated = "file",
    jobs = 1,
    host = "c",
    host_given = false,
    filetype = true,
    assertions = "error",
    env_allow = {},
  }, over or {})
end

---Run entries through the real isolated driver (real child editors).
---@param root string
---@param entries table[]
---@param extra? table Overrides of the `isolated.run` options (`options` is merged key by key).
---@return Testing.Inproc.Report
function S.run(root, entries, extra)
  extra = extra or {}
  local options_mod = require("testing.run.options")
  local prepend, append, child_env =
    options_mod.child_rtp({ root = root, project = { deps = {} }, args = {} })
  local opts = {
    root = root,
    files = entries,
    options = S.options(extra.options),
    rtp_prepend = prepend,
    rtp = append,
    child_env = child_env,
    grace_ms = 300,
    poll_ms = 10,
  }
  for k, v in pairs(extra) do
    if k ~= "options" then
      opts[k] = v
    end
  end
  return require("testing.run.isolated").run(opts)
end

---The case of a report whose file is `rel` (first one), or nil.
---@param report table
---@param rel string
---@return Testing.Result.Case|nil
function S.case_of(report, rel)
  for _, c in ipairs(report.result.cases) do
    if c.file == rel then
      return c
    end
  end
  return nil
end

---`file:status` per case, in IR order.
---@param report table
---@return string[]
function S.statuses(report)
  local out = {}
  for _, c in ipairs(report.result.cases) do
    out[#out + 1] = c.file .. ":" .. c.status
  end
  return out
end

---Is a process alive?
---@param pid integer
---@return boolean
function S.alive(pid)
  return require("testing.child").alive(pid)
end

return S
