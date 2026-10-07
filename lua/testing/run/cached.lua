---@module 'testing.run.cached'
-- @cache-allow env
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
---@field project_key? string `cache.project_key` of the run when the cache was prepared (names the cache folder, see `M.finish`).
---@field why_off? string Why a requested cache is not used.
---@field ctx? Testing.Cache.Ctx
---@field run_files Testing.Discover.File[] What the driver gets (the files that did not hit).
---@field hits table<string, Testing.Cache.Case[]> Spec file -> its cached cases.
---@field keys table<string, string> Spec file -> key (files that run and can be stored).
---@field infos table<string, Testing.Cache.FileInfo> Spec file -> what the key was computed from (the key is computed again after the run).
---@field uncacheable table<string, string> Spec file -> why it has no key.
---@field details table<string, Testing.Cache.Detail> Spec file -> why it has no key, in a form a program can read.
---@field parts table<string, string[]> Spec file -> the lines its key is the hash of (kept in the stored entry).
---@field allow_flip table<string, boolean> Spec file -> declares `-- @cache-allow nondeterministic`.
---@field audits table<string, Testing.Run.CacheAudit> Spec file -> a cache hit that runs anyway (`--cache-audit`).
---@field audit? { rate: number, audited: integer, stale: integer, skipped: integer } The audit of this run (nil: none asked for).
---@field findings Testing.Run.CacheFinding[] `cache.stale_pass` findings of the audit.
---@field nondeterministic table<string, string[]> Spec file -> the results its key has given (key flip).
---@field keylog? Testing.KeyLog Key-flip memory of this run.
---@field notes? string[] What the driver prints as notes before the run (an unusable key-flip memory).
---@field stored integer
---@field not_stored table<string, integer> Reason -> files.
---@field files Testing.Discover.File[] Every selected file, in run order.

---A cache hit that runs anyway, to be compared with the stored result.
---@class Testing.Run.CacheAudit
---@field key string
---@field stored Testing.Cache.Case[]
---@field parts? string[]

