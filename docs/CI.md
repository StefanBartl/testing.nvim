# `testing ci`: the pipeline of a repository

`testing ci` runs the whole check pipeline of a repository on this machine: formatting, lint, the suite,
conformance, whatever else the repository checks. One definition in the `ci` section of `.testing.lua`, the same
exit codes as a run, no cloud, no container, no shell scripts that copy each other.

For how the pieces fit together (shim, editor, hook, several repositories, hosted runner) see [WORKFLOW-CI.md](WORKFLOW-CI.md).

```
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ci [--profile=<name>] [--step=<a,b>] [--keep-going] [--reuse]
                                                              [--agent|--no-agent] [--json=<file>] [--junit=<file>]
                                                              [--state-dir=<dir>] [--events=<file>] [--suite-events=<file>] [--root=<dir>] [-- <suite options>]
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
| `skip_exit` | integer 1..255 | Process steps only: the exit code with which the step says it **skipped itself** (it could not check here, e.g. a tool it needs is missing). The step is then `skipped` with its last output line as the reason, the run is **partial** (`<step> skipped itself`: no proof, no sentinel) and the exit stays `0`. Any other non-zero exit is red. |

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

## Without writing a pipeline: the derived one

A Lua project (a `lua/` folder) that has **no `ci` section, or one without `profiles`**, gets its pipeline from what
the repository has:

| Step | When | Why |
| --- | --- | --- |
| `stylua` | `stylua.toml` or `.stylua.toml` | the project formats with stylua |
| `luacheck` | `.luacheckrc` | the project lints with luacheck (its own `include_files`/`exclude_files` decide what is read) |
| `suite` | discovery finds a spec file (`roots` and `spec_pattern` of `.testing.lua`, default `TESTS`; the same as `testing run` sees) | the project has specs |
| `conformance` | `conformance.gate = true` | the project made the conformance suite a gate |

Profiles: `fast` (stylua and luacheck, the check before a push) and `full` (all of them), `full` is the default.
`testing ci list` says where each step came from (`derived: stylua (stylua.toml)`), the document `testing-ci/1` has
`derived` (step and reason), and a derived step whose tool is missing says how to leave it out. The same files give
the same steps on every machine: only the repository is read, never the machine.

A section without `profiles` adjusts what is derived instead of replacing it:

```lua
ci = {
  skip = { "luacheck" },                                       -- leave a derived step out (opt-out)
  steps = {
    stylua = { preset = "stylua", args = { "lua", "TESTS" } }, -- a derived step defined anew
    docs = { run = { "scripts/gen_docs.sh", "--check" } },     -- a step of its own: it joins `full`
  },
},
```

`skip` names only derived steps (anything else is an error), and leaving everything out is an error. A section
**with** `profiles` is used as written, nothing is derived and `skip` is an error there. A project that is not a Lua
project, or has none of the files above, needs a section (`testing ci` says so, exit `2`). `testing ci --repos`
still picks the repositories whose `.testing.lua` has a `ci` section: running every Lua project below a root is a
decision of its own.

## Presets

| Preset | Runs | Needs |
| --- | --- | --- |
| `stylua` | `stylua --check .` (`--check` is fixed, `args` replaces `.`: a step never turns into a formatter) | `stylua` |
| `luacheck` | `luacheck --formatter plain --codes .` (`args` replaces `.`) | `luacheck` |
| `luals` | `lua-language-server --checklevel=Warning --check_format=pretty --check=. --configpath=<merged>` (`args` replaces `--check=.`, e.g. `{ "--check=lua" }`; a single file is not checked by LuaLS, name a directory; the configuration is built for the run, [below](#the-luals-preset-the-library-the-editor-gives-luals)). Never derived: a repo names it in a profile or runs `testing lint luals` | `lua-language-server` |
| `suite` | the suite, in this process (`testing stamp <root>`, or `testing run` with `stamp = false`) | |
| `conformance` | `testing conformance <root> --gate` in this process (a gate: without `--gate` it only reports) | |
| `surface` | `testing surface <root>` in this process | |
| `budget` | `testing budget <root>` in this process | |

`stylua`, `luacheck` and `luals` are also the checks of [`testing lint`](#testing-lint-the-linters-on-the-changed-files):
each carries a `lint` descriptor (`files`: the tool takes the files to check, else it checks the whole workspace and
the findings are filtered; `fix`: the command `--fix` runs, only `stylua`; `ext`: the files it reads, `lua`;
`on_save = false`: never on save, `luals`). One description of a linter for the pipeline, the command line and the
editor.

### The `luals` preset: the library the editor gives LuaLS

`lua-language-server --check` reads only the `.luarc.json` of the workspace. The editor reads it too, but on top of
what its LSP setup injects: the Neovim runtime, LuaLS' own meta libraries and the `lua/` folder of every plugin the
code requires. Without that, `vim` is an undefined global and every type of a dependency is unknown: thousands of
findings the editor never shows (testing.nvim: about 6250, against 180 with the library). So every run of the preset
(a `testing ci` step, `testing lint luals`) writes a merged configuration into the project's state directory
(`stdpath("state")/testing/<project>-<hash>/luals.luarc.json`, below `--state-dir` when one is given) and passes it with
`--configpath=<file>`:

- **the keys of the repository's own file** (`.luarc.json`, else `.luarc.jsonc`), kept as they are. Comments and
  trailing commas are accepted; a key may be written flat (`"workspace.library"`), nested
  (`"workspace": { "library": ... }`), with or without the `Lua.` prefix, the forms LuaLS reads itself;
- **`workspace.library`**, when the repository does not set it: `$VIMRUNTIME/lua`, `${3rd}/luv/library`,
  `${3rd}/busted/library`, `${3rd}/luassert/library`, and `<dir>/lua` of every dependency the runner resolves for the
  project: the `deps` of `.testing.lua` (found the way `deps` are, docs/CONFIG.md) and lib.nvim, which the runner
  always needs. Never the project itself (LLS-02: a library is foreign code), never the root of a dependency (its
  `TESTS/` would answer a `require("harness")` of this project);
- **`workspace.ignoreDir`**: the repository's entries and `.claude`, `.deps`, `.git` (places that hold copies of
  the workspace).

A repository that sets `workspace.library` itself keeps it unchanged, and the step output says so: the key
**replaces** what an editor injects, so what the check sees is then the repository's responsibility (rule LLS-01:
a `.luarc.json` does not set `workspace.library`). A step whose own `args` name a `--configpath` keeps it. A missing
`$VIMRUNTIME` (the check runs from Neovim: `testing ci`, `testing lint`) or a dependency that cannot be found is a
problem of the run, exit `3`, never a smaller library; a `.luarc.json` that is no JSON is exit `2`. The step output
names the library (`library: $VIMRUNTIME/lua, ${3rd} luv busted luassert, lib.nvim; ignoreDir: ...`), and
`testing lint --json` carries it as the check's `notes`.

A `luals` step takes about a minute on a repository of this size (the runtime is indexed every time), so it does not
belong in a profile that runs before every push. testing.nvim keeps it in a profile of its own,
`strict = { "full", "luals" }`, next to `full` (the pre-push hook and the proofs) and `fast`:
`testing ci --profile=strict` is the whole pipeline with the LuaLS diagnostics held at zero.

**Another repository to zero** (the fleet): no `workspace.library` in its `.luarc.json` (only `runtime.version`,
`workspace.checkThirdParty`, `workspace.ignoreDir` and its own diagnostics settings), every plugin it requires as a
dependency in `deps` of `.testing.lua`, then `testing lint luals --all` until it reports nothing (the measurement
is noisy: two runs in a row at zero, LLS-06/07), and a profile `strict = { "full", "luals" }` that keeps it there.
The findings themselves are worked off with the rules of the LuaLS diagnostics (LLS-01 .. LLS-46 of the rules vault).

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
(`--state-dir`, default `stdpath("state")`). The trace folders of a child that timed out or crashed (`testing-traces/<run>`,
[CHILD.md](CHILD.md)) are moved from the scratch directory to the real `stdpath("state")/testing-traces` before it
is removed (a folder of the same name there is filled file by file). A suite step whose own `env` sets
`XDG_STATE_HOME` keeps its traces where it put them.

A repository whose specs need more than that (a throwaway `NVIM_APPNAME`, a long `TEMP`) runs `testing ci` through its
`scripts/test.sh` (testing.nvim itself: `scripts/test.sh ci`; the `scripts/test.sh` that `testing init` writes has
the verb too, with `ci verify`, `ci list` and `ci hook` passed through), so the in-process suite gets the same
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
run under 150 ms): the step that just started, step n of m. The editor starts the run with `--events=<file>` and reads
the [events of the run](#events-of-a-run) while it goes, so the count needs no plan. It ends with `green`, `partial`
or `failed`. Not part of this version: the terminal.nvim view.

**A quiet suite, and a line that says what is going on.** The `step_start` of the suite step names the file of the
suite's own events ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#events-stream)); the editor reads it while the suite goes.
The progress indicator says `suite 12/187` (spec files done of selected), and the **last line of the buffer** is a
status line that changes every second, so a step that is quiet for minutes does not look dead:
`   ... suite: 12 of 187 spec files done, now TESTS/x_spec.lua (1:30)`, or `   ... luacheck is running (0:04)`. It is
removed when the run ends. The buffer shows the header `== suite`, the verdict line `-- suite: ...` and right after
it `   <n> spec file(s), <m> case(s)` (with `, <k> failed` when cases failed; no such line for a suite reused from its
stamp or skipped), but not what the specs print themselves (a spec may print anything: a table, a line without an end of
line, a progress meter). Those lines are kept aside; when the run is not green, the last 40 of them follow under
`-- the last n line(s) the suite printed:`. A line longer than 400 characters is cut and says how much was left out.
The terminal (`testing ci`) shows everything as before.

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

## The GitHub Actions status: `testing ci remote`

```
testing ci remote [<root>...] [--repos-root=<dir>] [--json] [--workflow=<name>] [--state-dir=<dir>]
```

The latest GitHub Actions run of the CI workflow per repository, one cell per system. It runs nothing locally and
never fetches: it asks GitHub about the commit the last `git fetch` brought.

Per repository:

1. `owner/repo` from `git remote get-url origin` (`https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
   `ssh://git@github.com/o/r`); any other host, or no `origin` remote, is `no_github`. A git that cannot read the
   directory (not a repository, "dubious ownership", no git, a timeout) is `unknown` with git's message, also below
   `--repos-root`: such a repository is never left out of the count.
