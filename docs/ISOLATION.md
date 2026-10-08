# Isolation modes and the guard settings

Shared state between spec files hides bugs for years: a spec that only passes because an earlier file
left an autocmd, a loaded module or a changed working directory behind. testing.nvim has four ways to
run a file, from cheap to exact, and a set of guards that name what a spec leaks.

Everything below is a **safety net, not a sandbox**: Lua code can bypass every monkeypatch. The real
boundary is the process plus the operating system.

## `isolated`

Set it with `--isolated <mode>` or `isolated = "<mode>"` in `.testing.lua` (the flag wins).

| Mode | What runs where | Cost | Exactness |
| --- | --- | --- | --- |
| `none` | every file in the runner's own editor | none | what one file leaves behind, the next one sees |
| `soft` | the same, but what a file changed is **restored** before the next file | a few snapshots per file | best effort, see below |
| `file` | one child editor per spec file | about 0.3 s per file on Windows, about 0.05 s on Linux | exact between files |
| `case` | one child editor per **case** (busted `it`) | the same per case: 200 cases cost about a minute on Windows | exact between cases |
| `auto` (default) | `file` for busted files, `none` for every other dialect | | |

A `script` file is always a child.

### `soft`

Between two spec files the runner snapshots the editor, runs the file, snapshots again, undoes the
difference and **looks again**: whatever is still different is reported as "NOT restored". Covered:
`package.loaded` entries (except `testing*`, `lib.*`, `vim*` and the Lua runtime, plus your
`soft_keep`), `_G` entries (by identity: a table mutated in place is not seen), `vim.g`, global
options, environment, the working directory, buffers, windows and tab pages, user commands,
autocommands, and keymaps (modes n i x s o c t l). Not covered: highlights, signs, namespaces,
registers, marks, quickfix lists, buffer- and window-local options, timers and other libuv handles,
LSP clients, `vim.diagnostic`. A leak of those survives silently; `file` is the exact answer. (The
warm pool checks and puts back more: registers, abbreviations, tab and window variables, diagnostics,
function identity; see [CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor).)

Every difference is a named finding, restored or not:

```
TESTS/a_spec.lua leaves autocmd BufEnter (pattern *.leak) in group `LeakGroup` (restored before the next file)
TESTS/a_spec.lua leaves global `leaked_global` (restored before the next file)
TESTS/a_spec.lua changes state: buffer 3 (x.txt) was wiped (NOT restored: a wiped buffer cannot be brought back)
```

The finding sits on the **last case of the file that leaked**. Its severity is the mode of the `state`
guard (below): `warn` is a note in the report, `error` fails that case, `off` restores silently. With
the guard layer present its `state` guard names the leaks per case, and the soft isolation reports
only what it could not restore.

`soft_keep = { "my.plugin.cache", "my.shared*" }` lists modules that stay loaded (exact name or
`prefix*`).

### `case`

For busted files. The cases of a file are **listed** first in a **throwaway child** (the describe blocks
run, no `it` body does, exactly like `--list`; `kind = "list"` of the child job): the top-level code of a
spec therefore sees the same sanitized environment and sandbox as in every other child, writes and loops
stay out of the runner, and a load-time hang is cut off by the file timeout (the file is then one `error`
case). The listing child runs **without the guard layer** (no case window exists to judge); the process
boundary is its protection. Selection (`--filter`, `--tags`, `--lf`) is applied in that child. The listings of
several files run side by side, up to `--jobs` of them (each costs an editor start and the load of its file), and
the cases start once their file is listed. Every
listed id then gets a
child that runs only that id. The describe blocks and hooks run again in each child, so a case sees
exactly what the top of its file gives it, never what an earlier case left behind. The results are
merged in listing order (= source order) whatever `--jobs` says, so the IR is the same for every
`jobs`. Honesty rules:

* an id that was listed but that its child did not report is an `error` case (the describe blocks
  differ between runs?);
* a child that dies or times out yields its `crash` / `timeout` case under **the case's id**;
* a file whose listing fails is one `error` case;
* a busted file that lists no case runs as one child, so the empty-file policy decides;
* every other dialect has one case per file: `case` degrades to `file` for it, with a note on the
  file's first case and one line on stderr.

## `guards`

```lua
-- .testing.lua
return {
  guards = {
    fs = "warn",              -- writes outside the run directory and the repo temp
    state = "warn",           -- autocmds, keymaps, buffers, globals, ... a case leaves behind
    scheduled_error = "error",-- errors in vim.schedule callbacks, timers, jobs
    prompt = "error",         -- blocking input()/confirm()/getchar()/vim.ui.*
    deprecation = "warn",     -- vim.deprecate (--strict makes it fail)
    process_net = "off",      -- spawned processes and network connections
    clock = false,            -- virtual clock and a fixed random seed (opt-in)
  },
  guard_allow = {
    fs = { "~/.local/share/my-plugin" },  -- paths a spec may write to
    spawn = { "git" },                    -- executables a spec may start
    network = { "localhost" },            -- hosts a spec may connect to
  },
}
```

The values are the defaults. Each guard is `"off"`, `"warn"` (a finding in the report, the run stays
green) or `"error"` (the finding fails its case); `--strict` promotes every `warn`. `state = "warn"`
means no category of the state guard fails a case. On the command line:

```
--guard fs=error --guard process-net=warn --guard clock=on
--allow-fs <path> --allow-spawn <exe> --allow-network <host>      (repeatable)
```

Flags win over the file; allow lists add up. An invalid value in `.testing.lua` is reported
(`key 'guards.fs' is invalid ...`) and the default stays.

