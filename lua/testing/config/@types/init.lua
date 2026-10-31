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

---@class Testing.HoverConfig
---@field max_width integer Longest line of the hover, in display columns.
---@field max_height integer Most lines of the hover.
---@field max_diff_lines integer Lines of a failure diff in the hover.

---@class Testing.HoverConfigOptions
---@field max_width? integer
---@field max_height? integer
---@field max_diff_lines? integer

---@class Testing.SurfaceViewKeys
---@field jump string|false `<CR>`: a row to the `src` of its entry, a spec file column to that file.
---@field status string|false `s`: the status filter, round (all, hit, missing, untracked, ignored).
---@field kind string|false `t`: the kind filter, round (all, binding, command, autocmd).
---@field export string|false `e`: write the filtered table as a tab separated file.

---@class Testing.SurfaceViewConfig
---@field keys Testing.SurfaceViewKeys

---@class Testing.SurfaceViewConfigOptions
---@field keys? { jump?: string|false, status?: string|false, kind?: string|false, export?: string|false }

---@class Testing.CiRepos
---@field roots string[] Directories whose sub-directories with a `ci` section are run by `:Testing ci repos` (env variables are expanded).
---@field include string[] Of the found ones only these directory names (empty: all).
---@field exclude string[] Leave these directory names out.

---@class Testing.CiConfig
---@field repos Testing.CiRepos

---@class Testing.CiConfigOptions
---@field repos? { roots?: string[], include?: string[], exclude?: string[] }

---@class Testing.LintConfig
---@field on_save boolean Lint a written file in the background (the checks that may run on save) and update its diagnostics.

---@class Testing.LintConfigOptions
---@field on_save? boolean

---@class Testing.Config
--- The effective configuration: `DEFAULTS` with the user's valid options merged on top.
---@field notify_prefix string Prefix of every message shown through lib.nvim.notify. Non-empty.
---@field keymaps Testing.KeymapsConfig Named keymap actions to rebind or drop; empty by default.
---@field hover Testing.HoverConfig The hover over a test (`testing.hover`).
---@field ci Testing.CiConfig `:Testing ci` from the editor.
---@field lint Testing.LintConfig `:Testing lint` and the check on save.
---@field surface_view Testing.SurfaceViewConfig The keys of the matrix view of `:Testing surface --matrix`.
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
---@field tags boolean `true`: `binding:`/`command:` tags and `-- @covers` headers of passing cases count as exercised.
---@field setup_chunk? string Lua code the surface is read after.

---@class Testing.ProjectConfig.Cache
---@field enabled boolean `true`: reuse results of unchanged spec files without `--cached` (ignored in CI).
---@field project_key? string Name of the cache folder instead of one derived from the checkout path (a cache restored on a runner with another path is found).

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

---@class Testing.ProjectConfig.Affected
---@field consumers? string Directory with the checkouts of the projects that use this one (absolute, or relative to the root): `--consumers`.

---@class Testing.ProjectConfig.Watch
---@field debounce_ms integer > 0. Quiet time after the last change before `--watch` re-runs.
---@field poll_ms integer > 0. Interval of the polling fallback.
---@field max_wait_ms integer 0 = off. A pending change starts a re-run after at most this long, however often files keep changing (the debounce alone never fires while someone keeps saving).

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
---@field isolate_home boolean Children get a home directory in their sandbox (`HOME`, `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`).
---@field trace boolean A child that times out or crashes leaves a trace artifact.
---@field jobs integer|"auto" >= 1, or "auto" (cores minus one; `testing.cli` resolves it to an integer). Parallel child processes of an isolated run.
---@field host "c"|"l" Child host: `c` = started like plenary's (`--cmd`/`-c`), `l` = `nvim -l`.
---@field filetype boolean The host runs `filetype plugin indent on`.
---@field disable_first_run boolean Set lib.nvim's first-run opt-out in every editor the runner starts, before `minit`.
---@field env_allow string[] Extra environment names (or `PREFIX*`) a child editor may inherit.
---@field minit string|false
---@field deps string[] Directory names, resolved by `testing.deps`.
---@field setup table<string, any> Options for the plugin's `setup()`.
---@field ci_remote Testing.ProjectConfig.CiRemote `testing ci remote`.
---@field ci_overview Testing.ProjectConfig.CiOverview `testing ci overview`.
---@field conformance Testing.ProjectConfig.Conformance
---@field surface Testing.ProjectConfig.Surface
---@field cache Testing.ProjectConfig.Cache
---@field coverage Testing.ProjectConfig.Coverage
---@field timeouts Testing.ProjectConfig.Timeouts
---@field snapshots Testing.ProjectConfig.Snapshots
---@field shard Testing.ProjectConfig.Shard
---@field affected Testing.ProjectConfig.Affected
---@field watch Testing.ProjectConfig.Watch
---@field budget Testing.ProjectConfig.Budget
---@field backends Testing.ProjectConfig.Backends
---@field ci? table The pipeline of `testing ci` (validated there: `testing.ci.schema`, docs/CI.md); nil: derived.

---@class Testing.ProjectConfig.CiRemote
---@field workflow string The GitHub Actions workflow whose latest run is reported (default "CI").
---@field branch string The branch whose fetched head (`origin/<branch>`) is asked about (default "main").
---@field non_gating string[] Job names containing one of these (case-insensitive) are listed but never decide.

---@class Testing.ProjectConfig.CiOverview
---@field include string[] Directory names taken in although the detection misses them (default { "lib.nvim" }).
---@field exclude string[] Directory names left out.

---@class Testing.ProjectConfig.Loaded
--- Result of `testing.config.project.load`.
---@field config Testing.ProjectConfig Always usable: defaults plus the valid keys.
---@field problems string[] One warning per invalid or unknown key, each naming the key.
---@field path? string File that was executed; nil when the project has none.
---@field error? string Set when the file exists but cannot be used (syntax error, raise, not a table, outside the root), or the root is not trusted: the caller exits 2.
---@field untrusted? boolean The workspace trust gate refused the root (`testing.trust`); nothing of it was executed.

---@class Testing.ConfigOptions
--- What the user passes to `setup()`: every key of `Testing.Config`, each optional.
---@field notify_prefix? string
---@field keymaps? Testing.KeymapsConfig
---@field hover? Testing.HoverConfigOptions
---@field ci? Testing.CiConfigOptions
---@field lint? Testing.LintConfigOptions
---@field surface_view? Testing.SurfaceViewConfigOptions

return {}
