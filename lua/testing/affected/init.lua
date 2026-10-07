---@module 'testing.affected'
---@brief Affected selection (F2): which spec files can a change reach? Never fewer than needed.
---@description
--- `select(opts)` takes the changed files (`git diff --name-only <base>` plus untracked files, argv
--- only, see `testing.affected.git`) and the spec files of the project, and returns the specs to
--- run with a reason for each.
---
--- GRAPH. The input graph is the documentation.nvim contract (`docs/testing-contract.md` there), soft-required:
---
---   require("documentation.testing").affected_specs({ root = ..., changed = { ... }, spec_roots = { ... } })
---     -> { version, specs = { rel... },
---          modules = { { id, module, path, role = "changed"|"dependent", specs }... },
---          unplaced_specs = { rel... }, ignored = { rel... }, complete = bool,
---          graph = { generated_at, commit, stale = bool, dirty, gaps = { { kind, path, module, reason }... } } }
---       | nil, err
---
--- `specs` are the specs that reach the changed files, `modules` the nodes the changed files map to (and
--- the nodes that depend on them), `unplaced_specs` the specs the graph cannot place ("run these too"),
--- `complete` whether a narrowed selection may be trusted. When the module is absent, or fails, or answers
--- something that is not that shape, the built-in conservative heuristic (`testing.affected.heuristic`) is
--- used and the result says so (`source`).
---
--- THE GRAPH ONLY ADDS. The graph cannot see a `require` built from a variable, a spec that names a file by
--- path, or a spec outside the directories it scans; the heuristic sees those. The selection is therefore
--- the union of what the heuristic reaches and what the graph names (plus its `unplaced_specs`): a graph
--- can make the selection bigger, never smaller.
---
--- RULES (A.15): this can omit cases when the graph is incomplete, therefore
---   * a stale graph (`graph.stale`), a graph that says `complete = false`, a graph that names a spec that
---     does not exist, and a changed file the graph does not know (`unknown`) select ALL specs, with the
---     reason named;
---   * git failing (not a repository, unknown revision, git missing) selects ALL specs;
---   * in CI (`CI`, `GITHUB_ACTIONS`, ...) an IMPLICIT use (`opts.implicit`: affected chosen by a
---     default or a configuration, not by the person at the keyboard) selects ALL specs; an explicit
---     use runs but warns. `--affected` is never the default in CI;
---   * specs that start a process (their code under test is invisible to any graph) are added whenever
---     a module changed.
---
--- Cross-repo (a change in lib.nvim selecting the specs of its consumers) is NOT done here: a changed
--- file of another checkout is not a changed file of this project. It needs `core/consumers.lua`
--- (documentation.nvim) in the contract.

local heuristic = require("testing.affected.heuristic")

local M = {}

---Environment names that mean "a CI service runs this".
---@type string[]
M.CI_ENV = {
  "CI",
  "GITHUB_ACTIONS",
  "GITLAB_CI",
  "BUILDKITE",
  "TF_BUILD",
  "JENKINS_URL",
  "CIRCLECI",
  "TRAVIS",
  "APPVEYOR",
  "TEAMCITY_VERSION",
  "DRONE",
}

---Does the environment look like CI?
---@param getenv? fun(name: string): string|nil
---@return boolean
function M.in_ci(getenv)
  getenv = getenv or vim.uv.os_getenv
  for _, name in ipairs(M.CI_ENV) do
    local v = getenv(name)
    if v and v ~= "" and v ~= "0" and v:lower() ~= "false" then
      return true
    end
  end
  return false
end

---@class Testing.Affected.Flags
---@field changed? boolean `--changed`
---@field since? string `--since <rev>`
---@field affected? boolean|string `--affected [rev]` (`true` without a revision)

