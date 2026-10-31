---@module 'testing.ci.runner_guard'
---@brief Protection of the local self-hosted runner from foreign code: the job-started hook and the list of reviewed commits.
---@description
--- ```
--- testing ci runner-guard check                     (the hook: decides from GITHUB_*; exit 0 = run, 1 = refuse)
--- testing ci runner-guard install|remove|status [--runners=<dir>]
--- testing ci trust [<owner/repo>] [<sha>] [--show] [--note=<text>] [--runners=<dir>]
--- testing ci trust --list | --revoke [<owner/repo>] [<sha>] | --mode=auto|always|off [<owner/repo>]
--- ```
---
--- A runner executes what a job says with the rights of its user. Foreign code reaches it by a pull request that
--- changes the workflow, and by a push to the default branch after a merge (specs, `.testing.lua` and scripts run
--- then). A check inside the workflow or `scripts/ci.sh` is no barrier, the change can edit it. So the check lives on
--- the machine of the runner: the runner starts `ACTIONS_RUNNER_HOOK_JOB_STARTED` before each job, and a non-zero
--- exit cancels the job. The hook script (`<runners>/_guard/job-started.ps1`, outside every work folder) only calls
--- `testing ci runner-guard check`; the rules are here, so a spec can run them.
---
--- Rules, in this order (`decide`):
---   1. mode `off` for the repository: run
---   2. event `pull_request` / `pull_request_target`: refuse (their code is never trusted)
---   3. actor or triggering actor is not the owner of the repository (the maintainer): refuse
---   4. repository private (and mode not `always`): run
---   5. the commit (`GITHUB_SHA`) is on the list of reviewed commits: run; else refuse and name `testing ci trust`
---
--- Review is per commit id, never per author (the author field is free text). The list is
--- `<runners>/reviewed.json`, read as untrusted data: a file that is not ours is an empty list (nothing is trusted
--- from it), never an error that lets a job through. Anything that cannot be decided (no `GITHUB_*` variables, no
--- `gh`) refuses.
---
--- Honest limit: this stops foreign code the maintainer did not release. It does not stop code the maintainer
--- released after a careless review, and not an attacker who can already write to the runner folder.

local M = {}

M.VERSION = 1
M.MAX_BYTES = 1024 * 1024
M.MAX_SHAS = 50
M.MAX_REPOS = 200
M.HOOK_VAR = "ACTIONS_RUNNER_HOOK_JOB_STARTED"
M.ENV_ROOT = "TESTING_RUNNER_ROOT"
M.MODES = { auto = true, always = true, off = true }
M.EVENTS =
  { push = true, workflow_dispatch = true, workflow_run = true, schedule = true, release = true }

M.USAGE = table.concat({
  "usage: testing ci runner-guard check",
  "       testing ci runner-guard install|remove|status [--runners=<dir>]",
  "       testing ci trust [<owner/repo>] [<sha>] [--show] [--note=<text>] [--runners=<dir>]",
  "       testing ci trust --list | --revoke [<owner/repo>] [<sha>] | --mode=auto|always|off [<owner/repo>]",
  "  The runner folder is $TESTING_RUNNER_ROOT, else `actions-runners` in your home folder (docs/RUNNER-GUARD.md).",
}, "\n")

local uv = vim.uv or vim.loop

---@class Testing.RunnerGuard.Ctx A seam for specs; the CLI passes none.
---@field env? table<string, string|nil>
---@field gh? fun(args: string[]): string|nil, string|nil
---@field now? integer
---@field root? string
---@field nvim? string
---@field script? string

---The variables this module reads, by literal names (a computed name makes a spec that loads the module
---unkeyable for the result cache).
---@return table<string, string|nil>
local function real_env()
  return {
    GITHUB_EVENT_NAME = os.getenv("GITHUB_EVENT_NAME"),
    GITHUB_ACTOR = os.getenv("GITHUB_ACTOR"),
    GITHUB_TRIGGERING_ACTOR = os.getenv("GITHUB_TRIGGERING_ACTOR"),
    GITHUB_REPOSITORY = os.getenv("GITHUB_REPOSITORY"),
    GITHUB_REPOSITORY_OWNER = os.getenv("GITHUB_REPOSITORY_OWNER"),
    GITHUB_SHA = os.getenv("GITHUB_SHA"),
    TESTING_RUNNER_ROOT = os.getenv("TESTING_RUNNER_ROOT"),
    USERPROFILE = os.getenv("USERPROFILE"),
    HOME = os.getenv("HOME"),
  }
