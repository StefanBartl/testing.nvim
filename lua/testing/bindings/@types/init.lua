---@meta
---@module 'testing.bindings.@types'

-- #####################################################################
-- bindings/keymaps.lua

---@alias Testing.KeymapActions
--- The named keymap actions the plugin declares, keyed by action name. Each value is a
--- `Lib.Keymap.Action` from lib.nvim (default lhs, mode, rhs, desc); the user can move or drop every
--- one of them through `setup({ keymaps = { <action> = "<lhs>" | false } })`.
---| table<string, Lib.Keymap.Action>

-- #####################################################################
-- bindings/child.lua, bindings/usrcmds.lua

---@class Testing.Child.Flags
---@field file? string[] `--file=<text>`: substring of the spec file name
---@field filter? string[] `--filter=<text>`: substring of the case name
---@field reporter? string `--reporter=<name>`
---@field rtp? string[] `--rtp=<dir>`
---@field config? string `--config=<file>`
---@field cached? boolean `--cached`: reuse the results of unchanged spec files
---@field no_cache? boolean `--no-cache`
---@field changed? boolean `--changed`: only the specs the working tree can reach
---@field since? string `--since=<rev>`
---@field shard? string `--shard=<i>/<n>`
---@field raw? string[] Arguments passed verbatim (`conformance`, `surface`, `budget` have their own grammar).

---@class Testing.Child.Opts
---@field root string Project root (absolute); also the working directory of the child.
---@field flags? Testing.Child.Flags
---@field json? string Where the IR is written (`run` only); default: a temp file that is removed afterwards.
---@field system? fun(argv: string[], opts: table, on_exit: fun(res: vim.SystemCompleted)): any Seam for specs (default `vim.system`).

---@class Testing.Child.Verdict
---@field level "info"|"warn"|"error"
---@field message string One notification text (may span lines).
---@field items table[] Quickfix items of the failures (empty when none).
---@field lines? string[] Output to show in a viewer (`list`, `doctor`).

---@class Testing.Usrcmds.MigrateCtx
---@field args { mode?: string, root?: string } `mode` is `dry-run` or `apply`; any other first word is the root.
---@field flags { ["fleet-root"]?: string }

---@class Testing.Module
--- Facade functions added by the editor-side commands (merged with the class of `testing.@types`).
---@field scaffold fun(root: string, opts?: Testing.Scaffold.Opts): Testing.Scaffold.Result Generate the test setup of a plugin repo; never overwrites unless `opts.force`.
---@field run fun(opts?: { root?: string, flags?: Testing.Child.Flags }, on_done?: fun(verdict: Testing.Child.Verdict)): boolean, string|nil Run the specs in a headless child nvim and show the result.

return {}
