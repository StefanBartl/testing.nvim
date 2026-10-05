# `testing.report`

Reporters turn a Result-IR into output. They read **only the IR** (never test output text), they are
pure functions that return lines (the caller prints or writes them), and everything that came from
the code under test is treated as hostile input (control characters, terminal escapes, bidi
overrides, invalid UTF-8, strings that look like workflow commands or XML).

| Module | Purpose |
|--------|---------|
| [`testing.report`](init.lua) | Registry (`term`, `github`, `junit`) and `run_reporters(result, opts)` |
| [`testing.report.term`](term.lua) | Terminal: `ok`/`FAIL` file lines, failures with `file:line`, expected/actual, line diff, durations, seed, summary |
| [`testing.report.github`](github.lua) | GitHub Actions `::error` annotations and the `$GITHUB_STEP_SUMMARY` Markdown table |
| [`testing.report.junit`](junit.lua) | JUnit XML: one `testsuite` per spec file, one `testcase` per case |
| [`testing.report.util`](util.lua) | Shared: `clean` (strict UTF-8 plus control-character escaping), `cap`, status classes |

## Using it

```lua
local report = require("testing.report")

local outputs, errors = report.run_reporters(result, {
  reporters = {
    "term",                                              -- lines for stdout
    { name = "junit", path = "out/junit.xml" },          -- written atomically (parent dirs created)
    { name = "github", opts = { max_annotations = 10 } },
  },
  defaults = { term = { width = 100, durations = 5 } },  -- per-reporter defaults, a spec's opts win
})
for _, out in ipairs(outputs) do
  if not out.path and not out.err then print(table.concat(out.lines, "\n")) end
end
-- errors: one message per failed reporter; the caller maps a non-empty list to exit code 3
```

`run_reporters` never raises. An unknown name, a reporter that throws, a bad path or a failing write
is an `err` on that output entry (and in `errors`); the other reporters still run.

A reporter module has `render(result, opts) -> string[]` and optionally `finish(result, opts)` (a side
output; the GitHub reporter appends the step summary there when `GITHUB_STEP_SUMMARY` is set).

## Terminal

```
ok    TESTS/a_spec.lua
FAIL  TESTS/b_spec.lua
      TESTS/b_spec.lua:12  values differ
        expected:
          1
        actual:
          2

1 spec(s) failed

seed: 4242  (reproduce: --shuffle --seed 4242)
summary: 2 pass, 1 fail (3 case(s)) in 1.50 s
```

* The `ok    name` / `FAIL  name` / `N spec(s) failed` shapes are those of the transitional lib.nvim
  runner. A file with only skipped cases prints `skip`, never `ok`; `xpass` fails its file.
* Multi-line `expected`/`actual` get a line diff (`- expected`, `+ actual`, context, folded runs).
  `lib.lua.diff.myers` is an O(n*m) DP, so equal head and tail lines are trimmed first and the
  remaining `n*m` is bounded by `diff_max_cells` (default 40000, i.e. 200 x 200 changed lines, a
  table under a megabyte). Above it the values are printed plainly with a note (SEC-32).
* Lines are truncated by display width (`lib.lua.strings.width`, CJK and emoji count as 2 columns).
* Colour is off unless `color = true`. `term.use_color({ is_tty, env, color })` implements the
  convention: explicit option, then `NO_COLOR`, then `FORCE_COLOR`/`CLICOLOR_FORCE`, then TTY.

| Option | Default | Meaning |
|--------|---------|---------|
| `color` | `false` | ANSI colours |
| `width` | `100` | Columns per line |
| `durations` | `0` | List the N slowest cases |
| `diff_max_cells` | `40000` | Bound of the diff DP |
| `diff_context` | `2` | Unchanged lines around a change |
| `max_value_lines` | `20` | Lines of a value or traceback shown |
| `max_diff_lines` | `60` | Lines of one diff shown |

## GitHub

Workflow commands are parsed from stdout, so the text is escaped as the runner expects: in the
message `%`, CR, LF become `%25`, `%0D`, `%0A`; in properties (`file`, `title`) also `:` and `,`
become `%3A`, `%2C`. Other control characters are made visible first, so a test name holding
`\n::set-output ...` can never start a second command. At most `max_annotations` (default 10, the
GitHub limit per type and step) are emitted, then one warning says how many were left out. Skips are
annotated with `annotate_skips = true`.

The step summary table escapes every cell for Markdown and HTML and is **appended** (other steps
share the file), capped at `summary_max_bytes` (default 900000).

## JUnit

* `fail`, `xpass` -> `<failure>`; `error`, `timeout`, `crash` -> `<error>`; `skip`, `xfail` ->
  `<skipped>`. The counters of every `testsuite` and of `testsuites` are derived from those elements.
* Well-formedness for any input: invalid UTF-8 becomes U+FFFD, characters XML 1.0 forbids become a
  visible `\xNN`, attributes escape `& < > " '`, bodies are CDATA with `]]>` split, bodies are capped at
  `max_body_bytes` (default 16384).
* Deterministic: no timestamp, no host name, fixed attribute order, IR order of cases, times in seconds.

## Specs

`TESTS/testing/report_*_spec.lua` run every reporter against hand-built IRs (one per status class and
a hostile one), parse the XML back with an independent minimal checker, and verify determinism.
