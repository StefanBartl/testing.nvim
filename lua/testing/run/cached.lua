---@module 'testing.run.cached'
---@brief The result cache (`--cached`) and the affected selection (`--changed`, `--since`, `--affected`) of a run.
---@description
--- `testing.cache` and `testing.affected` know how to decide; this module is where a run asks them, so that
--- all three drivers (in this editor, a child per file, the warm pool) are cached and selected the same way
--- and none of them knows about either.
---
--- CACHE. `M.prepare` computes the key of every selected spec file BEFORE the driver runs; a file with a valid
--- entry is taken out of the list the driver gets (its child is never started), a file without one runs.
--- `M.finish` then puts the cached cases back in file order (marked `cached = true`, with the note
--- `cached from <run id>`, status `pass`), recounts the summary and stores the new green files. A cached case
--- was not executed in this run and therefore never went through the guards or the effects ledger; the report
--- says so (`M.summary_line`, `run.cache` of the IR).
---
--- Honesty rules (the verdict is never greener than a full run would be):
---   * the cache is OFF unless asked for (`--cached`, `--cache-refresh`, or `cache.enabled` in `.testing.lua`,
---     which is ignored in CI); `--no-cache` always wins;
---   * a case selection (`--filter`, `--tags`, `--exclude-tags`, `--lf`) or `--list` turns it off with a note:
---     a file that ran only some of its cases is not the file the entry describes;
---   * `--strict` with discovery findings turns it off (the strict verdict lives in the driver);
---   * a file with a discovery finding is never taken from the cache (its note would be lost);
---   * nothing is stored after a run that was stopped (`--maxfail`) or that hit an infrastructure error;
---   * `testing.cache.put` itself refuses everything that is not a clean pass (see docs/CACHE.md).
---
--- AFFECTED. `M.select_affected` turns the changed files into the spec files that can reach them; the answer
--- never selects fewer files than needed (unknown changes select everything, with the reason named). A run
--- with fewer files than the project has is a PARTIAL run: it prints no sentinel.

local M = {}

---Flags of `.testing.lua` / the command line that make no difference to what a spec does.
---@type string[]
local CONFIG_NOT_IN_KEY = {
  "jobs",
  "shard",
  "watch",
  "budget",
  "cache",
  "conformance",
  "surface",
  "coverage",
  "backends",
}

---@class Testing.Run.CachePrep
---@field mode "use"|"refresh"|"off"
---@field why_off? string Why a requested cache is not used.
---@field ctx? Testing.Cache.Ctx
---@field run_files Testing.Discover.File[] What the driver gets (the files that did not hit).
---@field hits table<string, Testing.Cache.Case[]> Spec file -> its cached cases.
---@field keys table<string, string> Spec file -> key (files that run and can be stored).
---@field infos table<string, Testing.Cache.FileInfo> Spec file -> what the key was computed from (the key is computed again after the run).
---@field uncacheable table<string, string> Spec file -> why it has no key.
---@field stored integer
---@field not_stored table<string, integer> Reason -> files.
---@field files Testing.Discover.File[] Every selected file, in run order.

---The effective configuration that is part of every key: what the project and the command line say about HOW
---a spec runs, without what does not change a result (parallelism, sharding, the watcher).
---@param plan Testing.Cli.RunPlan
---@param run_opts Testing.Run.Options
---@return string digest
local function config_digest(plan, run_opts)
  local project = vim.deepcopy(plan.project)
  for _, k in ipairs(CONFIG_NOT_IN_KEY) do
    project[k] = nil
  end
  local run = vim.deepcopy(run_opts)
  run.jobs = nil
  local args = plan.args
  return vim.fn.sha256(vim.inspect({
    project = project,
    run = run,
    rtp = plan.rtp_dirs,
    case_timeout_ms = args.case_timeout_ms,
    file_timeout_ms = args.file_timeout_ms,
    first_run = args.first_run,
    strict = args.strict,
  }))
end

---Mode of the run from the flags; `why_off` names a reason that switched a requested cache off.
---@param plan Testing.Cli.RunPlan
---@param restricted string|nil Why a case selection makes the cache unusable (nil: none).
---@param getenv? fun(name: string): string|nil
---@return "use"|"refresh"|"off" mode
---@return string|nil why_off
function M.mode_of(plan, restricted, getenv)
  local args, cfg = plan.args, plan.project
  local cache = require("testing.cache")
  local in_ci = require("testing.affected").in_ci(getenv)
  local config_cached = cfg.cache and cfg.cache.enabled == true
  local explicit = args.cache == true or args.cache_refresh == true
  if config_cached and in_ci and not explicit then
    -- the same rule as for --affected: a default is never what decides in CI
    config_cached = false
  end
  local mode = cache.resolve_mode({
    cached = args.cache,
    no_cache = args.no_cache,
    refresh = args.cache_refresh,
    config_cached = config_cached,
  })
  if mode == "off" then
    return "off", nil
  end
  if restricted then
    return "off", restricted
  end
  return mode, nil
