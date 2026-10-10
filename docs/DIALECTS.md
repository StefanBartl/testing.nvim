# Dialects

A spec file is run by a **dialect**: a shim that gives it the helpers it was written against
without editing it. With `dialect = "auto"` (the default of [`.testing.lua`](CONFIG.md)) the file
text decides; a configured name forces one dialect for every file.

All dialects share the rule that makes a verdict trustworthy: a failed check is **recorded** on
the open case and the file goes on, so every failure of a file is visible. The recorded call site
is the spec's own `file:line`. A case without a single assertion is a failure, a file that raises
while loading is an `error` case, and a file whose dialect is unknown is a `skip` (reported with
the reason, never green; red under `--strict`). Nothing is a quiet pass.

### A spec that asks "does this check fail?"

There is one exception to "recorded", because it is the only way a spec can ask that question:
a failed check inside a `pcall` / `xpcall` **that the spec wrote**
(`pcall(function() H.eq(1, 2) end)`, `pcall(H.with_patched, t, k, v, function() H.eq(1, 2) end)`) is not
recorded but **raised** (`FAIL <msg>: expected X, got Y`), as on the projects' own runners. Checks that
pass are recorded everywhere.

What decides is the protected call that would **catch** the raise: the innermost one between the check
and the start of the case.

* It counts when the code that called `pcall` is in the spec's own file, and `pcall` / `xpcall` was
  called under that name.
* The harness and the runner are passed over, because they clean up and raise again
  (`with_patched`, the busted hooks). The harness is every file that defines a function of `H`, so a
  harness split over several files, or with helpers one table level down, counts.
* A protected call of anything else — the plugin under test protecting a callback (`pcall(cb)` in an
  event emitter, `safe_call`) — would catch the raise, and whether it passes it on is not known: if it
  kept the error the failed check would vanish and the case would pass. So there the check is recorded
  as usual.

The rule is a guess from the call stack and errs towards **recording**: a question it does not
recognise fails loudly in the spec, a check is never raised into a protected call it cannot attribute.
What is not recognised, and records:

* `return pcall(fn)` in tail position, and a `pcall` called under another name (`local try = pcall`).
  LuaJIT has no `istailcall`, but the call site is named after the helper. Write
  `local ok, err = pcall(...)` in the spec.
* A question asked from another file than the spec's: a wrapper that returns the spec
  (`return support.spec(function(H) ... end)`), a dispatcher that runs cases from a shared file, a helper
  file (`util.fails(fn)`), `vim.F.npcall`.
* A check on another coroutine than the one that started the case, and a stack more than 1000 frames
  above it.

What can still go missing, because the catch is not a Lua `pcall`: Neovim runs the callbacks of
`vim.schedule`, autocmds, keymaps, timers and `nvim_buf_attach` under its own protected call. A check
that fails there while a `pcall` of the spec is further out is raised into Neovim's catch, which prints
an error and goes on. The `scheduled_error` guard (default `error`, [GUARDS.md](GUARDS.md)) turns most of
these into a red case, with the message but without `file:line`. A mock inside the spec that protects a
callback and throws the error away cannot be told from a question either.

A spec that wraps its body in `pcall` for cleanup and re-raises (`assert(ok, err)`) stops at its first
failed check, as it did on the old runner; the file then ends as an `error` case carrying that check's
message.

## Matrix

| Dialect | Spec shape | Cases per file | Used by | `H` / globals provided |
| --- | --- | --- | --- | --- |
| `a` | `return function(H) ... end` | 1 | lib.nvim and its siblings | `eq`, `ok`, `tmpfile`, `read_lines`, `with_patched`, `with_stdpath_config` |
| `b` | `return function(H) ... end` | 1 | markdown.nvim, diff.nvim | `eq`, `ok`, `scratch(ft)`, `tmproot`, `tmpdir()`, `canonical`, `write_file` |
| `c` | `return function(H) ... end` | 1 | images.nvim | `eq`, `ok`, `falsy`, `contains`, `scratch(lines, ft)`, `tmpdir(fn)`, `write` |
| `d` | `local t = require("harness")`, `function M.run()`, `return M` | 1 | spotlight.nvim | the plugin's own `harness` module, wrapped; its `t.ok`/`t.failures` counters become assertions |
| `h` | `return function(H) ... end` on the project's own `TESTS/harness.lua` | 1 | repositories with helpers of their own | every function of the project's harness, wrapped |
| `script` | a self-running file: own counters, `print("[FAIL] ...")`, ends with `os.exit(n)` | 1 | pickers.nvim, cmdlog.nvim, filetree.nvim | nothing is provided: the file is started as a program in a child editor of its own |
| `busted` | `describe` / `it` at top level | one per `it` | plenary.busted specs | `describe`, `context`, `it`, `specify`, `pending`, `xit`, `before_each`, `after_each`, `setup`, `teardown`, `assert` (luassert subset) |

