---@meta
---@module 'testing.core.@types'

-- #####################################################################
-- core/result.lua -- the Result-IR (schema_version 1)

---@alias Testing.Status
--- Outcome of one case. `skip` is never green; `xpass` (an expected failure that passed) is an error.
---| "pass"
---| "fail"
---| "error"
---| "skip"
---| "xfail"
---| "xpass"
---| "timeout"
---| "crash"

---@class Testing.Result.Git
---@field sha string Abbreviated commit hash.
---@field dirty boolean Whether the working tree had uncommitted changes.

---@class Testing.Result.RunCache
---@field mode string `use` or `refresh`.
---@field files_cached integer Spec files that were not run (their result came from an entry).
---@field cases_cached integer
---@field files_ran integer
---@field stored integer
---@field nondeterministic? integer Files not stored because the same key gave another result (key flip); only when there were some.
---@field audit_rate? number `--cache-audit`: the share of the hits that ran anyway (0..1); the audit fields are only there when it was above 0.
---@field audited? integer Hits that ran anyway.
---@field audit_skipped? integer Hits picked for the audit that gave no result to compare (the run stopped, the file lost its cases).
---@field stale_pass? integer Audited hits whose fresh result differed from the stored one (`cache.stale_pass`).
---@field stale_pass_rate? number `stale_pass / audited`: the measured stale-pass rate of this run (0 when nothing was audited).
---@field findings? { code: string, file: string, key: string, message: string, parts?: string[] }[] The `cache.stale_pass` findings (the first 20).
---@field findings_total? integer All findings, when the list above is cut.

---@class Testing.Result.Run
--- Header of one run: who ran what, where, how.
---@field cache? Testing.Result.RunCache What the result cache did (`--cached`).
---@field verdict? Testing.Verdict The three-valued verdict of the run (`green`, `green-partial`, `red`), filled by the run driver (`testing.report.verdict`).
---@field id string `<UTC ISO timestamp>-<4 hex>`; unique per run.
---@field root string Repository root (a placeholder `<REPO>` after normalization).
---@field project_key string Stable key of the project, e.g. `lib.nvim@a1b2`.
---@field nvim string Neovim version, e.g. `0.12.0`.
---@field os string Operating system, e.g. `windows`.
---@field arch? string CPU architecture.
---@field git? Testing.Result.Git Absent when the project is not a git checkout.
---@field seed? integer Random seed of the run.
---@field jobs integer Parallelism (1 = serial).
---@field duration_ms number Wall time of the whole run.
---@field argv string[] The effective command-line arguments.

---@class Testing.Result.Assertion
--- One recorded assertion. Passing assertions carry no `expected`/`actual` (keeps big suites cheap).
---@field ok boolean
---@field kind string Assertion kind: `eq`, `same`, `ok`, `matches`, `has`, `error`, ... or `no_assertions`.
---@field msg? string The caller's message, or a generated one for a failure.
---@field expected? string Printable expected value (failures only).
---@field actual? string Printable actual value (failures only).
---@field file? string Source file of the assertion call.
---@field line? integer Source line of the assertion call.
---@field expected_ref? string Snapshot path (reserved for the snapshot kinds).
---@field diff? string Unified diff (reserved for the snapshot kinds).

---@class Testing.Result.Effects
--- What the case did to the outside world; always present, always three lists.
---@field spawned string[] Started processes.
---@field network string[] Network attempts.
---@field fs_outside_tmp string[] Writes outside the temp dir.

---@class Testing.Result.Artifact
---@field kind string e.g. `trace`, `screenshot`.
---@field path string

---@class Testing.Result.CaseError
--- Why a case has status `error`: the test body itself threw.
---@field message string First line of the thrown error.
---@field traceback string The full traceback (`lib.lua.error.safe_call`).

---@class Testing.Result.GuardFinding
--- One finding of a guard (or of the soft isolation between files): what leaked, wrote or blocked.
---@field guard string Guard name: `fs`, `state`, `scheduled_error`, `prompt`, `deprecation`, `process_net`, `clock`, ...
---@field severity "info"|"warn"|"error" `info` is listed only, `warn` is a warning, `error` also fails the case (`result.add_guard_finding` adds the failed `guard` assertion).
---@field id? string Stable id of the finding kind (`state.autocmd`, `process.spawn_blocked`, ...).
---@field case? string Id of the case the guard layer saw it in (the runner puts it on that case; without one it lands on the last case of the file).
---@field message string Names the culprit precisely ("spec X leaves autocmd Y in group Z").
---@field stack? string Where it happened (a deprecated call, an unanswered prompt, a scheduled error): the caller's stack, paths redacted, at most 2000 bytes.

