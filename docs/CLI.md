# Command line

```sh
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|list|doctor|init] [<root>] [options]
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua migrate [dry-run|apply] [<path>] [options]
```

Run it from `<root>`, the project whose specs should run: specs that look at "this repository" read
the working directory, and the runner deliberately does not change it (it says so when the working
directory is not the root). `-n -i NONE -u NONE` keep the run independent of the developer's shada,
swap files and config.

For this repository `scripts/test.sh` is the same thing with an isolated state directory:

```sh
scripts/test.sh                    # every spec under TESTS/
scripts/test.sh --file config      # only spec files whose name contains "config"
```

## Subcommands

| Subcommand | Does |
| --- | --- |
| `run` (default) | Discover and run the specs of `<root>`. |
| `list` | List what would run, run nothing (same as `run --list`). |
| `doctor` | Print the resolved configuration and the dependency report. Evaluates `.testing.lua`. |
| `migrate` | Plan (`dry-run`, the default) or write (`apply`) the move of a plugin repository from plenary, busted or a hand-written runner to testing.nvim, specs unchanged. It has its own arguments and exit codes: [MIGRATING.md](MIGRATING.md). |
| `init` | Scaffold `.testing.lua`, `TESTS/minimal_init.lua`, `scripts/test.sh` and a CI job in a project. Today only as the editor command `:Testing init` ([BINDINGS.md](BINDINGS.md)); on the command line it is refused with exit code `2`. |

The subcommand is the first argument, when it is exactly one of those words. Any other first
argument is the project root; a directory that is itself called `list` is spelled `./list` or
`--root list`.

## Options

Long options take their value as `--name value` or `--name=value`. The space form's value must not
start with `--` (spell `--name=--x` for that). `--` ends the options. Repeatable options accumulate;
a repeated single-value option is last-wins. An unknown option is exit code `2`.

An option that is accepted by the parser but not implemented is **refused** with exit code `2`
("not implemented yet"), never ignored. The tables below state which is which.

### Selecting what runs

| Option | Meaning |
| --- | --- |
| `<root>` / `--root <dir>` | Project root. |
| `--config <file>` | Project configuration file; must lie inside the root (default `<root>/.testing.lua`). |
| `--file <text>`, `--only <text>` | Only spec files whose **file name** contains `<text>` (literal, not a pattern); repeatable. |
| `--filter <text>` | Only cases whose name contains `<text>` (literal); repeatable. |
| `--tags <a,b>`, `--exclude-tags <a,b>` | Only cases with one of these tags / drop cases with one of them (exclusion wins). A tag is a `#word` in a busted `describe` or `it` title (`it("parses #slow input")`, applying to everything below a `describe`), or a header line `-- @tags slow integration` near the top of any spec, which tags every case of the file. |
| `--lf`, `--ff` | Only what failed last time; what failed last time first. The history lives in `stdpath("state")/testing/<project>/runs.jsonl`, is bounded, and is a convenience: it is never part of the verdict. |
| `--list`, `--dry-run` | List what would run, run nothing. |

### Controlling the run

| Option | Meaning |
| --- | --- |
| `-x`, `--maxfail <n>` | Stop after the first / the `<n>`th failure. Cases that did not run are not in the report, and the run says so. |
| `--shuffle`, `--seed <n>` | Random order; the seed is printed so a failure can be reproduced. |
| `--case-timeout <ms>`, `--file-timeout <ms>` | Timeouts of one case and one spec file (defaults from `timeouts` in `.testing.lua`). A case over its limit has the status `timeout`. In this editor the guard is best effort (it interrupts Lua code and `vim.wait`, not a spec that blocks inside C). In a child editor (`--isolated file`) the limits are **hard**: the child and its whole process tree are killed (`file_ms` + 2 s grace; for busted files also `case_ms` + 2 s without a new case once the first one is in). |
| `--strict` | A skipped case and a discovery finding (legacy spec location, symlink, unknown dialect) make the run red. |
| `--rtp <dir>` | Add `<dir>` to the runtimepath; repeatable. `<root>` is always added. |
| `--isolated <none\|file>` | `file`: every spec file runs in a **child editor of its own** (like plenary: nothing leaks from one file into the next; a crash, a hang or a prompt ends that file only). Default `auto` (`.testing.lua` `isolated`): busted files `file`, the other dialects `none`; a `script` is always a child. |
| `--jobs <n>` | Child editors running at once (default 1, `.testing.lua` `jobs`). The report, the printed child output and the exit code are the same for any `n`: results are merged in file order. |
| `--host <c\|l>` | How a child starts. `c` (default): like plenary's host, the spec runs from a `-c` command (`v:vim_did_enter` is 0, `expand('<cword>')` works). `l`: `nvim -l`. A `script` prefers `l` unless this is given. |
| `--env-allow <name>` | An environment variable (or `PREFIX*`) a child may inherit, on top of the allowlist; repeatable. See [child editors](../lua/testing/child/README.md). |

