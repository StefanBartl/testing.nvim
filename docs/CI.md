# `testing ci`: the pipeline of a repository

`testing ci` runs the whole check pipeline of a repository on this machine: formatting, lint, the suite,
conformance, whatever else the repository checks. One definition in the `ci` section of `.testing.lua`, the same
exit codes as a run, no cloud, no container, no shell scripts that copy each other.

For how the pieces fit together (shim, editor, hook, several repositories, hosted runner) see [WORKFLOW-CI.md](WORKFLOW-CI.md).

```
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ci [--profile=<name>] [--step=<a,b>] [--keep-going] [--reuse]
                                                              [--agent|--no-agent] [--json=<file>] [--junit=<file>]
                                                              [--state-dir=<dir>] [--root=<dir>] [-- <suite options>]
```

Everything runs on this machine. `testing ci` is meant to do locally what a hosted CI runner does (a pipeline of
steps, deadlines, a proof of the tested state, reports), without GitHub or any other service.

## The `ci` section

```lua
-- .testing.lua
return {
  -- ... the rest of the configuration
  ci = {
    profiles = {
      fast = { "stylua", "luacheck" },          -- names: presets, steps below, or other profiles
      full = { "fast", "suite", "conformance" }, -- a profile may include a profile
    },
    default = "full",                           -- optional: `full`, or the only profile
    steps = {
      -- a preset, adjusted: `args` replaces the preset's default arguments
      luacheck = { preset = "luacheck", args = { "lua", "TESTS", "scripts", "plugin" } },
      -- a step of the repository: argv, never a shell line
      docs = {
        run = { "scripts/gen_docs.sh", "--check" },
        needs = { "pandoc" },
        env = { DOCS_ROOT = "${root}" },
        timeout = "2m",
        when = { os = { "windows", "linux" } },
      },
    },
  },
}
```

| Key of a step | Type | Meaning |
| --- | --- | --- |
| `preset` | name | A built-in step (below). Excludes `run`. |
| `run` | argv (list of strings) | The command. A first element ending in `.sh` runs under Git Bash on Windows (never the WSL launcher) and `bash` elsewhere; `.ps1` runs under `pwsh -NoProfile -File` (or `powershell`). A first element with a path separator is a file below the root; a bare name is looked up on PATH (`bash` and `pwsh` through the same lookup as scripts), and the path the check found is the one that is started. |
| `args` | list of strings | Presets only: replaces the preset's default arguments. For the suite and the other in-process presets: options of that command. |
| `needs` | list of tool names | Looked up before the first step. The first element of `run` is always needed. |
| `env` | `{ NAME = "value" }` | Merged over the inherited environment, for this step only. |
| `timeout` | ms, `"30s"`, `"2m"`, `"1h"` | Deadline of a process step (default 10 minutes). At the deadline the whole process tree is killed and the step is red. An in-process preset takes none (an error): it cannot be killed, the suite has its own `timeouts`. |
| `when` | `{ os = { "windows", "linux", "macos" } }` | Only on these systems; elsewhere the step is `skipped` and the run stays complete. |
| `stamp` | boolean | `suite` only: write the green stamp (`testing stamp`, default `true`) or not. |

Placeholders, in `run`, `args` and `env` values: `${root}` (the project root) and `${deps.<name>}` (a dependency
found like `deps` of `.testing.lua`: `$<NAME>_DIR`, `.deps/<name>`, a sibling checkout, ...). Nothing else.

**Every problem in the section is an error** (exit `2`): an unknown key, a typo in a step, an unknown preset, a
profile cycle, a name that is neither a profile, a step nor a preset, `env` names that differ only in case (one
variable on Windows), a `timeout` on an in-process preset, an option in a suite step's `args` that runs no suite
(`--help`, `--cache-clear`, `--list`, `--dry-run`, `--watch`). Elsewhere in `.testing.lua` a bad key is a warning and
the default stays; a pipeline with a typo must not run green.

Also refused before anything runs (exit `2`): a relative `run` path that leaves the root (`../x.sh`; use an absolute
path or `${deps.<name>}`), and an argument with a character cmd.exe interprets (`& | < > ^ % ! "`) for a step whose
command is a batch file (`.bat`/`.cmd` run through cmd.exe, whose quoting libuv does not do).