---The selection mode of the command-line flags. `--changed` is the working tree against HEAD,
---`--since <rev>` is the working tree against a revision, `--affected [rev]` is `HEAD~1` by default
---(a developer tool). Giving more than one of them is an error, not a guess.
---@param flags Testing.Affected.Flags
---@return "changed"|"since"|"affected"|nil mode `nil` when no flag asks for a selection.
---@return string|nil since
---@return string|nil err
function M.mode_from_flags(flags)
  local asked = {}
  if flags.changed then
    asked[#asked + 1] = "--changed"
  end
  if flags.since ~= nil then
    asked[#asked + 1] = "--since"
  end
  if flags.affected then
    asked[#asked + 1] = "--affected"
  end
  if #asked > 1 then
    return nil, nil, table.concat(asked, " and ") .. " exclude each other"
  end
  if flags.changed then
    return "changed"
  end
  if flags.since ~= nil then
    local ok, why = require("testing.affected.git").valid_ref(flags.since)
    if not ok then
      return nil, nil, "--since: " .. tostring(why)
    end
    return "since", flags.since
  end
  if flags.affected then
    local given = flags.affected
    if type(given) == "string" then
      local ok, why = require("testing.affected.git").valid_ref(given)
      if not ok then
        return nil, nil, "--affected: " .. tostring(why)
      end
      return "affected", given
    end
    return "affected", nil
  end
  return nil
end

---@class Testing.Affected.Opts
---@field root string Project root (absolute).
---@field specs string[] Every spec file of the project, relative to the root (what discovery found).
---@field mode? "changed"|"since"|"affected" Default `changed`.
---@field since? string Revision for `since`; for `affected` default `HEAD~1`.
---@field changed? string[] Changed files (relative); skips git (specs, watch mode).
---@field implicit? boolean Affected was not asked for by the person (a default, a config key).
---@field roots? string[] Spec roots of the project (relative); passed to the provider, and the heuristic takes a support file as an input of every spec below its root.
---@field provider? false|fun(args: table): table|nil, string|nil Replaces `require("documentation.testing").affected_specs`; `false` = never ask.
---@field getenv? fun(name: string): string|nil Environment lookup (CI detection).
---@field run? fun(argv: string[], cwd: string): Testing.Affected.GitResult Git runner (specs).
---@field ignore? string[] Changed paths that never affect a spec (default `heuristic.DEFAULT_IGNORE`).
---@field read? fun(path: string): string|nil, string|nil File reader of the heuristic (specs).
---@field analyze? fun(path: string): Testing.Scan.Info|nil Replaces the analysis cache of the heuristic (default: the hash index of `testing.cache`, so an unchanged file is not read again).
---@field cache_dir? string Replaces `stdpath('cache')` for that index (specs).
---@field no_cache? boolean `--no-cache`: the analysis index on disk is neither read nor written (every file is read and analysed again).

---@class Testing.Affected.Result
---@field files string[] Selected specs, in the order of `opts.specs`.
---@field reason table<string, string> Spec -> why it is selected.
---@field unknown string[] Changed files nobody could place.
---@field all boolean Everything was selected because the selection cannot be trusted.
---@field all_reason? string Why (when `all`).
---@field source "graph"|"heuristic"|"none" Where the answer comes from.
---@field changed string[] The changed files that were looked at.
---@field warnings string[]
---@field ci boolean CI was detected.
---@field graph? table The `graph` metadata the provider returned.

---@param specs string[]
---@param why string
---@param extra table
---@return Testing.Affected.Result
local function select_all(specs, why, extra)
  local reason = {}
  for _, s in ipairs(specs) do
    reason[s] = "all: " .. why
  end
  return vim.tbl_extend("force", {
    files = vim.deepcopy(specs),
    reason = reason,
    unknown = {},
    all = true,
    all_reason = why,
    source = "none",
    changed = {},
    warnings = {},
    ci = false,
  }, extra)
end

---Is `v` a list of strings?
---@param v any
---@return boolean
local function strings(v)
  if type(v) ~= "table" then
    return false
  end
  for k, s in pairs(v) do
    if type(k) ~= "number" or type(s) ~= "string" then
      return false
    end
  end
  return true
end

---Is `v` a list of tables whose `fields` (when present) are strings?
---@param v any
---@param fields string[]
---@return boolean
local function records(v, fields)
  if type(v) ~= "table" then
    return false
  end
  for k, item in pairs(v) do
    if type(k) ~= "number" or type(item) ~= "table" then
      return false
    end
    for _, f in ipairs(fields) do
      if item[f] ~= nil and type(item[f]) ~= "string" then
        return false
      end
    end
  end
  return true
end

---Check the answer of the provider; returns the cleaned answer or nil and why.
---@param res any
---@return table|nil
---@return string|nil why
local function valid_answer(res)
  if type(res) ~= "table" then
    return nil, "no table"
  end
  if not strings(res.specs) then
    return nil, "specs must be a list of strings"
  end
  if res.modules ~= nil and not records(res.modules, { "module", "path", "role" }) then
    return nil, "modules must be a list of tables (module, path, role)"
  end
  if res.unplaced_specs ~= nil and not strings(res.unplaced_specs) then
    return nil, "unplaced_specs must be a list of strings"
  end
  if res.ignored ~= nil and not strings(res.ignored) then
    return nil, "ignored must be a list of strings"
  end
  if type(res.complete) ~= "boolean" then
    return nil, "complete is missing"
  end
  local g = res.graph
  if type(g) ~= "table" or type(g.stale) ~= "boolean" then
    return nil, "graph.stale is missing"
  end
  if g.gaps ~= nil and not records(g.gaps, { "kind", "path", "module" }) then
    return nil, "graph.gaps must be a list of tables (kind, path, module)"
  end
  return res
end

---Is `res` an answer in the shape of the documentation.nvim contract? (specs: the recorded real answers.)
---@param res any
---@return table|nil clean
---@return string|nil why
function M.check_answer(res)
  return valid_answer(res)
end

---Ask documentation.nvim. Returns the answer, or nil with the reason the graph was not used.
---@param opts Testing.Affected.Opts
---@param changed string[]
---@return table|nil answer
---@return string|nil why
local function ask_graph(opts, changed)
  if opts.provider == false then
    return nil, "graph disabled"
  end
  local fn = opts.provider or nil
  if fn == nil then
    local ok, mod = pcall(require, "documentation.testing")
    if not ok or type(mod) ~= "table" or type(mod.affected_specs) ~= "function" then
      return nil, "documentation.nvim is not available"
    end
    fn = mod.affected_specs
  end
  local ok, res, err = pcall(fn, {
    root = opts.root,
    changed = vim.deepcopy(changed),
    spec_roots = opts.roots and vim.deepcopy(opts.roots) or nil,
  })
  if not ok then
    return nil, "documentation.testing.affected_specs failed: " .. tostring(res)
  end
  if res == nil then
    return nil, "documentation.nvim gave no answer: " .. tostring(err)
  end
  local clean, why = valid_answer(res)
  if not clean then
    return nil, "documentation.nvim answered an unknown shape: " .. tostring(why)
  end
  return clean
end

---Select the specs a change can reach.
---@param opts Testing.Affected.Opts
---@return Testing.Affected.Result
function M.select(opts)
  local specs = opts.specs or {}
  local ci = M.in_ci(opts.getenv)
  local warnings = {}
  local base = { ci = ci, warnings = warnings }
  if ci and opts.implicit then
    return select_all(specs, "CI: --affected is never the default, the whole suite runs here", base)
  end
  if ci then
    warnings[#warnings + 1] =
      "affected selection in CI can omit cases when the graph is incomplete: prefer the full run there"
  end

  -- 1. the changed files
  local changed = opts.changed
  ---@type string[]
  local unsafe = {}
  if changed == nil then
    local err, bad
    changed, err, bad = require("testing.affected.git").changed(opts.root, {
      mode = opts.mode or "changed",
      since = opts.since,
      run = opts.run,
      ignored_dirs = vim.list_extend({ "lua" }, vim.deepcopy(opts.roots or {})),
    })
    if not changed then
      return select_all(specs, "git cannot tell what changed: " .. tostring(err), base)
    end
    unsafe = bad or {}
  end
  base.changed = changed
  if #unsafe > 0 then
    return select_all(
      specs,
      ("git reported %d path(s) that cannot be trusted (%s)"):format(
        #unsafe,
        (unsafe[1]:gsub("%c", "?"))
      ),
      vim.tbl_extend("force", base, { unknown = unsafe })
    )
  end

  local cls = heuristic.classify(
    changed,
    specs,
    { root = opts.root, ignore = opts.ignore, roots = opts.roots }
  )
  if #cls.unknown > 0 then
    local first = cls.unknown[1]
    return select_all(
      specs,
      ("%d changed file(s) cannot be placed (%s: %s)"):format(#cls.unknown, first, cls.why[first]),
      vim.tbl_extend("force", base, { unknown = cls.unknown })
    )
  end

  local reason, source, graph = nil, "heuristic", nil
  local analyze = opts.analyze
  local cache_mod
  if not analyze and not opts.read and not opts.no_cache then
    local okc, mod = pcall(require, "testing.cache")
    if okc then
      cache_mod = mod
      analyze = mod.analyzer({ root = opts.root, cache_dir = opts.cache_dir })
    end
  end

  -- 2. the documentation.nvim graph, when there is something it has to answer
  if next(cls.modules) ~= nil then
    local changed_modules = {}
    for _, file in pairs(cls.modules) do
      changed_modules[#changed_modules + 1] = file
    end
    table.sort(changed_modules)
    local answer, why = ask_graph(opts, changed_modules)
    if answer then
      graph = answer.graph
      if graph.stale then
        return select_all(
          specs,
          ("the module graph is stale (generated %s at %s)"):format(
            tostring(graph.generated_at),
            tostring(graph.commit)
          ),
          vim.tbl_extend("force", base, { graph = graph, source = "graph" })
        )
      end
      if not answer.complete then
        local kinds, seen_kind = {}, {}
        for _, g in ipairs(graph.gaps or {}) do
          if g.kind and not seen_kind[g.kind] then
            seen_kind[g.kind] = true
            kinds[#kinds + 1] = g.kind
          end
        end
        table.sort(kinds)
        return select_all(
          specs,
          ("the module graph says its answer is incomplete (%s)"):format(
            #kinds > 0 and table.concat(kinds, ", ") or "no reason given"
          ),
          vim.tbl_extend("force", base, { graph = graph, source = "graph" })
        )
      end
      -- every changed module file has to be placed by the graph: a node, a named gap, or an ignored file
      local known_path, known_module = {}, {}
      for _, m in ipairs(answer.modules or {}) do
        if m.path then
          -- a package node is named by its directory: its file is `<path>/init.lua` (or `<path>.lua`)
          known_path[m.path] = true
          known_path[m.path .. "/init.lua"] = true
          known_path[m.path .. ".lua"] = true
        end
        if m.module then
          known_module[m.module] = true
        end
      end
      for _, g in ipairs(graph.gaps or {}) do
        if g.path then
          known_path[g.path] = true
        end
      end
      for _, p in ipairs(answer.ignored or {}) do
        known_path[p] = true
      end
      local unknown = {}
      for mod, file in pairs(cls.modules) do
        if not (known_path[file] or known_module[mod]) then
          unknown[#unknown + 1] = file
        end
      end
      table.sort(unknown)
      if #unknown > 0 then
        return select_all(
          specs,
          ("the module graph does not know %s (incomplete)"):format(unknown[1]),
          vim.tbl_extend("force", base, { unknown = unknown, graph = graph, source = "graph" })
        )
      end
      local spec_set = {}
      for _, s in ipairs(specs) do
        spec_set[s] = true
      end
      -- what the graph cannot see comes from the heuristic: the graph only ADDS to it
      reason = heuristic.reach(cls, specs, {
        root = opts.root,
        read = opts.read,
        analyze = analyze,
        roots = opts.roots,
      })
      local named = {}
      for _, s in ipairs(answer.specs) do
        named[#named + 1] = { rel = s, why = "reaches a changed module (documentation graph)" }
      end
      for _, s in ipairs(answer.unplaced_specs or {}) do
        named[#named + 1] =
          { rel = s, why = "the graph cannot place it: run it too (documentation graph)" }
      end
      for _, n in ipairs(named) do
        local rel = n.rel:gsub("\\", "/")
        if spec_set[rel] then
          reason[rel] = reason[rel] or n.why
        elseif vim.uv.fs_stat(opts.root .. "/" .. rel) == nil then
          return select_all(
            specs,
            ("the module graph names a spec that does not exist (%s): out of date"):format(rel),
            vim.tbl_extend("force", base, { graph = graph, source = "graph" })
          )
        else
          -- a spec the project does not run (outside its roots or its pattern): nothing to select
          warnings[#warnings + 1] = ("the module graph names %s, which this project does not run"):format(
            rel
          )
        end
      end
      source = "graph"
    elseif opts.provider ~= false then
      warnings[#warnings + 1] = "module graph not used: "
        .. tostring(why)
        .. " (built-in heuristic)"
    end
  end

  -- 3. the built-in heuristic (also the only source when no module changed)
  if not reason then
    reason = heuristic.reach(cls, specs, {
      root = opts.root,
      read = opts.read,
      analyze = analyze,
      roots = opts.roots,
    })
  end

  if cache_mod then
    pcall(cache_mod.flush) -- the analysis index is a convenience: a failing write costs time only
  end
  local files = {}
  for _, s in ipairs(specs) do
    if reason[s] then
      files[#files + 1] = s
    end
  end
  local out_reason = {}
  for _, s in ipairs(files) do
    out_reason[s] = reason[s]
  end
  return {
    files = files,
    reason = out_reason,
    unknown = {},
    all = false,
    source = (#changed == 0 and "none") or source,
    changed = changed,
    warnings = warnings,
    ci = ci,
    graph = graph,
  }
end

---@class Testing.Affected.FreshOpts
---@field run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@field map? string Path of the module map relative to the root (default `docs/map/module_map.json`).

---@class Testing.Affected.Freshness
---@field status "ok"|"stale"|"missing"|"unknown"
---@field message string
---@field map_mtime? integer
---@field commit_time? integer

---Is `docs/map/module_map.json` at least as new as the last commit that changed code? (`testing doctor`.)
---A map older than that commit, or older than an uncommitted change of a Lua file, describes code that
---no longer exists: `--affected` would trust it, so the doctor warns.
---@param root string
---@param opts? Testing.Affected.FreshOpts
---@return Testing.Affected.Freshness
function M.graph_freshness(root, opts)
  opts = opts or {}
  local map = opts.map or "docs/map/module_map.json"
  local st = vim.uv.fs_stat(root .. "/" .. map)
  if not st then
    return {
      status = "missing",
      message = map .. " does not exist: --affected uses the built-in heuristic",
    }
  end
  local git = require("testing.affected.git")
  local commit_time = git.last_commit_time(root, "docs/map", opts.run)
  local mtime = st.mtime and st.mtime.sec or 0
  if not commit_time then
    return {
      status = "unknown",
      message = "cannot read the last commit time (not a git checkout?)",
      map_mtime = mtime,
    }
  end
  if mtime < commit_time then
    return {
      status = "stale",
      message = ("%s is older than the last commit (%s < %s): regenerate it before using --affected"):format(
        map,
        os.date("!%Y-%m-%dT%H:%M:%SZ", mtime),
        os.date("!%Y-%m-%dT%H:%M:%SZ", commit_time)
      ),
      map_mtime = mtime,
      commit_time = commit_time,
    }
  end
  local changed = git.changed(root, { mode = "changed", run = opts.run })
  for _, f in ipairs(changed or {}) do
    if f:match("%.lua$") and f:match("^lua/") then
      local fst = vim.uv.fs_stat(root .. "/" .. f)
      if fst and fst.mtime and fst.mtime.sec > mtime then
        return {
          status = "stale",
          message = ("%s is older than the uncommitted change of %s: regenerate it"):format(map, f),
          map_mtime = mtime,
          commit_time = commit_time,
        }
      end
    end
  end
  return {
    status = "ok",
    message = map .. " is newer than the last commit",
    map_mtime = mtime,
    commit_time = commit_time,
  }
end

return M
