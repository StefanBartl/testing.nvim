-- Stands for the plugin under test (never a spec): it runs a callback protected and keeps the error to itself.

local M = {}

---@param callback fun()
---@return boolean ok False when the callback raised.
function M.emit(callback)
  local ok = pcall(callback)
  return ok
end

return M
