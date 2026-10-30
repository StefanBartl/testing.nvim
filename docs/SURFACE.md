# Surface and binding coverage

`testing.surface` answers two questions about a plugin, with numbers instead of opinions:

1. **What does the plugin offer its user?** The *surface*: keymaps, user commands (with the routes of
   composer verbs), autocmds, the health check, the public Lua API and the typed config keys, each as an
   *entry* with a stable id and a source `file:line`. It is read from the registries of lib.nvim and from
   the live editor, **not** from the documentation (the documentation is generated from the same
   registries; reading it back would measure the generator).
2. **How much of it did the specs exercise?** *Coverage*: while the specs run, the handlers are counted
   (a keymap that fired, a command that ran, an autocmd that was triggered). The result is a ratio per
   kind and per spec file, a threshold that can be a gate, and a baseline that catches a regression.

Everything reports first. A threshold of `0` (the default) never fails; it becomes a CI gate per
repository after the findings are triaged.

```
testing surface [<root>] [--from ir.json] [--hits sink.jsonl] [--threshold 0.8] [--baseline b.json] [--json|--markdown] [--matrix] [--csv] [--no-tags]
:Testing surface [<root>] [--from=<ir.json>] [--threshold=<n>] [--markdown] [--matrix] [--csv] [--no-tags]   (a headless child; the report opens in a viewer)
```

## Quick start

```lua
-- .testing.lua
return {
  plugin = "sessions",
  setup = { keymaps = { save = "<leader>ss" }, marks = { enable = true } },  -- the setup() the surface is read with
  coverage = { bindings = 0, commands = 0 },     -- 0 = only report, 1.0 = gate
  surface = { track = true, threshold = 0.0 },   -- track: the runner counts what the specs exercise
}
```

```bash
testing . --json out.json          # a tracked run: every case carries `surface = { hit = { ids... } }`
testing surface . --from out.json  # the table, the ratio, the missing entries
testing surface . --from out.json --threshold 0.8                     # exit 1 below 80 %
testing surface . --from out.json --write-baseline surface.baseline.json
testing surface . --from out.json --baseline surface.baseline.json    # exit 1 when something that was exercised is not now
```

Without a tracked run `testing surface` lists the entries and says that nothing is measured. It never
calls an entry "missing" without a measurement.

## Ids

An id is `kind:name`, stable across runs and machines:

| Id | What |
| --- | --- |
| `binding:<lhs>` | a keymap in normal mode, `binding:<lhs>@x` / `@nx` for other modes (sorted letters) |
| `command:<Name>` | a user command |
| `command:<Verb> <path>` | a route of a composer verb, `command:Session save`; the bare `command:Verb` only when the verb has a `default` handler or a root route |
| `autocmd:<group>:<events>[:<pattern>][#n]` | an autocmd; group `-` when none, `:buf` when buffer-local, `#2`, `#3` number equal ids in creation order |
| `api:<module>.<name>` | a function of the public module |
| `config:<dotted.key>` | a key of the typed DEFAULTS |
| `health:<plugin>` | `lua/<plugin>/health.lua` exists |
| `action:<plugin>.<name>` | **alias** of a registered keymap action (not an entry, see below) |

The lhs of a keymap is only its *current default*: a spec may bind other keys. For an action registered
through `lib.nvim.bindings.keymap.register` the entry therefore carries the alias
`action:<registry key>.<action>`, and a hit is recorded under the id of the lhs **and** under the alias.
A spec that binds `<leader>x` instead of `<leader>ss` still covers the entry. A plain `vim.keymap.set`
has no action name; its identity is the lhs.

## What is read (and from where)

`testing.surface.read` runs in the editor after the plugin's `setup()`; `testing.surface.collect` does
exactly that in a **child editor** (`testing.rpc`, sandbox, guards on), with the minit, the dependencies
and the `setup` options of `.testing.lua`. The child gets the same environment as a test run: every
dependency of `deps` as `$<NAME>_DIR`, `REPOS_DIR` and the names of `env_allow`, so a minit that finds a
dependency through its variable works here too. The runner's own editor never loads the plugin.

