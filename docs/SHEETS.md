# Test sheets (`testing.sheet`)

A live check is a check somebody does by hand: open a dialog, look at it, press a key. A **test sheet**
writes the same check down as data, so that the part a machine can do runs with the suite (through the
RPC klicker, [CHILD.md](CHILD.md)) and only the judgement is left for a person. `testing sheets report`
turns the sheets and their last result into the checklist a person works through.

## A sheet

`TESTS/sheets/<name>.sheet.lua` returns a table:

```lua
return {
  id = "ui.option-float",                -- stable; the spec case is called `sheet:<id>`
  title = ":UI option float",
  task = "ui.nvim/try-the-ui-option-float-in-a-real-session",   -- optional: where the check comes from
  engine = "rpc",                        -- "rpc" (default) or "manual"
  minit = "TESTS/minimal_init.lua",      -- default; relative to the project root
  sizes = { { rows = 24, cols = 80 } },  -- one run per size (default 24x80)
  steps = {
    { lua = 'require("ui").setup({ usrcmds = true })' },
    { keys = ":UI<CR>", note = "open the float" },
    { wait = "vim.api.nvim_win_get_config(0).relative ~= ''" },
    { screen = "float", masks = { { row = 24 } } },
    { keys = "q" },
    { expect = "vim.api.nvim_win_get_config(0).relative == ''", note = "the float is gone" },
  },
  judge = { "the rows and texts read well" },        -- criteria for a person (later an AI reviewer)
  manual = { "the cheatsheet key <M-h> of the real config opens it" },  -- steps only a person can do
}
```

