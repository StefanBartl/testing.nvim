---@meta
---@module 'testing.conformance.@types'

-- #####################################################################
-- check.lua (the contract of one check module)

---@alias Testing.Conformance.Kind "static"|"runtime"
---@alias Testing.Conformance.Level "error"|"warn"|"info"
---@alias Testing.Conformance.Status "pass"|"fail"|"warn"|"manual"|"n/a"|"error"

---@class Testing.Conformance.Finding
---@field check string Id of the check (`K4`).
---@field rule string Rule id the finding is about (`REL-21`, `NEW-36`, ...).
---@field level Testing.Conformance.Level `error` fails the gate, `warn` never does, `info` is listed only.
---@field message string One line, safe to print (no control characters).
---@field file? string Path relative to the checked repository, forward slashes.
---@field line? integer
---@field waived? boolean Set by the waiver pass.
---@field waiver_reason? string

---@class Testing.Conformance.Check
---@field id string `K1` .. `K15`.
---@field title string
---@field rules string[] Rule ids the check enforces (`NEW-47`, `REL-21`, `REVIEW §6`, `LUA-96`).
---@field kind Testing.Conformance.Kind
---@field level Testing.Conformance.Level The level a finding has unless the check names another one.
---@field report_only? boolean The check can never fail the gate (K12, K13, K10).
---@field run fun(ctx: Testing.Conformance.Ctx): Testing.Conformance.Outcome

---What a check returns.
---@class Testing.Conformance.Outcome
---@field findings? Testing.Conformance.Finding[]
---@field na? string Reason: the check does not apply to this repository (status `n/a`).
---@field blocked? string Reason: a prerequisite failed (status `n/a`, the cause is another check).
---@field error? string Reason: the check could not run (status `error`, an infrastructure problem).
---@field notes? string[] Facts worth a line in the report (what was measured).
---@field volatile? string[] Facts that differ from run to run (times); kept in the report only with `timings = true`.
---@field rules? table<string, { status: string, count: integer }> Per-rule verdicts (K15).
---@field data? table Check specific data kept in the report.

-- #####################################################################
-- ctx

---@class Testing.Conformance.Fs
---@field root string
---@field cut integer Lines that were longer than the cap and were cut before a check saw them.
---@field abs fun(self: Testing.Conformance.Fs, rel: string): string|nil, string|nil
---@field stat fun(self: Testing.Conformance.Fs, rel: string): table|nil
---@field exists fun(self: Testing.Conformance.Fs, rel: string): boolean
---@field is_file fun(self: Testing.Conformance.Fs, rel: string): boolean
---@field is_dir fun(self: Testing.Conformance.Fs, rel: string): boolean
---@field read fun(self: Testing.Conformance.Fs, rel: string): string|nil, string|nil
---@field lines fun(self: Testing.Conformance.Fs, rel: string): string[]|nil, string|nil
---@field list fun(self: Testing.Conformance.Fs, rel: string): { name: string, type: string }[]
---@field walk fun(self: Testing.Conformance.Fs, rel: string, opts?: Testing.Conformance.WalkOpts): string[]

---@class Testing.Conformance.WalkOpts
---@field ext? string Only files with this extension (`lua`, no dot).
---@field skip? table<string, boolean> Directory names that are not entered (default: `.git`, `.claude`, `.deps`, `node_modules`).
---@field limit? integer At most this many files (default 5000).

---@class Testing.Conformance.Settings
---@field gate boolean `--gate` default of the repository (`conformance.gate`).
---@field skip string[] Check ids that do not run.
---@field waivers Testing.Conformance.Waiver[]
---@field load_budget_ms number
---@field keymaps_off table Options K3 calls `setup()` with, on top of `setup` (default `{ keymaps = false }`).
---@field timeout_ms integer Timeout of one child call.
---@field rules_bridge { rulesets?: string[], families: string[] }

---@class Testing.Conformance.Waiver
---@field check string Check id the waiver applies to.
---@field reason string Why (mandatory).
---@field rule? string Only findings of this rule.
---@field file? string Only findings in this file (`dir/` = everything below it).
---@field text? string Only findings whose message contains this text (plain).
---@field level? "error"|"warn"|"info" Only findings of this level (a waiver for a warning never hides an error).
---@field expires? string `YYYY-MM-DD`: from the day after, the waiver no longer applies and says so.

---@class Testing.Conformance.Ctx
---@field root string Absolute, forward slashes.
---@field plugin? string Lua module root (`.testing.lua` `plugin`, else derived).
---@field plugin_problem? string Why `plugin` could not be used.
---@field missing_deps? string[] Dependencies of `.testing.lua` that this machine does not have (set by the first runtime session).
---@field config table The validated project configuration (`testing.config.project`).
---@field settings Testing.Conformance.Settings
---@field fs Testing.Conformance.Fs
---@field modules fun(): { module: string, rel: string }[] The modules below `lua/<plugin>`.
---@field sources fun(dir: string): { rel: string, text: string, lines: string[] }[] The Lua files below a top-level directory (`lua`, `plugin`, `TESTS`), memoized.
---@field module_file fun(module: string): string|nil The repository-relative file of a module of the plugin.
---@field probe fun(name: string): table|nil, string|nil Runtime data of one child session (`main`, `keymaps_off`, `require`), `nil, why` when the child could not run.
---@field notes string[] Facts collected while running (they end up in `report.problems`, prefixed `note:`).
---@field missing_noted? boolean The missing dependencies of `.testing.lua` were noted.

-- #####################################################################
-- report

---@class Testing.Conformance.CheckResult
---@field id string
---@field title string
---@field kind Testing.Conformance.Kind
---@field rules string[]
---@field status Testing.Conformance.Status
---@field reason? string
---@field findings Testing.Conformance.Finding[]
---@field notes string[]
---@field rule_status? table<string, { status: string, count: integer }>
---@field data? table
---@field duration_ms? integer Only with `timings = true` (it makes the report non-deterministic).

---@class Testing.Conformance.ManualRule
---@field id string
---@field title string
---@field gate string `NEW_PROJECT`, `REVIEW`, `RELEASE`.
---@field severity string `critical`, `recommended`, `nice-to-have`.
---@field status "manual"
---@field reason string
---@field source? string `testing` or `rules.nvim`.

---@class Testing.Conformance.Report
---@field schema_version integer
---@field tool string
---@field root string `<REPO>`.
---@field name string Directory name of the repository.
---@field plugin? string
---@field mode "report"|"gate"
---@field checks Testing.Conformance.CheckResult[]
---@field manual Testing.Conformance.ManualRule[]
---@field summary table
---@field problems string[] Configuration problems (a waiver without a reason, an unknown check id).
---@field config_error? string `.testing.lua` could not be used at all (the defaults were used): exit code 2.
---@field bridge? table The rules.nvim bridge result.
---@field verdict "pass"|"warn"|"fail"|"error"

return {}
