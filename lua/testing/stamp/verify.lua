---@module 'testing.stamp.verify'
-- @cache-env TESTING_STAMP_SECRET GITHUB_EVENT_NAME GITHUB_REF
---@brief `testing verify`: is the tree still the one a green stamp proved? Answered from the keys, no spec runs.
---@description
--- Reads a stamp (`testing.stamp`, untrusted input), applies the trust, age and dirty-tree rules, recomputes the
--- cache key of every spec file (`testing.stamp.collect`) and compares. The answer is one of
---
---   verified     every file of the stamp has the same key now; exit 0 and the sentinel (the only green answer)
---   partial      nothing changed that a key can see, but some files have no key (clock, process, ...): they are
---                not proven and must run; exit 1, never green; the command to run them is printed
---   changed      a file has another key, is gone or is new; exit 1, with what differs (`testing explain` details)
---   rejected     runner, Neovim, OS or configuration differ from the stamp (the cause is named); exit 1
---   expired      the stamp is older than `--max-age` (default 7 days): run the suite; exit 1
---   dirty        the working tree has uncommitted changes: what is checked is not what would be committed
---                (`--allow-dirty` overrules, explicitly); exit 1
---   untrusted    the stamp does not come from where it must (a local stamp in CI, a CI stamp that was not written
---                on a trusted ref, a missing or wrong HMAC); exit 1
---   invalid      the file is not a usable stamp (size, JSON, schema, types, digest); exit 1
---   no-stamp     there is none to read; exit 1
---
--- Exit 2 is a usage error (an unknown flag, a secret that is too short), 3 an internal failure. Verdict equivalence:
--- the sentinel and exit 0 are printed ONLY for `verified`, where `proven == files`. A partial proof is never green.
---
--- It changes nothing: no cache entry is written, no history is touched.

local stamp = require("testing.stamp")

local M = {}

---@type integer
M.MAX_LIST = 500
---@type integer
M.SHOWN = 15
---Most files a rerun command names (more: the command runs the whole suite).
---@type integer
M.MAX_RERUN_FILES = 25
---Most key lines the terminal text names per changed file, and for all of them together (a closure of hundreds of
---files that moved with a dependency would otherwise print a line each: `testing explain <file>` shows them all).
---@type integer
M.MAX_DETAILS = 8
---@type integer
M.MAX_DETAIL_LINES = 60

---Flags of `verify` that are not options of a run.
---@class Testing.Verify.Own
---@field json boolean
---@field from_note boolean
---@field allow_dirty boolean
---@field require_hmac boolean
---@field allow_unsigned boolean
---@field stamp? string
---@field max_age? integer

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---@param secs integer
---@return string
local function duration(secs)
  if secs % 86400 == 0 then
    return plural(math.floor(secs / 86400), "day")
  elseif secs % 3600 == 0 then
    return plural(math.floor(secs / 3600), "hour")
  end
  return plural(secs, "second")
end

---@param ts integer
---@return string
local function when(ts)
  return os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
end

---A hash or key, cut to the length that tells two apart.
---@param s string
---@return string
local function short(s)
  return #s > 14 and s:sub(1, 12) or s
end

---A fact of the environment (`Neovim`, `OS/architecture`): shown whole, because the part that differs (the build of a
---nightly, the API level) is at the end of the text. Only a hostile stamp makes it long, and then it is cut.
---@param s string
---@return string
local function fact(s)
  return #s > 60 and (s:sub(1, 57) .. "...") or s
end

