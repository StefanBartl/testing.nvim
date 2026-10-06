# Output formats: reporters and the Result-IR

A run produces one **Result-IR**: a JSON document (`schema_version = 1`) with `run`, `cases` and
`summary`. Reporters turn it into output and read **nothing else**: never the text a test printed.
They are pure functions that return lines; the runner prints or writes them. Everything that came
from the code under test is treated as hostile input (control characters, terminal escapes, bidi
overrides, invalid UTF-8, strings that look like workflow commands or XML).

| Reporter | Output | Command line |
| --- | --- | --- |
| `term` | Plain console lines (default) | `--reporter term` |
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
* `effects` of a case (what the code under test did to the editor and the file system) are not
  collected yet; every case says so in its notes.

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

* The `ok    name` / `FAIL  name` / `N spec(s) failed` shapes are those of the transitional lib.nvim
  runner. A file with only skipped cases prints `skip`, never `ok`; an unexpected pass (`xpass`)
  fails its file.
* Multi-line `expected` / `actual` get a line diff, with equal head and tail trimmed first and the
  work bounded, so a huge value cannot stall the report.
* Lines are truncated by display width (CJK and emoji count as two columns).
* Colour is off unless asked for. The convention: an explicit option, then `NO_COLOR`, then
  `FORCE_COLOR` / `CLICOLOR_FORCE`, then whether stdout is a terminal.

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
