# Performance

What a run costs, how it is measured, and what the budgets of the concept (D.7) say against what this
machine does. The numbers are measurements, not promises: where a budget is missed it says so, and the
target is not adjusted to fit.

## Method

* **Harness** (`lua/testing/budget/harness.lua`): `vim.uv.hrtime` only, no dependency. One untimed warm-up
  call, then N timed calls (5; 3 for a case that starts a process; `--runs` changes it). The **median** is the
  number that counts: it ignores one antivirus scan or one GC pause. Minimum and maximum are stored so that a
  noisy run is visible. A sample is wall time, what a user waits for.
* **Check** (`testing budget`): a case fails when `median > baseline x factor` **and** `median - baseline > 1 ms`.
  `factor` is `budget.factor` (default 2.0). The 1 ms slack keeps a 0.3 ms case from failing at 0.7 ms: below a
  millisecond the clock, the GC and the scheduler decide. Exit code `1` on a regression, `2` without a baseline,
  `3` when a case cannot be measured.
* **Baseline**: `TESTS/bench/baseline.json`, written by `testing budget --update`, with the machine, the date and
  the method. It is only comparable to measurements of the **same machine**; the check says so when the CPU or
  the OS differs. Run it as a manual or nightly job, never as a blocking merge check (runner load makes it flaky
  by nature).

```sh
T="nvim -n -i NONE --headless -u NONE -l scripts/testing.lua"
$T budget .                  # check against TESTS/bench/baseline.json
$T budget . --update         # measure again and rewrite the baseline
$T budget . --filter child   # only the child editor cases
```

(`scripts/test.sh` cannot run it: it puts the root first, and a subcommand has to be the first argument.)

## The cases

| Case | What is timed |
| --- | --- |
| `doctor_startup` | `nvim -l scripts/testing.lua doctor` as a process: editor start to exit |
| `discover_100` | `testing.discover` over 100 spec files in 10 directories |
| `ir_encode_10k` | `testing.core.result.encode` of an IR with 10 000 cases |
| `history_append` | `testing.history.record` into a history that already holds 20 runs of 1 000 cases |
| `cache_hash_500` | read and `vim.fn.sha256` of 500 files of 2 KB: the work of a cache key, **without** the cache module's stat pre-check (which exists to avoid exactly this) |
| `child_spawn_cold` | `testing.rpc.spawn`: a new embedded editor to its first answer (the kill is not timed) |
| `child_kill` | `child.kill()`: ending an embedded editor with its whole process tree |
| `child_spawn_warm` | one call into an editor that is already running: what a pooled file saves compared with `child_spawn_cold` |

`child_spawn_cold` cannot be OS-cold: after the first start the executable and its libraries are in the file
cache. It is the cost of a start with a warm file cache **including** whatever the platform adds to every
process start (on Windows the antivirus scan).

## Measured on this machine

12th Gen Intel(R) Core(TM) i5-12400F, 12 threads, 48 GB, Windows_NT 10.0.26200 (x86_64), Neovim 0.12.2. Date of the measurement: 2026-10-06.

Baseline of `2026-10-06` (median of 9 runs after one warm-up; `TESTS/bench/baseline.json`):

| Case | Median | Min | Max |
| --- | ---: | ---: | ---: |
| `doctor_startup` | 105.3 ms | 100.2 ms | 130.9 ms |
| `discover_100` | 42.6 ms | 36.7 ms | 47.0 ms |
| `ir_encode_10k` | 174.7 ms | 162.9 ms | 188.8 ms |
| `history_append` | 8.11 ms | 3.60 ms | 11.1 ms |
| `cache_hash_500` | 24.4 ms | 23.5 ms | 28.1 ms |
| `cache_key_100` | 71.1 ms | 70.2 ms | 153.4 ms |
| `child_spawn_cold` | 121.7 ms | 117.8 ms | 135.1 ms |
| `child_kill` | 1.74 s | 1.64 s | 1.77 s |
| `child_spawn_warm` | 0.12 ms | 0.10 ms | 0.20 ms |

