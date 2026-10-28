---@module 'testing.ci.verify'
---@brief `testing ci verify`: is this state already proven by a complete green `testing ci` run? Nothing is run.
---@description
--- ```
--- testing ci verify [--profile=<name>] [--json] [--allow-dirty] [--max-age=<7d>] [--root=<dir>] [--state-dir=<dir>]
--- ```
---
--- Reads `ci-<profile>.json` (the last complete run of the profile, `testing-ci/1`) from the project's state directory
--- and compares it with now: the tree (`HEAD^{tree}`, so a rebase or a reworded commit keeps the proof), the Neovim
--- version, the resolved pipeline (hash) and the version of every tool of the profile. The suite is asked last, through
--- `testing verify` on its stamp: that answer carries the trust levels (a local stamp in CI, a missing HMAC, ...).
--- The answer is one of the words of `testing verify`:
---
---   verified     same tree, same tools and pipeline, the suite stamp verifies; exit 0 and the sentinel
---   changed      the tree is another one (or the suite's stamp says so): `rerun` names the steps that must run again
---                (a change that no spec can see leaves the suite out: `testing ci --reuse`)
---   rejected     Neovim, the pipeline, a tool version or the system differs, or a tool is missing
---   dirty        the working tree has uncommitted changes (`--allow-dirty` overrules, explicitly)
---   expired      the proof is older than `--max-age` (default 7 days)
---   untrusted, partial, invalid, no-stamp   as for `testing verify`; `no-stamp` also: no complete run of the profile
---
--- Exit 0 only for `verified`, 1 for any other answer, 2 a usage or pipeline error, 3 an internal failure.

local M = {}

M.EXIT_OK, M.EXIT_NOT_PROVEN, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci-verify/1"

M.DEFAULT_MAX_AGE = "7d"

M.USAGE = table.concat({
  "usage: testing ci verify [--profile=<name>] [--json] [--allow-dirty] [--max-age=<7d>]",
  "                         [--state-dir=<dir>] [--root=<dir>]",
  "  --profile=<name>  the profile whose last complete run is the proof (default: ci.default)",
  "  --json            print the document testing-ci-verify/1 instead of lines (no sentinel in it)",
  "  --allow-dirty     accept a working tree with uncommitted changes",
  "  --max-age=<d>     the oldest proof accepted: 7d, 12h, 30m, 90s (default 7d)",
  "  --state-dir=<dir> where the document and the suite's stamp are (default: stdpath('state'))",
  "  --root=<dir>      the project root (default: the current directory)",
}, "\n")

---@class Testing.Ci.Verify.Args
---@field profile? string
---@field json boolean
---@field allow_dirty boolean
---@field max_age string
---@field state_dir? string
---@field root string
---@field help boolean

local VALUED = { profile = true, ["max-age"] = true, ["state-dir"] = true, root = true }

---@param argv string[] The arguments after `verify`.
---@return Testing.Ci.Verify.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Verify.Args
  local args =
    { json = false, allow_dirty = false, max_age = M.DEFAULT_MAX_AGE, root = ".", help = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "json" and value == nil then
      args.json = true
    elseif key == "allow-dirty" and value == nil then
      args.allow_dirty = true
    elseif key and VALUED[key] then
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      args[key == "max-age" and "max_age" or key == "state-dir" and "state_dir" or key] = value
    else
      return nil, ("unknown argument %s"):format(a)
    end
    i = i + 1
  end
  local _, why = require("testing.stamp").parse_age(args.max_age)
  if why then
    return nil, "--max-age: " .. why
  end
  return args
end

---Ask `testing verify` about the suite's stamp, in this process; its document gives the answer.
---@param root string
---@param state_dir string|nil
---@param sv table The services of the outer run (only the sinks are replaced).
---@param opts? { allow_dirty?: boolean, max_age?: string }
---@return string status `verified`, `changed`, ... or `unknown` when no document came back.
---@return table|nil doc The `testing-verify/1` document.
function M.suite_status(root, state_dir, sv, opts)
  opts = opts or {}
  local argv = {
    "verify",
    root,
    "--stamp",
    require("testing.stamp").path(root, { state_dir = state_dir }),
    "--json",
  }
  if opts.allow_dirty then
    argv[#argv + 1] = "--allow-dirty"
  end
  if opts.max_age then
    vim.list_extend(argv, { "--max-age", opts.max_age })
  end
  local lines = {}
  local ok = pcall(
    require("testing.cli").main,
    argv,
    vim.tbl_extend("force", sv, {
      out = function(s)
        lines[#lines + 1] = s
      end,
      err = function() end,
    })
  )
  local okd, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or not okd or type(doc) ~= "table" or type(doc.status) ~= "string" then
    return "unknown", nil
  end
  return doc.status, doc
end

---The seconds since an ISO-8601 UTC time (`2026-10-28T12:00:00Z`), nil when it is not one.
---@param text any
---@return integer|nil
local function age_of(text)
  local y, mo, d, h, mi, s =
    tostring(text):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then
    return nil
  end
  -- `os.time` reads a table as local time; the offset of the zone is taken out
  local as_local = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
  return math.floor(os.time() - (as_local + offset))
end

---Why a document cannot be a proof at all (an incomplete or red run).
---@param doc any
---@return string|nil
local function unusable(doc)
  local ci = require("testing.ci")
  if type(doc) ~= "table" or doc.schema ~= ci.SCHEMA then
    return "not a testing-ci/1 document"
  end
  if doc.verdict ~= "green" then
    return ("the run was %s, not green"):format(tostring(doc.verdict))
  end
  if doc.partial == true or doc.head_moved == true or doc.tree_changed == true then
    return "the run was partial or the tree moved during it"
  end
  if doc.dirty ~= false then
    return "the run was on a working tree with uncommitted changes"
  end
  if type(doc.tree) ~= "string" or type(doc.steps) ~= "table" then
    return "the document names no tree or no steps"
  end
  return nil
end

---@param s string|nil
---@return string
local function short(s)
  return type(s) == "string" and s:sub(1, 8) or "?"
end

---The result: one status, the facts behind it.
---@class Testing.Ci.Verify.Result
---@field status string
---@field profile? string
---@field tree? string The tree now.
---@field proof_tree? string The tree of the proof.
---@field reasons string[]
---@field rerun string[] The steps that must run again.
---@field suite? string The suite stamp's answer.
---@field exit integer

---@param args Testing.Ci.Verify.Args
---@param sv table
---@return Testing.Ci.Verify.Result
local function check(args, sv)
  local ci = require("testing.ci")
  local schema = require("testing.ci.schema")
  local internal = ci.internal
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p") or sv.state_dir
  ---@type Testing.Ci.Verify.Result
  local res = { status = "invalid", reasons = {}, rerun = {}, exit = M.EXIT_NOT_PROVEN }
  local function fail(status, exit, reason)
    res.status, res.exit = status, exit
    if reason then
      res.reasons[#res.reasons + 1] = reason
    end
    return res
  end

  if vim.fn.isdirectory(root) ~= 1 then
    return fail("usage", M.EXIT_USAGE, ("root %s is not a directory"):format(args.root))
  end
  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    return fail("usage", M.EXIT_USAGE, loaded.error)
  end
  if loaded.config.ci == nil then
    return fail("usage", M.EXIT_USAGE, ("%s/.testing.lua has no `ci` section"):format(root))
  end
  local pipeline, problems = schema.resolve(loaded.config.ci)
  if not pipeline then
    return fail("usage", M.EXIT_USAGE, table.concat(problems or {}, "; "))
  end
  local profile = args.profile or pipeline.default
  local names = pipeline.profiles[profile]
  if not names then
    return fail("usage", M.EXIT_USAGE, ("unknown profile %s"):format(profile))
  end
  res.profile = profile

  local path = require("testing.state").dir(root, { state_dir = state_dir })
    .. "/ci-"
    .. profile
    .. ".json"
  local f = io.open(path, "rb")
  if not f then
    return fail(
      "no-stamp",
      M.EXIT_NOT_PROVEN,
      ("no complete run of profile %s is recorded (%s)"):format(profile, path)
    )
  end
  local text = f:read("*a")
  f:close()
  local okd, doc = pcall(vim.json.decode, text)
  local bad = okd and unusable(doc) or nil
  if not okd then
    bad = "the file is not JSON"
  end
  if bad then
    return fail("invalid", M.EXIT_NOT_PROVEN, bad)
  end
  res.proof_tree = doc.tree

  -- every process of our own is started now and collected together: git facts, the tool versions
  local facts = internal.git_facts(root)
  local planned, _, why = internal.plan(pipeline, names, root)
  local started = planned and internal.start_versions(planned) or {}
  res.tree = facts.tree

  if not planned then
    res.status = "rejected"
    vim.list_extend(res.reasons, why or { "a tool of the profile is missing" })
    return res
  end
  if facts.tree == nil then
    return fail(
      "invalid",
      M.EXIT_NOT_PROVEN,
      "no git tree to compare (not a repository, no commit)"
    )
  end

  local rejected = {}
  if doc.os ~= internal.this_os() then
    rejected[#rejected + 1] = ("system: proof on %s, now %s"):format(doc.os, internal.this_os())
  end
  if doc.nvim ~= tostring(vim.version()) then
    rejected[#rejected + 1] = ("neovim: proof with %s, now %s"):format(
      tostring(doc.nvim),
      tostring(vim.version())
    )
  end
  local sha = vim.fn.sha256(require("lib.nvim.json.canonical").encode(pipeline.digest_input))
  if doc.pipeline_sha ~= sha then
    rejected[#rejected + 1] = "the pipeline (`ci` section) differs from the one that was proven"
  end
  local proven = {}
  for _, s in ipairs(doc.steps) do
    if type(s) == "table" and type(s.name) == "string" then
      proven[s.name] = s
    end
  end
  for _, p in ipairs(planned) do
    local name = p.step.name
    local s = proven[name]
    if not p.skip and not p.step.inprocess then
      local line = internal.collect(started[name])
      line = line and vim.trim(line:match("[^\r\n]+") or "") or nil
      local was = s and s.tool_version
      if type(was) == "string" and line ~= was then
        rejected[#rejected + 1] = ("%s: proof with %s, now %s"):format(name, was, tostring(line))
      end
    end
  end
  if #rejected > 0 then
    res.status = "rejected"
    vim.list_extend(res.reasons, rejected)
    return res
  end

  if facts.dirty and not args.allow_dirty then
    return fail("dirty", M.EXIT_NOT_PROVEN, "git status is not empty (--allow-dirty overrules)")
  end
  local max_age = require("testing.stamp").parse_age(args.max_age) --[[@as integer]]
  local age = age_of(doc.time)
  if age == nil then
    return fail("invalid", M.EXIT_NOT_PROVEN, "the document has no valid time")
  end
  if age > max_age then
    return fail(
      "expired",
      M.EXIT_NOT_PROVEN,
      ("the proof is %d s old, the limit is %s"):format(age, args.max_age)
    )
  end

  -- the suite last: it is the one answer that needs the spec keys, and it carries the trust levels
  local has_suite = false
  for _, p in ipairs(planned) do
    has_suite = has_suite or (p.step.inprocess == "run" and p.step.stamp == true)
  end
  local suite_ok = true
  if has_suite then
    res.suite = M.suite_status(root, state_dir, sv, {
      allow_dirty = args.allow_dirty or facts.dirty == true,
      max_age = args.max_age,
    })
    suite_ok = res.suite == "verified"
  end
  local same_tree = doc.tree == facts.tree
  if same_tree and suite_ok then
    res.status, res.exit = "verified", M.EXIT_OK
    return res
  end
  if not suite_ok then
    res.status = res.suite == "unknown" and "invalid" or res.suite --[[@as string]]
    res.reasons[#res.reasons + 1] = "the suite's stamp: " .. tostring(res.suite)
  else
    res.status = "changed"
  end
  if not same_tree then
    res.reasons[#res.reasons + 1] = ("tree %s, the proof is for %s"):format(
      short(facts.tree),
      short(doc.tree)
    )
  end
  for _, p in ipairs(planned) do
    local suite = p.step.inprocess == "run" and p.step.stamp == true
    if not p.skip and (not suite or not suite_ok) then
      res.rerun[#res.rerun + 1] = p.step.name
    end
  end
  return res
end

---@param res Testing.Ci.Verify.Result
---@return table
local function document(res)
  return {
    schema = M.SCHEMA,
    status = res.status,
    verified = res.status == "verified",
    profile = res.profile or vim.NIL,
    tree = res.tree or vim.NIL,
    proof_tree = res.proof_tree or vim.NIL,
    suite = res.suite or vim.NIL,
    reasons = res.reasons,
    rerun = res.rerun,
    exit = res.exit,
  }
end

---`testing ci verify ...`.
---@param argv string[] The arguments after `verify`.
---@param sv table `out`, `err`, `state_dir`.
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci verify: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local ok, res = pcall(check, args, sv)
  if not ok then
    sv.err("testing ci verify: " .. tostring(res))
    return M.EXIT_INFRA
  end
  if res.exit == M.EXIT_USAGE then
    for _, r in ipairs(res.reasons) do
      sv.err("testing ci verify: " .. r)
    end
    return M.EXIT_USAGE
  end
  if args.json then
    sv.out(require("lib.nvim.json.canonical").encode(document(res)))
    return res.exit
  end
  local head = ("ci verify: %s"):format(res.status)
  if res.profile then
    head = head .. (" (profile %s"):format(res.profile)
    if res.suite then
      head = head .. ", suite stamp " .. res.suite
    end
    head = head .. ")"
  end
  sv.out(head)
  for _, r in ipairs(res.reasons) do
    sv.out("  " .. r)
  end
  if #res.rerun > 0 then
    sv.out(
      ("  run again: %s (testing ci --profile=%s --reuse)"):format(
        table.concat(res.rerun, ", "),
        res.profile
      )
    )
  end
  if res.exit == M.EXIT_OK then
    sv.out(require("testing.ci").SENTINEL)
  end
  return res.exit
end

return M
