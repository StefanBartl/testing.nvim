# `testing.child`

Two kinds of child editor live here:

* **A child per spec file** (M2 `testing.child` v1): one spec file runs in a **fresh child editor**,
  the way plenary ran one `nvim` per file. The pool that runs many of them and merges what they report
  is [`testing.run.isolated`](../run/isolated.lua); the child side is [`boot.lua`](boot.lua).
* **An RPC child** you drive (M2 `testing.rpc`): `nvim --embed`, msgpack-rpc over its stdio, a handle
  with `lua`, `api`, `fn`, `feed`, `input`, `mouse`, `settle`, `screen`, `notifies`, ... The driver is
  [`testing.rpc`](../rpc/init.lua), the in-child half is [`rpc_boot.lua`](rpc_boot.lua) and
  [`rpc_init.lua`](rpc_init.lua). Public surface: [docs/CHILD.md](../../../docs/CHILD.md). It shares
  the environment, the sandbox, the process start and the process-tree kill of this module.

| Module | Purpose |
|--------|---------|
| [`testing.child`](init.lua) | `build` (argv, environment, sandbox, job; pure), `environment` (sandbox + env, shared with `testing.rpc`), `prepare`, `spawn` (also the RPC mode: `on_stdout`), `kill_tree`, `cleanup`, `describe_exit` |
| [`testing.child.env`](env.lua) | The environment allowlist, the determinism variables and the sandbox variables (pure) |
| [`testing.child.fragment`](fragment.lua) | The result file a child writes (NDJSON) and the validation of it |
| [`testing.child.boot`](boot.lua) | Runs INSIDE a per-file child: reads the job, sets the editor up, runs the file, reports |
| [`testing.child.runner`](runner.lua) | Runs ONE spec file and writes its records (selector, `--lf`, timeouts, the guard layer of the job, soft isolation): shared by `boot` and the warm pool |
| [`testing.child.pool_boot`](pool_boot.lua) | Runs INSIDE a warm pool member: `run` (one file), `finish` (restore, reset, option and sandbox cleanup, structure check) |
| [`testing.child.rpc_init`](rpc_init.lua) | The `-u` file of an RPC child: runtimepath, then the project's minit |
| [`testing.child.rpc_boot`](rpc_boot.lua) | Runs INSIDE an RPC child: notify/prompt capture, guard hook, settle probe, reset, screen |

## What a child is

```
nvim -n -i NONE --headless -u NORC -c "lua ...dofile(boot)"      host c  (default)
nvim -n -i NONE --headless -u NORC -l <boot.lua>                 host l
```

`-u NORC`: no init file, but the editor's own runtime plugins (netrw, matchit, ...) load, as under
plenary's `-u minimal_init` or `--clean`.

* An argv **list** started by `vim.uv.spawn` (never a shell string), working directory = the project
  root. `lib.nvim.system.job` has no `cwd` / `env` / kill options and `vim.system` only completes when
  the pipes reach end-of-file (an orphan of the spec can hold them for ever), so this is the one place
  that talks to libuv directly. A child is finished when its **process** ended plus a 200 ms drain.
* The command line is **constant**. Everything variable is in a JSON job file named by
  `$TESTING_CHILD_JOB` (removed from the environment before the spec runs). No user text is ever
  parsed as a command.
* **Host `c`** starts like plenary's `PlenaryBustedFile` host: the spec runs from a `-c` command, so
  `v:vim_did_enter` is 0, `expand('<cword>')` / `expand('<cfile>')` work, and `filetype plugin indent
  on` is run (`filetype = false` in `.testing.lua` turns it off). **Host `l`** is `nvim -l`
  (`vim_did_enter` is 1, no buffer context). A `script` prefers `l`.
* The dependencies the CLI resolved, this checkout, lib.nvim and the `--rtp` directories are on the
  child's runtimepath, and `$<NAME>_DIR` of this checkout (`$TESTING_NVIM_DIR`), of lib.nvim and of
  every resolved dependency is in its environment (a project's `minit`, or an editor a spec starts,
  resolves them the same way the parent did), and so is the real `stdpath('data')/site` (read-only: installed Tree-sitter
  parsers). The project's `minit` runs in the child before the spec, as `-u minimal_init` did.
* **stdin is the null device.** `input()`, `inputlist()`, `inputdialog()`, `inputsecret()` and
  `confirm()` answer with "cancelled" (and the case gets a note saying so): lua_ls offers an
  `inputlist`, and in-process that ended the whole editor. A prompt asked in another way (a raw
  `:call input()`) cannot be answered; the hard timeout ends it (`timeout` for that file).

## Environment: an allowlist

A child does **not** inherit the environment. It gets:

* `PATH`, `PATHEXT`, `HOME`, `USERPROFILE`, `HOMEDRIVE`, `HOMEPATH`, `USER`, `USERNAME`, `LOGNAME`,
  `USERDOMAIN`, `COMPUTERNAME`, `APPDATA`, `LOCALAPPDATA`, `ALLUSERSPROFILE`, `PUBLIC`, `SHELL`,
  `COMSPEC`, `SystemRoot`, `SystemDrive`, `windir`, `OS`, `PROCESSOR_ARCHITECTURE`,
  `PROCESSOR_ARCHITEW6432`, `NUMBER_OF_PROCESSORS`, `ProgramFiles`, `ProgramFiles(x86)`,
  `ProgramW6432`, `ProgramData`, `CommonProgramFiles`, `CommonProgramFiles(x86)`,
  `CommonProgramW6432`, `LANG`, `LANGUAGE`, `LC_*`, `TZ`, `TERM`, `COLORTERM`, `NO_COLOR`,
  `FORCE_COLOR`, `CLICOLOR_FORCE`, `VIM`, `VIMRUNTIME`, `CI`, `GITHUB_ACTIONS`, `DISPLAY`,
  `WAYLAND_DISPLAY` (names are matched case-insensitively);