---@class Testing.Result.Case
---@field guards? Testing.Result.GuardFinding[] Guard findings; absent when there are none.
---@field id string Stable id `file::describe::case[#param]`.
---@field file string File of the case, relative to the root.
---@field line? integer Definition line of the case.
---@field tags string[]
---@field status Testing.Status
---@field duration_ms number
---@field retries integer
---@field assertions Testing.Result.Assertion[]
---@field effects Testing.Result.Effects
---@field artifacts Testing.Result.Artifact[]
---@field notes string[]
---@field error? Testing.Result.CaseError Set when `status == "error"`.
---@field reason? string Why a case was skipped.
---@field cached? boolean `true`: not executed in this run, the result comes from the result cache (`testing.cache`).
---@field flaky? boolean `true`: the case failed and then passed on a retry (`--retry-failed`); `retries` is the retry that passed. The status is `fail` (the run stays red) unless `--allow-flaky` replaced it by the passing result.
---@field surface? { hit: string[] } The keymaps, commands and autocmds the case exercised (`surface.track`).

---@class Testing.Result.Summary
--- One counter per status; always all eight keys.
---@field pass integer
---@field fail integer
---@field error integer
---@field skip integer
---@field xfail integer
---@field xpass integer
---@field timeout integer
---@field crash integer

---@class Testing.Result
---@field schema_version integer Always 1 for this layout.
---@field run Testing.Result.Run
---@field cases Testing.Result.Case[]
---@field summary Testing.Result.Summary
---@field warnings? string[] Privacy findings the redaction could not remove (set by `testing.run.inproc.sanitize`, never the leaked text itself; the verdict is unaffected).

---@class Testing.Result.RunOpts
--- Fields of `Testing.Result.Run`; everything has a default.
---@field id? string
---@field root? string
---@field project_key? string
---@field nvim? string
---@field os? string
---@field arch? string
---@field git? Testing.Result.Git
---@field seed? integer
---@field jobs? integer
---@field duration_ms? number
---@field argv? string[]

---@class Testing.Result.CaseOpts
---@field file string
---@field describe? string|string[] Describe path, outermost first.
---@field name string Case name.
---@field param? string|integer Parameter label, appended as `#param`.
---@field line? integer
---@field tags? string[]

---@class Testing.Result.FinishOpts
---@field expect_fail? boolean Map `fail` to `xfail` and `pass` to `xpass`.

---@class Testing.Result.PathRoots
--- Absolute directories replaced by a placeholder; any may be absent. Longest match wins.
---@field repo? string Becomes `<REPO>`.
---@field home? string Becomes `<HOME>`.
---@field tmp? string Becomes `<TMP>`.
---@field state? string Becomes `<STATE>`.

---@class Testing.Result.NormalizeOpts
---@field case_insensitive? boolean Match roots case-insensitively (Windows). Default false.

---@class Testing.Result.EncodeOpts
---@field roots? Testing.Result.PathRoots Normalize paths before encoding.
---@field case_insensitive? boolean
---@field indent? integer Pretty-print with this many spaces (default compact).
---@field redact? Testing.Result.Redact Redact the free text of the cases first (assertion text, error, notes).

---@class Testing.Result.Redact
---@field env_names? string[] Environment variable names: `NAME=value` loses its value (`NAME=<ENV>`).
---@field words? { text: string, ph?: string }[] Words replaced by `ph` where they stand alone (user name, host name); under 3 characters are ignored.

---@class Testing.Result.ValidateOpts
---@field forbid? string[] Words (e.g. the user name, the host name) that must not occur anywhere in the IR; whole word, case-insensitive.
---@field forbid_free_text_only? boolean Check `forbid` and the e-mail shape only in free text (assertion texts, error, notes, reason), not in ids, names and file names.
---@field allow_emails? boolean Skip the e-mail address leak check (default false).
---@field allow_abs_paths? boolean Skip the user-home-path leak check (default false).
---@field leak_warnings? string[] When given, the findings of the leak checks (forbidden word, e-mail, user-home path) are appended here and are NOT problems: the result stays valid (they never contain the leaked text itself). Structural problems are unaffected.