end

---Does anything in this run keep the cache from being sound?
---@param plan Testing.Cli.RunPlan
---@param selector table `testing.run.select` selector of the run.
---@param lf any The `--lf` selection (nil without).
---@param findings Testing.Discover.Finding[]
---@return string|nil why
local function restriction(plan, selector, lf, findings)
  local args = plan.args
  if args.list then
    return "--list runs nothing"
  end
  if selector.active or lf ~= nil or args.lf then
    return "a case selection (--filter, --tags, --exclude-tags, --lf) applies: a file would run only part of its cases"
  end
  if args.strict and #findings > 0 then
    return "--strict with discovery findings: the findings are judged by the driver"
  end
  return nil
end

---@class Testing.Run.CachePrepOpts
---@field plan Testing.Cli.RunPlan
---@field run_opts Testing.Run.Options
---@field files Testing.Discover.File[] The selected files, in run order.
---@field selector table
---@field lf any
---@field findings Testing.Discover.Finding[]
---@field seed? integer
---@field cache_dir? string Replaces `stdpath('cache')` (specs).
---@field getenv? fun(name: string): string|nil
---@field cache? table Replaces `testing.cache` (specs).

---Decide, per selected file, what the cache says; returns what the driver has to run.
---@param o Testing.Run.CachePrepOpts
---@return Testing.Run.CachePrep
function M.prepare(o)
  local plan = o.plan
  ---@type Testing.Run.CachePrep
  local prep = {
    mode = "off",
    run_files = o.files,
    hits = {},
    keys = {},
    infos = {},
    uncacheable = {},
    stored = 0,
    not_stored = {},
    files = o.files,
  }
  local restricted = restriction(plan, o.selector, o.lf, o.findings)
  local mode, why_off = M.mode_of(plan, restricted, o.getenv)
  prep.mode = mode
  prep.why_off = why_off
  if mode == "off" then
    return prep
  end
  local cache = o.cache or require("testing.cache")
  local args = plan.args

  local with_finding = {}
  for _, f in ipairs(o.findings) do
    if f.path then
      with_finding[f.path] = true
    end
  end

  prep.ctx = {
    root = plan.root,
    mode = mode,
    cache_dir = o.cache_dir,
    config_digest = config_digest(plan, o.run_opts),
    env_names = o.run_opts.env_allow,
    shuffled = args.shuffle or false,
    seed = o.seed,
    spec_roots = plan.project.roots,
    spec_pattern = plan.project.spec_pattern,
    -- `pcall(require, "optional")` is common and the run's runtime path is the one the key looks at: the
    -- absence of a module is part of the key (and the spec tree joins it, see `testing.cache`)
    unresolved = "absent",
  }
  local minit
  if type(plan.project.minit) == "string" then
    minit = plan.project.minit
  end
  -- the environment a CHILD editor sees is the allowlist of `testing.child.env` over this process's environment:
  -- a file that runs in a child is keyed by all of it, so no variable it reads is a hidden input
  local child_env
  do
    local env_mod = require("testing.child.env")
    local sane = env_mod.sanitize(vim.fn.environ(), { allow = o.run_opts.env_allow }).env
    local names = vim.tbl_keys(sane)
    table.sort(names)
    local lines = {}
    for _, name in ipairs(names) do
      lines[#lines + 1] = name .. "=" .. tostring(sane[name])
    end
    child_env = vim.fn.sha256(table.concat(lines, "\n"))
  end
  local project_cfg = require("testing.config.project")
  -- what `isolated_for` reads of the configuration: how the files run
  local isolation = { isolated = o.run_opts.isolated }
  ---@cast isolation Testing.ProjectConfig
  local run_files = {}
  for _, f in ipairs(o.files) do
    if with_finding[f.rel] then
      prep.uncacheable[f.rel] = "the discovery has a finding for this file"
      run_files[#run_files + 1] = f
    else
      local extra = { minit }
      if f.harness then
        extra[#extra + 1] = f.harness
      end
      local in_child = project_cfg.isolated_for(isolation, f.dialect) ~= "none"
      local info = {
        file = f.rel,
        dialect = f.dialect,
        extra = extra,
        child_env = in_child and child_env or nil,
      }
      local key, why = cache.key(info, prep.ctx)
      if not key then
        prep.uncacheable[f.rel] = why or "no key"
        local skipped = cache.counters.skipped
        skipped[why or "no key"] = (skipped[why or "no key"] or 0) + 1
        run_files[#run_files + 1] = f
      else
        local cases
        if mode == "use" then
          cases = cache.get(key, { root = plan.root, cache_dir = o.cache_dir, file = f.rel })
        end
        if cases then
          prep.hits[f.rel] = cases
        else
          prep.keys[f.rel] = key
          prep.infos[f.rel] = info
          run_files[#run_files + 1] = f
        end
      end
    end
  end
  prep.run_files = run_files
  return prep
end

---The report of a run in which no driver had anything to do (every file was cached).
---@param plan Testing.Cli.RunPlan
---@param seed? integer
---@return Testing.Inproc.Report
function M.empty_report(plan, seed)
  local inproc = require("testing.run.inproc")
  local res = inproc.begin_result(plan.root, { seed = seed, argv = plan.argv, jobs = 1 })
  res.run.duration_ms = 0
  require("testing.core.result").finalize(res)
  return {
    result = res,
    failed = 0,
    failed_files = 0,
    total = 0,
    files_run = 0,
    files_unrun = 0,
    files_unselected = 0,
    skipped = 0,
    stopped = false,
    wall_ms = 0,
    exit_code = 0,
    notes = {},
    unattached = {},
  }
end

---Put the cached cases back in file order, recount, and store what ran green.
---`report` is changed in place.
---@param prep Testing.Run.CachePrep
---@param report Testing.Inproc.Report
---@param opts? { cache?: table, cache_dir?: string, root: string }
---@return Testing.Inproc.Report report
function M.finish(prep, report, opts)
  opts = opts or { root = "" }
  if prep.mode == "off" then
    return report
  end
  local cache = opts.cache or require("testing.cache")
  local result = require("testing.core.result")
  local res = report.result

  local ran = {}
  local others = {}
  local known = {}
  for _, f in ipairs(prep.files) do
    known[f.rel] = true
  end
  for _, c in ipairs(res.cases) do
    if known[c.file] then
      ran[c.file] = ran[c.file] or {}
      table.insert(ran[c.file], c)
    else
      others[#others + 1] = c
    end
  end

  local merged = {}
  local ncached = 0
  for _, f in ipairs(prep.files) do
    local hit = prep.hits[f.rel]
    if hit then
      for _, c in ipairs(hit) do
        merged[#merged + 1] = c
        ncached = ncached + 1
      end
    else
      for _, c in ipairs(ran[f.rel] or {}) do
        merged[#merged + 1] = c
      end
    end
  end
  vim.list_extend(merged, others)
  res.cases = merged
  result.finalize(res)
  report.total = #res.cases
  report.skipped = res.summary.skip
  report.cases_cached = ncached
  report.files_cached = vim.tbl_count(prep.hits)

  -- store what ran green; never after a stopped run (a file may have lost cases to the stop)
  if not report.stopped then
    -- ONE fresh memo for the whole pass: the files are looked at again after the run (the memo of the start of the
    -- run is stale by definition), but a closure of 600 files is read once, not once per stored spec
    local fresh_ctx = prep.ctx and vim.tbl_extend("force", prep.ctx, { memo = {} }) or nil
    for rel, key in pairs(prep.keys) do
      local frag = ran[rel]
      -- the key was computed BEFORE the run: an input that was edited while the run was going (an editor that
      -- saves, a formatter, a checkout) would store the result for the new content under the old key
      local again = fresh_ctx and prep.infos[rel] and cache.key(prep.infos[rel], fresh_ctx)
      if frag and again ~= key then
        local reason = "an input changed while the run was going"
        prep.not_stored[reason] = (prep.not_stored[reason] or 0) + 1
      elseif frag then
        local ok, why = cache.put(key, frag, {
          file = rel,
          run = res.run.id,
        }, { root = prep.ctx and prep.ctx.root or opts.root, cache_dir = opts.cache_dir })
        if ok then
          prep.stored = prep.stored + 1
        else
          local reason = tostring(why or "not stored")
          prep.not_stored[reason] = (prep.not_stored[reason] or 0) + 1
        end
      end
    end
  end
  pcall(cache.flush)

  res.run.cache = {
    mode = prep.mode,
    files_cached = report.files_cached,
    cases_cached = ncached,
    files_ran = #prep.run_files,
    stored = prep.stored,
  }
  return report
end

---The most frequent entries of a reason -> count table, as "n reason, ...".
---@param counts table<string, integer>
---@param limit integer
---@return string
local function top_reasons(counts, limit)
  local rows = {}
  for reason, n in pairs(counts) do
    rows[#rows + 1] = { reason = reason, n = n }
  end
  table.sort(rows, function(a, b)
    if a.n ~= b.n then
      return a.n > b.n
    end
    return a.reason < b.reason
  end)
  local parts = {}
  for i = 1, math.min(limit, #rows) do
    parts[#parts + 1] = ("%d %s"):format(rows[i].n, rows[i].reason)
  end
  if #rows > limit then
    parts[#parts + 1] = ("%d more reason(s)"):format(#rows - limit)
  end
  return table.concat(parts, ", ")
end

---One line for the end of a run: how much came from the cache and why the rest did not.
---@param prep Testing.Run.CachePrep
---@return string|nil line nil when the cache was not in use
function M.summary_line(prep)
  if prep.mode == "off" then
    return nil
  end
  local nhit = vim.tbl_count(prep.hits)
  local nran = #prep.run_files
  local line = ("cache (%s): %d of %d spec file(s) were not run: their results are from earlier green runs; %d ran"):format(
    prep.mode,
    nhit,
    #prep.files,
    nran
  )
  local unc = vim.tbl_count(prep.uncacheable)
  if unc > 0 then
    local counts = {}
    for _, why in pairs(prep.uncacheable) do
      counts[why] = (counts[why] or 0) + 1
    end
    line = line .. ("; not cacheable: %s"):format(top_reasons(counts, 3))
  end
  if prep.stored > 0 then
    line = line .. ("; %d stored"):format(prep.stored)
  end
  if next(prep.not_stored) ~= nil then
    line = line .. ("; not stored: %s"):format(top_reasons(prep.not_stored, 2))
  end
  return line .. ". --no-cache runs everything."
end

---@class Testing.Run.AffectedSeams
---@field affected? table Replaces `testing.affected`.
---@field getenv? fun(name: string): string|nil Environment lookup (CI detection).
---@field run? function Git runner.
---@field provider? any Replaces `documentation.testing.affected_specs` (`false`: never ask).

---@class Testing.Run.AffectedResult
---@field files Testing.Discover.File[] The selected files that are affected (order kept).
---@field notes string[] Lines for stderr.
---@field label string What selected, for the "partial run" line (`--changed`, `--since <rev>`, `--affected`).
---@field result Testing.Affected.Result

---Narrow the selected files to the ones the changes can reach.
---@param plan Testing.Cli.RunPlan
---@param all_files Testing.Discover.File[] Every spec file of the project (the selection is made among these).
---@param files Testing.Discover.File[] The files selected so far.
---@param over? Testing.Run.AffectedSeams
---@return Testing.Run.AffectedResult|nil sel nil when no flag asks for a selection.
---@return string|nil err A flag that is wrong (a revision git must not see).
function M.select_affected(plan, all_files, files, over)
  over = over or {}
  local affected = over.affected or require("testing.affected")
  local mode, since, err = affected.mode_from_flags({
    changed = plan.args.changed,
    since = plan.args.since,
    affected = plan.args.affected,
  })
  if err then
    return nil, err
  end
  if not mode then
    return nil, nil
  end
  local specs = {}
  for _, f in ipairs(all_files) do
    specs[#specs + 1] = f.rel
  end
  local r = affected.select({
    root = plan.root,
    specs = specs,
    mode = mode,
    since = since,
    roots = plan.project.roots,
    implicit = false,
    getenv = over.getenv,
    run = over.run,
    provider = over.provider,
  })
  local chosen = {}
  for _, rel in ipairs(r.files) do
    chosen[rel] = true
  end
  local kept = {}
  for _, f in ipairs(files) do
    if chosen[f.rel] then
      kept[#kept + 1] = f
    end
  end
  local label = mode == "changed" and "--changed"
    or mode == "since" and ("--since " .. tostring(since))
    or ("--affected" .. (since and (" " .. since) or ""))
  local notes = {}
  for _, w in ipairs(r.warnings or {}) do
    notes[#notes + 1] = "affected: " .. w
  end
  if r.all then
    notes[#notes + 1] = ("affected: %s selects EVERY spec file: %s"):format(
      label,
      tostring(r.all_reason)
    )
  else
    notes[#notes + 1] = ("affected: %s selects %d of %d spec file(s) from %d changed file(s) (%s)"):format(
      label,
      #r.files,
      #specs,
      #(r.changed or {}),
      r.source or "?"
    )
  end
  return { files = kept, notes = notes, label = label, result = r }, nil
end

return M
