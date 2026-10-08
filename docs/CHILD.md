# The RPC child (`testing.rpc`)

A spec can start an **embedded, headless, isolated Neovim** and drive it the way a user (or Playwright)
would: type keys, click, wait until it is idle, read the screen, look at what it notified. This is
the surface for tests of plugins that need a real editor (UI, mappings, timers, floats), as opposed to
the per-file child of `--isolated file`, which runs a whole spec file in a fresh editor
([lua/testing/child/README.md](../lua/testing/child/README.md)).

```lua
local rpc = require("testing.rpc")

local child, err = rpc.spawn({ minit = "TESTS/minimal_init.lua" })
assert(child, err)

child.lua("require('myplugin').setup({})")
child.feed("ihello<Esc>")                       -- typed, runs to completion
child.input("gz")                               -- typed, NOT processed yet
child.settle(1000)                              -- wait for the editor to be idle
eq(child.lua_get("vim.g.result"), "done")
eq(child.screen().lines[1]:sub(1, 5), "hello")
child.kill()
```

`spawn` returns `child, nil` or `nil, err`; a handle that is not killed is killed when the editor
quits. Every call is **synchronous** from the spec's point of view (the caller waits with `vim.wait`,
the event loop keeps running) and has a **timeout**.

## Starting

```
nvim --embed --headless --clean -n -i NONE -u <testing/child/rpc_init.lua>
```

The command line is constant; everything variable travels in a JSON job file named by
`$TESTING_CHILD_JOB` (removed from the environment before your code runs). `rpc_init.lua` puts the
runtimepath in order and then runs **your minit** (`minit`), exactly like `-u minimal_init.lua`; a
minit that raises ends the child with exit code 3 and `spawn` returns `nil, "the child did not start:
..."` with the minit's own error. There is no `--listen`: nvim still opens its default server (a named
pipe on Windows, a socket in the private `XDG_RUNTIME_DIR` elsewhere), nothing here uses it.

| Option | Default | |
|---|---|---|
| `root` | cwd | working directory of the child, base of `<REPO>` in a trace |
| `minit` | none | absolute path of the project's minimal init |
| `rtp_prepend`, `rtp` | this checkout + lib.nvim | runtimepath entries; the FIRST entry of `rtp_prepend` wins |
| `env_allow`, `extra_env`, `parent_env` | none | see Environment |
| `deterministic` | `true` | `LANG`/`LC_ALL=C.UTF-8`, `TZ=UTC`; `false` passes the parent's through |
| `call_timeout_ms` | 10000 | timeout of one call; changeable later: `child.call_timeout_ms = 30000` |
| `boot_timeout_ms` | 20000 | start plus the project's minit |
| `kill_on_timeout` | `true` | a call that times out kills the child (see Timeouts) |
| `prompts` | `"cancel"` | `input()`, `confirm()`, ... answer "cancelled" (`"real"`: left alone) |
| `notify_passthrough` | `true` | `vim.notify` is captured AND passed on |
| `track_schedule` | `true` | count scheduled callbacks (for `settle`) |
| `guard` | `{ repo = root }` | config for `testing.guard.install`; `false` installs no guard |
| `size` | `{ rows = 24, cols = 80 }` | screen size used by `screen()` |
| `trace_dir`, `run_dir`, `trace_name` | temp dir | where the trace goes, see Trace |

## Environment, determinism, sandbox

* An **allowlist**, not a copy (`testing.child.env`): `PATH`, `HOME`, `SystemRoot`, ... plus what you
  name in `env_allow` (`"MAGICK_*"`). `GITHUB_TOKEN`, `*_API_KEY`, `$NVIM`, `$NVIM_LISTEN_ADDRESS` and
  everything starting with `NVIM` never reach the child (not even through `env_allow`).
