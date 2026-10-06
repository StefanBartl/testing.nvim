-- TESTS/testing/fixtures/cache/support.lua -- helpers of the cache and affected specs:
-- materialize the fixture project in a temporary directory and edit it.

local S = {}

local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))

---Seconds a fixture file is made older than now: a file younger than two seconds is "racy" for the stat
---pre-check and would be hashed every time.
S.AGE = 3600

---@param path string
---@param text string
---@param old? boolean Backdate the mtime (default true).
function S.write(path, text, old)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
  if old ~= false then
    local t = os.time() - S.AGE
    vim.uv.fs_utime(path, t, t)
  end
end

---A fresh copy of the fixture project.
---@param extra? table<string, string> More files (or replacements).
---@return string root
function S.project(extra)
  local files = dofile(dir .. "/project.lua")
  local root = vim.fs.normalize(vim.fn.tempname())
  for rel, text in pairs(files) do
    S.write(root .. "/" .. rel, text)
  end
  for rel, text in pairs(extra or {}) do
    S.write(root .. "/" .. rel, text)
  end
  return root
end

---Rewrite a file of the project (content changes, mtime moves forward by a minute so the stat differs).
---@param root string
---@param rel string
---@param text string
function S.edit(root, rel, text)
  S.write(root .. "/" .. rel, text, false)
  local t = os.time() - S.AGE + 60
  vim.uv.fs_utime(root .. "/" .. rel, t, t)
end

---@param path string
---@return string
function S.read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

---@param root string
function S.remove(root)
  vim.fn.delete(root, "rf")
end

---A passing Result-IR case of a file.
---@param file string
---@param name string
---@return table
function S.case(file, name)
  local result = require("testing.core.result")
  local c = result.new_case({ file = file, name = name })
  c.assertions[1] = { ok = true, kind = "ok" }
  return result.finish_case(c)
end

return S
