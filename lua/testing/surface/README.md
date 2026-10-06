# `testing.surface`

The machine-readable surface of a plugin (keymaps, commands, composer routes, autocmds, health, api,
config keys) and how much of it the specs exercise. Full documentation, limits and the integration
contract: [docs/SURFACE.md](../../../docs/SURFACE.md). It reports first; a threshold of `0` never fails.

| Module | Purpose |
|--------|---------|
| [`testing.surface`](init.lua) | `main(argv, services) -> code, text` (`testing surface`, `:Testing surface`), `report(root, opts)`, `collect`, `read`, `hits`, `annotate_ir` |
| [`testing.surface.ids`](ids.lua) | Stable `kind:name` ids, the mode suffix of bindings, `action:` aliases (pure) |
| [`testing.surface.read`](read.lua) | The registries of lib.nvim and the live editor -> entries, in this editor |
| [`testing.surface.collect`](collect.lua) | The same in a child editor (`testing.rpc`) after the plugin's `setup()` |
| [`testing.surface.track`](track.lua) | The tracking layer: `install` / `begin_case` / `end_case` / `collect` / `uninstall`, `hook_runner` for a minit |
| [`testing.surface.coverage`](coverage.lua) | Pure: ratio, statuses, thresholds, baseline and diff, hits from a Result-IR or a sink |
| [`testing.surface.render`](render.lua) | Text table, markdown, JSON |
