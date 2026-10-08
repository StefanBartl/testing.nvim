# Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|list|doctor|budget|conformance|surface|explain|stamp|verify|init] [<root>] [options]
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
| `surface` | The plugin's surface (keymaps, commands, autocmds, ...) and how much of it the specs exercised. Own arguments and exit codes too: `testing surface [<root>] [--from ir.json] [--threshold 0.8] [--baseline b.json [--require-signed-baseline]] [--json\|--markdown]`, see [SURFACE.md](SURFACE.md). A run is tracked with `surface = { track = true }` in `.testing.lua`: every case of the `--json` IR then carries `surface.hit`. |
| `explain` | Why a spec file is selected, taken from the cache, run or left out, and what its cache key is made of: `testing explain [<root>] <spec>... [--all] [--json] [--parts]`. Display only (changes nothing). Accepts the options of a run (`--config`, `--env-allow`, `--changed`, ...), because the key depends on them. See [Explain and audit](#explain-and-audit). |
| `stamp` | A run that writes the green stamp after a **complete** green run (verdict `green`: nothing selected away, nothing skipped, nothing stopped): `testing stamp [<root>] [--out <file>] [--note] [options of a run]`. Options that select part of the suite are refused (exit `2`); a run that is not green writes no stamp and exits `1`. See [Stamp and verify](#stamp-and-verify). |
| `verify` | Is the tree still the one a green stamp proved? Answers from the cache keys, runs no spec: `testing verify [<root>] [--stamp <file> \| --from-note] [--max-age 7d] [--allow-dirty] [--require-hmac] [--allow-unsigned] [--json]`. Exit `0` and the sentinel only for `verified` (every file proven). See [Stamp and verify](#stamp-and-verify). |
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
| `--cache-dir <dir>` | Base directory of the result cache (default `stdpath("cache")`; the environment variable `TESTING_CACHE_HOME` does the same, the flag wins). The project folder is below it; `cache = { project_key = ... }` in `.testing.lua` names that folder after a key instead of the checkout path. For a cache that travels between CI runners: [CI-CACHE.md](CI-CACHE.md). |
| `--cached`, `--no-cache`, `--cache-refresh`, `--cache-clear` | The result cache: a spec file whose inputs are byte-identical to an earlier green run does not run, and its cases are reported as cached. Off unless asked for; `--no-cache` always wins. See [Result cache](#result-cache). |
| `--cache-audit <0..1\|all>` | Run that share of the cache hits anyway and compare with the stored result: a difference is the finding `cache.stale_pass` and exit `1`; the measured stale-pass rate is on the cache line and in `run.cache` of the IR. Implies `--cached`; excludes `--cache-refresh`. See [Explain and audit](#explain-and-audit). |
| `--changed`, `--since <rev>`, `--affected[=<rev>]` | Only the specs the changes can reach (working tree against `HEAD`, against `<rev>`, or the last commit). A partial run: never a sentinel. See [Affected selection](#affected-selection). `--affected` takes its revision only as `--affected=<rev>`: a bare `--affected` never swallows the next argument. |
| `--consumers <dir>` | With one of the three above: also name the specs of the checkouts below `<dir>` (the projects that use this one) that the change reaches, as asked of documentation.nvim. A hint about other repositories, printed, never part of what runs here. Also `affected = { consumers = "<dir>" }` in `.testing.lua`. See [Consumers](#affected-selection). |

### Controlling the run

| Option | Meaning |
| --- | --- |
| `-x`, `--maxfail <n>` | Stop after the first / the `<n>`th failure. Cases that did not run are not in the report, and the run says so. |
| `--shuffle`, `--seed <n>` | Random order; the seed is printed so a failure can be reproduced. |
| `--order priority` | The files most likely to be red run first: what failed last time, what the working tree changed, the specs that `require` a changed module (nearest first), what has not run for 7 days or never, then the rest; inside a stage the file that took the least time first. It **orders and never filters**: the set of files is the one the other options selected, and the Result-IR stays in discovery order. Without history, git or a graph the discovery order is kept and a note says so. Excludes `--shuffle` (exit `2`); `--ff` is the special case of its first stage. `--list` shows `order <rank>  <file>  (<reason>)` before the cases of each file. |
| `--order slowest-first` | With `--jobs` of 2 or more and child editors: the children of the longest files (by their remembered duration) start first. Only the start changes, the results are merged in file order; see [Worker pool](#worker-pool). |
| `--retry-failed <n>`, `--allow-flaky` | Run a red case again up to `n` times (1 to 10). A case that passes on a retry is **flaky**: the run stays red, the case is marked and listed, and it is never cached. `--allow-flaky` counts it as green (still listed). See [Retry and flaky](#retry-and-flaky). |
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
| `--reporter <name>` | Terminal reporter (`term`, `github`, `junit`, `json`, `agent`). Without it: `TESTING_REPORTER`, then a coding-agent environment (`agent`), else `term`; see [Environment](#environment). |
| `--agent-budget <n>`, `--format <text\|jsonl>` | Only with the `agent` reporter (otherwise exit `2`): the character budget of the failure part (default 4000, at least 200; what does not fit is counted in a `more:` line) and the shape (`text`, or `jsonl`: one JSON object per line). |
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

### Explain and audit

```sh
testing explain . TESTS/x_spec.lua      # selected? hit, miss (what changed), or uncacheable (file, line, way out)?
testing explain . --all                 # hit rate and the reasons of the files that have no key, most frequent first
testing explain . x_spec --json         # the same as one JSON document (--parts adds the key lines to --all)
testing . --cached --cache-audit all    # re-run every cache hit and compare: the measured stale-pass rate
```

`testing explain` takes the spec as a path, a directory or a part of a file name, plus the options of a run, because
the key depends on them (`--changed` / `--since` / `--affected` add the selection: "left out by --changed"). It runs
nothing and writes nothing; exit `0`, `2` for a spec that matches nothing and for `--shuffle` without `--seed` (the seed of a shuffled run is part of its key, and a run without `--seed` draws a new one each time, so there is no key to explain: `testing explain . x_spec --shuffle --seed 7` explains the key of that run). `--cache-audit` re-runs the given share of
the hits (`0` to `1`, or `all`; a nightly CI job on the main branch is the intended use) and compares the cases and
statuses with the stored entry; a difference is `cache.stale_pass` (with the file, the first key lines and both
possible causes: an input the key cannot see, or a flaky spec), the entry is dropped, and the run exits `1`.
A spec whose key gave two different results is marked `nondeterministic` and not cached any more (explained by
`testing explain`). [CACHE.md](CACHE.md) has the rules.

### Stamp and verify

```sh
testing stamp .                          # run everything; after a COMPLETE green run write the stamp (state directory)
testing stamp . --out ci/stamp.json --note   # a chosen file, and a git note on the tree (refs/notes/testing)
testing verify .                         # no spec runs: is the tree still the stamped one?
testing verify . --json                  # one document (testing-verify/1)
testing verify . --stamp ci/stamp.json --max-age 3d
```

`stamp` is a run (every option of a run applies, because the cache keys depend on them). When its verdict is `green` it
writes, for every spec file, the cache key or the reason there is none, plus runner digest, Neovim version, OS and
configuration digest, the commit and the tree, all taken before the first spec runs: an input that changed while the
specs ran (an editor that saved, a formatter, a spec that rewrites a source) writes nothing and exits `1` as well. Any
other verdict writes nothing and exits `1`: you asked for a stamp and did not get one. The first line of the agent
report and the `verdict:` line of the terminal report say so before anything else: `RED ... exit 1` and `verdict:
red` with `no case failed; stamp not written` (the reason is on stderr), never `GREEN` or `exit 0` for a run that exits
`1` ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#agent)). The stamp is only attempted when every report file of the run was
written: a failed `--json`, `--junit` or `--github` file is exit `3` and no stamp. `--changed`, `--since`, `--affected`, `--filter`, `--file`, `--tags`, `--exclude-tags`, `--lf`,
`--shard`, `--maxfail`, `--list`, `--watch`, `--shuffle` and path arguments are refused with exit `2`.

`verify` recomputes the keys (roughly editor start plus the keys: a few tenths of a second, not milliseconds) after the
`minit` of the project, as a run does, and says exactly one of

| Answer | Meaning | Exit |
| --- | --- | --- |
| `verified` | every file of the stamp has the same key now, the stamp is young enough, the tree is clean, the stamp is trusted | `0`, and the sentinel as last line |
| `partial` | nothing a key can see changed, but some files have no key (clock, process, ...): they are not proven. The command to run them is printed | `1`, never the sentinel |
| `changed` | a file has another key, is gone, or is new; for a changed file the explanation of `testing explain` (which dependency, which environment name) when the cache still holds the entry of the stamped key | `1` |
| `rejected` | runner, Neovim, OS/architecture or configuration differ from the stamp (the cause is named), or the `minit` of the project failed (the keys cannot be computed the way a run computes them) | `1` |
| `expired` | older than `--max-age` (default `7d`; `s`, `m`, `h`, `d`) | `1` |
| `dirty` | `git status` is not empty: what is checked is not the committed tree (`--allow-dirty` overrules, explicitly) | `1` |
| `untrusted` | a local stamp in CI, a CI stamp that was not written on a trusted ref, a missing or wrong HMAC | `1` |
| `invalid`, `no-stamp` | the file is not a usable stamp (size, JSON, schema, digest, time), or there is none | `1` |

A partial proof is never green. `2` is a usage error (an unknown flag, a bad duration, a secret under 16 characters), `3`
an internal failure. `--json` prints the document instead of lines (no sentinel in it). The default stamp file is
`stamp.json` beside `runs.jsonl` in the state directory of the project, not in the checkout (a file in the tree would
make it dirty). The rules and what the stamp can and cannot prove: [CACHE.md](CACHE.md#stamp).

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

**Consumers.** A change in a library reaches the specs of the projects that use it, which are in other checkouts.
`--consumers <dir>` (or `affected = { consumers = "<dir>" }` in `.testing.lua`; the flag wins, a relative flag is
relative to the working directory, a relative key to the project root) names the directory that holds those
checkouts and asks documentation.nvim, in the same call that answers the selection, which specs of each of them the
change reaches (`affected_specs`, key `consumers`; contract: `documentation.nvim/docs/testing-contract.md`, "Other
repositories"). **The caller names the directory**: this runner does not know where your repositories are. The
answer is a hint that is only added to: it is printed (`--list`: on stdout; otherwise as `testing: note:` lines) and
it never makes the selection of this project smaller or bigger.

```
testing . --since origin/main --consumers .. --list
cross-repo: cascade.nvim: 19 spec(s) reach the change: TESTS/bindings_spec.lua, ...; its own module map is stale (run its full suite)
cross-repo: gitsuite.nvim: not measured (no committed module map): run the full suite of this repository
cross-repo: a consumer that is not below E:/repos is invisible here; a consumer that is not measured is not unaffected
```

A consumer that was **not measured** (no committed module map, a map that cannot be read) is listed with its reason
and the sentence "run the full suite of this repository": not measured is not "not affected". A consumer that is not
below the directory at all is invisible, and the last line says so. Specs of a consumer are relative to the
consumer's own root. Without documentation.nvim, with one that does not answer `cross_repo` (an older contract), with
an answer of another contract `version`, or with a malformed one (an absolute or `..` path, a control character, an
oversized list: the whole `cross_repo` is dropped) nothing else changes and a `cross-repo:` line says that no
consumer was measured. A change without a changed module (only a spec or a document) reaches no consumer, and when
git fails the consumers are not asked: both are said.

### Order

`--order priority` decides which spec file runs first; it never decides which files run (heuristics order,
only proofs such as the [cache](CACHE.md) skip). The rank of a file:

1. it failed last time (`runs.jsonl`, the same memory as `--lf`/`--ff`),
2. it was changed itself (git: working tree against `HEAD`, untracked files),
3. it reaches a changed file through `require`, nearest first (distance 1: the spec requires the changed module),
4. it has not run for 7 days, or never (`order.json`),
5. the rest.

Inside a rank the file that took the least time on its last execution comes first, a file without a known duration
after those, then the discovery order. Everything it needs is optional: with no history, no git or no usable graph
(a git failure selects "everything" and carries no distance) the discovery order is kept and a `testing: note: order:`
line on stderr says what was missing. The Result-IR and every report stay in discovery order, whatever order the
files ran in, so the report does not depend on it. `--list` shows `order <rank>  <file>  (<reason>)` before the cases
of each file. Cost: one `git` round and the affected scan (the same analysis index `--changed` uses).

`order.json` (beside `runs.jsonl`, `stdpath("state")/testing/<project>/`) remembers when each file last ran and how
long it took; `last_green.json` remembers the last full green run (see [the verdict](OUTPUT-FORMATS.md#the-verdict)).
Both are bounded, read as untrusted input, written atomically, and a failure to read or write is a note.

**Parallel runs of one project.** The state files beside `runs.jsonl` (`runs.jsonl`, `order.json`, `timings.json`,
`durations.json`, `last_green.json`, and `keys.json`, the memory of which cache key gave which result) are read, changed
and written back whole, so two runs at the same time (a CI matrix
on one machine, `watch` next to a manual run) must not overwrite each other. Every update takes a short lock
(`<file>.lock`, created exclusively), reads the file AGAIN inside the lock and merges into what it finds: the entries
of both runs survive (for `keys.json` that is what keeps a key that gave `pass` in one run and `fail` in the other
visible as a flip), and `last_green.json` keeps the record of the run that was green later (a record dated more than ten
minutes ahead of the clock was written by a wrong clock and does not count as later). A run that cannot get the lock
within 3 s prints a note (`... is locked by another run: not updated`) and leaves the file alone; a state directory that
cannot be written at all is reported as it is (`cannot lock <file>: EACCES ...`) after a second (long enough for a lock
whose delete a virus scanner still holds up on a busy Windows machine), not after the full wait; the state is a convenience, never part of the verdict, so the exit code does not change. A lock older than 10 s was left by a run that
died and is taken over.

### Retry and flaky

```sh
testing . --retry-failed 2            # a red case runs again, at most twice
testing . --retry-failed 2 --allow-flaky
```

`--retry-failed <n>` (1 to 10) repeats **only the files that have a red case** (`fail` or `error`; a `timeout` and a
`crash` are not repeated, they already cost the whole limit and are verdicts about the process, and `xpass` is a
verdict about the expectation). A case that passes on a retry is **flaky**, and flaky is never green by itself:

* the case keeps its status `fail`, gets `flaky = true`, `retries = <the retry that passed>` and a note; the run is
  **red** (exit `1`, no sentinel);
* the end of the output lists them: `flaky: 1 case(s) failed and then passed on a retry: the run stays RED`;
* a case that fails on every retry is plainly red (`retries = n`, the line `retry: ... failed on all n retries as
  well`); a case that the output of a retry does not contain at all (the file stopped early, the case was renamed)
  did not run again: it stays red, the line says `missing from the output of a retry`, and it is never reported as
  "failed on all retries";
* a file with a flaky case is **never stored in the result cache** (the cache refuses a case with `retries > 0`, and
  the run reports the file as flaky to it): a flaky result is not a proof.

`--allow-flaky` (needs `--retry-failed`) is the explicit choice to count a case that passed on a retry as green: the
passing result replaces the red one (`status = pass`, `flaky = true`, `retries = k`, a note that holds the first
failure), the exit code is recounted (`--strict` still makes a skipped case red), and the list of flaky cases is
printed anyway, never silently. They are not cached either. It never turns a case that failed on every retry green.
A run that accepted a flaky case is **`green-partial`**, never `green`: the reason `n flaky case(s) accepted
(--allow-flaky)` is part of the verdict, there is no sentinel (the agent reporter says `PARTIAL`), and the run is not
recorded as the last green run. So `green` stays exactly the run that prints the sentinel. The same holds for
`--maxfail`: a stop that left files unrun keeps the verdict partial even when a retry turned the failure green.

The retry runs the whole file again (the driver of the first run: this editor or a child editor) and looks only at
the cases that were red; what the rest of the file did the first time stands. The `--maxfail` threshold does not apply
to the rerun: a case of the file that failed this time (and not before) must not stop it before the case it is there
for has run again (that case would be `missing from the output of a retry`, not found flaky). `--retry-failed` excludes `--list` and
`--watch` (exit `2`). A quarantine (a known flaky case that is set aside until a date) is not part of this flag.

### Worker pool

`--jobs n` (or `jobs` in `.testing.lua`) caps the child editors that run at once in an isolated run
(`--isolated file`/`case`, `script` files). The permits are a `lib.nvim.async.Semaphore` (`Semaphore:with`
releases them on every path), one supervisor loop polls the deadlines, and results are merged strictly in file
order: the IR, the printed output and the exit code are the same for `--jobs 1` and `--jobs 8`
(`TESTS/testing/pool_spec.lua` proves the order, and that never more than `n` children overlap). The default is
**1**; `--jobs auto` / `jobs = "auto"` is cores minus one. With `--pool-reuse` the children are warm pool members
(`--pool-size`) that are reset and verified between files. `--profile` reports how busy the pool was.

`--order slowest-first` (with `--jobs` of 2 or more and child editors) starts the children of the **longest files
first**, by the durations the runner remembers (`durations.json` beside the history, the file `--shard` reads;
`shard.durations` in `.testing.lua` names a file of the repository instead): a file of 10 s that starts last adds
10 s to the end of the run, one that starts first overlaps with the rest. A file without a remembered duration
starts after the weighted ones, in file order; without any duration the file order is kept and a note says so. Only
the **start** changes: the results are still merged in file order, so the IR, the printed output, `--maxfail` and
the exit code are the same as without it. It orders and never filters, and excludes `--shuffle`. With `--jobs 1`, or
without child editors, there is nothing to order and a note says so.

**Slow files.** Every complete run adds the duration of each file (not a cached one) to `timings.json` beside the
history: the last 9 runs per file, bounded, read as untrusted input, written atomically. A file that takes more than
three times the median of at least three earlier runs, and at least 100 ms more than that median, is a warning on
stderr (`testing: warning: slower than usual: TESTS/x_spec.lua took 4.2 s, 3.2x its median of 1.3 s over 9 run(s)`):
never a failure, the machine may be busy.

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
run** (`3` when none finished: Ctrl-C in the first run is an aborted run, never a green exit). A run Ctrl-C cut short
does not replace it. A file that changes during three runs in a row (a spec that writes a Lua file below a watched
root) is taken for a product of the run, not an edit: it is ignored from then on and the status line names it, so the
watcher does not re-trigger itself for ever (restart `--watch` to watch it again). In-process runs forget the modules
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

The last line of a green run is the sentinel, and only the verdict `green` prints it: a **complete** run with no
skipped case, no `--maxfail` stop and no case that `--allow-flaky` accepted. A selection, `--maxfail` or a skip prints a distinct line instead ("partial run ...", "N
case(s) skipped ..."), so a script that greps for the sentinel cannot read a partial run as the
verdict. The same distinction is a line of every reporter, the **verdict** (`green`, `green-partial`, `red`, with
"n from cache, m ran, k skipped on purpose"), and `green` is exactly the run that prints the sentinel
([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#the-verdict)); the exit codes do not change. With the `agent` reporter the
first line of the output is that verdict and no sentinel is printed.

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
| `TESTING_REPORTER=<name>` | The stdout reporter when `--reporter` is not given (an unknown name is exit `2`). |
| `TESTING_AGENT=1\|0` | `1` selects the `agent` reporter, `0` switches the detection below off. |
| `CLAUDECODE=1`, `AI_AGENT=<name>` | A coding agent runs this: the `agent` reporter is selected when nothing else chose one. Both variables were **observed** in a Claude Code session (2026-10-07), no vendor page promises them; the list lives in `testing.report.agent.AGENT_ENV` and an agent that is not on it sets `TESTING_AGENT=1`. Only `scripts/testing.lua` reads these variables and hands them down: the library itself never looks at the environment, so a spec that calls `testing.cli.main` is not switched by where it runs. |
| `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR_FORCE` | Colour of the terminal reporter. |
| `GITHUB_STEP_SUMMARY` | Target of the step summary of `--github`. |
