---@module 'testing.run.options'
---@brief The run options of the isolation layer, read from ONE place: `plan.project` and `plan.args`.
---@description
--- Per-file isolation is configured by keys of `.testing.lua` and by command-line flags. Both are
--- read here and nowhere else, with safe defaults for a key that is absent, so the rest of the run
--- code asks `options.of(plan)` and never `plan.project.<key>`:
---
---   isolated      "auto" | "none" | "file"   `--isolated`; `.testing.lua` `isolated`. "auto" (the
---                                   default) = per dialect, resolved by `config.project.isolated_for`:
---                                   busted files "file" (plenary ran one editor per file), the
---                                   one-case-per-file dialects "none". A dialect `script` always
---                                   runs in a child.
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
---@field isolated "auto"|"none"|"file"
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
  return {
    isolated = (one_of(args.isolated or cfg.isolated, { "auto", "none", "file" }) or "auto") --[[@as "auto"|"none"|"file"]],
    jobs = math.floor(jobs),
    host = (one_of(args.host or cfg.host, { "c", "l" }) or "c") --[[@as "c"|"l"]],
    host_given = args.host ~= nil,
    filetype = cfg.filetype ~= false,
    disable_first_run = cfg.disable_first_run ~= false,
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

---How one file runs.
---@param opts Testing.Run.Options
---@param entry { dialect?: string }
---@return "file"|"none"
function M.isolation_of(opts, entry)
  ---@diagnostic disable-next-line: missing-fields
  local cfg = { isolated = opts.isolated } ---@type Testing.ProjectConfig
  return require("testing.config.project").isolated_for(cfg, entry.dialect or "a")
end

---Does any of the files need a child?
---@param opts Testing.Run.Options
---@param entries { dialect?: string }[]
---@return boolean
function M.any_isolated(opts, entries)
  for _, e in ipairs(entries) do
    if M.isolation_of(opts, e) == "file" then
      return true
    end
  end
  return false
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
