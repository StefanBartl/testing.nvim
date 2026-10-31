# Output formats: reporters and the Result-IR

A run produces one **Result-IR**: a JSON document (`schema_version = 1`) with `run`, `cases` and
`summary`. Reporters turn it into output and read **nothing else**: never the text a test printed.
They are pure functions that return lines; the runner prints or writes them. Everything that came
from the code under test is treated as hostile input (control characters, terminal escapes, bidi
overrides, invalid UTF-8, strings that look like workflow commands or XML).

| Reporter | Output | Command line |
| --- | --- | --- |
| `term` | Plain console lines (default) | `--reporter term` |
| `agent` | Compact text for coding agents: the verdict first, then only the failures | `--reporter agent`, `TESTING_REPORTER=agent`, or an agent environment |
| `github` | `::error` annotations on stdout and the Markdown step summary | `--github` |
| `junit` | JUnit XML, one `testsuite` per spec file, one `testcase` per case | `--junit <file>` |
| JSON | The Result-IR itself, validated again after writing | `--json <file>` |

A reporter that fails (unknown name, throws, cannot write its file) does not stop the others and
is never a pass: the run ends with exit code `3`.

## Events stream

`--events <file>` writes what a run is doing while it goes, one JSON object per line (NDJSON, flushed after every
line, keys sorted), for a supervisor that shows a run live (a dashboard, a statusline). It is a convenience beside
the reporters, never part of the verdict: a file that cannot be opened is a note on stderr and the run goes on, a
write that fails switches the stream off with one note, and the exit code never depends on it.

Every line has `v` (`1`), `event`, `ts` (unix seconds) and `run` (counts the runs that wrote to this file in this
process: `--watch` makes 1, 2, ...). The first run of a process truncates the file, a later one appends.

