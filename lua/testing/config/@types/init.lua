---@meta
---@module 'testing.config.@types'

-- #####################################################################
-- config/init.lua, config/DEFAULTS.lua

---@alias Testing.KeymapsConfig
--- Overrides for the plugin's named keymap actions, keyed by action name.
--- Each value is the new left-hand side, a list of left-hand sides, or `false` to drop that action.
--- `false` instead of a table binds no key at all.
---| table<string, string|string[]|false>
---| false

---@class Testing.Config
--- The effective configuration: `DEFAULTS` with the user's valid options merged on top.
---@field notify_prefix string Prefix of every message shown through lib.nvim.notify. Non-empty.
---@field keymaps Testing.KeymapsConfig Named keymap actions to rebind or drop; empty by default.

---@class Testing.ConfigOptions
--- What the user passes to `setup()`: every key of `Testing.Config`, each optional.
---@field notify_prefix? string
---@field keymaps? Testing.KeymapsConfig

return {}
