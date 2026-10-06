# For plugin authors: migrating from busted, plenary or a hand-written runner

The point of testing.nvim is that you do **not** rewrite specs. Your existing files stay exactly as
they are; only the way they are started changes. `testing migrate` does that part for you: it reads
your repository, writes down what it would change as a plan, and (only when you say `apply`, and only
in a repository without uncommitted changes) writes it.

What your specs look like decides which dialect runs them ([DIALECTS.md](DIALECTS.md)):

| Your specs | Today | After migrating |
| --- | --- | --- |
| `describe` / `it` with luassert, started by `PlenaryBustedDirectory` or `busted` | needs plenary or busted installed | the `busted` dialect, one Neovim per spec file like plenary, no plenary |
| `return function(H) ... end` on your own `TESTS/harness.lua`, started by a hand-written `TESTS/run.lua` | the hand-written runner | dialect `h`: your harness runs the spec, the runner only collects what it records |
| `return function(H) ... end` with the helpers of lib.nvim / markdown.nvim / images.nvim | a hand-written `TESTS/run.lua` | dialects `a`, `b` or `c` |
| `require("harness")` and `M.run()` | a hand-written `TESTS/run.lua` | dialect `d` |
| a file that runs itself (`nvim -l TESTS/x.lua`, own counters, `os.exit`) | one CI line per file | dialect `script`: one child process per file, exit code and printed `[FAIL]` lines are the verdict |

## The short way

