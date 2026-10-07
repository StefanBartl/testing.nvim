# The conformance suite (K1 .. K15)

The rules of the gates (`NEW_PROJECT`, `RELEASE`, `REVIEW`) that a program can decide are checks that run on
**every** plugin with a `.testing.lua`, without a line of spec code. The rules that need a reader stay
**manual** and are listed in the report as such, so a green report is never read as "every rule holds"
(guard rail L7, "gates are specification").

It **reports first**. A repository becomes gated (`conformance.gate = true`, or `--gate` in its CI) only after
its findings were triaged: fixed, waived with a reason, or accepted.

```
nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua conformance [<root>] [options]
```

(`testing conformance` is a subcommand of the runner: everything after the word is the suite's own grammar, not the
run options of [CLI.md](CLI.md). In the editor: `:Testing conformance [<root>] [--gate] [--only=K1,K3] [--skip=K10]
[--bridge] [--markdown]`, which runs it in a headless child and shows the report; a failed gate is a warning with
the report. From Lua: `require("testing.conformance").main(argv, services)`, see [Integration](#integration).)

The keys of `.testing.lua` that this suite reads are `conformance.gate`, `skip`, `waivers`, `keymaps_off`,
`timeout_ms`, `load_budget_ms`, `rules_bridge` (typed and validated by `testing.config.project`, see
[CONFIG.md](CONFIG.md); a bad value is reported with its name and the default stays), and `setup`.

| Option | |
| --- | --- |
| `--only K3,K7` | run only these checks (repeatable) |
| `--skip K10` | do not run these checks (repeatable); the entry stays in the report as `n/a` |
| `--report-only` | **default.** Always exit 0, except exit 3 when a check could not run |
| `--gate` | exit 1 when a check failed (`warn` never fails the gate) |
| `--json`, `--markdown` | print the report as JSON or Markdown instead of terminal lines |
| `--verbose`, `--manual` | terminal: waived findings and notes; the list of manual rules |
| `--bridge` | also run rules.nvim's own check of the same rule families (soft, see below) |
| `--timings` | add durations and the measured times (the report is then not deterministic) |
| `--json-file`, `--markdown-file`, `--junit-file` | also write a report file, never inside the checked repository |
| `--list` | list the checks |

Exit codes: `0` done, `1` `--gate` and a check failed, `2` usage error or an unusable `.testing.lua` (the report still
runs with the defaults and names the file's error), `3` a check could not run (the child editor did not start,
a check raised, the root is not a directory).

## What a report is

`conformance.run(root, opts) -> report` is a table (`conformance.json(report)` encodes it with sorted keys, the
same repository gives the same bytes unless `--timings` was asked for):

```lua
{
  schema_version = 1, tool = "testing.conformance",
  root = "<REPO>", name = "sessions.nvim", plugin = "sessions", mode = "report" | "gate",
  checks = { {                       -- K1 .. K15 in order
      id = "K4", title = "...", kind = "runtime" | "static", rules = { "REL-21", "NEW-22" },
      status = "pass" | "fail" | "warn" | "n/a" | "error",
      reason = "...",                -- n/a and error: why
      findings = { { check = "K4", rule = "REL-21", level = "error" | "warn" | "info",
                     message = "...", file = "lua/x/maps.lua", line = 12,
                     waived = true, waiver_reason = "..." } },
      notes = { "..." },             -- what was measured
      rule_status = { ["NEW-36"] = { status = "pass", count = 0 } },   -- K15: one verdict per rule
  } },
  manual = { { id = "NEW-09", severity = "recommended", gate = "NEW_PROJECT", title = "...",
               status = "manual", reason = "...", source = "testing" | "rules.nvim" } },
  summary = { checks = 15, pass = 9, fail = 1, warn = 3, ["n/a"] = 2, error = 0, manual = 64,
              findings = { error = 2, warn = 7, info = 0 }, waived = 0 },
  problems = { "a waiver without a reason is ignored", ... },  -- configuration problems
  bridge = { ... },                  -- only with --bridge
  verdict = "pass" | "warn" | "fail" | "error",
}
```

Status of a check: `fail` when a finding of level `error` is open, `warn` when only warnings are, `pass`
otherwise; `n/a` when the check does not apply (the reason says why; a failed prerequisite reads
`blocked: ...` and the cause is another check), `error` when it could not run (an infrastructure problem).
Everything is also available as terminal lines (`conformance.terminal`), Markdown (`conformance.markdown`)
and as a Result-IR (`conformance.to_result`), which the JUnit and GitHub reporters of `testing.report` render:
one case per check, a failed assertion per `error` finding (`::error file=,line=::` in GitHub Actions).

Text that came out of the checked repository (file names, lines, the error of its code) is hostile input: it
is made printable (control characters, escape sequences, bidirectional overrides become visible text) and
bounded before it enters a report.

## The checks

`kind = runtime` checks run in a **child editor** (`testing.rpc`: own XDG and temp directories, an
allowlisted environment, the guards on in observing mode), with the plugin loaded from the repository:
its root is first on the runtimepath, then this checkout of testing.nvim, lib.nvim and the `deps` of
`.testing.lua`. The suite starts at most three editors (`main`, `keymaps_off`, `require`) and shares the data
between the checks; a plugin is done in about 1.2 s (rules.nvim 1.4 s, lib.nvim with its 300 modules 3 s).
The child's working directory is a temporary directory, never the repository, and the checked repository is
never written to (SEC-47). The `minit` of `.testing.lua` is not run: it belongs to the specs, and what the
plugin needs must be listed in `deps`.

| # | Check | Rules | Kind | Level | Mechanics |
| --- | --- | --- | --- | --- | --- |
| K1 | every module under `lua/<plugin>/**` can be required on its own | NEW-47, XP-06 | static + runtime | error | Static: every literal `require("<plugin>.a.b")` of `lua/`, `plugin/`, `TESTS/` is resolved against the directory listing, case-exactly (Windows and macOS find `lua/Foo/bar.lua` for `foo.bar`, a Linux runner does not) and a module of the plugin that exists nowhere is reported. Runtime: every module is required alone in a fresh editor (the cache entries of its own tree forgotten after each one). An error is an `error`; another plugin's module that cannot be found is a `warn` (declare it in `deps`); a module that leaves a global, keymap, command or autocmd behind when merely required is a `warn`. One cause is one finding: a missing dependency, or a side effect, that many modules show because they load the module that has it is reported once, with the other modules named in the message. |
| K2 | `setup()` twice is idempotent | LUA-96 | runtime | error | The child calls `setup(<setup of .testing.lua>)` twice and compares keymaps, user commands, autocmds (a multiset) and the lib.nvim registries. More after the second call is an `error` (a registry that grows alone only a `warn`), fewer a `warn`. A `setup()` that raises is reported with its message. |
| K3 | `setup({ keymaps = false })` registers no keymaps | REL-20 (NEW-21) | runtime | error | A second editor calls `setup(<setup> + conformance.keymaps_off)`; everything it registers is a finding (`<Plug>` handles are ignored). `n/a` when the default setup registers no keymap, and when nothing in `lua/` or `plugin/` names the option (`keymaps` by default): then `keymaps = false` is not this plugin's spelling, and the reason says to name its own switch in `conformance.keymaps_off`. The first finding says so too: a plugin that switches its keymaps off with another option is judged by that option, once it is named. |
| K4 | every keymap has a `desc` | REL-21 (NEW-22) | runtime | error | Read from the editor (`nvim_get_keymap`), plus the lib.nvim registry. |
| K5 | every user command has completion | REL-22, UI-22 (NEW-26) | runtime | warn / error | `nvim_get_commands`: a command with arguments and no `-complete` is a `warn` (the suite cannot tell a closed value set from free text, UI-26). `composer.check_all()`: a failing route is an `error`. |
| K6 | `:checkhealth <plugin>` runs without an error | REL-16 (NEW-10), UI-57 | runtime | error | The report buffer is parsed: `ERROR` lines are errors, `WARNING` lines warnings; when a dependency of `.testing.lua` is not installed on this machine, the errors are warnings with that reason (the plugin reported the environment correctly). `n/a` without `lua/<plugin>/health.lua` (that is K15's). |
| K7 | every `pcall(require, ...)` soft dependency has a health check | REL-17, LUA-05 | static | warn | `health.lua` and the modules of the plugin it requires (two levels) must mention the dependency. |
| K8 | no `vim.deprecate` message and no scheduled error on load and setup | DEP-01, ERR-01 | runtime | error | The deprecation and scheduled-error guards, active while `plugin/` is sourced, the plugin required and `setup()` called twice: a `vim.deprecate` message, or an error raised by a `vim.schedule`/luv callback the plugin started (the editor prints it and goes on). `n/a` (not a pass) when the guards did not run in the child: nothing was observed. |
| K9 | no write outside tmp, no process, no network on load and setup | SEC-22, SEC-47 | runtime | error | The `process_net` and `fs` guards and the effects ledger of the same window. Starting a tool on purpose is a decision: waive it with a reason. `n/a` (not a pass) when the guards did not run. The window covers `plugin/`, `require` and both `setup()` calls (the second one is the repeated call of K2), not `:checkhealth` (a health check runs tools on purpose). |
| K10 | `require` + `setup()` within `load_budget_ms` | PERF-01 | runtime | warn, report-only | Three measurements (`vim.uv.hrtime`; the second and third after the modules were unloaded), median against `conformance.load_budget_ms` (default 40). |
| K11 | no new global | PRIN-10 | runtime | error | Exact `_G` difference over `plugin/`, `require` and two `setup()` calls. |
| K12 | keymap action without a command counterpart | REL-22 | runtime | warn, report-only | `lib.nvim.bindings.audit.gaps()`. A candidate list, never a verdict. |
| K13 | fragile keys, command-name prefix collisions | UI-22 | runtime | warn / info, report-only | `audit.key_risks()` (fragile = warn, common = info) and `audit.prefix_ambiguities()`, reduced to the pairs that involve a command of this plugin. |
| K14 | `docs/BINDINGS.md` / `docs/commands.md` match the registry | NEW-35, REL-06 | runtime | error / warn | A page that lib.nvim generated is re-rendered in the child and compared (`docs.check`, read-only): a difference is a `warn`. A hand-written document is checked in one direction: every registered command (`:Name`, not as the start of a longer name), keymap (lhs, `<leader>`, `<C-x>`, `<Bslash>` normalized) and autocmd group/event must appear in the text. A key of one character counts only when it is set off as code (a backtick span, a table cell, a fenced line), a longer one as a word of the prose too: the letters `gl` inside `global` document nothing. Commands and keymaps are an `error`, autocmds a `warn`. A command or group whose name the plugin's own sources never spell was registered by a dependency (`:KitPreview` of ui.nvim) and is not compared (a note names them). `n/a` without `docs/BINDINGS.md` (K15's). |
| K15 | static rules of the gates | see below | static | by rule | The rules below. One verdict per rule in `rule_status`. |

`n/a` is common and honest: K3, K4, K12 and K13 look at keymaps, and most plugins of this fleet bind none by
default. A plugin that wants them checked lists its keymaps in `setup` of `.testing.lua`:

```lua
return {
  plugin = "sessions",
  setup = { keymaps = { save = "<leader>ssa", load = "<leader>slo" } },
}
```

### K15: the static rules

Literal paths only (no glob on a root, XP-01), bounded reads, nothing written, nothing started. The predicates
follow the `check` blocks of rules.nvim, with the corrections its fleet runs brought (both spellings of
`stylua.toml`, busted only where `TESTS/` uses it, a lazy.nvim plugin spec and a generator template named
`*_spec.lua` are not tests). `critical` rules are errors, `recommended` warnings, `nice-to-have` info;
a heuristic (a grep) marks its items `warn` itself.

| Rule | Severity | What |
| --- | --- | --- |
| NEW-03 | recommended | `.luarc.json` exists |
| NEW-36 (LLS-01) | recommended | no `workspace.library` (flat or nested key) |
| NEW-37 (LLS-03) | recommended | `workspace.ignoreDir` lists `.claude` / `.deps` when they exist |
| NEW-38 | recommended | `diagnostics.globals` does not list `vim` |
| NEW-50 | recommended | `.luarc.json` is strict JSON |
| NEW-45 | recommended | `stylua.toml` or `.stylua.toml`; `line_endings` matches `.gitattributes` |
| NEW-49 | recommended | `.luacheckrc` declares busted where `TESTS/` uses `describe`/`it` |
| NEW-39 | critical | `TESTS/`, `TESTS/minimal_init.lua`, `scripts/test.sh` |
| NEW-48 | critical | no spec under `lua/` (template and plugin spec exempt), no Lua in `tests/`, `test/`, `spec/`, `docs/TESTS` |
| NEW-06, REL-28 | critical / recommended | `LICENSE` exists; it is MIT and the README has a License section |
| NEW-11 (REL-01), REL-10 | critical / recommended | `README.md`; an installation section or link |
| NEW-13 (REL-05), NEW-15 (REL-06) | critical | `doc/*.txt`, `docs/BINDINGS.md` exist |
| NEW-14 (REL-07) | critical | no `docs/ROADMAP.md` |
| NEW-07, NEW-27, NEW-08, NEW-10 (REL-16) | recommended / critical | `config/DEFAULTS.lua`, `config/init.lua`, `bindings/{keymaps,usrcmds,autocmds}`, `health.lua` |
| REL-35 | heuristic, warn | a reference to the author's vault (the word the rule greps for) in README, `docs/`, `doc/`, `lua/` |
| REL-13 | recommended | no `dir = vim.env...` in the README |
| LUA-93 (REL-11) | heuristic, warn | the README's lazy.nvim spec names a trigger; `lazy = false` with `cmd`/`ft` is a contradiction |
| LUA-82 (NEW-28, ERR-50) | heuristic, warn | something in `config/` validates; a `---@class ...Config/Opts` with `---@field` types the keys |
| CMT-15 | info | open `--- CDX:` tags are listed (a tag that was decided stays) |
| SEC-47 | heuristic, warn | `os.tmpname()` and `"/tmp/name"` literals |
| XP-01 | heuristic, warn | `glob`/`globpath` on a concatenated path |

### Manual rules

`conformance.manual()` (and the `manual` list of every report, `--manual` in the terminal) names the rules no
tool decides from the repository, with the reason: remote state (GitHub description, topics, default
branch), judgement (`NEW-09` what a level is, `NEW-16/17` which dependencies, `NEW-24/25`, `REL-12`), tools the
suite does not start (`lua-language-server --check`, `stylua --check`, `luacheck`: CI), git history
(`NEW-34`, `NEW-52`) and the REVIEW sections 1 to 9. A rule a check enforces only in part (K3 for
`REL-20`) is listed too, with the part that stays manual.

## Configuration: `conformance` in `.testing.lua`

```lua
return {
  plugin = "sessions",
  setup = { keymaps = { save = "<leader>ssa" } },     -- what K2 .. K14 call setup() with
  conformance = {
    load_budget_ms = 40,                             -- K10
    gate = false,                                    -- true: exit 1 when a check failed (report first!)
    skip = { "K10" },                                -- checks that do not run
    keymaps_off = { keymaps = false },               -- what K3 passes on top of `setup`
    timeout_ms = 20000,                              -- one call into the child editor
    waivers = {
      { check = "K9", rule = "SEC-22", text = "git", reason = "the status line needs `git` once" },
      { check = "K14", file = "docs/BINDINGS.md", reason = "autocmds are listed in docs/autocmds.md" },
    },
    rules_bridge = { rulesets = { "/path/to/Checklists/gates" }, families = { "NEW", "REL" } },
  },
}
```

A **waiver** names the check, optionally the `rule`, the `file` (a trailing `/` is a directory) and a `text` the
message must contain, and **must carry a reason** of at least 8 characters; one without is ignored and says so
in `problems`. A waived finding stays in the report (`waived = true` with its reason) and does not count; a
waiver that matches nothing is reported as stale. Two optional keys narrow a waiver: `level = "warn"` (only
findings of that level: a waiver for the warnings never hides an error) and `expires = "2027-01-31"` (a real
day; after it the waiver no longer applies and `problems` says that it expired). A waiver with none of `rule`,
`file`, `text` or `level` that hides an error finding is named in `problems` ("narrow it"). A key that is invalid or an unknown check id in `skip`
is a problem that names it, and the default stays (a typo must not silently switch a check off).

## The rules.nvim bridge (soft)

`conformance.rules_bridge(root, opts)` / `--bridge` runs rules.nvim's own `check_family_json` for the families
(`NEW`, `REL`) and

* lists the rules that have no `check` in rules.nvim as **manual** (`source = "rules.nvim"`) next to the suite's own;
* reports **drift**: a rule both sides decide with a different verdict means that testing.nvim's predicate or
  the rule in rules.nvim has gone stale (`bridge.drift`);
* never changes the verdict of K1 .. K15 or the exit code.

Without rules.nvim (not on the runtimepath, no sibling checkout) or without a configured ruleset the bridge answers
`{ available = false, status = "n/a", reason = ... }` and nothing else. The predicates of a ruleset are Lua that
rules.nvim executes with the rights of this editor: the same trust as `.testing.lua`.

## Reading a report: what to do with a finding

Every finding is one of: **the plugin is wrong** (fix it), **the check is wrong** (a false positive is a bug of the
suite: open an issue with the repository), **accepted** (waive it with the reason), or **not applicable here**
(skip the check with the reason in the comment). The first fleet triage found, for example: `:Session` is a prefix
of `:SessionLoad` (K13, a real ambiguity), dirty-tracking autocmds missing from `docs/BINDINGS.md` (K14), a
soft dependency without a health line (K7), `lib.nvim` registry entries that double on the second `setup()`
(K2 warn, the autocmds themselves do not).

## Integration

```lua
local conformance = require("testing.conformance")
local report = conformance.run(root, { only = { "K3" }, gate = false })
local code = conformance.main({ "--gate", root }, { out = print, err = print, cwd = root })
```

`conformance.main(argv, services)` takes `services.out`/`err` (sinks), `cwd` and, for specs, `run` (a replacement
for `conformance.run`); `conformance.run` accepts `probe` (a function that replaces the child sessions and
returns the data a session would, for specs), `settings` and `config` (overrides).

## Limits, said plainly

* **Hostile text.** The checks read the repository through one object (`fsx`): relative paths below the root only; every component of a path is resolved, so a link or a junction on a directory (`docs` -> elsewhere) is absent; a file is read up to 2 MiB, a Lua file for the checks up to 512 KiB (all sources together 64 MB, more is skipped and said); a line is cut at 2000 bytes before any pattern runs (a quadratic pattern on a line of a million characters took hours), and the report says how many lines were cut. Text of the repository in the Markdown report (a description, a group name, the directory name) is escaped, a file name is a code span with a fence it cannot leave.
* **Trust.** The runtime checks execute the plugin's code (its `plugin/` files, `require`, `setup()`, its
  health check), as running its specs does, and `.testing.lua` is executed like everywhere in testing.nvim. The child
  editor has an allowlisted environment (no `$NVIM`, no tokens) and its own XDG and temp directories, and the
  guards observe it; that is a net for accidents, not a sandbox. A repository you do not trust belongs in a
  container or VM (see GUARDS.md, "honest limit"), not in this suite. Every run says so on stderr (`this runs the repository's own code ... with your rights`); there is no trust gate beyond that, and no sandbox.
* The checks look at what **this** setup registers. A plugin whose keymaps are opt-in shows `n/a` for K3, K4,
  K12 and K13 until its `.testing.lua` lists them in `setup`.
* `nvim_get_keymap` shows a mapping with the leader expanded; K14 compares against the notations `<leader>x`
  and `\x` for the editor's default leader and against the action's name in backticks.
* Buffer-local keymaps are read for the buffer that is current after `setup()`, not for every filetype.
* K1's "fresh cache per module" forgets the modules of the plugin's own tree; a global side effect of one
  module stays in the editor for the next one (and is what the warning is about).
* K10 is a measurement on a machine you do not control (an antivirus scan makes a cold file slow): report-only.
* The guards are safety nets for accidents, not a sandbox (see [GUARDS.md](GUARDS.md)); K9 sees what a Lua wrapper
  sees, not what a started program does afterwards, and not Vimscript.