2. The commit: the head of `origin/<branch>` (`ci_remote.branch`, default `main`). Not "the newest run of the branch":
   a fast-forward push of a commit that already ran elsewhere does not always get a second run, and the newest run of
   `main` is then an older commit's verdict.
3. `GET /repos/<o>/<r>/actions/runs?head_sha=<sha>&per_page=20`, only the runs whose workflow is named
   `ci_remote.workflow` (default `CI`, compared without case: `ci` is the same; `--workflow` overrides it for every
   repository), the newest by `created_at`. A
   path-filtered sibling workflow (`pages`, `release-engine`) can be created after the CI run for the same push and must
   not become the verdict.
4. `GET .../runs/<id>/jobs`: each job goes to the cell `ubuntu`, `windows` or `macos` by its name, else, on a
   self-hosted runner, by its labels (`Linux` counts as ubuntu), or to `other` (a hosted stylua, luacheck or publish
   job: its `ubuntu-latest` image says nothing about the ubuntu leg). A job whose name contains a
   `ci_remote.non_gating` text (default `nightly`) is listed under `non_gating` and never decides.

States, worst first; a cell has the worst state of its jobs, the repository (`overall`) the worst of its cells:

| State | When |
| --- | --- |
| `failure` | a job failed or timed out (or the run concluded `failure` although no job did) |
| `rejected` | a run that failed (`failure`, `startup_failure`, no conclusion) with **zero jobs**: GitHub found the workflow file invalid and started nothing. Counting red jobs would read it as a pass |
| `cancelled` | a job was cancelled, or the run was cancelled before any job started (often `cancel-in-progress`: a newer run took over) |
| `unknown` | no token, no network, an API error (a redirect too: a renamed repository), git could not read the directory, an answer that is not one, a run without a job that is neither failed, cancelled nor skipped (`action_required`), a run with only non-gating jobs: never green |
| `waiting_runner` | a job queued on a `self-hosted` runner for longer than 2 minutes: the runner is off |
| `queued`, `running` | the run is not done |
| `success` | every job of the cell succeeded (skipped ones do not count against it) |
| `skipped` | every job skipped, or a head commit with `[skip ci]` (and the like) without a run |
| `no_run` | no run of the workflow for the commit |
| `no_github` | the origin is not on GitHub |

