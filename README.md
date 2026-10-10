> **Pre-alpha, milestones M0 to M2 are done, M4 and M5 are being wired in.** A test runner for Neovim
> plugins that runs the spec styles of the author's plugins unchanged, tells the truth about a run, and
> tests itself with itself. Spec files can run in a child editor of their own, guards name what a spec
> leaves behind, an opt-in warm pool reuses editors between files, and an opt-in result cache skips spec
> files that cannot have changed. No editor UI beyond `:Testing`. Expect breaking changes; do not depend on
> it.

# testing.nvim

```
  ████████╗███████╗███████╗████████╗██╗███╗   ██╗ ██████╗
  ╚══██╔══╝██╔════╝██╔════╝╚══██╔══╝██║████╗  ██║██╔════╝
     ██║   █████╗  ███████╗   ██║   ██║██╔██╗ ██║██║  ███╗
     ██║   ██╔══╝  ╚════██║   ██║   ██║██║╚██╗██║██║   ██║
     ██║   ███████╗███████║   ██║   ██║██║ ╚████║╚██████╔╝
     ╚═╝   ╚══════╝╚══════╝   ╚═╝   ╚═╝╚═╝  ╚═══╝ ╚═════╝
                                                     .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-pre--alpha-red)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
[![CI](https://github.com/StefanBartl/testing.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/StefanBartl/testing.nvim/actions/workflows/ci.yml)

> Sister plugin: [runtime-analysis.nvim](https://github.com/StefanBartl/runtime-analysis.nvim) —
> runtime truth for plugins (telemetry, live module inspection), the counterpart to what a test
> run tells you about them.

A test runner and orchestration layer for Neovim plugins, built on
[lib.nvim](https://github.com/StefanBartl/lib.nvim). The goal is to replace busted and plenary for
the author's plugins and to replace, extend and improve their hand-written test harnesses, with the
existing specs running **unchanged**. What is true today: the runner runs `describe`/`it` specs
**without plenary or busted** (verified on the 13 plenary repositories of the fleet, with a probe that
fails when plenary is reachable), runs the harness-style specs of the fleet (`return function(H)` and
the like, on the project's own harness where there is one), runs self-running scripts, can run every
spec file in a child editor of its own, tests this very repository with its own runner, and reports
through a terminal reporter, GitHub annotations, JUnit XML and a JSON result format. How close the
fleet is to the goal is measured, not claimed: see [Fleet status](#fleet-status). Moving the fleet's
repositories over has not happened.

## Table of contents

- [Status](#status)
- [What testing.nvim does differently](#what-testingnvim-does-differently)
- [Fleet status](#fleet-status)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Status

Pre-alpha, milestone M1 ("a runner that never lies"). What exists and works:

- **The runner**: `scripts/testing.lua` discovers specs below `TESTS/` (no depth limit), picks the
  dialect of every file, runs them in one Neovim process and exits with a code that means
  something: `0` green, `1` red, `2` usage or nothing to run, `3` infrastructure
  ([docs/EXIT-CODES.md](docs/EXIT-CODES.md)).
- **Dialects** ([docs/DIALECTS.md](docs/DIALECTS.md)): `return function(H)` in the three shapes of
  lib.nvim, markdown/diff.nvim and images.nvim (`a`, `b`, `c`), spotlight.nvim's `M.run()` (`d`),
  specs on a project's own `harness.lua` (`h`), self-running scripts (`script`) and `describe`/`it`
  with a luassert subset (`busted`). A failed check is recorded and the file goes on, so every
  failure is visible (inside a `pcall` the spec wrote it is raised, so a spec can ask whether a check
  fails: [docs/DIALECTS.md](docs/DIALECTS.md#a-spec-that-asks-does-this-check-fail)). Unsupported busted features (`spy`, `stub`, `mock`, `insulate`, ...) raise by
  name instead of passing silently.
- **Honesty**: a case without an assertion fails (unless `assertions = "warn"`, and then the terminal
  lists them); the runner is never greener than a project's own harness (collected failures, printed
  `[FAIL]` lines, fields named like a failure); a spec cannot end the run with `os.exit`; quitting
  the editor mid-run is exit `3`; a selection or a skipped case never prints the "all green" last
  line; a missing dependency is reported with all four places that were searched.
- **Child editors** ([CONFIG.md](docs/CONFIG.md#child-editors)): `isolated = "file"` (default for busted
  files and for scripts) runs every spec file in an editor of its own, `jobs` of them at once, with an
  environment allowlist, fixed `LANG`/`TZ` and a sandboxed `stdpath`. A file that crashes the editor is
  one `crash` case, a file that hangs is killed with its process tree and is one `timeout` case, each
  with a trace artifact; a prompt nobody can answer is cancelled; the other files run on.
  `isolated = "case"` gives every case a child, `"soft"` restores what a file changed in this editor
  ([docs/ISOLATION.md](docs/ISOLATION.md)).
- **Guards** ([docs/GUARDS.md](docs/GUARDS.md)): safety nets, not a sandbox. They name what a spec
  leaves behind ("spec X leaves autocmd Y in group Z", a stub in `package.preload`, a running job), what
  it writes outside the run folder, an error in a scheduled callback, a prompt nobody answers, a
  deprecation, and a process or connection (`process_net`, off by default; `guards.<name>` also takes a table to tune a guard, see [docs/GUARDS.md](docs/GUARDS.md#tuning-a-guard-in-testinglua)). They run in this editor
  and in every child; findings are in the terminal report, JUnit, GitHub and the IR (`case.guards`,
  `case.effects`). This repository's own suite runs with every guard on `error`.
- **The RPC child** ([docs/CHILD.md](docs/CHILD.md)): `testing.rpc` starts an embedded, headless,
  sandboxed editor that a spec drives like a user (`feed`, `input`, `settle`, `screen`, ...).
- **Warm pool** (opt-in, `--pool-reuse`): child editors that run file after file, each reset and
  checked clean in between; a member that cannot prove it is clean is replaced and a finding says why.
  Measured, not promised: six times faster for 40 trivial files, between 3 % (lib.nvim) and about a
  third (lsp.nvim) at `--jobs 4` for the two real suites tried, and no gain worth naming at `--jobs 1`
  ([docs/ISOLATION.md](docs/ISOLATION.md#the-warm-pool)).
- **Migration** ([docs/MIGRATING.md](docs/MIGRATING.md)): `testing migrate` plans (dry run, default) or
  writes the move of a repository to testing.nvim; specs, `TESTS/harness.lua` and `TESTS/run.lua` are
  never touched.
- **Selection and order**: `--file`, `--filter`, `--tags`, `--exclude-tags`, `--lf`, `--ff`,
  `-x`/`--maxfail`, `--shuffle`/`--seed`, `--list`, timeouts per case and file, `--shard i/n` for CI
  matrices, `--watch`, `--profile` ([docs/CLI.md](docs/CLI.md), [docs/PERFORMANCE.md](docs/PERFORMANCE.md)).
- **Result cache and affected selection** ([docs/CACHE.md](docs/CACHE.md)), both opt-in and never the
  default in CI: `--cached` does not run a spec file whose inputs (its content, the files it requires,
  the files it reads, the runner, Neovim, the configuration) are byte-identical to an earlier green run;
  its cases come back marked `cached` and counted as not run, a spec that reads the clock or starts a
  process is never cached, and `--no-cache` always wins. `--changed`, `--since <rev>` and `--affected` run only
  the specs the git changes can reach (a built-in heuristic on the `require` graph, to which the module graph of
  documentation.nvim can only ADD specs); a change nobody can place selects every spec, and a selection is a
  partial run that never prints the "all green" last line.
  With `--consumers <dir>` it also names the specs of the other checkouts below `<dir>` that the change reaches
  (a hint from documentation.nvim, never part of what runs). `--retry-failed <n>` runs a red case again; one that
  passes is **flaky**, the run stays red (`--allow-flaky` is the explicit exception: exit 0, but the verdict is
  `green-partial` and there is no sentinel) and a flaky file is never cached. `--order slowest-first` starts the longest files first with `--jobs`.
- **Conformance and surface** ([docs/CONFORMANCE.md](docs/CONFORMANCE.md),
  [docs/SURFACE.md](docs/SURFACE.md)): `testing conformance` runs the checks K1 to K15 of the gates on a
  plugin (report only until a repository opts into `conformance.gate`), `testing surface` lists a plugin's
  keymaps, commands and autocmds and, from a run with `surface = { track = true }`, how many of them the
  specs exercised. Both report first; neither is a gate by default.
- **Output** ([docs/OUTPUT-FORMATS.md](docs/OUTPUT-FORMATS.md)): terminal, GitHub annotations and
  step summary, JUnit XML, and the Result-IR as JSON (`schema_version = 1`, deterministic,
  redacted, validated after writing). Every reporter carries a three-valued **verdict**
  (`green`, `green-partial`, `red`, with "n from cache, m ran, k skipped on purpose"; `green` is
  exactly the run that prints the sentinel, and a red run names the last green run and what changed
  since). `--reporter agent` is a compact form for coding agents (verdict first, only failures with
  `file:line`, expected/actual and a repeat command, a character budget that counts what it cuts); it
  is selected by itself in a recognised agent environment. `--order priority` runs what failed last and
  what the changes reach first; it orders and never filters.
- **Per-project configuration** `.testing.lua` ([docs/CONFIG.md](docs/CONFIG.md)), with a validated
  schema.
- `:checkhealth testing`, and the `:Testing` command ([docs/BINDINGS.md](docs/BINDINGS.md)), which
  runs in a headless child so a run never touches the editor you work in.
- A headless spec suite that runs through the runner itself in CI on Linux, macOS and Windows.

Known limits, not hidden:

- Without isolation (`--isolated none`, the default for the non-busted dialects) all spec files of
  a run share one Neovim process, like in the old runners: shared `package.loaded`, globals and
  autocmds, and a native crash ends the whole run. The timeouts are then a best-effort guard that
  cannot interrupt a spec blocking inside C. Under `isolated = "file"` they are hard.
- A helper a spec leaves behind after its child ended normally is not killed on Windows (no job
  objects from Lua); on POSIX its process group is.
- The runner itself is started with `nvim -l` (`v:vim_did_enter` is `1`, `expand("<cfile>")` raises);
  specs that need the host of a `-c` command must run in a child (`isolated = "file"`, host `c`).
- `effects` of a case are filled by the guards: with `process_net` off (the default) no process or
  connection is seen, with `fs` off no write, and the case says so in its notes; an empty list is not a
  measurement then.
- The `init` subcommand exists only as `:Testing init`, not on the command line.
- The warm pool and `isolated = "soft"` restore and check what they can see (modules, globals,
  autocmds, mappings, commands, options, environment, the editor's LSP and diagnostic registries,
  running jobs and handles, the sandbox); the pool also puts back registers, abbreviations and `t:` /
  `w:` variables and names a replaced function of the editor API or the standard library. Quickfix
  lists, marks, highlight groups, `v:vim_did_enter` and state inside a C library they cannot. A child
  per file is the exact isolation.
- The state guard has nothing to protect in a child that runs one case (it dies with its case) and is off
  there; the cases say so. A `script` file runs under the other guards (one window for the whole file); one that leaves the editor with `:cquit` / `:qa!` writes no record, and its case says so.
- The result cache does not know what a spec reads from a path it builds at run time with no literal anywhere
  (declare it with `-- @cache-inputs` or opt out with `-- @cache off`), does not see the runtime directories of a
  dependency checkout or `stdpath('data')/site` (those of the project, `ftplugin/`, `queries/`, `after/`, ..., are
  part of every key), does not treat the clock or a process
  of a MODULE as a hidden input (the effects ledger refuses a file that really started one; a clock is not seen:
  `docs/CACHE.md`, "Known limit"), and a case selection (`--filter`, `--lf`, ...) turns it off for that run. The
  affected selection follows `require`s, path literals and directory listings: a spec that starts a process is
  run whenever a module changed, a spec that lists directories whenever anything changed, and a change in another
  checkout (lib.nvim) selects nothing here.
- Surface tracking does not work with the warm pool (it says so), a keymap with a string right-hand side
  cannot be observed, and no threshold fails `testing run`; `testing surface` is the gate.
- Not implemented at all: a test UI (tree, hover), snapshots, adapters for other test frameworks. Keys for
  some of these exist in `.testing.lua` and are validated, but nothing acts on them.

## What testing.nvim does differently

Compared with busted, plenary (`PlenaryBusted`), vusted, mini.test and neotest. What follows is limited to what the
code and the measurements of this repository show, and to what the documentation of those tools says on
2026-10-07; "not mentioned there" is weaker than "does not exist".

- **A result cache and an affected selection, per spec file.** None of those tools documents either. testing.nvim
  keys a spec file by everything it can see it depend on (its content, the closure of its `require`s including
  lib.nvim, the files it reads, the runner, Neovim, the configuration, the environment variables the configuration
  lists), and when it cannot know the inputs it does **not** cache (a spec that reads the clock, starts a process,
  reads an environment variable the key does not contain, or names a file outside the project). The comparison that
  fits is a build system that caches test results (Bazel, Gradle, Turborepo), not a test framework; those ask you to
  declare the inputs and warn that an undeclared one can produce a wrong hit, testing.nvim analyses them and refuses
  when unsure. That is only as strong as the scanner, which is not a parser: a path built at run time with no literal
  anywhere is invisible to it. Two procedures measure and catch that instead of asserting it away: `--cache-audit`
  re-runs a share of the hits and reports the **measured stale-pass rate**, and a spec whose key gave two different
  results is marked nondeterministic. `testing explain <spec>` says why a file was selected, taken from the cache or
  run, and what changed since its stored entry. `testing stamp` writes, after a complete green run, a small stamp of every
  file's key, and `testing verify` answers from the keys, without running a spec, whether anything a key can see
  changed since: `verified` (exit 0, sentinel) only when every file is proven, otherwise `partial`, `changed`,
  `expired`, `dirty` or `untrusted`, never green.
- **Guards and an effects ledger** that measure whether a spec is pure (processes, network, writes outside the
  temp directory, leftover state, deprecations, a clock). The cache refuses a file the ledger saw an effect in.
- **A result format with deterministic bytes** (the Result-IR: sorted keys, redacted, validated after writing) that
  every reporter and the cache read, and a verdict that does not flatter: a skip is never green, a partial run
  (a selection, a case filter, `--maxfail`) never prints the sentinel, and the line says how many files came from
  the cache, ran, or were skipped on purpose.
- **Heuristics order, proofs skip.** The affected selection is a heuristic: it picks and orders the specs that are
  likely to matter. Only the cache key, which compares the actual inputs, may let a run skip a file and still call the
  result complete.

What it does not do, and where the effect is small. The cache pays where a suite is made of many small, pure spec
files, and almost nothing where specs use the clock, processes, or paths outside the project. Measured on one
machine (Windows 11, 12 threads, Neovim 0.12.2, 2026-10-06, one run each, [docs/PERFORMANCE.md](docs/PERFORMANCE.md)):

| Suite | Spec files | Files from the cache, warm | Wall clock, plain, then warm |
| --- | ---: | ---: | --- |
| markdown.nvim | 47 | 27 | 18.0 s, then 12.3 s |
| ui.nvim | 65 | 29 | 40.0 s, then 28.1 s |
| images.nvim | 35 | 3 | 10.5 s, then 10.4 s |
| casedesk.nvim | 95 | 7 | 81.6 s, then 82.9 s |
| lib.nvim | 87 | 10 | 110.0 s, then 101.0 s |

The first run with `--cached` costs more than a plain one (+1 % to +41 % on these suites). `--changed` is not a gate:
it is a partial run that never prints the sentinel, and on lib.nvim the selection averaged 60 of 87 specs over the last
20 commits, because computed `require`s make a one-line change reach most of the suite. There is no shared or remote
cache, no retry or flaky-test quarantine, no test UI and no screenshots; the project is pre-alpha.

Measured stale-pass rate (`--cached --cache-audit all` after a warm run, 2026-10-07, same machine, one run each):
markdown.nvim 0 of 27 audited hits differed, ui.nvim 0 of 29. That is 56 hits and no stale pass found, which says the
key was right for those two suites on that day. It does not prove that it is right in general: the audit is a
sample of what the key already accepts, and a path that is built at run time stays invisible until a spec reads a
file that changes.

## Fleet status

The goal is measured, not claimed. On 2026-10-06 (Windows 11, Neovim 0.12.2) 39 of the 41 repositories
with specs were run twice, with their own runner (plenary or a hand-written `TESTS/run.lua`) and with
`testing run` on a copy, using the `.testing.lua` (and, where the old minimal init loaded plenary, the
`TESTS/minimal_init.lua`) that `testing migrate` proposes. **No spec was changed.**

- **Same verdict as the old runner: 30 of 39** (case for case in the busted repositories: rules 163,
  gitsuite 232, my 203, data 507, ui 1027, lsp 1523 including its one pending case, mdview 299, dap 246,
  sandbox 964; and the hand-written ones such as lib 87, documentation 107, tasks, media, insights,
  color_my_ascii, emojis, pdfport, open, ...). cascade is red under both runners, for the same reason.
- **Differs, and the reason is known: 9.**
  - gopath: the old runner reports 19/19 although 7 `[FAIL]` lines are printed (its harness collects
    failures itself); the runner is red with those 7. This is the honest verdict, not parity.
  - hover, github_stats: 2 cases each assert nothing and fail under the default `assertions = "error"`
    (plenary let them pass); green with `assertions = "warn"`. casedesk: one spec needs `$REPOS_DIR`
    in the child (`env_allow = { "REPOS_DIR" }`); green with it.
  - markdown (`expand("<cfile>")` under `nvim -l`), diff (a state leak between two spec files in one
    process, cause not found), images and spotlight (the plan puts `ui.nvim` on the runtimepath, their
    specs need it absent; spotlight also `v:vim_did_enter`), filetree (one case of `gaps.lua` that
    only passes while `$TEMP` is the default temp directory, reproducible without the runner: the
    sandbox of a child redirects it).
- Same verdict, one line lost: fileops.nvim is green, but one of its specs skips itself by design, and
  a skip is never green, so the "all green" sentinel line its CI greps for is not printed.
- Not measured: testing.nvim itself (its 44 spec files pass through its own runner) and plenary.nvim
  (not part of the fleet).

Per-file isolation matters: with plenary-style isolation lsp.nvim no longer ends in exit `3` (a
language server's prompt), hover.nvim's native crash can no longer take the run down, and about 60
cases that failed through leaked state in my, data, casedesk and ui pass. 17 cases of the plenary
repositories assert nothing (3 of them are spec bugs, e.g. `ipairs({ nil, 0 })` whose body never
runs); `assertions = "warn"` keeps their verdict and the terminal lists them.

## Requirements

- Neovim 0.10 or newer.
- [lib.nvim](https://github.com/StefanBartl/lib.nvim), a hard dependency, and new enough to contain
  `lib.nvim.fs.write.atomic` (commit `6304829`) and the `lib.lua.error.safe_call` that keeps
  non-string errors (commit `89cb912`). An older checkout fails with
  `module 'lib.nvim.fs.write.atomic' not found`; `:checkhealth testing` names the missing module and
  these commits.

The command-line runner looks for lib.nvim in four places, in this order: `$LIB_NVIM_DIR`,
`<repo>/.deps/lib.nvim`, a sibling `../lib.nvim`, `stdpath("data")/lazy/lib.nvim`. If none holds it, it
prints all four and exits with `3`.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "StefanBartl/testing.nvim",
  dependencies = { "StefanBartl/lib.nvim" },
  cmd = "Testing",
  opts = {},
}
```

