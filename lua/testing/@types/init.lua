---@meta
---@module 'testing.@types'

-- #####################################################################
-- init.lua

---@class Testing.Module
--- The public facade `require("testing")`.
---@field setup fun(opts?: Testing.ConfigOptions): Testing.Module Merge options, register the command and the keymaps. Safe to call twice.
---@field get_config fun(): Testing.Config The effective configuration (a reference, do not mutate).

return {}
