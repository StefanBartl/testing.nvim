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
---@field project Testing.ProjectConfig Defaults of a project's `.testing.lua`; not settable through `setup()`.

-- #####################################################################
-- config/project.lua (the per-project file `.testing.lua`)

---@alias Testing.Dialect "auto"|"testing"|"a"|"b"|"c"|"d"|"h"|"busted"|"script"

---@alias Testing.DialectSetting Testing.Dialect|table<string, Testing.Dialect> One dialect, or { [relative path or glob] = dialect, ["*"] = dialect }.

---@class Testing.ProjectConfig.Conformance
---@field load_budget_ms number >= 0. Budget of the load-time check. Reserved (M3).

---@class Testing.ProjectConfig.Coverage
---@field bindings number 0..1 gate threshold, 0 = report only. Reserved.
---@field commands number 0..1 gate threshold, 0 = report only. Reserved.

---@class Testing.ProjectConfig.Timeouts
---@field case_ms integer > 0. Hard timeout of one case.
---@field file_ms integer > 0. Hard timeout of one spec file.

---@class Testing.ProjectConfig.Snapshots
---@field dir string Relative path inside the project. Reserved.

---@class Testing.ProjectConfig.Backends
---@field luals boolean Reserved.
---@field pty boolean Reserved.
---@field playwright boolean Reserved.
---@field webdriver boolean Reserved.

---@class Testing.ProjectConfig
--- The effective content of `.testing.lua`: `DEFAULTS.project` with the valid keys of the file on top.
--- Paths are relative to the project root, never absolute, never containing `..`.
---@field plugin string Lua module root; "" is replaced by the directory name of the root (without `.nvim`) after loading.
---@field roots string[] Spec roots, non-empty.
---@field spec_pattern string[] Lua patterns (against the relative path) that make a file a spec; default `{ "_spec%.lua$" }`.
---@field dialect Testing.DialectSetting
---@field assertions "error"|"warn" A case without assertions: failure (`error`, default) or pass with a warning (`warn`).
---@field isolated "auto"|"none"|"file" Process isolation: `auto` = `file` for busted, `none` otherwise; resolve with `config.project.isolated_for`.
---@field jobs integer >= 1. Parallel child processes of an isolated run.
---@field host "c"|"l" Child host: `c` = started like plenary's (`--cmd`/`-c`), `l` = `nvim -l`.
---@field filetype boolean The host runs `filetype plugin indent on`.
---@field env_allow string[] Extra environment names (or `PREFIX*`) a child editor may inherit.
---@field minit string|false
---@field deps string[] Directory names, resolved by `testing.deps`.
---@field setup table<string, any> Options for the plugin's `setup()`.
---@field conformance Testing.ProjectConfig.Conformance
---@field coverage Testing.ProjectConfig.Coverage
---@field timeouts Testing.ProjectConfig.Timeouts
---@field snapshots Testing.ProjectConfig.Snapshots
---@field backends Testing.ProjectConfig.Backends

---@class Testing.ProjectConfig.Loaded
--- Result of `testing.config.project.load`.
---@field config Testing.ProjectConfig Always usable: defaults plus the valid keys.
---@field problems string[] One warning per invalid or unknown key, each naming the key.
---@field path? string File that was executed; nil when the project has none.
---@field error? string Set when the file exists but cannot be used (syntax error, raise, not a table, outside the root): the caller exits 2.

---@class Testing.ConfigOptions
--- What the user passes to `setup()`: every key of `Testing.Config`, each optional.
---@field notify_prefix? string
---@field keymaps? Testing.KeymapsConfig

return {}