## Usage

### Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . [options]
```

Run it from the root of the project whose specs should run (`scripts/testing.lua` is the one of the
testing.nvim checkout, so give its path when you are in another repository). Without a
configuration it runs every `*_spec.lua` below `TESTS/`:

```sh
... -l scripts/testing.lua . --file config      # spec files whose name contains "config"
... -l scripts/testing.lua . --filter parses    # cases whose name contains "parses"
... -l scripts/testing.lua . --list             # what would run, in which dialect
... -l scripts/testing.lua . --json out.json --junit out.xml --github
... -l scripts/testing.lua doctor .             # configuration and dependency report
... -l scripts/testing.lua . --cached           # skip spec files whose inputs did not change
... -l scripts/testing.lua . --changed          # only the specs the working tree can reach
... -l scripts/testing.lua explain . TESTS/x_spec.lua   # why it was selected, cached or run, and what changed
... -l scripts/testing.lua stamp .              # after a complete green run: write the green stamp
... -l scripts/testing.lua verify .             # no spec runs: is the tree still the stamped one?
... -l scripts/testing.lua . --cached --cache-audit all # re-run every cache hit: the measured stale-pass rate
... -l scripts/testing.lua conformance .        # the conformance checks K1 to K15
... -l scripts/testing.lua surface . --from out.json   # what the specs exercised (see docs/SURFACE.md)
```

All options: [docs/CLI.md](docs/CLI.md). A run looks like this (the terminal shows absolute
paths so that they are clickable; the JSON and the reports use project-relative ones):

```
FAIL  TESTS/calc_spec.lua
    fail  calc::fails visibly:9
        /path/to/project/TESTS/calc_spec.lua:9
          expected:
            99
          actual:
            2
    skip  calc::later:12
        skipped: pending