* **Determinism**: `LANG`, `LC_ALL` = `C.UTF-8` and `TZ` = `UTC` are SET; the parent's `LANGUAGE` and
  other `LC_*` are dropped. A spec behaves the same on every machine. `deterministic = false` opts out.
* **Sandbox**: one directory `testing-child-<pid>-<n>` below the temp dir with `config`, `data`,
  `state`, `cache`, `run`, `tmp`; `XDG_*`, `TEMP`/`TMP`/`TMPDIR` point into it, so `stdpath()` and
  `tempname()` never touch the real ones; the editor's log (`NVIM_LOG_FILE`) is in it. Removed by
  `kill()` and when the process ended. `HOME` stays real (git needs it).

## The handle

| Member | |
|---|---|
| `lua(code, ...)` | run Lua (`nvim_exec_lua`); `...` are the chunk's arguments (a `nil` arrives as `vim.NIL`); returns the value |
| `lua_get(expr, ...)` | value of a Lua expression: `child.lua_get("vim.fn.line('.')")` |
| `api.nvim_*(...)`, `fn.name(...)`, `cmd(c)`, `cmd_capture(c)` | the API (the `nvim_` prefix is optional), `vim.fn`, `:command` (and its output) |
| `o`, `bo`, `wo`, `g`, `b`, `w`, `t`, `v`, `env` | `vim.o` ... `vim.env`: `child.o.lines`, `child.g.x = 1`; `b`/`bo` mean the **current** buffer, `w`/`wo` the current window, at the moment of the call |
| `input(keys)` | `nvim_input`: typed like a user, queued; returns before the keys are processed |
| `feed(keys, {remap=, typed=})` | `nvim_feedkeys` with `x`: the typeahead is drained before it returns; `<Esc>` names are translated; mappings apply |
| `mouse(button, action, mods, row, col, grid?)` | `nvim_input_mouse`; 0-based screen cells |
| `settle(timeout_ms, {raise=, rounds=, interval_ms=})` | wait until idle: `true`, or `false, why` |
| `screen()` | `{ size, cursor, mode, lines, attrs, text }` |
| `notifies({clear=})`, `prompts({clear=})` | what the child notified / what it answered with "cancelled" |
| `messages()` | the lines of `:messages` |
| `effects()` | the guard's ledger `{ spawned, network, fs_outside_tmp }` (empty without a guard) |
| `guard.<method>(...)` | forward to the guard handle in the child: `guard.begin_case(ctx)`, `guard.end_case()`, `guard.collect()`, `guard.answer_prompts(...)` (plain data only) |
| `request(method, args?, timeout_ms?)` | raw msgpack-rpc call |
| `alive()`, `ensure_alive()`, `status()` | liveness (never raises / raises `child died: ...` / `{ state = running\|exited\|killed\|crashed, exit, exit_text, kill_reason }`) |
| `stderr()`, `trace()`, `write_trace(reason?)`, `trace_artifact()` | see Trace |
| `reset()`, `restart()`, `kill()`, `close_stdin()` | see Lifecycle |
| `pid`, `sandbox`, `dirs`, `boot_info()`, `rebaseline()` | facts and the settle baseline |

