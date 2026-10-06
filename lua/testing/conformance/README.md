# `testing.conformance`

The conformance suite K1 .. K15: the rules of the gates that a program can decide, run on a repository with a
`.testing.lua`, reported as data (JSON), Markdown, terminal lines and a Result-IR. Full description, the
table of checks and the configuration: [docs/CONFORMANCE.md](../../../docs/CONFORMANCE.md).

| Module | Purpose |
|--------|---------|
| [`testing.conformance`](init.lua) | The API: `run`, `main`, `parse_args`, `json`, `terminal`, `markdown`, `to_result`, `rules_bridge`, `exit_code`, `checks`, `manual` |
| [`runner`](runner.lua) | Builds the context, runs the checks under `xpcall`, applies the waivers, summarizes |
| [`catalog`](catalog.lua) | The checks in order and the manual rules |
| [`checks/kNN_*.lua`](checks) | One module per check: `{ id, title, rules, kind, level, run(ctx) }` |
| [`rules/`](rules) | The static rules K15 runs (`tooling`, `layout`, `hygiene`) |
| [`runtime`](runtime.lua) | The child-editor sessions (`main`, `keymaps_off`, `require`) |
| [`probe`](probe.lua) | The code that runs INSIDE the child editor; returns plain data, judges nothing |
| [`settings`](settings.lua) | Loads `.testing.lua` and validates the suite's `conformance` table (waivers need a reason) |
| [`fsx`](fsx.lua) | Read-only access to the repository: literal paths, bounded reads, never out of the root |
| [`render`](render.lua) | JSON, terminal lines, Markdown, Result-IR |
| [`rules_bridge`](rules_bridge.lua) | The soft bridge to rules.nvim: manual rules, drift |
| [`util`](util.lua) | Findings, safe display of repository text, multiset difference |

A new check is one file in `checks/`, one line in `catalog.ORDER`, a passing and a failing case in
`TESTS/testing/conformance_*_spec.lua`, and a row in docs/CONFORMANCE.md. A check never judges text it did not
read through `ctx.fs`, never writes, and returns `na`, `blocked` or `error` with a reason instead of guessing.
