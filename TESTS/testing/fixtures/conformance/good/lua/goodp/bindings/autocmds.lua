---@module 'goodp.bindings.autocmds'
---@brief The autocommands of the fixture plugin: one named group, cleared on every setup().

local M = {}

---@return nil
function M.setup()
  local autocmd = require("lib.nvim.bindings.autocmd")
  autocmd.group("GoodpGroup", true)
  autocmd.create("BufReadPost", function() end, {
    group = "GoodpGroup",
    desc = "goodp: note the opened buffer",
  })
end

return M