From the root of your plugin, with testing.nvim and lib.nvim checked out next to it (or anywhere the
runner can find them, see [CONFIG.md](CONFIG.md#dependencies)):

```sh
nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua migrate .        # dry run
nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua migrate apply .  # write it
```

or, inside Neovim: `:Testing migrate` (shows the plan in a viewer) and `:Testing migrate apply`.
Read the plan first. It is complete: the new `.testing.lua`, the new `scripts/test.sh`, the new (or
edited) `TESTS/minimal_init.lua`, the deletion of the old init script, and the edit of your CI workflow
as unified diffs, the lines that disappear, the dependencies it found, and a list of **notes** (manual
work) and **risks**.

```
testing migrate [dry-run|apply] [<path>] [--json] [--markdown] [--check] [--fleet-root=<dir>]
```

| | |
| --- | --- |
| `dry-run` (default) | Writes nothing. Prints the plan. |
| `apply` | Writes the plan. Refuses when the working tree has uncommitted changes (tracked or untracked), when `<path>` is not a git repository (it cannot tell), when a file changed after the plan was made, or when a target is a symlink. Nothing is written when anything is refused. |
| `--json` | The plan as JSON (sorted keys, the same plan is the same bytes). |
| `--markdown` | Markdown instead of terminal text. |
| `--check` | Exit code 1 while the plan is not empty: a CI gate "is this repository migrated?". |
| `--fleet-root` | The directory with your other `*.nvim` repositories. It is how `require("ui.kit")` becomes the dependency `ui.nvim`. Default: the parent of `<path>`. |

The commit is yours: `apply` leaves ordinary modifications in the working tree. Review them with
`git diff`, run `scripts/test.sh`, commit.

## What it does, file by file

| File | What happens |
| --- | --- |
| `.testing.lua` | **Created** when absent (an existing one is never touched, it is only compared: the plan lists the keys it does not name). Keys: `plugin`, `roots` (only when the old runner was pointed at another directory), `dialect`, `spec_pattern` (only for scripts without the `_spec` suffix), `deps`, `isolated`, `host`, `env_allow` (the environment variables the specs read that a child editor would not inherit: `REPOS_DIR`, `MAGICK_*` when a spec runs ImageMagick; credential-like names are reported as a risk and never proposed). **`assertions` and `timeouts` are not written**: only a run shows whether a case has no assertion or one is slow, so the plan has a note ("set it when the run asks for it"), see below. The text is formatted with the repository's own `stylua.toml` (see below). |
| `scripts/test.sh` | **Created**, or **replaced** when it starts plenary / the old runner (the diff shows every removed line). It resolves testing.nvim and each dependency in the four places of [CONFIG.md](CONFIG.md#dependencies), exits `1` naming all of them when one is missing, and passes the sentinel line your old runner printed with `--sentinel`. |
| `TESTS/minimal_init.lua` | **Created** when absent: the runtimepath and dependency lookup of the template, followed by what your old `scripts/minimal_init.lua` set up besides the old runner (no swapfile / shada, a fake clipboard, options, extra runtimepath entries, environment variables) as a visible, commented block, formatted with the repository's `stylua.toml`. When it exists and is not the gate yet, it is **replaced** by that same file (four lookup places, a fatal exit when a dependency is missing, `DEPS` = testing.nvim plus the detected dependencies); the old header comments, the old runtimepath statement, the old dependency lookup (`add_dep`, `prepend_env("LIB_NVIM_PATH")`) and every line that names plenary are dropped, and what else it set up (no swapfile / shada, options, ...) is carried over as a commented block. A file that already is the gate is not touched. The result is compiled before it is offered. |
| `scripts/minimal_init.lua` | **Deleted** when it belongs to the old runner (it names plenary, or a workflow / script starts it). The plan shows every line of it as a removal and says per block what happened: header, runtimepath of the repository, dependency lookup and everything that starts or locates plenary are replaced by the new file; the rest is carried over. A reference to it in a workflow is changed to `TESTS/minimal_init.lua`. When `TESTS/minimal_init.lua` exists already, nothing is deleted and a note asks you to merge by hand. An init script that does not mention the old runner and that nothing starts stays. |
| `.github/workflows/*.yml` | Edited **line by line** (comments, key order and every other step are not touched): the old runner call becomes `bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"`; a testing.nvim checkout (and one for every fleet dependency the job lacks) from `ci-verified` is added in the layout your existing checkouts use (`.deps/<name>`, or a sibling), separated by a blank line; the plan first asks GitHub (`git ls-remote --exit-code --heads`, 15 s timeout) whether each dependency has that branch: one that has only `main` is checked out from `main`, with a comment in the step and a plan note (`dependency X has no ci-verified branch: pinned to main`); without network the step keeps `ci-verified` and a note says the check was not possible; an artifact step uploads the JSON when the job fails; the plenary checkout, its `PLENARY*` environment and a `LIB_NVIM_PATH` that points to the sibling `lib.nvim` (`scripts/test.sh` finds it itself) are removed; a job or run-step name that says plenary becomes `tests (...)` / `Run the specs`; `shell: bash` is added to the step on Windows jobs. Job names, matrix and `timeout-minutes` stay. |
| the specs, `TESTS/harness.lua`, `TESTS/run.lua` | **Never touched.** The old runner stays so that you can compare both verdicts; delete `TESTS/run.lua` when they agree. |

Running it a second time produces an empty plan. That is how you know it is done.

### Formatting of the created Lua files

`.testing.lua` and `TESTS/minimal_init.lua` are run through `stylua` with the `stylua.toml` (or
`.stylua.toml`) of the repository, so `stylua --check .` stays green whatever the width (`column_width =
130`) or the indentation (tabs). The call is `stylua --config-path <repo>/stylua.toml --stdin-filepath
<repo>/<file> -` with the repository as working directory; no shell, the text goes in on stdin. Without a
`stylua.toml` nothing is formatted. Without `stylua` on `PATH` (or when it fails) the files stay in the
template's style (width 100, two spaces) and a note names the file and the configured width: run `stylua
<file>` before you commit. The generated files never contain the word "plenary" (case-insensitive).

### Override variable names of the dependencies

The variable that overrides the location of a dependency is derived from its **repository name**
(`testing.deps.env_name`): `color_my_ascii.nvim` is `$COLOR_MY_ASCII_NVIM_DIR`, not
`$COLOR_MY_ASCII_DIR`; `lib.nvim` is `$LIB_NVIM_DIR`. The plan lists the names as a note and points
at every remaining use of an older spelling in the files it knows (workflows, scripts); docs and
scripts of your repository that use another spelling have to be adapted by hand.

### Notes that point at prose

The migration never edits prose. It lists, with line numbers, the lines of `README.md` (and other
top-level `*.md`), `TESTS/*.md`, `docs/*.md`, `.luacheckrc` and `Makefile` that mention plenary (or the
init script that is deleted), as `cleanup hint, <file>` notes: reword what is about running the tests. A
mention of plenary in a comment of a spec file is only counted (with the first positions); specs are
never changed.

### Plenary stays when something else needs it

If a spec or a module of the plugin requires a plenary module other than its test runner
(`plenary.async`, `plenary.path`, ...), plenary is a **dependency**, not just a runner: the checkout step
and the minimal_init lines stay, and `plenary.nvim` is added to `deps` (recorded as "external, not in
fleet"). A plenary module that is only required behind `pcall` keeps the CI checkout but is not a hard
dependency.

## How dependencies are found

Every `require("x")` in `lua/` and `TESTS/` is read from the source with comments and strings left out
(a `require` in a string is not a dependency). A module is mapped, in this order, to: nothing needed
(`vim.*`, LuaJIT, `luassert`), your own plugin, **one repository of your fleet** (the `*.nvim`
directories beside yours that provide the whole module path), a well-known external plugin
(telescope, nui, plenary, neo-tree, ...; shown as "external, not in fleet"), or nothing found.

Not every `require` makes a dependency, because `scripts/test.sh` stops with exit code 1 when a
dependency is missing:

* a **hard** dependency is required at the top of a file in `lua/` (column 0, not behind `pcall`);
* what a fleet dependency itself needs the same way is added (up to three levels);
* a `require` behind `pcall` or inside a function is **optional**: listed in the notes, added to `deps`
  only when your old runner or CI put that repository in place anyway;
* an external plugin is added only when your old CI or minimal_init names it; `telescope.nvim` brings
  `plenary.nvim` with it (telescope does not load without it);
* what the old CI **checks out** decides, never what a comment mentions (`# modelled on ui.nvim's CI`
  is no checkout). A dependency whose name the specs also use with "absent" / "without" in a title is
  kept and listed as a risk: a spec that needs the plugin missing goes red with it on the runtimepath,
  one that simulates the absence (`package.preload`) loses cases without it, so decide by hand;
* a module that two fleet repositories provide is a **risk** (nothing is guessed), a module nobody
  provides is counted in the report.

## What you decide afterwards

* **`assertions = "warn"`, only when the run asks for it.** Under plenary a test with no assertion
  passes. testing.nvim fails such a case by default ("a case without assertions proves nothing"). The
  plan does not set the key (counting the empty cases needs a run); it has a note instead. If the first
  `scripts/test.sh` reports cases without assertions, put `assertions = "warn"` into `.testing.lua`,
  fix the cases, then remove the line again. The same goes for `timeouts = { case_ms = <ms> }`: plenary
  had no limit per case, the default here is 10 s; set it only when a run reports a case that timed out.
* **`isolated`.** Plenary ran one Neovim per spec file. Busted specs get `isolated = "file"` with
  `host = "c"` (the child starts like plenary's host: `vim.v.vim_did_enter` is `0`, `filetype plugin
  indent on` is active). Everything else shares one process like the old hand-written runners.
* **Specs that depend on the host.** `expand("<cfile>")` / `expand("<cword>")` and `vim.v.vim_did_enter`
  behave differently under `nvim -l` (E446 / E348, `1`) than from a `-c` command (what plenary and the
  old `-c luafile` CI lines did). With `isolated = "none"` the runner itself is started with `-l`, so
  such specs need `isolated = "file"` (host `c`); the plan lists them as a risk. Per-file isolation
  shows what a shared process hid: a spec that relies on a `setup()` an earlier spec called (the old
  runner's bootstrap, `require("x").setup({})` before all specs) is red alone. Put the bootstrap into
  `TESTS/minimal_init.lua` (it runs in every child) or fix the spec.
* **`dialect = "h"`** is written for `return function(H)` specs when your repository has its own
  `TESTS/harness.lua`: the fixed shims of the other dialects cannot know your helpers
  (`H.scratch(ft, lines)`, `H.tmpdir()`, a deep-equal `H.eq`). A harness that records failures itself
  (`H.failures`) instead of raising `FAIL ...` is reported as a risk: check the verdict against the old
  runner once.
* **Self-running scripts** get `dialect = "script"` and `host = "l"` (started with `nvim -l`, like the
  old CI line). They are named by anchored patterns of their whole relative path
  (`"^TESTS/smoke%.lua$"`, `spec_pattern`). `TESTS/run.lua` itself (the old runner) is never a spec, but
  a `run.lua` deeper down (`TESTS/refs/run.lua`) is one when a pattern names it.
* **Several runner steps in one job** (one per script): the first becomes the call, a later step that
  did nothing but start the old runner is removed, anything else stays and is reported.
* **A wrapper script** (`scripts/ci.sh tests` that runs `TESTS/run.lua` somewhere inside) cannot be
  followed; the plan says which call to change by hand.
* **Repositories that are not yours.** A clone whose `origin` belongs to another owner is skipped.

## Doing it by hand

The plan is the whole procedure, so there is nothing hidden in the command. Without it:

1. **Check out testing.nvim and lib.nvim** where the runner can find them (`$LIB_NVIM_DIR`,
   `.deps/lib.nvim`, a sibling directory, or `stdpath("data")/lazy/lib.nvim`). In CI, check both out into
   `.deps/` from `ci-verified`.
2. **Run it as it is**, nothing in your repository changes:

   ```sh
   nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua .
   ```

   Add `--list` first to see which spec file runs in which dialect, and why a file is `unknown`.
3. **Read what it tells you.** A run reports problems with where specs live (legacy `tests/`
   directories, busted specs under `lua/`), files whose dialect it cannot decide, and luassert features
   the busted dialect does not have (`spy`, `stub`, `mock`, `insulate`, ...). Those fail loudly with a
   message that names the feature; that is intended. A failed assertion no longer aborts the test body,
   so you see every failure of a test at once.
4. **Add a `.testing.lua`** only if the defaults do not fit ([CONFIG.md](CONFIG.md)).
5. **Switch your entry points**: `scripts/test.sh` of this repository is a template. Use `--json` and
   `--junit` in CI and upload them as artifacts when the job fails
   ([OUTPUT-FORMATS.md](OUTPUT-FORMATS.md)).
6. **Remove the old runner** once both give the same verdict. If a script reads the sentinel line the
   old runner printed, keep the name with `--sentinel`.

## What is the same

* File discovery (`*_spec.lua`), `describe` / `it` order of execution, hook order, `pending`.
* The exit code: `0` only when everything passed ([EXIT-CODES.md](EXIT-CODES.md)).

## What is different on purpose

* No spec can end the run: `os.exit` inside a spec is an error of that file, and quitting the editor is
  exit code `3`.
* A case that asserts nothing (unless `assertions = "warn"`), a file that registers no case, and a file
  whose dialect is unknown are failures, never passes.
* Unsupported busted/luassert features raise instead of silently doing nothing.
* A filtered run (`--file`) never prints the "all green" sentinel.

## For tools: the Lua API

```lua
local migrate = require("testing.migrate")
local report = migrate.analyze(root, { fleet_root = parent })  -- read-only facts, plain data
local plan   = migrate.plan(report)                            -- plan.ops: { path, action, diff, removed, after, ... }
print(migrate.render(plan, { format = "text" }))               -- or "markdown"
print(migrate.to_json(plan))
local result = migrate.apply(plan, { apply = true })           -- result.applied / result.errors; never raises
```

`plan.empty` is `true` for a migrated repository; `plan.skipped` / `plan.error` explain why there is no
plan. Every string from the repository is escaped (`\xNN`) before it is shown, so a hostile file name or
workflow line cannot reach your terminal as an escape sequence.
