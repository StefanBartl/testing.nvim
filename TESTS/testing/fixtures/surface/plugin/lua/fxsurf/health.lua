local M = {}

function M.check()
  vim.health.start("fxsurf")
  vim.health.ok("fixture")
end

return M
