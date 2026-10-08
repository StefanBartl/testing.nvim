# Guards and the effects ledger

`testing.guard` is a set of **safety nets** around a spec, plus a **ledger** that records what a
case did to the outside world. It can be installed in ANY Neovim: the child editor of an isolated
run installs it at boot, the in-process driver installs it in the runner's own editor.

> **Honest limit: guards are nets, not a sandbox.** They are monkeypatches of Lua functions. Lua
> code can bypass every one of them (a reference saved before the install, `rawset`, a C module,
> another process). Vimscript (`:call input()`, `:!cmd`, `system()` called from a `:call`) does not
> go through the Lua wrappers. The guards stop accidents and name them precisely; they do not stop
> an attacker. The real boundary is the process plus the operating system: a container or a VM.
> Do not run code you do not trust on the strength of these guards.

## Quick start

```lua
local guard = require("testing.guard")

local h = guard.install({
  repo = root,                                  -- the project root (also used for <REPO> redaction)
  guards = {
    process_net = { allow_exec = { "git" } },   -- config, nothing is hard-coded
    fs = { allow = { vim.fn.stdpath("state") .. "/myplugin" } },
  },
})

h:begin_case({ id = "a_spec.lua::group::case", file = "a_spec.lua", tags = { "spawn" } })
-- ... the spec body runs ...
local res = h:end_case()   -- { findings, effects, ledger, restored }

local run = h:collect()    -- { effects, findings, ledger, notes } over everything so far
h:uninstall()              -- every patch undone
```

| Call | Meaning |
| --- | --- |
| `guard.install(cfg) -> handle` | Installs the guards. Raises on an invalid config (a typo must not switch a net off). |
| `handle:snapshot(opts?)` | The "before" half. `opts.heavy` also takes the file-tree snapshot of the fs guard (per file, not per case). |
| `handle:enter(ctx?)` / `handle:leave()` | Open / close the **window** in which the wrapping guards are active. |
| `handle:check(ctx?) -> findings[]` | The "after" half: compares with the snapshot, returns every finding of the case so far. Idempotent. |
| `handle:begin_case(ctx, opts?)` / `handle:end_case(opts?)` | `snapshot + enter` and `leave + check (+ restore)`. `end_case` returns `{ findings, effects, ledger, ledger_data, restored }`. |
| `handle:collect(opts?) -> { effects, findings, ledger, ledger_data, notes }` | Everything since install. `effects` has the three IR lists plus `prompts` / `deprecations`; `ledger_data` is the plain (RPC-safe, mergeable) form of the ledger. `{ reset = true }` clears afterwards. |
| `handle:restore(which?)` | Soft isolation on demand (see the state guard). |
| `handle:answer_prompts{ input = ..., select = ..., confirm = ..., getchar = ... }` | Scripted prompt answers (prompt guard). |
| `handle:allow("spawn"\|"network", name)` | Allow an executable / host for the open case. |
| `handle:suspended(fn)` | Run `fn` with the wrappers silenced (a harness helper that must call `git`). |
| `handle:clock()` | The fake clock (clock guard), `nil` when the guard is off. |
| `handle:uninstall() -> unrestored` | Undo everything; the result lists patches that could not be undone because something wrapped over them. Idempotent. |
| `guard.tags_from_name(s)` | `@network`, `@spawn`, ... in a test name. |
| `guard.CANCEL` | Answer value for "the user cancelled". |

`ctx` (`Testing.Guard.CaseCtx`): `id`, `file`, `name`, `tags` (list of `"network"` / `"@spawn"`, or a
set), `settle_ms`. Tags are also read from `@tag` words in `id` and `name`.

### The window

The wrapping guards (process, network, prompt, deprecation, filesystem, scheduled-error) do
nothing but one boolean test unless a case is open. The runner and the helpers of lib.nvim spawn
processes and write files between cases; those never reach the ledger and are never blocked. The
snapshot guards (state, file tree) compare before/after and do not need the window.