1 spec(s) failed

summary: 1 pass, 1 fail, 1 skip (3 case(s)) in 0.00 s
```

### In the editor

```vim
:Testing run          " run the specs of the current project in a headless child
:Testing file         " the spec of the current buffer
:Testing last         " repeat the last run
:Testing health       " same as :checkhealth testing
:Testing conformance  " the conformance checks of the current project
:Testing cache clear  " delete the result cache of the project
```

The plugin binds no keymap and registers no autocommand by default. Every subcommand, flag and
completion: [docs/BINDINGS.md](docs/BINDINGS.md).

### Configuration

A project may have a `.testing.lua` in its root; this repository's own is a working example:

```lua
return {
  plugin = "testing",
  roots = { "TESTS" },
  dialect = "auto",
}
```

Every key and its type: [docs/CONFIG.md](docs/CONFIG.md).

## Documentation

- [docs/CLI.md](docs/CLI.md): every subcommand and option.
- [docs/CACHE.md](docs/CACHE.md): the result cache and the affected selection: keys, limits, format, the green stamp.
- [docs/CI-CACHE.md](docs/CI-CACHE.md): the result cache and the stamp in CI with `actions/cache`.
- [docs/HOOKS.md](docs/HOOKS.md): pre-push, pre-commit and Claude Code `Stop` hook recipes.
- [docs/CONFORMANCE.md](docs/CONFORMANCE.md): the checks K1 to K15 and how a repository adopts them.
- [docs/SURFACE.md](docs/SURFACE.md): the surface of a plugin and the binding coverage.
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md): `--profile`, `testing budget`, the worker pool, measured numbers.
- [docs/CONFIG.md](docs/CONFIG.md): `.testing.lua` keys with types, dependency resolution, `setup()` options.
- [docs/ISOLATION.md](docs/ISOLATION.md): the isolation modes (`none`, `soft`, `file`, `case`), the guard
  settings and the other isolation keys.
- [docs/GUARDS.md](docs/GUARDS.md): the guards (safety nets, not a sandbox) and the effects ledger.
- [docs/CHILD.md](docs/CHILD.md): the RPC child driver `testing.rpc` and the warm pool.
- [docs/EXIT-CODES.md](docs/EXIT-CODES.md): what `0`, `1`, `2` and `3` promise.
- [docs/DIALECTS.md](docs/DIALECTS.md): which spec styles run, and exactly what each shim supports.
- [docs/OUTPUT-FORMATS.md](docs/OUTPUT-FORMATS.md): reporters and the Result-IR.
- [docs/MIGRATING.md](docs/MIGRATING.md): for plugin authors coming from busted or plenary.
- [docs/BINDINGS.md](docs/BINDINGS.md): every keymap, user command and autocommand.
- `:help testing`: the reference inside the editor.

## Development

```sh
scripts/test.sh                  # all specs, through this repository's own runner
scripts/test.sh --file config    # specs whose file name contains "config"
TESTING_CACHE_HOME=~/.cache/testing-nvim-tests scripts/test.sh --cached   # unchanged specs do not run again
```

`scripts/test.sh` is `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua .` plus an isolated
state directory. It exits `3` (and names the four places) when `nvim` or lib.nvim cannot be found.
CI runs the same on three operating systems and uploads the JSON result and the JUnit report when
it fails; a second job runs lib.nvim's whole suite, unchanged, through the runner.

Formatting and lint are CI gates (`stylua --check .`, `luacheck lua TESTS scripts plugin`).
`lua-language-server --check` is deliberately **not** a CI gate: a CI runner has no Neovim runtime
types, so the check there reports every use of `vim` as an undefined global (about 3600 findings
here), and handing it the runtime as `workspace.library` in `.luarc.json` would replace the editor's
own library injection and make the local numbers and the CI numbers different measurements. With
`vim` declared as a bare global it still reports about 100 findings that come from the missing `uv`
and tree-sitter types (`uv.uv_pipe_t`, `TSNode`) and from the spec shims, not from the code. Run it
locally, with the runtime your editor injects, as a measure before and after a change.

## License

testing.nvim is released under the [MIT License](https://opensource.org/licenses/MIT), see
[LICENSE](LICENSE).
