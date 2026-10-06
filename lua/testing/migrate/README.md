# testing.migrate

Turns a repository that runs plenary / busted / a hand-written runner into one that runs on testing.nvim,
with its specs unchanged. Read-only analysis, the plan as data, one function that writes.

```lua
local migrate = require("testing.migrate")
local report = migrate.analyze(root, { fleet_root = dir_with_the_other_repos })
local plan   = migrate.plan(report)       -- plan.ops, plan.notes, plan.risks, plan.empty
print(migrate.render(plan, { format = "text" }))
migrate.apply(plan, { apply = true })     -- clean git tree required; dry run without apply = true
```

User documentation: [docs/MIGRATING.md](../../../docs/MIGRATING.md). Command: `:Testing migrate` and
`testing migrate` ([docs/BINDINGS.md](../../../docs/BINDINGS.md)).

| Module | Job |
| --- | --- |
| [`init`](init.lua) | The facade: `analyze`, `plan`, `render`, `to_json`, `apply`, `run`, `main(argv)` (what the command line calls; exit codes 0 / 1 `--check` / 2 refused / 3 unreadable). |
| [`analyze`](analyze.lua) | Specs and dialects (through `testing.discover`, behind an adapter), the repository's own harness, plenary use, CI structure, dependencies, the policy suggestions, risks. Plain data plus `texts`, the files that were read. |
| [`plan`](plan.lua) | The operations: `.testing.lua`, `scripts/test.sh`, `TESTS/minimal_init.lua`, the workflows. Each op carries the complete new text, the unified diff and the removed lines. Idempotent: each op tests for its own result. |
| [`legacy_init`](legacy_init.lua) | Splits the old `scripts/minimal_init.lua` into blocks: what the new `TESTS/minimal_init.lua` replaces (header, runtimepath, dependency lookup, anything that starts plenary) and what it carries over (swap / shada, fake clipboard, options). Pure. |
| [`format`](format.lua) | Runs `stylua` with the repository's `stylua.toml` on the Lua text the plan creates (stdin, argv, cwd = repository); a missing stylua becomes a note. Seams `exe` / `run` for specs. |
| [`ci`](ci.lua) | A GitHub Actions workflow parsed and edited as TEXT (line by line, no YAML library, no reformatting). |
| [`fleet`](fleet.lua) | `require` scan (comments and strings left out) and the module -> repository mapping. |
| [`apply`](apply.lua) | The only writer: clean git tree, every op validated first (path stays below the root, no symlink, create targets absent, modify / delete targets unchanged), atomic writes, deletions. |
| [`render`](render.lua) | The plan as Markdown / terminal text / JSON. Everything from the repository is escaped on the way out. |
| [`text`](text.lua) | Line splitting that round-trips CRLF and a missing final newline, unified diffs, `show` (escaping), path checks. |

## Rules

* `analyze` and `plan` read; they never write or execute a file of the repository (`.testing.lua` is read
  as text, never loaded). The one process is `stylua`, started without a shell on the text of a file the
  plan creates (see `format`).
* `apply` does nothing without `apply = true`, refuses a dirty or unknown git state, and validates
  everything before the first byte is written.
* The specs, `TESTS/harness.lua` and `TESTS/run.lua` are never in a plan.
* Hostile input (file names with quotes or `$(...)`, escape sequences in a workflow, paths with `..`) is
  quoted for the language it lands in (`testing.scaffold.render`) or refused; it never reaches a shell.