| Kind | Source | Details |
| --- | --- | --- |
| `binding` | `keymap.registered()` (registered actions and plain `keymap.set()`), plus live keymaps whose Lua callback is defined below the project root | `lhs`, `modes`, `action`, `buffer`, `untrackable` (a string rhs) |
| `command` | `usercmd.registered()`, plus live Lua commands defined below the root, plus the routes of `composer.registry()` | the verb itself is no entry (its routes are) |
| `autocmd` | `autocmd.registered()`, plus live Lua autocmds defined below the root | `events`, `group`, `pattern`, `once` |
| `api` | function fields of `require(<plugin>)` not starting with `_` | tracked (when asked), not part of the default ratio |
| `config` | `<plugin>.config.DEFAULTS` (also `.DEFAULTS`, `.config.defaults`, `.defaults`, `.config`) | flattened up to depth 3, `type` of each key; listed, not measurable |
| `health` | `lua/<plugin>/health.lua` | listed, not measurable |

"Of the plugin" means: the registry key is the plugin (or `<plugin>/<surface>` or the repository
directory name), or it appeared in the registry while the plugin was set up (a plugin may file its
actions under another name, sessions.nvim files them under `Session`), or the call site / the handler
function lies below the project root.

**The surface depends on the `setup` options.** An opt-in keymap that the default `setup()` does not bind
is not in the surface. Put the options that switch every optional part on into `.testing.lua`
`setup` (that is also what the conformance suite calls `setup()` with).

## Tracking

`testing.surface.track` is an installable layer in the style of `testing.guard`:

```lua
local track = require("testing.surface.track")
local h = track.install({ api = { "myplugin" }, sink = "/path/sink.jsonl" })   -- BEFORE the plugin's setup()
h:begin_case({ id = "a_spec.lua::case", file = "a_spec.lua" })
-- ... the spec runs ...
local res = h:end_case()        -- { hit = { ids... }, counts = { [id] = n } }
local run = h:collect()         -- { hit, counts, wrapped, cases, notes } since install
h:flush(file)                   -- a `run` line into the sink
local left = h:uninstall()      -- what could not be put back
```

How: handlers are wrapped when they are **created**. The layer patches the creation primitives
(`nvim_set_keymap`, `nvim_buf_set_keymap`, `nvim_create_user_command`, `nvim_buf_create_user_command`,
`nvim_create_autocmd`) and the composer registry of lib.nvim (the `run` of every route, the `default` of a
verb). `vim.keymap.set`, `lib.nvim.bindings.*` and a plugin's own wrappers all end in those primitives,
so one layer sees them all. Keymaps that exist at install time are re-set with a wrapped callback (same
options). A wrapper counts and returns what the original returns: arguments, `expr` mappings and the
`true` of a self-deleting autocmd stay intact; after `uninstall` it does nothing.

Restore: `uninstall()` puts the primitives back, the original callback of every keymap and command whose
live definition is still our wrapper, and the composer routes. An autocmd callback cannot be swapped in
place without changing the autocmd's id and order, so a wrapped autocmd keeps its (then inert) wrapper.

**Install order.** Install the layer *before* the guards and before the plugin's `setup()`: the guards
then wrap on top of it and are uninstalled first (LIFO), and everything the plugin creates is seen.
`track.hook_runner(opts)` is the connection for a project's minit until the runner owns it: it installs
the layer, hooks the runner's case windows (`testing.run.guards` `Session:open` / `Session:close`), and
flushes a `run` line when the editor ends (also at `os.exit` of a self-running script).

```lua
-- TESTS/minimal_init.lua of the project
vim.opt.rtp:prepend(root)
require("testing.surface.track").hook_runner({ api = { "myplugin" }, sink = vim.env.SURFACE_SINK })
```

The sink is written through the `io.open` of the time the module loaded, so the fs guard never sees it
(load the module from the minit, ahead of the guards).

### Output of a tracked run

* the **sink**: JSON lines. `{"k":"case","id","file","hit":[...],"counts":{...}}` per case,
  `{"k":"run","file"?,"hit","counts","wrapped":[...],"existing":{"commands","autocmds"}}` per editor.
* the **Result-IR** (the runner writes it when `surface.track = true`): `cases[].surface = { hit = { ids... } }`
  and `surface = { plugin, total, hit, ratio, missing, untracked, kinds, files, exact? }` at the top.
  `testing.surface.annotate_ir(ir, report)` writes the aggregate.

## Coverage