**Trust.** The `ci` section is part of `.testing.lua`, which runs as code anyway (the same trust as the project's
specs). Its steps add no shell (argv only; `${root}` and `${deps.<name>}` are the only placeholders, expanded once).
Process steps inherit the environment of `testing ci` with the step's `env` on top, as `scripts/ci.sh` did: the
tools a step runs (luacheck needs `LUA_PATH`) are not child editors, so the allowlist of `testing.child` does not
apply to them.

## Presets

| Preset | Runs | Needs |
| --- | --- | --- |
| `stylua` | `stylua --check .` (`--check` is fixed, `args` replaces `.`: a step never turns into a formatter) | `stylua` |
| `luacheck` | `luacheck --formatter plain --codes .` (`args` replaces `.`) | `luacheck` |
| `suite` | the suite, in this process (`testing stamp <root>`, or `testing run` with `stamp = false`) | |
| `conformance` | `testing conformance <root> --gate` in this process (a gate: without `--gate` it only reports) | |
| `surface` | `testing surface <root>` in this process | |
| `budget` | `testing budget <root>` in this process | |

The in-process presets do not start `nvim -l` inside `nvim -l`: they run through `testing.cli` in the same process
and with the same services. The suite step is green only when its Result-IR says so: exit `0` without a result is
`infra` ("the suite wrote no result"), and a `--json` file left from an earlier run is not read. Options after `--` go to the `suite` step: `testing ci -- --jobs 4` (an error when no
suite step is selected). An option that selects part of the suite (`--file`, `--filter`, `--tags`, `--shard`,
`--changed`, ... the ones `testing stamp` refuses) makes the whole run **partial**: no sentinel, and the document
says `partial_why = "suite options"`. A stamping suite step then runs as a plain run (a selection cannot earn a
stamp), so `testing ci --step=suite -- --file TESTS/x_spec.lua` checks one file.

A green suite whose own verdict is `green-partial` (a skipped case, an accepted flaky case, a stop) also makes the
run partial (`partial_why = "suite green-partial"`); a stamping step then writes no stamp and says so ("no stamp:
the suite is green-partial"), it is not red. Options after `--` that run no suite (`--cache-clear`, `--help`,
`--list`, ...) are refused with exit `2`.

**The suite never touches your real state.** Whoever starts `testing ci` (a terminal, the hook, the editor, a
runner), the `suite` step runs with `XDG_STATE_HOME` and `XDG_CACHE_HOME` pointing at a scratch directory that is
removed afterwards (the step's own `env` wins), so a spec never writes into the real `stdpath("state")` or
`stdpath("cache")`. The document and the stamp are placed below the real state directory before that
(`--state-dir`, default `stdpath("state")`).

A repository whose specs need more than that (a throwaway `NVIM_APPNAME`, a long `TEMP`) runs `testing ci` through its
`scripts/test.sh` (testing.nvim itself: `scripts/test.sh ci`), so the in-process suite gets the same
environment as a plain run. Such a wrapper asks for the real `stdpath("state")` before it isolates and passes it
as `--state-dir=<dir>`: the document and the suite's stamp go there (they would be lost with the scratch
directory), while the suite's own history stays isolated. A shared cache (`TESTING_CACHE_HOME`) reaches the suite
with `scripts/test.sh ci -- --cached`.

## A run

- The profile is `--profile`, else `ci.default`. `--step=a,b` runs only those steps: a **partial** run, which never
  prints the sentinel and is marked `partial` in the document.
- Before the first step every tool of the selected steps is looked up. A missing tool or dependency is exit `3`
  and nothing runs; the message names the step, the tool and where it was searched.
- Steps run one after the other, **fail-fast**: after a red step the rest is `skipped`. `--keep-going` runs every
  step and reports all red ones (one run, all findings).
- Process steps stream their output line by line. A deadline ends the whole process tree
  (`lib.nvim.system.job`, `kill_tree`): POSIX process group, Windows `taskkill /T`.
- A run is also partial when every step was skipped for this system (`no step ran on <os>`) and when the working
  tree changed during the run (a step wrote files: `tree_changed`).
- The processes `testing ci` starts itself (git facts, tool versions) are started together, not one after the other.

## Verify: is this state already proven?

```
testing ci verify [--profile=<name>] [--json] [--allow-dirty] [--max-age=<7d>] [--state-dir=<dir>] [--root=<dir>]
```

