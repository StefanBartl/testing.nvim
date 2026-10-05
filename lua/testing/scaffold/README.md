# testing.scaffold

`testing init`: generates the test setup of a plugin repository.

```lua
local result = require("testing.scaffold").init(root, { force = false, plugin = nil, deps = nil })
-- result.created / result.replaced / result.skipped : paths relative to root, forward slashes
-- result.errors                                     : "<path>: <reason>" each; empty = success
-- result.plugin                                     : the sanitized plugin name that was used
```

Also reachable as `:Testing init [<root>] [--force] [--plugin=<name>]` and
`require("testing").scaffold(root, opts)`.

## What it writes

| File | Purpose |
| --- | --- |
| `.testing.lua` | plugin name and dependencies for testing.nvim |
| `TESTS/minimal_init.lua` | runtimepath for isolated runs; exits 1 and names all four places when a dependency is missing |
| `TESTS/<plugin>/load_spec.lua` | a first spec that can fail: the module of the plugin must load |
| `scripts/test.sh` | the runner; exits 1 with the four searched places instead of running silent or green without nvim, testing.nvim or a dependency |
| `.github/workflows/ci.yml` | 3-OS matrix, `timeout-minutes`, the JSON IR uploaded on failure, dependencies from `ci-verified` |
| `stylua.toml`, `.luacheckrc`, `.gitattributes` | the formatter and linter settings the generated files expect |

A dependency is looked up in `$<NAME>_DIR`, `<repo>/.deps/<name>`, `<repo>/../<name>` and
`stdpath('data')/lazy/<name>`; an override that is set but wrong decides alone.

## Rules

- An existing file is never overwritten: it is `skipped`. Only `force = true` (the CLI's
  `--force`) replaces it, and the file is then listed in `replaced`.
- The plugin name is derived from `lua/<name>` or the directory name and **sanitized** (control
  sequences removed, then `[%w_-]` only) before it becomes part of a path or of any file.
- The templates in `templates/` are plain data. `render.lua` embeds each value in the quoting of the
  language it lands in (`|lua`, `|sh`, `|yaml`); a bare `@@NAME@@` accepts `[%w._/-]` only. No shell
  is involved, and every file is rendered before the first one is written.
- It never raises; every failure ends in `errors`.
