---@module 'testing.run.options'
---@brief The run options of the isolation layer, read from ONE place: `plan.project` and `plan.args`.
---@description
--- Per-file isolation is configured by keys of `.testing.lua` and by command-line flags. Both are
--- read here and nowhere else, with safe defaults for a key that is absent, so the rest of the run
--- code asks `options.of(plan)` and never `plan.project.<key>`:
---
---   isolated      "auto" | "none" | "file" | "case" | "soft"   `--isolated`; `.testing.lua` `isolated`.
---                                   "auto" (the default) = per dialect, resolved by
---                                   `config.project.isolated_for`: busted files "file" (plenary ran
---                                   one editor per file), the one-case-per-file dialects "none". "case"
---                                   = a child per case (busted; other dialects run as "file", with a
---                                   note). "soft" = this process, what a file changed is restored
---                                   before the next file (`testing.isolation`). A dialect `script`
---                                   always runs in a child.
---   soft_keep     string[]          `soft_keep`: modules "soft" never unloads (name or `prefix*`).
---   guards        table             `guards` + `--guard name=mode`: mode per guard ("off"|"warn"|"error";
---                                   `clock` boolean). Read by `M.guard_config`, the ONE adapter the guard
---                                   layer (`testing.guard`) gets its configuration from.
---   guard_allow   table             `guard_allow` + `--allow-fs/--allow-spawn/--allow-network`.
---   pool          table             `pool` + `--pool-size/--pool-reuse`: `{ size, reuse }` (warm pool).
---   determinism   boolean           `determinism` (`--no-determinism` turns it off): fixed LANG/TZ in a child.
---   trace         boolean           `trace` (`--no-trace` turns it off): trace artifact of a dead child.
---   strict        boolean           `--strict`.
---   jobs          integer >= 1      `--jobs`; `jobs`. Children running at once (default 1).
---   host          "c" | "l"         `--host`; `host`. Default "c" (plenary-like `-c` startup).
---   filetype      boolean           `filetype`. `filetype plugin indent on` in the child (default true).
---   disable_first_run boolean       `disable_first_run` (default true). Every editor the runner starts gets
---                                   `vim.g.lib_nvim_deps_disable_first_run = true` before the project's
---                                   minit (`M.apply_first_run_default`).
---   assertions    "error" | "warn"  `assertions`. "warn": a case that asserts nothing passes with a
---                                   recorded warning instead of failing (migration of old repos).
---   env_allow     string[]          `env_allow` + `--env-allow`: extra environment names a child may
---                                   inherit (`testing.child.env`).
---
--- `assertions` travels to the dialects (`opts.assertions` of `dialect.run_file`, `testing.policy`) in
--- both modes, in-process and isolated (the child gets it in its job), so it is one rule with one
--- implementation.

local M = {}

---@class Testing.Run.Options
---@field isolated "auto"|"none"|"file"|"case"|"soft"
---@field soft_keep string[]
---@field guards table<string, string|boolean> Mode per guard (`clock`: boolean).
---@field guard_allow { fs: string[], spawn: string[], network: string[] }
---@field pool { size: integer, reuse: boolean }
---@field determinism boolean
---@field trace boolean
---@field strict boolean
---@field jobs integer
---@field host "c"|"l"
---@field host_given boolean `--host` was passed (a `script` file otherwise prefers host `l`).
---@field filetype boolean
---@field disable_first_run boolean
---@field assertions "error"|"warn"
---@field env_allow string[]

---@param v any
---@param allowed string[]
---@return string|nil
local function one_of(v, allowed)
  for _, a in ipairs(allowed) do
    if v == a then
      return v
    end
  end
  return nil
end

---Names of the guards and their modes (the data lives in `testing.config.DEFAULTS`).
---@type string[]
M.GUARD_NAMES =
  { "fs", "state", "scheduled_error", "prompt", "deprecation", "process_net", "clock" }

