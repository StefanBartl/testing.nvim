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

## Result-IR

* Statuses: `pass`, `fail`, `error`, `skip`, `xfail`, `xpass`, `timeout`, `crash`.
* A case with no assertion is a failure, not a pass.
* Encoding is deterministic (sorted keys): the same IR is the same bytes.
* Paths are normalized: the repository, home, temp and state directories become `<REPO>`,
  `<HOME>`, `<TMP>`, `<STATE>`, so the file is the same on every machine.
* With `--json` the free text is **redacted** by the kernel: user and host name, environment
  `NAME=value` pairs, e-mail addresses, and every free-text token that holds a `Users/<name>` path
  shape (a spec about an anonymizer that asserts about a Windows profile path is no leak: the token
  becomes `<USER-PATH>`, the text around it stays readable). The validator still refuses a
  structurally broken IR (exit 3), but a privacy finding it cannot remove (for example a user-home
  path in a case id) never discards the verdict: the IR keeps every case and gets a top-level
  `warnings` list (paths of the findings, never the leaked text), and the terminal prints a note.
  `--junit` and `--github` read the same sanitized IR.
* `effects` of a case (what the code under test did to the editor and the file system) are filled by the guard
  layer ([GUARDS.md](GUARDS.md)); a case says in its notes when a guard that fills them is off, and an empty list
  is then not a measurement.
* Additive fields (`schema_version` stays 1):
  * `cases[].flaky = true` with `retries = k`: the case failed and then passed on retry `k` (`--retry-failed`). Its `status` is
    `fail` (the run is red) unless `--allow-flaky` replaced it by the passing result (`status = pass`); either way it is never
    cached. A case that failed on every retry has `retries = n` and no `flaky`.
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
exactly the run that prints the sentinel. The counts are in spec files: `n from cache, m ran, k skipped on
purpose` (`k` = files that were not selected). A skipped case is never green: it makes the run `green-partial`.

```
verdict: green (380 from cache, 32 ran, 0 skipped on purpose; 412 spec file(s))
verdict: green-partial (10 from cache, 5 ran, 30 skipped on purpose; 45 spec file(s)): 30 spec file(s) not selected (--changed); no sentinel
verdict: red (0 from cache, 3 ran, 0 skipped on purpose; 3 spec file(s))
last green run: 2026-10-07 12:00:03Z at 3f2a1b9; 2 file(s) changed since: lua/a.lua, TESTS/a_spec.lua
```

`run.verdict = { kind, exit_code, files = { total, selected, cached, ran, skipped, unrun }, cases = { total,
skipped }, reasons?, last_green?, changed_since? }`. For a `red` run the driver adds `last_green = { ts, sha? }`
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
  each; in `--format jsonl` an object of the kind `flaky`, `unasserted` or `no_case` after the verdict).
* **A report file that cannot be written** (`--json`, `--junit`): the first line is printed only after the files are
  written. When one cannot be, the exit code is `3` and the line says so (`INFRA | cannot write ... | exit 3`, in
  jsonl an object of the kind `infra`), never a verdict with another exit code.
* **One entry per cause**: failures with the same status, message (first line) and top frame (the assertion site, or
  the first frame of the traceback) are one entry with a counter (`ERROR x40`), the first case, and the hint that the
  rest is in the `--json` file. Several failed assertions of one case: the first, plus a count.
* **`expected` / `actual`**, one line each; multi-line values are cut to the first differing line with one line of
  context before it.
* **`rerun:`** the entry script as it was called, the arguments of the run without what selects or shows (`--file`,
  `--filter`, `--tags`, `--lf`, `--cached`, `--changed`, `--shard`, the reporter and report options, `-x`, `--shuffle`,
  `--order`, the path positionals), then `--file <file>` and `--filter '<case>'`. Every word is quoted for bash and PowerShell alike: bare when it only
  holds `[A-Za-z0-9_./:=+-]`, else in single quotes (nothing inside them is interpreted: `$(...)`, backticks, `$var`
  and `%` stay literal, spaces are kept as they are). A word with a single quote or a control character has no safe
  spelling: a `--filter` is left out, and for a file or argument the line says that there is no command.
* **`--agent-budget <n>`** (default 4000, at least 200) bounds the characters of everything after the verdict lines.
  An entry that does not fit in full is tried in short form (head line and `rerun:`); what still does not fit is
  counted in the last `more:` line, never dropped silently.
* **Stable**: the order is the order of the IR (file order, the same for any `--jobs`); the same IR gives the same lines.
* **`--format jsonl`**: the same data, one JSON object per line: `{"kind":"verdict",...}`, one `{"kind":"failure",...}`
  per cause (`count`, `where`, `case`, `message`, `expected`, `actual`, `rerun`), `{"kind":"guard",...}`, and
  `{"kind":"omitted",...}` when the budget cut something.
* **Hostile input**: case names, messages, values and file names go through the same cleaning as `term` (control
  characters, escape sequences, C1, bidi overrides, invalid UTF-8), are cut to one line, and a line that would start
  with `::` (a workflow command) is written with `\x3A:`.
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

The module-level reference for authors of reporters is
[`lua/testing/report/README.md`](../lua/testing/report/README.md).
