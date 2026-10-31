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

* `id` is the task's slug (or `--name`), with what an id does not allow (`/`, spaces, non-ASCII) made `-`; the
  file is named like the id, so a second sheet of the same task (`--name`) is a case of its own. `title` is the
  task's title (the id when it is empty), `task` the id given (letters, digits, `_`, `-`, `.` and one `/`).
  Strings are quoted as Lua strings and cut to 300 characters, so any title loads.
* `steps` is a skeleton that runs as it is: the intro screen off (it names the Neovim version), a setup step to
  fill in, `settle`, one `screen`. It checks nothing yet: write what a person would do.
* `judge` has one entry per checkbox (`-`, `*`, `+` or `1.` list items) under a level 1 or 2 heading `Akzeptanz` /
  `Acceptance`, up to the next such heading (ticked or not, at most 30). Boxes in a fenced code block or another
  section do not count; fences and headings are read as CommonMark does. A task without boxes gets one entry
  from its title.
* `notes` and the header comment say `DRAFT`: drop them once the steps are real and the snapshot is reviewed.

An existing sheet is **never overwritten** (exit 2; `--name` writes another file): the file is created
exclusively, so one that appears meanwhile is not written over either. The written file is loaded right away; a
draft that does not load is removed again. The vault is `--vault`, else `$TASKS_VAULT`, else
`<repo>/../tasks-vault`; the engine is found as for `--tasks` below. Exit codes: 0 written, 2 bad usage or the
sheet exists, 3 no vault or engine, the task could not be read, the file not written or the draft does not load.

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
<!-- testing:sheets:states ui.option-float=inbox -->
<!-- testing:sheets:end -->
```

* A second run replaces the block; a box ticked in the task (by hand, or by an app) stays ticked. The block has no
  date, so a task only changes when the state of its sheets does, and its paths always name the project, whatever
  roots the report was given.
* The last line inside the block is for programs: `<!-- testing:sheets:states <id>=<state> ... -->`, one entry
  per sheet (its id, or the file name of a sheet that does not load) with `red` (failed or does not load),
  `stale`, `never`, `inbox` (green, waiting for your judgement), `manual` or `green`. tasks.nvim reads this line
  (`show`, the dashboard, `list --sheet=`); the text above it is for people and may change its wording. A sheet
  that does not load still reaches its task as `red` when its file has a `task = "<area/slug>"` line of its own
  (read as text, nothing runs), so a broken sheet never leaves the rest of the task looking green.
* Only a marker on a line of its own and outside a fenced code block counts (one quoted in prose or code is text),
  and so does only a notes heading outside a fence. Fences are read as CommonMark does (the same rule as
  tasks.nvim): up to 3 spaces, closed only by the same character, at least as long, with nothing after it. A task whose markers are broken (a begin without its end, an end
  in front of the begin, two of them) is **not written**: it is reported (exit 1) and fixed by hand, so no text
  between stray markers is ever replaced. A task file with CRLF line endings is sent back with line feeds (the
  engine keeps the file's own ending).
* Reading and writing go through the engine of tasks.nvim, never into the files: `call bodies` for every task named
  (asked again for the ids a 2 MiB page did not reach), `call ops` with a `set_body` per changed task and `if_match` =
  the version read, in requests of at most 100 operations and about 200 KiB. A task edited in between is a
  `conflict` (reported, exit 1), not overwritten.
* A task that is not open (finished or unknown) is reported (`task <id> missing`) and the list says so under the
  sheet. A sheet without `task` is left out.
* The conformance check **K16** (`testing conformance`, [CONFORMANCE.md](CONFORMANCE.md)) turns the other half of
  this into a gate: a sheet whose task is neither open nor finished, a sheet that does not load, is a finding
  (`--gate`: exit 1). A sheet without `task` is a warning there.
* The engine is found like a dependency: `$TASKS_NVIM_DIR`, `<vault>/.deps/tasks.nvim`, `<vault>/../tasks.nvim`,
  `stdpath('data')/lazy/tasks.nvim`; `--tasks-cli <path/to/scripts/tasks.lua>` names it. `--dry-run` says what would
  change and writes nothing.

```
testing sheets report <root>... --from <ir.json>... --tasks <vault> [--dry-run]
```

Exit codes: 0 done, 1 a task could not be written (conflict, refused, a body too long to send back), 2 bad usage, 3
the engine could not be reached or the file not written.

## One task, now (`testing sheets run`)

```
testing sheets run --task <area/slug> [--root <dir>]... [--tasks <vault> [--tasks-cli <tasks.lua>] [--dry-run]]
```

runs the sheets that name the task (a sheet that does not load too) and, with `--tasks`, writes their state into
the task's block: no suite, no second command. tasks.nvim's `:Tasks sheet-run` calls it.

* The roots are `--root` (repeatable), else the task's area as a repository: `$REPOS_DIR/<area>`, else
  `<vault>/../<area>`. With `--tasks` the projects the task's block already names join them (found the same way):
  the block is written whole, so a sheet of the task in another project runs too instead of dropping out. A project
  that is not found is refused (pass `--root`). The engine is found before a sheet runs.
* Each root passes the workspace trust gate first (a sheet runs the project's minimal init).
* A missing snapshot is a failure, as on CI: a run from a task never writes a reference image (run the spec once).
* On the workstation (`NVIM_MACHINE_ROLE=workstation`, trimmed, any case) it refuses, unless
  `TESTING_ALLOW_WORKSTATION=1`; a value that is neither `workstation` nor `default` is refused as a typo.
* A red sheet carries its first failure line into the block (`red: 80x24 step 3, keys ...`).

Exit codes: 0 green (or waiting for a person) and written, 1 a sheet is red or the task could not be written, 2 bad
usage, refused (trust, workstation) or no sheet names the task, 3 the engine of tasks.nvim could not be reached.

## Hand over to an AI (`testing sheets prompt`, `testing sheets accept`)

Stage 0 of the AI link: no model is called here (ai.nvim's headless entry comes later). The commands write a Markdown
document a person pastes into the AI of their choice, and take the answer back only through a check.

```
testing sheets prompt draft --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--out <file>]
testing sheets prompt explain --task <area/slug> [--root <dir>]... [--tasks <vault>] [--out <file>]
testing sheets accept --task <area/slug> --from <file> [--repo <dir>] [--name <file>]
```

* `prompt draft`: asks for a sheet for the live check. The document holds the task (title and body, without the
  generated block of the last report, cut at 32 KiB), the rules of the sheet format and the skeleton
  `testing sheets new` would write; the answer asked for is one ```lua block that returns the sheet.