---@class Testing.Run.CacheFinding
---@field code "cache.stale_pass"
---@field file string
---@field key string
---@field message string
---@field parts? string[]

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
  local audit = args.cache_audit ~= nil
  local explicit = args.cache == true or args.cache_refresh == true or audit
  if config_cached and in_ci and not explicit then
    -- the same rule as for --affected: a default is never what decides in CI
    config_cached = false
  end
  local mode = cache.resolve_mode({
    cached = args.cache or audit or nil,
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

---@class Testing.Run.KeyInputs
---@field ctx Testing.Cache.Ctx
---@field info_of fun(f: Testing.Discover.File): Testing.Cache.FileInfo

---The part of the environment a CHILD editor sees from this process, as key lines `NAME=sha256(value)` (sorted).
---It is what `testing.child.environment` builds, minus what the driver sets itself: the allowlist of
---`testing.child.env` over the parent's environment (the project's `env_allow` included), and, while the run is
---deterministic (the default), without `LANG`, `LANGUAGE`, `LC_*` and `TZ`: the child gets fixed values instead of the
---parent's (`apply_determinism`), so no value of the parent can reach it and a machine with another locale keeps its
---hits. Every other variable a child receives stays: it can read it, and its value is part of the key. The sandbox
---variables (`XDG_*`, `TEMP`, ...) are the driver's own and not the parent's.
---@param environ table<string, string> The environment of this process (`vim.fn.environ()`).
---@param run_opts { env_allow?: string[], determinism?: boolean }
---@return string[] lines
function M.child_env_lines(environ, run_opts)
  local env_mod = require("testing.child.env")
  local sane = env_mod.sanitize(environ, { allow = run_opts.env_allow }).env
  local deterministic = run_opts.determinism ~= false
  if deterministic then
    env_mod.apply_determinism(sane)
  end
  local names = vim.tbl_keys(sane)
  table.sort(names)
  local lines = {}
  for _, name in ipairs(names) do
    lines[#lines + 1] = name .. "=" .. vim.fn.sha256(tostring(sane[name]))
  end
  -- the mode is part of the lines: a run with and one without determinism never share a key
  lines[#lines + 1] = "#determinism=" .. tostring(deterministic)
  return lines
end

---What a key is computed from, for a run: the context (configuration, environment names, spec roots, ...) and the
---function that turns a discovered file into the `file_info` of `testing.cache.key`. ONE place, used by the run
---(`M.prepare`) and by `testing explain`, so that the explanation can never be about another key than the run's.
---@param plan Testing.Cli.RunPlan
---@param run_opts Testing.Run.Options
---@param o { mode: "use"|"refresh"|"off", cache_dir?: string, seed?: integer, environ?: table<string, string> }
---@return Testing.Run.KeyInputs
function M.key_inputs(plan, run_opts, o)
  local args = plan.args
  ---@type Testing.Cache.Ctx
  local ctx = {
    root = plan.root,
    mode = o.mode,
    cache_dir = o.cache_dir,
    config_digest = config_digest(plan, run_opts),
    env_names = run_opts.env_allow,
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
  -- the environment a CHILD editor sees (`M.child_env_lines`): a file that runs in a child is keyed by all of it,
  -- so no variable it reads is a hidden input
  local child_env = M.child_env_lines(o.environ or vim.fn.environ(), run_opts)
  local project_cfg = require("testing.config.project")
  -- what `isolated_for` reads of the configuration: how the files run
  local isolation = { isolated = run_opts.isolated }
  ---@cast isolation Testing.ProjectConfig
  return {
    ctx = ctx,
    info_of = function(f)
      local extra = { minit }
      if f.harness then
        extra[#extra + 1] = f.harness
      end
      local in_child = project_cfg.isolated_for(isolation, f.dialect) ~= "none"
      return {
        file = f.rel,
        dialect = f.dialect,
        extra = extra,
        child_env = in_child and child_env or nil,
      }
    end,
  }
end

---Does the audit re-run this hit? A fraction picks by a hash of the key (and a salt), so a run is reproducible.
---@param rate number
---@param key string
---@param salt string
---@return boolean
function M.audit_picks(rate, key, salt)
  if rate <= 0 then
    return false
  end
  if rate >= 1 then
    return true
  end
  local h = tonumber(vim.fn.sha256(key .. "|" .. salt):sub(1, 8), 16) or 0
  return h / 4294967296 < rate
end

---Most findings of `--cache-audit` the IR and the terminal list (the count of all of them is always given).
---@type integer
M.MAX_FINDINGS = 20

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
---@field state_dir? string Replaces `stdpath('state')` (the key-flip memory).
---@field audit_salt? string Varies which hits a fractional `--cache-audit` picks (default: the clock; specs fix it).

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
    details = {},
    parts = {},
    allow_flip = {},
    audits = {},
    findings = {},
    nondeterministic = {},
    stored = 0,
    not_stored = {},
    files = o.files,
    -- the folder of the cache is named by `cache.project_key` of THIS run (the CLI set it before the run started): a
    -- spec that calls `cli.main` for another project changes the global while the files run, and the results must
    -- still be stored where the next run looks
    project_key = require("testing.cache.store").project_key,
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

  local inputs =
    M.key_inputs(plan, o.run_opts, { mode = mode, cache_dir = o.cache_dir, seed = o.seed })
  prep.ctx = inputs.ctx
  -- key flip: a key that gave different results before is not cached (`testing.cache.keylog`)
  local keylog = require("testing.cache.keylog").load(plan.root, { state_dir = o.state_dir })
  prep.keylog = keylog
  -- a corrupt `keys.json` is an empty log: the flip detection is blind until it is rewritten, and that is said
  prep.notes = vim.list_extend({}, keylog.notes)
  prep.ctx.flipped = function(file, key)
    return keylog:flipped(file, key)
  end
  if args.cache_audit ~= nil and mode == "use" then
    prep.audit = { rate = args.cache_audit, audited = 0, stale = 0, skipped = 0 }
  end
  local salt = o.audit_salt or tostring(vim.uv.hrtime())
  local run_files = {}
  for _, f in ipairs(o.files) do
    if with_finding[f.rel] then
      prep.uncacheable[f.rel] = "the discovery has a finding for this file"
      run_files[#run_files + 1] = f
    else
      local info = inputs.info_of(f)
      local key, why, parts, detail = cache.key(info, prep.ctx)
      if not key then
        prep.uncacheable[f.rel] = why or "no key"
        prep.details[f.rel] = detail
        if detail and detail.kind == "nondeterministic" then
          prep.nondeterministic[f.rel] = detail.classes
        end
        local skipped = cache.counters.skipped
        skipped[why or "no key"] = (skipped[why or "no key"] or 0) + 1
        run_files[#run_files + 1] = f
      else
        prep.allow_flip[f.rel] = detail and detail.allow_nondeterministic or false
        local cases
        if mode == "use" then
          cases = cache.get(key, { root = plan.root, cache_dir = o.cache_dir, file = f.rel })
        end
        if cases and prep.audit and M.audit_picks(prep.audit.rate, key, salt) then
          -- a sampled hit: it runs anyway, and the result is compared with the stored one
          prep.audits[f.rel] = { key = key, stored = cases, parts = parts }
          prep.infos[f.rel] = info
          run_files[#run_files + 1] = f
        elseif cases then
          prep.hits[f.rel] = cases
        else
          prep.keys[f.rel] = key
          prep.parts[f.rel] = parts
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
---@param opts? { cache?: table, cache_dir?: string, root: string, state_dir?: string }
---@return Testing.Inproc.Report report
function M.finish(prep, report, opts)
  local store = require("testing.cache.store")
  local saved = store.project_key
  store.project_key = prep.project_key
  local ok, res = pcall(M.finish_inner, prep, report, opts)
  store.project_key = saved
  if not ok then
    error(res, 0)
  end
  return res
end

---@param prep Testing.Run.CachePrep
---@param report Testing.Inproc.Report
---@param opts? { cache?: table, cache_dir?: string, root: string, state_dir?: string }
---@return Testing.Inproc.Report report
function M.finish_inner(prep, report, opts)
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

  -- a prep built by hand (a spec) may lack what `prepare` fills in
  prep.audits = prep.audits or {}
  prep.findings = prep.findings or {}
  prep.parts = prep.parts or {}
  prep.allow_flip = prep.allow_flip or {}
  prep.nondeterministic = prep.nondeterministic or {}
  local keylog = prep.keylog
  local run_id = res.run.id
  local now = os.time()
  local nondeterministic = 0
  ---@param rel string
  ---@param key string
  ---@param frag Testing.Result.Case[]|nil
  ---@return string[]|nil classes The different results the key has given, when this run makes it flip.
  local function observe(rel, key, frag)
    local class = keylog and require("testing.cache.keylog").class_of(frag)
    if not (keylog and class) then
      return nil
    end
    local flip = keylog:observe(rel, key, class, run_id, now)
    return flip and flip.classes or nil
  end

  -- the audit: a sampled hit ran anyway; the stored result must be the one a run gives. Not after a stopped run
  -- (a file may have lost cases to the stop).
  local base_root = prep.ctx and prep.ctx.root or opts.root
  for rel, a in pairs(prep.audits) do
    local frag = ran[rel]
    if report.stopped or not frag then
      prep.audit.skipped = prep.audit.skipped + 1
    else
      prep.audit.audited = prep.audit.audited + 1
      local same, how = M.same_result(a.stored, frag)
      if not same then
        prep.audit.stale = prep.audit.stale + 1
        prep.findings[#prep.findings + 1] = {
          code = "cache.stale_pass",
          file = rel,
          key = a.key,
          message = ("%s: the stored result differs from a fresh run under the SAME key (%s). Either an input the key cannot see changed (a file read by a computed path, a clock or a process of a module), or the spec is not deterministic (flaky). `testing explain %s` lists the key lines"):format(
            rel,
            how,
            rel
          ),
          parts = a.parts,
        }
        -- what is stored for this file cannot be trusted: it goes, and nothing new is written for it
        cache.discard(a.key, { root = base_root, cache_dir = opts.cache_dir })
      end
      observe(rel, a.key, frag)
    end
  end

  -- store what ran green; never after a stopped run (a file may have lost cases to the stop)
  if not report.stopped then
    -- ONE fresh memo for the whole pass: the files are looked at again after the run (the memo of the start of the
    -- run is stale by definition), but a closure of 600 files is read once, not once per stored spec
    local fresh_ctx = prep.ctx and vim.tbl_extend("force", prep.ctx, { memo = {}, flipped = false })
      or nil
    for rel, key in pairs(prep.keys) do
      local frag = ran[rel]
      -- the key was computed BEFORE the run: an input that was edited while the run was going (an editor that
      -- saves, a formatter, a checkout) would store the result for the new content under the old key
      local again = fresh_ctx and prep.infos[rel] and cache.key(prep.infos[rel], fresh_ctx)
      if frag and again ~= key then
        local reason = "an input changed while the run was going"
        prep.not_stored[reason] = (prep.not_stored[reason] or 0) + 1
      elseif frag then
        -- key flip: this key has given another result before (or now): not cached unless the spec says so
        local flip = observe(rel, key, frag)
        if flip and not prep.allow_flip[rel] then
          prep.nondeterministic[rel] = flip
          nondeterministic = nondeterministic + 1
          cache.discard(key, { root = base_root, cache_dir = opts.cache_dir })
          local reason = "nondeterministic: the same key gave different results"
          prep.not_stored[reason] = (prep.not_stored[reason] or 0) + 1
        else
          local ok, why = cache.put(key, frag, {
            file = rel,
            run = res.run.id,
            parts = prep.parts[rel],
            -- a file with a case that failed and then passed on a retry (`--retry-failed`) is never stored
            flaky = report.flaky_files and report.flaky_files[rel] or nil,
          }, { root = base_root, cache_dir = opts.cache_dir })
          if ok then
            prep.stored = prep.stored + 1
          else
            local reason = tostring(why or "not stored")
            prep.not_stored[reason] = (prep.not_stored[reason] or 0) + 1
          end
        end
      end
    end
  end
  if keylog then
    local kok, kerr = keylog:save()
    if not kok then
      report.notes = report.notes or {}
      report.notes[#report.notes + 1] = "the key-flip memory could not be written: "
        .. tostring(kerr)
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
  if nondeterministic > 0 then
    res.run.cache.nondeterministic = nondeterministic
  end
  local audit = prep.audit
  if audit and audit.rate > 0 then
    res.run.cache.audit_rate = audit.rate
    res.run.cache.audited = audit.audited
    res.run.cache.audit_skipped = audit.skipped
    res.run.cache.stale_pass = audit.stale
    res.run.cache.stale_pass_rate = audit.audited > 0 and (audit.stale / audit.audited) or 0
    local findings = {}
    for i, fd in ipairs(prep.findings) do
      if i > M.MAX_FINDINGS then
        break
      end
      local parts = fd.parts and vim.list_slice(fd.parts, 1, 300) or nil
      findings[#findings + 1] =
        { code = fd.code, file = fd.file, key = fd.key, message = fd.message, parts = parts }
    end
    if #findings > 0 then
      res.run.cache.findings = findings
      -- the list is cut (an IR with 300 key lines per finding must stay small), the count is not
      res.run.cache.findings_total = #prep.findings
    end
    -- the audit verdict: a deviation is a failure of the run, whatever the cases say
    if audit.stale > 0 and report.exit_code == 0 then
      report.exit_code = 1
    end
  end
  return report
end

---The stored result of a file and a fresh one: the same cases with the same statuses?
---@param stored Testing.Result.Case[]
---@param fresh Testing.Result.Case[]
---@return boolean same
---@return string how What differs (empty when nothing).
function M.same_result(stored, fresh)
  local want = {}
  for _, c in ipairs(stored) do
    want[c.id] = c.status
  end
  local got = {}
  for _, c in ipairs(fresh) do
    got[c.id] = c.status
  end
  local notes = {}
  for id, st in pairs(got) do
    if want[id] == nil then
      notes[#notes + 1] = ("case '%s' is new"):format(id)
    elseif want[id] ~= st then
      notes[#notes + 1] = ("case '%s' was %s, is %s"):format(id, want[id], st)
    end
  end
  for id in pairs(want) do
    if got[id] == nil then
      notes[#notes + 1] = ("case '%s' did not run"):format(id)
    end
  end
  if #notes == 0 then
    return true, ""
  end
  table.sort(notes)
  local shown = vim.list_slice(notes, 1, 3)
  if #notes > 3 then
    shown[#shown + 1] = ("%d more"):format(#notes - 3)
  end
  return false, table.concat(shown, "; ")
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
  prep.nondeterministic = prep.nondeterministic or {}
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
  local audit = prep.audit
  if audit and audit.rate > 0 then
    -- every hit is one of: ran again (audited), meant to run again but did not give a result (skipped: the run
    -- stopped, or the file lost its cases), or not picked; the denominator names all of them
    local total = audit.audited + audit.skipped + vim.tbl_count(prep.hits)
    line = line
      .. ("; audit: %d of %d hit(s) ran again%s, %d differ (stale-pass rate %.1f%%)"):format(
        audit.audited,
        total,
        audit.skipped > 0
            and (" (%d picked but skipped: the run stopped or the file gave no result)"):format(
              audit.skipped
            )
          or "",
        audit.stale,
        audit.audited > 0 and (100 * audit.stale / audit.audited) or 0
      )
  end
  local nflip = vim.tbl_count(prep.nondeterministic)
  if nflip > 0 then
    line = line .. ("; %d nondeterministic (same key, different result: not cached)"):format(nflip)
  end
  if next(prep.not_stored) ~= nil then
    line = line .. ("; not stored: %s"):format(top_reasons(prep.not_stored, 2))
  end
  return line .. ". --no-cache runs everything."
end

---The findings of the audit as lines for the terminal: each names the file, what differs and the first key lines.
---@param prep Testing.Run.CachePrep
---@return string[]
function M.audit_lines(prep)
  local lines = {}
  for i, fd in ipairs(prep.findings) do
    if i > M.MAX_FINDINGS then
      lines[#lines + 1] = ("... %d more finding(s) of --cache-audit (the first %d are listed; --json has the count)"):format(
        #prep.findings - M.MAX_FINDINGS,
        M.MAX_FINDINGS
      )
      break
    end
    lines[#lines + 1] = ("%s %s"):format(fd.code, fd.message)
    local parts = fd.parts or {}
    for k = 1, math.min(#parts, 8) do
      lines[#lines + 1] = "  key part: " .. parts[k]
    end
    if #parts > 8 then
      lines[#lines + 1] = ("  ... %d more key part(s)"):format(#parts - 8)
    end
  end
  return lines
end

---@class Testing.Run.AffectedSeams
---@field affected? table Replaces `testing.affected`.
---@field getenv? fun(name: string): string|nil Environment lookup (CI detection).
---@field run? function Git runner.
---@field provider? any Replaces `documentation.testing.affected_specs` (`false`: never ask).
---@field cache_dir? string Replaces `stdpath("cache")` for the analysis index of the selection (the run passes its own `cache_dir`).

---@class Testing.Run.AffectedResult
---@field files Testing.Discover.File[] The selected files that are affected (order kept).
---@field notes string[] Lines for stderr.
---@field label string What selected, for the "partial run" line (`--changed`, `--since <rev>`, `--affected`).
---@field result Testing.Affected.Result
---@field cross string[] Lines about the consumers of `--consumers` (empty without it): what to print, not what to run.

---The directory with the checkouts of the consumers, as an absolute path: `--consumers <dir>` (relative to
---the working directory, where the person typed it) or `affected.consumers` of `.testing.lua` (relative to
---the project root). The CALLER names it: this runner does not know where the other repositories are.
---@param plan Testing.Cli.RunPlan
---@return string|nil
function M.consumers_dir(plan)
  local given = plan.args.consumers
  local base
  if given == nil then
    local cfg = plan.project.affected
    given = cfg and cfg.consumers or nil
    base = plan.root
  end
  if given == nil then
    return nil
  end
  local path = given
  if base and not (path:match("^%a:[/\\]") or path:match("^[/\\]")) then
    path = base .. "/" .. path
  end
  path = vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
  return (vim.fs.normalize(path):gsub("/+$", ""))
end

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
    consumers = M.consumers_dir(plan),
    mode = mode,
    since = since,
    roots = plan.project.roots,
    implicit = false,
    getenv = over.getenv,
    run = over.run,
    provider = over.provider,
    -- `--no-cache` means the whole cache directory, the analysis index (`index.json`) included
    no_cache = plan.args.no_cache == true,
    cache_dir = over.cache_dir,
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
  return {
    files = kept,
    notes = notes,
    label = label,
    result = r,
    cross = affected.cross_lines and affected.cross_lines(r) or {},
  },
    nil
end

return M
