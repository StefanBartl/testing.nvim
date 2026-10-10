-- Stands for the plugin under test (never a spec): it runs a callback protected and keeps the error to itself.
-- The directory name starts with the name of the harness directory next to it (fixtures/h_export) on purpose: a
-- harness directory is a directory, not a prefix of a path.

local M = {}

---@param callback fun()
---@return boolean ok False when the callback raised.
function M.emit(callback)
  local ok = pcall(callback)
  return ok
end

return M