Statuses of an entry:

| Status | Meaning | In the ratio |
| --- | --- | --- |
| `hit` | exercised by at least one case | yes |
| `missing` | observable and never exercised | yes |
| `untracked` | cannot be observed: a string rhs / string command, or a handler that existed before the layer was installed | no |
| `ignored` | matches an `--ignore` pattern | no |
| `listed` | a kind that cannot be observed (`config`, `health`) | no |

`ratio = hit / (hit + missing)` over the kinds asked for (default `binding`, `command`, `autocmd`;
`--kind` changes them). A handler that **no run ever wrapped** is `missing` when every run reported that
nothing existed before its layer was installed (`exact`), because then it was never created; otherwise
it is `untracked`, because it may be one of the handlers the layer could not wrap. Per spec file the
report gives how much of the whole surface that file's cases exercised.

### Thresholds, exit codes, baseline

| Source | Meaning |
| --- | --- |
| `.testing.lua` `coverage.bindings` / `coverage.commands` (`autocmds` too) | threshold for that kind, `0` = only report |
| `.testing.lua` `surface.threshold` | threshold of the overall ratio |
| `--threshold 0.8` / `--threshold binding=1` | the command line wins |

Exit code: `0` done, `1` a threshold or the baseline failed, `2` usage or configuration error (also: a
threshold or a baseline without a tracked run), `3` the surface could not be read.

A threshold is a claim about a measurement, so **no measurement is a failure, not a pass**: when every entry of
the scope is `untracked` (the tracking was installed too late, or the dialect is not tracked), or the surface
holds no entry at all, the ratio does not exist and the threshold fails with `not measurable: ...`. Only a kind the
plugin does not have (no entry of it, tracked or not) passes. A threshold that is not a number between 0 and 1
(`NaN` would pass every comparison, `7` can never be met) is ignored with a note.

An IR of a run that was **not tracked** (no `cases[].surface` anywhere) measured nothing: every entry is
`untracked`, none is `missing`, and the run says so.

`--write-baseline FILE` writes the status of every counted entry (only when nothing failed).
`--baseline FILE` fails when an entry that was `hit` in the baseline is not now (a regression), and with
`--fail-on-new` also when a new entry is not exercised, and with `--fail-on-removed` also when an entry that was
exercised is gone from the surface (without it a vanished entry is only listed: renaming a command is not a
regression, deleting its only test coverage by deleting the command may be). A baseline carries a `digest` of its
entries: a run that finds the entries edited since (by hand, or by another tool: the bar then is whatever the file
says) names that in a note, and so does a baseline without a digest (written by an older version). New exercised entries and entries that are exercised now are listed as well.

The digest is a hint, not a seal: it is stored next to the entries it covers, so whoever can edit the entries can
recompute it. What `--require-signed-baseline` enforces is that the file is what a run wrote: with it, a baseline
whose entries do not match its digest (`edited`) or that has no digest (`unsigned`) fails the run (exit `1`, the
note names which of the two). It needs `--baseline` (without one the run is a usage error, exit `2`). It is for
gates that must not pass because someone lowered the bar by hand; to accept an intended change, rewrite the file
with `--write-baseline` from a green run and review the diff.

Output: a text table (default), `--markdown`, `--json`; `--out FILE` also writes it (atomically, like the
baseline: a crash leaves the old file or the new one, never half of it). Text from the plugin
(names, descriptions, paths) is scrubbed of control characters and bidi overrides.

## Tags: a case names the entry it tests

Besides the tracker, a case can claim an entry. A claim counts as a hit, is marked `hit (tag)` in the
table, is listed in `ir.surface.tagged`, and is noted in the report: a tag is a statement, not a measured
execution. Only a **passing** case claims; a failed or skipped case covers nothing.

| Where | How |
| --- | --- |
| Result-IR | a string in `cases[].tags` that is an id (`binding:<leader>ssa`, `command:Session save`); other tags such as `slow` are ignored |
| Dialect A (busted-style) | a header comment in the first 30 lines of the spec, which claims for every case of the file: `-- @covers binding:<leader>ssa, command:Session save` (`@covers:` and `@Covers` work too; a UTF-8 byte order mark in front of line 1 is skipped; `#tag` words of titles cannot hold `<`, `>` or a space) |