The table (one row per repository: repo, with the directory in front when it is named otherwise, ubuntu, windows,
macos, note; `ok`, `FAIL`, `no-runner`, `-` for a cell
without a job, `!` for a rejected run, `?` for unknown) ends with `fully green: <n> / <total>`. `--json` prints the
document `testing-ci-remote/1` instead: `schema`, `generated_at`, `token_source` (`env:TESTING_GITHUB_TOKEN` or `gh`,
never the token) or `token_error`, `workflow` (the `--workflow`), and `repos`, sorted by name, each with `repo`, `owner`,
`dir`, `branch`, `workflow`, `sha`, `overall`, `run` (`id`, `url`, `status`, `conclusion`, `created_at`, `updated_at`,
`event`, `attempt`), `os` (per cell `state`, `url` and `job`: the job that decided it), `non_gating`, `note`, `error`
and `config_error`. Keys are sorted and the same answers give the same bytes.

**Which repositories.** The roots named on the command line (default: the current directory), and with
`--repos-root=<dir>` (repeatable) every directory directly below `<dir>` that has a `.github/workflows` directory and a
GitHub origin; a name containing `vault` is left out (notes, tasks, rules: no code). lib.nvim counts, it has workflows
(no `.testing.lua` needed). A repository's `.testing.lua` is loaded for its `ci_remote` section when it has one
(workspace trust applies: an untrusted one keeps the defaults and says so in `config_error`).

