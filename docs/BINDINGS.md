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
| `:Testing health` | none | Run `:checkhealth testing`. |
| `:Testing config` | none | Show the effective configuration. |

`:Testing` is one compound command (`lib.nvim.bindings.usercmd.composer`):
subcommands are completed with `<Tab>`, and a wrong subcommand prints the usage.
It is registered when the plugin loads (`plugin/testing.lua`) and again,
harmlessly, by `setup()`.

Neither subcommand takes a range or a count: there is no text to act on and
nothing to repeat.

## Command-line entry

Not a Neovim binding, but the other way in: `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua
<root> [--json <file>] [--rtp <dir>] [--only <text>] [--sentinel <name>] [--no-timings]`. Options and
exit codes are in the README and in `:help testing-cli`. It registers no command, keymap or
autocommand in an interactive session.

## Autocommands

None.
