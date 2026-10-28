# `testing ci`: the pipeline of a repository

`testing ci` runs the whole check pipeline of a repository on this machine: formatting, lint, the suite,
conformance, whatever else the repository checks. One definition in the `ci` section of `.testing.lua`, the same
exit codes as a run, no cloud, no container, no shell scripts that copy each other.

```
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ci [--profile=<name>] [--step=<a,b>] [--keep-going]
                                                              [--json=<file>] [--root=<dir>] [-- <suite options>]
```

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
profile cycle, a name that is neither a profile, a step nor a preset. Elsewhere in `.testing.lua` a bad key is a
warning and the default stays; a pipeline with a typo must not run green.

## Presets

| Preset | Runs | Needs |
| --- | --- | --- |
| `stylua` | `stylua --check .` | `stylua` |
| `luacheck` | `luacheck --formatter plain --codes .` (`args` replaces `.`) | `luacheck` |
| `suite` | the suite, in this process (`testing stamp <root>`, or `testing run` with `stamp = false`) | |
| `conformance` | `testing conformance <root>` in this process | |
| `surface` | `testing surface <root>` in this process | |
| `budget` | `testing budget <root>` in this process | |

The in-process presets do not start `nvim -l` inside `nvim -l`: they run through `testing.cli` in the same process
and with the same services. Options after `--` go to the `suite` step: `testing ci -- --jobs 4` (an error when no
suite step is selected). An option that selects part of the suite (`--file`, `--filter`, `--tags`, `--shard`,
`--changed`, ... the ones `testing stamp` refuses) makes the whole run **partial**: no sentinel, and the document
says `partial_why = "suite options"`.

## A run

- The profile is `--profile`, else `ci.default`. `--step=a,b` runs only those steps: a **partial** run, which never
  prints the sentinel and is marked `partial` in the document.
- Before the first step every tool of the selected steps is looked up. A missing tool or dependency is exit `3`
  and nothing runs; the message names the step, the tool and where it was searched.
- Steps run one after the other, **fail-fast**: after a red step the rest is `skipped`. `--keep-going` runs every
  step and reports all red ones (one run, all findings).
- Process steps stream their output line by line. A deadline ends the whole process tree
  (`lib.nvim.system.job`, `kill_tree`): POSIX process group, Windows `taskkill /T`.

## Exit codes

The worst step decides: `0` every step green (or skipped for this system), `1` a step red (also a timeout; a
process step's own exit code other than 0 is red), `2` a usage or pipeline error, or an in-process step that ended
with `2` (state `error`), `3` a missing tool or dependency, a step that could not start, or an in-process step that
ended with `3` (state `infra`). The last line of a complete green run is `TESTING_CI_OK`; never after a partial
run, and never when HEAD moved during the run. See [EXIT-CODES.md](EXIT-CODES.md).

## The document `testing-ci/1`

Written after every run to the project's state directory (`ci.json` beside `runs.jsonl`, see [STATE.md](STATE.md)),
canonical JSON, under the state lock; `--json=<file>` writes a copy.

```json
{
  "schema": "testing-ci/1",
  "repo": "testing.nvim", "commit": "<sha>", "tree": "<HEAD^{tree}>", "dirty": false, "head_moved": false,
  "os": "windows", "profile": "full", "partial": false, "partial_why": null, "suite_args": [],
  "verdict": "green", "exit": 0, "first_red": null,
  "nvim": "0.12.2", "pipeline_sha": "<sha256 of the resolved pipeline>", "time": "2026-10-28T12:00:00Z",
  "steps": [
    { "name": "stylua", "state": "green", "exit": 0, "ms": 412, "tool_version": "stylua 2.5.2", "reason": null, "errors": [] }
  ]
}
```

`commit`, `tree` and `dirty` are taken before the first step (`null` when unknown: no git, not a repository);
`head_moved` is true when HEAD changed during the run. `verdict` is `green`, `green-partial` (`--step` or a suite
selection, `partial_why` says which), `red`, `error` (exit 2) or `infra` (exit 3). A step's `state` is `green`,
`red`, `skipped`, `error` or `infra`; `errors` holds up to 20 of its last output lines.

**Transition.** Where git ignores `.ci-last.json`, a complete run also writes it in the old format of
`scripts/ci.sh` (`repo`, `commit`, `dirty`, `time`, `state`, `note`), so readers of that file keep working. Where
git does not ignore it, nothing is written: a run never makes the tree dirty.
