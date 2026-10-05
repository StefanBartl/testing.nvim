# `testing.run`

Runs spec files. Today only the minimal in-process driver exists.

| Module | Purpose |
|--------|---------|
| [`testing.run.inproc`](inproc.lua) | Loads dialect-A spec files in the current Neovim, one case per file, builds the Result-IR |
| [`testing.cli`](../cli.lua) | Argument parsing, exit codes; entry point of [`scripts/testing.lua`](../../../scripts/testing.lua) |

## Command line

```
nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root> [--json out.json] [options]
```

Run it from `<root>`: specs are cwd-dependent (the old runners are documented as "run from the repo
root"), and the driver deliberately does not `chdir` (on Windows libuv's `chdir` exports an `=E:`
variable into the environment, which environment-auditing specs trip over). A different cwd is noted on
stderr.

| Option | Meaning |
|--------|---------|
| `--json <file>` | write the Result-IR (`schema_version = 1`); it is decoded and validated first, an invalid IR is never written |
| `--rtp <dir>` | add a directory to the runtimepath (repeatable; the old runners found sibling plugins themselves) |
| `--only <text>` | run only spec files whose path contains `<text>` (repeatable) |
| `--sentinel <name>` | last line when everything is green; default: the one `<root>/TESTS/run.lua` prints (e.g. `LIB_TESTS_OK`), else `TESTING_OK` |
| `--no-timings` | no timing line |

Exit codes: `0` green, `1` at least one file failed, `2` usage or configuration error (also: no spec
found, lib.nvim missing), `3` infrastructure error (IR cannot be validated or written, driver crashed).

## Mapping and output

* **One case = one spec file** (dialect A has no test cases): id `TESTS/x_spec.lua::x_spec.lua`, the
  assertions are the file's `H.eq` / `H.ok` calls. A raise of the file (or a load error) is an `error`
  case with a traceback; a file without any assertion fails (kernel rule), it is never hidden.
* Order is the order of the spec list in `<root>/TESTS/run.lua` when there is one (shared state between
  files depends on it); specs not listed run last, alphabetically, and are noted.
* Output keeps the shapes of the old runner (`ok    name`, `FAIL  name` plus one indented line per
  failed assertion, `N spec(s) failed`), then a timing line, then the sentinel (only when green and the
  IR was written).
* The serialized IR carries `<REPO>`, `<HOME>`, `<TMP>`, `<STATE>` instead of paths; the driver also
  scrubs escaped paths and profile paths that specs print themselves, and the user name (`<USER>`).