`cache_key_100` was added later (median of 5 runs, the review of the cache key). See finding 5 for the conditions of this measurement. The baseline file is the machine-readable form of this table.

## The D.7 budgets

| Run | Target (D.7) | Measured here | Verdict |
| --- | --- | --- | --- |
| lib.nvim, in-process | < 3 s | 137.6 s (87 files; CPU shared with other runs) | **missed** |
| lib.nvim, `--isolated file --jobs 8` | < 15 s | 39.7 s (same machine state) | **missed** |
| incremental (`--changed`, `--cached`) after one spec file changed | < 1 s median | lib.nvim, one spec edited: 1.14 - 1.52 s median (1 of 87 selected). The fixed parts (editor, discovery, git, key) are about 0.9 s here: see "Incremental run" | **missed** (by 0.15 - 0.5 s) |
| incremental after one module change | < 1 s median | `--changed` after a change of `core/result.lua`: 86 of 118 files (what depends on it), 193 s; lib.nvim, a leaf module: 62 of 87 files, 67 - 83 s | the selection is a safe superset; the budget is not reachable (see "Incremental run") |
| conformance suite per plugin | < 2 s | `testing conformance`, wall clock with the editor start, warm file cache: runtime-analysis.nvim 0.95 - 1.04 s, documentation.nvim 1.8 s, lib.nvim (300 modules) 2.7 - 2.9 s; the very first run after a long idle was 6.1 s | met except for lib.nvim |
| one Tier-1 feature test in the warm pool | 50 - 200 ms | 106 ms per trivial file at `--jobs 1`, 249 ms at `--jobs 4` (finding 3) | met at `--jobs 1`, **missed at `--jobs 4`** |
| fleet, 35 plugins x 30 features | 2 - 3 min | needs M6 | open |