Nothing is run. `verify` reads `ci-<profile>.json` (the last complete run of the profile) and compares it with now:
the tree (`HEAD^{tree}`: a rebase or a reworded commit keeps the proof), the system, Neovim, the hash of the
resolved pipeline and the version of every tool of the profile. The suite is asked last, through `testing verify`
on its stamp ([CLI.md](CLI.md#stamp-and-verify)), which brings the trust levels of a stamp along (a local stamp is
no proof in CI, `--require-hmac`).

| Answer | Meaning | Exit |
| --- | --- | --- |
| `verified` | same tree, system, Neovim, pipeline and tools, the suite's stamp verifies; the last line is `TESTING_CI_OK` | `0` |
| `changed` | another tree (or the suite's stamp says `changed`); `run again:` names the steps that must run | `1` |
| `rejected` | Neovim, the pipeline, a tool version or the system differs, or a tool is missing | `1` |
| `dirty` | `git status` is not empty (`--allow-dirty` overrules, explicitly) | `1` |
| `expired` | the proof is older than `--max-age` (default `7d`) | `1` |
| `untrusted`, `partial`, `invalid`, `no-stamp` | as for `testing verify`; `no-stamp` is also: no complete run of this profile yet | `1` |

`invalid` also covers a document that is no proof: red, partial, on a dirty tree, or a tree that changed during the
run. `--json` prints the document `testing-ci-verify/1` (`status`, `verified`, `profile`, `tree`, `proof_tree`,
`suite`, `reasons`, `rerun`). A usage error is `2`, an internal failure `3`.

**A change no spec can see** (a README, a docs file) changes the tree but not the suite's stamp: `verify` says
`changed` with `suite: verified` and `rerun` without the suite, and `testing ci --reuse` then skips the suite
(`reused: its stamp verifies`) and runs the other steps, so the new tree is proven within seconds. `--reuse` never
skips a suite whose stamp does not verify, and a suite with options after `--` always runs.

## The pre-push hook

```
testing ci hook install [--run=<profile>] [--verify=<profile>] [--root=<dir>]
testing ci hook remove [--root=<dir>]
```

`install` writes `pre-push` into the hooks folder git uses for the repository (a worktree, `core.hooksPath`), `remove`
deletes it. The hook computes no verdict of its own:

1. `testing ci verify [--profile=<verify>]`. A state that is already proven ends the hook with exit `0`, in a tenth of
   a second, without a step.
2. Otherwise `testing ci --profile=<run> --reuse` (default `fast`). Its exit code is the hook's: a red pipeline blocks
   the push, and an unchanged suite is not run again (`--reuse`).

`git push --no-verify` skips the hook. It finds testing.nvim without any Neovim configuration: `$TESTING_NVIM_DIR`,
`<repo>/.deps/testing.nvim`, `<repo>/../testing.nvim`, then the checkout `install` ran from. Both profiles must exist
in the `ci` section, or `install` refuses (exit `2`) and writes nothing.

The hook proves `HEAD`, not the refs a push names (git hands those on stdin; they are ignored). It runs the `--run`
profile, which writes `ci-<run>.json`, while `verify` asks for the `--verify` profile (default `ci.default`): to make
the second push of the same state pass at once, install with `--verify=<run>` or run the default profile once.

A pre-push hook that is not ours is never overwritten or removed (exit `1`). The hook of `:MyPlugins ci hook`
(mark `# MyPlugins ci pre-push hook`) is recognised and replaced; `remove` takes it away as well.

## In the editor

```
:Testing ci [<profile>] [--step=<a,b>] [--keep-going] [--reuse] [--root=<dir>]
:Testing ci status | verify | hook install | hook remove
```

The same pipeline, from Neovim, without ever blocking it. `:Testing ci` starts `testing ci --no-agent` in a headless
child (a step that hangs cannot take the session down), streams its output into the buffer `testing-ci://<repo>` (a
split opens, with the cursor in it, when it is not visible; a second `:Testing ci` while one runs shows that run instead of starting another; one `== <step>` section per step) and, when the child ends, reads back the document
`testing-ci/1` it wrote: the verdict is notified, and a red run fills the quickfix list with the findings of the red
steps (a red step without findings gets a text-only entry with its reason). The list opens only on red. One pipeline
runs per project at a time. `<profile>` and `--step=` complete from the project: the names come from `testing ci list
[--json]`, which runs in a child, so the editor never executes `.testing.lua` on a keypress.

`:Testing ci status` shows the last result (one line per step, the findings) and says `stale` when the tree changed
since. `verify` and `hook` run the driver's subcommands of the same name and show their text.

**Statusline.** `require("testing.ci.editor").statusline()` returns `ci: ✓ full @abc1234`, `ci: ✗ luacheck`, `ci: ~ fast`
(green but partial), `ci: ! infra`, `ci: … full` while a run goes, and appends `stale` when the tree is no longer the one
the result was for. It reads a cache and blocks on nothing: every 5 seconds (`editor.REFRESH_AFTER`) and after a run it re-reads
the document and asks git for the tree of HEAD in the background, so a run in a terminal, a commit or the pre-push hook
show up (uncommitted changes do not make a result stale; `ci verify` says `dirty`). Completion never waits for
`testing ci list` either: the first <Tab> after `.testing.lua` changed starts it, the next one has the names.

**Progress.** A run shows a progress indicator (`lib.nvim.progress`, in whatever style it resolves to; nothing for a
run under 150 ms): the step that just started and how many steps went, out of the profile's steps once `testing ci
list` has been asked for them (or the steps of `--step=`). It ends with `green`, `partial` or `failed`. Not part of
this version: the terminal.nvim view.

## Several repositories

```
testing ci --repos=<a,b> | --repos-root=<dir> | --repos-file=<list>
           [--repos-include=<names>] [--repos-exclude=<names>] [--refresh]
           [--force] [--jobs=<n>] [--profile=<name>] [--keep-going] [--reuse] [--state-dir=<dir>]
           [--json=<file>]
```

The pipelines of several repositories, one after the other. Every repository is a child process of its own, so
pipelines never share a Neovim, a global or a working directory. For each one `testing ci verify` runs first: a repository
whose state is already proven is **skipped** (`--force` runs it anyway), otherwise `testing ci` runs. After a change in
a library that is the big saving: only the repositories whose proof broke run again. Output is streamed line by line with
the repository's name in front, and every change of a repository's state is a line of its own,
`ci repos: [<done>/<total>] #<index> <event> <name>` (`verify`, `run`, then `proven`, `green`, `red`, `error` or
`infra`; `#<index>` tells apart two repositories with the same directory name); at the end there is one row per repository (`proven`/`not proven`/`forced`, the result,
the time) and a verdict line `ci repos: GREEN 3/3 (2 proven, not run)`. The exit code is the worst single result
(`0` green or proven, `1` red, `2` a usage or pipeline error, `3` infrastructure); the last line of an all-green run is
`TESTING_CI_OK`. `--json=<file>` writes the rows as the document `testing-ci-repos/1`: `verdict`, `exit`, `profile` and
`repos`, one entry per repository with `name`, `dir` (absolute), `verify`, `state` (`skipped` for a proven one),
`code`, `ms` and `doc`, the `testing-ci/1` its run wrote (`null` when it did not run or wrote none).

Which repositories: an explicit list (`--repos`, a list file with one directory per line), or every directory directly
below a root (`--repos-root`, repeatable) whose `.testing.lua` has a `ci` section. That detection is textual (the file is
not executed by the multi-repository run), cached in the state directory and rebuilt by `--refresh`; `--repos-include`
and `--repos-exclude` narrow it by directory name (an included name that does not exist is still asked for, and fails
loudly). `--jobs=<n>` (1 to 16) runs that many repositories at the same time.

From the editor, the repositories are a setting, not a hard-wired list:

```lua
require("testing").setup({
  ci = { repos = { roots = { "$REPOS_DIR" }, include = {}, exclude = { "scratch" } } },
})
```

`:Testing ci repos [--force] [--jobs=<n>] [--profile=<name>] [--refresh] [--keep-going] [--reuse] [--repos-root=<dir>]`
runs them in one child and streams the output into the buffer `testing-ci://repos-<hash>`. At the top of that buffer a
table follows the run (one row per repository with its state, `(n not started yet)` below), with a progress indicator
alongside; when the child ends, the table is rewritten from its document (verify, result, time per repository), the
verdict names the repositories that are not green, and their findings fill the quickfix list, each entry with the
repository's name in front (a repository without findings gets a text-only entry with its state and exit code). The
list opens only on red.

## Reports and findings

A process preset has an **error format** (Vim's `errorformat` items `%f` (a file name, no blanks), `%l`, `%c`, `%m`
and `%%`; any other item is an error; several alternatives per preset): `luacheck` `%f:%l:%c: %m`, `stylua`
`Diff in %f:`. Each output line is matched as it arrives, and the **findings** (file, line, column, text; at most
200 are listed, all are counted) go into the document. The suite's findings come from its Result-IR (one per case
that is not green, at the failed assertion, with the first line of its message), so they do not depend on the
reporter the suite printed with; a `--json` of yours after `--` is used for that, otherwise a temporary one. A
repository step has no error format and no findings, only its last output lines.

