# Exit codes

The command-line runner (`scripts/testing.lua`) and `scripts/test.sh` use four exit codes. A CI step
can tell "the suite is red" from "the machinery is broken" by the code alone.

| Code | Meaning | Examples |
| --- | --- | --- |
| `0` | Every spec file passed. | |
| `1` | At least one case failed, errored, timed out or crashed (a child editor that died: signal, native crash, exit code != 0, no result). Under `--strict` also a skipped case, a case that does not apply here (n/a convention) or a discovery finding. | A failed assertion, a spec that raises, a case over its timeout, a spec listed by the project's old runner but missing on disk. |
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
  `green-partial` (a selection, a case filter, a skip, a `--maxfail` stop, a `--time-budget` that ran out, files
  left out by `--skip-uncacheable`, a case `--allow-flaky` accepted: no sentinel, the reasons are named); exit `1`
  is `red`. The interim finding of `testing fast` is neither: it never sets an exit code and never carries the
  sentinel.
  Every reporter prints that distinction ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#the-verdict)), so a caller that
  needs "everything was looked at" reads the verdict or the sentinel, not the exit code alone.
* **The runner never raises.** Anything unexpected is exit `3` with a message on stderr
  (`TESTING_DEBUG=1` adds the traceback).

`testing stamp` and `testing verify` use the same four codes with their own reading. `verify`: `0` only for `verified`
(every file proven; the sentinel follows), `1` for every other answer (`partial`, `changed`, `rejected`, `expired`, `dirty`,
`untrusted`, `invalid`, `no-stamp`: a partial proof is never `0`), `2` a usage error (a bad flag or duration, a secret
shorter than 16 characters), `3` an internal failure. `stamp` is a run: it exits as the run does, except that a run that
did not earn a stamp (not `green`: a skip, an accepted flaky case, a stop) exits `1` instead of `0`, because the caller
asked for a stamp and did not get one (so is a run whose stamp could not be written); the first line of the agent report
and the `verdict:` line of the terminal report agree with that exit code (`RED ... exit 1`, `verdict: red`), never
`GREEN`/`exit 0` for a run that exits `1`. A selection option is `2` before anything runs
([CLI.md](CLI.md#stamp-and-verify)).

`scripts/test.sh` adds one case of its own: `nvim` not on `PATH` is exit `3`.

`testing ci` ([CI.md](CI.md)) uses the four codes over its steps, the worst one decides: `0` every step green (or
skipped for this system), `1` a red step (a timeout too), `2` a usage or pipeline error (every problem of the `ci`
section is one), `3` a tool or dependency that is missing (checked before the first step: nothing runs) or a step
that could not start, or a report (`ci.json`, `--json`, `--junit`) that could not be written. A suite step is green only
when its Result-IR says so (exit `0` without a result is `3`). The sentinel `TESTING_CI_OK` follows only a complete green
run, never a `--step` selection.

`testing ci remote` ([CI.md](CI.md#the-github-actions-status-testing-ci-remote)) reads GitHub, it runs nothing: `0` every
repository was fetched and none is red (`no_run`, `no_github`, `skipped`, `queued`, `running` and `waiting_runner` are not
red), `1` a repository is `failure`, `rejected` or `cancelled` (red wins over everything else), `2` a usage error (an
unknown flag, a root that is not a directory, no repository found below `--repos-root`), `3` a repository could not be
fetched (`unknown`: no token, no network, an API error, git could not read it) and none is red, or lib.nvim has no
`net.github` (older than ccd30b5; nothing is asked). An `unknown` is never reported as green.

`testing ci overview` ([CI.md](CI.md#fleet-overview-testing-ci-overview)) reads only and writes one HTML page: `0` the
page was written (with `--json` alone: the document printed), also when repositories are red (a report, not a gate:
`testing ci remote` and `testing ci verify` gate), `2` a usage error (an unknown flag, a root or `--repos-root` that is
not a directory, an `--include`/`--exclude` that is no directory name, no repository), `3` the page could not be
written.

`testing lint` ([CI.md](CI.md#testing-lint-the-linters-on-the-changed-files)) uses them over its checks, the worst one
decides: `0` every check green (or nothing to check), `1` findings, `2` usage (an unknown check, a file outside the
root, two scopes), `3` a tool that is missing (that check is skipped, the others run; a red check never hides it) or
a check that could not run.

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

`testing call fleet|repo` ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#the-contract-testing-export1)) prints a document,
it is no verdict: red repositories are still exit `0`.

| Code | Meaning |
| --- | --- |
| `0` | The document was printed (also with red repositories, and when the CI adapter failed: `remote.error` says so). |
| `2` | Bad usage: an unknown method or option, a directory that is not there, no repository found. Or refused: `repo --export` of a repository the data classes of this device do not release (`private`, `unclassified`, no `areas.json`); nothing is printed on stdout. |
| `3` | The document could not be built: it would leak a path of this machine (export form), it is larger than 8 MiB, an internal error. Nothing is printed on stdout. |

`testing export --out <dir>` ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md#the-export-folder-testing-export---out)) writes the
export folder; it is no verdict either.

| Code | Meaning |
| --- | --- |
| `0` | The folder was written: also when nothing changed (no file moved), when repositories are red, and when the data classes released none (no `areas.json` on this device: an empty fleet, the reason on stderr). |
| `2` | Bad usage, nothing written: an unknown option, no `--out`, a directory that is not there, no repository found, `NVIM_MACHINE_ROLE` neither `workstation` nor `default`; or the folder is refused (not empty and without `testing-export.json`, a `testing-export.json` that is no manifest or names a file of another shape, `repos` a link, a `fleet.json` or `repos/*.json` in the way that the manifest does not list, a `.tmp-<pid>-<hex>` that holds anything a write never creates there or is no plain directory, or that belongs to a write that is still running). |
| `3` | The documents could not be built (a leak, larger than 8 MiB) or the folder could not be written (also: the file of a repository no longer exported could not be moved aside, the leftover `.tmp-<id>` of an earlier write could not be removed). The folder is as it was: the old manifest stays valid and matches its files (only when even that fails is `.tmp-<id>` kept, and the message says so; the next write removes it). |

`testing ci --repos... --export=<dir>` ([CI.md](CI.md#several-repositories)) keeps the codes of the fleet run and adds
two: a folder the export would refuse is `2` before anything runs (the same checks as `testing export`, a file in the
way included), an export that could not be written makes the run `3` (no sentinel); a folder that changed during the
run and is refused at the end is `2` as well.