* what the project asks for: `.testing.lua` `env_allow = { "MAGICK_*", "MY_VAR" }` and
  `--env-allow <name>` (exact names or a `PREFIX*`; a bare `*` and everything starting with `NVIM` are
  refused);
* the sandbox variables below.

**Determinism.** `LANG`, `LANGUAGE`, `LC_*` and `TZ` of the parent are *not* passed on (the list above
names them for completeness: they are allowed, then replaced): the child gets `LANG=C.UTF-8`,
`LC_ALL=C.UTF-8`, `TZ=UTC` ([`env.apply_determinism`](env.lua)), so a spec that formats a date or
compares a message gives the same answer on the author's `de_AT` workstation and on CI. Opt out with
`deterministic = false` in the child spec (`testing.child.build`, `testing.rpc.spawn`); the run
options key is `determinism` (`testing.run.options`); whoever builds the child spec maps it to `deterministic`.

So `GITHUB_TOKEN`, `*_API_KEY`, cloud credentials, `$NVIM` and `$NVIM_LISTEN_ADDRESS` (which would
point a spec at the editor that runs the tests) never reach a spec. `NVIM*` can not be allowed.

A project whose specs need a tool that is configured through the environment names it:
ImageMagick on Windows needs `MAGICK_HOME` / `MAGICK_CONFIGURE_PATH` (`env_allow = { "MAGICK_*" }`).

## Sandbox: no writes into the user's state

Every child gets one directory below the parent's temp directory (`testing-child-<pid>-<n>`, removed
afterwards) with `config`, `data`, `state`, `cache`, `run` and `tmp`, and `XDG_CONFIG_HOME`,
`XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, `XDG_RUNTIME_DIR`, `TEMP`, `TMP`, `TMPDIR` point
into it. `stdpath('data'|'state'|'cache'|'config')` and `tempname()` of a spec therefore never touch
the real ones. **Not redirected:** `HOME` / `USERPROFILE` / `APPDATA` / `LOCALAPPDATA` (git needs the
user's identity); a spec that writes there writes there.

## Results: `result.ndjson`

The child reports through a file, not stdout (a spec may print anything):

```
{"k":"progress","case":{...}}   a case the moment it finished        (streamed)
{"k":"case","case":{...}}       the final cases, when the file is over
{"k":"done","files_run":1,...}  last line
```

The parent merges **in file order**, validates the cases with the IR validator (and refuses cases
that name another file), and applies the same `sanitize` as an in-process run to the merged IR (path
placeholders, redaction). A killed child leaves only `progress` records, and those are used.

## Verdicts

| What happened | Status of that file |
|---|---|
| finished, exit code 0 | its own cases |
| the pool killed it (`file_ms` + 2 s; busted: `case_ms` + 2 s without a new case) | the cases that finished + one `timeout` |
| exit code != 0, a signal, a native crash (Windows `0xC0000005`, POSIX 139), the spec quit the editor, no `done` record, an unreadable fragment | the cases that finished + one `crash` with the exit description and the tail of stderr |
| a `script` file | one case: exit code **and** printed `[FAIL]` lines (`testing.dialect.script`); a signal / native crash is `crash` |

The run goes on, the exit code is 1.

**When the child is finished.** When its *process* has exited, plus 200 ms (`DRAIN_MS`) to read what
was still in the pipes, or at once when both pipes reached end-of-file. Not when the pipes close: a
helper the spec left behind (a language server) holds the inherited pipe ends, and waiting for them
would turn a green file into a timeout or hang the run. A process that is still alive
`REAP_MS` (10 s) after the kill is abandoned (`abandon`): the file is a `timeout` case that says so.

## Killing

A timeout kills the whole **process tree** (a spec that started language servers or other editors must
not leave them behind): Windows `taskkill /PID <pid> /T /F`; POSIX the root is frozen (`SIGSTOP`),
its descendants are read from one `ps -A -o pid= -o ppid=` call, then the process group (the child is
started detached, `kill(-pid, SIGKILL)`) **and every descendant** get `SIGKILL`. The descendant walk
is needed because `jobstart` puts every job in a session of its own (measured on Linux: PGID = SID =
the helper's pid), so the group kill alone leaves a spec's `jobstart`ed helper alive. The root is killed
directly if that fails. The children are also killed when the editor quits (`VimLeavePre`; the
autocmd exists only while a child does). **Limits:** a parent that is itself killed
cannot clean up; a descendant that was reparented before the walk (its parent died on its own) is
not found by the walk (POSIX: unless it kept the group); without `ps` only the group dies; on
Windows a grandchild that broke away from its parent's job and whose parent is already dead is not
found by `/T`, and a helper left behind by a child that ended normally is not killed at all (POSIX: the
process group is killed once the child is gone). It cannot hold the run any more, but it can keep
the child's sandbox directory from being deleted.