| Report | Shows |
| --- | --- |
| terminal (default) | the step output as it comes (`== <step>` before, `-- <step>: <state> (<duration>)` after), then one row per step, the verdict line and, after a complete green run, `TESTING_CI_OK` |
| `--agent` | the verdict as the first line (`ci GREEN full 4/4`, `ci RED luacheck (2 findings) exit 1`; `ci PARTIAL ...` for a `--step` run, a suite selection or a HEAD that moved, never `GREEN`), then only what needs a look: per red step its findings, or its last output lines. Nothing is streamed. Chosen by default in an agent environment (`TESTING_AGENT=1`, `CLAUDECODE=1`, ..., as for a run); `--no-agent` forces the terminal report |
| `--junit=<file>` | JUnit XML: one `testsuite` per step, its findings as failed `testcase`s (the step's reason in each body, one more testcase counts the findings over the cap), a skipped step as `skipped` |
| `--json=<file>` | a copy of the document `testing-ci/1` (below) |

## Exit codes

The worst step decides: `0` every step green (or skipped for this system), `1` a step red (also a timeout; a
process step's own exit code other than 0 is red), `2` a usage or pipeline error, or an in-process step that ended
with `2` (state `error`), `3` a missing tool or dependency, a step that could not start, or an in-process step that
ended with `3` (state `infra`), and a report (`ci.json`, `--json`, `--junit`) that could not be written. The last
line of a complete green run is `TESTING_CI_OK`; never after a partial run, and never when HEAD moved during the run.
The headline names the step that decided the exit code. See [EXIT-CODES.md](EXIT-CODES.md).

## The document `testing-ci/1`

Written after every run to the project's state directory (`ci.json` beside `runs.jsonl`, see [STATE.md](STATE.md)),
canonical JSON, under the state lock; `--json=<file>` writes a copy. That includes a run that stopped before its first
step (verdict `error` or `infra`, its `problems`, no steps), so an old green document never stays behind. A
complete run (all its steps, not partial) is also `ci-<profile>.json`: the last complete run of that profile, which a
`--step` run or another profile never replaces.

```json
{
  "schema": "testing-ci/1",
  "repo": "testing.nvim", "commit": "<sha>", "tree": "<HEAD^{tree}>", "dirty": false, "head_moved": false,
  "os": "windows", "profile": "full", "partial": false, "partial_why": null, "suite_args": [],
  "verdict": "green", "exit": 0, "first_red": null,
  "nvim": "0.12.2", "pipeline_sha": "<sha256 of the resolved pipeline>", "time": "2026-10-28T12:00:00Z",
  "steps": [
    { "name": "stylua", "state": "green", "exit": 0, "ms": 412, "tool_version": "stylua 2.5.2", "reason": null,
      "errors": [], "findings": [], "findings_total": 0 },
    { "name": "luacheck", "state": "red", "exit": 1, "ms": 980, "tool_version": "Luacheck: 1.2.0", "reason": null,
      "errors": ["..."], "findings": [{ "file": "lua/a.lua", "line": 3, "col": 7, "text": "(W211) unused variable 'x'" }],
      "findings_total": 1 }
  ]
}
```

`commit`, `tree` and `dirty` are taken before the first step (`null` when unknown: no git, not a repository);
`head_moved` is true when HEAD changed during the run, `tree_changed` when the working tree did; `deciding` is the
step that decided the exit code; `write_errors` lists reports that could not be written. `verdict` is `green`, `green-partial` (`--step` or a suite
selection, `partial_why` says which), `red`, `error` (exit 2) or `infra` (exit 3). A step's `state` is `green`,
`red`, `skipped`, `error` or `infra`; `errors` holds up to 20 of its last output lines.

**Transition.** Where git ignores `.ci-last.json`, a complete run also writes it in the old format of
`scripts/ci.sh` (`repo`, `commit`, `dirty`, `time`, `state`, `note`), so readers of that file keep working. Where
git does not ignore it, nothing is written: a run never makes the tree dirty.