end

---@param ctx? Testing.RunnerGuard.Ctx
---@param name string
---@return string|nil
local function read_var(ctx, name)
  return (ctx and ctx.env or real_env())[name]
end

---The folder of the runners (one sub folder per repository).
---@param ctx? Testing.RunnerGuard.Ctx
---@param given? string `--runners=`
---@return string
function M.root(ctx, given)
  local r = given or (ctx and ctx.root) or read_var(ctx, M.ENV_ROOT)
  if not r or r == "" then
    local home = read_var(ctx, "USERPROFILE") or read_var(ctx, "HOME") or vim.fn.expand("~")
    r = home .. "/actions-runners"
  end
  return (vim.fs.normalize(r):gsub("/+$", ""))
end

---@param root string
---@return string
function M.store_path(root)
  return root .. "/reviewed.json"
end

---@param s any
---@return boolean
local function is_sha(s)
  return type(s) == "string" and #s == 40 and s:match("^%x+$") ~= nil and s:lower() == s
end

---@param s any
---@return string|nil
local function repo_key(s)
  -- GitHub: an owner is alphanumeric with hyphens; a name may hold dots but is never `.` or `..` (they would
  -- walk out of `repos/<owner>/<name>` in an API path)
  if type(s) ~= "string" or #s > 140 then
    return nil
  end
  local owner, name = s:match("^(%w[%w%-]*)/([%w%-_.]+)$")
  if not owner or name == "." or name == ".." then
    return nil
  end
  return s:lower()
end
M.repo_key = repo_key

---@class Testing.RunnerGuard.Entry
---@field mode string auto|always|off
---@field shas { sha: string, at: integer, note?: string }[]

