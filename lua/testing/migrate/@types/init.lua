---@meta
---@module 'testing.migrate.@types'

-- #####################################################################
-- migrate/analyze.lua

---@class Testing.Migrate.SpecFile
---@field rel string Path relative to the root.
---@field dialect string `a`, `b`, `c`, `d`, `h`, `busted`, `testing` or `unknown`.
---@field origin? string `root` or `legacy`.
---@field harness? string Relative path of the project harness the file runs on (dialect `h`).
---@field symlink? boolean

---@class Testing.Migrate.Specs
---@field total integer
---@field by_dialect table<string, integer>
---@field files Testing.Migrate.SpecFile[]
---@field legacy string[] Legacy places that hold specs (NEW-48).
---@field under_lua string[] Spec-named files below `lua/` (NEW-48).

---@class Testing.Migrate.Finding
---@field kind string
---@field severity string
---@field path? string
---@field message string

---@class Testing.Migrate.Harness
---@field file? string `TESTS/harness.lua` when it exists.
---@field run_lua boolean `TESTS/run.lua` exists.
---@field listed string[] Spec names in the order `TESTS/run.lua` lists them.
---@field sentinel? string The green-run line the old runner prints.
---@field collects_failures boolean The harness records failures itself instead of raising `FAIL ...`.
---@field fail_convention boolean The harness raises errors that start with `FAIL`.

---@class Testing.Migrate.CiWorkflow
---@field rel string
---@field jobs Testing.Migrate.CiJobInfo[]
---@field parse_error? string

---@class Testing.Migrate.Dep
---@field name string Directory name of the repository.
---@field kind "fleet"|"external"
---@field note string `fleet repository` or `external, not in fleet`.
---@field modules string[] Modules of it that are required (at most 6).
---@field transitive boolean Needed by a dependency, not by the repository itself.

---@class Testing.Migrate.Deps
---@field list Testing.Migrate.Dep[] Hard dependencies: go to `deps` of `.testing.lua`.
---@field optional Testing.Migrate.Dep[] Only required behind `pcall`.
---@field unresolved table<string, integer> Top-level module -> count of requires nobody provides.
---@field ambiguous table<string, string[]> Module -> several fleet repositories.
---@field declared_only string[] Named by the old runner but never required.

---@class Testing.Migrate.Report
---@field root string Absolute, forward slashes.
---@field name string Directory name.
---@field error? string Set when the root cannot be analysed.
---@field is_self? boolean The repository is testing.nvim itself.
---@field origin? string URL of `origin` from `.git/config`.
---@field third_party? boolean `origin` belongs to another owner: not a migration target.
---@field plugin? string Lua module root.
---@field specs Testing.Migrate.Specs
---@field findings Testing.Migrate.Finding[]
---@field harness Testing.Migrate.Harness
---@field dot_testing boolean `.testing.lua` exists.
---@field test_sh { exists: boolean, migrated: boolean, plenary: boolean }
---@field minimal_init { exists: boolean, plenary_lines: Testing.Migrate.PlenaryLine[] }
---@field legacy_init? { rel: string, legacy: boolean, blocks: Testing.Migrate.InitBlock[] } `scripts/minimal_init.lua` when it exists; `legacy`: it belongs to the old runner (mentions it, or a workflow / script starts it).
---@field cleanup { files: Testing.Migrate.CleanupFile[], specs: { total: integer, samples: { rel: string, lnum: integer, text: string }[] } } Prose that still talks about the old runner.
---@field makefile? { plenary: boolean }
---@field ci { workflows: Testing.Migrate.CiWorkflow[] }
---@field runner { plenary_dirs: string[], scripts_invoked: string[], scripts_no_suffix?: string[], unmappable?: string[], runner_dirs?: string[] }
---@field plenary { beyond_runner: { module: string, file: string, soft: boolean }[], needed: boolean, keep_ci: boolean }
---@field fleet { root: string, repos: integer }
---@field deps Testing.Migrate.Deps
---@field policy { isolated: string, isolated_reason: string, host?: string, assertions: string, assertions_reason: string, timeouts?: { case_ms: integer } }
---@field env { allow: string[], secrets: string[] } Environment names the specs read: proposed for `env_allow`, and credential-like ones (not proposed).
---@field risks string[]
---@field texts table<string, string|nil> The files that were read (the plan edits exactly these bytes). Not part of the JSON form.

-- #####################################################################
-- migrate/plan.lua

---@class Testing.Migrate.Op
---@field path string Relative to the root, forward slashes.
---@field action "create"|"modify"|"delete"
---@field kind "config"|"script"|"minit"|"ci"
---@field before? string Text that was read (nil for a create).
---@field after? string Complete new text (nil for a delete).
---@field diff string Unified diff, `a/<path>` to `b/<path>`.
---@field removed string[] Lines of `before` that are gone in `after`.
---@field exec? boolean Mode 0755.
---@field reason string
---@field changes? string[] CI: one line per edit.

---@class Testing.Migrate.Analysis
---@field specs_total integer
---@field by_dialect table<string, integer>
---@field own_harness boolean
---@field run_lua boolean
---@field sentinel? string
---@field plenary_lines integer Plenary lines the plan removes.
---@field deps string[]
---@field optional_deps string[]
---@field ci string[] One line per workflow.
---@field policy table

---@class Testing.Migrate.Plan
---@field root string
---@field name string
---@field ops Testing.Migrate.Op[]
---@field notes string[] Manual work and facts.
---@field risks string[]
---@field empty boolean No operation: the repository is migrated.
---@field error? string The root could not be analysed.
---@field skipped? string Why the repository is not a migration target.
---@field config? table The values written to `.testing.lua`.
---@field analysis? Testing.Migrate.Analysis

-- #####################################################################
-- migrate/apply.lua

---@class Testing.Migrate.PlanOpts
---@field owner? string GitHub owner of the fleet repositories the CI checks out (default `StefanBartl`).
---@field format? Testing.Migrate.FormatOpts Seam for the stylua call (default: the `stylua` on PATH).

---@class Testing.Migrate.RenderOpts
---@field format? "markdown"|"text" Default markdown.

---@class Testing.Migrate.MainOpts
---@field is_dirty? fun(root: string): boolean|nil, string|nil Seam for specs (default: git).
---@field cwd? string Root when the arguments name none (default: the working directory).

---@class Testing.Migrate.ApplyOpts
---@field apply? boolean Must be `true`: the default is a dry run that writes nothing.
---@field is_dirty? fun(root: string): boolean|nil, string|nil Seam for specs (default: `git status --porcelain` through lib.nvim.git).

---@class Testing.Migrate.ApplyResult
---@field applied string[] Paths written.
---@field deleted string[] Paths deleted.
---@field errors string[] Why nothing (or not everything) was written.

return {}
