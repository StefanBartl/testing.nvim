# Exit codes

The command-line runner (`scripts/testing.lua`) and `scripts/test.sh` use four exit codes. A CI step
can tell "the suite is red" from "the machinery is broken" by the code alone.

| Code | Meaning | Examples |
| --- | --- | --- |
| `0` | Every spec file passed. | |
| `1` | At least one case failed, errored, timed out or crashed (a child editor that died: signal, native crash, exit code != 0, no result). Under `--strict` also a skipped case or a discovery finding. | A failed assertion, a spec that raises, a case over its timeout, a spec listed by the project's old runner but missing on disk. |
| `2` | Usage or configuration error, or nothing to run. | Unknown option, no `<root>`, root is not a directory, an unusable `.testing.lua`, no spec found, a selection (`--file`, `--filter`, `--tags`, `--lf`) that matches nothing. |
| `3` | Infrastructure error. The verdict cannot be trusted. | A dependency is missing (the message names all four places searched), the project's `minit` raised, the JSON IR or a report could not be written or failed validation, the editor was quit under the run, an internal error. |

Rules behind the numbers:

* **Never a green exit after an aborted run.** A spec that calls `os.exit` is refused (that file
  becomes an `error` case and the run goes on); quitting the editor (`:qa!`, `:cquit`) ends with `3`
  and the message "run did not complete".
* **`--watch` ends with the code of the last COMPLETED run**; Ctrl-C before any run completed is `3` (an aborted
  run, never `0`).
* **Never a silent ignore.** An option that is parsed but not implemented is refused with `2`, never
  accepted and dropped: a run that dropped `--filter` would be a green verdict about something else.
  (Every option of `--help` is implemented today; `init` on the command line is the exception, see
  [CLI.md](CLI.md).)
* **A partial run is not the project's verdict.** A selection (`--file`, `--filter`, `--tags`,
  `--lf`), `--maxfail` and a run that holds skipped cases print a distinct last line instead of the
  sentinel a script might read as "the whole suite is green".
* **The verdict is a reading of the code, never a fifth code.** Exit `0` is `green` (the sentinel) or
  `green-partial` (a selection, a case filter, a skip: no sentinel, the reasons are named); exit `1` is `red`.
  Every reporter prints that distinction ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#the-verdict)), so a caller that
  needs "everything was looked at" reads the verdict or the sentinel, not the exit code alone.
* **The runner never raises.** Anything unexpected is exit `3` with a message on stderr
  (`TESTING_DEBUG=1` adds the traceback).

`scripts/test.sh` adds one case of its own: `nvim` not on `PATH` is exit `3`.

## A file that dies or hangs

In a child editor (`isolated = "file"`, every `script`) one file cannot take the run down with it. A
file whose editor died (segfault, `os.exit`, a signal, no result) is one `crash` case, a file that
exceeded its hard limit (the process tree is killed) is one `timeout` case; both are red (exit `1`),
every other file still runs and reports. In the one-process mode (`--isolated none`) a native crash
ends the whole run, and the shell reports the signal (`139` for a segfault) without a report: that is
what the child mode is for.

## `testing migrate`

The migration tooling has its own codes, because its question is different:

| Code | Meaning |
| --- | --- |
| `0` | The plan was printed (dry run), or written (`apply`), or there is nothing to do. |
| `1` | `--check` only: the plan is not empty, the repository is not migrated yet. |
| `2` | Bad usage, or `apply` refused (dirty working tree, not a git repository, a file changed since the plan, a symlink target). Nothing is written when anything is refused. |
| `3` | The root cannot be analysed. |