---Read the list. Never raises. `keep`: the file may hold more than this reader sees, so a writer must not replace it.
---@param path string
---@return table<string, Testing.RunnerGuard.Entry> repos
---@return string|nil note
---@return boolean|nil keep
function M.read(path)
  local st = uv.fs_stat(path)
  if not st then
    return {}, nil
  end
  if st.type ~= "file" or st.size > M.MAX_BYTES then
    return {},
      ("%s is not a regular file or larger than %d bytes: nothing is trusted from it"):format(
        path,
        M.MAX_BYTES
      ),
      true
  end
  local text, rerr = require("lib.nvim.fs.read")(path)
  if not text then
    return {}, ("%s cannot be read: %s"):format(path, tostring(rerr)), true
  end
  local ok, doc = pcall(require("lib.nvim.json").decode, text)
  if not ok or type(doc) ~= "table" or doc.v ~= M.VERSION or type(doc.repos) ~= "table" then
    return {},
      ("%s is not a list of version %d: nothing is trusted from it"):format(path, M.VERSION),
      ok and type(doc) == "table"
  end
  local out, n = {}, 0
  for k, e in pairs(doc.repos) do
    local key = repo_key(k)
    if key and type(e) == "table" and n < M.MAX_REPOS then
      local entry = { mode = M.MODES[e.mode] and e.mode or "auto", shas = {} }
      if type(e.shas) == "table" then
        for _, s in ipairs(e.shas) do
          if type(s) == "table" and is_sha(s.sha) and #entry.shas < M.MAX_SHAS then
            local at = type(s.at) == "number"
                and s.at == s.at
                and s.at >= 0
                and s.at < 9e15
                and math.floor(s.at)
              or 0
            local note = type(s.note) == "string" and s.note:sub(1, 200):gsub("%c", " ") or nil
            entry.shas[#entry.shas + 1] = { sha = s.sha, at = at, note = note }
          end
        end
      end
      out[key] = entry
      n = n + 1
    end
  end
  return out, nil
end

---@param path string
---@param fn fun(repos: table<string, Testing.RunnerGuard.Entry>)
---@return boolean ok
---@return string|nil err
local function update(path, fn)
  local repos, note, keep = M.read(path)
  if keep then
    return false, note .. "; it is left as it is (move it away to start a new list)"
  end
  fn(repos)
  local text, eerr = require("lib.nvim.json").encode({ v = M.VERSION, repos = repos })
  if not text then
    return false, "cannot encode the list: " .. tostring(eerr)
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not ok then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true
end

-- --------------------------------------------------------------------------------------------------- the decision

---@class Testing.RunnerGuard.Facts
---@field event? string
---@field actor? string
---@field triggering_actor? string
---@field repo? string `owner/name`
---@field owner? string
---@field sha? string
---@field is_private? boolean|nil nil: unknown (treated as public)
---@field entry? Testing.RunnerGuard.Entry

---@param s string|nil
---@return string
local function lc(s)
  return (s or ""):lower()
end

---Pure decision.
---@param f Testing.RunnerGuard.Facts
---@return boolean run
---@return string reason
function M.decide(f)
  local mode = f.entry and f.entry.mode or "auto"
  if mode == "off" then
    return true, "guard is off for this repository"
  end
  if
    (f.event or "") == ""
    or (f.repo or "") == ""
    or (f.sha or "") == ""
    or (f.actor or "") == ""
  then
    return false,
      "the hook got no GITHUB_EVENT_NAME / GITHUB_REPOSITORY / GITHUB_SHA / GITHUB_ACTOR: nothing to decide on"
  end
  if f.event == "pull_request" or f.event == "pull_request_target" then
    return false, ("event %s: the code of a pull request never runs on this runner"):format(f.event)
  end
  -- an allowlist: events that run the code of a ref the maintainer pushed or chose (pull_request_review and
  -- the like run the merge ref of a pull request)
  if not M.EVENTS[f.event] then
    return false,
      ("event %s is not one this runner takes (push, workflow_dispatch, workflow_run, schedule, release)"):format(
        f.event
      )
  end
  local owner = lc(f.owner ~= "" and f.owner or (f.repo or ""):match("^([^/]+)/"))
  if lc(f.actor) ~= owner then
    return false, ("actor %s is not the maintainer (%s)"):format(f.actor, owner)
  end
  if f.triggering_actor and f.triggering_actor ~= "" and lc(f.triggering_actor) ~= owner then
    return false,
      ("triggering actor %s is not the maintainer (%s)"):format(f.triggering_actor, owner)
  end
  if f.is_private == true and mode ~= "always" then
    return true, "private repository, maintainer"
  end
  for _, s in ipairs(f.entry and f.entry.shas or {}) do
    if s.sha == lc(f.sha) then
      return true, "commit " .. f.sha:sub(1, 12) .. " is on the list of reviewed commits"
    end
  end
  return false,
    ("commit %s of %s is not reviewed (unreviewed commits since the last release)"):format(
      f.sha:sub(1, 12),
      f.repo
    )
end

---@param ctx? Testing.RunnerGuard.Ctx
---@param args string[]
---@return string|nil out
---@return string|nil err
local function gh(ctx, args)
  if ctx and ctx.gh then
    return ctx.gh(args)
  end
  local ok, proc = pcall(vim.system, vim.list_extend({ "gh" }, args), { text = true })
  if not ok then
    return nil, "gh cannot be started: " .. tostring(proc)
  end
  local r = proc:wait(30000)
  if r.code ~= 0 then
    return nil, ((r.stderr or ""):gsub("%s+$", ""):sub(1, 300))
  end
  return r.stdout or ""
end

---`testing ci runner-guard check`: the hook.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param ctx? Testing.RunnerGuard.Ctx
---@return integer
local function check(sv, ctx)
  local repo = read_var(ctx, "GITHUB_REPOSITORY")
  local key = repo_key(repo)
  local facts = {
    event = read_var(ctx, "GITHUB_EVENT_NAME"),
    actor = read_var(ctx, "GITHUB_ACTOR"),
    triggering_actor = read_var(ctx, "GITHUB_TRIGGERING_ACTOR"),
    repo = key and repo or "",
    owner = read_var(ctx, "GITHUB_REPOSITORY_OWNER"),
    sha = read_var(ctx, "GITHUB_SHA"),
  }
  local repos, note = M.read(M.store_path(M.root(ctx)))
  if note then
    sv.err("runner-guard: note: " .. note)
  end
  facts.entry = key and repos[key] or nil
  if key and (facts.entry and facts.entry.mode or "auto") ~= "off" then
    local out = gh(ctx, { "api", "repos/" .. repo, "--jq", ".private" })
    local v = out and out:gsub("%s+", "")
    facts.is_private = v == "true" and true or (v == "false" and false or nil)
  end
  local run, reason = M.decide(facts)
  if run then
    sv.out("runner-guard: allowed: " .. reason)
    return 0
  end
  sv.err("runner-guard: JOB REFUSED: " .. reason)
  if
    facts.sha
    and facts.sha ~= ""
    and key
    and facts.event ~= "pull_request"
    and facts.event ~= "pull_request_target"
  then
    sv.err(
      ("runner-guard: review it, then: testing ci trust %s %s   (and re-run the job)"):format(
        repo,
        facts.sha
      )
    )
  end
  sv.err("runner-guard: switch off: testing ci runner-guard remove (docs/RUNNER-GUARD.md)")
  return 1
end

-- --------------------------------------------------------------------------------------------------- trust

local SENSITIVE = {
  { "^%.github/", ".github" },
  { "^scripts/", "scripts" },
  { "%.sh$", "shell" },
  { "%.ps1$", "powershell" },
  { "%.cmd$", "cmd" },
  { "%.bat$", "cmd" },
  { "^%.testing%.lua$", ".testing.lua" },
  { "^TESTS/", "specs" },
  { "package%.json$", "package.json" },
  { "package%-lock%.json$", "lockfile" },
  { "pnpm%-lock%.yaml$", "lockfile" },
  { "Cargo%.lock$", "lockfile" },
  { "Cargo%.toml$", "Cargo.toml" },
  { "build%.rs$", "build.rs" },
  { "%.deps/", ".deps" },
}

---Why a changed file deserves a close look (nil: ordinary).
---@param path string
---@return string|nil
function M.flag(path)
  for _, r in ipairs(SENSITIVE) do
    if path:find(r[1]) then
      return r[2]
    end
  end
  return nil
end

---@param argv string[]
---@return table|nil args
---@return string|nil problem
function M.parse_trust(argv)
  ---@type table
  local a = { positional = {} }
  for _, x in ipairs(argv) do
    if x == "--show" or x == "--list" or x == "--revoke" then
      a[x:sub(3)] = true
    elseif x:match("^%-%-mode=") then
      a.mode = x:sub(8)
      if not M.MODES[a.mode] then
        return nil, "--mode is auto, always or off"
      end
    elseif x:match("^%-%-note=") then
      a.note = x:sub(8):gsub("%c", " "):sub(1, 200)
    elseif x:match("^%-%-runners=") then
      a.runners = x:sub(11)
    elseif x:sub(1, 1) == "-" then
      return nil, "unknown option " .. x:sub(1, 40):gsub("%c", "?")
    else
      a.positional[#a.positional + 1] = x
    end
  end
  for _, p in ipairs(a.positional) do
    if not (repo_key(p) or p:match("^%x+$") and #p >= 7 and #p <= 40) then
      return nil, "not a repository (owner/name) or a commit id: " .. p:sub(1, 40):gsub("%c", "?")
    end
  end
  if #a.positional > 2 then
    return nil, "at most a repository and a commit id"
  end
  return a
end

---@param ctx? Testing.RunnerGuard.Ctx
---@param cwd? string
---@return string|nil
local function repo_of_cwd(ctx, cwd)
  local ok, proc = pcall(
    vim.system,
    { "git", "-C", cwd or ".", "remote", "get-url", "origin" },
    { text = true }
  )
  if not ok then
    return nil
  end
  local r = proc:wait(10000)
  if r.code ~= 0 then
    return nil
  end
  local o, n = require("testing.ci.remote").parse_origin(r.stdout or "")
  return o and n and (o .. "/" .. n) or nil
end

---@param sv table
---@param repo string
---@param prev string|nil
---@param sha string
---@param ctx? Testing.RunnerGuard.Ctx
local function summary(sv, repo, prev, sha, ctx)
  if not prev then
    sv.out(
      ("no earlier reviewed commit of %s on the list: review the whole tree at %s"):format(
        repo,
        sha:sub(1, 12)
      )
    )
    return
  end
  local text, err = gh(ctx, { "api", ("repos/%s/compare/%s...%s"):format(repo, prev, sha) })
  local ok, doc = pcall(vim.json.decode, text or "")
  if not text or not ok or type(doc) ~= "table" then
    sv.out(
      ("cannot compare %s...%s (%s): review the tree yourself"):format(
        prev:sub(1, 12),
        sha:sub(1, 12),
        tostring(err)
      )
    )
    return
  end
  sv.out(
    ("since %s: %s commit(s), status %s"):format(
      prev:sub(1, 12),
      tostring(doc.total_commits or #(doc.commits or {})),
      tostring(doc.status)
    )
  )
  if doc.status ~= "ahead" then
    sv.out(
      "  note: the new commit is not a plain successor of the last reviewed one (history rewritten or other branch)"
    )
  end
  for _, c in ipairs(doc.commits or {}) do
    local msg = (c.commit and c.commit.message or ""):match("^[^\n]*"):gsub("%c", " "):sub(1, 70)
    local who = c.commit and c.commit.author and c.commit.author.name or "?"
    sv.out(
      ("  commit %s  %-20s %s"):format(tostring(c.sha):sub(1, 10), tostring(who):sub(1, 20), msg)
    )
  end
  local flagged, total = {}, 0
  for _, f in ipairs(doc.files or {}) do
    total = total + 1
    local why = M.flag(tostring(f.filename))
    if why then
      flagged[#flagged + 1] = ("  look closely [%s] %s (%s)"):format(
        why,
        tostring(f.filename):gsub("%c", "?"),
        tostring(f.status)
      )
    end
  end
  sv.out(
    ("  %d file(s) changed%s"):format(total, total >= 300 and " (the API lists at most 300)" or "")
  )
  for _, l in ipairs(flagged) do
    sv.out(l)
  end
end

---`testing ci trust ...`.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), cwd?: string }
---@param ctx? Testing.RunnerGuard.Ctx
---@return integer
function M.trust_main(argv, sv, ctx)
  local a, problem = M.parse_trust(argv)
  if not a then
    sv.err("testing ci trust: " .. problem)
    sv.err(M.USAGE)
    return 2
  end
  local path = M.store_path(M.root(ctx, a.runners))
  if a.list then
    local repos, note = M.read(path)
    if note then
      sv.err("testing ci trust: note: " .. note)
    end
    local keys = vim.tbl_keys(repos)
    table.sort(keys)
    for _, k in ipairs(keys) do
      local e = repos[k]
      sv.out(("%s  mode=%s  %d reviewed"):format(k, e.mode, #e.shas))
      for _, s in ipairs(e.shas) do
        sv.out(("  %s  %s  %s"):format(s.sha:sub(1, 12), os.date("!%Y-%m-%d", s.at), s.note or ""))
      end
    end
    if #keys == 0 then
      sv.out("(the list of reviewed commits is empty: " .. path .. ")")
    end
    return 0
  end
  local repo, sha
  for _, p in ipairs(a.positional) do
    if repo_key(p) then
      repo = p
    else
      sha = p:lower()
    end
  end
  repo = repo or repo_of_cwd(ctx, sv.cwd)
  local key = repo_key(repo)
  if not key or not repo then
    sv.err("testing ci trust: no repository given and none found at origin of the current folder")
    return 2
  end
  if a.mode then
    local ok, err = update(path, function(repos)
      repos[key] = repos[key] or { mode = "auto", shas = {} }
      repos[key].mode = a.mode
    end)
    if not ok then
      sv.err("testing ci trust: " .. tostring(err))
      return 3
    end
    sv.out(("%s: mode %s"):format(key, a.mode))
    return 0
  end
  if a.revoke then
    local ok, err = update(path, function(repos)
      local e = repos[key]
      if not e then
        return
      end
      if sha then
        e.shas = vim.tbl_filter(function(s)
          return s.sha:sub(1, #sha) ~= sha
        end, e.shas)
      else
        e.shas = {}
      end
    end)
    if not ok then
      sv.err("testing ci trust: " .. tostring(err))
      return 3
    end
    sv.out(("%s: %s revoked"):format(key, sha or "every reviewed commit"))
    return 0
  end
  -- resolve to the full id at GitHub: this checks that the commit exists in THIS repository
  local ref = sha
  if not ref then
    local branch, berr = gh(ctx, { "api", "repos/" .. repo, "--jq", ".default_branch" })
    branch = branch and branch:gsub("%s+", "")
    if not branch or branch == "" then
      sv.err(
        "testing ci trust: cannot read the default branch of " .. repo .. ": " .. tostring(berr)
      )
      return 3
    end
    ref = branch
  end
  local full, ferr = gh(ctx, { "api", ("repos/%s/commits/%s"):format(repo, ref), "--jq", ".sha" })
  full = full and full:gsub("%s+", "")
  if not is_sha(full) then
    sv.err(("testing ci trust: %s has no commit %s: %s"):format(repo, ref, tostring(ferr)))
    return 3
  end
  local repos = M.read(path)
  local entry = repos[key]
  local prev = entry and entry.shas[#entry.shas] and entry.shas[#entry.shas].sha or nil
  summary(sv, repo, prev ~= full and prev or nil, full, ctx)
  if a.show then
    sv.out("(--show: nothing recorded)")
    return 0
  end
  local now = ctx and ctx.now or os.time()
  local ok, err = update(path, function(rs)
    local e = rs[key] or { mode = "auto", shas = {} }
    rs[key] = e
    e.shas = vim.tbl_filter(function(s)
      return s.sha ~= full
    end, e.shas)
    e.shas[#e.shas + 1] = { sha = full, at = now, note = a.note }
    while #e.shas > M.MAX_SHAS do
      table.remove(e.shas, 1)
    end
  end)
  if not ok then
    sv.err("testing ci trust: " .. tostring(err))
    return 3
  end
  sv.out(
    ("reviewed: %s %s  (re-run the refused job: gh run rerun <id> -R %s)"):format(key, full, repo)
  )
  return 0
end

-- --------------------------------------------------------------------------------------------------- install

---@param s string
---@return string
local function psq(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

---The hook script. It decides nothing; no nvim or script: the job is refused.
---@param nvim string
---@param script string
---@return string
function M.hook_text(nvim, script)
  local lines = {
    "# generated by `testing ci runner-guard install`; do not edit (install rewrites it, remove deletes it)",
    "$nvim = " .. psq(nvim),
    "$script = " .. psq(script),
    "if (-not (Test-Path -LiteralPath $nvim) -or -not (Test-Path -LiteralPath $script)) {",
    "  [Console]::Error.WriteLine('runner-guard: nvim or testing.lua is missing: job refused (testing ci runner-guard install, or remove)')",
    "  exit 1",
    "}",
    -- a nvim that cannot start leaves $LASTEXITCODE empty, and `exit $null` is 0: the job would run
    "$global:LASTEXITCODE = $null",
    "$code = 1",
    "try {",
    "  & $nvim --headless -u NONE -l $script ci runner-guard check",
    "  if ($null -ne $LASTEXITCODE) { $code = $LASTEXITCODE }",
    "} catch {",
    "  [Console]::Error.WriteLine('runner-guard: the check could not run: ' + $_)",
    "}",
    "exit $code",
    "",
  }
  return table.concat(lines, "\r\n")
end

---@param root string
---@return string[] names runner folders
local function runner_dirs(root)
  local out = {}
  for name, t in vim.fs.dir(root) do
    if
      t == "directory"
      and not name:match("^[_.]")
      and uv.fs_stat(root .. "/" .. name .. "/run.cmd")
    then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---@param ctx? Testing.RunnerGuard.Ctx
---@return string nvim
---@return string script
local function tools(ctx)
  local nvim = ctx and ctx.nvim or vim.v.progpath
  local script = ctx and ctx.script
  if not script then
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    script = vim.fs.normalize(vim.fn.fnamemodify(src, ":p:h:h:h:h") .. "/scripts/testing.lua")
  end
  return nvim, script
end

---Text of a `.env` ("" when there is none); nil and the reason when it exists but cannot be read.
---@param path string
---@return string|nil text
---@return string|nil err
local function read_env(path)
  if not uv.fs_stat(path) then
    return ""
  end
  return require("lib.nvim.fs.read")(path)
end

---The value of a hook line (name compared without regard to case, as Windows does), else nil.
---@param line string
---@return string|nil
local function hook_value(line)
  local name, v = line:match("^%s*([%w_]+)=(.*)$")
  if name and name:upper() == M.HOOK_VAR then
    return v
  end
  return nil
end

---Rewrite the `.env` of a runner without the hook line; with `value`, add it.
---@param env_path string
---@param value string|nil
---@param ours fun(v: string): boolean
---@return boolean ok
---@return string|nil err_or_state "foreign" when a hook of someone else is there and nothing was changed
local function edit_env(env_path, value, ours)
  local text, rerr = read_env(env_path)
  if not text then
    return false, "cannot read .env: " .. tostring(rerr)
  end
  local keep = {}
  for line in text:gmatch("[^\r\n]+") do
    local v = hook_value(line)
    if v == nil then
      keep[#keep + 1] = line
    elseif not ours(v) then
      return true, "foreign"
    end
  end
  if value then
    keep[#keep + 1] = M.HOOK_VAR .. "=" .. value
  end
  local ok, err = require("lib.nvim.fs.write.atomic")(
    env_path,
    table.concat(keep, "\r\n") .. (#keep > 0 and "\r\n" or ""),
    {}
  )
  if not ok then
    return false, tostring(err)
  end
  return true
end

---@param argv string[]
---@param sv table
---@param ctx? Testing.RunnerGuard.Ctx
---@return integer
local function manage(action, argv, sv, ctx)
  local given
  for _, x in ipairs(argv) do
    if x:match("^%-%-runners=") then
      given = x:sub(11)
    else
      sv.err("testing ci runner-guard: unexpected argument " .. x:sub(1, 40):gsub("%c", "?"))
      return 2
    end
  end
  local root = M.root(ctx, given)
  if vim.fn.isdirectory(root) ~= 1 then
    sv.err("testing ci runner-guard: no runner folder: " .. root)
    return 2
  end
  local nvim, script = tools(ctx)
  local hook = (root .. "/_guard/job-started.ps1"):gsub("/", "\\")
  local function ours(v)
    return vim.fs.normalize(v):lower() == vim.fs.normalize(hook):lower()
  end
  local code = 0
  if action == "install" then
    local ok, err = require("lib.nvim.fs.write.atomic")(
      root .. "/_guard/job-started.ps1",
      M.hook_text(nvim, script),
      { mkdirp = true }
    )
    if not ok then
      sv.err("testing ci runner-guard: cannot write the hook: " .. tostring(err))
      return 3
    end
  end
  for _, name in ipairs(runner_dirs(root)) do
    local env_path = root .. "/" .. name .. "/.env"
    local text = read_env(env_path)
    local values = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
      values[#values + 1] = hook_value(line)
    end
    local state = not text and "unreadable .env"
      or (#values == 0 and "not guarded")
      or (#values == 1 and ours(values[1]) and "guarded" or "foreign hook")
    if action == "status" then
      sv.out(("%-16s %s"):format(name, state))
    else
      local ok, res = edit_env(env_path, action == "install" and hook or nil, ours)
      if not ok then
        sv.err(("%-16s cannot write .env: %s"):format(name, tostring(res)))
        code = 3
      elseif res == "foreign" then
        sv.err(("%-16s has a hook of its own: left alone"):format(name))
        code = 1
      else
        sv.out(
          ("%-16s %s (a running runner reads .env after stop and start)"):format(
            name,
            action == "install" and "guarded" or "not guarded"
          )
        )
      end
    end
  end
  if action == "remove" then
    pcall(uv.fs_unlink, root .. "/_guard/job-started.ps1")
  end
  if action == "status" then
    local repos, note = M.read(M.store_path(root))
    sv.out(
      ("hook script: %s"):format(
        uv.fs_stat(root .. "/_guard/job-started.ps1") and "present" or "missing"
      )
    )
    sv.out(
      ("reviewed list: %d repositor%s%s"):format(
        vim.tbl_count(repos),
        vim.tbl_count(repos) == 1 and "y" or "ies",
        note and (" (" .. note .. ")") or ""
      )
    )
  end
  return code
end

---`testing ci runner-guard ...`.
---@param argv string[]
---@param sv table
---@param ctx? Testing.RunnerGuard.Ctx
---@return integer
function M.main(argv, sv, ctx)
  local sub = argv[1]
  if sub == "check" and #argv == 1 then
    return check(sv, ctx)
  end
  if sub == "install" or sub == "remove" or sub == "status" then
    return manage(sub, vim.list_slice(argv, 2), sv, ctx)
  end
  sv.err(M.USAGE)
  return 2
end

return M
