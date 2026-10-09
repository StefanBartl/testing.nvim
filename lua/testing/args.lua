---@module 'testing.args'
---@brief Argument parser of the command line: `testing [run|init|list|doctor] [<root>] [options]`.
---@description
--- Pure: reads only the list it is given (the caller passes `_G.arg`, which `nvim -l` fills with
--- everything after the script), never executes or `eval`s any of it, never touches the editor or
--- the filesystem (SEC-34/35: no `-c` strings with user text, nothing is interpreted as code).
---
--- Grammar (GNU style):
---   * subcommand: the FIRST argument, when it is exactly `run`, `init`, `list` or `doctor`
---     (default `run`). Any other first argument is the project root as before; a directory that is
---     called `list` is spelled `./list` or `--root list`.
---   * long options take their value as `--name value` or `--name=value`; the value of the
---     space form is the next argument verbatim, except that it must not start with `--`
---     (spell `--name=--x` for that). An empty value is an error.
---   * `--` ends the options; the rest are positionals.
---   * short options: `-h`, `-x` (no clustering).
---   * repeatable options accumulate (`--rtp a --rtp b`); a repeated scalar option is last-wins.
---   * positionals: the first is the project root (unless `--root` is given), the rest are `paths`.
---   * everything unknown is a usage error (the caller maps it to exit code 2 and prints `USAGE`).
---
--- The parser only parses and validates; what a flag does is wired by the caller (`testing.cli`).
--- `Args.given` records which options the user passed (canonical names), so the caller can refuse
--- an option it does not implement yet instead of silently ignoring it.

local M = {}

---@type string[]
M.SUBCOMMANDS =
  { "run", "init", "list", "doctor", "budget", "conformance", "surface", "explain", "verify" }

---Subcommand names that are parsed but not dispatched yet. Empty since the integration step wired
---`conformance` and `surface` (`testing.cli` hands them to their own modules, with their own arguments,
---before the run options are parsed).
---@type string[]
M.RESERVED_COMMANDS = {}

---Largest `<n>` of `--shard i/n` (a CI matrix is never wider).
M.MAX_SHARDS = 1000

---Reporter names `--reporter` accepts; the reporter implementation extends this list.
---@type string[]
M.REPORTERS = { "term", "github", "junit", "json", "agent" }

---Smallest `--agent-budget` (characters): below it not even a verdict line and one failure would fit.
M.AGENT_BUDGET_MIN = 200

