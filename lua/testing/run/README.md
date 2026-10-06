# `testing.run`

Runs the spec files of a project in the current Neovim and builds the Result-IR. Reporters render the
IR; nothing here prints test results itself.

| Module | Purpose |
|--------|---------|
| [`testing.run.project`](project.lua) | One `testing run`: minit, discovery, selection and order, the run, reporters, history, sentinel, exit code |
| [`testing.run.inproc`](inproc.lua) | The driver: runs the planned files in their dialect under a timeout guard, builds the IR; `list`, `sanitize`, `write_json` |
| [`testing.run.isolated`](isolated.lua) | The isolated driver: one child editor per spec file, a pool of them (`--jobs`), results merged in file order, hard timeouts, crash classification |
| [`testing.run.options`](options.lua) | The isolation options (`isolated`, `jobs`, `host`, `filetype`, `assertions`, `env_allow`) read from ONE place: flags win over `.testing.lua` |
| [`testing.child`](../child/README.md) | One child editor: argv, sandbox, environment, start, process-tree kill; `boot.lua` runs inside it |
| [`testing.run.select`](select.lua) | Pure: `--file`/`--filter`/`--tags` matching, `--lf` grouping, deterministic shuffle |
| [`testing.run.timeout`](timeout.lua) | Best-effort in-process timeouts (count hook, `vim.wait` clamp) |
| [`testing.history`](../history.lua) | `runs.jsonl` behind `--lf` / `--ff` (untrusted input when read back) |
| [`testing.cli`](../cli.lua) | Arguments, config, dependencies, exit codes; entry of [`scripts/testing.lua`](../../../scripts/testing.lua) |

## A run, in order

1. `minit` of `.testing.lua` (default `TESTS/minimal_init.lua`) runs in this editor when the file
   exists, as the old runners `dofile`d their `minimal_init.lua`. A raise is exit code 3.
   (`setup` is reserved for the conformance suite and is not called.)
2. Discovery (`testing.discover`): spec files below `roots`, dialect per file (sniffed, or the
   `dialect` override), findings (legacy places NEW-48, symlinks, unknown dialects), the order and
   sentinel of the project's own `TESTS/run.lua`.
3. Selection and order: `--file`, paths, `--lf` / `--ff`, `--shuffle [--seed N]`; `--filter`,
   `--tags`, `--exclude-tags` per case.
4. `--list` / `--dry-run` prints the planned cases and stops (exit 0, or 2 when nothing is selected).
5. The run, under the exit guard: `os.exit` inside a spec raises (that file becomes an `error` case),
   quitting the editor is exit code 3.
6. Reporters: the terminal reporter reads the real IR (clickable absolute paths); `--junit`,
   `--github`, `--json` and `--reporter json|junit|github` read the sanitized IR (placeholders for
   paths, user/host/environment redacted by the kernel, decoded again and validated). A reporter that
   cannot write is exit code 3.
7. History and the sentinel.

## Mapping, statuses, exit codes

* Dialects a, b, c, d, h: **one case per spec file**, id `TESTS/x_spec.lua::x_spec.lua`. Busted:
  **one case per `it`**, id `TESTS/x_spec.lua::describe::...::it`.
* `error`: the spec raised, did not load, did not return `function(H)` (the message names the spec
  path), or is listed by the project's runner but missing on disk. `timeout`: see below. `skip`: the
  dialect is unknown (the file is not run) or the spec said `pending`.
* Exit codes: `0` green, `1` a `fail`/`error`/`timeout`/`crash`/`xpass` case (under `--strict` also a
  skip and a warn/error finding), `2` usage, config, nothing to run or nothing selected, `3`
  infrastructure (dependency, minit, IR, reporter, driver).
* **A skip is never green.** Without `--strict` it does not fail the run, but the run prints no
  sentinel; with `--strict` it is exit 1.
* **Sentinel** (the `LIB_TESTS_OK` style of the project's `TESTS/run.lua`, else `TESTING_OK`): last
  line, only on exit 0 of a complete run (no `--file`/path/`--filter`/`--tags`/`--lf`, no `-x` stop)
  with no skipped case and after every requested file was written. Otherwise a distinct last line
  (`partial run: ...`, `N case(s) skipped: ...`) takes its place.

## Selection

* `--file <text>`: the spec FILE's path relative to the root contains `<text>` (plain substring, never
  the absolute path). Positional paths below the root select a file or a directory.