The lib.nvim numbers are single runs of the whole suite (`cd lib.nvim && testing .` and `testing . --isolated
file --jobs 8`), 87 spec files. One spec fails and one errors in both modes on this machine (the same counts in
both; they are lib.nvim's, not part of this measurement). The time is
dominated by a handful of files that spawn `git` or `curl`: `git_sync_spec.lua` 16.6 s, `git_status_spec.lua`
11.5 s, `git_show_spec.lua` 9.1 s, `curl_spec.lua` 7.5 s, `git_spec.lua` 6.8 s of the in-process run, which is
more than the whole 3 s budget five times over. On Windows every process start pays the antivirus scan, and
those specs start many. So the budget is not missable by the runner: it is **not reachable on this
machine** without changing what those specs do (fewer, bigger git fixtures, or a fake `git` for the parts that
do not test git). That is a finding for the budget task, not an adjustment of the number. The parallel run is
3.5 times faster than the serial one and still 2.6 times over its budget, for the same reason.

## Cache and affected selection

Windows 11, 12 threads, Neovim 0.12.2, 2026-10-06. Every number is one run of the named command, wall clock including
the editor start; "cold" is an empty cache directory, "warm" the second run. These numbers replace the ones that were
measured before the review of the cache key: that key missed hidden inputs (a module that reads a file, a path outside
the project, the spec files a lint spec reads, a changed mtime that was set back) and its hit rates were too good to
be true. The key is stricter now, and the table says what that costs.

| Suite | Files | `--no-cache` | `--cached`, cold | `--cached`, warm | Files from the cache |
| --- | ---: | ---: | ---: | ---: | ---: |
| markdown.nvim | 47 | 18.0 s | 23.7 s (+32 %) | 12.3 s (-32 %) | 27 |
| ui.nvim | 65 | 40.0 s | 42.1 s (+5 %) | 28.1 s (-30 %) | 29 |
| sandbox.nvim | 38 | 23.7 s | 28.2 s (+19 %) | 19.8 s (-16 %) | 16 |
| images.nvim | 35 | 10.5 s | 12.8 s (+22 %) | 10.4 s (-1 %) | 3 |
| casedesk.nvim | 95 | 81.6 s | 115.1 s (+41 %, two files flaked) | 82.9 s (+2 %) | 7 |
| lib.nvim | 87 | 110.0 s | 111.2 s (+1 %) | 101.0 s (-8 %) | 10 |

lib.nvim run through `testing . --first-run --rtp <runtime-analysis.nvim>` (the way CI runs it): 87 of 87 pass in 129 s.

What this says, plainly:

* The cache pays where a suite is made of many small, pure specs: markdown.nvim and ui.nvim are a third faster warm.
  Where most files are kept out of it, it does not, and `testing run --cached` prints the reason per file (`not
  cacheable: ...`), so the list of what to change is in the output. images.nvim: 23 of 35 files name an ImageMagick
  install path outside the project that exists on this machine (a spec that reads the installed tools); casedesk.nvim:
  64 of 95 files name `C:/repos`, a place that exists here; lib.nvim: 30 files run in this editor and a project module
  reads the environment by a computed name.
* Cold costs more than it did: the key now follows every project module a spec loads (files it reads, the data next to
  it, the environment it reads) and takes the whole project into the key for a spec that loads code by `:runtime`. The
  cold overhead is the first hashing of the closure; the stat pre-check (size, mtime, ctime, inode) makes every later
  key cheap.
* Keys: `testing.cache.key` of 100 spec files whose closures hold 8 modules each takes about 70 ms with a warm index
  (`testing budget`, case `cache_key_100`); the closure of lib.nvim's 87 specs takes 230 ms warm. Within one run a file
  is hashed, analysed and stat-ed once, instead of once per spec (the review measured 110 - 160 ms per spec and 8.3 s for
  118 specs before). The Neovim part of the key (version, API level, OS, architecture) is made once per process: it
  cost about 1.8 ms per key (`vim.version()` and `vim.fn.api_info()`), which the budget case does not show because it
  fixes `ctx.nvim` (measured with the real version, 100 specs with a closure of one module each, warm index, best of
  5, Windows 11, Neovim 0.12.2, 2026-10-07: 218 ms before, 41 ms after). The digests of the runtime directories of the
  project root (`ftplugin/`, `queries/`, ...) are made once per run, like every other directory digest.
* A file made to keep the scanner busy costs what any other file costs. The header directives (`-- @cache ...`,
  `-- @cache-allow`, `-- @cache-env`, `-- @cache-inputs`, `-- @require-wrapper`) used to be read with `(.-)%s*$`, which is
  quadratic in the blanks of a line (a directive and 40 000 blanks took 2.6 s for all five, 100 000 took 22 s for one;
  at the size the hash index allows, hours, with no spec run). They read the rest of the line now (linear), and a header
  line is read up to 16384 bytes. The same shape is gone from the regex fallback of the spec discovery and from the CI
  migration (`TESTS/testing/scan_hostile_line_spec.lua`: 60 000 blanks, a quarter of a second as the limit, about a
  millisecond measured).
* Redaction is linear in the length of a token. The patterns of `core/ledger.lua` (`name: value`, `name=value`, URL
  user info) and of `core/result.lua` (e-mail shapes, `Users/<name>`) used to be re-scanned from every position of a long
  run without a separator (quadratic: 20 000 hex digits in one argument took 17 s per pass, and a spawn goes through
  several passes). Each starts at a frontier or at a literal now (`TESTS/testing/guard_ledger_argv_spec.lua`,
  `TESTS/testing/core_result_redact_spec.lua`: 60 000 bytes, a second and a half as the limit, tens of milliseconds
  measured). The path matchers of the ledger redactor (one `fs_realpath` per root) are built once per redactor, not for
  every text.
* A hit rate counts only what is sound. The earlier version of this section reported 41 - 83 % on four of these
  suites; stale passes found in the review (a module that reads a file next to it, a `package.path` that points outside
  the spec root, `:runtime`, a path above the project, an mtime put back with `touch -r`, a lint spec that reads the
  other specs) were in that number.

The affected selection, on the last 20 commits of two repositories (the checkout of each commit, `--affected --list`
with the built-in heuristic, no module graph):

| Repository | Specs | Selected, mean | Everything | Nothing | Why everything |
| --- | ---: | ---: | ---: | ---: | --- |
| lib.nvim | 87 | 60 (70 %), 61 - 63 for a change of one leaf module, 2 for a commit that only touched two specs | 1 of 20 | 0 | one commit whose five changed files reach every spec |
| documentation.nvim | 107 | 67 (64 %) | 9 of 20 | 7 of 20 (only CI files changed) | `standalone/*.lua` and `scripts/*.lua` are not a module, a spec or a document: 7 commits; two commits whose 14 changed files reach every spec |

The selection is a superset, never a subset: a change of a document selects the specs that name it (before: everything),
a module that lists directories or loads files selects the specs that require it, a helper below a spec directory
selects every spec below the topmost directory that holds specs. The price is precision: a one-line change of a leaf
module of lib.nvim selects 61 of 87 specs, because lib.nvim loads its modules by computed names and a computed
`require` is an edge to every module below the prefix. An imprecise selection is the safe error.

### Incremental run: the D.7 budget "under 1 s median" (measured 2026-10-07)

Protocol (`scripts/bench-incremental.sh`, a manual tool, never a CI step): a copy of lib.nvim (87 spec files, 300
modules) with a throwaway cache; one untimed run builds the indexes; then per timed run one new comment line is appended
to one file, `testing . --first-run --changed --cached` is timed (wall clock, editor start included) and the file is
restored; median of 5 - 7 runs, run twice.

| One file edited | Selected | Median | Min - max |
| --- | ---: | ---: | ---: |
| `TESTS/which_key_spec.lua` (a spec that runs 0.2 s) | 1 of 87 | 1.14 s | 1.06 - 2.2 s |
| `TESTS/cache_spec.lua` (a spec that runs 0.56 s) | 1 of 87 | 1.26 / 1.30 s | 1.23 - 2.4 s |
| `TESTS/async_spec.lua` | 1 of 87 | 1.52 s | 1.51 - 1.56 s |
| `lua/lib/lua/numeral/roman.lua` (a leaf module), `--changed` | 62 of 87 | 67.5 s (one run) | |
| the same, `--affected` (HEAD~1) | 62 of 87 | 80.1 s / 83.0 s | |

**The budget is missed, and the cause is not one slow step.** Where the 1.26 s of the `cache_spec.lua` case go: editor start
0.15 s, discovery of 87 spec files 0.23 s, the selection (git and the `require` scan with a warm index) 0.13 s, the key
of the selected spec 0.38 s, the spec itself 0.56 s. Even with an empty spec the sum of the fixed parts is about 0.9 s
on this machine (Windows: every `git` is a process start, and so is the editor). Before the git commands of the
selection ran at once (`testing.affected.git.run_parallel`: five process starts, one wait) the same case took
1.47 s. What is left to win is small: the key of one spec (0.38 s: a closure of its modules, hashed with a warm
index), and the discovery that reads every spec header.

For a **module** change the budget is out of reach by a factor of 60 - 80, and the reasons are in the selection and the
cache, not in the runner:

* 62 of 87 specs are selected for *any* module of lib.nvim, even a leaf like `lib.lua.numeral.roman`. The earlier
  reading of this table blamed `lib.lua.lazy` (a computed `require` is an edge to every module) and estimated 46 of 87
  without it. **That estimate does not hold today** (re-measured 2026-10-07, see "The require wrapper" below): the
  reasons of the 62 are, counted per spec, 30 specs that reach a module which lists directories in its own
  surroundings (`lib.nvim.bindings.autocmd.docs`: any change reaches it), 15 specs that list directories or load files
  themselves, 8 that reach the parent module `lib` (a package whose `init` does `require(require("lib.config").strategy_module())`),
  6 that start a process, 2 that name the changed file, and 1 with a computed `require`.
* Only 10 of the 87 files can be cached (30 files: a module reads the environment by a computed name; 28 read the
  clock; 9 start a process), so a selected file runs again even when its key matches.

**The require wrapper (M5 lever, implemented, measured, no gain on lib.nvim).** `testing.affected.wrapped` reads the
call sites of a module that declares `-- @require-wrapper require module fn` (see [CACHE.md](CACHE.md#affected-selection)):
`lazy.require("lib.x")` with a literal is an edge to `lib.x`, the wrapper is no longer a dependency on everything, and a
file that uses the wrapper in any way the scanner cannot follow stays a dependency on everything. It is sound by
construction (the spec `affected_wrapped_spec.lua` has the uses that must stay "everything": passed on, computed or
concatenated name, undeclared member, `pcall(require, ...)`, alias bound twice, a prefix that matches the wrapper) and
costs nothing where no module declares it. On a copy of lib.nvim with the declaration added to `lib.lua.lazy`
(one comment line): `--changed --list` after a change of `lua/lib/lua/numeral/roman.lua` still selects **62 of 87**, before
and after. Switching every computed-`require` module of lib.nvim off in an experiment (`lib`, `lib.health`,
`lib.nvim.require`, `lib.strategies.*`, ...) also leaves 62: the dynamic modules are not what holds the selection.
What holds it are the four reasons above, none of which a wrapper declaration touches. The honest result: the lever is
in, the budget for a module change is not closer. `scripts/bench-incremental.sh` on that copy (`lua/lib/lua/numeral/roman.lua`, `--changed --cached`, 3 runs, whole suite
of the 62 files, the machine busy with other work during the run): 92.9 - 94.1 s, median 93.9 s (exit 1: the lib.nvim
specs that fail on this machine), against 67.5 - 83.0 s measured before on a quiet machine: the same 62 files, so the
difference is load, not the change. The spec edit (`TESTS/cache_spec.lua`, 5 runs, same busy machine): 2.0 - 2.3 s
median 2.05 s (first run 5.3 s), 1 of 87 selected; the 1.26 s above were measured on a quiet machine. The next levers are the ones in the list (a module that lists
directories in its own surroundings seeds every change; a package whose `init` computes its exports makes its parent a
seed of every child), and each of them needs the same test as this one: a proof that nothing is dropped.

So on lib.nvim the incremental loop is "about 1.3 s after editing a spec" and "one to two minutes after editing a
module". The budget stays missed; it is not adjusted.

## The worker pool

What the task text asks of `--jobs`, checked against the code and the specs:

| Statement | Status |
| --- | --- |
| permits are a `lib.nvim.async.Semaphore` | yes: `testing.run.isolated` makes `async.Semaphore.new(o.jobs)` and runs every child inside `Semaphore:with`, which releases on every path; a lib.nvim without `Semaphore:with` is refused with a message that names the stale copy |
| never more than `n` children at once | yes: `pool_spec.lua` measures the peak overlap (`jobs = 1`: 1, `jobs = 3`: at most 3) |
| deterministic order | yes: results are merged strictly in file order, so the IR, the printed output and the exit code are the same for any `--jobs` (`pool_spec.lua`: the last file finishes first and is still merged last) |
| a failing child does not stop the others; `--maxfail` kills the running ones and drops their results | yes (`pool_spec.lua`) |
| warm members that are reset and verified (`--pool-reuse`) | yes, M2 |
| `--shard i/n` for CI matrices | **added**: `testing.run.shard`, see [CLI.md](CLI.md#sharding) |
| default `--jobs` = cores minus one (D.7, task text) | **not the default**: the default stays 1, because changing it changes the behaviour of every run. What was missing was a way to ask for it: `--jobs auto` / `jobs = "auto"` is cores minus one. Making it the default is a decision for the author |
| utilisation of the pool is visible | **added**: `--profile` (`pool.utilisation`, exact when the driver reports per-file wall time, otherwise marked approximate) |

Not done, and said so: the drivers do not yet report per-file `spawn_ms` / `load_ms` / `run_ms`
(`report.file_timings`); `--profile` uses them when they are there and falls back to the sum of the case
times, which leaves out the process overhead. `--durations` and the durations of the history (`durations.json`)
exist; LuaJIT's `jit.p` per case does not.

## Findings

1. **Ending a child editor is the most expensive thing the runner does to a process**: `child_kill` is 1.7 s
   per editor on Windows, 14 times a start (`child_spawn_cold`, 0.12 s) and 15 000 times a call into a running one
   (`child_spawn_warm`, 0.12 ms). The tree kill first asks the process table (a PowerShell start) for the
   descendants and then runs `taskkill /T /F`. A warm pool pays it once per member at shutdown and once per member
   that is discarded; a run with several timeouts pays it per timeout. The numbers belong to
   `testing.child.kill_tree`; a task for its owner: ask for the descendants with something cheaper than a
   PowerShell start (or only when the root kill leaves something behind). What came after `/T` is gone since: a
   `taskkill` start for every descendant of the snapshot (a second each, one after the other, even when `/T` had ended
   it) became a check whether the process still exists and, for a survivor only, one call for all of them (measured
   on a loaded Windows 11 machine, a child with one helper: 5.0 - 5.4 s before, 3.2 s after).
2. **The two lib.nvim budgets are not reachable on this machine** (table above), because five spec files that
   start `git` and `curl` take more time than the whole budget. Either the budget is adjusted for Windows, or
   those specs change (fewer larger git fixtures, a fake `git` where git is not the subject). Not adjusted here.
3. **The warm pool is slower than a child per file when files are small and `--jobs` is more than 1.** 30 trivial
   spec files (`return function(H) H.ok(true, 'x') end`), whole run including the editor that runs the runner,
   median of 5:

   | Mode | Wall time | Per file |
   | --- | ---: | ---: |
   | in this editor (`--isolated none`) | 0.43 s | 14 ms |
   | a child per file, `--jobs 1` | 4.64 s | 155 ms |
   | warm pool, `--jobs 1` | 3.17 s | 106 ms |
   | a child per file, `--jobs 4` | 1.72 s | 57 ms |
   | warm pool, `--jobs 4` | 7.48 s | 249 ms |

   The pool wins at `--jobs 1` (a third less) and loses badly at `--jobs 4`. `--profile` says where the time is
   not: starting the four members is 0.67 s summed and verifying the files 0.22 s summed, of a run phase of 7.7 s.
   One call into a running member is 0.12 ms (`child_spawn_warm`). So about 250 ms per file go into the
   orchestration around a file, and it grows with the number of members. The driver does not report per-file
   `spawn_ms` / `load_ms` / `run_ms` yet (`report.file_timings`, see "Not done" above), which is exactly what would
   say which step it is. A finding for the pool's owner; the budget of 50 - 200 ms per Tier-1 test is met at
   `--jobs 1` and missed at `--jobs 4`.
4. **`ir_encode_10k`** is 18 ms per 1 000 cases (`174.7 ms`): not a problem at the sizes of a real suite; the number is
   in the baseline so that a change to `normalize`/`redact` that doubles it is seen.
5. **Measurement conditions.** The machine was shared with other test runs (CPU 45 - 60 % busy during the
   baseline, 95 - 100 % during the first attempts). The first attempt gave `doctor_startup` 255 ms and
   `child_spawn_cold` 2.4 s (the kill was inside the timed region then: finding 1); the baseline above is the
   quieter one. Two consecutive runs of the check differed by at most 13 % on every case but `history_append`
   (4 and 8 ms), well inside `budget.factor`. A baseline for a quiet machine or a CI runner has to be written on
   that machine (`--update`).

### The keys of the suite's own specs, and the child environment (2026-10)

Measured with `testing explain . --all` on this repository (`--cached` twice, then `--cache-audit all`, Windows 11,
one run takes about 5.5 minutes):

| | before | after |
| --- | ---: | ---: |
| spec files with a cache key | 33 of 139 (24 %) | 119 of 146 (82 %) |
| most frequent reason for no key | 50 files: a module the spec loads reads the environment by a computed name | 15 files: the clock (timing assertions) |
| stored by a full `--cached` run | not measured (the folder defect below applied) | 80 of 144 |
| from the cache in the second run | 0 | 79 of 144 |
| `--cache-audit all` | | 79 of 79 hits run again, 0 differ |

(Specs of other work on the same tree are in "after": 146 files against 139.) Why a key is not a hit: 37 files have a
key and are never stored, because the effects ledger sees a process they start (a child editor, `git`); the clock
takes 15 (they assert that something is fast: a cached pass would say nothing); 9 start a process the scanner sees.
What changed, in the order of the files it freed:

* The runner's own modules that read the whole environment, or a variable by a computed name, now say so (`-- @cache-env`
  for `testing.deps` and `testing.affected`, whose names are known; `-- @cache-allow env` for the snapshots, the
  redaction and the key code itself). That alone was 45 of the 50 files.
* The scanner no longer takes a table field named `environ` / `os`, a `vim.env` that is only tested, a `".."` or `"~/"`
  that is only compared, or a lone backslash for a read of the environment, of the clock or of a place outside the
  project (see "What the scanner does NOT count" in CACHE.md); 11 files.
* 25 specs carry `-- @cache-env`, `-- @cache-allow time|random|spawn|net|outside` with the reason next to it (a stubbed
  `vim.system`, relative ages of fixtures, the bad values of a path validator).
* A suite that calls `cli.main` from a spec (this one does, in 24 files) left the cache folder of the other project in a
  global, and the hosting run stored its results where its next run did not look: **0 hits in 144 files** even with every
  key stable. A run keeps the folder it started with now.

The child environment (`isolated = "file"`, every busted file): the key held one digest of the whole sanitized parent
environment, including the `LANG`, `LANGUAGE`, `LC_*` and `TZ` that the child never sees (it gets fixed values). Measured
with `testing explain --all --json` on copies of two suites that run every file in a child, once as it is and once with
`LANG=xx_XX.UTF-8 LANGUAGE=de TZ=Pacific/Fiji LC_TIME=de_AT.UTF-8`:

| | keys that survive another locale, before | after | keys that survive another `TERM`/`COLORTERM`/`DISPLAY` |
| --- | ---: | ---: | ---: |
| markdown.nvim (30 keyed files) | 0 | 30 | 0 before and after |
| ui.nvim (31 keyed files) | 0 | 31 | 0 before and after |

`PATH`, `HOME`, `TERM`, `COLORTERM`, `DISPLAY`, `WAYLAND_DISPLAY`, `NO_COLOR`, ... stay in the key: a child can read each
of them (a headless editor still derives `&term` from `TERM`, `has("clipboard")` from `DISPLAY`, tools it starts from
`PATH`) and no analysis of a spec proves it does not. Dropping them would be a guess; the price is a miss between two
terminals with another `TERM`. The lines are one per variable now (`child-env NAME=<hash>`), so `testing explain` names
the variable that changed instead of saying that "the child environment" did.

## Rules checked

* **PERF-11 (memoization)**: nothing measured here repeats pure work per call; the stable hash of a path is
  computed once per shard computation, `scan_dirs` is one pass per cycle. No memoization added: no measurement
  supports one.
* **PERF-13 (async instead of blocking)**: the pool acquires members asynchronously (`spawn_async`); the watch
  loop waits in 10 - 50 ms slices of `vim.wait` and does its work between them; a luv callback only sets a
  flag and a timestamp. The in-process run itself is synchronous by design.
* **PERF-40 to 47 (cache)**: the cache and its measurements are in "Cache and affected selection" above; the rules are
  checked by `cache_key_spec`, `cache_store_spec` and `integration_cache_spec`. The hash case measures the cost
  the cache is built to avoid.
* **PERF-60 (adaptive delay)**: the watch debounce is a quiet time (it restarts with every event), not a fixed
  sleep. The polling fallback uses a fixed interval (`watch.poll_ms`); an adaptive one (slower while nothing
  changes) is possible and not done, because no measurement shows the poll costing anything: one scan of a
  few hundred files is a few milliseconds per second.
* **PRIN-36 (instrumentation is never neutral)**: `--profile` is a few `hrtime` reads and one pass over the cases;
  `testing budget` measures with the same harness it reports with. Neither changes a verdict.