A claim on an id that is not in the surface is a stale tag and is listed under "exercised but not in the
surface". A claim spelled another way than the entry (`binding:<Leader>a` for `binding:<leader>a`, another mode
suffix of the same keys) counts for that entry, in the table and in the matrix. `--no-tags` (or
`surface = { tags = false }`) turns the claims off, so the ratio is the tracked one only; an IR without `cases[].surface` still takes the
claims (they are static), while the rest stays `untracked`.

Limits of the claims:

* The ids of a `-- @covers` line are separated by `,` or `;` **only when a kind follows** (`binding:`, `command:`,
  `autocmd:`, `api:`, `config:`, `health:`), so a name may hold the separators: `-- @covers binding:;, command:Open`
  claims `binding:;` and `command:Open`. The price: a `,` or `;` at the very end of the list belongs to the last
  id (`binding:<leader>,` is that keymap; a trailing comma after `command:Open` makes the id `command:Open,`,
  which is listed as a stale tag), and a misspelled kind (`bindin:a`) does not end the id before it.
* A header is read only from a file below the project root. The path of the case must be relative and free of a
  `..` segment, a drive or a leading slash, and the file is resolved before it is opened: a symbolic link or a
  junction that leads out of the root (also on an intermediate directory) claims nothing. A file name that merely
  contains two dots (`a..b_spec.lua`) is fine.
* Only a case whose status is `pass` claims; a case without a status has not been seen to pass.
* At most 256 tags per case are read (the rest is ignored, with a note).
* A malformed `surface.*` value in `.testing.lua` (`tags = "no"`) is reported as a `config:` note and the default stays.

## The matrix and the report sections

```bash
testing surface . --from out.json                    # the list; "not covered" names each entry: `binding:<leader>slt - no feature test`
testing surface . --from out.json --matrix           # entries x spec files, cases that exercised the entry per file
testing surface . --from out.json --matrix --csv     # the same as a tab separated table (tabs and line breaks in a cell become `?`)
testing surface . --from out.json --matrix --json    # `matrix = { files, rows = { { id, kind, status, cells, total } } }` and `table = { header, rows, files, src }`
testing surface . --from out.json --write-ir annotated.json   # the IR with the aggregate as its own `surface` section
```

`--matrix` needs a tracked run (`--from` or `--hits`): without one it prints why and exits `2`, like `--write-ir`
without `--from`. An entry no case exercised has `cells = {}` in the JSON. The `table` section of the JSON holds
the cells of `--matrix --csv` (`render.matrix_rows`) plus, per file column, the spec file as the IR named it
(`files`) and, per row, the `src` of the entry (`""` when it has none). The `surface` section of the IR holds the
totals, the ratio per kind and per spec file, `missing`, `untracked` and `tagged`.

### The matrix view (`:Testing surface --matrix`)

`:Testing surface --from=out.json --matrix` asks the child for `--matrix --json` and shows its `table` in a
lib.nvim ui.kit viewer (`testing.surface.view`): one line per entry, one column per spec file. The view shows the
cells as the child wrote them; it recomputes nothing. With `--csv` or `--markdown` the text goes to the output viewer
as before; without a tracked run the reason is shown instead of a view.

| Key | Does |
| --- | --- |
| `<CR>` | On a spec file column: open that spec file. Anywhere else on a row: open the `src` of the entry at its line (an entry whose source is a module or unknown says so, the view stays). |
| `s` | Status filter, round: all, hit (a `hit (tag)` row is a hit), missing, untracked, ignored (`--ignore`). |
| `t` | Kind filter, round: all, binding, command, autocmd. |
| `e` | Export the shown rows (with the filters) as a tab separated file, the format of `--matrix --csv`; asks for the path (default `<root>/surface-matrix.csv`; `~` and `$VAR` are expanded, a relative path is below the root). |
| `?` | The cheatsheet. `q` / `<Esc>` close. |

The keys are buffer-local to the view and come from `surface_view.keys` of `setup()` (`false` leaves one out,
[CONFIG.md](CONFIG.md)); the winbar legend, the `?` cheatsheet and the keymaps are built from that one list.

## Gating a repository by baseline

A percentage is a claim most plugins of a fleet cannot meet yet (keymaps are rarely pressed by specs). A baseline gate
asks less and holds more: what the specs exercise today must stay exercised.