* `--filter <text>`: the case ID contains `<text>` (plain substring; the id holds file, describe
  titles and `it` title, so a file name or a describe title selects too). Repeatable, any match.
* `--tags a,b` / `--exclude-tags c`: tags are `#word` in a `describe`/`it` title (a trailing
  `#<digits>` is the duplicate counter), and `-- @tags a b` header comment lines in the first 30
  lines of a spec tag every case of the file. Any listed tag selects; exclusion wins.
* `-x` / `--maxfail N`: stop after N red cases. Inside a busted file the remaining `it`s are not run;
  later files are not run, the report says how many.
* `--shuffle [--seed N]`: files are shuffled with a private PRNG (Park-Miller): one seed, one order, on
  every platform, whatever a spec does to `math.random`. The seed is printed before the run, stored
  in `run.seed` and repeated in the failure report. **Cases inside one busted file keep their source
  order**: `it` bodies run where they are written, as in plenary.
* `--lf`: only files with a remembered failure, and in them only the failed cases (the whole file if
  the file itself failed). Nothing remembered: everything runs and a note says so. `--ff`: failed
  files first. `--durations N`: the N slowest cases (0 = all).

## History

`stdpath('state')/testing/<name>-<12 hex>/runs.jsonl`, one line per run: `{"v":1,"run","ts","seed",
"summary","failed":[ids]}`. `failed` is cumulative (a case that ran and passed leaves, a file that ran
completely forgets ids it no longer produces, a file that is gone is dropped). Bounded: 20 runs, 5000
ids, 500 bytes per id, 1 MiB; written atomically. Untrusted when read back: size cap, every line
decoded under `pcall` and validated, bad lines dropped and counted, a garbage file is ignored with a
note. It is never part of the verdict: a failing write is a note.

## Timeouts, honestly

`timeouts.case_ms` / `timeouts.file_ms` of `.testing.lua`, overridden by `--case-timeout` /
`--file-timeout`. In-process Lua cannot be preempted, so the guard injects an error:

* a **count hook** raises `testing: timeout: ...` every 10000 VM instructions once a deadline passed
  (LuaJIT does not call hooks from compiled traces, so the JIT is switched off while a guard is
  active and restored afterwards): stops `while true do end` and retry loops;
* a **`vim.wait` wrapper** clamps the wait to the time left and raises when it ran out: stops waiting
  for a condition that never comes.

The file deadline is persistent (a spec that swallows the error with `pcall` is stopped again), the
case deadline is one-shot and re-armed by the driver after each case. The status is `timeout`
(exit 1), never `error` or `pass`; a spec that caught the error and finished is still a `timeout`.

`case_ms` applies per `it` of a busted file. The one-case-per-file dialects have no case boundary
inside the file, so only `file_ms` applies there.

**Child editors have hard limits.** With `--isolated file` (default for busted files) the file runs
in a child process (`testing.child`) and the POOL enforces the limits from outside: `file_ms` plus a
2 s grace since the start, and for busted files `case_ms` plus the grace without a new case once the
first one finished (loading a big file is not a stuck case). The whole process tree is killed
(Windows `taskkill /T /F`, POSIX the process group), the status is `timeout` for that file only, the
cases that finished before are kept, the run goes on. The in-child guard above still runs first and
usually ends the file with the precise message.

**Not interruptible in-process:** a spec blocked inside C (`vim.system(...):wait()` without a timeout,
`io.read`, a blocking `vim.fn.system`, a stuck RPC call) is not stopped in this editor. Run it in a
child (`--isolated file`): that is what the kill is for.

## Output shapes

The terminal reporter keeps the lines of the old runner (`ok    TESTS/x_spec.lua`,
`FAIL  TESTS/x_spec.lua` plus indented detail, `N spec(s) failed`), then a summary, then the findings
(`finding [NEW-48 warn] ...`), the `timings:` line (`--no-timings` removes it) and the sentinel.