---@class Testing.Args
---@field command "run"|"init"|"list"|"doctor"|"budget"|"conformance"|"surface"
---@field help boolean `-h`/`--help`
---@field root? string Project root (`--root` or the first positional).
---@field paths string[] Positionals after the root.
---@field config? string `--config <file>`
---@field json? string `--json <file>`
---@field junit? string `--junit <file>`
---@field events? string `--events <file>`
---@field github boolean `--github`
---@field reporter? string `--reporter <name>` (one of `REPORTERS`)
---@field agent_budget? integer `--agent-budget <n>`: character budget of the `agent` reporter
---@field format? "text"|"jsonl" `--format text|jsonl`: shape of the `agent` reporter (default text)
---@field order? "priority"|"slowest-first" `--order priority`: what failed last and what the changes reach runs first; `--order slowest-first`: the longest files start first (never a filter)
---@field filter string[] `--filter <text>`: literal substring of the case name (SEC-30), repeatable
---@field file string[] `--file <text>`/`--only <text>`: substring of the spec FILE NAME, repeatable
---@field tags string[] `--tags a,b`
---@field exclude_tags string[] `--exclude-tags a,b`
---@field lf boolean `--lf`: last failed
---@field ff boolean `--ff`: failed first
---@field maxfail? integer `-x` (1) or `--maxfail N`
---@field shuffle boolean `--shuffle`
---@field seed? integer `--seed N` (needs `--shuffle`)
---@field durations? integer `--durations N`
---@field list boolean `--list`/`--dry-run` (and the `list` subcommand)
---@field strict boolean `--strict`
---@field rtp string[] `--rtp <dir>`, repeatable
---@field case_timeout_ms? integer `--case-timeout <ms>`
---@field file_timeout_ms? integer `--file-timeout <ms>`
---@field sentinel? string `--sentinel <name>` (transitional: last line of a green run)
---@field isolated? "none"|"file"|"case"|"soft" `--isolated none|file|case|soft`: a child editor per spec file / per case, or this editor with a restore between files
---@field guard string[] `--guard <name>=<mode>`, repeatable (validated by `check_guard`)
---@field allow_fs string[] `--allow-fs <path>`, repeatable
---@field allow_spawn string[] `--allow-spawn <exe>`, repeatable
---@field allow_network string[] `--allow-network <host>`, repeatable
---@field pool_size? integer `--pool-size <n>`
---@field pool_reuse? boolean `--pool-reuse` (true) / `--no-pool-reuse` (false); nil = the config decides
---@field determinism? boolean `--no-determinism` (false); nil = the config decides
---@field trace? boolean `--no-trace` (false); nil = the config decides
---@field jobs? integer `--jobs <n>`: children running at once (isolated runs)
---@field jobs_auto? boolean `--jobs auto`: cores minus one (the caller resolves it into `jobs`)
---@field shard_text? string `--shard i/n` as typed
---@field shard? { index: integer, count: integer } `--shard i/n`, validated (1 <= i <= n)
---@field watch boolean `--watch`: re-run the affected spec files when something changes
---@field watch_debounce_ms? integer `--watch-debounce <ms>`
---@field watch_max_wait_ms? integer `--watch-max-wait <ms>`
---@field watch_poll boolean `--watch-poll`: poll the file system instead of using fs events
---@field profile boolean `--profile`: per-phase timing, slowest files and cases, histogram (`run.profile` in the IR)
---@field baseline? string `--baseline <file>` (`budget`)
---@field factor_text? string `--factor <x>` as typed (`budget`)
---@field factor? number `--factor <x>`: a measurement may be this many times the baseline (`budget`)
---@field budget_update boolean `--update` (`budget`): write the measured values as the new baseline
---@field budget_allow_new boolean `--allow-new` (`budget`): a measured case without a baseline entry is not an error
---@field budget_runs? integer `--runs <n>` (`budget`): measured runs per case
---@field cache? boolean `--cached`: reuse the results of unchanged spec files, store new green ones
---@field no_cache boolean `--no-cache`: never read or write the cache (wins over `--cached`, `--cache-refresh` and the config)
---@field cache_refresh boolean `--cache-refresh`: run everything and store the results, never read
---@field cache_audit_text? string `--cache-audit <0..1|all>` as typed
---@field cache_audit? number `--cache-audit`: the share of the cache hits (0..1; `all` = 1) that run anyway and are compared with the stored result
---@field cache_dir? string `--cache-dir <dir>`: replaces `stdpath('cache')` as the base of the result cache
---@field cache_clear boolean `--cache-clear`: delete the cache of this project and exit
---@field affected? boolean|string `--affected` / `--affected=<rev>`: the specs the changes since `<rev>` (default `HEAD~1`) can reach
---@field changed boolean `--changed`: the specs the working tree against `HEAD` can reach
---@field since? string `--since <rev>`: the specs the working tree against `<rev>` can reach
---@field consumers? string `--consumers <dir>`: also ask documentation.nvim which specs of the checkouts below `<dir>` the changes reach (a hint, never a narrowing)
---@field retry_failed? integer `--retry-failed <n>` (1..10): a red case runs again up to `n` times; one that passes is `flaky` and the run stays red
---@field allow_flaky boolean `--allow-flaky`: a case that failed and then passed on a retry counts as green (it is still listed as flaky and never cached)
---@field host? "c"|"l" `--host c|l`: how a child starts (`c` = plenary-like `-c`, `l` = `nvim -l`)
---@field env_allow string[] `--env-allow <name>`, repeatable: environment names a child may inherit
---@field first_run boolean `--first-run`: do not disable lib.nvim's first-run float (default false)
---@field timings boolean false after `--no-timings`
---@field given table<string, boolean> Canonical names (`json`, `maxfail`, ...) of the options the user passed.

---@class Testing.Args.Option
---@field name string Canonical name (no dashes, underscores): the key in `Args.given`.
---@field long? string Long spelling without the dashes.
---@field short? string Short spelling without the dash.
---@field kind "flag"|"value"|"list"|"csv"|"int"|"optvalue" `optvalue`: `--name` alone stores true, `--name=<v>` stores `<v>` (never consumes the next argument).
---@field field string Field of `Testing.Args` that receives the value.
---@field word? string An `int` that also accepts this word (`--jobs auto`); the word sets `word_field`.
---@field word_field? string
---@field const? any Value a `flag` stores (default true).
---@field arg? string Placeholder for the usage text.
---@field min? integer Lower bound of an `int`.
---@field check? fun(v: string): string|nil Returns a problem text for an invalid value.
---@field help string

