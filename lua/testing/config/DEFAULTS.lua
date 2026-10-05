---@module 'testing.config.DEFAULTS'
---@brief Plugin-side defaults of testing.nvim: pure data, no side effects at require time.
---@description
--- Every key of `Testing.Config` appears here with its default. The file only names values: no
--- environment lookup, no filesystem access (LUA-06), so `require("testing.config.DEFAULTS")` is
--- safe from docs generators and specs.

---@type Testing.Config
local DEFAULTS = {
  -- Prefix of every message the plugin shows through lib.nvim.notify.
  notify_prefix = "[testing]",
  -- Named keymap actions (action name -> lhs | list of lhs | false). The plugin has no action
  -- yet, so nothing is bound by default; the table is where a user spec rebinds or drops them.
  keymaps = {},
}

return DEFAULTS