**The token.** `$TESTING_GITHUB_TOKEN`, a fine-grained token that can only read (repository permissions *Actions:
read* and *Metadata: read*), else `gh auth token`. Never `GITHUB_TOKEN`: it is not read, and it is taken out of the
environment of `gh` (which would print it back). The token goes to curl through its configuration on stdin, never on
a command line, and appears in no output, no document, no cache file and no error. Without a token every repository
that needs GitHub is `unknown` and the exit code is `3`.

**Cache.** Per checkout `<state>/testing/ci-remote/<owner>_<repo>_<dir hash>.json` (`--state-dir`, default
`stdpath('state')`; two checkouts of one repository keep their own) holds the ETags and the last answers (only the fields used). The runs are asked with `If-None-Match`: a `304` reuses
the stored answer and does not count against the rate limit. The jobs of a completed run whose `updated_at` did not
change are not asked again at all; an open run's jobs are asked again, conditionally. Offline, a repository is
`unknown`, never its stored state.

Exit codes: `0` nothing red, `1` a repository is `failure`, `rejected` or `cancelled`, `2` usage, `3` a repository
could not be fetched ([EXIT-CODES.md](EXIT-CODES.md)).

## Fleet overview: `testing ci overview`

```
testing ci overview [<root>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>] [--out=<file.html>]
                    [--json] [--no-remote] [--state-dir=<dir>]
```

