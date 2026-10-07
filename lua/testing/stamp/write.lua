---@module 'testing.stamp.write'
-- @cache-env TESTING_STAMP_SECRET
---@brief `testing stamp`: after a COMPLETE green run, write the stamp.
---@description
--- `testing stamp [<root>] [--out <file>] [--note] [run options]` is a run (every option of a run applies: the key
--- depends on them) that, when its verdict is `green` (`verdict.kind == "green"`: no selection, nothing skipped,
--- nothing stopped, no flaky case accepted, no `cache.stale_pass`), writes the stamp. For any other verdict nothing
--- is written and the exit code is 1: the caller asked for a stamp and does not get one. The options that make a run
--- partial (`--changed`, `--filter`, a path, `--maxfail`, ...) are refused up front with exit code 2.
---
--- The stamp goes to `--out`, by default into the state directory of the project (never into the checkout, where
--- it would make the tree dirty). `--note` also attaches it to the tree object as a git note under
--- `refs/notes/testing`. With `TESTING_STAMP_SECRET` set (at least 16 characters) an HMAC is added; the secret
--- itself is never written or printed.

local stamp = require("testing.stamp")

local M = {}

---An option that makes the run less than a full run cannot give a stamp.
---@param args Testing.Args
---@return string|nil problem
function M.refuse(args)
  local function no(flag)
    return ("`stamp` needs a full run: %s selects part of the suite or changes what is run"):format(
      flag
    )
  end
  if args.changed then
    return no("--changed")
  end
  if args.since then
    return no("--since")
  end
  if args.affected then
    return no("--affected")
  end
  if #args.filter > 0 then
    return no("--filter")
  end
  if #args.file > 0 then
    return no("--file")
  end
  if #args.tags > 0 then
    return no("--tags")
  end
  if #args.exclude_tags > 0 then
    return no("--exclude-tags")
  end
  if args.lf then
    return no("--lf")
  end
  if args.shard then
    return no("--shard")
  end
  if args.maxfail then
    return no("--maxfail")
  end
  if args.list then
    return no("--list")
  end
  if args.watch then
    return no("--watch")
  end
  if #args.paths > 0 then
    return no("a path argument")
  end
  if args.shuffle then
    return "`stamp` cannot use --shuffle: the seed is part of every key, so a later `verify` could never match"
  end
  return nil
end

---Is the secret of the environment usable? A set but short secret is refused, never silently ignored.
---@param getenv fun(name: string): string|nil
---@return string|nil secret
---@return string|nil problem
function M.secret(getenv)
  local s = getenv(stamp.SECRET_ENV)
  if s == nil or s == "" then
    return nil, nil
  end
  if #s < stamp.MIN_SECRET then
    return nil,
      ("%s is set but shorter than %d characters: refused (a short secret protects nothing)"):format(
        stamp.SECRET_ENV,
        stamp.MIN_SECRET
      )
  end
  return s, nil
end

---@class Testing.Stamp.BeforeRun
---@field plan Testing.Cli.RunPlan
---@field sv Testing.Run.Services
---@field run_opts Testing.Run.Options
---@field ordered Testing.Discover.File[]
---@field disc table

---What a stamp is about, taken BEFORE a spec runs.
---@class Testing.Stamp.Before
---@field records? Testing.Stamp.Current[]
---@field env? Testing.Stamp.Env
---@field facts? Testing.Stamp.GitFacts
---@field frozen? Testing.Stamp.Frozen The process state the keys read (runtime path, environment, `package.path`).
---@field error? string Why nothing could be taken.

