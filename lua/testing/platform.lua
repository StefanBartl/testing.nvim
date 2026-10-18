---@module 'testing.platform'
--- The one place that says which system this process runs on. `lib.nvim.cross.platform` is the source (LUA-07); a child
--- process that boots without lib.nvim on its runtimepath (the pooled guard children) falls back to the editor's own
--- `has()`, which answers the same for the two systems that matter here.
---
--- Functions, not constants: a module that wants a constant at load time calls them once.

local M = {}

---@param module string
---@param feature string
---@return boolean
local function ask(module, feature)
  local ok, fn = pcall(require, module)
  if ok and type(fn) == "function" then
    local called, value = pcall(fn)
    if called and type(value) == "boolean" then
      return value
    end
  end
  return vim.fn.has(feature) == 1
end

---Native Windows (not WSL).
---@return boolean
function M.is_windows()
  return ask("lib.nvim.cross.platform.is_windows", "win32")
end

---macOS.
---@return boolean
function M.is_macos()
  return ask("lib.nvim.cross.platform.is_macos", "mac")
end

---Do paths differ in case only where the file system does not tell them apart? (Windows and, by default, macOS.)
---@return boolean
function M.is_case_insensitive()
  return M.is_windows() or M.is_macos()
end

return M
