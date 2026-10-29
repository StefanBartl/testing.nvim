# The CI workflow: how the pieces fit together

One definition of "this repository is fine", used in four places: in the terminal, before a push, in the editor, and
on the hosted runner. This page is the use case; [CI.md](CI.md) is the reference for every option.

## The idea

- **One definition per repository**: the `ci` section of `.testing.lua` (profiles of steps: `stylua`, `luacheck`,
  `suite`, `conformance`, a repository's own steps).
- **One engine**: `testing ci` runs it. The same pipeline, the same exit codes, everywhere.
- **One entry point per repository**: `scripts/ci.sh`, a shim that finds testing.nvim and calls `testing ci`
  (`--fast` is `--profile=fast`; a gate name such as `luacheck` is `--step=luacheck`). The GitHub workflow, the
  pre-push hook, `:MyPlugins ci` and a person in a terminal all run this one script.
- **A proof of the tested state**: a green run writes `ci-<profile>.json` and the suite's stamp. `testing ci verify`
  answers in a tenth of a second whether the current tree is already proven, so nothing is run twice.

## A repository, set up

A Lua project with a `stylua.toml`, a `.luacheckrc` and specs needs **no `ci` section at all**: `stylua`, `luacheck`,
the suite (and `conformance`, when it is a gate) are derived from those files, `fast` and `full` with them
([CI.md](CI.md#without-writing-a-pipeline-the-derived-one)). `testing ci list` shows what was derived and why. Only
what differs is written down:

```lua
-- .testing.lua
return {
  deps = { "lib.nvim" },
  ci = {
    skip = { "conformance" },                                -- leave a derived step out
    steps = {
      docs = { run = { "scripts/gen_docs.sh", "--check" } }, -- a step of the repository: argv, never a shell line
    },
  },
}
```

A section with `profiles` is the whole pipeline, written by hand, for a project whose checks differ more.

```bash
scripts/ci.sh                # the default profile (full)
scripts/ci.sh --fast         # stylua and luacheck, seconds
scripts/ci.sh luacheck       # one gate: a partial run, green for that gate only
scripts/ci.sh --keep-going   # every step, all red ones at once
```

Repositories with a Lua suite run through `scripts/test.sh ci` (it finds the dependencies and isolates state, the same
as a plain suite run). Vaults without a suite carry a `.testing.lua` with only the `ci` section and a shim that looks
for testing.nvim itself (`$TESTING_NVIM_DIR`, `.deps/testing.nvim`, `../testing.nvim`).

A missing tool or dependency is exit `3` before any step runs, never a silent green.

## A day with it

1. **Edit, then check fast.** `scripts/ci.sh --fast` (or `:Testing ci fast` in the editor). Formatting and lint, in
   seconds.
2. **In the editor.** `:Testing ci` runs the pipeline in a headless child, so a hanging step cannot take the session
   down. Output streams into `testing-ci://<repo>`, a progress indicator shows step n of m, the verdict is notified,
   and a red run fills the quickfix list with the findings (a click jumps to the place). `:Testing ci status` shows
   the last result and says `stale` when the tree changed since. The statusline component
   `require("testing.ci.editor").statusline()` shows `ci: ✓ full @abc1234` / `ci: ✗ luacheck` / `stale`.
3. **Before the push.** `testing ci hook install` writes a pre-push hook: it runs `testing ci verify` first. A proven
   state passes at once; otherwise the `fast` profile runs with `--reuse` (an unchanged suite is not run again). A red
   pipeline blocks the push; `git push --no-verify` skips it.
4. **After a change in a library.** `:Testing ci repos` (or `testing ci --repos-root=$REPOS_DIR`) runs the pipelines of
   all repositories that have a `ci` section. Each repository is verified first and **skipped when it is already
   proven**, so only the repositories the change reached run again. A table at the top of the buffer follows the run;
   the quickfix list collects the findings of every red repository, prefixed with its name.

## On the hosted runner

The GitHub workflow of a repository does not spell the commands out again: it checks out the dependencies below
`.deps/` and runs `scripts/ci.sh` (one job per gate where independent red/green marks are wanted, e.g.
`scripts/ci.sh luacheck`).

- **Dependencies come from `ci-verified`.** Every repository publishes the branch `ci-verified` once its own CI is
  green. Other repositories check out `lib.nvim`, `testing.nvim` and so on at that branch, so a half-finished change
  in a library never breaks its dependents.
- **testing.nvim needs lib.nvim.** A job that runs the shim therefore checks out both below `.deps/`.
- **Private repositories** run on a self-hosted runner. Without a running runner a push stays "Queued". Start it with
  `scripts/runners.ps1 ensure <repo>` of the nvim configuration.
- **The same files, a different machine.** What the runner does and what you did locally are the same steps; a
  difference is a finding (a tool version, a missing dependency), not a second pipeline to maintain.

## What the `conformance` step checks

K1 to K15 of [CONFORMANCE.md](CONFORMANCE.md): layout, documentation, tooling, and static rules read from the text of
the repository. `UI-63` is one of them: no `vim.fn.confirm`, `vim.fn.input`, `vim.fn.inputlist` or literal Yes/No
`vim.ui.select` in `lua/` outside the dialog helper; ask through `lib.nvim.ui.dialog`, or mark an intended exception
with `-- native-prompt: <reason>`. It is a warning, so it never turns the gate red by itself.

## Exit codes and the sentinel

`0` green (or skipped for this system), `1` a step red, `2` usage or configuration error (a typo in the `ci`
section is an error, never a green run), `3` a tool or dependency is missing or a step could not start. The last line
of a complete green run is `TESTING_CI_OK`; a partial run (`--step`, suite options, a green-partial suite) never
prints it. See [EXIT-CODES.md](EXIT-CODES.md).

## Adding a repository

1. `testing init` (or `testing migrate`) for `.testing.lua`, `TESTS/minimal_init.lua` and `scripts/test.sh`.
2. Add the `ci` section; `testing ci list` shows the resolved profiles.
3. Replace `scripts/ci.sh` by the shim (keep the name: workflows, hooks and `:MyPlugins ci` call it).
4. Check it from both sides: a format error and a red case turn it red (exit `1`), a missing tool gives exit `3`.
5. Point the workflow at `scripts/ci.sh` and give the job the dependency checkouts.

## Not there yet

- **Test explorer node**: the pipeline as a node with its steps, restart from a step (`ci-explorer-knoten`, waits for
  the explorer).
- **Live check in a real editor**: split, progress style and statusline were built against a fake process; the check
  by hand is the task `ci-editor-live-test-von-testing-ci-ci-repos-im-echten-editor`.
- **Terminal view** (terminal.nvim instead of the scratch buffer) is optional and not built.
