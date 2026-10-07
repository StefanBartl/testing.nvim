---@module 'testing.stamp.write'
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

---@class Testing.Stamp.AfterRun
---@field plan Testing.Cli.RunPlan
---@field sv Testing.Run.Services
---@field run_opts Testing.Run.Options
---@field ordered Testing.Discover.File[]
---@field disc table
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
  local records, env = collect.records(plan, sv, o.run_opts, o.ordered, o.disc)
  if #records == 0 then
    err("testing: stamp: not written: the project has no spec file")
    return false
  end
  local facts = collect.git_facts(plan.root, seam.run)
  local keyed = 0
  for _, r in ipairs(records) do
    keyed = keyed + (r.key and 1 or 0)
  end
  local st = stamp.build({
    head = {
      commit = facts.commit,
      tree = facts.tree,
      dirty = facts.git and facts.dirty or nil,
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
