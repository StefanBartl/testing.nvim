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
---@field load_budget_ms number >= 0. Budget of the K10 load-time check (ms).
---@field gate boolean `true`: `testing conformance` exits 1 on a failed check (default: report only).
---@field skip string[] Check ids that do not run.
---@field waivers table[] Accepted findings, each `{ check, reason, rule?, file?, text? }` (a reason is mandatory).
---@field keymaps_off table What K3 passes to `setup()` on top of `setup`.
---@field timeout_ms integer 1000..600000. Timeout of one call into the conformance child editor.
---@field rules_bridge { rulesets?: string[], families: string[] } The soft bridge to rules.nvim.

---@class Testing.ProjectConfig.Surface
---@field track boolean `true`: the runner counts the handlers the specs exercise (`cases[].surface`).
---@field threshold number 0..1 gate threshold of the overall ratio, 0 = report only.
---@field kinds string[] Kinds counted in the ratio.
---@field ignore string[] Lua patterns of entry ids that are not counted.
---@field setup_chunk? string Lua code the surface is read after.

---@class Testing.ProjectConfig.Cache
---@field enabled boolean `true`: reuse results of unchanged spec files without `--cached` (ignored in CI).

---@class Testing.ProjectConfig.Coverage
---@field bindings number 0..1 gate threshold, 0 = report only.
---@field commands number 0..1 gate threshold, 0 = report only.
---@field autocmds number 0..1 gate threshold, 0 = report only.

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

---@class Testing.ProjectConfig.Shard
---@field balance "size"|"count"|"hash"|"history" How `--shard` weighs the files.
---@field durations? string Relative path of a JSON file `{ "<spec path>": <ms> }` (opt-in: used by `history`).

---@class Testing.ProjectConfig.Watch
---@field debounce_ms integer > 0. Quiet time after the last change before `--watch` re-runs.
---@field poll_ms integer > 0. Interval of the polling fallback.

---@class Testing.ProjectConfig.Budget
---@field factor number 1..1000. A measurement may be this many times its baseline.
---@field baseline string Relative path of the baseline JSON.

---@alias Testing.GuardMode "off"|"warn"|"error"

---@class Testing.ProjectConfig.Guards
---@field fs Testing.GuardMode Writes outside the run directory and the repo temp.
---@field state Testing.GuardMode State a case/file leaves behind (autocmds, keymaps, buffers, globals).
---@field scheduled_error Testing.GuardMode Errors in `vim.schedule` callbacks, timers and jobs.
---@field prompt Testing.GuardMode Blocking prompts (`input`, `confirm`, `getchar`, `vim.ui.*`).
---@field deprecation Testing.GuardMode `vim.deprecate` messages (warn; `--strict` makes them fail).
---@field process_net Testing.GuardMode Spawned processes and network connections (the ledger is collected whatever this says).
---@field clock boolean Virtual clock and fixed random seed (opt-in).

---@class Testing.ProjectConfig.GuardAllow
---@field fs string[] Paths a spec may write to besides the run directory.
---@field spawn string[] Executables a spec may start.
---@field network string[] Hosts a spec may connect to.

---@class Testing.ProjectConfig.Pool
---@field size integer 0..256. Children the warm pool keeps (0 = `jobs`). Consumed by the warm pool.
---@field reuse boolean Reset and reuse a child between files instead of respawning it.

---@class Testing.ProjectConfig
--- The effective content of `.testing.lua`: `DEFAULTS.project` with the valid keys of the file on top.
--- Paths are relative to the project root, never absolute, never containing `..`.
---@field plugin string Lua module root; "" is replaced by the directory name of the root (without `.nvim`) after loading.
---@field roots string[] Spec roots, non-empty.
---@field spec_pattern string[] Lua patterns (against the relative path) that make a file a spec; default `{ "_spec%.lua$" }`.
---@field dialect Testing.DialectSetting
---@field assertions "error"|"warn" A case without assertions: failure (`error`, default) or pass with a warning (`warn`).
---@field isolated "auto"|"none"|"file"|"case"|"soft" Isolation: `auto` = `file` for busted, `none` otherwise; `case` = a child per case (busted; others `file`); `soft` = this process with restore between files; resolve with `config.project.isolated_for`.
---@field soft_keep string[] Modules the soft isolation never unloads (exact name or `prefix*`).
---@field guards Testing.ProjectConfig.Guards
---@field guard_allow Testing.ProjectConfig.GuardAllow
---@field pool Testing.ProjectConfig.Pool
---@field determinism boolean Children get a fixed `LANG`/`LC_ALL` and `TZ`.
---@field trace boolean A child that times out or crashes leaves a trace artifact.
---@field jobs integer|"auto" >= 1, or "auto" (cores minus one; `testing.cli` resolves it to an integer). Parallel child processes of an isolated run.
---@field host "c"|"l" Child host: `c` = started like plenary's (`--cmd`/`-c`), `l` = `nvim -l`.
---@field filetype boolean The host runs `filetype plugin indent on`.
---@field disable_first_run boolean Set lib.nvim's first-run opt-out in every editor the runner starts, before `minit`.
---@field env_allow string[] Extra environment names (or `PREFIX*`) a child editor may inherit.
---@field minit string|false
---@field deps string[] Directory names, resolved by `testing.deps`.
---@field setup table<string, any> Options for the plugin's `setup()`.
---@field conformance Testing.ProjectConfig.Conformance
---@field surface Testing.ProjectConfig.Surface
---@field cache Testing.ProjectConfig.Cache
---@field coverage Testing.ProjectConfig.Coverage
---@field timeouts Testing.ProjectConfig.Timeouts
---@field snapshots Testing.ProjectConfig.Snapshots
---@field shard Testing.ProjectConfig.Shard
---@field watch Testing.ProjectConfig.Watch
---@field budget Testing.ProjectConfig.Budget
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
