-- TESTS/testing/guard_support.lua -- helpers shared by the guard specs (guard_*): run a scenario
-- script of fixtures/guard/ in a REAL child editor (lib.nvim.system.job, plain `nvim -l`; no RPC
-- driver involved) and read its result. Loaded with dofile by the specs; not a spec itself.

local S = {}

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
---testing.nvim checkout.
S.repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))
S.dir = vim.fs.dirname(vim.fs.normalize(this)) .. "/fixtures/guard"

local cache = {}

---@return string
local function lib_dir()
  local deps = require("testing.deps")
  local lib, why = deps.resolve("lib.nvim", S.repo)
  assert(lib, why)
  return lib.dir
end

---Run `fixtures/guard/<name>.fixture.lua` (every scenario, or only `only`) and return its result
---by scenario name. Results are cached per (name, only): the specs of one file share one child.
---@param name string
---@param only? string
---@return table<string, table> scenarios
---@return string raw stdout + stderr of the child
function S.run(name, only)
  local key = name .. "\0" .. tostring(only)
  if cache[key] then
    return cache[key].scenarios, cache[key].raw
  end
  local args = {
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    S.dir .. "/" .. name .. ".fixture.lua",
    S.repo,
    lib_dir(),
  }
  args[#args + 1] = only or "-"
  -- two directories of the RUNNER's own temp dir (SEC-47): the child's OS temp dir and a sibling
  -- that is outside of it, so a write there is a leak by definition
  local tmp, outside = vim.fn.tempname(), vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  vim.fn.mkdir(outside, "p")
  args[#args + 1] = tmp
  args[#args + 1] = outside
  local r = require("lib.nvim.system.job").start_blocking({
    command = vim.v.progpath,
    args = args,
    timeout_ms = 90000,
  })
  vim.fn.delete(tmp, "rf")
  vim.fn.delete(outside, "rf")
  local raw = (r.stdout or "") .. (r.stderr or "")
  local json = raw:match("GUARD%-RESULT:([^\n]*)")
  assert(
    json,
    ("scenario %s: no result line (exit %s):\n%s"):format(name, tostring(r.code), raw:sub(1, 2000))
  )
  local decoded = vim.json.decode(json, { luanil = { object = true, array = true } })
  local by_name = {}
  for _, c in ipairs(decoded) do
    by_name[c.name] = c
  end
  cache[key] = { scenarios = by_name, raw = raw }
  return by_name, raw
end

---Ids of the findings of a scenario, in order.
---@param case table
---@return string[]
function S.ids(case)
  local ids = {}
  for _, f in ipairs(case.findings or {}) do
    ids[#ids + 1] = f.id
  end
  return ids
end

---The findings of a scenario with a given id.
---@param case table
---@param id string
---@return table[]
function S.of(case, id)
  local out = {}
  for _, f in ipairs(case.findings or {}) do
    if f.id == id then
      out[#out + 1] = f
    end
  end
  return out
end

---Findings that make a case fail or warn (everything but `info`).
---@param case table
---@return table[]
function S.loud(case)
  local out = {}
  for _, f in ipairs(case.findings or {}) do
    if f.severity ~= "info" then
      out[#out + 1] = f
    end
  end
  return out
end

---Is there a finding with `id` whose message contains every plain `needles` entry?
---@param case table
---@param id string
---@param needles string[]
---@return table|nil
function S.find(case, id, needles)
  for _, f in ipairs(S.of(case, id)) do
    local all = true
    for _, n in ipairs(needles) do
      if not f.message:find(n, 1, true) then
        all = false
        break
      end
    end
    if all then
      return f
    end
  end
  return nil
end

return S
