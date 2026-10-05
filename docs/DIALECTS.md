# Dialects

A spec file is run by a **dialect**: a shim that gives it the helpers it was written against
without editing it. With `dialect = "auto"` (the default of [`.testing.lua`](CONFIG.md)) the file
text decides; a configured name forces one dialect for every file.

All dialects share the rule that makes a verdict trustworthy: a failed check is **recorded** on
the open case and the file goes on, so every failure of a file is visible. The recorded call site
is the spec's own `file:line`. A case without a single assertion is a failure, a file that raises
while loading is an `error` case, and a file whose dialect is unknown is a `skip` (reported with
the reason, never green; red under `--strict`). Nothing is a quiet pass.

## Matrix

| Dialect | Spec shape | Cases per file | Used by | `H` / globals provided |
| --- | --- | --- | --- | --- |
| `a` | `return function(H) ... end` | 1 | lib.nvim and its siblings | `eq`, `ok`, `tmpfile`, `read_lines`, `with_patched`, `with_stdpath_config` |
| `b` | `return function(H) ... end` | 1 | markdown.nvim, diff.nvim | `eq`, `ok`, `scratch(ft)`, `tmproot`, `tmpdir()`, `canonical`, `write_file` |
| `c` | `return function(H) ... end` | 1 | images.nvim | `eq`, `ok`, `falsy`, `contains`, `scratch(lines, ft)`, `tmpdir(fn)`, `write` |
| `d` | `local t = require("harness")`, `function M.run()`, `return M` | 1 | spotlight.nvim | the plugin's own `harness` module, wrapped; its `t.ok`/`t.failures` counters become assertions |
| `h` | `return function(H) ... end` on the project's own `TESTS/harness.lua` | 1 | repositories with helpers of their own | every function of the project's harness, wrapped |
| `busted` | `describe` / `it` at top level | one per `it` | plenary.busted specs | `describe`, `context`, `it`, `specify`, `pending`, `xit`, `before_each`, `after_each`, `setup`, `teardown`, `assert` (luassert subset) |

`a`, `b` and `c` share the semantics of `H.eq` and `H.ok`: a file that only uses those two is `a`.
Reading an `H` key that does not exist answers `nil` (feature detection must not raise).

The sniffer never answers `h`: a project harness is a fact about the project, not the file. A
`return function(H)` spec whose `H` keys no fixed shim provides, in a project that has a
`TESTS/harness.lua`, runs as `h`.

### How `auto` decides

* An explicit override always wins and is reported as such.
* Comments and the contents of strings are not evidence: a commented-out `describe(` does not make a
  file a busted file.
* Top-level `describe(` / `it(` means `busted`; `require("harness")` plus a `run` function means `d`;
  `return function(H)` is `a`, `b`, `c` or `h` by the `H` keys it uses.
* Conflicting evidence (busted and `return function(H)` in one file, helpers of `b` and `c` at once)
  and no evidence at all give `unknown`. An `unknown` file is an error finding with the reason and
  its case is a `skip` that names the reason: nobody guesses silently, and `--strict` makes it red.

## Dialect `h`

The project's `harness.lua` is loaded and every function of its table is wrapped. An error that
reads `[file:line: ]FAIL ...` is a failed assertion: it is recorded and the call returns `false`.
Any other error propagates and ends the file as `error` (a helper's own bug is loud, not a failed
check). Functions whose body mentions `FAIL` are assertions and count as passes when they return.

Limits: a helper that calls other assertions and fails in the middle stops there; a harness whose
failures do not read `FAIL ...` is not recognised and its errors end the file as `error`.

## Dialect `d`

The plugin's `harness` module is loaded the way its own runner does (`require("harness")` with the
spec's directory on `package.path`) and restored afterwards. The file is one case. A harness
without the two counters (`passed`, `failures`) is not dialect `d`; the shim raises instead of
guessing.

## `busted` (plenary.busted specs, without plenary)

The shim executes a file like plenary does: `it` runs where it is written, so a spec that reads
state set by an earlier `it` of its `describe` body keeps working.

| Behavior | Detail |
| --- | --- |
| Case id | `<file>::<describe>::...::<it>`; a repeated id gets `#2`, `#3`, ... |
| `before_each` | all enclosing blocks, outermost first |
| `after_each` | plenary's order (outermost first), also when the body failed |
| `setup` / `teardown` | `setup` runs when registered, `teardown` when its block ends; a failing `setup` makes every `it` of that block an `error` |
| `pending(reason)` inside an `it` | ends the body at once; the case is `skip` (never green) |
| `pending(name, fn)` outside a body, `it(name)` without a function | a skipped case |
| A raise outside any `it` (describe body, top level, load error) | an `error` case of its own |
| A file that registers no case | a failing case: a spec that runs nothing proves nothing |

Supported luassert: `equal`/`equals`, `same`, `True`/`False` (`is_true`, `is_false`), `truthy`,
`falsy`, `nil` (`is_nil`, `is_not_nil`), `table`, `string`, `function`, `boolean`, `number`,
`userdata`, `thread`, `matches`/`match`, `error`/`errors` (`has_error`, `has_no.errors`), `near`;
the modifier words `is`, `are`, `has`, `does`, `was`, `not`, `no`, joined with `_` or `.`; and the
plain call `assert(value, msg)`.

Not supported, by design: using one of these **raises** a message that names it, so a spec that
needs it fails loudly instead of passing without having asserted:

* `spy`, `stub`, `mock`
* `insulate`, `expose`, `finally`, `xdescribe` (use `pending`)
* luassert extensions: custom assertion registration, `assert.message`, `assert.are.unique`, ...

Known differences from plenary: a failed assertion does not abort the body (all failures of a case
are visible), and `pending()` inside a body aborts it.
