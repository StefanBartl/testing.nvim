---@module 'goodp.util'
---@brief A plain module with one optional integration.

local M = {}

---Is which-key installed?
---@return boolean
function M.has_which_key()
  local ok = pcall(require, "which-key")
  return ok
end

return M
