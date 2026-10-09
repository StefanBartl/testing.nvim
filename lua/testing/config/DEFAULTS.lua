---@module 'testing.config.DEFAULTS'
---@brief Plugin-side defaults of testing.nvim: pure data, no side effects at require time.
---@description
--- Every key of `Testing.Config` appears here with its default. The file only names values: no
--- environment lookup, no filesystem access (LUA-06), so `require("testing.config.DEFAULTS")` is
--- safe from docs generators and specs.
---
--- `project` holds the defaults of the per-project file `.testing.lua` (see `testing.config.project`,
--- which validates what a project writes there against exactly these keys).

---@type Testing.Config
local DEFAULTS = {
  -- Prefix of every message the plugin shows through lib.nvim.notify.
  notify_prefix = "[testing]",
  -- Named keymap actions (action name -> lhs | list of lhs | false). The plugin has no action
  -- yet, so nothing is bound by default; the table is where a user spec rebinds or drops them.
  keymaps = {},
  -- Defaults of `.testing.lua` in a project root.
  project = {
    -- Lua module root of the project (conformance and coverage need it); "" = the directory name
    -- of the root without a trailing ".nvim".
    plugin = "",
    -- Spec roots relative to the project root. Legacy locations are discovered on top and reported.
    roots = { "TESTS" },
    -- Lua patterns (against the project-relative path) that make a file a spec.
    spec_pattern = { "_spec%.lua$" },
    -- "auto" = sniff the dialect per file; or "testing", "a", "b", "c", "d", "h" (the project's own
    -- harness), "busted", "script" (a self-running script); or a table { [path or glob] = name, ["*"] = name }.
    dialect = "auto",
    -- A case without assertions: "error" = failure, "warn" = pass with a warning.
    assertions = "error",
    -- "auto" = one child process per file for busted specs, one shared process otherwise;
    -- "none" = everything in this process; "file" = one child per spec file; "case" = one child per
    -- CASE (busted files; every other dialect degrades to "file" with a note); "soft" = everything in
    -- this process, with what a file changed restored between the files (resolve with
    -- config.project.isolated_for).
    isolated = "auto",
    -- Modules the soft isolation never unloads (exact names or `prefix*`), on top of `testing*`,
    -- `lib.nvim*` and everything that was loaded before the run started.
    soft_keep = {},
    -- Parallel child processes of an isolated run: an integer, or "auto" (cores minus one).
    jobs = 1,
    -- Guards (safety nets, NOT a sandbox: Lua code can bypass every monkeypatch). Per guard "off",
    -- "warn" (a finding in the report) or "error" (a finding fails the case). `clock` is opt-in.
    -- `process_net` is off by default for now; its LEDGER (`effects`) is always collected.
    guards = {
      fs = "warn",
      state = "warn",
      scheduled_error = "error",
      prompt = "error",
      deprecation = "warn",
      process_net = "off",
      clock = false,
    },
    -- What the guards let through, each a list: writes below these paths (fs), these executables
    -- (spawn), these hosts (network). Shown in the report, never silent.
    guard_allow = { fs = {}, spawn = {}, network = {} },
    -- Warm child pool (round 2): `size` children kept alive (0 = `jobs`), `reuse` = reset and reuse
    -- a child between files instead of respawning it.
    pool = { size = 0, reuse = false },
    -- Child editors start with a fixed `LANG`/`LC_ALL` and `TZ` (the same output on every machine).
    determinism = true,
    -- A child that times out or crashes leaves a trace of what it did (artifact of the case).
    trace = true,
    -- Host of a child process: "c" = started like plenary (--cmd/-c, vim_did_enter == 0), "l" = nvim -l.
    host = "c",
    -- The host runs `filetype plugin indent on` (plenary's minimal init does).
    filetype = true,
    -- Test-environment default: set `vim.g.lib_nvim_deps_disable_first_run = true` in every editor the
    -- runner starts (child and in-process) before the project's `minit`, so lib.nvim's one-time
    -- "missing tools" float (empty stdpath('cache')) cannot open windows/buffers inside a spec.
    -- false = leave the variable alone.
    disable_first_run = true,
    -- Environment names (or `PREFIX*`) a child may inherit on top of the built-in allowlist
    -- (`testing.child.env`): REPOS_DIR, MAGICK_*, ... A name starting with NVIM is never passed on.
    env_allow = {},
    -- Minimal init of the project (used by isolated child runs); false = none.
    minit = "TESTS/minimal_init.lua",
    -- Dependencies (directory names) resolved by testing.deps: $<NAME>_DIR, .deps/, ../, stdpath('data')/lazy/.
    deps = {},
    -- Options the conformance suite calls the plugin's setup() with.
    setup = {},
    -- `testing conformance`: gate = true makes a failed check exit 1 (report-only until the findings of
    -- the repository are triaged); skip = check ids that do not run; waivers = accepted findings, each with
    -- a reason; keymaps_off = what K3 passes to setup() on top of `setup`; timeout_ms of one child call.
    conformance = {
      load_budget_ms = 40,
      gate = false,
      skip = {},
      waivers = {},
      keymaps_off = { keymaps = false },
      timeout_ms = 20000,
      rules_bridge = { families = { "NEW", "REL" } },
    },
    -- `testing surface`: track = true makes the runner count which handlers the specs exercised;
    -- threshold 0 = only report (see docs/SURFACE.md).
    surface = {
      track = false,
      threshold = 0,
      kinds = { "binding", "command", "autocmd" },
      ignore = {},
    },
    -- The result cache (docs/CACHE.md): `enabled = true` reuses results without `--cached` (never in CI).
    cache = { enabled = false },
    -- Gate thresholds 0..1; 0 = report only.
    coverage = { bindings = 0, commands = 0, autocmds = 0 },
    timeouts = { case_ms = 10000, file_ms = 60000 },
    snapshots = { dir = "TESTS/__snapshots__" },
    -- `--shard i/n`: how the spec files are distributed. "size" (file bytes: the same on every job of a
    -- matrix), "count", "hash" (stable under added files) or "history" (measured durations: every job must
    -- see the same ones, see `shard.durations`, which has no default: it is opt-in).
    shard = { balance = "size" },
    -- `--consumers`: the directory with the checkouts of the projects that use this one (no default: opt-in).
    affected = {},
    -- `--watch`: quiet time after the last change before a re-run (a editor save fires several events), and
    -- the polling interval of the fallback when the file system cannot deliver events.
    watch = { debounce_ms = 150, poll_ms = 1000, max_wait_ms = 0 },
    -- `testing budget`: a measurement may be `factor` times its baseline before the check fails; the
    -- baseline file (JSON written by `testing budget --update`) lives in the project.
    budget = { factor = 2.0, baseline = "TESTS/bench/baseline.json" },
    backends = { luals = false, pty = false, playwright = false, webdriver = false },
  },
}

return DEFAULTS