#### What happens to a child

* **It finishes**: its cases are merged. **It dies** (a native crash such as a segfault in a library,
  `os.exit`, `:cquit`, a signal, an exit code other than `0`, no result): the cases it finished plus ONE
  `crash` case for the file, naming the exit (`exit code 3221225477 = NTSTATUS 0xC0000005`, `signal 11
  (SIGSEGV)`) and the tail of its stderr. The run goes on; the exit code is `1`.
* **It hangs** (a blocking C call, a language server's prompt that nobody answers: stdin is the null
  device and `input()` / `inputlist()` / `confirm()` answer "cancelled"): `file_ms` (+ 2 s) after the
  start, or for busted files `case_ms` (+ 2 s) without a new case, the child **and its process tree**
  are killed and the file ends with ONE `timeout` case. A process that is still alive 10 s after the kill
  is abandoned: the run never waits for it.
* **It leaves a helper behind** that holds its stdout/stderr (a language server): the child counts as
  finished when its own process ended (plus 200 ms to read what was still in the pipes), not when the
  helper ends. On POSIX the leftovers of its process group are killed; on Windows they are not (no job
  objects from Lua), but they cannot hold the run any more.
* What a child printed is shown **in file order**, once, with the header `output of <file>:`.

### Output

| Option | Meaning |
| --- | --- |
| `--reporter <name>` | Terminal reporter (`term`, `github`, `junit`, `json`). |
| `--json <file>` | Write the Result-IR (`schema_version = 1`) and validate it again. |
| `--junit <file>` | Write a JUnit XML report. |
| `--github` | Emit GitHub Actions annotations and the step summary. |
| `--durations <n>` | Name the `<n>` slowest cases (`0` = all). |
| `--sentinel <name>` | Last line of a fully green run (default `TESTING_OK`, or the one the project's old `TESTS/run.lua` printed). |
| `--no-timings` | Do not print the timing line. |

Reporters and the IR are described in [OUTPUT-FORMATS.md](OUTPUT-FORMATS.md).

## What a run does

1. Parse the arguments and load `<root>/.testing.lua` ([CONFIG.md](CONFIG.md)); warnings about its
   keys go to stderr.
2. Resolve the dependencies (all of them, so one run reports every missing one), then run the
   project's `minit` file (if it exists) in this editor, the way the old runners did.
3. Discover the specs below the spec roots (`TESTS/` by default), with no depth limit, in a
   deterministic order (byte-wise sorted path). A symlinked directory is reported and not entered; a
   spec in a legacy place (`docs/TESTS`, `tests`, `test`, `scripts`) is run and reported; a busted
   spec below `lua/` is reported, not run. A project without a single spec is exit code `2`.
4. Sniff the dialect of every file ([DIALECTS.md](DIALECTS.md)) and run it: the files that need
   isolation (`--isolated`, `.testing.lua` `isolated`: busted files by default, every `script`) each in
   a child editor of their own, the others in this editor, one process, like the old hand-written
   runners. The result is merged in file order, so it is the same for any `--jobs`.
5. Print the result, write the requested reports, record the run for `--lf`/`--ff`, exit
   ([EXIT-CODES.md](EXIT-CODES.md)).

The last line of a green run is the sentinel, and only a **complete** green run with no skipped case
prints it. A selection, `--maxfail` or a skip prints a distinct line instead ("partial run ...", "N
case(s) skipped ..."), so a script that greps for the sentinel cannot read a partial run as the
verdict.

If the project still has a `TESTS/run.lua` (the old runner of the fleet), its spec list sets the
order of those files and the last line it prints is the default sentinel. A spec listed there but
missing on disk is a failing case. The file is never executed. Without `run.lua` the order is the
discovery order (sorted by relative path): a project whose specs depend on the order of that list
needs it kept, or `isolated = "file"`; `testing migrate` warns when the list is not alphabetical.

Discovery compares directories by their real path, **case-folded on a case-insensitive file system**
(detected by a probe: the same directory under a swapped-case spelling is the same inode), so `TESTS/`
and `tests/` are one directory there (Windows, macOS, WSL `/mnt/*`) and a spec is never listed twice.
On a case-sensitive file system nothing is folded.

## Environment

| Variable | Effect |
| --- | --- |
| `$LIB_NVIM_DIR` | Explicit location of lib.nvim; if set but invalid the run fails (exit `3`). Every dependency has a `$<NAME>_DIR` ([CONFIG.md](CONFIG.md#dependencies)). |
| `TESTING_DEBUG=1` | Tracebacks for internal errors. |
| `NO_COLOR`, `FORCE_COLOR`, `CLICOLOR_FORCE` | Colour of the terminal reporter. |
| `GITHUB_STEP_SUMMARY` | Target of the step summary of `--github`. |
