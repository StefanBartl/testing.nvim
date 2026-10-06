# `testing.dialect`

Shims that let existing spec files run on the kernel (`testing.core`) without being edited. Every dialect has
the same entry point, `run_file(a, spec, opts) -> cases` (see [`init.lua`](init.lua)); the cases are finished
and the caller adds them to the result.

| Module | Dialect | Cases per file |
|--------|---------|----------------|
| [`harness_a`](harness_a.lua) | A: `return function(H)`, `H.eq/ok/tmpfile/read_lines/with_patched/with_stdpath_config` (lib.nvim) | 1 |
| [`harness_b`](harness_b.lua) | B: `H.eq/ok/scratch(ft)/tmproot/tmpdir()/canonical/write_file` (markdown.nvim, diff.nvim) | 1 |
| [`harness_c`](harness_c.lua) | C: `H.eq/ok/falsy/contains/scratch(lines, ft)/tmpdir(fn)/write` (images.nvim) | 1 |
| [`harness_d`](harness_d.lua) | D: `M.run()` with the plugin's own `harness` module (spotlight.nvim) | 1 |
| [`harness_project`](harness_project.lua) + [`harness_conventions`](harness_conventions.lua) | h: `return function(H)` on the project's own `harness.lua` (every repo whose helpers a shim cannot reproduce) | 1 |
| [`script`](script.lua) | script: a self-running script (`nvim -l TESTS/x.lua`, own counters, exit code); only the verdict lives here, the child process is the driver's | 1 |
| [`busted`](busted.lua) + [`luassert`](luassert.lua) | E: plenary.busted `describe` / `it` (dap, sandbox, github_stats, ...) | one per `it` |

A, B, C and h share `H.eq` / `H.ok` semantics: a failed check is **recorded** on the open case and the spec goes on, so every
failure of a file is visible (P1). The recorded call site is the spec's own `file:line`. An unknown `H` key reads `nil`.

## Dialect h

The project's `harness.lua` is loaded and every function of its table is wrapped **in place** (counters, lists and
internal state stay one object). What counts as a failed check is a *convention*
([`harness_conventions`](harness_conventions.lua), data plus small functions, `register()` adds one):

| Convention | Harness shape | Fleet |
|------------|---------------|-------|
| `fail_text` | `error("FAIL <msg>", 2)` from `H.eq` / `H.ok` / `H.match`: recorded, the call returns `false`, the spec goes on | 13 repos |
| `check_collector` | `H.check(name, fn)` pcalls `fn`, prints `[FAIL]`, appends to `H.failures`; assertions inside raise plain errors: one assertion per check, failed with the callback's error | gopath.nvim |
| `failure_list` | a `failures` list: growth is failures | spotlight-style |
| `counters` | numeric `checks` / `assertions` / `passed` (a helper that raises one is an assertion), `failed` / `fail_count` (growth is failure) | fileops, emojis, gopath |
| `printed_failures` | lines printed inside harness calls that read `[FAIL] ...`, `FAIL ...`, `not ok ...`, written with `print`, `io.write`, `io.stdout:write`, `io.stderr:write` or `nvim_out_write` (`testing.policy.capture` hooks all of them) | any |
| generic net | no convention: any number or list field of `H` whose NAME contains `fail`, `err`, `bad` or `broken` and that grew while the file ran (`H.n_bad`, `H.errors`, also one that came into existence during the file) | any |

**The runner is never greener than the project's own harness.** After the file ran, what the harness collected or
counted or printed and the adapter did not see is added as failed assertions of kind `project_failures` (gopath.nvim
reported 19/19 although 7 `[FAIL]` lines were printed). Any other error is not an assertion failure: it propagates and
ends the file as `error`. Assertions are the functions whose body raises `FAIL`, plus every function that raised a
failure or moved a pass counter. The call site of a recorded check is the spec's own line (the innermost assertion for a
check). Limits: a helper that calls other assertions and fails in the middle stops there; a harness whose failures are
neither `FAIL ...` errors, nor collected or counted in a field named like a failure, nor printed is not recognised.

`discover` chooses `h` for a file when a shim cannot be proven equivalent to the harness (see
[`discover/README.md`](../discover/README.md)); `dialect = "h"` in `.testing.lua` forces it.

## Dialect script

`discover` classifies a file with no framework but a top-level `os.exit(` / `cquit` as `script` (or `.testing.lua` says
`dialect = { ["*"] = "script" }` together with a `spec_pattern`). `dialect.run_file("script", ...)` answers an `error`
case, because a script ends its own process: the child driver runs it in a process of its own and hands
`{ code, stdout, stderr, timed_out, crashed }` to `script.build_case(a, rel, run, opts)`:

* a timeout is `timeout`, a native crash (exit 139, 0xC0000005, `crashed`) is `crash`;
* failure lines (`[FAIL]`, `FAIL ...`, `not ok`) are failed assertions, also under exit 0 (never greener than the
  script); a summary `N passed, M failed[, K skipped]` is read; `M > 0` is red;
* exit != 0 without failure lines: a Lua error on stderr is `error`, else one failed assertion `exit code N`;
* exit 0 without any summary is the one assertion "exit code 0".

## Assertion policy and skips (`testing.policy`)

A case without assertions is a failure by default (P4). Two honest exits, applied by every dialect to the finished
case:

* **skip convention**: no assertion at all and a printed line starting with `skip` (`skip  git_spec.lua: git not
  usable`) is a `skip`, never green, red under `--strict`. A spec that asserted before skipping keeps its verdict;
  failures, errors and timeouts are never turned into skips.
* **`assertions = "warn"`** (`.testing.lua`, `opts.assertions`): a case without assertions is a pass that carries one
  passing synthetic assertion (kind `no_assertions`, so the IR stays valid) and the note
  `warning: case made no assertions`. The migration config of a repository that ran under plenary sets it.

## Dialect D

The plugin's `harness` module is loaded as its runner does (`require("harness")`); its functions are wrapped and what
`t.passed` / `t.failures` gain is recorded as assertions. `package.path` and `package.loaded.harness` are restored.

## Busted

Executed like plenary does: `it` runs where it is written. Ids are `<file>::<describe>::...::<it>` (`#2` for repeats).
`before_each` outer block first, `after_each` in plenary's order (outer block first), `setup` when registered,
`teardown` at the end of its block. `pending(reason)` inside a body ends it as `skip`. A raise outside an `it`
(describe body, top level, setup, load error) is an `error` case of its own; a file without a case fails.
Unsupported (raise, never pass): `spy`, `stub`, `mock`, `insulate`, `expose`, `finally`, `xdescribe`, luassert
assertions beyond the supported list (`luassert.supported()`).
Known differences to plenary: a failed assertion does not abort the body; `pending()` inside a body aborts it.

`run_file(a, spec, { select = fn(id), dry = true, on_case = fn(case), assertions = "error"|"warn" })` also returns a listing of case ids.
