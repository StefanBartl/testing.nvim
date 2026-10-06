---@module 'goodp.bindings.keymaps'
---@brief The keymaps of the fixture plugin, through the lib.nvim registry.

local M = {}

---@param user table|false|nil
---@return nil
function M.setup(user)
  require("lib.nvim.bindings.keymap").register("goodp", {
    actions = {
      open = {
        rhs = function()
          vim.cmd("Goodp open")
        end,
        desc = "open the goodp window",
      },
    },
  }, user)
end

return M
