# Bindings

Every keymap, user command and autocommand testing.nvim registers.

## Keymaps

None. The plugin binds no key by default.

Keymaps will be declared as named actions and bound through
`lib.nvim.bindings.keymap.register`. Each action can then be moved or dropped:

```lua
require("testing").setup({
  keymaps = {
    -- <action> = "<lhs>" | { "<lhs>", ... } | false
  },
})
```

`keymaps = false` binds nothing at all.

## User commands

| Command | Arguments | Description |
| --- | --- | --- |
| `:Testing` | none | Same as `:Testing run`. |
| `:Testing run [<root>]` | `--file=<text>` (repeatable), `--filter=<text>` (repeatable), `--reporter=<name>`, `--rtp=<dir>` (repeatable), `--config=<file>`, `--cached`, `--no-cache`, `--changed`, `--since=<rev>`, `--shard=<i>/<n>` | Run the spec files of the project in a headless child Neovim. `<root>` defaults to the nearest ancestor of the working directory that holds `.testing.lua`, `TESTS` or `.git`. `--cached` skips spec files whose inputs did not change since a green run (their cases are reported as cached, [CACHE.md](CACHE.md)); `--changed` / `--since=<rev>` run only the specs the working tree / that revision can reach; a run with either is a partial run (no sentinel). |
| `:Testing file [<spec>]` | `--rtp=<dir>` | Run the spec file of the current buffer (or of `<spec>`). A file that is not a `*_spec.lua` is refused: running the spec that belongs to a source file is not implemented yet. |
| `:Testing last` | none | Repeat the last `run`/`file` of this session. |
| `:Testing list [<root>]` | as `run` | List the spec files that would run; run nothing. The list opens in a viewer. |
| `:Testing init [<root>]` | `--force`, `--plugin=<name>`, `--hooks` | Generate `.testing.lua`, `TESTS/minimal_init.lua`, `TESTS/<plugin>/load_spec.lua`, `scripts/test.sh`, `.github/workflows/ci.yml`, `stylua.toml`, `.luacheckrc` and `.gitattributes` in `<root>` (default: the working directory). An existing file is never overwritten, it is reported as kept; `--force` replaces it. With `--hooks` it writes the hook recipes instead (`scripts/hooks/{_testing.sh,pre-push,pre-commit,claude-stop}`, never over an existing file, `--force` does not apply) and prints the three commands that are left to you (`git add`, `git update-index --chmod=+x` for `pre-push` and `pre-commit` so that a clone on Linux, macOS or WSL runs them, `git config core.hooksPath`): [HOOKS.md](HOOKS.md). |
| `:Testing migrate [<mode>] [<root>]` | `--fleet-root=<dir>` | `<mode>` is `dry-run` or `apply`. Plan the move of a plugin repository from plenary / busted / a hand-written runner to testing.nvim, specs unchanged ([MIGRATING.md](MIGRATING.md)). `dry-run` (the default) writes nothing: it opens the plan (analysis, the new `.testing.lua`, `scripts/test.sh`, `TESTS/minimal_init.lua`, the CI workflow as a diff, notes, risks) in a viewer. `apply` writes it, and refuses a repository with uncommitted changes. The first word is the mode when it is `dry-run` or `apply`, else it is the root. `--fleet-root` is the directory with the sibling `*.nvim` repositories used to map `require`s to dependencies (default: the parent of `<root>`). |
| `:Testing conformance [<root>]` | `--gate`, `--only=<ids>`, `--skip=<ids>`, `--bridge`, `--markdown` | Run the conformance checks K1..K15 on the project in a headless child Neovim and show the report ([CONFORMANCE.md](CONFORMANCE.md)). Report only unless `--gate` (or `conformance.gate` in `.testing.lua`); a failed gate is a warning with the report, not an error. |
| `:Testing surface [<root>]` | `--from=<ir.json>`, `--threshold=<n>`, `--markdown` | List the plugin's keymaps, commands, autocmds and how much of it the specs exercised ([SURFACE.md](SURFACE.md)). Without `--from` (the IR of a tracked run) nothing is measured and the report says so. |
| `:Testing budget [<root>]` | `--update`, `--allow-new`, `--factor=<x>` | Measure the performance budgets of the runner and compare them with the baseline ([PERFORMANCE.md](PERFORMANCE.md)). |
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

Runs never happen in the editor's own process. The driver
(`scripts/testing.lua`) is started as a child with an argument list (no shell,
every value its own argument) and the project root as its working directory. The
result is shown as one notification and, when something failed, as a quickfix
list (`:copen`) with one entry per failed case, pointing at the failing
assertion. The verdict is the child's exit code: 0 green, 1 failed, 2 usage or
configuration error, 3 infrastructure error; a summary is only ever "green" for
code 0, and a run that produced no readable result says so instead of "0 failed".

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

## Autocommands

None.
