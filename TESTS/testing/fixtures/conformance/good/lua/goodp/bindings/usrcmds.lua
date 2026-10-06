---@module 'goodp.bindings.usrcmds'
---@brief The user command of the fixture plugin: `:Goodp open|close` with completion.

local M = {}

local VALUES = { "open", "close" }

---@return nil
function M.setup()
  require("lib.nvim.bindings.usercmd").create("Goodp", function(args)
    vim.g.goodp_last = args.args
  end, {
    nargs = "?",
    desc = "Open or close the goodp window",
    complete = function()
      return VALUES
    end,
  })
end

return M