* `prompt explain`: runs the task's sheets as `testing sheets run` does (trust gate, workstation rule, as on CI) and
  writes nothing into the task. For each red sheet the document holds every failure line (a snapshot failure shows
  the first differing rows), its snapshot files and its source; the answer asked for is the cause and, for a bug of
  the plugin, one ```task block (`title:`, `summary:`) that tasks.nvim turns into a bug task after confirmation. No
  red sheet: nothing is written (exit 0, a note on stderr).
* `accept`: takes the answer's last ```lua block (at the start of a line, any case; the whole text when it has
  none) and writes `TESTS/sheets/<id>.sheet.lua` of the area's repository (`--repo`, else `$REPOS_DIR/<area>`, else
  beside `--vault`) only when it loads (`sheet.load`, as data; reading stops after a million instructions, so a loop
  in a draft ends), names the task and no sheet of that name exists (created exclusively).

What the model sees is exactly the document: the task's title and body, the sheet format, the skeleton, and for
`explain` the failure lines, snapshot file names and the sheet's source. A project's path is written as its name
(`ui.nvim/TESTS/...`). The failure lines show what the child editor showed or returned (a snapshot's differing rows,
`got <value>`): what a sheet puts on the screen goes to the model too. A vault or root whose path names `tricentis`,
as written, made absolute or resolved (a link, `--vault .`), is refused (exit 2): its tasks may carry customer data,
and nothing of them is handed to an AI.

## Limits

* Only the RPC engine exists; browser and desktop windows (Playwright, WebDriver) and terminal byte streams
  are later engines.
* `judge` is for a person; an AI reviewer that pre-sorts the inbox does not exist yet.
* A step's Lua is code: review a sheet like a spec.
