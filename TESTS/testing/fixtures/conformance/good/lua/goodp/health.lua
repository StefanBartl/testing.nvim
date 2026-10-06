---@module 'goodp.health'
---@brief `:checkhealth goodp`.

local M = {}

---@return nil
function M.check()
  vim.health.start("goodp")
  vim.health.ok("goodp is loaded")
  if pcall(require, "lib.nvim.bindings.keymap") then
    vim.health.ok("lib.nvim is available")
  else
    vim.health.error("lib.nvim is missing")
  end
  if pcall(require, "which-key") then
    vim.health.ok("which-key is available")
  else
    vim.health.info("which-key is not installed (optional)")
  end
end

return M