1. `.testing.lua`: `surface = { track = true }` (the runner counts what the specs exercise).
2. `scripts/test.sh surface ...` (the `test.sh` of `testing init` has the subcommand; older copies need the same
   four lines as the `conformance` branch).
3. Let CI write the IR of one Linux run (`scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"`) and upload it
   (`actions/upload-artifact`, name `surface-ir`). Write the baseline **from that artifact**, not from your machine: a
   spec that behaves differently on the runner (a missing tool, another OS) would turn an entry into a false
   regression: `scripts/test.sh surface --from <downloaded ir> --write-baseline surface.baseline.json`; commit it.
4. CI step on that one Linux leg: `bash scripts/test.sh surface --from "$RUNNER_TEMP/testing-ir.json" --baseline
   surface.baseline.json --require-signed-baseline`. A regression is exit 1, a baseline edited by hand is exit 1.
5. To accept an intended change (a command removed, a spec dropped on purpose), rewrite the file from a green Linux run
   and review the diff.

Pilot: fileops.nvim (`surface.baseline.json`, the "Surface baseline gate" step of its `ci.yml`).

## Honest limits

* **Aliases.** A handler is counted when the *wrapper* runs. A keymap that holds its own reference to a
  function (`rhs = M.open`) does not count as a call of `api:myplugin.open`; a command that calls
  `M.open()` through the module does. API tracking wraps the function fields of the loaded module at
  every `begin_case`; call sites that saved the original earlier are not seen.
* **String handlers.** A keymap with a string rhs (`"<cmd>Session save<cr>"`) and a command given as a
  string cannot be wrapped: they are listed and `untracked`. The command a string rhs runs is observed
  on its own, the keymap is not.
* **Created later.** Buffer-local keymaps and autocmds a plugin creates on `FileType` or on first use
  exist only once a spec triggers them; the surface read after `setup()` does not list them, and a
  handler created before the layer was installed cannot be wrapped (commands and autocmds are not
  recreated; keymaps are re-set).
* **Composer verbs.** Routes are tracked through the `run` of the route table; a verb that is
  dispatched by something that bypasses the registered handler (`handle:dispatch`) is not seen. The verb
  itself is not an entry.
* **Autocmd ids** number equal group/event/pattern combinations in creation order; clearing an augroup
  between two registrations shifts the numbers.
* **Ownership.** Everything created while a spec runs is counted; only what is in the surface is
  reported (hits on ids that are not in the surface are listed as "exercised but not in the surface").
  A handler defined in another module (a shared wrapper) is attributed to that module, not to the plugin.
* **Nets, not a sandbox.** Like the guards, the layer is a monkeypatch; Lua can bypass it.
* **The surface is a function of `setup`.** Opt-in surface that the configured `setup()` does not switch
  on is not listed (and therefore not demanded).

## Modules

| Module | Purpose |
| --- | --- |
| `testing.surface` | `main(argv, services) -> code, text`, `report(root, opts)`, `collect`, `read`, `hits`, `coverage`, `annotate_ir`, `parse_args` |
| `testing.surface.ids` | id construction and parsing |
| `testing.surface.read` | the registries -> entries, in this editor |
| `testing.surface.collect` | the same in a child editor |
| `testing.surface.track` | the tracking layer: `install`, `hook_runner`, `unwrap` |
| `testing.surface.coverage` | pure: `compute`, `by_file`, `thresholds`, `check`, `baseline`, `diff`, `matrix`, `from_ir`, `from_sink`, `annotate_ir` |
| `testing.surface.tags` | `is_id`, `ids_of_tags`, `parse_covers`, `file_covers`, `apply`: the claims of passing cases (tags, `-- @covers`) |
| `testing.surface.render` | text, markdown, JSON, `matrix_rows`, `tsv` |
| `testing.surface.view` | the matrix view of `:Testing surface --matrix`: `parse`, `filter`, `lines`, `cell_at`, `target`, `export_text`, `export_path` (pure), `open`, `show_verdict` |

## Integration: what is wired and what is not

Wired by the integration step (`testing run` with `surface = { track = true }` in `.testing.lua`):

* `.testing.lua`: `surface.{track, threshold, kinds, ignore, tags, setup_chunk}` and `coverage.autocmds` are typed keys
  ([CONFIG.md](CONFIG.md)).