---Take the inputs of the run: the keys of every spec file, the environment and the git facts. A stamp describes the
---inputs the specs were GIVEN. Keys computed after the run would describe whatever the files are by then: an editor
---that saves, a formatter or a spec that rewrites a source during the run would make a stamp for content that never
---ran, and `verify` would call that tree proven. Never raises (the stamp is refused later, with the reason).
---@param o Testing.Stamp.BeforeRun
---@return Testing.Stamp.Before
function M.before_run(o)
  local collect = require("testing.stamp.collect")
  local seam = (o.sv --[[@as table]]).stamp or {}
  local frozen = collect.freeze()
  local ok, records, env = pcall(collect.records, o.plan, o.sv, o.run_opts, o.ordered, o.disc)
  if not ok then
    return { error = tostring(records) }
  end
  local gok, facts = pcall(collect.git_facts, o.plan.root, seam.run)
  if not gok then
    return { error = tostring(facts) }
  end
  -- the key lines are for the details of a changed file in `verify`; they would only sit in memory during the run
  for _, r in ipairs(records) do
    r.parts = nil
  end
  return { records = records, env = env, facts = facts, frozen = frozen }
end

---What the stamp lists, given the keys of before and after the run. A file whose key differs is a file whose inputs
---changed while it ran (`moved`). The one difference that is no change of an input: the run itself made the key
---`nondeterministic` (it gave a result another run did not; `testing.cache.keylog`); that file is listed as not
---provable, as it always was.
---@param before Testing.Stamp.Current[]
---@param after Testing.Stamp.Current[]
---@return Testing.Stamp.Current[] records
---@return string[] moved Files whose inputs differ after the run, in byte order.
function M.reconcile(before, after)
  local now = {}
  for _, r in ipairs(after) do
    now[r.file] = r
  end
  local records, moved, seen = {}, {}, {}
  for _, r in ipairs(before) do
    seen[r.file] = true
    local n = now[r.file]
    if n and n.key == r.key and n.uncacheable == r.uncacheable then
      records[#records + 1] = r
    elseif n and r.key and n.uncacheable and n.kind == "nondeterministic" then
      records[#records + 1] = n
    else
      moved[#moved + 1] = r.file
      records[#records + 1] = r
    end
  end
  for _, r in ipairs(after) do
    if not seen[r.file] then
      moved[#moved + 1] = r.file
    end
  end
  table.sort(moved, function(a, b)
    return stamp.bytecmp(a, b) < 0
  end)
  return records, moved
end

---@class Testing.Stamp.AfterRun
---@field plan Testing.Cli.RunPlan
---@field sv Testing.Run.Services
---@field run_opts Testing.Run.Options
---@field ordered Testing.Discover.File[]
---@field disc table
---@field pre? Testing.Stamp.Before What `M.before_run` took before the run.
---@field res Testing.Result
---@field verdict Testing.Verdict
---@field err fun(s: string)

---Write the stamp of a finished run, if the run earned one.
---@param o Testing.Stamp.AfterRun
---@return boolean written
function M.after_run(o)
  local plan, sv, err = o.plan, o.sv, o.err
  local own = plan.stamp or {}
  local seam = (sv --[[@as table]]).stamp or {}
  local getenv = seam.getenv or vim.uv.os_getenv
  local project = require("testing.run.project")
  local v = o.verdict
  if v.kind ~= "green" then
    local why = v.kind == "red" and "the run is red"
      or ("the run is not a complete green run: %s"):format(table.concat(v.reasons or {}, "; "))
    err(project.safe_line("testing: stamp: not written: " .. why))
    return false
  end
  local run_cache = o.res.run and o.res.run.cache
  if run_cache and (run_cache.stale_pass or 0) > 0 then
    err("testing: stamp: not written: the cache audit found a stale pass in this run")
    return false
  end
  local secret, problem = M.secret(getenv)
  if problem then
    err("testing: stamp: not written: " .. problem)
    return false
  end

  local collect = require("testing.stamp.collect")
  local pre = o.pre
  if not (pre and pre.records and pre.env and pre.facts) then
    err(
      project.safe_line(
        "testing: stamp: not written: the inputs of the run could not be recorded before it: "
          .. tostring(pre and pre.error or "not taken")
      )
    )
    return false
  end
  if #pre.records == 0 then
    err("testing: stamp: not written: the project has no spec file")
    return false
  end
  -- the keys of AFTER the run, to see whether an input moved under the specs: the stamp keeps the keys of before
  -- with the runtime path, the environment and `package.path` of before the run: a spec of an in-process run may change
  -- those (they are no input that moved), and only a file can make the keys differ
  local after_records, after_env =
    collect.records(plan, sv, o.run_opts, o.ordered, o.disc, pre.frozen)
  local records, moved = M.reconcile(pre.records, after_records)
  if #moved > 0 then
    local names = {}
    for i, f in ipairs(moved) do
      if i > 5 then
        names[#names + 1] = ("... and %d more"):format(#moved - 5)
        break
      end
      names[#names + 1] = f
    end
    err(
      project.safe_line(
        ("testing: stamp: not written: an input changed while the run was going (%s). The suite ran against the earlier content: run it again"):format(
          table.concat(names, ", ")
        )
      )
    )
    return false
  end
  local env = pre.env
  if not vim.deep_equal(env, after_env) then
    err(
      "testing: stamp: not written: the runner, Neovim or the configuration changed while the run was going"
    )
    return false
  end
  local facts = pre.facts
  local after_facts = collect.git_facts(plan.root, seam.run)
  if
    after_facts.git ~= facts.git
    or after_facts.commit ~= facts.commit
    or after_facts.tree ~= facts.tree
  then
    err(
      "testing: stamp: not written: the checkout (commit or tree) changed while the run was going: the stamp would describe another state than the one the keys are about"
    )
    return false
  end
  -- what the specs left in the tree (or the editor changed) counts: the stamp does not claim a clean tree then
  local dirty = (facts.git and (facts.dirty or after_facts.dirty)) or nil
  local keyed = 0
  for _, r in ipairs(records) do
    keyed = keyed + (r.key and 1 or 0)
  end
  local st = stamp.build({
    head = {
      commit = facts.commit,
      tree = facts.tree,
      dirty = dirty,
      run = o.res.run.id,
      ts = seam.now or os.time(),
      summary = {
        files = #records,
        keyed = keyed,
        cases = #o.res.cases,
        cached = v.files.cached,
        ran = v.files.ran,
      },
    },
    origin = stamp.origin(getenv),
    env = env,
    records = records,
    secret = secret,
  })
  local text, eerr = stamp.encode(st)
  if not text then
    err("testing: stamp: not written: cannot encode the stamp: " .. tostring(eerr))
    return false
  end
  local path = own.out and vim.fs.normalize(vim.fn.fnamemodify(own.out, ":p"))
    or stamp.path(plan.root, { state_dir = sv.state_dir })
  local ok, werr = require("lib.nvim.fs.write.atomic")(path, text .. "\n", { mkdirp = true })
  if not ok then
    err(project.safe_line("testing: stamp: not written: " .. tostring(werr)))
    return false
  end
  err(
    project.safe_line(
      ("testing: stamp: written %s (%d files, %d with a key, %d not provable; digest %s%s)"):format(
        path,
        #records,
        keyed,
        #records - keyed,
        st.digest:sub(1, 12),
        st.hmac and ", HMAC" or ""
      )
    )
  )
  if keyed < #records then
    err(
      ("testing: stamp: note: %d file(s) have no cache key; `testing verify` can never prove them, it will say `partial`"):format(
        #records - keyed
      )
    )
  end
  if own.note then
    local nok, nerr = collect.note_write(plan.root, facts.tree or "", path, seam.run)
    if nok then
      err(
        "testing: stamp: attached to tree "
          .. (facts.tree or "?"):sub(1, 12)
          .. " as git note refs/notes/testing"
      )
    else
      err(project.safe_line("testing: stamp: note not written: " .. tostring(nerr)))
      return false
    end
  end
  return true
end

return M
