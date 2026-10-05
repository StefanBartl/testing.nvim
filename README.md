> **Pre-alpha — kernel, dialect shim and a command-line driver only.** There is no runner, no
> discovery beyond `TESTS/*_spec.lua`, no reporter and no editor UI yet. Expect breaking changes;
> do not depend on it.

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
[lib.nvim](https://github.com/StefanBartl/lib.nvim). Today it ships a result kernel (a JSON
result format and assertions that record instead of raising), a shim that runs existing
`return function(H) ... end` spec files unchanged, a command-line driver for them, a `:Testing`
command, a validated configuration, `:checkhealth testing` and a headless spec suite that runs on
Linux, macOS and Windows.

## Table of contents

- [Status](#status)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Status

Pre-alpha, milestone M0 (a falsification experiment). What exists:

- `require("testing").setup(opts)` with a typed, validated configuration.
- `:Testing health` and `:Testing config`, and `:checkhealth testing`.
- The kernel in [`lua/testing/core`](lua/testing/core/README.md): the Result-IR (JSON,
  `schema_version = 1`, deterministic, with a validator) and collecting assertions: a failed
  check is recorded and the file runs on, so every failure of a file is visible.
- The dialect-A shim in [`lua/testing/dialect`](lua/testing/dialect/README.md), which runs spec
  files of the shape `return function(H) H.eq(...) end` without editing them.
- A command-line driver, `scripts/testing.lua`, that runs a project's `TESTS/*_spec.lua` files
  in one Neovim process and writes the Result-IR.
- A headless spec suite for the above, run in CI on three operating systems.

The M0 question was whether this kernel can run a real, existing suite unchanged with the same
verdict as that suite's own runner. It did so for lib.nvim's whole suite (87 spec files, same
verdict per file, timings not measurably worse). Known limits: dialect A has no test cases, so one
spec file is one case; the IR encoder has no redaction option yet; all files share one Neovim
process, like in the old runner.

What does not exist yet: parallel or isolated execution, test discovery beyond the file pattern,
filtering by case, reporters other than the plain console lines, any editor UI, adapters. Do not
expect more than the driver below.

## Requirements

- Neovim 0.10 or newer.
- [lib.nvim](https://github.com/StefanBartl/lib.nvim) — a hard dependency, not optional.
  It must be new enough to contain `lib.nvim.fs.write.atomic` (lib.nvim commit `6304829`) and the
  `lib.lua.error.safe_call` that keeps non-string errors (commit `89cb912`); an older checkout fails
  with `module 'lib.nvim.fs.write.atomic' not found` and `:checkhealth testing` names the missing
  module and these commits.

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

### Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root> [options]
```

Run it from `<root>`, the project whose `TESTS/*_spec.lua` files should run: specs that look at
"this repository" read the working directory, and the driver deliberately does not change it.

| Option | Meaning |
| --- | --- |
| `--json <file>` | Write the Result-IR to `<file>` and validate it again. |
| `--rtp <dir>` | Add `<dir>` to the runtimepath (repeatable); `<root>` is always added. |
| `--only <text>` | Run only spec files whose path contains `<text>` (repeatable). |
| `--sentinel <name>` | Last line on success; default: the one the project's `TESTS/run.lua` prints. |
| `--no-timings` | Do not print the timing line. |
| `-h`, `--help` | Usage. |

Exit codes: `0` all green, `1` at least one spec failed or errored, `2` usage or configuration
error (including a missing lib.nvim), `3` infrastructure error (the JSON could not be written or
failed validation). lib.nvim is looked up in `$LIB_NVIM_DIR`, `<repo>/.deps/lib.nvim` and a sibling
`../lib.nvim`.

Honesty rules of the driver: a spec listed in `TESTS/run.lua` but missing on disk is a failing
case; a spec that calls `os.exit` is an `error` case (the run goes on), and quitting the editor
(`:qa!`) ends with exit code 3 "run did not complete"; a filtered run (`--only`) prints
`partial run: N of M spec files` instead of the sentinel; every case notes that its `effects` were
not collected (M0). With `--json` the free text is redacted (user and host name, environment
`NAME=value` pairs, e-mail addresses) by the kernel, and the validator refuses what is left.

## Documentation

- [docs/BINDINGS.md](docs/BINDINGS.md) — every keymap, user command and autocommand.
- `:help testing` — the same reference inside the editor, including every `setup()` option.

## Development

```sh
scripts/test.sh            # all specs
scripts/test.sh config     # specs whose file name contains "config"
```

CI additionally runs lib.nvim's complete suite (checked out from `ci-verified`) through the
driver and uploads the Result-IR when that fails.

The runner needs `nvim` on `PATH` and finds lib.nvim in `$LIB_NVIM_DIR`, in `.deps/lib.nvim`,
or in a sibling `../lib.nvim` checkout; it exits with code 1 and names all three if none exists.

## License

testing.nvim is released under the [MIT License](https://opensource.org/licenses/MIT) — see
[LICENSE](LICENSE).
