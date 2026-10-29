---@module 'testing.bindings.keymaps'
---@brief Global keymaps of testing.nvim: one action, `hover`, without a default key.
---@description
--- The plugin declares its keymaps as named actions (`ACTIONS`) and binds them through
--- `lib.nvim.bindings.keymap.register`, so a user can move or drop each one with
--- `setup({ keymaps = { <action> = "<lhs>" | false } })`, or bind nothing with `keymaps = false`.
--- `hover` has no default lhs, so nothing is bound until the user names a key for it
--- (`keymaps = { hover = "<leader>th" }`).

local M = {}

---@type Testing.KeymapActions
M.ACTIONS = {
  -- No default key: the user opts in with `keymaps = { hover = "<lhs>" }`.
  hover = {
    rhs = function()
      require("testing.hover").show()
    end,
    desc = "last result of the test under the cursor",
  },
}

---Bind every declared action that the user has not dropped. A no-op while `ACTIONS` is empty; an action without a default and without a user key binds nothing.
---@param cfg Testing.Config
---@return boolean registered Whether anything was handed to lib.nvim
function M.register(cfg)
  if next(M.ACTIONS) == nil then
    return false
  end
  require("lib.nvim.bindings.keymap").register("testing", {
    prefix = "<leader>t",
    which_key = { group = "Testing" },
    actions = M.ACTIONS,
  }, cfg.keymaps)
  return true
end

return M
