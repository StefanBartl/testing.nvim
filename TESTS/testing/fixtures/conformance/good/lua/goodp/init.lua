---@module 'goodp'
---@brief A conformant fixture plugin: idempotent setup, switchable keymaps, documented bindings.

local M = {}

---@param opts? table
---@return nil
function M.setup(opts)
  local config = require("goodp.config").setup(opts)
  require("goodp.bindings.keymaps").setup(config.keymaps)
  require("goodp.bindings.usrcmds").setup()
  require("goodp.bindings.autocmds").setup()
end

return M