---The option table drives both the parser and the usage text.
---@type Testing.Args.Option[]
local OPTIONS = {
  { name = "help", long = "help", short = "h", kind = "flag", field = "help", help = "this text" },
  {
    name = "root",
    long = "root",
    kind = "value",
    field = "root",
    arg = "<dir>",
    help = "project root (default: the first positional)",
  },
  {
    name = "config",
    long = "config",
    kind = "value",
    field = "config",
    arg = "<file>",
    help = "configuration file inside the root (default: <root>/.testing.lua)",
  },
  {
    name = "cache_dir",
    long = "cache-dir",
    kind = "value",
    field = "cache_dir",
    arg = "<dir>",
    help = "base directory of the result cache (default: stdpath('cache'); env TESTING_CACHE_HOME); the project folder is below it",
  },
  {
    name = "json",
    long = "json",
    kind = "value",
    field = "json",
    arg = "<file>",
    help = "write the Result-IR (schema_version 1) to <file>",
  },
  {
    name = "events",
    long = "events",
    kind = "value",
    field = "events",
    arg = "<file>",
    help = "write the events of the run (NDJSON: run_start, case, run_done; with --watch also watch_change) to <file> while it goes; - is stdout (the reporter then prints to stderr)",
  },
  {
    name = "junit",
    long = "junit",
    kind = "value",
    field = "junit",
    arg = "<file>",
    help = "write a JUnit XML report to <file>",
  },
  {
    name = "github",
    long = "github",
    kind = "flag",
    field = "github",
    help = "emit GitHub Actions annotations and the step summary",
  },
  {
    name = "reporter",
    long = "reporter",
    kind = "value",
    field = "reporter",
    arg = "<name>",
    help = "terminal reporter",
    check = function(v)
      for _, r in ipairs(M.REPORTERS) do
        if r == v then
          return nil
        end
      end
      return ("unknown reporter '%s' (one of: %s)"):format(v, table.concat(M.REPORTERS, ", "))
    end,
  },
  {
    name = "agent_budget",
    long = "agent-budget",
    kind = "int",
    field = "agent_budget",
    arg = "<n>",
    min = M.AGENT_BUDGET_MIN,
    help = "character budget of --reporter agent (what does not fit is counted, never dropped silently)",
  },
  {
    name = "format",
    long = "format",
    kind = "value",
    field = "format",
    arg = "<text|jsonl>",
    help = "shape of --reporter agent: text (default) or jsonl (one line per failure group)",
    check = function(v)
      if v == "text" or v == "jsonl" then
        return nil
      end
      return ("--format must be 'text' or 'jsonl', got '%s'"):format(v)
    end,
  },
  {
    name = "order",
    long = "order",
    kind = "value",
    field = "order",
    arg = "<priority|slowest-first>",
    help = "priority: what failed last, what changed and what the changes reach run first; slowest-first: with --jobs the longest files (by their remembered duration) start first. Orders, never filters",
    check = function(v)
      if v == "priority" or v == "slowest-first" then
        return nil
      end
      return ("--order must be 'priority' or 'slowest-first', got '%s'"):format(v)
    end,
  },
  {
    name = "filter",
    long = "filter",
    kind = "list",
    field = "filter",
    arg = "<text>",
    help = "only cases whose name contains <text> (literal, not a pattern); repeatable",
  },
  {
    name = "file",
    long = "file",
    kind = "list",
    field = "file",
    arg = "<text>",
    help = "only spec files whose FILE NAME contains <text>; repeatable",
  },
  {
    name = "file",
    long = "only",
    kind = "list",
    field = "file",
    arg = "<text>",
    help = "alias of --file",
  },
  {
    name = "tags",
    long = "tags",
    kind = "csv",
    field = "tags",
    arg = "<a,b>",
    help = "only cases with one of these tags; repeatable",
  },
  {
    name = "exclude_tags",
    long = "exclude-tags",
    kind = "csv",
    field = "exclude_tags",
    arg = "<a,b>",
    help = "skip cases with one of these tags; repeatable",
  },
  { name = "lf", long = "lf", kind = "flag", field = "lf", help = "only what failed last time" },
  { name = "ff", long = "ff", kind = "flag", field = "ff", help = "what failed last time first" },
  {
    name = "maxfail",
    short = "x",
    kind = "flag",
    field = "maxfail",
    const = 1,
    help = "stop after the first failure (= --maxfail 1)",
  },
  {
    name = "maxfail",
    long = "maxfail",
    kind = "int",
    field = "maxfail",
    arg = "<n>",
    min = 1,
    help = "stop after <n> failures",
  },
  {
    name = "shuffle",
    long = "shuffle",
    kind = "flag",
    field = "shuffle",
    help = "run in random order (the seed is reported)",
  },
  {
    name = "seed",
    long = "seed",
    kind = "int",
    field = "seed",
    arg = "<n>",
    min = 0,
    help = "seed of --shuffle",
  },
  {
    name = "durations",
    long = "durations",
    kind = "int",
    field = "durations",
    arg = "<n>",
    min = 0,
    help = "name the <n> slowest cases (0 = all)",
  },
  {
    name = "list",
    long = "list",
    kind = "flag",
    field = "list",
    help = "list what would run, run nothing",
  },
  { name = "list", long = "dry-run", kind = "flag", field = "list", help = "alias of --list" },
  {
    name = "strict",
    long = "strict",
    kind = "flag",
    field = "strict",
    help = "warnings (deprecations, ...) fail the run",
  },
  {
    name = "rtp",
    long = "rtp",
    kind = "list",
    field = "rtp",
    arg = "<dir>",
    help = "add <dir> to the runtimepath; repeatable",
  },
  {
    name = "case_timeout",
    long = "case-timeout",
    kind = "int",
    field = "case_timeout_ms",
    arg = "<ms>",
    min = 1,
    help = "hard timeout of one case",
  },
  {
    name = "file_timeout",
    long = "file-timeout",
    kind = "int",
    field = "file_timeout_ms",
    arg = "<ms>",
    min = 1,
    help = "hard timeout of one spec file",
  },
  {
    name = "sentinel",
    long = "sentinel",
    kind = "value",
    field = "sentinel",
    arg = "<name>",
    help = "last line of a fully green run (default: taken from <root>/TESTS/run.lua)",
  },
  {
    name = "isolated",
    long = "isolated",
    kind = "value",
    field = "isolated",
    arg = "<none|file|case|soft>",
    help = "file: a child editor per spec file (default for busted files); case: a child per CASE (busted; slow, exact); soft: this editor, state restored between files",
    check = function(v)
      if v == "none" or v == "file" or v == "case" or v == "soft" then
        return nil
      end
      return ("--isolated must be 'none', 'file', 'case' or 'soft', got '%s'"):format(v)
    end,
  },
  {
    name = "guard",
    long = "guard",
    kind = "list",
    field = "guard",
    arg = "<name>=<mode>",
    help = "set a guard (fs, state, scheduled_error, prompt, deprecation, process_net: off|warn|error; clock: on|off); repeatable",
    check = function(v)
      return M.check_guard(v)
    end,
  },
  {
    name = "allow_fs",
    long = "allow-fs",
    kind = "list",
    field = "allow_fs",
    arg = "<path>",
    help = "the fs guard lets writes below <path> through; repeatable",
    check = function(v)
      return M.check_allow("--allow-fs", v)
    end,
  },
  {
    name = "allow_spawn",
    long = "allow-spawn",
    kind = "list",
    field = "allow_spawn",
    arg = "<exe>",
    help = "the process guard lets <exe> be started; repeatable",
    check = function(v)
      return M.check_allow("--allow-spawn", v)
    end,
  },
  {
    name = "allow_network",
    long = "allow-network",
    kind = "list",
    field = "allow_network",
    arg = "<host>",
    help = "the network guard lets connections to <host> through; repeatable",
    check = function(v)
      return M.check_allow("--allow-network", v)
    end,
  },
  {
    name = "pool_size",
    long = "pool-size",
    kind = "int",
    field = "pool_size",
    arg = "<n>",
    min = 0,
    help = "children the warm pool keeps (0 = --jobs)",
  },
  {
    name = "pool_reuse",
    long = "pool-reuse",
    kind = "flag",
    field = "pool_reuse",
    const = true,
    help = "reset and reuse a child between files instead of respawning it",
  },
  {
    name = "pool_reuse",
    long = "no-pool-reuse",
    kind = "flag",
    field = "pool_reuse",
    const = false,
    help = "respawn a child for every file (the default)",
  },
  {
    name = "determinism",
    long = "no-determinism",
    kind = "flag",
    field = "determinism",
    const = false,
    help = "children keep the parent's LANG/LC_ALL/TZ instead of fixed ones",
  },
  {
    name = "trace",
    long = "no-trace",
    kind = "flag",
    field = "trace",
    const = false,
    help = "no trace artifact for a child that times out or crashes",
  },
  {
    name = "jobs",
    long = "jobs",
    kind = "int",
    field = "jobs",
    arg = "<n|auto>",
    min = 1,
    word = "auto",
    word_field = "jobs_auto",
    help = "child editors running at once (isolated runs; default 1; auto = cores minus one)",
  },
  {
    name = "host",
    long = "host",
    kind = "value",
    field = "host",
    arg = "<c|l>",
    help = "how a child starts: c = like plenary's host (default), l = nvim -l",
    check = function(v)
      if v == "c" or v == "l" then
        return nil
      end
      return ("--host must be 'c' or 'l', got '%s'"):format(v)
    end,
  },
  {
    name = "env_allow",
    long = "env-allow",
    kind = "list",
    field = "env_allow",
    arg = "<name>",
    help = "environment variable (or PREFIX*) a child may inherit; repeatable",
    check = function(v)
      local ok, why = require("testing.child.env").check_entry(v)
      if ok then
        return nil
      end
      return ("--env-allow '%s': %s"):format(v, why)
    end,
  },
  {
    name = "first_run",
    long = "first-run",
    kind = "flag",
    field = "first_run",
    const = true,
    help = "keep lib.nvim's one-time first-run float enabled (a suite that tests it, such as lib.nvim's own)",
  },
  {
    name = "shard",
    long = "shard",
    kind = "value",
    field = "shard_text",
    arg = "<i/n>",
    help = "run only shard <i> of <n> (1-based; a deterministic partition of the spec files, for CI matrices; also with --list)",
    check = function(v)
      local _, why = M.parse_shard(v)
      return why
    end,
  },
  {
    name = "watch",
    long = "watch",
    kind = "flag",
    field = "watch",
    help = "run, then re-run the affected spec files whenever something changes (failed files first; Ctrl-C ends it)",
  },
  {
    name = "watch_debounce",
    long = "watch-debounce",
    kind = "int",
    field = "watch_debounce_ms",
    arg = "<ms>",
    min = 1,
    help = "quiet time after the last change before --watch re-runs (default from .testing.lua watch.debounce_ms)",
  },
  {
    name = "watch_max_wait",
    long = "watch-max-wait",
    kind = "int",
    field = "watch_max_wait_ms",
    arg = "<ms>",
    min = 1,
    help = "longest a change waits before --watch re-runs, however often files keep changing (default from .testing.lua watch.max_wait_ms; 0 = off there)",
  },
  {
    name = "watch_poll",
    long = "watch-poll",
    kind = "flag",
    field = "watch_poll",
    help = "--watch polls the file system instead of using fs events (network drives, exhausted watchers)",
  },
  {
    name = "profile",
    long = "profile",
    kind = "flag",
    field = "profile",
    help = "per-phase timing, slowest files and cases, histogram, pool use (text on stderr; run.profile in the IR)",
  },
  {
    name = "baseline",
    long = "baseline",
    kind = "value",
    field = "baseline",
    arg = "<file>",
    help = "budget: baseline file (default budget.baseline of .testing.lua)",
  },
  {
    name = "factor",
    long = "factor",
    kind = "value",
    field = "factor_text",
    arg = "<x>",
    help = "budget: a measurement may be <x> times its baseline (default budget.factor of .testing.lua)",
    check = function(v)
      local n = tonumber(v)
      if n == nil or n ~= n or n < 1 or n > 1000 then
        return ("--factor needs a number between 1 and 1000, got '%s'"):format(v)
      end
      return nil
    end,
  },
  {
    name = "budget_update",
    long = "update",
    kind = "flag",
    field = "budget_update",
    help = "budget: write the measured values as the new baseline",
  },
  {
    name = "budget_allow_new",
    long = "allow-new",
    kind = "flag",
    field = "budget_allow_new",
    help = "budget: a case that has no baseline entry yet is not an error (the gate compared nothing for it)",
  },
  {
    name = "budget_runs",
    long = "runs",
    kind = "int",
    field = "budget_runs",
    arg = "<n>",
    min = 1,
    help = "budget: measured runs per case (default 5; the median counts)",
  },
  {
    name = "cache",
    long = "cached",
    kind = "flag",
    field = "cache",
    const = true,
    help = "do not run spec files whose inputs are byte-identical to an earlier green run (their cases are reported as cached)",
  },
  {
    name = "no_cache",
    long = "no-cache",
    kind = "flag",
    field = "no_cache",
    help = "never read or write the result cache (wins over --cached, --cache-refresh and .testing.lua)",
  },
  {
    name = "cache_refresh",
    long = "cache-refresh",
    kind = "flag",
    field = "cache_refresh",
    help = "run everything and store the green results, never read the cache",
  },
  {
    name = "cache_audit",
    long = "cache-audit",
    kind = "value",
    field = "cache_audit_text",
    arg = "<0..1|all>",
    help = "run this share of the cache hits anyway and compare (a difference is `cache.stale_pass`, exit 1); implies --cached",
    check = function(v)
      if v == "all" then
        return nil
      end
      local n = tonumber(v)
      if n == nil or n ~= n or n < 0 or n > 1 then
        return ("--cache-audit needs a number from 0 to 1 or 'all', got '%s'"):format(v)
      end
      return nil
    end,
  },
  {
    name = "cache_clear",
    long = "cache-clear",
    kind = "flag",
    field = "cache_clear",
    help = "delete the result cache of this project and exit",
  },
  {
    name = "affected",
    long = "affected",
    kind = "optvalue",
    field = "affected",
    arg = "[=<rev>]",
    help = "only the specs the changes since <rev> (default HEAD~1) can reach: a developer tool, never the default in CI",
  },
  {
    name = "changed",
    long = "changed",
    kind = "flag",
    field = "changed",
    help = "only the specs the working tree (against HEAD, untracked files included) can reach",
  },
  {
    name = "since",
    long = "since",
    kind = "value",
    field = "since",
    arg = "<rev>",
    help = "only the specs the working tree against <rev> can reach",
  },
  {
    name = "consumers",
    long = "consumers",
    kind = "value",
    field = "consumers",
    arg = "<dir>",
    help = "with --changed, --since or --affected: name the specs of the checkouts below <dir> that the changes reach (documentation.nvim; a hint, it never narrows this project's selection)",
  },
  {
    name = "retry_failed",
    long = "retry-failed",
    kind = "int",
    field = "retry_failed",
    arg = "<n>",
    min = 1,
    help = "run a red case again up to <n> times (1..10); one that passes is flaky and the run stays red",
    check = function(v)
      local n = tonumber(v)
      if n and n > 10 then
        return ("--retry-failed: at most 10 retries, got '%s'"):format(v)
      end
      return nil
    end,
  },
  {
    name = "allow_flaky",
    long = "allow-flaky",
    kind = "flag",
    field = "allow_flaky",
    help = "with --retry-failed: a case that passes on a retry counts as green (still listed as flaky, never cached)",
  },
  {
    name = "timings",
    long = "no-timings",
    kind = "flag",
    field = "timings",
    const = false,
    help = "do not print the timing line",
  },
}