## Configuration

Defaults live in [`lua/testing/guard/config.lua`](../lua/testing/guard/config.lua) (`DEFAULTS`).
A section is a table or a bare mode string (`fs = "off"`, `prompt = false`).

| Key | Default | Meaning |
| --- | --- | --- |
| `strict` | `false` | Promotes every `warn` to `error` (the later `--strict`). |
| `settle_ms` | `0` | `vim.wait(settle_ms)` before the checks so pending `vim.schedule` callbacks ran. |
| `max_findings` | `500` | Bound of the findings kept per run (SEC-32); the rest is counted in `notes`. |
| `restore` | `false` | Soft isolation after each case: `true` (default set) or a list of state categories. |
| `ledger` | `{ max_entries = 200, max_text = 300 }` | Bounds of the ledger. |
| `repo`, `run_dir`, `tmp` | `nil` | Redaction root (`repo`); extra allowed write roots (`run_dir`, `tmp`). |
| `roots` | derived | Explicit `{ repo, home, tmp, state }` for the `<REPO>` / `<HOME>` / `<TMP>` / `<STATE>` placeholders. |
| `guards.<name>.mode` | see below | `off` (not installed at all), `warn`, `error`. |
| `guards.fs.watch_stdpath` | `false` | Also walk the real stdpath config / data / state / cache trees in the tree snapshot (see below). |
| `guards.prompt.getchar_wait_ms` | `300` | How long a blocking `getchar()` with nothing typed ahead waits for the spec to feed a key (see below). |

(`testing.guard.install` takes all of these; `.testing.lua` and the flags reach the modes and
`guard_allow` only, through `testing.run.options.guard_config`.)

These are the defaults of the guard layer itself (`guard.install` called by a spec or a tool). **The runner
(`testing`, `.testing.lua`) starts from its own, safer set** ([CONFIG.md](CONFIG.md)): `fs = "warn"`,
`state = "warn"`, `process_net = "off"` (its ledger then says "not measured"), the rest as below. A project
switches `process_net` on with `guards = { process_net = "warn" }` and lists what is expected.

| Guard | Default mode (guard layer) | Fails the case by default |
| --- | --- | --- |
| `fs` | `error` | yes |
| `state` | `error` (per category, see below) | yes (`options`, `vars`, `env`, `highlights`, `lua_globals`, `preload`, `channels` only warn; `modules` is info) |
| `scheduled_error` | `error` | yes |
| `prompt` | `error` | yes |
| `deprecation` | `warn` | no, `error` under `strict` |
| `process_net` | `error` | yes |
| `clock` | `off` | never produces findings |

### Tuning a guard in `.testing.lua`

`guards.<name>` is a bare mode or a table `{ mode = ..., <key> = ... }`. The table form reaches the guard
layer through `require("testing.run.options").guard_config`; lists add to the layer's own defaults (a
project's `ignore_groups` does not drop the editor's `nvim.`), plain values replace them.

A key is checked on its own: a wrong value or an unknown key is one warning that names it
(`key 'guards.fs.allow' is invalid ...`, `unknown key 'guards.fs.typo'`), and the valid keys of the same table stay,
the `mode` included. (A table is dropped as a whole, and the guard keeps its default, only when no key of it is valid.)
A list of Lua patterns (`allow_patterns`, `ignore_patterns`) is walked for its syntax, not just probed: `a[`, `%.log%`
or `x%b` are refused with the key named (the default stays), because they raise on the first file name that reaches the
broken item. An `ignore_patterns` entry that gets to the fs guard anyway (a use of the guard layer without the project
configuration) is dropped with a note: the tree snapshot then sees more files, and is never lost.

