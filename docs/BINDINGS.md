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
| `:Testing run [<root>]` | `--file=<text>` (repeatable), `--filter=<text>` (repeatable), `--reporter=<name>`, `--rtp=<dir>` (repeatable), `--config=<file>` | Run the spec files of the project in a headless child Neovim. `<root>` defaults to the nearest ancestor of the working directory that holds `.testing.lua`, `TESTS` or `.git`. |
| `:Testing file [<spec>]` | `--rtp=<dir>` | Run the spec file of the current buffer (or of `<spec>`). A file that is not a `*_spec.lua` is refused: running the spec that belongs to a source file is not implemented yet. |
| `:Testing last` | none | Repeat the last `run`/`file` of this session. |
| `:Testing list [<root>]` | as `run` | List the spec files that would run; run nothing. The list opens in a viewer. |
| `:Testing init [<root>]` | `--force`, `--plugin=<name>` | Generate `.testing.lua`, `TESTS/minimal_init.lua`, `TESTS/<plugin>/load_spec.lua`, `scripts/test.sh`, `.github/workflows/ci.yml`, `stylua.toml`, `.luacheckrc` and `.gitattributes` in `<root>` (default: the working directory). An existing file is never overwritten, it is reported as kept; `--force` replaces it. |
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

The Lua API behind them: `require("testing").run(opts, on_done)` and
`require("testing").scaffold(root, opts)`.

## Command-line entry

Not a Neovim binding, but the other way in: `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua
<root> [--json <file>] [--rtp <dir>] [--only <text>] [--sentinel <name>] [--no-timings]`. Options and
exit codes are in the README and in `:help testing-cli`. It registers no command, keymap or
autocommand in an interactive session.

## Autocommands

None.