| `event` | Fields |
| --- | --- |
| `run_start` | `project` (directory name, never a path), `files_total`, `files_selected`; the plan: `files` (the selected spec files in run order, at most 2000, `plan_truncated` when there are more), `cases_estimate` and `cases_estimated = true` (the cases the files will probably produce, counted from the `describe`/`it` positions of the source, one for a file without them: an **estimate**, shown as a guess and replaced by what the stream says) |
| `file_start` | `file`, `cases_estimate` (+ `cases_estimated`): the file begins to run. With `--jobs` several files can start before the first `case` |
| `case` | `file`, `id`, `status` (the Result-IR statuses), `duration_ms`, `cached` (`true`: not executed, from the result cache; cached cases are announced after the run's cache step) |
| `file_end` | `file`, `cases`, `failed`, `duration_ms`: after the last `case` of the file |
| `run_done` | always after a `run_start` (an empty one when the run ended before it began); `exit_code`, `verdict` (`green`, `green-partial`, `red`; absent when the run ended before one existed), `summary` (a counter per status; absent likewise), `aborted` (`true` when the editor was quit during the run) |
| `phase_done` | `testing fast` only, once, when the likely files (phase 1) are done and before the rest is finished: `phase` (`1`), `verdict` (`green`, `green-partial` or `red` **of phase 1 alone**: an interim finding, not the verdict of the run), `specs` (files in phase 1), `from_cache`, `ran`, `failed` (files with a red case). A reader takes the verdict of the run from `run_done`, never from here. Not sent when there is no phase 1. |
| `watch_change` | `--watch` only, between two runs and only when a run follows (a change that runs nothing is not announced): `files` (at most 20, project-relative), `count`; carries the number of the run it leads to |

The order: `file_start` of a file comes before its cases and `file_end` after them; the `case` lines of one file are
consecutive; the `file_start` of a later file can come before the `file_end` of an earlier one (the start is
announced when the file begins, the end with the next file's first case or at `run_done`), so a reader keeps a **set**
of open files, not a stack. A file that began and produced no case (the run stopped) is closed at `run_done`.

`--events -` writes the stream to **stdout**, one flushed line per event, for a supervisor that spawns the run and
reads the pipe. Stdout then belongs to the stream alone: the reporter's text and the `--watch` status lines go to
stderr. The editor being quit while a run is going (`:qa`, Ctrl-C that reaches the exit guard) ends every open
stream with `run_done` carrying `exit_code = 3` and `aborted = true`. A process killed hard cannot write anything: a
stream that ends without `run_done` was aborted, and whoever kills the process must kill its tree (child editors
are not told). A reader skips lines that are not JSON: a spec that runs in the runner's own editor and writes to
stdout itself can still reach the pipe.

It never carries assertion text, error messages, notes, program output or absolute paths. Case ids and file names
come from the code under test: control characters, bidi overrides and invalid UTF-8 are defused and every string is
capped at 500 bytes. A reader ignores fields and events it does not know; the details of a finished run are in the
[Result-IR](#result-ir) of `--json`. With `--list` nothing is written.

**Reading it in an editor.** `testing.run.events_reader` turns the bytes of `--events -` (as `vim.system` hands them
to a stdout callback, in any chunking) into validated events: a line buffer across chunk boundaries, a limit per line
(`MAX_LINE`, 64 KiB: a longer line is dropped as a whole and reported once), `pcall(json.decode)` and a type check per
kind (a line that fails is a *problem*, never an event or an error), control characters and bidi overrides replaced in
every word of the project under test, unknown kinds ignored and unknown versions refused. `finish(exit_code)` says how
the stream ended: a stream without `run_done` (the driver was killed or crashed) ends with a `run_done` of the
reader's own (`aborted = true`, `synthetic = true`, the exit code of the process), so a UI never waits for an end that
will not come, and the cases announced before the kill stay what they were.

```lua
local reader = require("testing.run.events_reader").new({
  on_event = function(ev) end,       -- run_start, file_start, case, file_end, run_done, watch_change
  on_problem = function(msg) end,    -- optional; at most 20 are reported, `reader.problems` counts all
})
vim.system(cmd, { stdout = function(_, data) if data then reader:feed(data) end end },
  function(obj) reader:finish(obj.code) end)
```

## Result-IR

* Statuses: `pass`, `fail`, `error`, `skip`, `xfail`, `xpass`, `timeout`, `crash`.
* A case with no assertion is a failure, not a pass.
* Encoding is deterministic (sorted keys): the same IR is the same bytes.
* Paths are normalized: the repository, home, temp and state directories become `<REPO>`,
  `<HOME>`, `<TMP>`, `<STATE>`, so the file is the same on every machine.
* With `--json` the free text is **redacted** by the kernel: user and host name, environment
  `NAME=value` pairs, e-mail addresses (also several that follow each other without a separator,
  `a@b.com1c@d.org`, each one goes whole), and every `Users/<name>` segment of a path in free text
  (a spec about an anonymizer that asserts about a Windows profile path is no leak: the segment
  becomes `<USER-PATH>`, the rest of the path and the text around it stay readable). Which `users` is
  a profile folder is decided on the side of privacy, but a project must stay readable:
  * `Users` with a capital U is one wherever it stands (after a drive letter, in `/mnt/c/Users/x`, in a
    URL, in a path a spec asserts about).
  * `users` in any other spelling (`users`, `USERS`) is one only as the **first folder below a root** of
    a file system that does not tell the spellings apart: `c:\users\x`, `/mnt/c/users/x`,
    `/cygdrive/c/users/x` and the share of a UNC path, `\\host\users\x` or `//host/users/x`. A share
    written with a backslash is a UNC path wherever it stands. One written with forward slashes is one only
    where a path can begin: at the start of the text, behind a blank, a quote or a bracket (`"`, `'`, `(`,
    `[`, `{`) or behind one of `=`, `,`, `;`, `<`, `>`, `|`. Behind anything else (a `:`, a letter, a
    digit, a `/`) it is the tail of a URL or of a path and stays: `https://host/users/x`, `x//host/users/x`.
  * Everywhere else it is a directory of the project or a route and stays as it is: `GET /users/42`,
    `https://host/users/42`, `lua/app/users/model.lua:12`, `D:\data\users\x`. A `users` folder deeper in a
    drive (`D:\data\users\maria`) is not read as a profile folder, because `lua/myapp/users/` of a project on
    a Windows drive looks the same.
  The validator (`abs_path_leak`) looks for the same shapes, so it neither lets one through nor refuses a
  project directory (`TESTS/testing/core_result_redact_spec.lua`). The validator still refuses a structurally broken IR (exit 3), but a privacy finding it cannot
  remove (for example a user-home path in a case id) never discards the verdict: the IR keeps every case and gets a top-level
  `warnings` list (paths of the findings, never the leaked text), and the terminal prints a note.
  `--junit` and `--github` read the same sanitized IR.
* `effects` of a case (what the code under test did to the editor and the file system) are filled by the guard
  layer ([GUARDS.md](GUARDS.md)); a case says in its notes when a guard that fills them is off, and an empty list
  is then not a measurement.
* Additive fields (`schema_version` stays 1):
  * `cases[].describe` (a list of strings, the describe titles outermost first) and `cases[].name` (the case name): the
    words of the id, so a tree can be built without cutting the id apart. Absent where a dialect has no describe
    level; a reader falls back to the id ([STATE.md](STATE.md)).
  * `cases[].flaky = true` with `retries = k`: the case failed and then passed on retry `k` (`--retry-failed`). Its `status` is
    `fail` (the run is red) unless `--allow-flaky` replaced it by the passing result (`status = pass`); either way it is never
    cached. A case that failed on every retry has `retries = n` and no `flaky`.
  * `cases[].na` (a string, the printed `n/a  <reason>` line): the case (`status = skip`) or its rest (`status = pass`)
    does not apply here. Counted in `run.verdict.cases.na`, never a reason for `green-partial`, red under `--strict`.
  * `cases[].cached = true`: the case was **not executed** in this run, its result comes from the result cache
    ([CACHE.md](CACHE.md)); `status` is `pass`, a note says `cached from <run id>`, and no guard or ledger saw it.
    `run.cache = { mode, files_cached, cases_cached, files_ran, stored }` summarizes it. With `--cache-audit` (a
    share of the hits ran anyway) it also carries `audit_rate`, `audited`, `stale_pass`, `stale_pass_rate` (the
    measured stale-pass rate: differences over audited hits), `audit_skipped` (picked, but nothing to compare) and
    `findings` (`{ code = "cache.stale_pass", file, key, message, parts }`, the first 20, `findings_total` counts all); `nondeterministic` counts files that were not stored because their key gave another result
    before (only when there were some).
  * `cases[].surface = { hit = { ids... } }`: the keymaps, commands and autocmds the case exercised, with
    `surface.track = true` ([SURFACE.md](SURFACE.md)).
  * `run.profile` with `--profile` ([PERFORMANCE.md](PERFORMANCE.md)).
  * `run.time_regressions = { { file, ms, median, runs }, ... }`, only when a file took more than three times its
    median of earlier runs ([CLI.md](CLI.md), "Slow files"); the agent report prints it as a `slower` notice.
  * `run.verdict`, the verdict of the run, see [The verdict](#the-verdict).

## The verdict

Every reporter says the same thing about the run, from `run.verdict` of the IR (the run driver fills it,
a reporter handed an IR without it derives a smaller one from the cases):

| Kind | Means | Exit code | Sentinel |
| --- | --- | --- | --- |
| `green` | Every spec file ran green in this run or has a valid cache hit; nothing was selected away or skipped. | `0` | printed |
| `green-partial` | Exit `0`, but not everything was looked at: a selection (`--file`, a path, `--shard`, `--changed`, `--since`, `--affected`), a case filter (`--filter`, `--tags`, `--lf`), a skipped case, files a stop left unrun. The reasons are named. | `0` | never |
| `red` | A case failed, errored, timed out or crashed. | `1` | never |

The kind never changes an exit code (`0` green and partial, `1` red, `2` and `3` as before), and `green` is
exactly the run that prints the sentinel. One run exits `1` without a failed case: `testing stamp` for a run that was
not given its stamp. The stdout reporters (`term`, `agent`) show it as `red` with the reason `stamp not written` (and
`no case failed`), so the kind they print is the exit code the process has; the report files keep the verdict of the cases. The counts are in spec files: `n from cache, m ran, k skipped on
purpose` (`k` = files that were not selected). A skipped case is never green: it makes the run `green-partial`. A case
that does not apply here (the n/a convention: a printed `n/a  <reason>` line, `case.na` in the IR) is the exception: it
is counted as `, j case(s) n/a here` and listed with its reason, but the run stays `green` (red under `--strict`).

```
verdict: green (380 from cache, 32 ran, 0 skipped on purpose; 412 spec file(s))
verdict: green-partial (10 from cache, 5 ran, 30 skipped on purpose; 45 spec file(s)): 30 spec file(s) not selected (--changed); no sentinel
verdict: red (0 from cache, 3 ran, 0 skipped on purpose; 3 spec file(s))
last green run: 2026-10-07 12:00:03Z at 3f2a1b9; 2 file(s) changed since: lua/a.lua, TESTS/a_spec.lua
```

`run.verdict = { kind, exit_code, files = { total, selected, cached, ran, skipped, unrun }, cases = { total,
skipped, na? }, reasons?, last_green?, changed_since? }` (`cases.skipped` leaves out the n/a cases, `cases.na` counts
them and is absent at 0). For a `red` run the driver adds `last_green = { ts, sha? }`
(the last run that was `green`, remembered in `last_green.json` beside the history) and `changed_since = { count,
files }` (git: what differs from that commit, working tree and untracked files included, minus files that were
already modified at the green run and have the same content now; at most 12 names, the count is complete). Both are
hints for finding the cause, never part of the verdict, and absent when there is no git or no green run.

How the reporters show it: `term` prints the `verdict:` line after the summary (and the `last green run:` line for a
red run); `github` puts it in the step summary (heading `passed (partial, ...)` for `green-partial`) and adds a
`::notice` for a partial run; `junit` adds a `verdict` property to every `testsuite`; `--json` carries `run.verdict`;
`agent` makes it the first line.

## `term`

```
ok    TESTS/a_spec.lua
FAIL  TESTS/b_spec.lua
      TESTS/b_spec.lua:12  values differ
        expected:
          1
        actual:
          2

1 spec(s) failed
```

* A file that came from the result cache prints `ok    name (cached)` and the summary says how many cases
  were not run (`2 pass (2 case(s), 1 cached, not run)`).
* The `ok    name` / `FAIL  name` / `N spec(s) failed` shapes are those of the transitional lib.nvim
  runner. A file with only skipped cases prints `skip`, never `ok`; an unexpected pass (`xpass`)
  fails its file.
* Multi-line `expected` / `actual` get a line diff, with equal head and tail trimmed first and the
  work bounded, so a huge value cannot stall the report.
* Lines are truncated by display width (CJK and emoji count as two columns).
* **Hostile input**: text from the code under test (messages, errors, tracebacks, expected/actual values, diff
  lines, skip reasons, process command lines) is cleaned like in every reporter (control characters, escape
  sequences, C1, bidi overrides, invalid UTF-8). Every line that would start with `::` (a workflow command, which
  the runner of GitHub Actions also reads behind indentation, ASCII or Unicode) is written with `\x3A:`, so a
  failure message cannot forge an annotation or switch the real ones off with `::stop-commands::`. A line that
  begins that way is two columns wider than the width. The legacy form `##[error]...` is read by the runner at
  any position of a line, so every `##[` is written `#\x23[` (three columns wider each).
* Colour is off unless asked for. The convention: an explicit option, then `NO_COLOR`, then
  `FORCE_COLOR` / `CLICOLOR_FORCE`, then whether stdout is a terminal.

## `agent`

A compact form for coding agents, where every line costs tokens. `--reporter agent`, `TESTING_REPORTER=agent`,
or no reporter at all inside a recognised agent environment (see [CLI.md](CLI.md#environment)):

```
RED | 3 fail, 1 error, 412 pass, 2 skip | 380 from cache, 32 ran, 0 skipped on purpose | 4.1 s | exit 1
last green run: 2026-10-07 12:00:03Z at 3f2a1b9; 2 file(s) changed since: lua/a.lua, TESTS/a_spec.lua
FAIL TESTS/cfg_spec.lua:42  cfg::parses nested keys
  values differ
  differs at line 3 of 7/7:
     b = 2,
  - c = 3,
  + c = 9,
  rerun: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua . --file TESTS/cfg_spec.lua --filter 'cfg::parses nested keys'
ERROR x40 module 'lib.nvim.foo' not found  (first: lua/x/init.lua:3  case; 39 more: --json <file>)
  rerun: ...
GUARD x2 TESTS/b_spec.lua  [state warn] leaves autocmd BufEnter in group G
more: 12 failure group(s) (30 case(s)) not shown (budget 4000 chars); all of them: --json <file> or --agent-budget <n>
```

* **The first line is the verdict** (`GREEN`, `PARTIAL`, `RED`) with the full sums, the files from the cache / run /
  skipped on purpose, the duration and the exit code. It is computed from the whole run before anything is cut: a
  shortened report can never read as green. A `PARTIAL` run names its reasons on the second line, a `RED` run adds
  the `last green run:` line ([the verdict](#the-verdict)).
* **Only failures.** A green file, a passing case and what a green spec printed do not appear; neither do the `ok`
  lines, the timing line, the `partial run` line or the sentinel (the first line says the same). Paths are relative to
  the project root. What a green run still has to say is on stdout as well, one line each: `flaky: n case(s) failed and
  then passed on a retry: ...` (`--retry-failed`), `warning: n case(s) passed without asserting anything
  (assertions = "warn"): ...` and `warning: n file(s) registered no case on this platform ...` (at most five names
  each; in `--format jsonl` an object of the kind `flaky`, `unasserted` or `no_case` after the verdict), and
  `warning: n file(s) slower than usual (over 3x their median): ...` for a file that took more than three times its
  median (kind `slower`; a warning, never a failure).
* **A report file that cannot be written** (`--json`, `--junit`): the first line is printed only after the files are
  written. When one cannot be, the exit code is `3` and the line says so (`INFRA | cannot write ... | exit 3`, in
  jsonl an object of the kind `infra`), never a verdict with another exit code. The line is ONE line whatever the
  reason holds (an IR that failed validation names the offending ids on several lines: the first line and ` ...`
  are on stdout, all of it is on stderr).
* **A stamp that was asked for and not written** (`testing stamp`, [CLI.md](CLI.md#stamp-and-verify)): the process
  exits `1` although no case failed (an `--out` that cannot be written, a run that is not complete). The first line
  then says `RED ... exit 1` and the second line `no case failed; stamp not written ...` (in jsonl the verdict
  object has `"verdict":"red"`, `"exit_code":1` and the reason in `reasons`; the terminal reporter prints
  `verdict: red`), never `GREEN` or `exit 0`. The reason itself is on stderr (`testing: stamp: not written: ...`).
  The report files (`--json`, `--junit`, `--github`) are written before the stamp step and describe the cases:
  they keep the verdict of the cases.
* **One entry per cause**: failures with the same status, message (first line) and top frame (the assertion site, or
  the first frame of the traceback) are one entry with a counter (`ERROR x40`), the first case, and the hint that the
  rest is in the `--json` file. Several failed assertions of one case: the first, plus a count.
* **`expected` / `actual`**, one line each; multi-line values are cut to the first differing line with one line of
  context before it.
* **`rerun:`** the entry script as it was called, the arguments of the run without what selects or shows (`--file`,
  `--filter`, `--tags`, `--lf`, `--cached`, `--changed`, `--shard`, the reporter and report options, `-x`, `--shuffle`,
  `--order`, the path positionals), then `--file <file>` and `--filter '<case>'`. Every word is quoted for bash and
  PowerShell (7 and Windows PowerShell 5.1) alike: bare when it only
  holds `[A-Za-z0-9_./:=+-]`, else in single quotes (nothing inside them is interpreted: `$(...)`, backticks, `$var`
  and `%` stay literal, spaces are kept as they are). A word with a single quote, a double quote, a control
  character, an empty word or a backslash at the end of a word that holds a space has no safe spelling (Windows
  PowerShell 5.1 loses the quote, drops the empty argument and lets the trailing backslash swallow the rest of the
  line): a `--filter` is left out, and for a file or argument the line says that there is no command. A value that
  starts with `--` is written `--filter='--help prints usage'` (the argument parser would take it for the next option
  in the `--filter <value>` form). A case name longer than 200 bytes is cut to that many: the filter is a plain
  substring of the case id, so the prefix still selects the case, and the line stays short.
* **`--agent-budget <n>`** (default 4000, at least 200) bounds the characters of everything after the verdict lines.
  An entry that does not fit in full is tried in short form (head line and `rerun:`); what still does not fit is
  counted in the last `more:` line, never dropped silently.
* **Stable**: the order is the order of the IR (file order, the same for any `--jobs`); the same IR gives the same lines.
* **`--format jsonl`**: the same data, one JSON object per line: `{"kind":"verdict",...}`, one `{"kind":"failure",...}`
  per cause (`count`, `where`, `case`, `message`, `expected`, `actual`, `rerun`), `{"kind":"guard",...}`, and
  `{"kind":"omitted",...}` when the budget cut something.
* **Hostile input**: case names, messages, values and file names go through the same cleaning as `term` (control
  characters, escape sequences, C1, bidi overrides, invalid UTF-8), are cut to one line, and a line that would start
  with `::` (a workflow command) is written with `\x3A:`. That holds after any whitespace, ASCII or Unicode (a
  no-break space, an ideographic space, U+2028: the runner of GitHub Actions trims all of it before it looks for
  `::`), and for every line the run writes to stderr, a line after a line break inside a message included. The
  legacy form `##[command]` is found by the runner anywhere in a line, so every `##[` is written `#\x23[` (in the
  `jsonl` form `##[`, a JSON escape: the line stays valid JSON and decodes to the original text). The same holds
  for the diagnostics of the run itself (`--list`, the notes about cases without an assertion, the `timings:` line,
  the findings, the retry notes) and for the IR that `--reporter json` prints on stdout. A `rerun:` command cannot
  spell a word that holds `##[`: the `--filter` ends in front of it (a prefix still selects the case), and a file
  name that holds it gets a note instead of a command.
* **No sentinel.** `GREEN` is printed exactly where the sentinel would be. A script that greps for the sentinel
  uses `--reporter term` (or `TESTING_AGENT=0`).

Measured on 2026-10-07 (stdout bytes of the reporter; roughly 4 bytes per token for this kind of text, no
tokenizer was run): on lib.nvim's own suite run without its `runtime-analysis.nvim` dependency (87 files, one
`error`, 80 guard warnings of passing specs) `term` printed 9 818 bytes and `agent` 3 892 (-60 %); on a copy of this
repository with three modules broken on purpose (18 files ran, 1 `fail` and 13 `error` of ten different causes)
`term` printed 23 309 bytes and `agent` 3 932 (-83 %). Both fit the default budget of 4000 characters, which is why
that is the default: it holds the verdict and about a dozen failure causes in full, and a guard-heavy run gives up
guard lines first (they come last). What the reporter cannot shorten is what a spec prints itself in the editor
process (`--isolated none`): that reaches the terminal as it is, in every reporter.

Choosing it: `--reporter`, then `TESTING_REPORTER`, then `TESTING_AGENT` (`1` on, `0` off), then an agent
environment (`AI_AGENT` set, or `CLAUDECODE=1`; both were observed in a Claude Code session, the list is
`testing.report.agent.AGENT_ENV`), else `term`. Only `scripts/testing.lua` reads the environment, so the library
and its specs are never switched by where they run.

## `github`

Workflow commands are parsed from stdout, so the text is escaped as the runner expects, and other
control characters are made visible first: a test name holding `\n::set-output ...` can never start a
second command. At most 10 annotations are emitted (the GitHub limit per type and step), then one
warning says how many were left out. The step summary table is **appended** to
`$GITHUB_STEP_SUMMARY` (other steps share the file) and capped in size.

## `junit`

* `fail` and `xpass` become `<failure>`; `error`, `timeout` and `crash` become `<error>`; `skip` and
  `xfail` become `<skipped>`. All counters are derived from those elements.
* Well-formed XML for any input: invalid UTF-8 becomes U+FFFD, characters XML 1.0 forbids become a
  visible `\xNN`, attributes are escaped, bodies are CDATA with `]]>` split and size-capped.
* Deterministic: no timestamp, no host name, fixed attribute order, times in seconds.
* On stdout (`--reporter junit`) the document is a CI log: no line may hold a workflow command. The legacy `##[` is
  written `#&#35;[` in an attribute and `#]]><![CDATA[#[` inside a body, and a body line that starts with `::` gets the
  two colons apart (`:]]><![CDATA[:`); an XML parser reads the original text back. A file (`--junit <file>`) is no
  log and keeps the text as it is.

The module-level reference for authors of reporters is
[`lua/testing/report/README.md`](../lua/testing/report/README.md).

## The contract `testing-export/1`

The documents an app, a web page or a panel reads: the fleet, one repository, the manifest of an export folder. They
are the only interface for such a client: it reads no `last.json`, no `runs.jsonl` and no IR. testing.nvim writes them,
never the app. The JSON Schema is
[`schemas/testing-export/1/testing-export.schema.json`](../schemas/testing-export/1/testing-export.schema.json)
(draft 2020-12); the golden files of a synthetic fleet are in
[`TESTS/golden/testing-export-1/`](../TESTS/golden/testing-export-1/) (an export folder byte for byte; regenerate them on
purpose with `nvim -n -i NONE --headless -u NONE -l TESTS/golden/regenerate_export.lua` and commit them with the code
change, a changed golden file is a changed contract).

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua call fleet --repos-root=E:/repos [--export] [--remote]
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua call repo <dir> [--export] [--remote]
```

`testing call` prints one line of canonical JSON on stdout ([CLI.md](CLI.md#subcommands)). The Lua API is
`testing.export`: `fleet(opts)`, `repo(dir, opts)`, `export(opts)` (the files of an export folder and the manifest,
written by nothing yet: `testing export --out` will write them, the manifest last; `opts.previous(path)` gives the
folder's current file texts so that an unchanged document keeps its bytes), `encode`, `read`, `validate`, `leaks`,
`repo_key`.

### Head

Every document starts with the same fields:

| Field | Meaning |
| --- | --- |
| `schema` | `"testing-export/1"`. |
| `plugin` | `"testing.nvim"`. |
| `kind` | `fleet`, `repo` or `manifest`. |
| `form` | `local` (for a process on this machine: carries `root`) or `export` (a folder, a web page, a panel: no absolute path anywhere). A manifest is always `export`. |
| `generated_at` | UTC, `YYYY-MM-DDTHH:MM:SSZ`. For `ci_remote` this is also the time of the GitHub answer. In an export folder written again (`export` with `previous`), a document whose digest did not change keeps the `generated_at` and `engine` of its file: the time its content was first written. |
| `engine` | `{ version, git, nvim }` of testing.nvim. |
| `rev` | What the sources looked like (`last.json`, `last_green.json`, `ci.json` with the paths of this machine replaced by their placeholders, the CI run). |
| `digest` | `sha256:<16 hex>` of the content **without** `generated_at` and `engine`: two documents of an unchanged state have the same digest, whenever and wherever they were made. The manifest's `rev` and `digest` follow the path and digest of each of its files, not their bytes (which hold `generated_at`). |
| `capabilities` | What this engine writes (`fleet`, `manifest`, `repo`); a client shows only what is listed. |
| `root` | Only in the local form: the repos root (fleet, when exactly one `--repos-root` was named) or the repository (repo). |

The bytes are canonical (`lib.nvim.json.canonical`): keys sorted by byte value, no whitespace (stdout, the form that is
hashed), or indented by two spaces with a final line feed (the files of an export folder). A document is at most
8 MiB; a bigger one is an error, never a cut document.

### `fleet`

`repos[]`, one row per repository, sorted by directory name; `excluded` (how many were left out: vaults and
`--exclude`; their names are not in the document); `remote = { asked, error }` (whether the CI adapter was asked and
why it failed, redacted). The repositories are found as `testing ci overview` finds them: below each `--repos-root`
every directory with workflows, a `ci` section or a `.testing.lua`, no vault (a name containing "vault"), `lib.nvim`
taken in, `--include`/`--exclude` on top; or the directories named.

A row:

| Field | Meaning |
| --- | --- |
| `key` | `<basename>-<12 hex of sha256(basename, a line feed, root commit)>`: the same in every clone of the repository, below any folder, on any machine (no path goes into it); without git the root commit is empty. Not the name of the state directory (that one hashes the absolute path). |
| `name` | The directory name. |
| `root` | Only in the local form: the absolute directory. |
| `head` | `{ sha, branch, dirty }` of the checkout now (git); `null` when it is no checkout. |
| `local` | The last local result (`last.json`, merged over partial runs): `run_id`, `ts`, `verdict` (`red` when a case is red; `green-partial` when the last run was partial or a case was skipped; else `green`), `summary` (all eight statuses), `cases`, `files`, `partial`, `stale` (spec files changed, gone or without a result since), `commit` (the commit of the last green record when it is this run, else `null`). `null`: no result recorded. |
| `last_green` | `{ run_id, ts, sha }` of the last completely green run (`last_green.json`), or `null`. |
| `ci_local` | The last local pipeline run (`ci.json`): `verdict`, `profile`, `partial`, `commit`, `tree`, `dirty`, `first_red`, `time`; or `null`. |
| `ci_remote` | The CI adapter's record (`testing ci remote`, only with `--remote`): `state` (its states), `repo` (`owner/name`), `sha`, `branch`, `workflow`, `os.{ubuntu,windows,macos}` (`{ state, url, job }`, `null` without a job for that system), `run` (`id`, `url`, `status`, `conclusion`, `created_at`, `updated_at`, `event`, `attempt`), `note`. `null`: not asked (no `--remote`). Asked, but the adapter gave no record for the repository (it failed, see `remote.error`): `state = "unknown"`, `os` all `null`, `run: null`, a `note` that says so. Links only to `https://github.com/`; the token is in no document. |
| `counts` | `{ fail, flaky }` of the last result (`flaky`: cases marked flaky in it), `null` without a result. |

### `repo`

The row of one repository as `repo`, and its red cases (`fail`, `error`, `timeout`, `crash`, `xpass`) by file and line
as `cases[]`: `id`, `file`, `line`, `status`, `name`, `describe`, `duration_ms`, `flaky`, `message`, `expected`,
`actual` (line breaks kept), `fails[{ line, msg }]`, `fails_total`. At most 500 cases; `cases_red` counts all,
`cases_omitted` those left out. `notes` says why a source of the state could not be used.

### `manifest`

The table of contents of an export folder, `testing-export.json`:
`files[{ path, sha256, bytes }]`, sorted by path. A reader reads the manifest first and checks every file against its
sum, so it never sees half an export. The folder:

```
<dir>/
  testing-export.json        kind manifest
  fleet.json                 kind fleet (export form)
  repos/<key>.json           kind repo, one per repository of the fleet
```

### Redaction and paths

`last.json` keeps messages as the code under test wrote them, with absolute paths. Every free text of a document
(messages, expected, actual, notes, names, the CI adapter's notes) is redacted as the IR redacts a message
(`testing.run.inproc.redact_text`: the repository is `<REPO>`, the home directory `<HOME>`, the temporary directory
`<TMP>`, the state directory `<STATE>`, user and host name, `NAME=value` pairs of the environment), the bare value of
every environment variable whose name says it is a secret (`TOKEN`, `SECRET`, `PASSWORD`, `AUTH`, `API_KEY`, ...; at
least 8 bytes) becomes `<ENV>`, then every absolute path left becomes `<PATH>` (a drive path, a UNC path with either
slash, a POSIX path, also right after a `>` that closes no placeholder, a `file:` URI); a failure text is cut to 4 KiB, a note to 300 bytes. That holds in both forms. The absolute `root`
exists only in the local form. Before an export-form document is handed out, a detector looks at every string and key
for the same shapes (a drive path, a UNC path with either slash, an absolute POSIX path, a `file:` URI), the home
directory and the roots of the repositories (as whole paths: `/root` is not in `rootless_spec.lua`), a secret of the
environment and the user name (not in the name, the key and the file of a repository, names the user chose); a finding refuses the document (`testing call` exits `3`), it is never written with the leak.

### Rules for a reader

- Refuse a higher `schema` (`testing-export/2` is a break); read a lower one.
- Ignore unknown fields: additions come within version 1 and are announced in `capabilities`.
- A missing or `null` value is unknown, never 0 (`local: null` is "no result", not "0 cases").
- Refuse a document bigger than 8 MiB and an unknown `kind`.

`testing.export.read(text)` implements these rules; `testing.export.validate(doc)` checks a document against the
JSON Schema (the schema describes exactly what this version writes, so a field nobody listed fails there, not in a
reader). The suite validates every golden file and every form against it with a Lua validator of the keywords the
schema uses (`testing.export.schema`); an unknown keyword is an error of the schema, not a pass.
