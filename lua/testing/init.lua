---@module 'testing'
---@brief Public facade of testing.nvim.
---@description
--- `setup(opts)` merges the options (see `testing.config`), registers `:Testing` and the keymap
--- actions. The test runner itself is not implemented yet; this is the skeleton it will grow in.

local M = {}

---Merge options, register the command and the keymaps. Safe to call twice.
---@param opts? Testing.ConfigOptions
---@return Testing.Module
function M.setup(opts)
  local config = require("testing.config")
  local problems = config.setup(opts)
  if #problems > 0 then
    require("testing.notify").get().warn("setup(): " .. table.concat(problems, "; "))
  end
  require("testing.bindings.usrcmds").register()
  require("testing.bindings.keymaps").register(config.get())
  return M
end

---The effective configuration (a reference, do not mutate).
---@return Testing.Config
function M.get_config()
  return require("testing.config").get()
end

---@type Testing.Module
return M
