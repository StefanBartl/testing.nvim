# Dialects

A spec file is run by a **dialect**: a shim that gives it the helpers it was written against
without editing it. With `dialect = "auto"` (the default of [`.testing.lua`](CONFIG.md)) the file
text decides; a configured name forces one dialect for every file.

All dialects share the rule that makes a verdict trustworthy: a failed check is **recorded** on
the open case and the file goes on, so every failure of a file is visible. The recorded call site
is the spec's own `file:line`. A case without a single assertion is a failure, a file that raises
while loading is an `error` case, and a file whose dialect is unknown is an `error` case with the reason (never a
skip, never green). Nothing is a quiet pass.

## A spec that asks "does this check fail?"

**The recommended way to ask is explicit**: `local ok, err = H.ask(function() H.eq(1, 2) end)` (dialects a, b and
c; in the kernel `a.ask(fn, ...)`). A failed check inside `ask` raises (also when no `pcall` of the spec stands
between it and the `ask`, and whatever else is further out), is caught there and leaves nothing in the case. It is
**recorded** instead when a protected call of the code under test, a message handler or a C function (`xpcall` only)
lies between the check and the `ask`: that call may keep the error, and a failed check must never vanish.
`a.error`, `a.no_error` and luassert `has_error` / `has_no.errors` are built on it, so
`assert.has_error(function() assert.equal(1, 2) end)` passes in busted style, as in luassert, with or without a
`pcall` further out. Which protected call counts as the spec's own is decided by the rules below also inside an `ask`.

What follows is the **fallback for specs written before `ask`** (the project's own `pcall` idiom keeps working, and
`lib.nvim`'s specs use it). There is one exception to "recorded", because it is the only way a spec can ask that
question without `ask`: a failed check inside a `pcall` / `xpcall` **that the spec wrote**
(`pcall(function() H.eq(1, 2) end)`, `pcall(H.with_patched, t, k, v, function() H.eq(1, 2) end)`) is not
recorded but **raised** (`FAIL <msg>: expected X, got Y`), as on the projects' own runners. Checks that
pass are recorded everywhere.

What decides is the protected call that would **catch** the raise: the innermost one between the check
and the start of the case.

* It counts when the code that called `pcall` is in the spec's own file (the file the dialect loaded; so
  a question the spec asks itself is answered even when a framework of another file starts it), and
  `pcall` / `xpcall` was called under that name as a global, a local or an upvalue.
* The harness and the runner are passed over, because they clean up and raise again
  (`with_patched`, the busted hooks). The harness is `harness.lua` and the files below its directory that
  define a function of `H`, directly or one table level down (own fields, no metamethods), so a harness
  split over several files counts. A function of `H` that comes from anywhere else, such as
  `H.sut = require("plugin")`, is the code under test and does not count. Paths are compared absolute and
  normalized (a helper found through `./?.lua` counts, `TESTS/../lib/x.lua` is not below `TESTS`), and a file
  below `lua/`, `plugin/`, `after/`, `ftplugin/`, `autoload/` or `src/` of the harness directory never counts: a
  `harness.lua` in the project root has the plugin there (a harness in the project root counts only the harness
  file itself and the files below `tests/`, `test/`, `spec/` and `specs/`, whatever the capitalisation: `TESTS/`
  counts; a single-file plugin in the root is the code under test, and a support module in the root or in
  `helpers/` is not the harness, so its checks are recorded). The files are not read, so a support module of
  the harness directory that is exported through `H` and keeps the error of its own `pcall` (an event bus
  that logs a failing handler) counts as harness: keep it out of the harness directory, or make it raise
  again. No spec file counts, even when it put its helpers into a harness table that outlives the file.
