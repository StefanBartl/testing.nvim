---@meta
---@module 'testing.scaffold.@types'

-- #####################################################################
-- scaffold/init.lua

---@class Testing.Scaffold.Opts
---@field force? boolean Replace files that exist (default false: they are reported in `skipped`).
---@field plugin? string Module name of the plugin (default: detected, see `testing.scaffold`).
---@field deps? string[] Dependencies of the project besides testing.nvim (default `{ "lib.nvim" }`).
---@field hooks? boolean Write the hook recipes (`scripts/hooks/*`) instead of the setup; never replaces a file, `force` or not.
---@field owner? string GitHub owner the CI checks the dependencies out from (default `StefanBartl`).

---@class Testing.Scaffold.Result
---@field created string[] Paths relative to the root, forward slashes.
---@field replaced string[] Existing files that `force` overwrote (empty without force).
---@field skipped string[] Existing files that were left alone.
---@field errors string[] `"<path>: <reason>"`; empty on success.
---@field plugin? string The sanitized plugin name that was used.

return {}
