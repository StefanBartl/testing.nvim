# The last result (`testing.state`)

`runs.jsonl` ([CLI.md](CLI.md), `--lf`) keeps only the ids of the red cases. A UI needs more: the counters,
the duration, which cases are green, the message of a red one, and whether the file changed since the case
ran. `testing.state` is that shared state for an explorer, a hover, a quickfix list, diagnostics and a
statusline. It is a pure data module: no window, no buffer, no keymap.

```
stdpath('state')/testing/<project>/last.json   the last result per case, merged over partial runs
stdpath('state')/testing/<project>/prev.json   the one before it
```

Every run writes it after the history (`testing.run.project`). It is a convenience, never part of the verdict:
a failing write is a note (`testing: note: result not stored: ...`) and the run goes on.

## What it holds

Per case: `id`, `file`, `line`, `status`, `duration_ms`, `flaky`, `describe` (the titles, outermost first),
`name`, `fails` (every failing assertion as `{ line, msg }`, at most 20; the hover lists them for a file that is one
case) with `fails_total` (the count of ALL failing assertions, written only when it is above the 20 kept, read back
only as a whole number above `#fails` and up to 1,000,000), and for a red or skipped case `message` (first line of the first failing assertion, the error, or
the skip reason), `expected` and `actual`. Per spec file: `{ mtime_ns, size, run, ts }` from when its result
was recorded. The Result-IR carries `describe` and `name` as additive optional fields of a case
([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md)); a reader that does not find them falls back to the id.

## Merged, not replaced

`testing --file a_spec.lua` must not make the results of `b_spec.lua` disappear. A run replaces the cases it
produced (by id) and keeps the others. A file that ran **completely** forgets the ids it no longer produces
and renews its file record; a run with a case restriction (`--filter`, `--lf`, a stop) only replaces what ran
and is marked `partial`. A file that no longer exists is dropped with its cases.

## Stale

`is_stale(state, file)` compares the recorded `{ mtime_ns, size }` with the file now. A changed file, a
deleted one and a file without a record are stale (`changed`, `gone`, `no result`): the result of a stale file
must never be shown as a current green. `mtime_ns` is a **decimal string**: nanoseconds since the epoch do
not fit a double, and a number that went through JSON would not equal itself. File names are compared with
forward slashes, so a Windows path from a buffer finds its record.

## The API

```lua
local state = require("testing.state")
local st = state.load(root)                   -- always a state; st.notes says what was ignored
state.snapshot(st)                            -- counters: summary, cases, files, failed, stale, partial
state.case(st, id)                            -- one case
state.case_at(st, file, line, { exact = true }) -- the case a line belongs to
state.file_summary(st, file)                  -- counts, red ids, duration, stale + reason
state.is_stale(st, file)                      -- boolean, reason
state.failures(st)                            -- the red cases by file and line
state.newly_failed(st, state.load_prev(root)) -- ids red now and not in prev.json
state.apply(st, res, info)                    -- merge a finished run (in memory)
local off = state.subscribe(st, function(s, event) end)  -- called on apply; a broken subscriber hurts nobody
state.record(root, res, info)                 -- what the driver calls: read again under the lock, apply, write
```

## An untrusted file

`last.json` is read back like `runs.jsonl`: a size cap (`MAX_BYTES`) before decoding, `pcall` around the
decode, every field validated; a case that fails is dropped and counted in `notes`, a file that is not
usable (not JSON, an array, an unknown version, a directory) is ignored with a note. Titles and messages lose
their control characters and are cut (`MAX_TEXT`), so a terminal sequence in a test title does not reach a
window. Nothing from the file is used as a path. It is written atomically under the lock of
`testing.statelock`, bounded in bytes, cases and string lengths.