* That premise does not hold for a harness helper that **catches on purpose**: `H.throws(fn)`
  (`not pcall(fn)`), or a retry or poll helper (`H.eventually(fn)`: `pcall(fn)` in a loop, raising only the
  last error). Its `pcall` is passed over too, so a failed check inside its callback is **recorded** and the
  callback returns normally: the helper sees success, the question is answered wrongly and the case goes
  red (a retry helper never retries, its first failed poll stays recorded). It is never green. Ask the
  question with a `pcall` in the spec file (`pcall(function() H.eq(1, 2) end)`), poll with a predicate
  or a `pcall` loop in the spec, or let the helper raise a `FAIL ...` error of its own: a helper whose
  body does that is an assertion (see [Dialect `h`](#dialect-h)), and a check inside its callback is raised.
* A protected call of anything else is not passed over: the plugin under test protecting a callback
  (`pcall(cb)` in an event emitter, `safe_call`), or a framework of another file running the spec under a
  `pcall` of its own. It would catch the raise, and whether it passes it on is not known: if it kept the
  error the failed check would vanish and the case would pass. So there the check is recorded as usual.

The rule is a guess from the call stack and errs towards **recording**: a question it does not
recognise fails loudly in the spec, a check is never raised into a protected call it cannot attribute.
What is not recognised, and records:

* `return pcall(fn)` in tail position, a `pcall` called as a field or a method, and one called under
  another name (`local try = pcall`). LuaJIT has no `istailcall`, but the call site is named after the
  helper. Write `local ok, err = pcall(...)` in the spec.
* A question asked from another file than the spec's: a dispatcher that runs cases from a shared file, a
  helper file (`util.fails(fn)`), `vim.F.npcall`.
* A check on another coroutine than the one that started the case, and a stack more than 500 frames
  above it.
* A check in the message handler of an `xpcall` (`xpcall(fn, function(e) H.eq(e, "x") end)`) is not a
  question: the handler runs on top of the frame the error comes from, and a raise there is lost (LuaJIT
  answers "error in error handling"). It is recorded after `error()` / `assert()` and when a C function sits
  between the check and the `xpcall` (a `coroutine.wrap` that rethrows, a failing `require`). Only a runtime
  error of Lua code (a nil index) cannot be told from the function: a failed check in that handler is lost.
  Check the returned message after `xpcall` returned instead.
* `return pcall(check)` as the condition of a `vim.wait` or in a retry helper records the first failed
  attempt for good; write `local ok = pcall(check); return ok`. A helper file for questions
  (`util.fails(fn)`) has to be handed the `pcall` by the spec: the call must stand in the spec file.

What works as a question: `local ok, err = pcall(fn)`, `xpcall(fn, debug.traceback)`,
`pcall(H.with_patched, ...)`, `pcall(H.eq, ...)`, `local pcall = pcall`, and a `pcall` inside a helper
that the spec file defines itself. A spec made only of answered questions has no recorded check: finish
with `H.ok(not ok, ...)` so the case has one.

What can still go missing, because the catch is not a Lua `pcall`:

* Neovim runs the callbacks of `vim.schedule` (while the spec waits), autocmds, keymaps, timers and
  the buffer callbacks of typed keys under its own protected call. A check that fails there while a
  `pcall` of the spec is further out is raised into Neovim's catch, which prints an error and goes on.
  The `scheduled_error` guard (default `error`, [GUARDS.md](GUARDS.md)) turns these into a red case,
  with the message but without `file:line`. It finds the error in `:messages`, which keeps 500 entries: a
  case that prints about 500 more messages after the swallowed check pushes the error out and stays
  green (only a `vim.schedule` callback is still seen). Callbacks that run synchronously for the caller
  (`nvim_buf_set_lines`, `:normal`, `nvim_buf_call`, `:doautocmd`) hand the raise on to the spec's
  `pcall`, which answers; `vim.on_key` runs under a Lua `xpcall` of the runtime, so its checks are recorded.
* A mock inside the spec that protects a callback and throws the error away cannot be told from a question.
* Code is told apart by the name of its chunk (`debug.getinfo(...).source`), the only thing a frame
  carries. Code that is loaded under the name of the spec file or of the harness
  (`load(text, "@" .. spec_path)`) is taken for it. Only a deliberate construct does that.
* A guessed question leaves a trace: a case that raised failed checks only because the stack looked like a
  question carries the note "N failed check(s) were raised into a pcall of the spec", so a swallowed failure (a
  mock, a handler, a callback of Neovim) is not completely invisible to whoever reads the Result IR (`--json`,
  `cases[].notes`; the terminal, JUnit and GitHub reporters do not print notes). A question asked with `ask` leaves
  none, and neither does a raise that got out of the spec and was booked as a failure (below).
* A plugin below the runner's own directory (testing.nvim testing its own modules) counts as the runner.

A spec that wraps its body in `pcall` for cleanup and re-raises (`error(err, 0)`, `error(err)`, `assert(ok, err)`)
stops at its first failed check, as it did on the old runner. The check is booked as a **failure** (verdict
`fail`, the message of the check, the line of the check, not the line that raised it again); the rest of that spec
body does not run (in busted: the rest of that `it`, the next one runs). An error that is no failed check (`error("boom")`, a nil index) still ends the file as an
`error`. This holds in every dialect that runs its checks through the kernel (a, b, c, h, busted).

**A failed check outside any case** (a `describe` body, the top level of a file) has no case to be recorded in, so it
raises. Should a `pcall` of the code under test (an emit / safe-call wrapper) keep that raise, the file would be green.
The kernel therefore also keeps every such failed check, and the runner books them after the file as one failed case,
`checks outside a case`, with the message and the call site of each check (a raise that got out of the file is
reported once, as the `error` case it already is; in `isolated = "case"` every case child sees the same failure and the
file still reports it once). The same holds for the `busted` dialect's luassert chain (`assert.is_true(...)`,
`assert.are.equal(...)`) in a `describe` body or in `setup` / `teardown`.

Two limits, both on purpose. Outside a case there is no stack boundary that tells a `pcall` of the code under test from
a `pcall` the spec wrote itself, so a spec's own `pcall` around a check at that level is booked as well (a false red,
never a false green): ask with `assert.has_error(...)` there, or move the question into an `it`. And the plain call
`assert(value, msg)` keeps the contract of Lua's builtin: it raises its message, and a `pcall` that keeps the raise keeps
it, in a `describe` body as in an `it`.

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
* Top-level `describe(` / `it(` means `busted`, unless a file with the harness entry `return function(H)` declares the helper itself (`local function describe`, `local it = ...`): that is its own helper, not busted (text based, so globals and parameters are not recognised); `require("harness")` plus a `run` function means `d`;
  `return function(H)` is `a`, `b`, `c` or `h` by the `H` keys it uses.
