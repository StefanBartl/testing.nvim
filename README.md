> **Pre-alpha, milestone M1.** A test runner for Neovim plugins that runs the spec styles of the
> author's plugins unchanged, tells the truth about a run, and tests itself with itself. No
> editor UI beyond `:Testing`, no process isolation between spec files yet, and the fleet has not
> been migrated. Expect breaking changes; do not depend on it.

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

A test runner and orchestration layer for Neovim plugins, built on
[lib.nvim](https://github.com/StefanBartl/lib.nvim). The goal is to replace busted and plenary for
the author's plugins and to replace, extend and improve their hand-written test harnesses, with the
existing specs running **unchanged**. What is true today: the runner runs `describe`/`it` specs
**without plenary or busted**, runs the harness-style specs of the fleet (`return function(H)` and
the like), tests this very repository with its own runner, and reports through a terminal reporter,
GitHub annotations, JUnit XML and a JSON result format. Moving the fleet's repositories over is the
next step and has not happened.

## Table of contents

- [Status](#status)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Status

Pre-alpha, milestone M1 ("a runner that never lies"). What exists and works:

- **The runner**: `scripts/testing.lua` discovers specs below `TESTS/` (no depth limit), picks the
  dialect of every file, runs them in one Neovim process and exits with a code that means
  something: `0` green, `1` red, `2` usage or nothing to run, `3` infrastructure
  ([docs/EXIT-CODES.md](docs/EXIT-CODES.md)).
- **Dialects** ([docs/DIALECTS.md](docs/DIALECTS.md)): `return function(H)` in the three shapes of
  lib.nvim, markdown/diff.nvim and images.nvim (`a`, `b`, `c`), spotlight.nvim's `M.run()` (`d`),
  specs on a project's own `harness.lua` (`h`), and `describe`/`it` with a luassert subset
  (`busted`). A failed check is recorded and the file goes on, so every failure is visible.
  Unsupported busted features (`spy`, `stub`, `mock`, `insulate`, ...) raise by name instead of
  passing silently.
- **Honesty**: a case without an assertion fails; a spec cannot end the run with `os.exit`; quitting
  the editor mid-run is exit `3`; a selection or a skipped case never prints the "all green" last
  line; a missing dependency is reported with all four places that were searched.
- **Selection and order**: `--file`, `--filter`, `--tags`, `--exclude-tags`, `--lf`, `--ff`,
  `-x`/`--maxfail`, `--shuffle`/`--seed`, `--list`, timeouts per case and file.
- **Output** ([docs/OUTPUT-FORMATS.md](docs/OUTPUT-FORMATS.md)): terminal, GitHub annotations and
  step summary, JUnit XML, and the Result-IR as JSON (`schema_version = 1`, deterministic,
  redacted, validated after writing).
- **Per-project configuration** `.testing.lua` ([docs/CONFIG.md](docs/CONFIG.md)), with a validated
  schema.
- `:checkhealth testing`, and the `:Testing` command ([docs/BINDINGS.md](docs/BINDINGS.md)), which
  runs in a headless child so a run never touches the editor you work in.
- A headless spec suite that runs through the runner itself in CI on Linux, macOS and Windows.

Known limits, not hidden:

- All spec files share one Neovim process, like in the old runners. A spec that blocks inside C
  (a `vim.system():wait()` without timeout) cannot be interrupted by the timeouts.
- `effects` of a case (processes, network, writes) are not measured yet; every case says so.
- The `init` subcommand exists only as `:Testing init`, not on the command line.
- Not implemented at all: parallel or isolated execution, a test UI, snapshots, coverage,
  conformance checks, adapters for other test frameworks. Keys for some of these exist in
  `.testing.lua` and are validated, but nothing acts on them.
- The fleet's repositories still run on their own runners.

## Requirements

- Neovim 0.10 or newer.
- [lib.nvim](https://github.com/StefanBartl/lib.nvim), a hard dependency, and new enough to contain
  `lib.nvim.fs.write.atomic` (commit `6304829`) and the `lib.lua.error.safe_call` that keeps
  non-string errors (commit `89cb912`). An older checkout fails with
  `module 'lib.nvim.fs.write.atomic' not found`; `:checkhealth testing` names the missing module and
  these commits.

The command-line runner looks for lib.nvim in four places, in this order: `$LIB_NVIM_DIR`,
`<repo>/.deps/lib.nvim`, a sibling `../lib.nvim`, `stdpath("data")/lazy/lib.nvim`. If none holds it, it
prints all four and exits with `3`.

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

### Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . [options]
```

Run it from the root of the project whose specs should run (`scripts/testing.lua` is the one of the
testing.nvim checkout, so give its path when you are in another repository). Without a
configuration it runs every `*_spec.lua` below `TESTS/`:

```sh
... -l scripts/testing.lua . --file config      # spec files whose name contains "config"
... -l scripts/testing.lua . --filter parses    # cases whose name contains "parses"
... -l scripts/testing.lua . --list             # what would run, in which dialect
... -l scripts/testing.lua . --json out.json --junit out.xml --github
... -l scripts/testing.lua doctor .             # configuration and dependency report
```

All options: [docs/CLI.md](docs/CLI.md). A run looks like this (the terminal shows absolute
paths so that they are clickable; the JSON and the reports use project-relative ones):

```
FAIL  TESTS/calc_spec.lua
    fail  calc::fails visibly:9
        /path/to/project/TESTS/calc_spec.lua:9
          expected:
            99
          actual:
            2
    skip  calc::later:12
        skipped: pending

1 spec(s) failed

summary: 1 pass, 1 fail, 1 skip (3 case(s)) in 0.00 s
```

### In the editor

```vim
:Testing run          " run the specs of the current project in a headless child
:Testing file         " the spec of the current buffer
:Testing last         " repeat the last run
:Testing health       " same as :checkhealth testing
```

The plugin binds no keymap and registers no autocommand by default. Every subcommand, flag and
completion: [docs/BINDINGS.md](docs/BINDINGS.md).

### Configuration

A project may have a `.testing.lua` in its root; this repository's own is a working example:

```lua
return {
  plugin = "testing",
  roots = { "TESTS" },
  dialect = "auto",
}
```

Every key and its type: [docs/CONFIG.md](docs/CONFIG.md).

## Documentation

- [docs/CLI.md](docs/CLI.md): every subcommand and option.
- [docs/CONFIG.md](docs/CONFIG.md): `.testing.lua` keys with types, dependency resolution, `setup()` options.
- [docs/EXIT-CODES.md](docs/EXIT-CODES.md): what `0`, `1`, `2` and `3` promise.
- [docs/DIALECTS.md](docs/DIALECTS.md): which spec styles run, and exactly what each shim supports.
- [docs/OUTPUT-FORMATS.md](docs/OUTPUT-FORMATS.md): reporters and the Result-IR.
- [docs/MIGRATING.md](docs/MIGRATING.md): for plugin authors coming from busted or plenary.
- [docs/BINDINGS.md](docs/BINDINGS.md): every keymap, user command and autocommand.
- `:help testing`: the reference inside the editor.

## Development

```sh
scripts/test.sh                  # all specs, through this repository's own runner
scripts/test.sh --file config    # specs whose file name contains "config"
```

`scripts/test.sh` is `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua .` plus an isolated
state directory. It exits `3` (and names the four places) when `nvim` or lib.nvim cannot be found.
CI runs the same on three operating systems and uploads the JSON result and the JUnit report when
it fails; a second job runs lib.nvim's whole suite, unchanged, through the runner.

## License

testing.nvim is released under the [MIT License](https://opensource.org/licenses/MIT), see
[LICENSE](LICENSE).
