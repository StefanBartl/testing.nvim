---@module 'goodp.config'
---@brief Validated, merged configuration of the fixture plugin.

local M = {}

local current = vim.deepcopy(require("goodp.config.DEFAULTS"))

---@param opts any
---@return nil
function M.validate(opts)
  vim.validate("opts", opts, "table")
  if opts.keymaps ~= nil and type(opts.keymaps) ~= "table" and opts.keymaps ~= false then
    error("goodp: keymaps must be a table or false", 0)
  end
end

---@param opts? table
---@return Goodp.Config
function M.setup(opts)
  opts = opts or {}
  M.validate(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(require("goodp.config.DEFAULTS")), opts)
  return current
end

return M