| Step | Does | Fails when |
|---|---|---|
| `keys = s` | typed through `child.feed` (mappings apply, returns when the typeahead is empty) | the keys left an error message (`v:errmsg`, e.g. `E492`); `ignore_errmsg = true` for keys that run `silent! cmd` on purpose (it still sets `v:errmsg`) |
| `input = s` | queued through `child.input` (returns at once); the way into insert mode (`input = "A"`, then a `wait` for the mode): `keys` feeds with `x`, which ends insert mode again | never |
| `lua = s` | runs in the child | it raises |
| `settle = ms` | waits until the child is idle | it is not idle in time |
| `wait = expr` (`timeout` ms, default 2000) | polls a Lua expression in the child | it is not truthy in time |
| `expect = expr` | evaluates a Lua expression in the child now | it is not truthy |
| `screen = name` (`masks`, `cursor`, `mode`) | compares the screen with a snapshot ([CHILD.md](CHILD.md#screen-snapshots-testingscreen)); the name gets the size: `float.80x24` | the snapshot differs (or is missing on CI) |

Milliseconds are whole numbers up to 600000 (10 minutes), sizes up to 1000 rows or columns: an endless wait
is a mistake, not a check. Every step may carry a `note`; a failure names the size, the step number and the
note, and all failures of a sheet are one line. The first failed
step ends that size (the steps after it depend on it). The UI is attached before the first step, so windows
and floats are laid out for the sheet's size.

The file is read as **data**: `load` with an empty environment, so a sheet cannot call anything while it is
read (a sheet that touches `os` does not load). What runs is the Lua of its steps, inside the child editor.
`load` checks the shape and names the field of a mistake (`steps[3] has two actions (keys and lua)`).

## A sheet from a task (`testing sheets new`)

```
testing sheets new --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--tasks-cli <tasks.lua>] [--name <file>]
```

reads the live-check task through tasks.nvim (`call task`) and writes a **draft** `TESTS/sheets/<slug>.sheet.lua`
into the repository (default the current directory):

* `id` is the task's slug, `title` its title, `task` the id given; strings are quoted as Lua strings, so any title
  loads.
* `steps` is a skeleton that runs as it is: the intro screen off (it names the Neovim version), a setup step to
  fill in, `settle`, one `screen`. It checks nothing yet: write what a person would do.
* `judge` has one entry per checkbox under `## Akzeptanz` / `## Acceptance` (ticked or not, at most 30; boxes in a
  fenced code block or another section do not count). A task without boxes gets one entry from its title.
* `notes` and the header comment say `DRAFT`: drop them once the steps are real and the snapshot is reviewed.

An existing sheet is **never overwritten** (exit 2; `--name` writes another file). The written file is loaded
right away; a draft that does not load is removed again. The vault is `--vault`, else `$TASKS_VAULT`, else
`<repo>/../tasks-vault`; the engine is found as for `--tasks` below. Exit codes: 0 written, 2 bad usage or the
sheet exists, 3 the task could not be read or the file not written.

## Running sheets

Each sheet is one case of an ordinary spec, named `sheet:<id>`; the report finds its last result by that
name in `testing.state`. A busted style spec:

```lua
-- @cache-inputs TESTS/sheets/ TESTS/__snapshots__/
local sheet = require("testing.sheet")
local root = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

describe("test sheets", function()
  for _, path in ipairs(sheet.files(root .. "/TESTS/sheets")) do
    local s, err = sheet.load(path)
    it(s and sheet.spec_name(s) or path, function()
      assert(s, err)
      sheet.check(s, { root = root })
    end)
  end
end)
```

`sheet.expect(H.ok, s, opts)` hands the verdict to a collecting harness instead of raising; `sheet.run(s, opts)`
returns `{ ok, status, failures, snapshots }`. A project whose process guard is strict lists `nvim` in
`guard_allow.spawn` (the sheet starts a child editor). A `manual` sheet runs nothing (status `manual`).

## The report

```
testing sheets report [<root>...] [--from <ir.json>]... [--out <file>]
```

reads the sheets of every root (default the current directory) and the last results, and writes one
Markdown list (stdout without `--out`). The last results come from the editor's state (`testing.state`,
written by `testing run` and `:Testing`) or, with `--from`, from the Result-IR of a run
(`testing run --json <file>`). `scripts/test.sh` runs with a throwaway app name and stdpath, so its
results never reach the state: run it with `--json <file>` and pass that file. An IR says nothing about
staleness (it is one run); several `--from` files are merged by case name.

| Section | What is in it |
|---|---|
| Red, stale or not run | the case failed, its spec file, the sheet or one of its snapshots changed since it ran, it never ran, or the sheet does not load |
| Review inbox | the automated part is green and the sheet has `judge` criteria: the criteria as checkboxes and the snapshot files to look at |
| Manual | the `manual` steps (of a manual sheet, or of a green sheet without `judge`) |
| Automated | green, nothing left for a person |

Text from a sheet or a result is written on one line (a newline in a title cannot start a heading or a
checkbox), and a backtick cannot end an inline code span. Nothing is run by the report: run the suite first. Exit codes: 0 written or printed, 2 bad usage, 3 the
file could not be written.

## Into the tasks (`--tasks <vault>`)

A sheet names its live-check task (`task = "ui.nvim/..."`). With `--tasks <vault>` the report also writes the state
of every sheet into that task, as a generated block in front of `## Notizen` / `## Notes` (or at the end):

```
<!-- testing:sheets:begin -->
## Test sheets

_Generated by `testing sheets report --tasks`; edit the sheet, not this block (ticked boxes are kept)._

- **:UI option float** (`ui.option-float`, `ui.nvim/TESTS/sheets/ui-option-float.sheet.lua`): automated part green, waiting for your judgement
  - Judge:
    - [ ] The rows and texts of the float read well
  - By hand:
    - [ ] In the real config the cheatsheet key <M-h> opens the same float
  - Look at: `ui.nvim/TESTS/__snapshots__/sheets/ui-option-float.sheet/float.80x24.snap`
<!-- testing:sheets:end -->
```

* A second run replaces the block; a box ticked in the task (by hand, or by an app) stays ticked. The block has no
  date, so a task only changes when the state of its sheets does, and its paths always name the project, whatever
  roots the report was given.
* Only a marker on a line of its own and outside a fenced code block counts (one quoted in prose or code is text),
  and so does only a notes heading outside a fence. A task whose markers are broken (a begin without its end, an end
  in front of the begin, two of them) is **not written**: it is reported (exit 1) and fixed by hand, so no text
  between stray markers is ever replaced. A task file with CRLF line endings is sent back with line feeds (the
  engine keeps the file's own ending).
* Reading and writing go through the engine of tasks.nvim, never into the files: `call bodies` for every task named
  (asked again for the ids a 2 MiB page did not reach), `call ops` with a `set_body` per changed task and `if_match` =
  the version read, in requests of at most 100 operations and about 200 KiB. A task edited in between is a
  `conflict` (reported, exit 1), not overwritten.
* A task that is not open (finished or unknown) is reported (`task <id> missing`) and the list says so under the
  sheet. A sheet without `task` is left out.
* The engine is found like a dependency: `$TASKS_NVIM_DIR`, `<vault>/.deps/tasks.nvim`, `<vault>/../tasks.nvim`,
  `stdpath('data')/lazy/tasks.nvim`; `--tasks-cli <path/to/scripts/tasks.lua>` names it. `--dry-run` says what would
  change and writes nothing.

```
testing sheets report <root>... --from <ir.json>... --tasks <vault> [--dry-run]
```

Exit codes: 0 done, 1 a task could not be written (conflict, refused, a body too long to send back), 2 bad usage, 3
the engine could not be reached or the file not written.

## Limits

* Only the RPC engine exists; browser and desktop windows (Playwright, WebDriver) and terminal byte streams
  are later engines.
* `judge` is for a person; an AI reviewer that pre-sorts the inbox does not exist yet.
* A step's Lua is code: review a sheet like a spec.