---The command that runs `files` (or, with too many, the whole suite) with the options of this invocation.
---@param plan Testing.Cli.RunPlan
---@param files string[]
---@return { command: string, files: integer, whole_suite: boolean }|nil
local function rerun_of(plan, files)
  local agent = require("testing.report.agent")
  local argv = vim.deepcopy(plan.argv or {})
  if argv[1] == "verify" then
    table.remove(argv, 1)
  end
  local rest = require("testing.args").repeat_argv(argv)
  if #rest == 0 or rest[1]:sub(1, 1) == "-" then
    table.insert(rest, 1, ".")
  end
  local parts = { agent.DEFAULTS.command }
  for _, a in ipairs(rest) do
    local q = agent.shell_quote(a)
    if not q then
      return nil
    end
    parts[#parts + 1] = q
  end
  local whole = #files > M.MAX_RERUN_FILES
  if not whole then
    for _, f in ipairs(files) do
      local q = agent.shell_quote(f)
      if not q then
        whole = true
        break
      end
      parts[#parts + 1] = "--file " .. q
    end
  end
  if whole then
    -- the files that have a key hit the cache, so `--cached` makes the whole run cost what the rest costs
    parts[#parts + 1] = "--cached"
  end
  return { command = table.concat(parts, " "), files = #files, whole_suite = whole }
end

---@param res table
---@param status string
---@param reason? string
---@return table
local function finish(res, status, reason)
  res.status = status
  res.reason = reason
  res.exit_code = status == "verified" and 0 or 1
  return res
end

---Does `now` lie within the allowed age of the stamp, and is the stamp not from the future?
---@param st Testing.Stamp
---@param now integer
---@param max_age integer
---@return "ok"|"future"|"expired"
local function age_state(st, now, max_age)
  if st.head.ts > now + stamp.FUTURE_SLACK then
    return "future"
  end
  if now - st.head.ts > max_age then
    return "expired"
  end
  return "ok"
end

---Read the text of the stamp: the file, or the note of the current tree.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param own Testing.Verify.Own
---@param get_facts fun(): Testing.Stamp.GitFacts The git facts of the tree (asked once per check).
---@param run? fun(argv: string[], cwd: string): table
---@return string|nil text
---@return string|nil why
---@return string|nil source
---@return "no-stamp"|"invalid"|nil status What a failure is.
local function read_text(plan, sv, own, get_facts, run)
  local collect = require("testing.stamp.collect")
  if own.from_note then
    local facts = get_facts()
    if not facts.tree then
      return nil, "no tree to look a note up for (not a git checkout, or no commit yet)", "note"
    end
    local text, why = collect.note_read(plan.root, facts.tree, run)
    return text, why, "git note refs/notes/testing"
  end
  local path = own.stamp and vim.fs.normalize(vim.fn.fnamemodify(own.stamp, ":p"))
    or stamp.path(plan.root, { state_dir = sv.state_dir })
  local st = vim.uv.fs_stat(path)
  if not st then
    return nil, "no stamp at " .. path .. " (write one with `testing stamp`)", path
  end
  if st.type ~= "file" then
    return nil, path .. " is not a regular file", path, "invalid"
  end
  if st.size > stamp.MAX_BYTES then
    return nil, ("%s is larger than %d bytes"):format(path, stamp.MAX_BYTES), path, "invalid"
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, "cannot read " .. path, path, "invalid"
  end
  return text, nil, path
end

---Answer the question. Never raises for bad input; a stamp that is not usable is a status.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param own Testing.Verify.Own
---@return table result
function M.check(plan, sv, own)
  local seam = (sv --[[@as table]]).stamp or {}
  local getenv = seam.getenv or vim.uv.os_getenv
  local now = seam.now or os.time()
  local run = seam.run
  local res = { notes = {}, causes = {} }

  local secret = getenv(stamp.SECRET_ENV)
  if secret == "" then
    secret = nil
  end
  if secret and #secret < stamp.MIN_SECRET then
    res.usage = ("%s is set but shorter than %d characters: refused (a short secret protects nothing)"):format(
      stamp.SECRET_ENV,
      stamp.MIN_SECRET
    )
    return finish(res, "usage", res.usage)
  end

  -- three git processes: asked once, whichever of the note lookup and the tree comparison needs them first
  local collect = require("testing.stamp.collect")
  local facts_memo
  local function get_facts()
    facts_memo = facts_memo or collect.git_facts(plan.root, run)
    return facts_memo
  end

  local text, why, source, failure = read_text(plan, sv, own, get_facts, run)
  res.source = source
  if not text then
    return finish(res, failure or "no-stamp", why)
  end
  local st, bad = stamp.decode(text)
  if not st then
    return finish(res, "invalid", ("%s is not a usable stamp: %s"):format(tostring(source), bad))
  end
  res.stamp = {
    digest = st.digest,
    run = st.head.run,
    ts = st.head.ts,
    commit = st.head.commit,
    tree = st.head.tree,
    origin = st.origin.kind,
    files = #st.files,
  }

  -- who may have written it
  local in_ci = require("testing.affected").in_ci(getenv)
  local here = in_ci and "ci" or "local"
  if st.origin.kind ~= here then
    return finish(
      res,
      "untrusted",
      ("a %s stamp is not accepted %s: a stamp counts only where it was written"):format(
        st.origin.kind,
        in_ci and "in CI" or "on a developer machine"
      )
    )
  end
  if in_ci and not st.origin.trusted then
    return finish(
      res,
      "untrusted",
      ("the CI stamp was not written on a trusted ref (event %s, ref %s): a pull request, a fork or another branch never counts"):format(
        st.origin.event or "?",
        st.origin.ref or "?"
      )
    )
  end
  if secret then
    if not st.hmac then
      return finish(
        res,
        "untrusted",
        ("%s is set, the stamp carries no HMAC: it may have been written by anyone"):format(
          stamp.SECRET_ENV
        )
      )
    end
    if not stamp.hmac_ok(st, secret) then
      return finish(
        res,
        "untrusted",
        "the HMAC of the stamp does not match (forged, edited, or made under another secret)"
      )
    end
    res.hmac = "checked"
  else
    if own.require_hmac then
      return finish(
        res,
        "untrusted",
        ("--require-hmac needs the secret in %s, which is not set"):format(stamp.SECRET_ENV)
      )
    end
    if in_ci and not own.allow_unsigned then
      -- in CI an unchecked stamp is never green: whoever can write the file can write a "trusted" origin
      return finish(
        res,
        "untrusted",
        ("in CI a stamp is accepted only with its HMAC checked: set %s (at least %d characters) on the stamping and the verifying job, or pass --allow-unsigned to rest on where the file came from"):format(
          stamp.SECRET_ENV,
          stamp.MIN_SECRET
        )
      )
    end
    if st.hmac then
      res.notes[#res.notes + 1] = ("the stamp carries an HMAC that was not checked (%s is not set)"):format(
        stamp.SECRET_ENV
      )
    elseif in_ci then
      res.notes[#res.notes + 1] =
        "authenticity rests on where the stamp file came from (it has no HMAC, --allow-unsigned); see docs/CACHE.md, Stamp"
    end
    res.hmac = "unchecked"
  end

  -- how old
  local max_age = own.max_age or stamp.DEFAULT_MAX_AGE
  local state = age_state(st, now, max_age)
  if state == "future" then
    return finish(
      res,
      "invalid",
      "the stamp is dated in the future: the clocks disagree or the file was made up"
    )
  end
  if state == "expired" then
    local days = math.floor((now - st.head.ts) / 86400)
    return finish(
      res,
      "expired",
      ("the stamp is %s old (limit %s, --max-age): run the suite"):format(
        plural(days, "day"),
        duration(max_age)
      )
    )
  end

  -- the checked tree is the committed one?
  local facts = get_facts()
  res.git = facts
  if not facts.git then
    if st.head.tree or st.head.commit then
      -- the stamp names a commit or tree: without git the claim cannot be compared, so it is never green
      return finish(
        res,
        "rejected",
        "git did not answer here (not a git checkout, or git failed), but the stamp names a commit/tree: whether this tree is the stamped one cannot be checked, so it is not accepted"
      )
    end
    res.notes[#res.notes + 1] =
      "not a git checkout: whether the tree matches a commit cannot be checked"
  elseif facts.dirty then
    if not own.allow_dirty then
      local names = table.concat(facts.changes or {}, ", ")
      return finish(
        res,
        "dirty",
        ("the working tree has %s (%s%s): what is checked is not the committed tree. Commit or stash them, or pass --allow-dirty to check the working tree as it is"):format(
          plural(facts.changed_count or 0, "uncommitted change"),
          names,
          (facts.changed_count or 0) > #(facts.changes or {}) and ", ..." or ""
        )
      )
    end
    res.notes[#res.notes + 1] =
      "the working tree is dirty (--allow-dirty): the answer is about the working tree, not about a commit"
  end
  if facts.tree and st.head.tree then
    res.same_tree = facts.tree == st.head.tree
  end

  -- the keys now, in the environment a run computes them in: after the `minit` of the project, which puts
  -- directories on the runtime path that the keys look at (the minit of a project is run as `testing run` runs it)
  local run_opts = require("testing.run.options").of(plan)
  local discover = sv.discover or require("testing.discover")
  local disc, records, env
  local mok, merr = require("testing.run.project").with_minit(plan, run_opts, function()
    disc = discover.discover(plan.root, {
      roots = plan.project.roots,
      dialect = plan.project.dialect,
      spec_pattern = plan.project.spec_pattern,
    })
    local ordered = discover.order(disc)
    records, env = collect.records(plan, sv, run_opts, ordered, disc)
  end)
  if not mok then
    return finish(
      res,
      "rejected",
      ("%s: the keys of a run are computed after it, so this tree cannot be compared with the stamp"):format(
        tostring(merr)
      )
    )
  end
  res.sentinel = plan.args.sentinel or (disc.runner and disc.runner.sentinel) or "TESTING_OK"

  -- what differs in the world around the keys: named as a cause
  local causes = {}
  local function differ(label, old, new, show)
    if old ~= new then
      causes[#causes + 1] = ("%s: %s -> %s"):format(label, show(old), show(new))
    end
  end
  differ("runner (lua/testing)", st.env.runner, env.runner, short)
  differ("Neovim", st.env.nvim, env.nvim, fact)
  differ("OS/architecture", st.env.os, env.os, fact)
  if st.env.config ~= env.config then
    causes[#causes + 1] =
      "configuration: the options of this invocation or .testing.lua differ from the stamp's (digest changed)"
  end
  if #causes > 0 then
    res.causes = causes
    return finish(
      res,
      "rejected",
      "the stamp was made under other conditions than these; every key would differ: run the suite"
    )
  end

  -- the files
  local have = {}
  for _, r in ipairs(records) do
    have[r.file] = r
  end
  local want = {}
  local changed, unproven, proven = {}, {}, 0
  for _, f in ipairs(st.files) do
    want[f.file] = true
    local cur = have[f.file]
    if not cur then
      changed[#changed + 1] = { file = f.file, change = "gone", old = f.key }
    elseif f.key then
      if cur.key == f.key then
        proven = proven + 1
      elseif cur.key then
        changed[#changed + 1] = {
          file = f.file,
          change = "changed",
          old = f.key,
          new = cur.key,
          parts = cur.parts,
        }
      else
        unproven[#unproven + 1] = {
          file = f.file,
          reason = "no key now: " .. tostring(cur.uncacheable),
          from = "now",
        }
      end
    else
      unproven[#unproven + 1] = { file = f.file, reason = f.uncacheable, from = "stamp" }
    end
  end
  for _, r in ipairs(records) do
    if not want[r.file] then
      changed[#changed + 1] = { file = r.file, change = "new", new = r.key }
    end
  end
  table.sort(changed, function(a, b)
    return stamp.bytecmp(a.file, b.file) < 0
  end)
  res.counts = {
    files = #st.files,
    proven = proven,
    not_provable = #unproven,
    changed = #changed,
  }
  res.changed, res.unproven = changed, unproven

  -- explain details of the changed files: the stored entry of the OLD key carries its key lines
  local cache = sv.cache or require("testing.cache")
  local explain = require("testing.cache.explain")
  for i, c in ipairs(changed) do
    if i > M.SHOWN then
      break
    end
    if c.change == "changed" and c.old and c.parts then
      local ok, entry = pcall(cache.peek, c.old, {
        root = plan.root,
        cache_dir = sv.cache_dir,
        file = c.file,
      })
      if ok and entry and entry.parts then
        c.details = explain.diff(entry.parts, c.parts)
      else
        c.details_why = "no stored entry for the stamped key; `testing explain "
          .. c.file
          .. "` shows the key lines"
      end
    end
  end

  local to_run = {}
  for _, c in ipairs(changed) do
    if c.change ~= "gone" then
      to_run[#to_run + 1] = c.file
    end
  end
  for _, u in ipairs(unproven) do
    to_run[#to_run + 1] = u.file
  end
  table.sort(to_run, function(a, b)
    return stamp.bytecmp(a, b) < 0
  end)
  if #to_run > 0 then
    res.rerun = rerun_of(plan, to_run)
  end

  if #changed > 0 then
    return finish(res, "changed")
  end
  if #unproven > 0 then
    return finish(res, "partial")
  end
  if proven ~= #st.files then
    -- cannot happen (every file is proven, changed or unproven); the one place a green answer could leak
    return finish(res, "partial", "internal: the count of proven files does not match")
  end
  return finish(res, "verified")
end

---Which key lines come first when only some are shown: what changed, then what is new, then what is gone (a
---dependency that went away drags hundreds of `removed` lines with it).
local WEIGHT = { changed = 1, added = 2, removed = 3 }

---@param details { change: string }[]
---@return { change: string }[] sorted A copy; the order of equals is kept.
local function by_weight(details)
  local idx = {}
  for i = 1, #details do
    idx[i] = i
  end
  table.sort(idx, function(a, b)
    local wa, wb = WEIGHT[details[a].change] or 4, WEIGHT[details[b].change] or 4
    if wa ~= wb then
      return wa < wb
    end
    return a < b
  end)
  local out = {}
  for i, k in ipairs(idx) do
    out[i] = details[k]
  end
  return out
end

---The terminal text of a result.
---@param res table
---@return string[]
function M.render(res)
  local lines = {}
  local function add(s)
    lines[#lines + 1] = s
  end
  local st = res.stamp
  local origin = st
      and ("stamp of run %s, %s%s"):format(
        st.run,
        when(st.ts),
        st.commit and (", commit " .. st.commit:sub(1, 7)) or ""
      )
    or nil
  if res.status == "verified" then
    add(
      ("verified: unchanged since the green %s: %d of %d files proven"):format(
        origin,
        res.counts.proven,
        res.counts.files
      )
    )
  elseif res.status == "partial" then
    add(
      ("partial: %d of %d files proven; %d not provable (not green): %s"):format(
        res.counts.proven,
        res.counts.files,
        res.counts.not_provable,
        origin
      )
    )
    local recs = {}
    for _, u in ipairs(res.unproven) do
      recs[#recs + 1] = { status = "uncacheable", reason = u.reason, file = u.file }
    end
    for _, r in ipairs(require("testing.cache.explain").rank_uncacheable(recs)) do
      if #lines <= 6 then
        add(("  %3d  %s  (e.g. %s)"):format(r.count, r.reason, table.concat(r.files, ", ")))
      end
    end
  elseif res.status == "changed" then
    add(
      ("changed: %s differ from the stamp (%s); %d of %d proven"):format(
        plural(res.counts.changed, "file"),
        origin,
        res.counts.proven,
        res.counts.files
      )
    )
    local budget = M.MAX_DETAIL_LINES
    for i, c in ipairs(res.changed) do
      if i > M.SHOWN then
        add(("  ... and %d more (--json lists them all)"):format(#res.changed - M.SHOWN))
        break
      end
      if c.change == "changed" then
        add(("  changed  %s: key %s -> %s"):format(c.file, short(c.old), short(c.new)))
        local details = by_weight(c.details or {})
        local shown = math.max(0, math.min(#details, M.MAX_DETAILS, budget))
        for j = 1, shown do
          local d = details[j]
          local name = d.name == d.kind and "" or (" " .. d.name)
          local what = d.change == "changed"
              and ("%s -> %s"):format(tostring(d.old), tostring(d.new))
            or (
              d.change == "added" and ("new" .. (d.new and d.new ~= "" and (" " .. d.new) or ""))
              or "gone"
            )
          add(("      %s %s%s: %s"):format(d.change, d.kind, name, what))
        end
        budget = budget - shown
        if #details > shown then
          add(
            ("      ... and %d more key line(s) (`testing explain %s --parts` lists the key lines)"):format(
              #details - shown,
              c.file
            )
          )
        end
        if c.details_why then
          add("      " .. c.details_why)
        end
      elseif c.change == "gone" then
        add(("  gone     %s: in the stamp, no spec file now"):format(c.file))
      else
        add(("  new      %s: not in the stamp"):format(c.file))
      end
    end
  elseif res.status == "usage" then
    add("testing: verify: " .. tostring(res.reason))
    return lines
  else
    add(("%s: %s"):format(res.status, tostring(res.reason)))
    for _, c in ipairs(res.causes or {}) do
      add("  " .. c)
    end
  end
  if res.status == "partial" or res.status == "changed" then
    for i, u in ipairs(res.unproven or {}) do
      if res.status == "changed" and i > 5 then
        break
      end
      if i > M.SHOWN then
        add(
          ("  ... and %d more not provable (--json lists them all)"):format(#res.unproven - M.SHOWN)
        )
        break
      end
      add(("  not provable  %s: %s"):format(u.file, u.reason))
    end
  end
  if res.rerun then
    add(
      (
        res.rerun.whole_suite and "  run the suite (the proven files hit the cache): %s"
        or "  run them with: %s"
      ):format(res.rerun.command)
    )
  end
  if res.same_tree == true and res.status == "verified" then
    add("  the tree is the very tree of the stamp")
  end
  for _, n in ipairs(res.notes or {}) do
    add("  note: " .. n)
  end
  if res.status ~= "verified" and res.status ~= "usage" then
    add("  (no sentinel: only `verified` is green)")
  end
  return lines
end

---The JSON document of a result.
---@param res table
---@return table
function M.document(res)
  local function cap(list)
    local out = {}
    for i, v in ipairs(list or {}) do
      if i > M.MAX_LIST then
        break
      end
      out[#out + 1] = v
    end
    return out
  end
  local changed = {}
  for _, c in ipairs(cap(res.changed)) do
    local details = c.details
    local total
    if details and #details > M.MAX_LIST then
      -- the list is cut (a document with thousands of key lines per file must stay small), the count is not
      total = #details
      details = vim.list_slice(by_weight(details), 1, M.MAX_LIST)
    end
    changed[#changed + 1] = {
      file = c.file,
      change = c.change,
      old = c.old,
      new = c.new,
      details = details,
      details_total = total,
      details_why = c.details_why,
    }
  end
  local unproven = {}
  for _, u in ipairs(cap(res.unproven)) do
    unproven[#unproven + 1] = { file = u.file, reason = u.reason, from = u.from }
  end
  return {
    schema = "testing-verify/1",
    status = res.status,
    verified = res.status == "verified",
    exit_code = res.exit_code,
    reason = res.reason,
    stamp = res.stamp,
    source = res.source,
    counts = res.counts,
    causes = res.causes,
    changed = changed,
    not_provable = unproven,
    rerun = res.rerun,
    notes = res.notes,
    hmac = res.hmac,
    same_tree = res.same_tree,
  }
end

---Run `testing verify`.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param own Testing.Verify.Own
---@return integer exit_code
function M.main(plan, sv, own)
  local project = require("testing.run.project")
  local res = M.check(plan, sv, own)
  if res.status == "usage" then
    sv.err(project.safe_line("testing: verify: " .. tostring(res.reason)))
    return project.EXIT_USAGE
  end
  if own.json then
    local text, err = require("lib.nvim.json").encode(M.document(res), { indent = 2 })
    if not text then
      sv.err("testing: verify: cannot encode the result: " .. tostring(err))
      return project.EXIT_INFRA
    end
    sv.out(text)
    return res.exit_code
  end
  for _, line in ipairs(M.render(res)) do
    sv.out(project.safe_line(line))
  end
  if res.status == "verified" then
    -- the sentinel is the last line, as in a run, and only for this answer
    sv.out(project.safe_line(res.sentinel or "TESTING_OK"))
  end
  return res.exit_code
end

return M
