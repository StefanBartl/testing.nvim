# `testing ci`: the pipeline of a repository

`testing ci` runs the whole check pipeline of a repository on this machine: formatting, lint, the suite,
conformance, whatever else the repository checks. One definition in the `ci` section of `.testing.lua`, the same
exit codes as a run, no cloud, no container, no shell scripts that copy each other.

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

A repository whose specs need an isolated state and cache directory runs `testing ci` through its
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

A pre-push hook that is not ours is never overwritten or removed (exit `1`). The hook of `:MyPlugins ci hook`
(mark `# MyPlugins ci pre-push hook`) is recognised and replaced; `remove` takes it away as well.

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
