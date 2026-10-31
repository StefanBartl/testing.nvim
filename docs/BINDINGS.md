# Bindings

Every keymap, user command and autocommand testing.nvim registers.

## Keymaps

None bound by default. One named action exists, without a default key, so a user opts in:

| Action | Default | Does |
| --- | --- | --- |
| `hover` | none | Same as `:Testing hover`: the last result of the test under the cursor, in a float. |

Actions are bound through `lib.nvim.bindings.keymap.register`; each can be moved or dropped:

```lua
require("testing").setup({
  keymaps = {
    hover = "<leader>th", -- <action> = "<lhs>" | { "<lhs>", ... } | false
  },
})
```

`keymaps = false` binds nothing at all.

### Keys of the matrix view

`:Testing surface --from=<ir.json> --matrix` opens a view with keys of its own, buffer-local to that view and bound
only while it is open. Each can be moved or dropped with `surface_view = { keys = { <action> = "<lhs>" | false } }`;
the winbar legend and the `?` cheatsheet are built from the same table.

| Action | Default | Does |
| --- | --- | --- |
| `jump` | `<CR>` | On a spec file column: open that spec file; elsewhere on a row: open the source of the entry at its line. |
| `status` | `s` | Status filter, round: all, hit, missing, untracked, ignored. |
| `kind` | `t` | Kind filter, round: all, binding, command, autocmd. |
| `export` | `e` | Write the shown rows as a tab separated file (asks for the path). |

`?` shows the cheatsheet, `q` and `<Esc>` close the view.

## User commands

