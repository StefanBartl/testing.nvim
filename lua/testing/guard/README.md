# `testing.guard`

Guards v2 (M2): safety nets around a spec and the effects ledger. Installable in any Neovim (the
child bootstrap and the in-process driver call the same API). Full documentation:
[docs/GUARDS.md](../../../docs/GUARDS.md). **Nets, not a sandbox.**

| Module | Purpose |
|--------|---------|
| [`testing.guard`](init.lua) | `install(cfg) -> handle`; `handle:begin_case / end_case / snapshot / check / collect / restore / uninstall`, tags, findings |
| [`testing.guard.config`](config.lua) | Defaults, merge and validation of the configuration (pure) |
| [`testing.guard.patch`](patch.lua) | Restorable monkeypatches (the one place functions are replaced) |
| [`testing.guard.fs`](fs.lua) | Writes outside the allowed roots: wrapped entry points plus a bounded tree snapshot |
| [`testing.guard.state`](state.lua) | State-leak snapshot before / after, named findings, soft isolation (`restore`) |
| [`testing.guard.scheduled_error`](scheduled_error.lua) | Errors in `vim.schedule` / luv callbacks / autocmds, `vim.notify(ERROR)` |
| [`testing.guard.prompt`](prompt.lua) | `input` / `confirm` / `getchar` / `vim.ui.*` never block; scripted answers |
| [`testing.guard.deprecation`](deprecation.lua) | `vim.deprecate` captured (warn, error under strict) |
| [`testing.guard.process_net`](process_net.lua) | Processes and network blocked by default, logged, released by tag / config / `allow` |
| [`testing.guard.clock`](clock.lua) | Opt-in fake clock and seed (`@clock`, `advance(ms)`) |
| [`testing.core.ledger`](../core/ledger.lua) | The effects ledger: bounded, redacting, mergeable, deterministic; feeds the IR `effects` |