* `testing surface ...` is dispatched by `testing.cli` with its own arguments and exit codes (`:Testing surface` in
  the editor).
* **Tracking in the runner.** The layer is installed before the project's `minit` (so before a `setup()` it calls):
  in this editor by `testing.run.project`, in a child editor by `testing.child.boot` (the job's `guard.surface`),
  and it follows the runner's case windows (`testing.run.guards` `Session:open` / `Session:close`). The hits of
  a window are put into the case (`testing.run.guards.attach_surface`): `cases[].surface = { hit = { ids... } }`,
  in the IR a `--json` run writes. `testing surface --from ir.json` joins it with the surface read from the plugin.
  A project's minit no longer calls `track.hook_runner`: the runner owns the layer now, and a minit that still
  calls it would install it a second time (use `hook_runner` only for a run that is not started by `testing run`,
  or when you want the JSON-lines `sink`).
* `:checkhealth testing` reports that the tracking layer loads.

Not wired, said plainly:

* **The warm pool** (`--pool-reuse`) does not track: a pool member lives across files and the layer would stack. The
  run says so on stderr and no case carries `surface`.
* The top-level `ir.surface` aggregate (`total`, `ratio`, `missing`, `exact`) is not written by the runner;
  `testing surface --from` computes all of it. Without `exact`, a handler no run wrapped is `untracked`, never
  claimed `missing`.
* **What a hit means.** A hit counts when the handler the PLUGIN registered ran: a handler that was defined in a
  spec file (`_spec.lua`, or below `TESTS/`, `tests/`, `spec/`) is not wrapped, so a spec that replaces `<leader>a`
  with its own function does not make the key look exercised. An `api:` entry counts a call from anywhere, also
  from another function of the same module: an upper bound, not proof that a spec called it. Autocommands are one
  id per event; the group keeps its name when it is emptied later; the pattern `*` is no pattern.
* No threshold fails `testing run`; `testing surface` is the gate (`--threshold`, `coverage.*`, `--baseline`).

## The contract the integration followed (kept for the record)

What is needed so that the pieces above are wired into the runner. Everything here is a request to the
owner of the named file; `testing.surface` exposes the API.

1. **`.testing.lua` schema** (`config/project.lua`, `config/DEFAULTS.lua`):
   `surface = { track = false, threshold = 0.0, kinds = { "binding", "command", "autocmd" }, ignore = {}, tags = true, setup_chunk = nil }`
   with `track` and `tags` boolean, `threshold` number in 0..1, `kinds` and `ignore` string lists (`ignore` are Lua
   patterns on ids), `setup_chunk` a string. `coverage` may additionally take `autocmds` (number 0..1).
2. **CLI** (`cli.lua`): `testing surface <args>` is dispatched before the run options are parsed, like
   `migrate`: `local code, text = require("testing.surface").main(rest, { cwd = vim.fn.getcwd() })`, text to
   stdout (stderr for code 2), the code is the exit code.
3. **`:Testing surface`** (`bindings/usrcmds.lua`): the same call, the text in the viewer; `--matrix` alone adds
   `--json` and hands the verdict to `testing.surface.view.show_verdict`.
4. **Tracking in the runner** (`child/boot.lua`, `child/rpc_init.lua`, `run/guards.lua`, `run/inproc.lua`):
   with `surface.track` the job carries `surface = { api = { plugin } }`;
   the child installs `track.install(job.surface)` before the minit; `Session:open` calls
   `h:begin_case(ctx)` and `Session:close` calls `h:end_case()`, whose result goes into the IR case as
   `case.surface = { hit = res.hit }` (an optional field; `core/result.lua` ignores it today and the
   validator accepts it); at the end of the file the child adds `h:collect()` (`wrapped`, `notes`,
   `existing`) to the `done` record. The parent builds `ir.surface` with
   `require("testing.surface").annotate_ir(ir, report)` (`exact = true` when every child reported
   `existing` as zero). The layer must be installed first and uninstalled last (LIFO with the guards).
5. **`:checkhealth testing`** (`health.lua`): one line "surface: tracking available" when
   `testing.surface.track` loads.
6. **README / `doc/testing.txt` / `docs/CLI.md`**: the `surface` subcommand and the link to this page.
