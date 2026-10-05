# `testing.dialect`

Shims that let existing spec files run on the kernel (`testing.core`) without being edited. Every dialect has
the same entry point, `run_file(a, spec, opts) -> cases` (see [`init.lua`](init.lua)); the cases are finished
and the caller adds them to the result.

| Module | Dialect | Cases per file |
|--------|---------|----------------|
| [`harness_a`](harness_a.lua) | A: `return function(H)`, `H.eq/ok/tmpfile/read_lines/with_patched/with_stdpath_config` (lib.nvim) | 1 |
| [`harness_b`](harness_b.lua) | B: `H.eq/ok/scratch(ft)/tmproot/tmpdir()/canonical/write_file` (markdown.nvim, diff.nvim) | 1 |
| [`harness_c`](harness_c.lua) | C: `H.eq/ok/falsy/contains/scratch(lines, ft)/tmpdir(fn)/write` (images.nvim) | 1 |
| [`harness_d`](harness_d.lua) | D: `M.run()` with the plugin's own `harness` module (spotlight.nvim) | 1 |
| [`harness_project`](harness_project.lua) | h: `return function(H)` on the project's own `harness.lua` (14 repos with helpers of their own) | 1 |
| [`busted`](busted.lua) + [`luassert`](luassert.lua) | E: plenary.busted `describe` / `it` (dap, sandbox, github_stats, ...) | one per `it` |

A, B, C and h share `H.eq` / `H.ok` semantics: a failed check is **recorded** on the open case and the spec goes on, so every
failure of a file is visible (P1). The recorded call site is the spec's own `file:line`. An unknown `H` key reads `nil`.

## Dialect h

The project's `harness.lua` is loaded and every function wrapped. An error that reads `[file:line: ]FAIL ...` is a
failed assertion (recorded, call returns `false`); any other error propagates (a helper's bug ends the file as `error`).
Functions whose body mentions `FAIL` are assertions and count as passes when they return.

## Dialect D

The plugin's `harness` module is loaded as its runner does (`require("harness")`); its functions are wrapped and what
`t.passed` / `t.failures` gain is recorded as assertions. `package.path` and `package.loaded.harness` are restored.

## Busted

Executed like plenary does: `it` runs where it is written. Ids are `<file>::<describe>::...::<it>` (`#2` for repeats).
`before_each` outer block first, `after_each` in plenary's order (outer block first), `setup` when registered,
`teardown` at the end of its block. `pending(reason)` inside a body ends it as `skip`. A raise outside an `it`
(describe body, top level, setup, load error) is an `error` case of its own; a file without a case fails.
Unsupported (raise, never pass): `spy`, `stub`, `mock`, `insulate`, `expose`, `finally`, `xdescribe`, luassert
assertions beyond the supported list (`luassert.supported()`).
Known differences to plenary: a failed assertion does not abort the body; `pending()` inside a body aborts it.

`run_file(a, spec, { select = fn(id), dry = true, on_case = fn(case) })` also returns a listing of case ids.