---Guards that `--guard <name>=<mode>` names (underscores or dashes).
---@type string[]
M.GUARD_NAMES =
  { "fs", "state", "scheduled_error", "prompt", "deprecation", "process_net", "clock" }

---@param v string
---@return string|nil problem
function M.check_guard(v)
  local name, mode = v:match("^([%w_%-]+)=([%w]+)$")
  if not name then
    return ("--guard '%s': expected <name>=<mode>, e.g. fs=error"):format(v)
  end
  name = name:gsub("%-", "_")
  if not vim.tbl_contains(M.GUARD_NAMES, name) then
    return ("--guard: unknown guard '%s' (one of: %s)"):format(
      name,
      table.concat(M.GUARD_NAMES, ", ")
    )
  end
  if name == "clock" then
    if mode ~= "on" and mode ~= "off" then
      return ("--guard clock: the mode is 'on' or 'off', got '%s'"):format(mode)
    end
  elseif mode ~= "off" and mode ~= "warn" and mode ~= "error" then
    return ("--guard %s: the mode is 'off', 'warn' or 'error', got '%s'"):format(name, mode)
  end
  return nil
end

---@param flag string
---@param v string
---@return string|nil problem
function M.check_allow(flag, v)
  if #v > 400 or v:find("%c") then
    return ("%s: not a valid value (too long or control characters)"):format(flag)
  end
  return nil
