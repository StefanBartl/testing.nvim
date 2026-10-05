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
| `dialect` | `"auto"`, `"testing"`, `"a"`, `"b"`, `"c"`, `"d"`, `"busted"` | `"auto"` | `"auto"` sniffs the dialect per file; a name forces one dialect for every file. See [DIALECTS.md](DIALECTS.md). |
| `minit` | `false` or relative path | `"TESTS/minimal_init.lua"` | Minimal init of the project, for isolated child runs. |
| `deps` | list of directory names | `{}` | Dependencies the run needs (see below). A missing one is exit code `3`. |
| `setup` | table | `{}` | Options the conformance suite calls the plugin's `setup()` with (reserved). |
| `timeouts.case_ms` | integer > 0 | `10000` | Hard timeout of one case. |
| `timeouts.file_ms` | integer > 0 | `60000` | Hard timeout of one spec file. |
| `conformance.load_budget_ms` | number >= 0 | `40` | Reserved (conformance suite). |
| `coverage.bindings`, `coverage.commands` | number 0..1 | `0` | Reserved (coverage gates; `0` = report only). |
| `snapshots.dir` | relative path | `"TESTS/__snapshots__"` | Reserved (snapshots). |
| `backends.luals`, `.pty`, `.playwright`, `.webdriver` | boolean | `false` | Reserved (optional backends). |

"Reserved" keys are validated and kept, but nothing acts on them yet.

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
