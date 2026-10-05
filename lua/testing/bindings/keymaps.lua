---@module 'testing.bindings.keymaps'
---@brief Global keymaps of testing.nvim: there are none yet.
---@description
--- The plugin declares its keymaps as named actions (`ACTIONS`) and binds them through
--- `lib.nvim.bindings.keymap.register`, so a user can move or drop each one with
--- `setup({ keymaps = { <action> = "<lhs>" | false } })`, or bind nothing with `keymaps = false`.
--- `ACTIONS` is empty until the runner has an action worth a key, so nothing is bound by default.

local M = {}

---@type Testing.KeymapActions
M.ACTIONS = {}

---Bind every declared action that the user has not dropped. A no-op while `ACTIONS` is empty.
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
