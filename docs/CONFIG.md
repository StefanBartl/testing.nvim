# Configuration

testing.nvim has two separate configurations. Do not mix them up.

| What | Where | Used by |
| --- | --- | --- |
| The **project file** `.testing.lua` | the root of the project under test | the command-line runner (`scripts/testing.lua`) |
| The **plugin options** of `require("testing").setup(opts)` | your Neovim config | the editor commands (`:Testing`) |

## `.testing.lua` (per project)

A Lua file in the project root that returns a table. Every key is optional; what is not named
keeps its default. This repository's own [`.testing.lua`](../.testing.lua) is a working example.

```lua
-- .testing.lua
return {
  plugin = "myplugin",
  roots = { "TESTS" },
  dialect = "auto",
  minit = "TESTS/minimal_init.lua",
  deps = { "plenary.nvim" },
}
```

**Security.** Loading `.testing.lua` executes it with the privileges of the editor process, the
same trust as running the project's own specs. The runner therefore loads it only from the root
you named on the command line (or from `--config <file>`, which must lie inside that root once
symlinks are resolved), as text (never as bytecode) and below 256 KiB. `:checkhealth testing` does
not execute it: it evaluates the file in an empty environment with an instruction budget and says so
when the file needs more than a plain table.

**Validation.** Keys are checked before they are merged over the defaults. An invalid value, an
unknown key and a table where a scalar belongs each produce one warning that names the key and what
was expected; the default stays in place and the run goes on. Only a file that cannot be used at
all (syntax error, raises, does not return a table, lies outside the root) is an error: exit code
`2`.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `plugin` | string, letters/digits/`._-` | directory name without `.nvim` | Lua module root of the project. |
| `roots` | non-empty list of relative paths without `..` | `{ "TESTS" }` | Spec roots below the project root. |
| `spec_pattern` | non-empty list of Lua patterns | `{ "_spec%.lua$" }` | What makes a file below a root a spec, matched against its project-relative path. A project whose specs lack the suffix (self-running scripts such as `TESTS/units.lua`) names its own, e.g. `{ "_spec%.lua$", "^TESTS/[%w_]+%.lua$" }`. `harness.lua`, `run.lua` and `minimal_init.lua` directly in a root are never specs; `TESTS/refs/run.lua` is one when a pattern names it. |
| `dialect` | one of `"auto"`, `"testing"`, `"a"`, `"b"`, `"c"`, `"d"`, `"h"`, `"busted"`, `"script"`, or a table `{ ["<path or glob>"] = "<name>", ["*"] = "<name>" }` | `"auto"` | `"auto"` sniffs the dialect per file; a name forces one dialect for every file; the table form sets it per file (a literal relative path wins over a glob with more literal characters, the lone `"*"` is the fallback; `*` is one segment, `**` crosses segments, `?` one character). See [DIALECTS.md](DIALECTS.md). |
| `assertions` | `"error"` or `"warn"` | `"error"` | A case without a single assertion: `"error"` fails it (the default, "a case that asserts nothing proves nothing"); `"warn"` passes it, records `no_assertions` and a note in the IR, and the terminal lists the cases. A migrated plenary repository uses `"warn"`: plenary let such cases pass. The same switch decides what a **busted file without a registered case** is (a spec that registers cases per platform has none on the others): `"error"` fails it, `"warn"` records one `skip` case (`no case registered on this platform`, with a warning note and a terminal listing); under `--strict` that skip makes the run red. |
| `isolated` | `"auto"`, `"none"`, `"file"`, `"case"` or `"soft"` | `"auto"` | `"file"`: every spec file runs in a child editor of its own; `"case"`: a child per case (busted; every other dialect runs as `"file"`, with a note); `"soft"`: all in this editor, what a file changed is restored before the next one; `"none"`: all in this editor, nothing restored; `"auto"`: `"file"` for busted files, `"none"` for the other dialects. A `script` is always a child. See [ISOLATION.md](ISOLATION.md). |
| `guards` | table `{ fs, state, scheduled_error, prompt, deprecation, process_net = "off"\|"warn"\|"error"; clock = boolean }` | `fs = "warn"`, `state = "warn"`, `scheduled_error = "error"`, `prompt = "error"`, `deprecation = "warn"`, `process_net = "off"`, `clock = false` | The guards (safety nets, not a sandbox): installed in this editor and in every child, their findings are in the report and the IR (`case.guards`, `case.effects`). `--guard name=mode`. Every guard except `clock` also takes a table `{ mode = ..., <tuning> }` (no `mode`: the default one), for example `state = { mode = "warn", categories = { autocmds = "off" }, ignore_groups = { "MyPlugin" }, keep = { "MyPlugin" } }` or `fs = { allow = { "TESTS/tmp" } }`: see [Tuning a guard](GUARDS.md#tuning-a-guard-in-testinglua). An unknown key or a wrong type is one warning that names the key; the default stays. These are the **runner** defaults; the guard layer's own (`testing.guard.config`, used by a spec that calls `testing.guard.install` directly) are listed in [GUARDS.md](GUARDS.md). See also [ISOLATION.md](ISOLATION.md). |
| `guard_allow` | table `{ fs, spawn, network }` of string lists | all empty | What the guards let through on purpose: paths a spec may write below, executables it may start, hosts it may connect to. Shown in the report, never silent. `--allow-fs`, `--allow-spawn`, `--allow-network`. |
| `pool` | table `{ size = integer >= 0, reuse = boolean }` | `{ size = 0, reuse = false }` | The warm pool: with `reuse` the files of an `isolated = "file"` run share child editors that are reset and VERIFIED clean between files (a member that cannot prove it is clean is replaced, and a finding says why); `size` editors at most (`0`: `min(jobs, 4)`, never more than `jobs`). `--pool-reuse`, `--pool-size`. See [CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor). |
| `determinism` | boolean | `true` | A child starts with `LANG`/`LC_ALL=C.UTF-8` and `TZ=UTC`; `false` passes the parent's through. `--no-determinism`. |
| `trace` | boolean | `true` | A child that timed out or died leaves a trace artifact on its `timeout` / `crash` case. `--no-trace`. |
| `soft_keep` | list of module names (`prefix*` allowed) | `{}` | Modules the soft isolation (`isolated = "soft"`, the warm pool) never unloads. |
| `jobs` | integer 1..256, or `"auto"` | `1` | Child editors running at once. The report is the same for any value. `"auto"` is cores minus one (at least 1), resolved by the command line before the run; `--jobs` overrides it. |
| `shard.balance` | `"size"`, `"count"`, `"hash"` or `"history"` | `"size"` | How `--shard i/n` weighs the spec files: file bytes (the same on every job of a CI matrix), equal counts, a stable hash of the path (adding a file moves no other), or measured durations. See [CLI.md](CLI.md#sharding). |
| `shard.durations` | relative path without `..` | absent | JSON file `{ "<spec path>": <ms> }` that `balance = "history"` reads instead of the local history. Absent on purpose (opt-in): with it, every job of a matrix reads the same durations; without it a job's own history decides, and jobs can compute different partitions. |
| `watch.debounce_ms` | integer > 0 | `150` | `--watch`: quiet time after the last change before a re-run (an editor save fires several events). `--watch-debounce` overrides it. |
| `watch.poll_ms` | integer > 0 | `1000` | `--watch`: polling interval of the fallback used when the file system cannot deliver events (or with `--watch-poll`). |
| `budget.factor` | number 1..1000 | `2.0` | `testing budget`: a measurement may be this many times its baseline before the check fails. `--factor` overrides it. |
| `budget.baseline` | relative path without `..` | `"TESTS/bench/baseline.json"` | `testing budget`: the baseline file `--update` writes. `--baseline` overrides it. |
| `host` | `"c"` or `"l"` | `"c"` | How a child starts: `"c"` like plenary's host (a `-c` command: `vim.v.vim_did_enter` is `0`, `expand("<cword>")` works), `"l"` like `nvim -l`. |
| `filetype` | boolean | `true` | A child runs `filetype plugin indent on` (plenary's minimal init does). |
| `disable_first_run` | boolean | `true` | Test-environment default: every editor the runner starts (each child, and this editor for an in-process run, restored afterwards) gets `vim.g.lib_nvim_deps_disable_first_run = true` **before** the project's `minit` runs. lib.nvim shows a one-time "missing tools" float on a plugin's first start when `stdpath('cache')` is empty; a child's cache is always empty, so without this the float opens windows and buffers inside a spec. A value the project (or the user) already set is left alone; `false` leaves the variable untouched. |
| `env_allow` | list of names, each optionally ending in `*` | `{}` | Environment variables a child may inherit on top of the built-in allowlist (`PATH`, `HOME`, `LANG`, `LC_*`, ...; secrets are never passed). `{ "REPOS_DIR", "MAGICK_*" }`. A bare `*` and names starting with `NVIM` are refused. `--env-allow` adds to it. |
| `minit` | `false` or relative path | `"TESTS/minimal_init.lua"` | Minimal init of the project; it runs in this editor and in every child before the spec. |
| `deps` | list of directory names | `{}` | Dependencies the run needs (see below). A missing one is exit code `3`. |
| `setup` | table | `{}` | Options `testing conformance` and `testing surface` call the plugin's `setup()` with. Put the options that switch every optional part on here: opt-in keymaps that the default `setup()` does not bind are not part of the surface. |
| `timeouts.case_ms` | integer > 0 | `10000` | Timeout of one case: a guard in this editor, **hard** in a child (a busted file whose child writes no new case for `case_ms` + 2 s is killed with its process tree). |
| `timeouts.file_ms` | integer > 0 | `60000` | Timeout of one spec file; hard in a child (`file_ms` + 2 s, then the process tree is killed and the file is one `timeout` case). |
| `conformance.load_budget_ms` | number >= 0 | `40` | K10 of `testing conformance`: `require` + `setup()` must fit in this many milliseconds. |
| `conformance.gate` | boolean | `false` | `true`: `testing conformance` exits `1` when a check failed. Off until the findings of the repository are triaged ([CONFORMANCE.md](CONFORMANCE.md)). |
| `conformance.skip` | list of check ids | `{}` | `{ "K10" }`: checks that do not run (they stay in the report as `n/a`). |
| `conformance.waivers` | list of tables | `{}` | Accepted findings: `{ check = "K4", reason = "...", rule?, file?, text? }`. A waiver **needs a reason** of at least 8 characters; one without is ignored and named. |
| `conformance.keymaps_off` | table | `{ keymaps = false }` | What K3 passes to `setup()` on top of `setup` to switch the keymaps off. |
| `conformance.timeout_ms` | integer 1000..600000 | `20000` | Timeout of one call into the conformance child editor. |
| `conformance.rules_bridge.rulesets`, `.families` | list of paths, non-empty list of prefixes | none, `{ "NEW", "REL" }` | `testing conformance --bridge`: the rule files and rule families of rules.nvim to run on top. |
| `surface.track` | boolean | `false` | `true`: the runner counts which keymaps, commands and autocmds the cases exercise and writes `surface = { hit = { ids... } }` into every case of the IR (in a child editor per file and in this editor; not with the warm pool, which says so). `testing surface --from ir.json` reads it ([SURFACE.md](SURFACE.md)). |
| `surface.threshold` | number 0..1 | `0` | Gate on the overall ratio of `testing surface`; `0` = only report. |
| `surface.kinds` | list of `binding`, `command`, `autocmd`, `api` | `{ "binding", "command", "autocmd" }` | The kinds counted in the ratio. |
| `surface.ignore` | list of Lua patterns | `{}` | Entry ids that are not counted. |
| `surface.setup_chunk` | string | absent | Lua code the surface is read after. |
| `cache.enabled` | boolean | `false` | `true`: reuse the results of unchanged spec files without `--cached`. Ignored in CI: a default never decides there ([CACHE.md](CACHE.md)). `--no-cache` wins. |
| `coverage.bindings`, `.commands`, `.autocmds` | number 0..1 | `0` | Gate thresholds of `testing surface` per kind; `0` = report only. |
| `snapshots.dir` | relative path | `"TESTS/__snapshots__"` | Reserved (snapshots). |
| `backends.luals`, `.pty`, `.playwright`, `.webdriver` | boolean | `false` | Reserved (optional backends). |

"Reserved" keys are validated and kept, but nothing acts on them yet. A key of the tables above that is invalid
is reported with its name and the default stays (a bad `conformance.gate` never switches a gate on).

### Child editors

With `isolated = "file"` (and for every `script` file) a spec file runs in a **child editor**:
`nvim -n -i NONE --headless -u NORC`, started from the project root with an environment allowlist
(`env_allow`) and its own `stdpath` data/state/cache/config and temp directories, stdin from the null
device. The editor's runtime plugins load (netrw, matchit, ...), the dependencies and the project's
`minit` are on its runtimepath, and the `$<NAME>_DIR` of every resolved dependency is set, so an
editor a spec starts itself finds them too. A child that dies (native crash, `os.exit`, no result)
becomes **one** `crash` case of that file; one that exceeds its limit is killed with its whole process
tree and becomes one `timeout` case. Either way the other files run on. See
[the child driver](../lua/testing/child/README.md).

### Dependencies

A dependency `<name>` (for example `lib.nvim` or `plenary.nvim`) is looked up in four places, in
this order. The first one that holds a valid checkout wins:

1. `$<NAME>_DIR`, where every character outside `A-Z0-9` of the upper-cased name becomes `_`
   (`lib.nvim` gives `$LIB_NVIM_DIR`)
2. `<root>/.deps/<name>` (what CI checks out)
3. `<root>/../<name>` (a sibling checkout)
4. `stdpath("data")/lazy/<name>` (what a plugin manager installed)

An override in place 1 that is set but not valid is a failure, not a reason to fall through: an
override that is silently ignored is a lie about which code ran. When nothing is found, the message
names all four places and what was found at each, and the exit code is `3`.

A project that is checked out where its siblings are not (a git worktree, a temporary copy) still finds
its `deps` without any `$<NAME>_DIR`: when places 2 and 3 of the project have nothing, the same two
places beside the **runner's** checkout are tried (the source reads `(beside the runner)`). An invalid
override is never replaced by this.

`lib.nvim` is the runner's own hard dependency and is resolved the same way, relative to the
testing.nvim checkout. A stale copy that comes first in that order (a `.deps/lib.nvim` left over from an
earlier CI run) that lacks what the runner needs (`fs.write.atomic`, lib.nvim >= 6304829) is not used
blindly: the runner exits `3` and names the checkout, what is missing, the commit that has it and the four
places. `testing doctor` prints the resolution of everything.

## Plugin options (`setup()`)

```lua
require("testing").setup({
  notify_prefix = "[testing]",
  keymaps = {},
})
```

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `notify_prefix` | non-empty string | `"[testing]"` | Prefix of every message the plugin shows. |
| `keymaps` | `table<string, string\|string[]\|false>` or `false` | `{}` | Moves or drops named keymap actions; `false` binds no key at all. See [BINDINGS.md](BINDINGS.md). |

A key with the wrong type, and any unknown key, is dropped and reported with a warning; the
default stays in place.
