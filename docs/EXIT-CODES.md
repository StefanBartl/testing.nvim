# Exit codes

The command-line runner (`scripts/testing.lua`) and `scripts/test.sh` use four exit codes. A CI step
can tell "the suite is red" from "the machinery is broken" by the code alone.

| Code | Meaning | Examples |
| --- | --- | --- |
| `0` | Every spec file passed. | |
| `1` | At least one case failed, errored or timed out. Under `--strict` also a skipped case or a discovery finding. | A failed assertion, a spec that raises, a case over its timeout, a spec listed by the project's old runner but missing on disk. |
| `2` | Usage or configuration error, or nothing to run. | Unknown option, no `<root>`, root is not a directory, an unusable `.testing.lua`, no spec found, a selection (`--file`, `--filter`, `--tags`, `--lf`) that matches nothing. |
| `3` | Infrastructure error. The verdict cannot be trusted. | A dependency is missing (the message names all four places searched), the project's `minit` raised, the JSON IR or a report could not be written or failed validation, the editor was quit under the run, an internal error. |

Rules behind the numbers:

* **Never a green exit after an aborted run.** A spec that calls `os.exit` is refused (that file
  becomes an `error` case and the run goes on); quitting the editor (`:qa!`, `:cquit`) ends with `3`
  and the message "run did not complete".
* **Never a silent ignore.** An option that is parsed but not implemented is refused with `2`, never
  accepted and dropped: a run that dropped `--filter` would be a green verdict about something else.
  (Every option of `--help` is implemented today; `init` on the command line is the exception, see
  [CLI.md](CLI.md).)
* **A partial run is not the project's verdict.** A selection (`--file`, `--filter`, `--tags`,
  `--lf`), `--maxfail` and a run that holds skipped cases print a distinct last line instead of the
  sentinel a script might read as "the whole suite is green".
* **The runner never raises.** Anything unexpected is exit `3` with a message on stderr
  (`TESTING_DEBUG=1` adds the traceback).

`scripts/test.sh` adds one case of its own: `nvim` not on `PATH` is exit `3`.