| Guard | Keys besides `mode` |
| --- | --- |
| `fs` | `allow` (directories, added to `guard_allow.fs`), `allow_patterns`, `ignore`, `ignore_patterns` |
| `state` | `categories` (`{ <category> = "error"|"warn"|"info"|"off" }`, capped at the guard's mode), `ignore_groups`, `ignore_vars`, `ignore_options`, `ignore_env`, `ignore_globals`, `ignore_highlights`, `ignore_usercmds`, `ignore_keymaps` (name or left-hand-side prefixes), `keep`, `max_per_category` |
| `scheduled_error` | `allow_patterns`, `notify` |
| `process_net` | `allow_exec`, `allow_hosts` (added to `guard_allow.spawn` / `.network`) |
| `prompt` | `getchar_wait_ms` |

`state.keep` is the short way to say "`setup()` leaves these on purpose": every name in it is ignored as an
autocmd group, a user command and a keymap left-hand side (prefix match). A plugin whose `setup()`
creates a hundred commands under one prefix needs one line instead of one per category:

```lua
guards = {
  state = { mode = "warn", keep = { "MyPlugin" }, categories = { options = "off" } },
  process_net = { mode = "warn", allow_exec = { "git" } },
}
```

## Findings

`{ id, guard, severity = "error"|"warn"|"info", message, case, file, detail?, stack?, count }`.
The same id + message inside one case is stored once and counted. Messages and stacks pass the
redaction (`<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`, secrets). The stack (a deprecated call, an
unanswered prompt, a scheduled error) travels into the IR as `case.guards[i].stack` (at most 2000
bytes), so a finding like "uses a deprecated API: vim.highlight" names its call site without a manual
grep.

| Id | Guard | Meaning |
| --- | --- | --- |
| `fs.write_outside` | fs | A wrapped write entry point wrote outside the allowed roots. |
| `fs.changed_outside` | fs | The tree snapshot saw a created / modified / deleted file the wrappers did not name. |
| `state.autocmd` | state | `spec X leaves autocmd BufEnter in group MyGroup (pattern *.lua)` |
| `state.usercmd` | state | A user command (global or buffer-local) that was not there before. |
| `state.keymap` | state | A global or buffer-local map added, replaced or removed. |
| `state.buffer`, `state.window`, `state.tab` | state | Created and still alive. |
| `state.cwd`, `state.rtp` | state | Working directory / runtimepath entries changed. |
| `state.option` | state | A global option value changed (named diff with both values). |
| `state.var`, `state.env` | state | `vim.g` / environment variable added, changed or removed (names only, never values). |
| `state.highlight` | state | Highlight group added or redefined. |
| `state.lua_global` | state | New key in `_G`. |
| `state.preload` | state | New key in `package.preload`: a stub that makes a later `require` of that name fail or answer wrongly. (Found in the fleet: a spec "restores" its stubs from a table that skips nil values, so a stub that did not exist before stays.) |
| `state.channel` | state | A job started by the case is still running. |
| `state.module` | state | `package.loaded` key added (info). |
| `scheduled.schedule_callback` | scheduled_error | A `vim.schedule` callback threw (message and stack). |
| `scheduled.luv_callback` | scheduled_error | A luv / timer callback threw. |
| `scheduled.error_message` | scheduled_error | `E5105` / `E5107` / `E5108` / "Error detected while processing" in `:messages`. |
| `scheduled.notify_error` | scheduled_error | `vim.notify(msg, ERROR)` during the case (`notify` severity, default `info`). |
| `prompt.unanswered` | prompt | A prompt without an answer (the call raised). |
| `deprecation.used` | deprecation | `vim.deprecate` was called. |
| `process.spawn_blocked` | process_net | A process was started (blocked in mode `error`). |
| `network.blocked` | process_net | A network call was made (blocked in mode `error`). |
| `pool.discarded` | pool (the runner, not a guard) | A warm pool member could not prove it was clean after this file and was replaced ([CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor)). |

## The guards

### fs: writes outside the run folder

Two independent nets.

1. **Wrappers** while a case is open: `io.open` (write, append and update modes), `io.output`,
   `os.remove`, `os.rename`, `vim.fn.writefile` / `delete` / `mkdir` / `rename`, `vim.uv.fs_open`
   (string and numeric flags) and the path-taking luv mutators (`fs_unlink`, `fs_mkdir`, `fs_rmdir`,
   `fs_rename`, `fs_copyfile`, `fs_symlink`, `fs_link`, `fs_mkdtemp`, `fs_mkstemp`, `fs_chmod`,
   `fs_utime`), plus `BufWritePre` for `:write` / `:saveas`. The path is **resolved**
   (`lib.nvim.fs.normkey`: relative to the cwd, `..` and symlinks / junctions / 8.3 names resolved, the
   deepest existing ancestor for a path that does not exist yet) before it is compared (SEC-40).
2. **Tree snapshot** (`snapshot{ heavy = true }`) of watched roots, default: the cwd and the repo
   root (`watch_stdpath = true` adds stdpath config / data / state / cache): names, sizes and mtimes
   of at most `max_files` (5000) files below `max_depth` (12). It sees what the wrappers cannot (a C
   library, `git`, a nested editor), but it is heavy: take it per file, not per case. A truncated walk
   says so in `notes`. The real stdpath trees are opt-in because a developer machine holds tens of
   thousands of files there (plugin clones, a whole config repo): with them watched, two trivial specs
   took 7 seconds under `--isolated none`, 0.02 s without; a walk cut at `max_files` is mostly blind
   anyway. The wrappers still see every write that goes through Lua.

Allowed: the OS temp dir (`uv.os_tmpdir()`), the directory of `tempname()`, `run_dir`, `tmp`,
`guards.fs.allow` (directories) and `allow_patterns` (Lua patterns on the resolved, forward-slash
path), and the **sandbox of a child editor**: when the temp dir is `<base>/tmp` and `stdpath('data')`
and `stdpath('state')` lie below `<base>/data` and `<base>/state` (the layout of
`testing.child.env.sandbox_env`), all of `<base>` is allowed. A plugin that writes its usage file into
its own `stdpath('data')` in a child writes into a directory that dies with the child; it was 62
warnings in one fleet repo. The layout decides, never a name. Legitimate writers (sessions, cmdlog, calibration files) belong into the project's config.
`block = true` raises instead of observing. Read-only opens never count.

### state: leaks between specs

A snapshot before and after: autocmds (group, event, pattern), user commands, keymaps (global and
buffer-local of surviving buffers, modes n/i/x/s/o/c/t/l), buffers / windows / tabs, cwd, runtimepath,
all global option values, `vim.g`, the environment, highlight groups, `_G`, `package.preload`,
running jobs and `package.loaded`. Each category has its own severity (`categories`); `ignore_groups`, `ignore_vars`,
`ignore_options`, `ignore_env`, `ignore_highlights`, `ignore_globals` take prefixes / names. More
than `max_per_category` (20) items of one category are summarized in one finding.

What the editor's **own runtime** changes when a spec loads a filetype, a syntax or a lazily loaded
module is never a leak of the spec and is not captured at all (35 to 50 percent of all findings in the
fleet runs): `vim.g.markdown_*`, `java_*`, `typescript_*`, `pandoc#*`, `lua_version`, `lua_subversion`,
`did_load_*`; the global value of the `syntax` option; `_G.re`; highlight groups defined with
`default = true` (every `$VIMRUNTIME/syntax/*.vim` does); the jobs of the clipboard provider
(`win32yank`, `xclip`, `pbcopy`, `wl-copy`, ...). The lists are `RUNTIME_*` / `CLIPBOARD_PROVIDERS` in
[`state.lua`](../lua/testing/guard/state.lua). `g:loaded_<plugin>` flags are NOT ignored: they are the
plugin's own and can stop a later `:runtime plugin/...` in the same editor.

**Soft isolation** (`restore = true | {...}` or `handle:restore()`): closes windows / tabs and
deletes buffers the case created, restores the cwd, deletes leaked autocmds and user commands,
deletes / restores keymaps, puts back options, `vim.g`, environment, runtimepath and highlights.
`modules`, `lua_globals` and `preload` are restored only when named explicitly; running jobs are never stopped. This is an aid for
in-process runs, **not isolation**: a module-local cache, a replaced Lua function, a coroutine or an
upvalue stays. `isolated = file` is the real fix; the guard tells you what to fix.

### scheduled_error: errors nobody sees

Neovim prints an error in a scheduled / luv callback and goes on; the spec stays green. While a case
is open `vim.schedule` runs the callback under `xpcall` (the error is re-raised, so the editor
reacts as before); after the case `:messages` is scanned from the position of the snapshot; ERROR
notifications are recorded. `allow_patterns` lets a deliberate error through. Limit: the message
history is bounded, an error pushed out of it is only seen if `vim.schedule` wrapped it.

### prompt: nothing blocks

`vim.fn.input` / `inputdialog` / `inputsecret` / `inputlist` / `confirm` / `getchar` / `getcharstr`
(blocking forms; `getchar(0)` and `getchar(1)` poll and pass) and `vim.ui.input` / `vim.ui.select`
are replaced. A blocking `getchar()` / `getcharstr()` is not a prompt when a key is typed ahead (a
test that `nvim_feedkeys`s its key before calling a picker) or when one arrives while it waits: with
nothing typed ahead the event loop runs for `getchar_wait_ms` (default 300) so that a timer or an
autocmd of the spec can feed the key (ui.nvim's window picker tests do exactly that); only then it is
refused. `getchar_wait_ms = 0` refuses at once. Answers: `h:answer_prompts{ input = "yes", select = 2, confirm = 1, getchar = "y" }`:
a scalar answers every prompt of its kind, a list is consumed in order, a function is called with
the prompt arguments, `guard.CANCEL` cancels. Without an answer the call raises an error naming the
prompt and carrying the stack, and `prompt.unanswered` stays a finding even if the spec `pcall`s
it. In mode `warn` the call does not raise: the finding is a warning and the prompt is answered like a
cancelled one (`""`, Esc, `nil`, `0`), because nothing may wait for a key in a headless run (mode
`warn` used to fail the case anyway; under `--strict` a `warn` is an `error` and raises). Every prompt is in the ledger kind `prompts`. Answers belong to a case (reset by `enter`).

### deprecation

`vim.deprecate` is recorded (once per API and case) instead of printed: `warn`, `error` under
`strict`. Ledger kind `deprecations`.

### process_net: processes and network

Wrapped: `vim.system`, `vim.fn.jobstart` / `termopen` / `system` / `systemlist`, `io.popen`,
`os.execute`, `vim.uv.spawn`; `tcp:connect`, `udp:send` / `try_send` / `connect`,
`vim.uv.getaddrinfo`, `vim.net.request` (if the editor has it), `vim.fn.sockconnect`.

Every attempt goes into the ledger (`spawned` with the redacted argv, `network` with the host);
blocked entries are marked `[blocked]`. A call is **let through** (still logged) when

* the case has the tag `@spawn` (processes) / `@network` (network), in `tags` or as a word in its name;
* the executable (file name, `.exe` / `.cmd` / `.bat` ignored, case-insensitive) is in
  `guards.process_net.allow_exec`, or the host in `allow_hosts`;
* the case called `h:allow("spawn", "git")` / `h:allow("network", "host")`.

Otherwise (mode `error`) the call raises `testing.guard: ... (blocked: tag the case @spawn or list it
in guards.process_net.allow_exec)`. Mode `warn` lets everything through and only reports.
`@network` allows the network only, `@spawn` processes only. One attempt is one ledger entry
(`vim.system` calls `uv.spawn`, `vim.net.request` calls `vim.system`: a re-entrancy guard folds
them). A command given as a **shell string** is judged by its first word only (the extra outer pair of quotes that
`cmd /c` wants around a line whose program is quoted, `""git" "--version" 2>&1"`, is no part of it).

Redaction (SEC-10 / SEC-22): `--token abc`, `--password=...`, `Authorization: <scheme> ...`, `Cookie:` /
`X-*-Token` / `X-*-Key` headers, URL user info and secret query keys (`?key=`, `&sig=`), JSON members
(`"password": "..."`), the credential flags of `curl` (`-u`, `--user`, `-U`, `-b`, `--cookie`; the
one-letter ones also with the value attached, `-uadmin:pw`), `sshpass -p`,
`docker login -p`, `mysql -pSECRET`, and token shapes (GitHub, Slack, JWT, OpenAI-style, AWS) never reach
the ledger or a finding; the program is shown by file name, so the ledger reads the same on every
machine. This is **best effort**: a secret in a position no rule knows (a bare positional password of an
unknown tool) is not recognized, and the rules err towards masking.

### clock (opt-in)

`guards.clock.mode = "error"` (any mode but `off`) wraps `os.time`, `os.clock`, `os.date`,
`vim.uv.now` / `hrtime` / `gettimeofday`, `vim.fn.localtime` / `strftime`. They are transparent until
a fake clock is **started**: by the tag `@clock` on the case or `h:clock():start{ epoch?, seed? }`.
While started the clock stands still at the real time of the start; `h:clock():advance(ms)` moves
it. A configured `seed` seeds `math.randomseed` and `srand`. The case window closing stops it.

Limits: real timers stay real (`vim.defer_fn`, `uv.new_timer`, `vim.wait` do not use these
functions, so `advance` does not fire them); a loop waiting for the clock to move hangs under a frozen
clock; the seeding cannot be undone.

## The effects ledger

[`testing.core.ledger`](../lua/testing/core/ledger.lua): a bounded (SEC-32), deduplicating,
redacting list per kind.

* `add(kind, text, { blocked?, allowed? })`, `entries(kind)`, `total(kind)`, `dropped(kind)`.
* `to_effects()` is the IR `effects` of a case: always the lists `spawned`, `network`,
  `fs_outside_tmp` (sorted strings, `[blocked]` and `(xN)` marks, a final "N more not recorded" entry
  when the bound dropped something). `to_effects{ extra = true }` adds the other kinds (`prompts`,
  `deprecations`); the IR schema does not carry them yet.
* `merge(other)`: another ledger or its `serialize()` output (several children); counts add up, the
  bounds of the receiver apply, malformed input is refused as a whole.
* `serialize()` / `encode()` / `ledger.deserialize(t)`: sorted and with a fixed key order, so the same
  effects give the same bytes in every merge order.
* `ledger.redactor(roots)`, `ledger.redact_secrets(s)`, `ledger.format_argv(argv)`.

## Cost

Measured on Windows 11, Neovim 0.12.2, one editor, default configuration (all guards, clock on):

| What | Cost |
| --- | --- |
| `install` (7 guards) | about 8 ms once |
| `begin_case` + `end_case` (light snapshot, state diff, `:messages` scan) | about 3 ms per case |
| wrapped call inside the window (`io.open`, `os.time`, ...) | below measurement noise (under 1 us) |
| heavy tree snapshot | proportional to the watched trees; the real stdpath dirs of a developer machine cost seconds (bounded by `max_files`), the sandboxed dirs of a child editor are nearly empty |

Switch off what a project does not need: `state.categories.options = "off"`,
`state.categories.highlights = "off"`, `fs.snapshot = false`. `guard_core_spec` asserts a budget of
50 ms per case and 25 us per wrapped call.

## Self tests

Every guard has RED scenarios (the guard must trigger and must name the problem) and GREEN controls
(it must stay quiet). They run in a **real child editor** (`nvim -l`, started with
`lib.nvim.system.job`, no RPC driver involved):
[`TESTS/testing/fixtures/guard/*.fixture.lua`](../TESTS/testing/fixtures/guard) with the shared
`boot.lua`, driven by `TESTS/testing/guard_<name>_spec.lua`. `guard_core_spec` and
`guard_ledger_spec` cover the in-process variant, the patcher, the ledger and the budget.

## Where the runner installs them

| Run | Where | Window |
| --- | --- | --- |
| in this editor (`isolated = "none"` / `"soft"`) | `testing.run.inproc` installs the layer once for the run (`guard_cfg`) | one per case |
| a child editor per file | the job carries the configuration (`guard`), `testing.child.runner` installs it for the file and uninstalls it with the file; **the state guard is off** in a child that runs ONE case (a file of a one-case dialect, `isolated = "case"`): everything it leaves dies with the process, and naming it was 90 percent of the findings of some fleet runs. The cases say so (`state: leaks ... are not measured`). A busted file keeps it: its cases share the editor | one per case |
| a `script` file | its own `nvim -l` process, one window around the whole file (the state guard is off: the process ends with the file). The window closes and the findings are written when the script returns, raises or calls `os.exit`; a script that leaves the editor with `:cquit` / `:qa!` writes no record and its case says so (`guards: no record from this script file`): an empty list there is not a result | one for the file |
| a warm pool member | the same runner, per file: patches never pile up in a member that runs many files | one per case |

What the guards found travels back with the cases: `case.guards`, `case.effects`, and for findings that
no case can carry (a file that ran no case) the `unattached` list of the `done` record, printed by the
parent. The one adapter from the run options to this configuration is
`require("testing.run.options").guard_config`. The pool adds one finding of its own, `pool` /
`pool.discarded`, when a member could not be reset ([CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor)).

The state guard and the soft isolation both ignore the editor's own lazily created autocmd groups
(`nvim.*`, for example `nvim.diagnostic.buf_wipeout`): the runtime module that made one keeps its id,
so deleting it breaks that module for the rest of the process. They also ignore a groupless `once`
autocmd on `SafeState` (the runtime's matchparen registers one at every cursor move; it removes
itself at the next idle moment).

## Notes for integrators

* A runner that enables the guards on a project whose specs themselves start processes (this
  repository's specs start child editors) lists the executable in `guards.process_net.allow_exec`
  (`{ "nvim" }`) or runs the harness part inside `h:suspended`.
* Call `begin_case` AFTER the harness set the case up and `end_case` BEFORE it tears down, so the
  harness's own spawns, writes and autocmds stay outside the window / the diff.
* In a child editor the stdpath directories and the temp dir are sandboxed (`testing.child`), so the
  fs guard needs no allow list for them.
* A layer that cannot be built (a changed Neovim API, a missing module) raises from `install` and
  undoes the guards that were installed before it; `guard.live_count()` is the number of layers that are
  installed in this editor (a warm pool member that ends a file with one still installed is discarded:
  the next file would wrap the wrappers). The in-process driver uninstalls the layer it installed on
  every path out, also when its own report code raises.
* Run `uninstall` before the editor is reused for anything else; check its result for patches
  something else wrapped over. The guards come down in the reverse install order; a teardown that
  raises is named in the result (`the <guard> guard failed to uninstall: ...`), never swallowed, and a
  slot that cannot be written back does not keep the others installed. `guard.take_unrestored()` returns
  (and forgets) every label no uninstall could put back: a warm pool member asks it after each file, and a
  spec that stubbed `io.open` or `vim.system` on top of a guard's wrapper without restoring it discards
  the member with `guard patch not restored: <slot> (<file> ...)`.
* The fs guard lets exactly the Windows null device through (`nul`, `//./nul`, `\\.\nul`, only on
  Windows); a file named `nul` anywhere else is judged like any other write.
* The snapshot at the start of a busted case runs with the deadlines of the in-process timeout guard
  suspended, so a case deadline of the spec never cuts it off (`guard state: snapshot failed:
  testing: timeout`); its time is not charged to the case.

## Allowlist proposals from the fleet runs

M2 ran every guard over the 35 migrated repositories (24 in warn mode with `--isolated file` and
`none`, 11 busted repositories with and without the warm pool). What is a real leak became a task in the
repository's own area (tag `found-by-testing-nvim`); what is **legitimate** behavior is an allowlist
entry that belongs in that repository's `.testing.lua`, visible in every report. None of them was
written by testing.nvim: the fleet repositories were only measured. The shape:

```lua
guard_allow = { spawn = { "git" }, fs = { "TESTS" }, network = {} },
guards = { process_net = "warn" },   -- the spawn net is off by default; with it on, list what is expected
```

`guard_allow.fs` takes directories (prefix match on the resolved path; a relative path is resolved
against the current directory, which is the project root when the runner is started from it, so use
`--allow-fs` or an absolute path when in doubt), `spawn` executable names, `network` hosts.

| Repository | `guard_allow.spawn` | `guard_allow.fs` | Why |
| --- | --- | --- | --- |
| gitsuite, casedesk, rules, buffer-ctx, fileops, sessions, gopath, documentation | `git` | | The specs make tmp repositories (`git init`, `commit`, `rev-parse`): 508 findings in gitsuite alone, 313 in documentation |
| ai, ui, insights, language, documentation, runtime-analysis | `nvim` | | A fake `claude` CLI, `nvim --version`, a headless nvim as dev server |
| mdview, diff, runtime-analysis | `curl` | | Local servers of the spec; better: stub the transport (diff `url_spec` talks to the real network) |
| pdfport, media, images, dap, markdown | `python3`, `pdftotext`; `ffmpeg`; `magick`, `tesseract`; `rustc`; `rg` | | Real tools the plugin integrates |
| open, fileops | `powershell` | | A security spec of reveal-in-fm (`echo sec34`), the recycle bin |
| lsp | `lua-language-server` | | `probe_live_spec.lua:248` |
| reposcope, sessions, language, recommender, insights | | `TESTS` (or the fixture directories) | Fixtures below `TESTS/.fixture-*` that the specs create and remove in the repository |
| documentation | | `.deps` | `.deps/generate-all-*` fixtures |
| diff, casedesk | | | `Z:/definitely/not/writable` and `/no/such/file.txt` are deliberate negative probes: allow them or give the spec a path below `tempname()` |

Notes:

* Under `isolated = "file"` a plugin that writes into its own `stdpath('data'|'state'|'cache')` needs
  **no** entry: that is the child's sandbox and it is allowed by layout. Without isolation
  (`--isolated none|soft`) those writes go to the real directories of the developer; the fleet
  `scripts/test.sh` files set only `NVIM_APPNAME`, so insights, debugging, markdown and
  runtime-analysis write to `%LOCALAPPDATA%\<app>-tests-data`. The generated `scripts/test.sh` now
  points `XDG_STATE_HOME` and `XDG_CACHE_HOME` at a scratch directory (as this repository's does).
* Plugin-global state that `setup()` leaves (autocmd groups, `:Commands`, keymaps) is harmless with
  `isolated = "file"` and named by the state guard otherwise (ai, dap, my, ui, media, cascade): do not
  allowlist it, restrict the state guard instead: `guards = { state = "off" }` for such a repository
  under isolation, or `isolated = "file"` in its config (the state guard is off in a child that runs one
  case anyway).
* A spec that must see a real, blocking prompt answered by a timer (ui.nvim's window picker) now works
  with the default `getchar_wait_ms`; a spec that needs a prompt answered by the user's own input has to
  be answered with `h:answer_prompts{}`.
* `getchar()` pickers, the clipboard provider's job and the runtime's own highlight, option and variable
  changes (35 to 50 percent of the first runs' state warnings) are handled by the guards themselves and
  need no entry.