| Command | Arguments | Description |
| --- | --- | --- |
| `:Testing` | none | Same as `:Testing run`. |
| `:Testing run [<root>]` | `--file=<text>` (repeatable), `--filter=<text>` (repeatable), `--reporter=<name>`, `--rtp=<dir>` (repeatable), `--config=<file>`, `--cached`, `--no-cache`, `--changed`, `--since=<rev>`, `--shard=<i>/<n>` | Run the spec files of the project in a headless child Neovim. `<root>` defaults to the nearest ancestor of the working directory that holds `.testing.lua`, `TESTS` or `.git`. `--cached` skips spec files whose inputs did not change since a green run (their cases are reported as cached, [CACHE.md](CACHE.md)); `--changed` / `--since=<rev>` run only the specs the working tree / that revision can reach; a run with either is a partial run (no sentinel). |
| `:Testing file [<spec>]` | `--rtp=<dir>` | Run the spec file of the current buffer (or of `<spec>`). A file that is not a `*_spec.lua` is refused: running the spec that belongs to a source file is not implemented yet. |
| `:Testing last` | none | Repeat the last `run`/`file` of this session. |
| `:Testing hover` | none | The last result of what is under the cursor, in a float (the `hover` keymap action does the same). On an `it` line: status, duration, age and for a red case the first failing assertion with a small diff; on a `describe` line: the cases below it; on any other line of a spec: the file summary (cases green/red, slowest, last run); a file that is one case (dialect A) shows its result and every failing assertion as `file:line`. A spec path written in another buffer (a note, a task, a report) answers with the file summary. Never a stale green: an outdated result (file changed or gone, or the buffer has unsaved changes) is worded in the past tense and titled `(outdated)`; a case or file without a result says `not run yet`. Cases are matched to the text by describe path and name (cleaned the way the store keeps titles; a repeated title takes the nearest recorded line), so a file that grew above them still finds them. A line inside the body of an `it` answers with that case (the body is the run of deeper-indented lines under the `it` line, so this needs formatted code, like the discovery's regex backend; a one-line `it` has no body). A file counts when its name matches `_spec.lua` (the default `spec_pattern`) or the store has a result for it; other files under `TESTS/` (`harness.lua`, helpers) are no specs. Only plain file buffers answer: a `fugitive://`, `oil://`, `diffview://` or `term://` buffer, a scratch buffer or a UNC path does not. The `file` preview for a path in another buffer looks at `_spec.lua` names only, before any file is touched, and leaves every other file to hover.nvim's own preview. The same text is registered with [hover.nvim](https://github.com/WKDSteve/hover.nvim) softly (no `require` at load time): a position (`:Hover show`, `on_request`, never the automatic trigger) and a `file` preview for spec paths. hover.nvim is never `require`d by `setup()` (under a lazy loader that would load it): when it is not loaded yet, a retry waits in the augroup `TestingHoverRegister` (`VimEnter`, `User LazyLoad`, `User VeryLazy`) and `:Testing hover` tries on first use; `:checkhealth testing` says registered / not registered / absent. The first line of the float is coloured `HoverError` (red) or `TestingHoverWarn` (outdated, not run; linked to `DiagnosticWarn`), both defined with `default = true`. Without hover.nvim only the command and the key exist. Size from `hover = { max_width, max_height, max_diff_lines }` ([CONFIG.md](CONFIG.md)); it applies to the float as well as to hover.nvim. Titles, messages and values are cleaned of control characters and cut. Reads `testing.state` (`docs/STATE.md`), runs nothing. |
| `:Testing terminal` | none | Repeat the last `run`/`file` (else run the project) as the job of a [terminal.nvim](https://github.com/WKDSteve/terminal.nvim) terminal named `testing`: the reporter's own output to scroll and copy, nothing parsed, no quickfix list. Needs terminal.nvim. |
| `:Testing list [<root>]` | as `run`, without `--cached` and `--reporter` | List the spec files that would run; run nothing. The list opens in a viewer. Nothing runs, so there is no result cache to skip files with and no output to format: the two flags are not offered (a wrong flag is a usage error, not a silent no-op). `--no-cache` stays for `--changed` / `--since`: it analyses every file again instead of reading the stored index. |
| `:Testing init [<root>]` | `--force`, `--plugin=<name>`, `--hooks`, `--update`, `--write` | With `--update`: bring `scripts/test.sh` and `TESTS/minimal_init.lua` to the current templates, keeping what is the repository's own; a preview with the diff, `--write` writes (a file with a risk or uncommitted changes only with `--force`) ([CLI.md](CLI.md#updating-the-setup)). Otherwise: generate `.testing.lua`, `TESTS/minimal_init.lua`, `TESTS/<plugin>/load_spec.lua`, `scripts/test.sh`, `.github/workflows/ci.yml`, `stylua.toml`, `.luacheckrc` and `.gitattributes` in `<root>` (default: the working directory). An existing file is never overwritten, it is reported as kept; `--force` replaces it. With `--hooks` it writes the hook recipes instead (`scripts/hooks/{_testing.sh,pre-push,pre-commit,claude-stop}`, never over an existing file, `--force` does not apply) and prints the three commands that are left to you (`git add`, `git update-index --chmod=+x` for `pre-push` and `pre-commit` so that a clone on Linux, macOS or WSL runs them, `git config core.hooksPath`): [HOOKS.md](HOOKS.md). |
| `:Testing migrate [<mode>] [<root>]` | `--fleet-root=<dir>` | `<mode>` is `dry-run` or `apply`. Plan the move of a plugin repository from plenary / busted / a hand-written runner to testing.nvim, specs unchanged ([MIGRATING.md](MIGRATING.md)). `dry-run` (the default) writes nothing: it opens the plan (analysis, the new `.testing.lua`, `scripts/test.sh`, `TESTS/minimal_init.lua`, the CI workflow as a diff, notes, risks) in a viewer. `apply` writes it, and refuses a repository with uncommitted changes. The first word is the mode when it is `dry-run` or `apply`, else it is the root. `--fleet-root` is the directory with the sibling `*.nvim` repositories used to map `require`s to dependencies (default: the parent of `<root>`). |
| `:Testing conformance [<root>]` | `--gate`, `--only=<ids>`, `--skip=<ids>`, `--bridge`, `--markdown` | Run the conformance checks K1..K16 on the project in a headless child Neovim and show the report ([CONFORMANCE.md](CONFORMANCE.md)). Report only unless `--gate` (or `conformance.gate` in `.testing.lua`); a failed gate is a warning with the report, not an error. |
| `:Testing surface [<root>]` | `--from=<ir.json>`, `--threshold=<n>`, `--markdown`, `--matrix`, `--csv`, `--no-tags` | List the plugin's keymaps, commands, autocmds and how much of it the specs exercised ([SURFACE.md](SURFACE.md)). Without `--from` (the IR of a tracked run) nothing is measured and the report says so. `--matrix`: entries x spec files in an interactive view (filters, jumps, export; [Keys of the matrix view](#keys-of-the-matrix-view)), as text with `--csv` (a tab separated table) or `--markdown`. |
| `:Testing budget [<root>]` | `--update`, `--allow-new`, `--factor=<x>` | Measure the performance budgets of the runner and compare them with the baseline ([PERFORMANCE.md](PERFORMANCE.md)). |
| `:Testing ci [<profile>]` | `--step=<a,b>`, `--keep-going`, `--reuse`, `--root=<dir>` | Run the pipeline of the `ci` section of `.testing.lua` ([CI.md](CI.md)) in a headless child: the output streams into the buffer `testing-ci://<repo>` (a split opens when it is not visible), the verdict is notified, and a red run fills the quickfix list with the findings of the red steps (opened only on red). The editor never blocks. `<profile>` and `--step=` complete from the project (`testing ci list`, run in a child: the editor does not execute `.testing.lua`). |
| `:Testing lint [<check>...]` | `--file`, `--changed`, `--all`, `--fix`, `--root=<dir>` | Run the lint checks (`stylua`, `luacheck`, `luals`: the lint steps of the pipeline, or the named ones) in a headless child, `testing lint --json` ([CI.md](CI.md#testing-lint-the-linters-on-the-changed-files)). Default scope: the changed files; `--file` the file of the current buffer, `--all` everything. The findings fill the quickfix list "testing lint" (opened only when there are some) and become `vim.diagnostic` in the loaded buffers, one namespace per check (`testing.lint.<check>`); a checked file without findings is cleared. `--fix` rewrites what `stylua` can fix and reloads the buffers; it is refused while a buffer of a file in its scope has unsaved changes (save first). The verdict is notified; a missing tool is named. The check names complete from the project. With `setup({ lint = { on_save = true } })` a written file is checked in the background (never `luals`), diagnostics only. |
| `:Testing ci repos` | `--force`, `--jobs=<n>`, `--profile=<name>`, `--refresh`, `--keep-going`, `--reuse`, `--repos-root=<dir>` | Run the pipelines of the repositories of the setting `ci.repos` one after the other, `verify` first ([CI.md](CI.md#several-repositories)); the output streams into the buffer `testing-ci://repos-<hash>` below a live table of the repositories, red findings go to the quickfix list. |
| `:Testing ci status` | `--root=<dir>` | The last result of the project in a viewer: the verdict, one line per step, the findings. Says when the tree changed since (`stale`). |
| `:Testing ci verify` | `--profile=<name>`, `--allow-dirty`, `--root=<dir>` | `testing ci verify` in a child: is this state already proven by a complete green run? Nothing runs. |
| `:Testing ci hook install` | `--run=<profile>`, `--verify=<profile>`, `--root=<dir>` | Install the pre-push hook (`testing ci hook install`, [CI.md](CI.md#the-pre-push-hook)). |
| `:Testing ci hook remove` | `--root=<dir>` | Remove it again (a hook that is not ours stays). |
| `:Testing cache stats [<root>]` | none | Show entries, size and directory of the result cache of the project. |
| `:Testing cache clear [<root>]` | none | Delete the result cache of the project. It is regenerable: deleting it costs time, never correctness. |
| `:Testing health` | none | Run `:checkhealth testing`. |
| `:Testing config` | none | Show the effective configuration. |
| `:Testing doctor [<root>]` | none | Show the project's resolved `.testing.lua` and where each dependency was found (or all four places that were searched). |

`:Testing` is one compound command (`lib.nvim.bindings.usercmd.composer`):
subcommands, `--flags` and their values are completed with `<Tab>`, and a wrong
subcommand prints the usage. The lists are computed when you press the key:
`--reporter=` offers the reporters the plugin has at that moment and `--file=`
offers the spec files that exist below the project root now. The command is
registered when the plugin loads (`plugin/testing.lua`) and again, harmlessly,
by `setup()`.

Every flag carries a one-line `desc`: the text next to it in lib.nvim's option
cheatsheet (opt-in there: `composer.setup({ help = { enable = true, keymap = ... } })`,
then press the key on the command line). A positional argument says what it is
for too: `DIR` and `FILE` explain themselves, `migrate`'s `[mode]` carries the
text of its argument type.
`TESTS/testing/usrcmds_help_spec.lua` fails for a flag or an argument without one.

Runs never happen in the editor's own process. The driver
(`scripts/testing.lua`) is started as a child with an argument list (no shell,
every value its own argument) and the project root as its working directory. The
result is shown as one notification and, when something failed, as a quickfix
list (`:copen`) with one entry per failed case, pointing at the failing
assertion. The verdict is the child's exit code: 0 green, 1 failed, 2 usage or
configuration error, 3 infrastructure error; a summary is only ever "green" for
code 0, and a run that produced no readable result says so instead of "0 failed".

A run in a root that is not trusted ([CONFIG.md](CONFIG.md#workspace-trust)) ends with exit 2 before anything of
the project runs. `:Testing <cmd>` and `:Testing ci` then ask once (`vim.ui.select`): *Trust it and run again*
stores the root like `testing trust add <root>` and starts the same run again; *Do not trust it* (or closing the
question) leaves the refusal as the verdict. A second refusal of the run that follows is not asked about again,
and a headless nvim (no UI) is never asked. `:Testing ci repos` does not ask: an untrusted repository is an
`error` row of its table, trust it with `testing trust add <dir>` or list the parent in `TESTING_TRUST_ROOTS`.

No subcommand takes a range or a count: there is no text to act on and nothing
to repeat. `:Testing last` is the repeat.

The Lua API behind them: `require("testing").run(opts, on_done)`,
`require("testing").scaffold(root, opts)` and, for `:Testing migrate`,
`require("testing.migrate")` (`analyze`, `plan`, `render`, `to_json`, `apply`, `main`).

`:Testing migrate` runs in this editor's process: it only reads files (and, with `apply`,
writes the few files of the plan), so it needs no child process. Completion offers `dry-run`,
`apply` and directories for the first word and directories for the root. The result is
one notification (the count and whether anything was written) plus the full plan in the viewer.

## Command-line entry

Not a Neovim binding, but the other way in: `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua
<root> [--json <file>] [--rtp <dir>] [--only <text>] [--sentinel <name>] [--no-timings]`, and
`testing migrate [dry-run|apply] [<path>] [--json] [--markdown] [--check] [--fleet-root=<dir>]`
(exit 0 done, 1 `--check` found work, 2 refused or bad usage, 3 unreadable root). Options and
exit codes are in the README and in `:help testing-cli`. It registers no command, keymap or
autocommand in an interactive session.

## Statusline

`require("testing.ci.editor").statusline()` returns the text for the project of the current buffer: `ci: ✓ full @abc1234`,
`ci: ✗ luacheck`, `ci: ~ fast` (green but partial), `ci: ! infra`, `ci: … full` while a run is going, and `stale`
appended when the tree is no longer the one the result was for. It reads the cached result only and starts nothing,
except one asynchronous refresh (`editor.refresh(root)`) the first time a project is asked about; a run refreshes it
when it ends. Example (lualine): `{ function() return require("testing.ci.editor").statusline() end }`.

## Autocommands

None.