---Strings of a list, in order, nothing else (a hand-built plan may hold garbage).
---@param ... any lists
---@return string[]
local function strings_of(...)
  local out, seen = {}, {}
  for _, list in ipairs({ ... }) do
    if type(list) == "table" then
      for _, v in ipairs(list) do
        if type(v) == "string" and v ~= "" and not seen[v] then
          seen[v] = true
          out[#out + 1] = v
        end
      end
    end
  end
  return out
end

---Modes of the guards: the defaults, the config on top, `--guard name=mode` last. A garbage value
---keeps the layer below it.
---@param cfg table
---@param args table
---@return table<string, string|boolean>
local function guards_of(cfg, args)
  local defaults = require("testing.config.DEFAULTS").project.guards
  local out = {}
  local from_cfg = type(cfg.guards) == "table" and cfg.guards or {}
  for _, name in ipairs(M.GUARD_NAMES) do
    if name == "clock" then
      local v = from_cfg.clock
      out.clock = type(v) == "boolean" and v or defaults.clock
    else
      out[name] = one_of(from_cfg[name], { "off", "warn", "error" }) or defaults[name]
    end
  end
  for _, item in ipairs(args.guard or {}) do
    local name, mode = tostring(item):match("^([%w_%-]+)=(%w+)$")
    name = name and name:gsub("%-", "_")
    if name == "clock" then
      if mode == "on" or mode == "off" then
        out.clock = mode == "on"
      end
    elseif name and defaults[name] ~= nil and one_of(mode, { "off", "warn", "error" }) then
      out[name] = mode
    end
  end
  return out
end

---@param plan { args?: table, project?: table }
---@return Testing.Run.Options
function M.of(plan)
  local args = plan.args or {}
  local cfg = plan.project or {}
  local jobs = args.jobs or cfg.jobs
  if type(jobs) ~= "number" or jobs < 1 then
    jobs = 1
  end
  local allow = {}
  for _, list in ipairs({ cfg.env_allow or {}, args.env_allow or {} }) do
    for _, name in ipairs(list) do
      allow[#allow + 1] = name
    end
  end
  local pool_cfg = type(cfg.pool) == "table" and cfg.pool or {}
  local pool_size = args.pool_size
  if pool_size == nil then
    pool_size = pool_cfg.size
  end
  if type(pool_size) ~= "number" or pool_size < 0 or pool_size > 256 then
    pool_size = 0
  end
  local pool_reuse = args.pool_reuse
  if pool_reuse == nil then
    pool_reuse = pool_cfg.reuse == true
  end
  local allow_cfg = type(cfg.guard_allow) == "table" and cfg.guard_allow or {}
  return {
    isolated = (
      one_of(args.isolated or cfg.isolated, { "auto", "none", "file", "case", "soft" }) or "auto"
    ) --[[@as "auto"|"none"|"file"|"case"|"soft"]],
    soft_keep = strings_of(cfg.soft_keep),
    guards = guards_of(cfg, args),
    guard_allow = {
      fs = strings_of(allow_cfg.fs, args.allow_fs),
      spawn = strings_of(allow_cfg.spawn, args.allow_spawn),
      network = strings_of(allow_cfg.network, args.allow_network),
    },
    pool = { size = math.floor(pool_size), reuse = pool_reuse == true },
    determinism = args.determinism ~= false and cfg.determinism ~= false,
    trace = args.trace ~= false and cfg.trace ~= false,
    strict = args.strict == true,
    jobs = math.floor(jobs),
    host = (one_of(args.host or cfg.host, { "c", "l" }) or "c") --[[@as "c"|"l"]],
    host_given = args.host ~= nil,
    filetype = cfg.filetype ~= false,
    disable_first_run = cfg.disable_first_run ~= false and not args.first_run,
    assertions = (one_of(cfg.assertions, { "error", "warn" }) or "error") --[[@as "error"|"warn"]],
    env_allow = allow,
  }
end

---Name of the lib.nvim global that suppresses the one-time "missing tools" float
---(`lib.nvim.deps.first_run`, read on every `show_once` call).
M.FIRST_RUN_GLOBAL = "lib_nvim_deps_disable_first_run"

---Test-environment default for the editor this runs in: when `enabled` and the user has not decided
---(variable unset), set lib.nvim's first-run opt-out. Returns a function that undoes it (a no-op when
---nothing was set), so an editor that hosts a run is left as it was found.
---@param enabled boolean
---@return fun() restore
function M.apply_first_run_default(enabled)
  if not enabled or vim.g[M.FIRST_RUN_GLOBAL] ~= nil then
    return function() end
  end
  vim.g[M.FIRST_RUN_GLOBAL] = true
  return function()
    vim.g[M.FIRST_RUN_GLOBAL] = nil
  end
end

---How one file runs: in this process, in a child of its own, or (busted, `isolated = "case"`) in a
---child per case.
---@param opts Testing.Run.Options
---@param entry { dialect?: string }
---@return "file"|"case"|"none" mode
---@return string|nil note Set when `case` degraded to `file` (the dialect has one case per file).
function M.isolation_of(opts, entry)
  ---@diagnostic disable-next-line: missing-fields
  local cfg = { isolated = opts.isolated } ---@type Testing.ProjectConfig
  local project = require("testing.config.project")
  local dialect = entry.dialect or "a"
  local mode = project.isolated_for(cfg, dialect)
  local note
  if project.degraded_case(cfg, dialect) then
    note = ("isolated=case degraded to file: a dialect-%s spec file is ONE case, so it gets one child"):format(
      dialect
    )
  end
  return mode, note
end

---Does any of the files need a child?
---@param opts Testing.Run.Options
---@param entries { dialect?: string }[]
---@return boolean
function M.any_isolated(opts, entries)
  for _, e in ipairs(entries) do
    if M.isolation_of(opts, e) ~= "none" then
      return true
    end
  end
  return false
end

---Does the run restore state between the files that run in this process (`isolated = "soft"`)?
---@param opts Testing.Run.Options
---@return boolean
function M.is_soft(opts)
  return opts.isolated == "soft"
end

---@class Testing.Run.GuardConfig
--- What `require("testing.guard").install(cfg)` takes (`testing.guard.config`), JSON-safe: it travels to
--- a child in the job (`guard`). Every mode is `off|warn|error`.
---@field repo? string Project root.
---@field strict boolean `--strict`: the guard layer promotes every `warn` to `error`.
---@field restore boolean Always false: restoring between FILES is the runner's soft isolation (`testing.isolation`), not a per-case restore of the state guard.
---@field guards table<string, table> `{ <guard> = { mode, ... } }`, see below.

---The ONE adapter between the run options and the guard layer: option names in, the layer's
---configuration out. The in-process driver calls it once per run, the isolated driver once per
---child (it travels in the job as `guard`). Pure: a fresh table every time.
---
---   guards.fs              { mode, allow = guard_allow.fs }
---   guards.state           { mode, categories = every category capped at `mode` }
---   guards.scheduled_error { mode }
---   guards.prompt          { mode }
---   guards.deprecation     { mode }
---   guards.process_net     { mode, allow_exec = guard_allow.spawn, allow_hosts = guard_allow.network }
---   guards.clock           { mode = "warn" when `guards.clock`, else "off"; seed }
---
--- Whether the effects ledger is collected while `process_net` is "off" is the guard layer's decision
--- (it installs a guard only for a mode other than "off").
---Severity ranks: a category of the state guard keeps its own default only up to the mode the project
---chose for the guard (`state = "warn"` means no category of it fails a case).
---@type table<string, integer>
local RANK = { off = 0, info = 1, warn = 2, error = 3 }

---The categories of the state guard, each capped at `mode`. Read from the guard layer's own defaults
---(nil when there is none: its defaults then apply as they are).
---@param mode string
---@return table<string, string>|nil
local function state_categories(mode)
  local ok, gcfg = pcall(require, "testing.guard.config")
  local cats = ok
    and type(gcfg) == "table"
    and gcfg.DEFAULTS
    and gcfg.DEFAULTS.guards.state.categories
  if not cats then
    return nil
  end
  local out = {}
  for cat, own in pairs(cats) do
    out[cat] = (RANK[own] or 0) <= (RANK[mode] or 0) and own or mode
  end
  return out
end

---@param opts Testing.Run.Options
---@param ctx? { root?: string, seed?: integer, in_child?: boolean, throwaway?: boolean } `throwaway`: the editor ends with its one case, so the state guard has nothing to protect and is switched off (the effects ledger and the other guards stay).
---@return Testing.Run.GuardConfig
function M.guard_config(opts, ctx)
  ctx = ctx or {}
  local g, allow = opts.guards, opts.guard_allow
  if ctx.throwaway and g.state ~= "off" then
    g = vim.tbl_extend("force", g, { state = "off" })
  end
  return {
    repo = ctx.root,
    strict = opts.strict == true,
    restore = false,
    guards = {
      fs = { mode = g.fs, allow = vim.deepcopy(allow.fs) },
      state = {
        mode = g.state,
        categories = state_categories(g.state --[[@as string]]),
      },
      scheduled_error = { mode = g.scheduled_error },
      prompt = { mode = g.prompt },
      deprecation = { mode = g.deprecation },
      process_net = {
        mode = g.process_net,
        allow_exec = vim.deepcopy(allow.spawn),
        allow_hosts = vim.deepcopy(allow.network),
      },
      clock = { mode = g.clock == true and "warn" or "off", seed = ctx.seed },
    },
  }
end

---Host of a file: a `script` was written for `nvim -l`, so it prefers `l` unless `--host` says otherwise.
---@param opts Testing.Run.Options
---@param entry { dialect?: string }
---@return "c"|"l"
function M.host_of(opts, entry)
  if entry.dialect == "script" and not opts.host_given then
    return "l"
  end
  return opts.host
end

---The runtimepath of a child: this checkout first, then lib.nvim, the project's dependencies, the
---root and the `--rtp` directories, in the order the parent put them on its own, and last the real
---`stdpath('data')/site` (installed parsers, read-only).
---@param plan { root: string, project?: table, args?: table }
---@return string[] prepend
---@return string[] append
---@return table<string, string> env `$<NAME>_DIR` of every dependency the parent resolved, for the child
---  (and for the editors a spec starts from it: `tasks.nvim` finds lib.nvim that way)
function M.child_rtp(plan)
  local deps = require("testing.deps")
  local prepend = { deps.self_dir() }
  local append = {}
  -- the checkout that is running: a project's minit asks for `testing.nvim` like for any dependency
  local env = { [deps.env_name("testing.nvim")] = deps.self_dir() }
  local lib = deps.resolve("lib.nvim", deps.self_dir())
  if lib then
    append[#append + 1] = lib.dir
    env[deps.env_name("lib.nvim")] = lib.dir
  end
  local resolved = deps.resolve_all((plan.project or {}).deps or {}, plan.root)
  for _, r in ipairs(resolved) do
    append[#append + 1] = r.dir
    env[deps.env_name(r.name)] = r.dir
  end
  append[#append + 1] = plan.root
  for _, dir in ipairs((plan.args or {}).rtp or {}) do
    append[#append + 1] = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
  end
  -- READ-ONLY: the real `stdpath('data')/site` holds the installed Tree-sitter parsers and queries
  -- that a plenary run (default runtimepath) finds; the child's own `stdpath('data')` is a sandbox
  -- (nothing is written there), so without this every spec that needs a real grammar would skip.
  local site = vim.fs.normalize(vim.fn.stdpath("data") .. "/site")
  if vim.fn.isdirectory(site) == 1 then
    append[#append + 1] = site
  end
  return prepend, append, env
end

return M