* Conflicting evidence (busted and `return function(H)` in one file, helpers of `b` and `c` at once)
  and no evidence at all give `unknown`. An `unknown` file is an error finding with the reason and
  its case is an `error` that names the reason: nobody guesses silently, and nothing about it is green.

## Dialect `h`

The project's `harness.lua` is loaded and every function of its table is wrapped, so the harness'
own state stays one coherent object. The rule is **never greener than the project's own harness**:

* An error that reads `[file:line: ]FAIL ...` is a failed assertion: it is recorded and the call
  returns `false` (inside a `pcall` the spec wrote it is raised instead, see [A spec that asks "does this check fail?"](#a-spec-that-asks-does-this-check-fail)). Functions
  whose body mentions `FAIL` are assertions and count as passes when they return.
* A helper that only **runs a callback** (`H.notifications(fn)`, `H.notices(fn)`) is not an assertion even though the assertions inside the callback raise the project's counter (`H.checks`): the callback's assertions are recorded one by one, the helper is counted only when the counter grew by more than the assertions recorded inside the call. The IR therefore follows the project's counter (fileops 52 of 52, emojis 929 of 929).
* A collector (`H.check(name, fn)`: it catches the callback's error itself and appends to
  `H.failures`) is recorded as one assertion, failed when the harness collected a failure. A spec that tests
  the harness may take an expected failure back out of `H.failures`: the assertion (and the failure line it
  printed) is withdrawn.
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

[A spec that asks "does this check fail?"](#a-spec-that-asks-does-this-check-fail) does not apply
here: the checks are the plugin's own `t.*`, which record into its counters and never raise (as on the
plugin's own runner), so `pcall(function() t.eq("x", 1, 2) end)` returns `true` and the failure stays
recorded. The same holds for dialect `script`, which runs in a child editor. A spec that tests the
harness may take an expected failure back out of `t.failures`: the failure is then withdrawn from the case.

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
are visible; inside a `pcall` the spec wrote it raises, as in plenary), and `pending()` inside a body
aborts it.
