# Configuration

testing.nvim has two separate configurations. Do not mix them up.

| What | Where | Used by |
| --- | --- | --- |
| The **project file** `.testing.lua` | the root of the project under test | the command-line runner (`scripts/testing.lua`) |
| The **plugin options** of `require("testing").setup(opts)` | your Neovim config | the editor commands (`:Testing`) |

## `.testing.lua` (per project)

A Lua file in the project root that returns a table. Every key is optional; what is not named
keeps its default. This repository's own [`.testing.lua`](../.testing.lua) is a working example.

```lua
-- .testing.lua
return {
  plugin = "myplugin",
  roots = { "TESTS" },
  dialect = "auto",
  minit = "TESTS/minimal_init.lua",
  deps = { "plenary.nvim" },
}
```

**Security.** Loading `.testing.lua` executes it with the privileges of the editor process, the
same trust as running the project's own specs. The runner therefore loads it only from the root
you named on the command line (or from `--config <file>`, which must lie inside that root once
symlinks are resolved), as text (never as bytecode) and below 256 KiB. `:checkhealth testing` does
not execute it: it evaluates the file in an empty environment with an instruction budget and says so
when the file needs more than a plain table.

**Validation.** Keys are checked before they are merged over the defaults. An invalid value, an
unknown key and a table where a scalar belongs each produce one warning that names the key and what
was expected; the default stays in place and the run goes on. Only a file that cannot be used at
all (syntax error, raises, does not return a table, lies outside the root) is an error: exit code
`2`.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `plugin` | string, letters/digits/`._-` | directory name without `.nvim` | Lua module root of the project. |
| `roots` | non-empty list of relative paths without `..` | `{ "TESTS" }` | Spec roots below the project root. |
| `spec_pattern` | non-empty list of Lua patterns | `{ "_spec%.lua$" }` | What makes a file below a root a spec, matched against its project-relative path. A project whose specs lack the suffix (self-running scripts such as `TESTS/units.lua`) names its own, e.g. `{ "_spec%.lua$", "^TESTS/[%w_]+%.lua$" }`. `harness.lua`, `run.lua` and `minimal_init.lua` directly in a root are never specs; `TESTS/refs/run.lua` is one when a pattern names it. |
| `dialect` | one of `"auto"`, `"testing"`, `"a"`, `"b"`, `"c"`, `"d"`, `"h"`, `"busted"`, `"script"`, or a table `{ ["<path or glob>"] = "<name>", ["*"] = "<name>" }` | `"auto"` | `"auto"` sniffs the dialect per file; a name forces one dialect for every file; the table form sets it per file (a literal relative path wins over a glob with more literal characters, the lone `"*"` is the fallback; `*` is one segment, `**` crosses segments, `?` one character). See [DIALECTS.md](DIALECTS.md). |
| `assertions` | `"error"` or `"warn"` | `"error"` | A case without a single assertion: `"error"` fails it (the default, "a case that asserts nothing proves nothing"); `"warn"` passes it, records `no_assertions` and a note in the IR, and the terminal lists the cases. A migrated plenary repository uses `"warn"`: plenary let such cases pass. The same switch decides what a **busted file without a registered case** is (a spec that registers cases per platform has none on the others): `"error"` fails it, `"warn"` records one `skip` case (`no case registered on this platform`, with a warning note and a terminal listing); under `--strict` that skip makes the run red. |
| `isolated` | `"auto"`, `"none"` or `"file"` | `"auto"` | `"file"`: every spec file runs in a child editor of its own; `"none"`: all in this editor; `"auto"`: `"file"` for busted files, `"none"` for the other dialects. A `script` is always a child. |
| `jobs` | integer 1..256 | `1` | Child editors running at once. The report is the same for any value. |
| `host` | `"c"` or `"l"` | `"c"` | How a child starts: `"c"` like plenary's host (a `-c` command: `vim.v.vim_did_enter` is `0`, `expand("<cword>")` works), `"l"` like `nvim -l`. |
| `filetype` | boolean | `true` | A child runs `filetype plugin indent on` (plenary's minimal init does). |
| `disable_first_run` | boolean | `true` | Test-environment default: every editor the runner starts (each child, and this editor for an in-process run, restored afterwards) gets `vim.g.lib_nvim_deps_disable_first_run = true` **before** the project's `minit` runs. lib.nvim shows a one-time "missing tools" float on a plugin's first start when `stdpath('cache')` is empty; a child's cache is always empty, so without this the float opens windows and buffers inside a spec. A value the project (or the user) already set is left alone; `false` leaves the variable untouched. |
| `env_allow` | list of names, each optionally ending in `*` | `{}` | Environment variables a child may inherit on top of the built-in allowlist (`PATH`, `HOME`, `LANG`, `LC_*`, ...; secrets are never passed). `{ "REPOS_DIR", "MAGICK_*" }`. A bare `*` and names starting with `NVIM` are refused. `--env-allow` adds to it. |
| `minit` | `false` or relative path | `"TESTS/minimal_init.lua"` | Minimal init of the project; it runs in this editor and in every child before the spec. |
| `deps` | list of directory names | `{}` | Dependencies the run needs (see below). A missing one is exit code `3`. |
| `setup` | table | `{}` | Options the conformance suite calls the plugin's `setup()` with (reserved). |
| `timeouts.case_ms` | integer > 0 | `10000` | Timeout of one case: a guard in this editor, **hard** in a child (a busted file whose child writes no new case for `case_ms` + 2 s is killed with its process tree). |
| `timeouts.file_ms` | integer > 0 | `60000` | Timeout of one spec file; hard in a child (`file_ms` + 2 s, then the process tree is killed and the file is one `timeout` case). |
| `conformance.load_budget_ms` | number >= 0 | `40` | Reserved (conformance suite). |
| `coverage.bindings`, `coverage.commands` | number 0..1 | `0` | Reserved (coverage gates; `0` = report only). |
| `snapshots.dir` | relative path | `"TESTS/__snapshots__"` | Reserved (snapshots). |
| `backends.luals`, `.pty`, `.playwright`, `.webdriver` | boolean | `false` | Reserved (optional backends). |

"Reserved" keys are validated and kept, but nothing acts on them yet.

### Child editors

With `isolated = "file"` (and for every `script` file) a spec file runs in a **child editor**:
`nvim -n -i NONE --headless -u NORC`, started from the project root with an environment allowlist
(`env_allow`) and its own `stdpath` data/state/cache/config and temp directories, stdin from the null
device. The editor's runtime plugins load (netrw, matchit, ...), the dependencies and the project's
`minit` are on its runtimepath, and the `$<NAME>_DIR` of every resolved dependency is set, so an
editor a spec starts itself finds them too. A child that dies (native crash, `os.exit`, no result)
becomes **one** `crash` case of that file; one that exceeds its limit is killed with its whole process
tree and becomes one `timeout` case. Either way the other files run on. See
[the child driver](../lua/testing/child/README.md).

### Dependencies

A dependency `<name>` (for example `lib.nvim` or `plenary.nvim`) is looked up in four places, in
this order. The first one that holds a valid checkout wins:

1. `$<NAME>_DIR`, where every character outside `A-Z0-9` of the upper-cased name becomes `_`
   (`lib.nvim` gives `$LIB_NVIM_DIR`)
2. `<root>/.deps/<name>` (what CI checks out)
3. `<root>/../<name>` (a sibling checkout)
4. `stdpath("data")/lazy/<name>` (what a plugin manager installed)

An override in place 1 that is set but not valid is a failure, not a reason to fall through: an
override that is silently ignored is a lie about which code ran. When nothing is found, the message
names all four places and what was found at each, and the exit code is `3`.

`lib.nvim` is the runner's own hard dependency and is resolved the same way, relative to the
testing.nvim checkout. `testing doctor` prints the resolution of everything.

## Plugin options (`setup()`)

```lua
require("testing").setup({
  notify_prefix = "[testing]",
  keymaps = {},
})
```

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `notify_prefix` | non-empty string | `"[testing]"` | Prefix of every message the plugin shows. |
| `keymaps` | `table<string, string\|string[]\|false>` or `false` | `{}` | Moves or drops named keymap actions; `false` binds no key at all. See [BINDINGS.md](BINDINGS.md). |

A key with the wrong type, and any unknown key, is dropped and reported with a warning; the
default stays in place.