end

---Parse `i/n` of `--shard`: 1 <= i <= n <= `MAX_SHARDS`, decimal digits only.
---@param v string
---@return { index: integer, count: integer }|nil shard
---@return string|nil problem
function M.parse_shard(v)
  local i, n = tostring(v):match("^(%d+)/(%d+)$")
  if not i or #i > 6 or #n > 6 then
    return nil, ("--shard needs <i>/<n> (e.g. 2/4), got '%s'"):format(tostring(v))
  end
  local index, count =
    tonumber(i), --[[@as integer]]
    tonumber(n) --[[@as integer]]
  if count < 1 or count > M.MAX_SHARDS then
    return nil, ("--shard: <n> must be between 1 and %d, got %d"):format(M.MAX_SHARDS, count)
  end
  if index < 1 or index > count then
    return nil, ("--shard: <i> must be between 1 and <n> (%d), got %d"):format(count, index)
  end
  return { index = index, count = count }, nil
end

---Options that only make sense together with something else are refused, never silently ignored.
---@param args Testing.Args
---@return string|nil problem
function M.check_combination(args)
  local given = args.given
  if args.command == "budget" then
    return nil
  end
  for _, name in ipairs({
    "baseline",
    "factor",
    "budget_update",
    "budget_allow_new",
    "budget_runs",
  }) do
    if given[name] then
      return ("--%s belongs to `budget`"):format((name:gsub("budget_", ""):gsub("_", "-")))
    end
  end
  if args.watch then
    if args.list then
      return "--watch runs the specs; it cannot be combined with --list"
    end
    if args.shard then
      return "--watch cannot be combined with --shard"
    end
    if args.profile then
      return "--profile measures one run; it cannot be combined with --watch"
    end
  else
    if given.watch_debounce then
      return "--watch-debounce needs --watch"
    end
    if given.watch_max_wait then
      return "--watch-max-wait needs --watch"
    end
    if args.watch_poll then
      return "--watch-poll needs --watch"
    end
  end
  if args.profile and args.list then
    return "--profile measures a run; it cannot be combined with --list"
  end
  local selecting = {}
  if args.changed then
    selecting[#selecting + 1] = "--changed"
  end
  if args.since ~= nil then
    selecting[#selecting + 1] = "--since"
  end
  if args.affected then
    selecting[#selecting + 1] = "--affected"
  end
  if #selecting > 1 then
    return table.concat(selecting, " and ") .. " exclude each other"
  end
  if args.consumers ~= nil and #selecting == 0 then
    return "--consumers asks which specs of other checkouts a change reaches: it needs --changed, --since or --affected"
  end
  if args.allow_flaky and args.retry_failed == nil then
    return "--allow-flaky needs --retry-failed <n>"
  end
  if args.retry_failed ~= nil and (args.list or args.watch) then
    return "--retry-failed repeats red cases of a run; it cannot be combined with --list or --watch"
  end
  if args.cache_audit ~= nil and args.cache_refresh then
    return "--cache-audit compares cache hits; --cache-refresh never reads the cache: they exclude each other"
  end
  if args.watch and (#selecting > 0 or args.cache or args.cache_refresh or args.cache_audit) then
    return "--watch selects the changed files itself; it cannot be combined with --cached, --cache-refresh, --changed, --since or --affected"
  end
  if
    args.cache_clear
    and (#selecting > 0 or args.cache or args.cache_refresh or args.cache_audit or args.watch)
  then
    return "--cache-clear only deletes the cache and exits; it cannot be combined with a run option"
  end
  return nil
end

---@type table<string, Testing.Args.Option>
local BY_LONG, BY_SHORT = {}, {}
for _, o in ipairs(OPTIONS) do
  if o.long then
    BY_LONG[o.long] = o
  end
  if o.short then
    BY_SHORT[o.short] = o
  end
end

---Usage text, built from the option table so that it cannot drift from the parser.
---@return string
function M.usage()
  local lines = {
    "usage: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|init|list|doctor|budget|conformance|surface] [<root>] [options]",
    "       nvim -n -i NONE --headless -u NONE -l scripts/testing.lua migrate [dry-run|apply] [<path>] [--json|--markdown] [--check] [--fleet-root=<dir>]",
    "",
    "  run      run the spec files of <root> (default)",
    "  list     list what would run (= run --list)",
    "  doctor   print the resolved configuration and the dependency report",
    "  budget   measure the performance budgets and compare them with the baseline (exit 1 when one is exceeded)",
    "  conformance  run the conformance checks K1..K15 on <root> (own options: conformance --help)",
    "  surface  list the plugin's surface (keymaps, commands, ...) and how much the specs exercised (surface --help)",
    "  explain  why a spec was selected, cached or run, and what its cache key is made of: explain <root> <spec>... [--all] [--json] [--parts]",
    "  stamp    run the suite and, after a COMPLETE green run, write the green stamp: stamp <root> [--out <file>] [--note] [run options]",
    "  verify   is the tree still the one a green stamp proved? (no spec runs; exit 0 + sentinel only when every file is proven): verify <root> [--stamp <file>|--from-note] [--max-age 7d] [--allow-dirty] [--require-hmac] [--allow-unsigned] [--json]",
    "  init     scaffold .testing.lua, TESTS/minimal_init.lua, scripts/test.sh, a CI job",
    "  migrate  plan (or write) the move of a repository from plenary / busted / its own runner to testing.nvim",
    "",
    "  <root>   project root; further positionals are paths below it",
  }
  for _, o in ipairs(OPTIONS) do
    local spelled = {}
    if o.short then
      spelled[#spelled + 1] = "-" .. o.short
    end
    if o.long then
      spelled[#spelled + 1] = "--" .. o.long
    end
    local left = table.concat(spelled, ", ") .. (o.arg and (" " .. o.arg) or "")
    lines[#lines + 1] = ("  %-24s %s"):format(left, o.help)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "exit: 0 green, 1 failures, 2 usage/config error, 3 infrastructure error"
  return table.concat(lines, "\n")
end

---@return Testing.Args
local function new_args()
  return {
    command = "run",
    help = false,
    paths = {},
    github = false,
    filter = {},
    file = {},
    tags = {},
    exclude_tags = {},
    lf = false,
    ff = false,
    shuffle = false,
    list = false,
    strict = false,
    rtp = {},
    env_allow = {},
    guard = {},
    allow_fs = {},
    allow_spawn = {},
    allow_network = {},
    first_run = false,
    watch = false,
    watch_poll = false,
    profile = false,
    budget_update = false,
    budget_allow_new = false,
    cache_clear = false,
    no_cache = false,
    cache_refresh = false,
    changed = false,
    allow_flaky = false,
    timings = true,
    given = {},
  }
end

---Parse a non-negative decimal integer, nothing else (no hex, no exponent, no sign).
---@param v string
---@return integer|nil
local function parse_uint(v)
  if v:match("^%d+$") and #v <= 15 then
    return tonumber(v)
  end
  return nil
end

---Apply one option with its (already extracted) value; returns a problem text or nil.
---@param args Testing.Args
---@param o Testing.Args.Option
---@param spelled string The spelling the user typed, for messages.
---@param value string|nil
---@return string|nil
local function apply(args, o, spelled, value)
  if o.kind == "flag" then
    if value ~= nil then
      return ("option %s takes no value"):format(spelled)
    end
    if o.const == nil then
      args[o.field] = true
    else
      args[o.field] = o.const
    end
  else
    if o.kind == "optvalue" and value == nil then
      args[o.field] = true
      args.given[o.name] = true
      return nil
    end
    if value == nil or value == "" then
      return ("option %s needs a value"):format(spelled)
    end
    if o.word and value == o.word then
      args[
        o.word_field --[[@as string]]
      ] = true
      args.given[o.name] = true
      return nil
    end
    if o.check then
      local why = o.check(value)
      if why then
        return why
      end
    end
    if o.kind == "value" or o.kind == "optvalue" then
      args[o.field] = value
    elseif o.kind == "list" then
      local list = args[o.field]
      list[#list + 1] = value
    elseif o.kind == "csv" then
      local list = args[o.field]
      for item in value:gmatch("[^,]+") do
        item = vim.trim(item)
        if item ~= "" then
          if not item:match("^[%w_.:%-]+$") then
            return ("option %s: invalid tag '%s' (letters, digits and _ . : - only)"):format(
              spelled,
              item
            )
          end
          list[#list + 1] = item
        end
      end
    elseif o.kind == "int" then
      local n = parse_uint(value)
      if n == nil or n < (o.min or 0) then
        if o.word then
          return ("option %s needs an integer >= %d or '%s', got '%s'"):format(
            spelled,
            o.min or 0,
            o.word,
            value
          )
        end
        return ("option %s needs an integer >= %d, got '%s'"):format(spelled, o.min or 0, value)
      end
      args[o.field] = n
    end
  end
  args.given[o.name] = true
  return nil
end

---Parse the arguments. Returns nil and a message on a usage error.
---@param argv string[]
---@return Testing.Args|nil
---@return string|nil problem
function M.parse(argv)
  local args = new_args()
  local i, n = 1, #argv
  local positionals = {}

  if n >= 1 then
    for _, list in ipairs({ M.SUBCOMMANDS, M.RESERVED_COMMANDS }) do
      for _, name in ipairs(list) do
        if argv[1] == name then
          args.command = name --[[@as "run"|"init"|"list"|"doctor"|"budget"|"conformance"|"surface"|"explain"|"verify"]]
          i = 2
        end
      end
    end
  end

  local options_done = false
  while i <= n do
    local a = tostring(argv[i])
    if options_done or a == "-" or a:sub(1, 1) ~= "-" then
      positionals[#positionals + 1] = a
    elseif a == "--" then
      options_done = true
    elseif a:sub(1, 2) == "--" then
      local name, inline = a:match("^%-%-([^=]+)=(.*)$")
      if not name then
        name = a:sub(3)
      end
      local o = BY_LONG[name]
      if not o then
        return nil, ("unknown option %s"):format(a)
      end
      local value = inline
      if value == nil and o.kind ~= "flag" and o.kind ~= "optvalue" then
        local nxt = argv[i + 1]
        if nxt ~= nil and tostring(nxt):sub(1, 2) ~= "--" then
          value = tostring(nxt)
          i = i + 1
        end
      end
      local problem = apply(args, o, "--" .. name, value)
      if problem then
        return nil, problem
      end
    else
      local o = BY_SHORT[a:sub(2)]
      if not o then
        return nil, ("unknown option %s"):format(a)
      end
      local problem = apply(args, o, a, nil)
      if problem then
        return nil, problem
      end
    end
    i = i + 1
  end

  if args.help then
    return args, nil
  end

  if args.root == nil then
    args.root = table.remove(positionals, 1)
  end
  args.paths = positionals

  if args.lf and args.ff then
    return nil, "--lf and --ff exclude each other"
  end
  if args.seed ~= nil and not args.shuffle then
    return nil, "--seed needs --shuffle"
  end
  if args.order ~= nil and args.shuffle then
    return nil, "--order and --shuffle exclude each other"
  end
  if args.command == "list" then
    args.list = true
  end
  if args.shard_text ~= nil then
    args.shard = M.parse_shard(args.shard_text)
  end
  if args.cache_audit_text ~= nil then
    args.cache_audit = args.cache_audit_text == "all" and 1 or tonumber(args.cache_audit_text)
  end
  if args.factor_text ~= nil then
    args.factor = tonumber(args.factor_text)
  end
  local problem = M.check_combination(args)
  if problem then
    return nil, problem
  end
  return args, nil
end

---Options that decide WHAT a repeat of a failed case runs or HOW the result is shown: a repeat command
---(`--reporter agent`'s `rerun:` line) is the original arguments without them.
---@type table<string, true>
M.REPEAT_DROP = {
  reporter = true,
  agent_budget = true,
  format = true,
  json = true,
  events = true,
  junit = true,
  github = true,
  filter = true,
  file = true,
  tags = true,
  exclude_tags = true,
  lf = true,
  ff = true,
  list = true,
  maxfail = true,
  shuffle = true,
  seed = true,
  durations = true,
  profile = true,
  timings = true,
  cache = true,
  no_cache = true,
  cache_refresh = true,
  cache_audit = true,
  cache_clear = true,
  affected = true,
  changed = true,
  since = true,
  shard = true,
  order = true,
  watch = true,
  watch_debounce = true,
  watch_max_wait = true,
  watch_poll = true,
}

---The arguments of `argv` without the options in `drop` (default `REPEAT_DROP`) and without the path
---positionals (the subcommand word and the root stay). Pure; an argument it does not know stays.
---@param argv string[]
---@param drop? table<string, true>
---@return string[]
function M.repeat_argv(argv, drop)
  drop = drop or M.REPEAT_DROP
  local out = {}
  local i, n = 1, #argv
  local positionals = 0
  local options_done = false
  while i <= n do
    local a = tostring(argv[i])
    local o, takes
    if options_done or a == "-" or a:sub(1, 1) ~= "-" then
      positionals = positionals + 1
      local is_word = i == 1 and vim.tbl_contains(M.SUBCOMMANDS, a)
      if is_word or positionals <= 1 then
        out[#out + 1] = a
      end
      if is_word then
        positionals = positionals - 1
      end
    elseif a == "--" then
      options_done = true
    else
      local inline
      if a:sub(1, 2) == "--" then
        local name, value = a:match("^%-%-([^=]+)=(.*)$")
        o = BY_LONG[name or a:sub(3)]
        inline = value
      else
        o = BY_SHORT[a:sub(2)]
      end
      takes = o ~= nil and inline == nil and o.kind ~= "flag" and o.kind ~= "optvalue"
      local nxt = argv[i + 1]
      local consumes = takes and nxt ~= nil and tostring(nxt):sub(1, 2) ~= "--"
      if not (o and drop[o.name]) then
        out[#out + 1] = a
        if consumes then
          out[#out + 1] = tostring(nxt)
        end
      end
      if consumes then
        i = i + 1
      end
    end
    i = i + 1
  end
  return out
end

return M
