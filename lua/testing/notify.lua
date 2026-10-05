---@module 'testing.notify'
---@brief Notifier bound to the configured prefix.
---@description
--- Thin re-export of `lib.nvim.notify` (LUA-03): the only thing added is the prefix from the
--- configuration. Nothing else in the plugin calls `vim.notify` directly.

local M = {}

---@return table notifier `info`, `warn`, `error`, `debug` as in lib.nvim.notify
function M.get()
  return require("lib.nvim.notify").create(require("testing.config").get().notify_prefix)
end

return M
