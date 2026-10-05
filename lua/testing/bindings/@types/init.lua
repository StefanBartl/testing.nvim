---@meta
---@module 'testing.bindings.@types'

-- #####################################################################
-- bindings/keymaps.lua

---@alias Testing.KeymapActions
--- The named keymap actions the plugin declares, keyed by action name. Each value is a
--- `Lib.Keymap.Action` from lib.nvim (default lhs, mode, rhs, desc); the user can move or drop every
--- one of them through `setup({ keymaps = { <action> = "<lhs>" | false } })`.
---| table<string, Lib.Keymap.Action>

return {}