Where findings show up: the terminal (`guard findings: N warning(s), M failure(s)`, one line each),
JUnit (a warning is the `system-out` of its testcase; a failure is the usual `failure`), GitHub (a
`::warning` annotation and a section of the step summary), and the JSON IR (`case.guards`, a list of
`{ guard, severity, message, id? }` with severity `info`, `warn` or `error`; `info` is listed in the IR
only). The effects ledger (`case.effects`) is filled by the guard layer; without one the cases say
"effects: not collected".

## The warm pool

`pool = { reuse = true }` (`--pool-reuse`) runs the files of an `isolated = "file"` run in embedded
editors that are reset and checked between files instead of one new process per file; how it works and
what it checks is in [CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor). It is **off by
default**, and what it buys is measured here, not assumed. Windows 11, Neovim 0.12.2, 2026-10-06, an
otherwise idle machine, the wall time of the whole run through the command line; the suites are
read-only measurement targets (lsp.nvim 65 spec files / 1523 cases, lib.nvim 87 spec files), and run to
run the times vary by several seconds:

| Run | a child per file | warm pool |
| --- | --- | --- |
| 40 trivial files, `--jobs 1` | 6.0 to 6.4 s | 1.0 s |
| lsp.nvim, `--jobs 1` | 116 to 117 s | 97 to 119 s |
| lsp.nvim, `--jobs 4` | 42 to 43 s (2026-10-06, later run) | 30 to 31 s |
| lib.nvim, `--jobs 1` | 86 to 87 s | 83 to 89 s |
| lib.nvim, `--jobs 4` | 27 to 28 s | 25 to 27 s |

* Starting a child editor costs about 0.15 s here (the 0.3 s of the M0 measurement is not reproduced), so
  the pool pays off only where that is a large share of a file: the 40 trivial files run six times
  faster; a suite whose files take one to two seconds each gains nothing worth naming at `--jobs 1`
  and between 3 % (lib.nvim) and about a third (lsp.nvim) at `--jobs 4`.
* The verdict is the same: lib.nvim gives the same 84 passed, 2 failed, 1 error (the same cases) as a
  child per file, and lsp.nvim 1522 passed and 1 skipped. Getting there needed what the pool checks:
  the first lsp.nvim runs differed in 3 to 10 cases until the member state that a respawned child loses
  with its process was named and put back (see the list in CHILD.md).
* The pool finds leaks a child per file hides, and says so. In lsp.nvim four files leave a running timer
  (`languages_spec`, `recovery_spec`, `supervisor_spec`, `usercmds_impl_spec`; with `--jobs 4` also
  `lua_ls_reload_spec`), in lib.nvim one (`progress_kit_style_spec`): their members are discarded, and
  the finding names the timer. `lsp/integrations_quality_spec` restores its `package.preload` stubs
  from a table that skips nil values, so the stubs stay behind and the next file that requires an
  adapter fails; the state guard names it too (`leaves package.preload["lsp.integrations.nvchad"]`,
  also in a run without isolation). These are findings about those specs, not about the pool; the
  fleet repositories were not changed.
* The fleet run of the M2 review (`--jobs 4`, same suites, respawn against pool, wall time): lsp 42.2 s
  against 30.2 s (-28 %), sandbox 11.4 against 10.0 s, casedesk 24.3 against 22.5 s, ai 6.0 against
  5.3 s, mdview 8.1 against 7.6 s, gitsuite 20.6 against 20.2 s, ui 13.9 against 13.7 s, data 4.3
  against 4.6 s; **my.nvim 4.7 against 6.8 s and spotlight 3.8 against 7.4 s are slower**: 9 of 21 and
  27 of 33 members are discarded (my: an asynchronous `pwsh` per `setup()`; spotlight: `v:vim_did_enter`
  and removed autocmds). Verdicts are identical except where `v:vim_did_enter` is 1 in a member
  (ui.nvim `menu_spec`, spotlight `autocmds_spec`). The first ui.nvim pool run was not green: a tab
  variable (`t:bufs`) with the numbers of wiped buffers, diagnostics of an earlier file and `vim.lsp`
  loaded by the member itself made later files fail; the pool now clears and avoids all three. A pool
  that discards most of its members is slower than a child per file; the finding names why.

## The other keys

| Key | Flag | Default | Meaning |
| --- | --- | --- | --- |
| `pool = { size, reuse }` | `--pool-size n`, `--pool-reuse` / `--no-pool-reuse` | `size = 0` (= `min(jobs, 4)`), `reuse = false` | the warm child pool ([CHILD.md](CHILD.md#the-warm-pool-files-after-each-other-in-one-editor)) |
| `determinism` | `--no-determinism` | `true` | children start with a fixed `LANG`/`LC_ALL` and `TZ` |
| `trace` | `--no-trace` | `true` | a child that times out or crashes leaves a trace artifact |
| `soft_keep` | | `{}` | modules `soft` never unloads |

`testing doctor <root>` prints the effective values.

## For the other layers

* One adapter turns the options into the guard layer's configuration:
  `require("testing.run.options").guard_config(options, { root, seed, in_child })`. The in-process
  driver passes it to `require("testing.guard").install`, the isolated driver puts it in the child job
  as `guard`.
* `require("testing.run.guards")` is the runner's seam: it installs the layer when there is one (no
  module = no guards, silently), opens the window of a case (`begin_case`) and closes it (`end_case`)
  and puts the findings and effects into the IR with `result.add_guard_finding` /
  `result.merge_effects`. For a dialect with one case per file there is one window around the file;
  for busted one per `it`, opened when the dialect asks the selector for the case (the one moment a
  case starts and carries its id).
* The soft isolation's state snapshot is a **backend** (`capture`, `diff`, `restore`). The internal
  one is `testing.isolation.snapshot`; the guard layer replaces it by exporting `soft_backend()` from
  `testing.guard.state`.
