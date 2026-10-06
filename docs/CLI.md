# Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|list|doctor|budget|conformance|surface|init] [<root>] [options]
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua migrate [dry-run|apply] [<path>] [options]
```

Run it from `<root>`, the project whose specs should run: specs that look at "this repository" read
the working directory, and the runner deliberately does not change it (it says so when the working
directory is not the root). `-n -i NONE -u NONE` keep the run independent of the developer's shada,
swap files and config.

For this repository `scripts/test.sh` is the same thing with an isolated state directory:

```sh
scripts/test.sh                    # every spec under TESTS/
scripts/test.sh --file config      # only spec files whose name contains "config"
```

## Subcommands

| Subcommand | Does |
| --- | --- |
| `run` (default) | Discover and run the specs of `<root>`. |
| `list` | List what would run, run nothing (same as `run --list`). |
| `doctor` | Print the resolved configuration and the dependency report. Evaluates `.testing.lua`. |
| `migrate` | Plan (`dry-run`, the default) or write (`apply`) the move of a plugin repository from plenary, busted or a hand-written runner to testing.nvim, specs unchanged. It has its own arguments and exit codes: [MIGRATING.md](MIGRATING.md). |
| `budget` | Measure the hot paths of a run (`testing doctor` start, discovery of 100 files, IR encode of 10 000 cases, history append, hashing 500 files, starting / ending / calling a child editor) and compare them with a stored baseline; exit `1` when one is slower than baseline x factor. See [`testing budget`](#testing-budget) and [PERFORMANCE.md](PERFORMANCE.md). `<root>` defaults to the current directory. |
| `conformance` | The conformance checks K1 .. K15 on `<root>`, reported as data and terminal lines; report only unless `--gate` or `conformance.gate`. It has **its own arguments and exit codes**, so everything after the word goes to it, not to the run options: `testing conformance [<root>] [--only K3,K7] [--skip K10] [--gate] [--json\|--markdown] ...`, see [CONFORMANCE.md](CONFORMANCE.md). |
| `surface` | The plugin's surface (keymaps, commands, autocmds, ...) and how much of it the specs exercised. Own arguments and exit codes too: `testing surface [<root>] [--from ir.json] [--threshold 0.8] [--baseline b.json] [--json\|--markdown]`, see [SURFACE.md](SURFACE.md). A run is tracked with `surface = { track = true }` in `.testing.lua`: every case of the `--json` IR then carries `surface.hit`. |
| `init` | Scaffold `.testing.lua`, `TESTS/minimal_init.lua`, `scripts/test.sh` and a CI job in a project. Today only as the editor command `:Testing init` ([BINDINGS.md](BINDINGS.md)); on the command line it is refused with exit code `2`. |

The subcommand is the first argument, when it is exactly one of those words. Any other first
argument is the project root; a directory that is itself called `list` is spelled `./list` or
`--root list`.

## Options

Long options take their value as `--name value` or `--name=value`. The space form's value must not
start with `--` (spell `--name=--x` for that). `--` ends the options. Repeatable options accumulate;
a repeated single-value option is last-wins. An unknown option is exit code `2`.

An option that is accepted by the parser but not implemented is **refused** with exit code `2`
("not implemented yet"), never ignored. The tables below state which is which.

### Selecting what runs

| Option | Meaning |
| --- | --- |
| `<root>` / `--root <dir>` | Project root. |
| `--config <file>` | Project configuration file; must lie inside the root (default `<root>/.testing.lua`). |
| `--file <text>`, `--only <text>` | Only spec files whose **file name** contains `<text>` (literal, not a pattern); repeatable. |
| `--filter <text>` | Only cases whose name contains `<text>` (literal); repeatable. |
| `--tags <a,b>`, `--exclude-tags <a,b>` | Only cases with one of these tags / drop cases with one of them (exclusion wins). A tag is a `#word` in a busted `describe` or `it` title (`it("parses #slow input")`, applying to everything below a `describe`), or a header line `-- @tags slow integration` near the top of any spec, which tags every case of the file. |
| `--lf`, `--ff` | Only what failed last time; what failed last time first. The history lives in `stdpath("state")/testing/<project>/runs.jsonl`, is bounded, and is a convenience: it is never part of the verdict. |
| `--list`, `--dry-run` | List what would run, run nothing. |
| `--shard <i>/<n>` | Run only shard `i` (1-based) of `n`: a deterministic partition of the spec files for CI matrices, see [Sharding](#sharding). Works with `--list`. |
| `--cached`, `--no-cache`, `--cache-refresh`, `--cache-clear` | The result cache: a spec file whose inputs are byte-identical to an earlier green run does not run, and its cases are reported as cached. Off unless asked for; `--no-cache` always wins. See [Result cache](#result-cache). |
| `--changed`, `--since <rev>`, `--affected[=<rev>]` | Only the specs the changes can reach (working tree against `HEAD`, against `<rev>`, or the last commit). A partial run: never a sentinel. See [Affected selection](#affected-selection). `--affected` takes its revision only as `--affected=<rev>`: a bare `--affected` never swallows the next argument. |

### Controlling the run

| Option | Meaning |
| --- | --- |
| `-x`, `--maxfail <n>` | Stop after the first / the `<n>`th failure. Cases that did not run are not in the report, and the run says so. |
| `--shuffle`, `--seed <n>` | Random order; the seed is printed so a failure can be reproduced. |
| `--case-timeout <ms>`, `--file-timeout <ms>` | Timeouts of one case and one spec file (defaults from `timeouts` in `.testing.lua`). A case over its limit has the status `timeout`. In this editor the guard is best effort (it interrupts Lua code and `vim.wait`, not a spec that blocks inside C). In a child editor (`--isolated file`) the limits are **hard**: the child and its whole process tree are killed (`file_ms` + 2 s grace; for busted files also `case_ms` + 2 s without a new case once the first one is in). |
| `--strict` | A skipped case and a discovery finding (legacy spec location, symlink, unknown dialect) make the run red. |
| `--rtp <dir>` | Add `<dir>` to the runtimepath; repeatable. `<root>` is always added. |
| `--isolated <none\|file\|case\|soft>` | `file`: every spec file runs in a **child editor of its own** (like plenary: nothing leaks from one file into the next; a crash, a hang or a prompt ends that file only). Default `auto` (`.testing.lua` `isolated`): busted files `file`, the other dialects `none`; a `script` is always a child. |
| `--pool-reuse`, `--no-pool-reuse`, `--pool-size <n>` | The warm pool: with `--pool-reuse` the files of an `--isolated file` run share child editors that are reset and verified clean between files, instead of a child per file. `--pool-size` caps the editors (default `min(--jobs, 4)`). A member that crashes or hangs dies alone; one that cannot prove it is clean is replaced and a `pool` finding names the leak. `script` files and `--isolated case` never use it. See [CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor). |
| `--guard <name>=<mode>`, `--allow-fs <path>`, `--allow-spawn <exe>`, `--allow-network <host>` | The guards and what they let through ([ISOLATION.md](ISOLATION.md#guards)); repeatable. |
| `--no-determinism`, `--no-trace` | A child keeps the parent's `LANG`/`LC_ALL`/`TZ` / leaves no trace artifact when it dies. |
| `--jobs <n\|auto>` | Child editors running at once (default 1, `.testing.lua` `jobs`); `auto` is cores minus one (at least 1). The permits are a `lib.nvim.async.Semaphore`; the report, the printed child output and the exit code are the same for any `n`: results are merged in file order. See [Worker pool](#worker-pool). |
| `--watch`, `--watch-debounce <ms>`, `--watch-poll` | Run, then re-run on every change, see [Watch](#watch). |
| `--host <c\|l>` | How a child starts. `c` (default): like plenary's host, the spec runs from a `-c` command (`v:vim_did_enter` is 0, `expand('<cword>')` works). `l`: `nvim -l`. A `script` prefers `l` unless this is given. |
| `--env-allow <name>` | An environment variable (or `PREFIX*`) a child may inherit, on top of the allowlist; repeatable. See [child editors](../lua/testing/child/README.md). |
| `--first-run` | Keep lib.nvim's one-time "missing tools" float enabled. By default the runner switches it off in every editor it starts (`disable_first_run`); lib.nvim's own suite tests that float and needs this flag. |

#### What happens to a child

* **It finishes**: its cases are merged. **It dies** (a native crash such as a segfault in a library,
  `os.exit`, `:cquit`, a signal, an exit code other than `0`, no result): the cases it finished plus ONE
  `crash` case for the file, naming the exit (`exit code 3221225477 = NTSTATUS 0xC0000005`, `signal 11
  (SIGSEGV)`) and the tail of its stderr. The run goes on; the exit code is `1`.
* **It hangs** (a blocking C call, a language server's prompt that nobody answers: stdin is the null
  device and `input()` / `inputlist()` / `confirm()` answer "cancelled"): `file_ms` (+ 2 s) after the
  start, or for busted files `case_ms` (+ 2 s) without a new case, the child **and its process tree**
  are killed and the file ends with ONE `timeout` case. A process that is still alive 10 s after the kill
  is abandoned: the run never waits for it.
* **It leaves a helper behind** that holds its stdout/stderr (a language server): the child counts as
  finished when its own process ended (plus 200 ms to read what was still in the pipes), not when the
  helper ends. On POSIX the leftovers of its process group are killed; on Windows they are not (no job
  objects from Lua), but they cannot hold the run any more.
* What a child printed is shown **in file order**, once, with the header `output of <file>:`.

### Output

| Option | Meaning |
| --- | --- |
| `--reporter <name>` | Terminal reporter (`term`, `github`, `junit`, `json`). |
| `--json <file>` | Write the Result-IR (`schema_version = 1`) and validate it again. |
| `--junit <file>` | Write a JUnit XML report. |
| `--github` | Emit GitHub Actions annotations and the step summary. |
| `--durations <n>` | Name the `<n>` slowest cases (`0` = all). |
| `--profile` | Where the time went: phases, slowest files and cases, histogram, child start cost, pool use. Text on **stderr** (so the sentinel stays the last line of stdout) and `run.profile` in the `--json` IR. See [Profile](#profile). |
| `--sentinel <name>` | Last line of a fully green run (default `TESTING_OK`, or the one the project's old `TESTS/run.lua` printed). |
| `--no-timings` | Do not print the timing line. |

Reporters and the IR are described in [OUTPUT-FORMATS.md](OUTPUT-FORMATS.md).

### `testing budget`

```sh
testing budget [<root>] [--baseline <file>] [--factor <x>] [--runs <n>] [--filter <case>] [--update] [--allow-new]
```

| Option | Meaning |
| --- | --- |
| `--update` | Measure and write the result as the new baseline (`budget.baseline`, default `TESTS/bench/baseline.json`). Cases that were not measured (`--filter`) keep their old entry; nothing is written when a case cannot be measured. |
| `--baseline <file>` | Another baseline file. |
| `--factor <x>` | A case fails when its median is above baseline x `<x>` (1..1000; default `budget.factor` = 2.0). It also has to be more than 1 ms slower: below a millisecond the clock decides. |
| `--runs <n>` | Timed runs per case (default 5, 3 for a case that starts a process). |
| `--allow-new` | A measured case that has no baseline entry yet is not an error (see the exit codes): without it the gate compared nothing for that case and says so. |
| `--filter <text>` | Only the cases whose name contains `<text>`; repeatable. |

Exit codes: `0` every case within its limit (or the baseline was written), `1` a case exceeded its limit, `2` no
baseline (write one with `--update`), no case matches, or a measured case has **no baseline entry** (a renamed case, a
corrupted entry, a new one: the gate compared nothing; `--allow-new` accepts it), `3` a case could not be measured
(never a pass). Baseline entries that nobody measures any more are listed (not with `--filter`). The `machine` of the
baseline file is printed as plain, bounded text: the file is committed and a pull request can edit it. The check
is meant for a nightly or manual job, not for a merge gate: a CI runner is a different machine than the one that
wrote the baseline. [PERFORMANCE.md](PERFORMANCE.md) has the method, the cases and the numbers.

### Sharding

`--shard i/n` runs the files of bucket `i` of `n`. Every job of a CI matrix computes the same `n` buckets from the
same file list and takes its own, so together they run every spec file once and no file twice.

```yaml
strategy:
  matrix:
    shard: [1/4, 2/4, 3/4, 4/4]
steps:
  - run: scripts/test.sh --shard ${{ matrix.shard }}
```

How files are weighed is `shard.balance` in `.testing.lua` ([CONFIG.md](CONFIG.md)): `size` (default: file bytes,
the same on every job), `count`, `hash` (a new file moves no other file), or `history` (measured durations; every
job must read the SAME durations, so point `shard.durations` at a JSON file of the repository, otherwise the local
history decides and jobs can disagree). The partition is longest-processing-time-first: heaviest file first, each
to the lightest bucket. Inside a shard the files keep the discovery order. A path argument narrows a shard further;
`--file`, `--filter` and `--tags` work on top of it.

A shard that gets no file (more shards than files) is exit code `0`, says so on stderr and prints no sentinel. A
sharded run is a partial run: no sentinel. The durations of every complete run are remembered next to the history
(`durations.json`), which is what `balance = "history"` reads.

### Result cache

```sh
testing . --cached          # reuse what is unchanged, store what ran green
testing . --no-cache        # never read or write the cache (wins over everything else)
testing . --cache-refresh   # run everything and store the green results, never read
testing . --cache-clear     # delete the cache of this project and exit
```

A spec file runs only when something it depends on changed: its own content, the files it `require`s
(transitively, also in lib.nvim and the other checkouts on the runtime path), the files it reads, the runner,
Neovim, the effective configuration (`.testing.lua`, the options that decide how a spec runs), the project's
`minit` and its harness. A file that reads the clock, starts a process or the network, or reads an
environment variable the configuration does not list, **has no key and always runs**; so does every file with a
discovery finding. What is cached is the case list of a file that passed cleanly (no retry, no guard finding of
severity `warn` or above, nothing in the effects ledger); a red file is never stored. [CACHE.md](CACHE.md) has the
rules, the limits and the format.

What a cached run looks like:

```
ok    TESTS/a_spec.lua (cached)
ok    TESTS/b_spec.lua
summary: 2 pass (2 case(s), 1 cached, not run) in 0.01 s

cache (use): 1 of 2 spec file(s) were not run: their results are from earlier green runs; 1 ran; not cacheable: 1 reads the clock. --no-cache runs everything.
```

It never reports more than a full run would:

* the verdict and the exit code are the full run's (a cached case is a `pass`, marked `cached = true` in the IR
  with the note `cached from <run id>`; `run.cache` of the IR says how many files and cases);
* a case selection (`--filter`, `--tags`, `--exclude-tags`, `--lf`) or `--strict` with discovery findings turns the
  cache off for that run, with a note on stderr, because a file that ran only some of its cases is not the file an
  entry describes; `--list` never uses it;
* nothing is stored after a run that `--maxfail` stopped;
* an entry is untrusted input: a damaged or foreign one is a miss, never a partial hit;
* `cache = { enabled = true }` in `.testing.lua` switches it on without the flag, **except in CI** (a default is
  never what decides there; the explicit `--cached` still works).

The cache lives under `stdpath("cache")/testing/<project>-<hash>/`, per user and per machine, bounded
(30 days, 64 MB, 5000 entries). `scripts/test.sh` uses a throwaway cache directory; set `TESTING_CACHE_HOME` to
keep one between invocations. A cached file is not executed, so `--profile` shows only what ran, and `--jobs`,
`--shard` and `--shuffle` work as usual (a shuffled run puts the seed into the key).

### Affected selection

```sh
testing . --changed                 # the working tree against HEAD, untracked files included
testing . --since origin/main       # the working tree against a revision
testing . --affected                # the last commit (HEAD~1); a developer tool
testing . --affected=HEAD~3
```

The changed files come from git (`git diff --name-only`, then the untracked files, as argument lists: no shell);
the specs that can reach them come from the module graph of documentation.nvim when its contract is on the
runtime path (`require("documentation.testing")`), else from the built-in heuristic (the `require` graph of
`lua/**`, project-local). It never selects fewer specs than needed: a changed file nobody can place (a README,
`.testing.lua`, a path git prints that is not trusted), a stale graph, or git failing **selects every spec**, with
the reason on stderr. A revision with a leading `-`, a range, whitespace or shell characters is refused (exit `2`)
before git sees it.

A selection is a **partial run**: it prints `partial run: 2 of 40 spec files (--changed; no sentinel)` and never
the sentinel, even when green. When nothing is affected the run says so, runs nothing and exits `0`: that is not a
green run (no sentinel), and `--changed` is a developer tool, not a CI gate: in CI an explicit selection runs but
warns, and `--affected` is never the default there. `--changed`, `--since` and `--affected` exclude each other, and
cannot be combined with `--watch`, which does its own selection. [CACHE.md](CACHE.md#affected-selection) has the rules.

### Worker pool

`--jobs n` (or `jobs` in `.testing.lua`) caps the child editors that run at once in an isolated run
(`--isolated file`/`case`, `script` files). The permits are a `lib.nvim.async.Semaphore` (`Semaphore:with`
releases them on every path), one supervisor loop polls the deadlines, and results are merged strictly in file
order: the IR, the printed output and the exit code are the same for `--jobs 1` and `--jobs 8`
(`TESTS/testing/pool_spec.lua` proves the order, and that never more than `n` children overlap). The default is
**1**; `--jobs auto` / `jobs = "auto"` is cores minus one. With `--pool-reuse` the children are warm pool members
(`--pool-size`) that are reset and verified between files. `--profile` reports how busy the pool was.

### Watch

`--watch` runs the specs once, then keeps running. After every change it waits for `watch.debounce_ms` (150) of
quiet and re-runs:

* the changed spec files;
* for a changed `.lua` file that is not a spec: the specs the affected-selection names
  (`testing.affected.select`, when that module exists), otherwise **every** spec, with a note: a library change
  never silently runs nothing;
* the files that failed in the last run, **first**.

```
watching TESTS, lua (fs events, debounce 150 ms). Ctrl-C quits.
watch: run 1 finished (exit 1, failing: TESTS/a_spec.lua). Waiting for changes (Ctrl-C quits).
watch: 1 change(s) (lua/x.lua) -> running 2 file(s)
watch: run 2 finished (exit 0). Waiting for changes (Ctrl-C quits).
```

The watched trees are the spec roots and `lua/`. Events come from `lib.nvim.fs.watch`; a change is decided by a
snapshot diff (path, mtime, size), so a burst of saves is one run with every changed file, and an event without a
content change runs nothing. If a watcher cannot be started (`ENOENT`, `ENOSPC` = inotify watches exhausted,
`EMFILE`) the watch **polls** every `watch.poll_ms` (1000) and says so; `--watch-poll` asks for that up front
(network drives, containers). On Linux libuv cannot watch a tree recursively, so there is one handle per
directory, refreshed after every run; on Windows and macOS one recursive handle watches each root. Closing a
handle is asynchronous in libuv (Windows keeps the directory until it ran), so the watcher closes the handles
first and lets the loop turn once before it returns.

Ctrl-C ends the watch cleanly: the handles are closed, running children are killed with their process trees
(`testing.child.kill_all`, which covers warm pool members), and the **exit code is the one of the last completed
run** (`0` when none finished). A run Ctrl-C cut short does not replace it. In-process runs forget the modules
that were not loaded before the first run (except `testing*`, `lib.nvim*`, `lib.lua*`), so an edit to a plugin
module is seen by the next run; child editors start fresh anyway. `--watch` cannot be combined with `--list`,
`--shard` or `--profile`.

### Profile

`--profile` costs a few clock reads and one pass over the cases; it never changes a verdict. The text report goes
to stderr; the same numbers are `run.profile` of the IR (`--json`), an additive field: `schema_version` stays 1.

* `phases`: milliseconds of `discovery`, `run` (everything between the end of discovery and the end of the run:
  selection, minit, the drivers), `report` (reporters, history, everything after) and `total`. `report` is in the
  text only: the IR was written before it ended. A phase nobody marked is absent, never zero.
* `files` / `cases`: the 50 slowest. A file's time is the sum of its cases unless the driver reports its wall time
  (`report.file_timings`: `wall_ms`, `spawn_ms`, `load_ms`, `run_ms`); `source` says which.
* `histogram`: cases per duration class (`<= 1, 5, 10, 50, 100, 500, 1000, 5000 ms`, then open).
* `spawn`: child editors started and what that cost, from the pool statistics and the per-file timings;
  `measured = false` when the driver reports neither.
* `pool`: jobs, members started, files that reused one, members discarded and the utilisation (busy time / jobs x
  run wall time; `approx` when the busy time is case time only, which leaves out the process overhead).

LuaJIT's sampling profiler (`jit.p`) is not part of this: `--profile` is the cheap, always-available view; a
line-level profile of one slow case is a separate tool.

## What a run does

1. Parse the arguments and load `<root>/.testing.lua` ([CONFIG.md](CONFIG.md)); warnings about its
   keys go to stderr.
2. Resolve the dependencies (all of them, so one run reports every missing one), then run the
   project's `minit` file (if it exists) in this editor, the way the old runners did.
3. Discover the specs below the spec roots (`TESTS/` by default), with no depth limit, in a
   deterministic order (byte-wise sorted path). A symlinked directory is reported and not entered; a
   spec in a legacy place (`docs/TESTS`, `tests`, `test`, `scripts`) is run and reported; a busted
   spec below `lua/` is reported, not run. A project without a single spec is exit code `2`.
4. Sniff the dialect of every file ([DIALECTS.md](DIALECTS.md)) and run it: the files that need
   isolation (`--isolated`, `.testing.lua` `isolated`: busted files by default, every `script`) each in
   a child editor of their own, the others in this editor, one process, like the old hand-written
   runners. The result is merged in file order, so it is the same for any `--jobs`.
5. Print the result, write the requested reports, record the run for `--lf`/`--ff`, exit
   ([EXIT-CODES.md](EXIT-CODES.md)).

The last line of a green run is the sentinel, and only a **complete** green run with no skipped case
prints it. A selection, `--maxfail` or a skip prints a distinct line instead ("partial run ...", "N
case(s) skipped ..."), so a script that greps for the sentinel cannot read a partial run as the
verdict.

If the project still has a `TESTS/run.lua` (the old runner of the fleet), its spec list sets the
order of those files and the last line it prints is the default sentinel. A spec listed there but
missing on disk is a failing case. The file is never executed. Without `run.lua` the order is the
discovery order (sorted by relative path): a project whose specs depend on the order of that list
needs it kept, or `isolated = "file"`; `testing migrate` warns when the list is not alphabetical.

Discovery compares directories by their real path, **case-folded on a case-insensitive file system**
(detected by a probe: the same directory under a swapped-case spelling is the same inode), so `TESTS/`
and `tests/` are one directory there (Windows, macOS, WSL `/mnt/*`) and a spec is never listed twice.
On a case-sensitive file system nothing is folded.

## Environment

| Variable | Effect |
| --- | --- |
| `$LIB_NVIM_DIR` | Explicit location of lib.nvim; if set but invalid the run fails (exit `3`). Every dependency has a `$<NAME>_DIR` ([CONFIG.md](CONFIG.md#dependencies)). |
| `TESTING_DEBUG=1` | Tracebacks for internal errors. |
| `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR_FORCE` | Colour of the terminal reporter. |
| `GITHUB_STEP_SUMMARY` | Target of the step summary of `--github`. |