`a`, `b` and `c` share the semantics of `H.eq` and `H.ok`: a file that only uses those two is `a`.
Reading an `H` key that does not exist answers `nil` (feature detection must not raise).

The sniffer answers `h` in one situation only: a `return function(H)` spec whose `H` keys no fixed shim
provides (or provides with different semantics, e.g. a deep-equal `H.eq`), in a project that has a
`TESTS/harness.lua`. An explicit `dialect = "h"` is never second-guessed.

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

The project's `harness.lua` is loaded and every function of its table is wrapped, so the harness'
own state stays one coherent object. The rule is **never greener than the project's own harness**:

* An error that reads `[file:line: ]FAIL ...` is a failed assertion: it is recorded and the call
  returns `false` (inside a `pcall` the spec wrote it is raised instead, see [A spec that asks "does this check fail?"](#a-spec-that-asks-does-this-check-fail)). Functions
  whose body mentions `FAIL` are assertions and count as passes when they return.
* A helper that only **runs a callback** (`H.notifications(fn)`, `H.notices(fn)`) is not an assertion even though the assertions inside the callback raise the project's counter (`H.checks`): the callback's assertions are recorded one by one, the helper is counted only when the counter grew by more than the assertions recorded inside the call. The IR therefore follows the project's counter (fileops 52 of 52, emojis 929 of 929).
* A collector (`H.check(name, fn)`: it catches the callback's error itself and appends to
  `H.failures`) is recorded as one assertion, failed when the harness collected a failure.
* After the file ran, what the harness recorded and the adapter did not see is added as failures:
  growth of a failure list or counter (`H.failures`, `H.failed`, `H.fail_count`), failure lines the
  harness printed (`[FAIL] ...`, `FAIL ...`, `not ok ...`) through `print`, `io.write`,
  `io.stdout:write`, `io.stderr:write` or `nvim_out_write`, and, as a last net for a harness no
  convention describes, any number or list field of `H` whose **name** contains `fail`, `err`, `bad`
  or `broken` and that grew while the file ran (`H.n_bad`, `H.errors`, `H.late_errors`). A spec whose
  own harness says "7 failed" is red here with those 7.
* Any other error propagates and ends the file as `error` (a helper's own bug is loud, not a failed
  check).

Limits, honestly: a helper that calls other assertions and fails in the middle stops there; a harness
that reports its failures only in a way no convention knows (not by raise, not in a field named like
a failure, not in a printed line) is not seen; and a harness that counts passes under another name
makes a green file "a case without assertions" (loud, never green). New conventions are data: see
`lua/testing/dialect/harness_conventions.lua`.

## Dialect `script`

A file that runs itself (`nvim -l TESTS/units.lua`): it counts its own checks, prints `[ OK ]` /
`[FAIL]` lines and ends with `os.exit(failed == 0 and 0 or 1)`. It cannot run in the runner's process
(it would end it), so it runs in a child editor of its own, by default started like `nvim -l`
(`host = "l"`, `--host` overrides). The file is **one case**; its verdict is the exit code **and** the
`[FAIL]` lines it printed (a script that prints failures and still exits `0` is red), a signal or a
native crash is `crash`, a limit exceeded is `timeout`. A summary of `0 passed` is a case without
assertions. The sniffer recognises scripts by a top-level `os.exit(` / `cquit` and no `describe` /
`function(H)`; a script without the `_spec` suffix needs a `spec_pattern` ([CONFIG.md](CONFIG.md)).

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
| A file that registers no case | a failing case (`assertions = "error"`, the default): a spec that runs nothing proves nothing. Under `assertions = "warn"` it is **one `skip` case** with the reason `no case registered on this platform` and a warning note; the terminal lists such files after the report. A spec that registers its cases per platform (`if windows then it(...) end`) has none on the others, which is not a failure. A skip is never silent and never green under `--strict` (exit 1). |

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