---@class Testing.Result.Module
---@field SCHEMA_VERSION integer
---@field STATUSES Testing.Status[] The status enum, in canonical order.
---@field PLACEHOLDERS table<string, string> Root key to placeholder text.
---@field make_run_id fun(time?: integer, rnd?: integer): string
---@field case_id fun(opts: Testing.Result.CaseOpts): string
---@field new_run fun(opts?: Testing.Result.RunOpts): Testing.Result.Run
---@field new_case fun(opts: Testing.Result.CaseOpts): Testing.Result.Case
---@field new fun(opts?: Testing.Result.RunOpts): Testing.Result
---@field add_case fun(result: Testing.Result, case: Testing.Result.Case): Testing.Result.Case
---@field finish_case fun(case: Testing.Result.Case, opts?: Testing.Result.FinishOpts): Testing.Result.Case
---@field add_guard_finding fun(case: Testing.Result.Case, finding: Testing.Result.GuardFinding): boolean Record a guard finding; severity `error` also fails the case.
---@field merge_effects fun(case: Testing.Result.Case, effects: table<string, string[]>|nil) Merge a ledger's `spawned`/`network`/`fs_outside_tmp` lists into the case.
---@field GUARD_SEVERITIES string[] `info`, `warn`, `error`.
---@field MAX_GUARD_FINDINGS integer Findings kept per case.
---@field MAX_EFFECTS integer Entries kept per effects list.
---@field summarize fun(cases: Testing.Result.Case[]): Testing.Result.Summary
---@field finalize fun(result: Testing.Result): Testing.Result
---@field normalize fun(value: any, roots: Testing.Result.PathRoots, opts?: Testing.Result.NormalizeOpts): any
---@field encode fun(result: Testing.Result, opts?: Testing.Result.EncodeOpts): string|nil, string|nil
---@field validate fun(result: any, opts?: Testing.Result.ValidateOpts): boolean, string[]

-- #####################################################################
-- core/assert.lua -- collecting assertions

---@alias Testing.Assert.Clock fun(): number Monotonic milliseconds.

---@class Testing.Assert.Opts
---@field clock? Testing.Assert.Clock Defaults to `vim.uv.hrtime` when present, else `os.clock`.

---@alias Testing.Assert.CaseBody fun(a: Testing.Assert.Context)

---@class Testing.Assert.Context
--- The collecting assertions `a`. Every function records onto the current case and does not raise on a
--- failed check, except inside a protected call the spec wrote (`testing.core.protected`: the spec asks
--- "does this fail?" and gets the raise). Arguments are `(actual, expected, msg?)`, the same order as the
--- `H.eq` of dialect A.
--- Plain dot calls: `a.eq(x, 1)`, they can be destructured (`local eq = a.eq`).
---@field depth integer Extra frames to skip when locating the caller (a wrapper that does not tail call sets 1).
---@field eq fun(actual: any, expected: any, msg?: string): boolean Strict `==`; tables by identity.
---@field same fun(actual: any, expected: any, msg?: string): boolean Deep equality (keys sorted, metatables ignored).
---@field deep_eq fun(actual: any, expected: any, msg?: string): boolean Alias of `same`.
---@field ok fun(value: any, msg?: string): boolean Truthy.
---@field not_ok fun(value: any, msg?: string): boolean Falsy.
---@field is_nil fun(value: any, msg?: string): boolean
---@field not_nil fun(value: any, msg?: string): boolean
---@field matches fun(str: any, pattern: string, msg?: string): boolean Lua pattern match on a string.
---@field has fun(haystack: any, needle: string, msg?: string): boolean Plain substring.
---@field error fun(fn: function, pattern?: string, msg?: string): boolean `fn` must throw; optional pattern on the message.
---@field no_error fun(fn: function, msg?: string): boolean, any `fn` must not throw; also returns its first result.
---@field fail fun(msg: string): boolean An explicit, unconditional failure.
---@field begin_case fun(opts: Testing.Result.CaseOpts): Testing.Result.Case Bind a fresh case; later assertions land on it.
---@field end_case fun(opts?: Testing.Result.FinishOpts): Testing.Result.Case Finish and unbind the current case.
---@field current fun(): Testing.Result.Case|nil The bound case, if any.
---@field scope fun(): table Assertion functions bound to the case open now; a call after that case ended is recorded in `late` and raises.
---@field late { case_id: string, kind: string, file: string|nil, line: integer|nil, msg: string }[] Assertions that arrived after their case ended.
---@field run_case fun(opts: Testing.Result.CaseOpts, body: Testing.Assert.CaseBody, finish?: Testing.Result.FinishOpts): Testing.Result.Case Run `body(a)` as one case.

---@class Testing.Assert.Module
---@field new fun(opts?: Testing.Assert.Opts): Testing.Assert.Context
---@field inspect fun(value: any): string Deterministic printable form of a value.
---@field deep_equal fun(a: any, b: any): boolean

return {}