Return values: a `vim.NIL` at the top of a result becomes `nil`; buffer, window and tab handles are
plain integers and are **never cached** by the driver: the child checks them when the call executes
(`Invalid buffer id: 9999` is the child's message), and the accessors `b`, `w`, `bo`, `wo` re-resolve
"current" every time. An empty Lua table that nvim wants as a dictionary (`nvim_get_option_value("lines",
{})`) is converted from the API metadata.

**Errors from the child** raise in the parent with the child's message and Lua traceback:
`child error in nvim_exec_lua: Lua: ...: boom` + `stack traceback:`. The child survives them.

## `feed` versus `input`

`feed` is `nvim_feedkeys(keys, "mtx")`: keys are handled as typed, mappings apply, and the call returns
when the typeahead is empty. Work a mapping *starts* (a timer, a job, `vim.schedule`) is not part of
that. `input` queues the keys and returns at once. In both cases `settle` is how a spec waits for the
rest. Keys that leave an operator pending or wait for a prompt are the spec's responsibility: use
`<Esc>` or answer them.

## `settle(timeout_ms)`: what "idle" means, and what it does not know

The Playwright "networkidle" for Neovim. It polls a probe in the child every few milliseconds and
returns `true` after **two consecutive quiet probes**. A probe is quiet when:

1. no typed key waits (`getchar(1) == 0`),
2. no mode waits for the user (`nvim_get_mode().blocking`),
3. no callback scheduled with `vim.schedule` is pending (counted through a wrapper of `vim.schedule`
   installed at start),
4. no more libuv handles per type (timers, jobs, pipes, fs watchers, ...) are active than at the
   **baseline** taken right after the minit. nvim's own `signal`, `async`, `tty`, `idle`, `check`, `prepare`
   handles are ignored.

Otherwise it returns `false, "not idle after N ms: handles (timer=1)"` (`raise = true` raises that).
**What it cannot know:** a callback scheduled through a reference to `vim.schedule` taken before the
boot ran (a plugin's `local schedule = vim.schedule` at load time); work a plugin has not started yet (a
debounce that arms its timer on the next event); work in other processes; a plugin that keeps a
periodic timer for ever (it never settles: the message names the handle type; call `rebaseline()`
after the plugin was set up to accept it). A half typed mapping (`gq` of `gqq`) is busy until
`timeoutlen` ran out, because its timer is a handle. It is a heuristic for "nothing the editor
started is still running", not a proof.

## `screen()`

Attaches a UI on first use (`size`), forces a redraw and reads the grid with `screenstring()` /
`screenattr()`. `lines[r]` is row r (one character per cell), `text` the same with trailing blanks cut,
`attrs[r]` one letter per cell: space = no highlight, otherwise one letter per **distinct** attribute in
order of first appearance. Attributes are comparable, not resolvable to a highlight group (use
`vim.inspect_pos` in the child for a buffer position). `cursor` is the screen cursor (1-based).

## Notifications, messages, prompts, guard

* `vim.notify` is replaced in the child after the minit ran; each call is pushed to the parent as a
  notification, so `notifies()` is still there when the child died and the trace contains the last ones.
  A plugin that cached `vim.notify` in a local before that bypasses the capture.
* `prompts = "cancel"` (default): `vim.fn.input`, `inputdialog`, `inputsecret`, `inputlist`, `confirm`
  answer "cancelled" immediately and are recorded (`prompts()`: `{ fn, text }`). `child.fn.input(...)`
  goes through `vim.fn` and is covered; `:call input()` and Vimscript are not (a request that blocks
  on a prompt ends as a timeout, never a hang).
* **Guard**: if `testing.guard` exists in the child's runtimepath, `install(cfg)` is called once at
  start (config: the `guard` option). The returned handle is kept: `child.guard.begin_case(...)`,
  `end_case()`, `collect()` forward to it, `effects()` returns the ledger. When a guard is installed it
  owns the prompts (the driver's capture is off). A guard whose `install` raises makes `spawn` fail. A
  `testing.guard` module whose `install` returns no handle but has a module-level `collect()` works for
  `effects()`.

## Lifecycle

* `reset()` (warm reset): back to one tab, one window, normal mode, an empty command line, no buffers,
  the baseline working directory; the captures are cleared. It **returns what is still different** as
  readable sentences: `autocmd BufEnter in group MyGroup (pattern *)`, `global keymap n <F9>`,
  `vim.g.leaked_global`, `1 active timer handle(s)`. An empty list = clean. Autocmds, mappings,
  globals and `package.loaded` are *not* undone (an honest reset cannot); a non-empty list means
  `restart()`. The editor's own lazily created `nvim.*` groups are ignored.
* `restart()`: kills the tree and starts a new process with the same options; the handle is the same
  (`pid`, `sandbox`, `dirs` change).
* `kill()`: kills the whole **process tree** and waits until it is gone (never longer than 10 s, then
  the process is abandoned), removes the sandbox. Windows `taskkill /PID /T /F`; POSIX: the root is
  frozen, its descendants are read from one `ps` call, the process group and every descendant get
  SIGKILL (a `jobstart`ed helper has a group of its own). A grandchild that was reparented before
  the walk is not found. Idempotent.
* `close_stdin()`: ends the session from the client side; an embedded editor quits by itself (exit
  code 1, reported as `exited`). Nothing hangs when the client goes away.

## Dead children and timeouts: never a hang

* The process ends while a call is running: the call raises at once `child died during nvim_exec_lua:
  it ended with exit code 139 (= 128 + signal 11 (SIGSEGV))` plus the tail of what the child left (see
  below) and the trace path. `status().state` is `crashed` (signal or non-zero exit), `exited` (code
  0, `:qa`, `close_stdin`) or `killed`. Every later call raises `child died: ...` too.
* A call that does not answer within `call_timeout_ms`: with `kill_on_timeout` (default) the whole tree
  is killed and the call raises `RPC call nvim_exec_lua timed out after 500 ms (child pid 4711 was
  killed)`. After a timeout the child's state is unknowable and every later call would queue behind the
  stuck one, so it does not stay around. `kill_on_timeout = false` leaves it (and `kill()` is yours).
* An embedded nvim forwards **no stderr** (measured on Windows and Linux): the driver reads what is
  there anyway (its pipe), the reason of a failed start (`rpc_init` writes it to a file) and the tail
  of the editor's own log in the sandbox. A stuck `input()` is a timeout.
* The driver never serves a request FROM the child (it answers with an error): a spec cannot make the
  child call into the editor that runs the tests, which `jobstart({ rpc = true })` would allow. This is
  the reason for the own msgpack-rpc client, plus: `vim.rpcrequest` blocks without a timeout.

## Trace

On a timeout or crash the driver writes a small JSON file (and `trace_artifact()` returns the record
for `case.artifacts`: `{ kind = "trace", path = ... }`; `write_trace()` writes one on demand):

```json
{ "version": 1, "reason": "timeout", "child": { "pid": 4711, "exit_text": "...", "kill_reason": "timeout", "argv": [...] },
  "calls_total": 214, "calls": [ { "n": 214, "method": "nvim_exec_lua", "args": "...", "at_ms": 5120, "ms": 500, "status": "timeout" } ],
  "events": [ { "at_ms": 5001, "kind": "notify", "text": "about to hang", "level": "WARN" } ],
  "stderr_tail": "...", "truncated": false }
```

* the last **50 calls** (arguments clipped to 240 characters, outcomes `ok`, `error`, `timeout`,
  `died`), the last **100 events** (`notify`, `prompt`), the tail of stderr / start error / log;
* **bounded** to 128 KiB (SEC-32): the oldest history is dropped first, `truncated` says so;
* **redacted like the IR**: every string goes through the IR kernel (`<REPO>`, `<HOME>`, `<TMP>`,
  `<STATE>`, user and host name, environment pairs, e-mail shapes);
* written atomically into `trace_dir` (default `<tmp>/testing-traces`); the artifact path is
  `<RUN>/<relative>` when the file lies inside `run_dir`, otherwise the absolute path, which the IR
  encoder turns into `<TMP>/...`.

The runner writes the same kind of file for a **child per file** (`--isolated file`) that timed out or
died, and for a warm pool member: `trace = true` (the default; `--no-trace` / `trace = false` turn it
off) puts a `{ kind = "trace", path }` record in `artifacts` of the `timeout` / `crash` case. The file
holds the cases the child finished, how it ended (exit, kill reason) and the tail of its stderr; a pool
member's file has its RPC calls too. They go to `<stdpath('state')>/testing-traces/<run-id>/` (it
survives the run, a CI job can upload it); `<run-id>` is `<date>-<time>-<pid>` of this editor, so
parallel runs (CI jobs, the fleet) never share a folder. At most 40 files are kept per run, and whole
run folders whose newest file is older than a week are removed (looked for once per editor, at its first
trace); another run's young folder is never touched. File names carry the pid and a counter (a reused pid does not overwrite). The path in the IR
is `<STATE>/testing-traces/<run-id>/...`.

## Calls that do not block

`spawn` and every call of the handle wait with `vim.wait`: right for a spec, wrong for a supervisor
that has to keep watching other children while one of them runs a whole spec file. Three additions
serve that (the warm pool uses them; a spec can too):

* `rpc.spawn_async(opts, cb)` starts the editor and returns at once; `cb(child)` or `cb(nil, err)` runs
  on the main loop when the boot request was answered (or after `boot_timeout_ms`).
* `child.exec_async(code, args, cb)` runs Lua in the child like `lua`, without waiting: `cb(ok, result)`
  runs ONCE on the main loop, when the answer arrived or the process ended, whichever is first. A
  process that dies completes the call with `ok = false` and the death message, a call on a dead
  child fails the same way: never a hang. **It has no timeout of its own**: the caller supervises its
  deadline and kills the tree (`require("testing.child").kill_tree(child.proc())`).
* `child.proc()` is the process handle (`testing.child`: `pid`, `exit`, `kill_tree`, ...) and
  `child.death_text()` what explains its end (stderr tail, the reason of a failed start, the log tail).
* The option `defer_plugins = true` builds the runtimepath (`rtp_prepend`, `rtp`, the minit) but applies
  it only after the editor sourced its `plugin/` files, like a child started with `-c` never has the
  project on its runtimepath while the editor loads plugins. Default `false`: a real session.

## The warm pool: files after each other in one editor

`--pool-reuse` (`pool = { reuse = true }`) runs the spec files of an `--isolated file` run in pool
members instead of a child per file ([lua/testing/run/pool.lua](../lua/testing/run/pool.lua)). A member
is an RPC child as described above (embedded, headless, sandboxed, deterministic), started with
`defer_plugins`, and boots like any other child: the project's minit runs once, in the member.

One file in a member is two requests, so that the editor returns to its main loop in between (what the
file scheduled can run; the editor's own idle hooks fire):

1. `run`: soft isolation takes its snapshot, the file runs through the same runner a child per file uses
   (`testing.child.runner`: selector, guards, timeouts, fragment records), the output of `:messages` is
   kept;
2. `finish`: the soft isolation restores what the file changed and checks its own work (captures again
   and compares; modules loaded during the file are unloaded, `lib.*` included, so a lib.nvim module that
   registered an autocmd when it loaded registers it again; `vim.*`, `jit.*` and `testing.*` stay, and so
   do the editor's own `nvim.*` autocmd groups and `g:loaded_<name>_provider` flags), the **options** of every scope are put back to the values of the start (a `:set` of a
   buffer- or window-local option also changes the global default of every new buffer and window),
   `reset()` wipes buffers and closes windows (floats included) and tabs and deletes every `t:` and
   `w:` variable of the tab and window that stay (and, when `vim.diagnostic` is loaded, every
   diagnostic); the **registers** (`a-z`, `0-9`, `-`, `/` and the unnamed one) and the **abbreviations**
   are put back; the **sandbox directories** (`stdpath` config, data, state, cache) lose everything the
   file wrote, and the structure is checked: one tab, one window, one empty unnamed buffer, normal mode.
   Finally the **identity of functions** is compared with the start: a function of `vim`, `vim.api`,
   `vim.fn`, `vim.fs`, `vim.json`, `vim.uv`, `vim.ui`, `vim.keymap` (and of `vim.lsp`, `vim.diagnostic`,
   `vim.treesitter` when they were loaded already), of `string` (and its metatable), `table`, `os` and
   `io` that a file replaced, removed or added is a leak that discards the member and is named
   (`vim.fn.expand was replaced`). A function created lazily by `vim.fn` on first use is not mistaken for
   one (it is recognised by where it was defined). The member never loads `vim.lsp` or `vim.diagnostic`
   on its own account: plugin code asks `rawget(vim, "lsp")` whether that happened.

The member is used again only when everything above came back empty: nothing the soft isolation could
not restore, no active libuv handle (a timer, an fs watcher, a language server's process and pipes), no
running job (`jobstart`; libuv hides those from the handle walk, their channel is counted) and no unrun
callback more than at the start, nothing left in the sandbox, no option that would not go back. Otherwise it is
**discarded** (its process tree is killed), the next file gets a new member, and a finding on the file's
last case says why (`pool` / `pool.discarded`: `<file> leaves state the warm pool could not reset ...`;
severity follows `guards.state`: `error` fails the file, `warn` reports, `off` records it as `info`).
A member that crashes or exceeds its hard limit dies alone: the other members and the files after it
are untouched, the file is one `crash` / `timeout` case with a trace artifact (the RPC calls of the
member included).

What it does not do, and why that is the honest limit:

* **`script` files and `isolated = "case"` never use a member**: a script ends its own process, and a
  child per case is the point of `case`.
* It cannot see state that lives in a C library, in an upvalue the snapshot cannot reach, or in a module
  that keeps a reference to something that was restored (the runtime's own `nvim.*` autocmd groups are
  therefore never touched). A suite that depends on `package.loaded` of a plugin being fresh for every
  file gets that through the soft isolation's unload; a spec that holds on to a module table across files
  (`dofile` caches, singletons in `_G`) is what the verification exists to name.
* **Not checked at all**: marks, quickfix and location lists, highlight groups,
  `vim.diagnostic` configuration (when it was not loaded at the start), extmark namespaces, signs, a
  function that is only reachable through a closure, the state of language servers that are
  not libuv handles of this editor. (A language server a file leaves running is a libuv process with pipes, or a job: it discards the member.) The state guard names highlight and option changes per case (`warn`), but they do not
  stop a member from being reused. A project whose specs need a pristine one of these uses a child per
  file.
* The first file in a member starts with the editor already entered (`v:vim_did_enter` is 1), not like a
  `-c` child (0). A project whose specs depend on that must use a child per file. (Found in the
  fleet: ui.nvim's `menu_spec` "a setup with prewarm = false cancels a chain that has not started yet"
  counts a chain that only waits for `VimEnter` in a `-c` child; in a member that chain has started.)
* A red case in a member that already ran files carries a note naming the files before it and the
  way to tell a leak from a bug (`--no-pool-reuse`): the verification cannot see everything.
* Output of a file is what `:messages` holds, not what a child's stdout would have received.
* It costs time where it cannot be used: a suite whose files all leave something behind pays for the
  check and respawns anyway. The numbers are in [ISOLATION.md](ISOLATION.md).

Options: `--pool-size <n>` (default `min(--jobs, 4)`, never more than `--jobs`), `--pool-reuse` /
`--no-pool-reuse`, `.testing.lua` `pool = { size, reuse }`. `testing doctor` and `:checkhealth testing`
show what is in effect.

## Limits (honest)

* `settle` is a heuristic (above). `screen()` attributes are not highlight groups.
* The capture of `vim.notify` and the prompts is a monkeypatch: not a sandbox. The guard is a safety
  net, not a boundary; the boundary is the process plus the OS ([docs/GUARDS.md](GUARDS.md)).
* `messages()` needs a child that answers; after a crash only the notifications, the events and the
  log tail remain.
* The per-call timeout does not interrupt a child that is stuck in C; it kills it.