One static HTML page of many repositories: per repository the local state and the latest GitHub Actions run per
system, with a link to the run. It **only reads** and never starts a pipeline or a suite. That is the difference to
`testing ci --repos-root` ([Several repositories](#several-repositories)), which runs every repository that is not
proven (minutes per repository).

Per repository it reads three things:

1. The answer of `testing ci verify --json` ([Verify](#verify-is-this-state-already-proven)), asked in the same process
   (git facts and tool versions, as `verify` reads them; no step runs). The only processes it starts are `git` and the
   `--version` of a profile's tools; the CI adapter asks `gh auth token` for a token. `verify` runs the repository's
   `.testing.lua`, and its suite answer puts the repository on `'runtimepath'` and sets the cache's project key: both
   are restored after each repository, so one repository's modules never reach the next.
2. `ci.json` and `ci-<profile>.json` in the repository's state directory (the last `testing ci` and the last complete
   run of the profile, [the document](#the-document-testing-ci1)).
3. The CI adapter of `testing ci remote` ([above](#the-github-actions-status-testing-ci-remote)): the same token, ETag
   cache and states. `--no-remote` skips it (offline): the CI columns are then `?`.

A repository whose state cannot be read (a broken file, a source that fails) is `unknown` with the reason in its note;
the page is written all the same.

The local column:

| State | When |
| --- | --- |
| `proven` | `ci verify` says `verified`; the age is that of the proof (`ci-<profile>.json`) |
| `red` | the last run (`ci.json`) or the last complete run of the profile (`ci-<profile>.json`) was red (a later green partial run does not undo it; of two red ones the newer counts, also for the age); the note names the first red step (and the profile for the complete run) and says `(an older tree)` when the tree changed since, `(tree unknown)` when git cannot tell (the page reads `HEAD^{tree}` itself when `verify` did not) |
| `unknown` | anything else, with the answer of `ci verify` (`no-stamp`, `changed`, `dirty`, `rejected`, ...) and its first reason |
| `no testing.nvim` | the repository has no `.testing.lua` (lib.nvim: CI only) |

A run of several repositories (`testing ci --repos-root`) does not write each repository's state; such repositories are
`no-stamp` here until a `testing ci` ran in them.

**Which repositories.** The roots named (default: the current directory) and, below each `--repos-root` (repeatable),
the repositories with `.github/workflows` (as `testing ci remote --repos-root` finds them; one without a GitHub origin
is listed too, as `no GitHub`), those `testing ci --repos-root` finds (a `ci` section in `.testing.lua`, read uncached)
and every other one with a `.testing.lua` (a suite without a pipeline). The named-roots registry of the concept is not
read: a repository outside every `--repos-root` is named as a root. A name containing `vault` is
left out (tasks-vault, rules-vault, tricentis-vault: notes, no code; the last one is company context). Then
`ci_overview.include` (default `{ "lib.nvim" }`: it has no `.testing.lua`) and `--include=<a,b>` are taken in even when
the detection misses them (an included vault is taken in too), and `ci_overview.exclude` and `--exclude=<a,b>` are left
out. Both take directory names only (no separator, no `..`; otherwise exit `2`), as `ci_overview` does. `ci_overview` is read from the `.testing.lua` of the current directory ([CONFIG.md](CONFIG.md)). The names left
out are printed (`ci overview: left out: ...`) and listed in `--json`; the page only counts them. An included name
that no `--repos-root` has is reported on stderr.

**The page.** One self-contained file: inline CSS, no script, no font, no request (its Content-Security-Policy is
`default-src 'none'`), light and dark through `prefers-color-scheme`. The header shows `generated_at` and the counts;
one row per repository, sorted by directory name: local state with its age, ubuntu, windows, macos (`ok`, `FAIL`,
`-` for a system without a job: not configured, not red), the CI run (a link) and a note. The checkbox "nur rot (red
only)" hides every row that is neither locally red nor `failure`/`rejected` on CI (CSS only). Every text is
HTML-escaped. Free texts (the notes of `ci verify` and of the adapter) are redacted as the IR redacts a case's
message, expected and actual (`testing.run.inproc.redact_text`: the roots become `<REPO>`, `<HOME>`, `<TMP>`,
`<STATE>` (the `--state-dir` of the page), then user, host, environment values and e-mail shapes), and every absolute
path that is left becomes `<PATH>` (a drive, UNC or POSIX path, also in backticks or brackets, of one part or with a
space in it; a URL such as `https://github.com/...` stays): a repository appears by its directory name only. A note
is cut after about 300 bytes, at a character boundary. Links only to `https://github.com/`. The same inputs give
the same bytes.

**Where.** `--out=<file.html>`, default `<state>/testing/overview.html` (`--state-dir`, default `stdpath('state')`);
the path is printed (`ci overview: wrote <path>`). `--json` prints the document `testing-ci-overview/1` instead
(`schema`, `generated_at`, `counts`, `excluded`, `missing`, `repos[]` with `repo`, `local` (`state`, `verify`,
`profile`, `time`, `age_s`, `note`) and `ci` (`overall`, `os.<system>.state`/`url`, `run_url`, `note`); no absolute
path), and writes the page only when `--out` is given too.

Exit codes: `0` the page was written, or with `--json` alone the document printed (also when repositories are red: it
is a report, not a gate; `testing ci remote` and `testing ci verify` are the gates), `2` usage (an unknown flag, a root
or `--repos-root` that is not a directory, an `--include`/`--exclude` that is no directory name, no repository), `3` the
page could not be written ([EXIT-CODES.md](EXIT-CODES.md)).

## Events of a run

`testing ci --events=<file>` writes what the run is doing while it goes, one JSON object per line (NDJSON, flushed after
every line, keys sorted), for a UI that shows a run without reading its terminal text (the editor, a test explorer, a
desktop app). The file is written anew by every run that starts, also by one that stops at once (a configuration
error, a `--root` that is no directory: `run_start` and `run_done`); a command line that cannot be parsed at all leaves
it untouched. Like the suite's stream it is never part of the verdict: a file
that cannot be opened or written is one note on stderr, and the run goes on.

Every line has `v` (`1`), `event` and `ts` (unix seconds).

| `event` | Fields |
| --- | --- |
| `run_start` | `profile`, `root` (directory name, never a path), `steps` (the planned steps in order; empty for a run that stops before its first step) |
| `step_start` | `step`, `index`, `total`; the suite step also `suite_events`: the file of the suite's own events (file n of m, [OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#events-stream)), `<file>.suite.ndjson` unless `--suite-events` names one; absent for a suite reused from its stamp and when the suite's own `args` or the options after `--` bring an `--events` (nothing is written next to the run's file) |
| `step_end` | `step`, `index`, `total`, `state` (`green`, `red`, `skipped`, `error`, `infra`), `ms`, `exit` (a process step), `reason`, `findings_total`. A step that never started (skipped for this system, after a red step without `--keep-going`) has a `step_end` and no `step_start` |
| `run_done` | `verdict`, `exit`, `partial_why`, `deciding`, `first_red`; a run that stopped before its first step: `verdict`, `exit`, `problems` |

The findings themselves are in the document `testing-ci/1` (`--json`), which is complete when `run_done` is there.

## `testing lint`: the linters on the changed files

```
testing lint [<check>...] [--file=<f>...|--changed|--all] [--fix] [--on-save] [--agent|--no-agent] [--json] [--root=<dir>]
:Testing lint [<check>...] [--file|--changed|--all] [--fix] [--root=<dir>]
```

The lint checks without the rest of the pipeline, for the files that changed, the current file or everything.

- **Checks**: the steps of the pipeline (written or [derived](#without-writing-a-pipeline-the-derived-one)) whose
  preset lints (`stylua`, `luacheck`, `luals`), all of them by default; a step's own `args`, `needs`, `env` and
  `timeout` apply. A named check is such a step, or a lint preset the pipeline does not have (its defaults:
  `testing lint luals` in a repository whose pipeline has no `luals` step). That fallback is only for a project
  that has no pipeline at all (no `ci` section, nothing to derive): an untrusted root or a `.testing.lua` that cannot
  be used is exit `2` with the loader's problem (and `:Testing lint` asks for trust like `:Testing ci`). Anything
  else is exit `2`.
- **Scope**: `--changed` (default) the files changed against `HEAD` plus the untracked files git does not ignore;
  `--file=<f>` this file (relative to the root, or absolute below it; outside the root is exit `2`), repeatable; a
  value that names no file is split on commas (`--file=a.lua,b.lua`), so a file with a comma in its name is still
  one file; `--all` exactly what the step checks in `testing ci` (its own `args`). The scopes exclude each other. A
  check only sees the files with one of its extensions **and below the paths of its `args`** (a step with
  `args = { "--std", "luajit", "lua" }` sees `lua/...`; `.` is everything; a path that is a file matches only
  itself): a scope is never more than `--all`. The other files are listed as `not checked by <check> (outside its
  args)` in the terminal report and as `not_checked` in the document, not as findings. Nothing to check is exit `0`
  with `lint: nothing changed (...)`.
- **How a check runs**: a check that takes files (`stylua`, `luacheck`) gets the files in place of the paths of
  its `args`; the options of its `args` stay (`luacheck --formatter plain --codes --std luajit lua/a.lua`; an
  option whose value is the next argument is known per preset). `stylua` gets `--respect-ignores` before named
  files, so `.styluaignore` applies as it does for `--all` (check and fix). `luals` checks the whole workspace
  (LuaLS checks no single file) and keeps the findings of the files in scope, compared as relative paths
  (case-insensitive on Windows); it is green only when its output held findings and none was in scope: an exit `1`
  without a single finding it could read (a crash, a configuration error) is red with its last output lines. The processes are those of
  `testing ci`: the same `needs` lookup, deadline and error format.
- **`--fix`**: a check with a fix (`stylua`) checks first, runs the fix on the files that had findings (with `--all`:
  `stylua <its args>`; with named files `stylua --respect-ignores <files>`), checks again and names the files
  that changed (`fixed: lua/a.lua`); a check without one
  (`luacheck`, `luals`) runs as usual and says `<check>: no --fix`. The exit code is what is still wrong.
- **A missing tool** skips that check with a reason that names the tool and where it was searched; the other checks
  still run, and the exit code is `3`, never `0`, also next to a red check.
- **Exit codes**, the worst wins: `0` green (or nothing to check), `1` findings, `2` usage, `3` a tool is missing or
  a check could not run.
- **Output**: the terminal report has a section per check (`== luacheck (2 files)`, its findings as
  `file:line:col: message`, `-- luacheck: red, 2 finding(s)`) and the verdict (`lint: GREEN 2/2`, `lint: RED luacheck
  (exit 1)`). `--agent` (the default in an agent environment, as for `testing ci`) prints the verdict first
  (`lint GREEN 2/2`, `lint RED luacheck (2 findings)`, `lint INFRA luals (...)`), then only the findings.
  `--json` prints the document `testing-lint/1` to stdout: `schema`, `root`, `scope` (`mode`, `files`), `fix`,
  `verdict`, `exit`, `deciding`, `problems` and per check `name`, `preset`, `state` (`green`, `red`, `skipped`,
  `error`, `infra`), `exit`, `ext`, `files` (`null` for `--all`), `findings` (`file`, `line`, `col`, `message`,
  `check`), `findings_total`, `fixed`, `no_fix`, `missing`, `nothing` (no file in scope), `not_checked`, `reason`,
  `errors`, `notes` (how the check ran: the library of `luals`).
- **`--on-save`**: the default set leaves out the checks whose preset says `on_save = false` (`luals`); this is what
  the editor's check on save runs.

**In the editor**, `:Testing lint` starts `testing lint --json` in a headless child (the editor never executes
`.testing.lua` and never waits) and, when it ends, fills the quickfix list "testing lint" with the findings (opened
only when there are some), sets `vim.diagnostic` in the loaded buffers with one namespace per check
(`testing.lint.<check>`; a checked file without findings has that check's diagnostics cleared) and notifies the
verdict. `--file` is the file of the current buffer; without a scope flag the changed files are checked. The check
names complete from the project (`testing ci list`, which lists its lint steps) and the lint presets. `--fix` is
refused while a buffer of a file in its scope has unsaved changes ("save first": the fix rewrites the file on disk);
after it the buffers of rewritten files are reloaded (`:checktime`). Every run (manual and on save) is numbered when
it starts, and a check's diagnostics of a file are only replaced by a run that started later than the one that set
them, so a slow `:Testing lint` never overwrites a newer save's result. When a check's findings were cut at the cap
(200), nothing of that check is cleared.

**On save** (off by default): `setup({ lint = { on_save = true } })` lints a written file (`BufWritePost` on the
extensions of the lint presets) with `testing lint --on-save --file=<file>` after 300 ms of quiet, in the
background, one run per buffer at a time: a newer save stops the older run, whose result is dropped. Only the
diagnostics change, no quickfix list opens, and a message appears only when a check could not run (exit `3`: a
missing tool). "Nothing to lint here" is silent: no child starts for a file whose root (found upwards from it) has
neither a `.testing.lua` nor a `lua/` folder, or that does not lie below it, and an exit `2` (no pipeline, an
untrusted root, a broken `.testing.lua`) says nothing on save.
`luals` never runs on save. `:checkhealth testing` lists every lint preset's tool (found or not, its path and
version). A missing tool is a warning only when a lint step of the project's pipeline needs it (read from the
`.testing.lua` table health evaluates in its sandbox, or derived from the repository; health never executes the
file); otherwise it is information: the linters are optional.

## Reports and findings

A process preset has an **error format** (Vim's `errorformat` items `%f` (a file name, no blanks), `%l`, `%c`, `%m`
and `%%`; any other item is an error; several alternatives per preset): `luacheck` `%f:%l:%c: %m`, `stylua`
`Diff in %f:`, `luals` `%F:%l:%c %m` (`%F` is our own item: a file name that may hold blanks, not at its start;
LuaLS prints `lua\my dir\a.lua:2:3 ...`). Each output line is matched as it arrives, without its colour escapes and,
for a line that redraws itself with carriage returns (LuaLS' progress text), only its last part; a relative file
name is written with forward slashes and without a leading `./`, and the **findings** (file, line, column, text; at most
200 are listed, all are counted; a finding the output lists twice, as LuaLS' pretty output can, is listed and counted
once) go into the document. The suite's findings come from its Result-IR (one per case
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

**Transition.** Where git ignores `.ci-last.json`, a run also writes it in the old format of `scripts/ci.sh` (`repo`,
`commit`, `dirty`, `time`, `state`, `note`), so readers of that file keep working: every run of the whole pipeline
(a red one always, so an old green never stays; a green-partial one as `green` with the note `partial: <why>`), and a
run that stops for a missing tool or dependency (`red`, the problem as the note, for the commit that is checked out).
A narrowed run (`--step`, suite options) and a run in which HEAD or the tree moved write nothing. Where git does not
ignore the file, nothing is written: a run never makes the tree dirty.
