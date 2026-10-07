# `testing.core`

The kernel of testing.nvim: the **Result-IR** and the **collecting assertions**. Pure Lua, no editor
API apart from the lazy `lib.nvim.json` call in `result.encode`, so everything here is testable in
plain `nvim -l` runs and could be driven by any front end (runner, reporter, dialect shim, adapter).

| Module | Purpose |
|--------|---------|
| [`testing.core.result`](result.lua) | The IR (`schema_version = 1`): builders, verdict rules, summary, deterministic JSON, path placeholders, validator |
| [`testing.core.assert`](assert.lua) | Assertions that record instead of raising, bound to the current case |
| [`@types/`](@types/init.lua) | `Testing.Result.*`, `Testing.Assert.*` |

## The IR

```lua
local result = require("testing.core.result")

local res = result.new({ project_key = "demo.nvim@a1b2", nvim = "0.12.0", os = "windows", jobs = 1 })
result.add_case(res, case)       -- a finished case, see below
result.finalize(res)             -- recount res.summary from res.cases

local json, err = result.encode(res, { roots = { repo = root, home = home, tmp = tmp, state = state } })
local ok, problems = result.validate(res, { forbid = { "bob" } })
```

Shape (the contract; reporters, cache, UI and adapters know nothing else):

```
{ schema_version = 1,
  run     = { id, root, project_key, nvim, os, arch?, git?, seed?, jobs, duration_ms, argv },
  cases   = { { id, file, line?, tags, status, duration_ms, retries,
                assertions = { { ok, kind, msg?, expected?, actual?, file?, line? } },
                effects = { spawned, network, fs_outside_tmp }, artifacts, notes,
                error? = { message, traceback }, reason?, flaky? } },
  summary = { pass, fail, error, skip, xfail, xpass, timeout, crash } }
```

* **Ids** are `file::describe::...::case[#param]` (`result.case_id`), the key for cache, history and
  quarantine.
* **Status** is one of `pass | fail | error | skip | xfail | xpass | timeout | crash`. `skip` is never
  green; `xpass` is an error (strict, like pytest).
* **A case without assertions fails** (`result.finish_case`): a test that asserts nothing proves
  nothing. The IR then carries one synthetic failed assertion of kind `no_assertions` with the reason.
  An empty case is never mapped to `xfail`.
* **Passing assertions carry no `expected`/`actual`**; failures carry both as deterministic printable
  strings (keys sorted, no addresses). That keeps large suites cheap.
* **Placeholders**: `encode({ roots = ... })` replaces the repo root, home, temp and state directory
  by `<REPO>`, `<HOME>`, `<TMP>`, `<STATE>` (longest root wins; both slash styles; pass
  `case_insensitive = true` on Windows) and replaces invalid UTF-8 bytes by `?`, so the JSON is the
  same on every machine and always decodable.
* **Determinism**: `lib.nvim.json.encode` sorts object keys, so the same IR is the same bytes.
  The only inputs that vary between runs are the ones the caller supplies (run id, durations).
  A traceback names its call site, so it differs when the throwing case is started from another
  line.
* **`result.validate`** checks shape, the status enum, unique ids, `id` starts with `<file>::`, the
  summary against a recount, status/assertion consistency (a `pass` needs at least one assertion and
  none failed), and that no user-home path (`/Users/x`, `C:\Users\x`, `/home/x`) and none of
  `opts.forbid` (e.g. the user name, case-insensitive) survived. Works on the in-memory table and
  on a decoded JSON file. At most 100 problems are returned. With `opts.leak_warnings` (a table) the
  leak checks (user-home path, forbidden word, e-mail) fill that table instead of failing the result;
  `testing.run.inproc.sanitize` uses it, so a cosmetic privacy finding becomes `warnings` in the IR.

## Collecting assertions

```lua
local assert_mod = require("testing.core.assert")
local a = assert_mod.new()            -- one context per worker

local case = a.run_case({ file = "TESTS/x_spec.lua", describe = "demo", name = "adds" }, function(c)
  c.eq(1 + 1, 2, "adds")              -- (actual, expected, msg): the order of dialect A's H.eq
  c.same({ 1 }, { 1 })                -- deep equality
  c.matches("abc", "^a")              -- Lua pattern
  c.error(function() error("x") end, "x")
end)
-- case.status, case.assertions, case.error ...
```

* A failed check **never raises**: it appends `{ ok = false, kind, msg, expected, actual, file, line }`
  to the bound case, returns `false`, and the body goes on. Every failure of a case is therefore
  visible, not just the first (problem P1).
* `file`/`line` come from `debug.getinfo` at the caller of the assertion. A wrapper that is **not** a
  tail call must set `a.depth = 1` (a tail call erases its frame and needs nothing).
* A thrown error in the body ends only that body: status `error`, `case.error.message` (first line) and
  `case.error.traceback` from `lib.lua.error.safe_call`; assertions recorded before it are kept. A
  thrown non-string value is reported as `non-string error value (table)` rather than a raw address.
* An assertion with **no case bound** raises: a silent drop would hide failures. Bind with
  `a.begin_case(opts)` / `a.end_case(finish?)`, or use `a.run_case(opts, body, finish?)`.
* `eq` is strict (`==`, tables by identity); `same` / `deep_eq` compare deeply (metatables ignored).

| Function | Records |
|----------|---------|
| `eq`, `same`, `deep_eq` | equality (kind `eq` / `same`) |
| `ok`, `not_ok`, `is_nil`, `not_nil` | truthiness / nil checks |
| `matches(str, pattern)`, `has(haystack, needle)` | Lua pattern / plain substring |
| `error(fn, pattern?)`, `no_error(fn)` | `fn` must / must not throw (`no_error` also returns its result) |
| `fail(msg)` | an explicit failure |

`assert_mod.inspect(v)` and `assert_mod.deep_equal(a, b)` are the pure helpers behind the messages
(`lib.lua.dump` walks `pairs` order and prints function addresses, which an IR cannot use).

## Clock

`assert_mod.new({ clock = fn })` takes a monotonic millisecond clock (default `vim.uv.hrtime` when it
exists, else `os.clock`), so durations are testable.

## Tests

`TESTS/testing/core_result_spec.lua` and `TESTS/testing/core_assert_spec.lua`.
