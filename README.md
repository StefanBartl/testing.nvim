> **Pre-alpha — skeleton only.** This repository holds the plugin's structure, configuration,
> health check and its own test suite. The test runner itself is not implemented yet, so there is
> nothing to run tests with. Expect breaking changes; do not depend on it.

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

A planned test runner and orchestration layer for Neovim plugins, built on
[lib.nvim](https://github.com/StefanBartl/lib.nvim). Today it ships the skeleton it will grow in:
a `:Testing` command, a configuration with validation, `:checkhealth testing`, and a headless
spec suite that runs on Linux, macOS and Windows.

## Table of contents

- [Status](#status)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Status

Pre-alpha. What exists:

- `require("testing").setup(opts)` with a typed, validated configuration.
- `:Testing health` and `:Testing config`.
- `:checkhealth testing`.
- A headless spec suite for the above, run in CI on three operating systems.

What does not exist yet: discovery, execution and reporting of tests. Nothing in this repository
runs your tests.

## Requirements

- Neovim 0.10 or newer.
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — a hard dependency, not optional.

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

```vim
:Testing health   " same as :checkhealth testing
:Testing config   " show the effective configuration
```

The plugin binds no keymap and registers no autocommand by default.

## Documentation

- [docs/BINDINGS.md](docs/BINDINGS.md) — every keymap, user command and autocommand.
- `:help testing` — the same reference inside the editor, including every `setup()` option.

## Development

```sh
scripts/test.sh            # all specs
scripts/test.sh config     # specs whose file name contains "config"
```

The runner needs `nvim` on `PATH` and finds lib.nvim in `$LIB_NVIM_DIR`, in `.deps/lib.nvim`,
or in a sibling `../lib.nvim` checkout; it exits with code 1 and names all three if none exists.

## License

testing.nvim is released under the [MIT License](https://opensource.org/licenses/MIT) — see
[LICENSE](LICENSE).
