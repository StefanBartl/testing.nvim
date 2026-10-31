---@module 'testing.ci.remote'
---@brief `testing ci remote`: the latest GitHub Actions run of the CI workflow per repository, per system.
---@description
--- ```
--- testing ci remote [<root>...] [--repos-root=<dir>] [--json] [--workflow=<name>] [--state-dir=<dir>]
--- ```
---
--- Per repository: `owner/repo` from `git remote get-url origin` (https and ssh; any other host is `no_github`), the
--- commit from `git log -1 origin/<branch>` (no fetch: the last fetched state is what is asked about). The runs of THAT
--- commit (`actions/runs?head_sha=`), not of the branch: a fast-forward push of a commit that already ran elsewhere
--- does not always get a second run, and "the newest run of main" is then an older commit's verdict. Of those runs only
--- the workflow with the configured name counts (`ci_remote.workflow`, default "CI"): a path-filtered sibling workflow
--- can be created after the CI run for the same push. Then the jobs of the newest such run, sorted into the cells
--- ubuntu, windows, macos (by the job's name, else its labels) and other (lint, publish, ...); a job whose name
--- contains a `ci_remote.non_gating` text (default "nightly") is listed but never decides.
---
--- States, worst first (the overall state of a repository is the worst of its cells): failure, rejected (a completed
--- run with zero jobs: GitHub refused the workflow file), cancelled, unknown (no token, network or API error, an
--- unexpected answer: never green), waiting_runner (a queued job on a self-hosted runner for longer than
--- `WAITING_RUNNER_S`), queued, running, success, skipped (every job skipped, or a head commit with `[skip ci]` and no
--- run), no_run (no run of the workflow for the commit), no_github.
---
--- The token: `$TESTING_GITHUB_TOKEN` (a fine-grained read-only token: Actions and Metadata read), else `gh auth
--- token`; never `GITHUB_TOKEN` (`lib.nvim.net.github.token`). It goes to curl through its config on stdin and appears
--- in no output, no document, no cache file and no error text.
---
--- Requests are conditional: per repository the ETag and the last answer live in
--- `<state>/testing/ci-remote/<owner>_<repo>.json`; a `304` reuses the stored answer (it does not count against the
--- rate limit), and the jobs of a completed run whose `updated_at` did not change are not asked for again.
---
--- Exit codes: 0 every repository was fetched and none is red, 1 a repository is failure, rejected or cancelled, 2 a
--- usage error, 3 a repository could not be fetched (unknown) and none is red: no token, no network.

local M = {}

M.EXIT_OK, M.EXIT_RED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci-remote/1"

---The environment variable of the dedicated read-only token.
M.TOKEN_ENV = "TESTING_GITHUB_TOKEN"

---A queued job on a self-hosted runner older than this (seconds) is `waiting_runner`: the runner is off.
M.WAITING_RUNNER_S = 120

---Repositories asked about at the same time (each is at most two requests one after the other).
M.PARALLEL = 8

---How long the whole fetch may take before the repositories still open are `unknown`.
M.DEADLINE_MS = 120000

---The cells of the table, in order.
M.OS = { "ubuntu", "windows", "macos" }

---Worst first: the overall state is the first of these that a cell has.
M.ORDER = {
  "failure",
  "rejected",
  "cancelled",
  "unknown",
  "waiting_runner",
  "queued",
  "running",
  "success",
  "skipped",
  "no_run",
  "no_github",
}

local RANK = {}
for i, s in ipairs(M.ORDER) do
  RANK[s] = i
end

---What makes the exit code 1.
local RED = { failure = true, rejected = true, cancelled = true }

M.USAGE = table.concat({
  "usage: testing ci remote [<root>...] [--repos-root=<dir>] [--json] [--workflow=<name>] [--state-dir=<dir>]",
  "  <root>              a repository (default: the current directory)",
  "  --repos-root=<dir>  every directory directly below <dir> with a GitHub origin and .github/workflows",
  '                      (names containing "vault" are left out; repeatable)',
  "  --json              print the document testing-ci-remote/1 instead of the table",
  '  --workflow=<name>   the workflow of every repository (default: ci_remote.workflow, "CI")',
  "  --state-dir=<dir>   where the ETag cache lives (default: stdpath('state'))",
  "  token: $" .. M.TOKEN_ENV .. " (read-only), else `gh auth token`; never GITHUB_TOKEN",
  "  exit: 0 nothing red, 1 failure/rejected/cancelled, 2 usage, 3 a repository could not be fetched",
}, "\n")

---Replaced by a spec: the processes and the network this module uses.
M.deps = {
  ---Start `git -C <dir> <args>`; the handle's `wait()` gives `{ code, stdout, stderr }`.
  ---@param dir string
  ---@param args string[]
  ---@return { wait: fun(self): { code: integer, stdout?: string, stderr?: string } }
  git = function(dir, args)
    local argv = vim.list_extend({ "git", "-C", dir }, args)
    local ok, proc = pcall(vim.system, argv, { text = true })
    if not ok then
      return {
        wait = function()
          return { code = -1, stdout = "", stderr = tostring(proc) }
        end,
      }
    end
    return {
      wait = function()
        return proc:wait(30000)
      end,
    }
  end,
  ---@return string|nil token
  ---@return string source_or_reason
  token = function()
    return require("lib.nvim.net.github").token({ env_var = M.TOKEN_ENV })
  end,
  ---@type Lib.Net.Github.Transport|nil nil: real curl.
  transport = nil,
  ---@return integer seconds since the epoch
  now = function()
    return os.time()
  end,
}

---@class Testing.Ci.Remote.Args
---@field roots string[]
---@field repos_roots string[]
---@field json boolean
---@field workflow? string
---@field state_dir? string
---@field help boolean

local VALUED = { ["repos-root"] = true, workflow = true, ["state-dir"] = true }

---@param argv string[] The arguments after `remote`.
---@return Testing.Ci.Remote.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Remote.Args
  local args = { roots = {}, repos_roots = {}, json = false, help = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "json" and value == nil then
      args.json = true
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
      if key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "state-dir" then
        args.state_dir = value
      else
        args.workflow = value
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.roots[#args.roots + 1] = a
    end
    i = i + 1
  end
  return args
end

---Text from GitHub or git, fit for a terminal and a document: no control characters, bounded.
---@param s any
---@param max? integer
---@return string|nil
local function text(s, max)
  if type(s) ~= "string" then
    return nil
  end
  s = s:gsub("%c", " ")
  max = max or 300
  return #s > max and s:sub(1, max) or s
end

---`owner`, `repo` of a GitHub remote URL (https, ssh, scp-like); nil for any other host.
---@param url string
---@return string|nil owner
---@return string|nil repo
function M.parse_origin(url)
  url = vim.trim(url or "")
  local host, path = url:match("^%a[%w+.-]*://([^/]+)/(.+)$")
  if not host then
    -- scp-like `git@github.com:owner/repo.git` (a drive letter `E:/x` has a one-letter host, never github.com)
    host, path = url:match("^([^/:]+):(.+)$")
  end
  if not host then
    return nil
  end
  host = host:gsub("^.*@", ""):gsub(":%d*$", ""):lower()
  if host ~= "github.com" and host ~= "www.github.com" then
    return nil
  end
  path = path:gsub("^/+", ""):gsub("/+$", ""):gsub("%.git$", "")
  local owner, repo = path:match("^([%w%-_.]+)/([%w%-_.]+)$")
  if not owner or repo == "." or repo == ".." then
    return nil
  end
  return owner, repo
end

---Seconds since the epoch of a GitHub timestamp `2026-10-31T12:00:00Z` (UTC, without the local zone).
---@param ts any
---@return integer|nil
function M.epoch(ts)
  if type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    return nil
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days from the civil date (Howard Hinnant's algorithm): no os.time, which reads the local zone
  y = mo <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

---A run as far as this module needs it; nil for anything that is not one (the answer and the cache are untrusted).
---@param raw any
---@return table|nil
local function trim_run(raw)
  if type(raw) ~= "table" or type(raw.id) ~= "number" then
    return nil
  end
  return {
    id = raw.id,
    name = text(raw.name, 200),
    status = text(raw.status, 40),
    conclusion = text(raw.conclusion, 40),
    created_at = text(raw.created_at, 40),
    updated_at = text(raw.updated_at, 40),
    html_url = text(raw.html_url, 500),
    head_sha = text(raw.head_sha, 64),
    event = text(raw.event, 40),
    run_attempt = type(raw.run_attempt) == "number" and raw.run_attempt or nil,
  }
end

---@param raw any
---@return table|nil
local function trim_job(raw)
  if type(raw) ~= "table" or type(raw.id) ~= "number" then
    return nil
  end
  local labels = {}
  if type(raw.labels) == "table" then
    for _, l in ipairs(raw.labels) do
      labels[#labels + 1] = text(l, 100)
    end
  end
  return {
    id = raw.id,
    name = text(raw.name, 200) or "",
    status = text(raw.status, 40),
    conclusion = text(raw.conclusion, 40),
    html_url = text(raw.html_url, 500),
    created_at = text(raw.created_at, 40),
    started_at = text(raw.started_at, 40),
    labels = labels,
  }
end

---@param list any
---@param trim fun(raw: any): table|nil
---@return table[]|nil
local function trim_list(list, trim)
  if type(list) ~= "table" then
    return nil
  end
  local out = {}
  for _, raw in ipairs(list) do
    out[#out + 1] = trim(raw)
  end
  return out
end

---The newest run of `workflow` (by `created_at`, then id); nil when there is none. The name is compared without
---case: the repositories spell their CI workflow `CI` and `ci`.
---@param runs table[]
---@param workflow string
---@return table|nil
function M.pick_run(runs, workflow)
  local best
  workflow = workflow:lower()
  for _, r in ipairs(runs) do
    if r.name and r.name:lower() == workflow then
      local key = (r.created_at or "") .. ("%020d"):format(r.id)
      if not best or key > best.key then
        best = { key = key, run = r }
      end
    end
  end
  return best and best.run
end

---@param job table
---@return boolean
local function self_hosted(job)
  for _, l in ipairs(job.labels or {}) do
    if l:lower() == "self-hosted" then
      return true
    end
  end
  return false
end

---The state of one job.
---@param job table
---@param now integer
---@param fallback_ts? string When the job has no `created_at`: the run's.
---@return string
function M.job_state(job, now, fallback_ts)
  local s, c = job.status, job.conclusion
  if s == "completed" then
    if c == "success" then
      return "success"
    elseif c == "cancelled" then
      return "cancelled"
    elseif c == "skipped" or c == "neutral" then
      return "skipped"
    elseif c == "failure" or c == "timed_out" or c == "startup_failure" then
      return "failure"
    end
    return "unknown"
  elseif s == "in_progress" then
    return "running"
  elseif s == "queued" or s == "waiting" or s == "pending" or s == "requested" then
    local since = M.epoch(job.created_at) or M.epoch(fallback_ts)
    if self_hosted(job) and since and now - since >= M.WAITING_RUNNER_S then
      return "waiting_runner"
    end
    return "queued"
  end
  return "unknown"
end

---The cell of a job: an OS named in its name, else, on a self-hosted runner, in its labels (`linux` is ubuntu);
---"other" for none. A hosted job without an OS in its name is a gate (stylua, luacheck, publish) whatever image it
---runs on: its `ubuntu-latest` says nothing about the ubuntu leg.
---@param job table
---@return string
function M.job_os(job)
  local name = job.name:lower()
  for _, sys in ipairs(M.OS) do
    if name:find(sys, 1, true) then
      return sys
    end
  end
  if not self_hosted(job) then
    return "other"
  end
  for _, l in ipairs(job.labels or {}) do
    l = l:lower()
    if l:find("ubuntu", 1, true) or l == "linux" then
      return "ubuntu"
    elseif l:find("windows", 1, true) then
      return "windows"
    elseif l:find("macos", 1, true) then
      return "macos"
    end
  end
  return "other"
end

---@param a string|nil
---@param b string|nil
---@return string|nil the worse of the two
local function worse(a, b)
  if a == nil then
    return b
  elseif b == nil then
    return a
  end
  return RANK[a] <= RANK[b] and a or b
end

---Skip markers GitHub honours in a head commit message.
local SKIP = { "[skip ci]", "[ci skip]", "[no ci]", "[skip actions]", "[actions skip]" }

---@param message string|nil
---@return boolean
local function has_skip_marker(message)
  message = (message or ""):lower()
  for _, m in ipairs(SKIP) do
    if message:find(m, 1, true) then
      return true
    end
  end
  return false
end

---Fill `rec` (the record of one repository) from its run and that run's jobs.
---@param rec table
---@param run table
---@param jobs table[]
---@param non_gating string[] Lowercase texts.
---@param now integer
function M.classify(rec, run, jobs, non_gating, now)
  rec.run = {
    id = run.id,
    url = run.html_url,
    status = run.status,
    conclusion = run.conclusion,
    created_at = run.created_at,
    updated_at = run.updated_at,
    event = run.event,
    attempt = run.run_attempt,
  }
  local notes = {}
  if #jobs == 0 then
    if run.status == "completed" then
      if run.conclusion == "skipped" then
        rec.overall = "skipped"
      else
        -- GitHub created the run, found the workflow file invalid and failed it without starting anything: every
        -- per-job query is empty, which reads like "nothing red" when only red jobs are counted
        rec.overall = "rejected"
        notes[#notes + 1] = "WORKFLOW REJECTED (0 jobs)"
      end
    else
      rec.overall = run.status == "in_progress" and "running" or "queued"
      notes[#notes + 1] = "no jobs yet"
    end
    rec.note = table.concat(notes, "; ")
    return
  end

  table.sort(jobs, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.id < b.id
  end)
  local cells = {}
  local others_red, ng = {}, {}
  for _, job in ipairs(jobs) do
    local state = M.job_state(job, now, run.created_at)
    local lname = job.name:lower()
    local gating = true
    for _, t in ipairs(non_gating) do
      if lname:find(t, 1, true) then
        gating = false
        break
      end
    end
    if not gating then
      ng[#ng + 1] = { name = job.name, state = state, url = job.html_url }
    else
      local sys = M.job_os(job)
      local cell = cells[sys]
      if not cell or worse(cell.state, state) ~= cell.state then
        cells[sys] = { state = state, url = job.html_url, job = job.name }
      end
      if sys == "other" and RED[state] then
        others_red[#others_red + 1] = job.name
      end
    end
  end
  local overall
  for _, cell in pairs(cells) do
    overall = worse(overall, cell.state)
  end
  -- a run that concluded red although no job did (a startup failure after the jobs) is not green
  if
    run.status == "completed"
    and (overall == "success" or overall == "skipped")
    and (
      run.conclusion == "failure"
      or run.conclusion == "startup_failure"
      or run.conclusion == "timed_out"
    )
  then
    overall = "failure"
    notes[#notes + 1] = "run concluded " .. run.conclusion
  end
  rec.overall = overall or "unknown"
  rec.os = require("lib.nvim.json.canonical").object(cells)
  if #others_red > 0 then
    notes[#notes + 1] = "also red: " .. table.concat(vim.list_slice(others_red, 1, 2), ", ")
  end
  if #ng > 0 then
    rec.non_gating = ng
    local red = {}
    for _, j in ipairs(ng) do
      if RED[j.state] then
        red[#red + 1] = j.name
      end
    end
    if #red > 0 then
      notes[#notes + 1] = "non-gating red: " .. table.concat(vim.list_slice(red, 1, 2), ", ")
    end
  end
  if run.status ~= "completed" then
    notes[#notes + 1] = "run " .. tostring(run.status)
  end
  if #notes > 0 then
    rec.note = table.concat(notes, "; ")
  end
end

---@param state_dir string
---@param rec table
---@return string
local function cache_path(state_dir, rec)
  return ("%s/testing/ci-remote/%s_%s.json"):format(state_dir, rec.owner, rec.repo)
end

---The stored answers of a repository (untrusted: bounded, decoded under pcall, every entry trimmed again).
---@param path string
---@return table|nil
local function read_cache(path)
  local raw = require("lib.nvim.fs.read_bounded")(path, 4 * 1024 * 1024)
  if not raw then
    return nil
  end
  local ok, doc = pcall(vim.json.decode, raw)
  if not ok or type(doc) ~= "table" or doc.v ~= 1 then
    return nil
  end
  local out = { sha = text(doc.sha, 64) }
  if type(doc.runs) == "table" and type(doc.runs.etag) == "string" then
    local list = trim_list(doc.runs.list, trim_run)
    if list then
      out.runs = { etag = doc.runs.etag, list = list }
    end
  end
  local j = doc.jobs
  if type(j) == "table" and type(j.run_id) == "number" then
    local list = trim_list(j.list, trim_job)
    if list then
      out.jobs = {
        run_id = j.run_id,
        run_status = text(j.run_status, 40),
        run_updated_at = text(j.run_updated_at, 40),
        etag = type(j.etag) == "string" and j.etag or nil,
        list = list,
      }
    end
  end
  return out
end

---@param path string
---@param cache table
local function write_cache(path, cache)
  cache.v = 1
  local ok, enc = pcall(require("lib.nvim.json.canonical").encode, cache)
  if ok then
    -- a convenience, not part of the verdict: a cache that cannot be written only costs a full request next time
    pcall(require("lib.nvim.fs.write.atomic"), path, enc, { mkdirp = true })
  end
end

---Ask GitHub about one repository; `done()` once `rec` is filled.
---@param rec table
---@param ctx { token: string, state_dir: string, now: integer, non_gating: table<table, string[]> }
---@param done fun()
local function fetch(rec, ctx, done)
  local github = require("lib.nvim.net.github")
  local path = cache_path(ctx.state_dir, rec)
  local cache = read_cache(path) or {}
  local fresh = { sha = rec.sha }
  local finished = false
  local function finish(err)
    if finished then
      return
    end
    finished = true
    if err then
      -- an error text never carries the token (lib.nvim.net.github) — and is cut and cleaned here all the same
      rec.overall = "unknown"
      rec.error = text((tostring(err):gsub(vim.pesc(ctx.token), "***")), 300)
      rec.note = rec.error
    else
      write_cache(path, fresh)
    end
    done()
  end
  local function opts(etag, query)
    return { token = ctx.token, etag = etag, query = query, transport = M.deps.transport }
  end

  local base = ("/repos/%s/%s/actions/runs"):format(rec.owner, rec.repo)
  -- the stored ETag belongs to the runs of the stored commit only
  local runs_cache = cache.sha == rec.sha and cache.runs or nil
  github.request(
    base,
    opts(runs_cache and runs_cache.etag, { head_sha = rec.sha, per_page = "20" }),
    function(res, err)
      local ok, perr = pcall(function()
        if not res then
          return finish(err)
        end
        local runs
        if res.not_modified and runs_cache then
          runs = runs_cache.list
          fresh.runs = { etag = res.etag or runs_cache.etag, list = runs }
        else
          runs = trim_list(type(res.data) == "table" and res.data.workflow_runs, trim_run)
          if not runs then
            return finish("GitHub answered the runs without a workflow_runs list")
          end
          fresh.runs = res.etag and { etag = res.etag, list = runs } or nil
        end
        local run = M.pick_run(runs, rec.workflow)
        if not run then
          if has_skip_marker(rec.message) then
            rec.overall = "skipped"
            rec.note = "head commit has [skip ci]"
          else
            rec.overall = "no_run"
            rec.note = ("no %s run for %s"):format(rec.workflow, rec.sha:sub(1, 7))
          end
          return finish()
        end
        local jc = cache.jobs and cache.jobs.run_id == run.id and cache.jobs or nil
        -- a completed run that did not change since its jobs were stored: no request at all
        if
          jc
          and run.status == "completed"
          and jc.run_status == "completed"
          and jc.run_updated_at == run.updated_at
        then
          fresh.jobs = jc
          M.classify(rec, run, vim.deepcopy(jc.list), ctx.non_gating[rec], ctx.now)
          return finish()
        end
        github.request(
          ("%s/%d/jobs"):format(base, run.id),
          opts(jc and jc.etag, { per_page = "100" }),
          function(res2, err2)
            local ok2, perr2 = pcall(function()
              if not res2 then
                return finish(err2)
              end
              local jobs
              if res2.not_modified and jc then
                jobs = jc.list
              else
                jobs = trim_list(type(res2.data) == "table" and res2.data.jobs, trim_job)
                if not jobs then
                  return finish("GitHub answered the jobs without a jobs list")
                end
              end
              fresh.jobs = {
                run_id = run.id,
                run_status = run.status,
                run_updated_at = run.updated_at,
                etag = res2.etag or (jc and jc.etag),
                list = jobs,
              }
              M.classify(rec, run, vim.deepcopy(jobs), ctx.non_gating[rec], ctx.now)
              finish()
            end)
            if not ok2 then
              finish("internal error: " .. tostring(perr2))
            end
          end
        )
      end)
      if not ok then
        finish("internal error: " .. tostring(perr))
      end
    end
  )
end

---The configuration of a repository's `ci_remote` (its `.testing.lua`; the defaults without one or when it cannot be
---loaded, which the record notes).
---@param dir string
---@return { workflow: string, branch: string, non_gating: string[] } cfg
---@return string|nil problem
local function repo_config(dir)
  local defaults = require("testing.config.DEFAULTS").project.ci_remote
  if not vim.uv.fs_stat(dir .. "/.testing.lua") then
    return vim.deepcopy(defaults)
  end
  local ok, loaded = pcall(require("testing.config.project").load, dir)
  if not ok then
    return vim.deepcopy(defaults), ".testing.lua: " .. tostring(loaded)
  end
  if loaded.error then
    return vim.deepcopy(defaults), ".testing.lua: " .. tostring(loaded.error)
  end
  return loaded.config.ci_remote
end

---The repositories of the command line: absolute directories, each marked whether it came from a `--repos-root`.
---@param args Testing.Ci.Remote.Args
---@return { dir: string, from_root: boolean }[]|nil
---@return string|nil problem
function M.resolve(args)
  local out, seen = {}, {}
  local function add(dir, from_root)
    dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "")
    if not seen[dir] then
      seen[dir] = true
      out[#out + 1] = { dir = dir, from_root = from_root }
    end
  end
  for _, root in ipairs(args.roots) do
    if vim.fn.isdirectory(root) ~= 1 then
      return nil, ("%s is not a directory"):format(root)
    end
    add(root, false)
  end
  for _, parent in ipairs(args.repos_roots) do
    if vim.fn.isdirectory(parent) ~= 1 then
      return nil, ("--repos-root %s is not a directory"):format(parent)
    end
    parent = vim.fs.normalize(vim.fn.fnamemodify(parent, ":p")):gsub("/$", "")
    local names = {}
    for name, kind in vim.fs.dir(parent) do
      -- the vaults (notes, tasks, rules) are no code repositories, even with a workflow
      if
        (kind == "directory" or kind == "link")
        and not name:lower():find("vault", 1, true)
        and vim.fn.isdirectory(parent .. "/" .. name .. "/.github/workflows") == 1
      then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      add(parent .. "/" .. name, true)
    end
  end
  if #args.roots == 0 and #args.repos_roots == 0 then
    add(".", false)
  end
  return out
end

---The records of `repos`, sorted by name; the token source (or why there is none).
---@param repos { dir: string, from_root: boolean }[]
---@param opts { workflow?: string, state_dir: string }
---@return table[] records
---@return { token_source?: string, token_error?: string } info
function M.collect(repos, opts)
  local now = M.deps.now()
  local records, non_gating = {}, {}

  -- git facts: two processes per repository, started together in slices and waited for together
  local SLICE = 16
  for first = 1, #repos, SLICE do
    local slice = {}
    for i = first, math.min(first + SLICE - 1, #repos) do
      local r = repos[i]
      local cfg, problem = repo_config(r.dir)
      local branch = cfg.branch
      slice[#slice + 1] = {
        r = r,
        cfg = cfg,
        problem = problem,
        url = M.deps.git(r.dir, { "remote", "get-url", "origin" }),
        head = M.deps.git(r.dir, { "log", "-1", "--format=%H%n%B", "origin/" .. branch, "--" }),
      }
    end
    for _, s in ipairs(slice) do
      local url_res = s.url:wait()
      local head_res = s.head:wait()
      local owner, repo
      if url_res.code == 0 then
        owner, repo = M.parse_origin(url_res.stdout or "")
      end
      -- below a --repos-root only GitHub repositories count; a named one is always reported
      if owner or not s.r.from_root then
        local rec = {
          repo = repo or vim.fs.basename(s.r.dir),
          owner = owner,
          dir = s.r.dir,
          branch = s.cfg.branch,
          workflow = opts.workflow or s.cfg.workflow,
          config_error = s.problem and text(s.problem, 300),
        }
        if not owner then
          rec.overall = "no_github"
          rec.note = url_res.code == 0 and "origin is not on GitHub" or "no origin remote"
        else
          local sha = head_res.code == 0 and (head_res.stdout or ""):match("^(%x+)") or nil
          if not sha or #sha < 40 then
            rec.overall = "unknown"
            rec.error = ("no origin/%s (not fetched?)"):format(s.cfg.branch)
            rec.note = rec.error
          else
            rec.sha = sha
            rec.message = (head_res.stdout or ""):sub(#sha + 2)
          end
        end
        local lowered = {}
        for _, t in ipairs(s.cfg.non_gating) do
          lowered[#lowered + 1] = t:lower()
        end
        non_gating[rec] = lowered
        records[#records + 1] = rec
      end
    end
  end

  local info = {}
  local pending = {}
  for _, rec in ipairs(records) do
    if rec.overall == nil then
      pending[#pending + 1] = rec
    end
  end
  if #pending > 0 then
    local ok, token, source = pcall(M.deps.token)
    if not ok then
      token, source = nil, tostring(token)
    end
    if not token then
      info.token_error = text(source, 300)
      for _, rec in ipairs(pending) do
        rec.overall = "unknown"
        rec.error = "no GitHub token: " .. info.token_error
        rec.note = "no GitHub token"
      end
    else
      info.token_source = source
      local ctx = { token = token, state_dir = opts.state_dir, now = now, non_gating = non_gating }
      local next_i, open = 1, 0
      local function launch()
        while open < M.PARALLEL and next_i <= #pending do
          local rec = pending[next_i]
          next_i = next_i + 1
          open = open + 1
          fetch(rec, ctx, function()
            open = open - 1
            launch()
          end)
        end
      end
      launch()
      vim.wait(M.DEADLINE_MS, function()
        return open == 0 and next_i > #pending
      end, 10)
      for _, rec in ipairs(pending) do
        if rec.overall == nil then
          rec.overall = "unknown"
          rec.error = "no answer within the deadline"
          rec.note = rec.error
        end
      end
    end
  end

  for _, rec in ipairs(records) do
    rec.message = nil
  end
  table.sort(records, function(a, b)
    if a.repo ~= b.repo then
      return a.repo < b.repo
    end
    return a.dir < b.dir
  end)
  return records, info
end

---The document `testing-ci-remote/1`.
---@param records table[]
---@param info table
---@param opts { workflow?: string }
---@return table
function M.document(records, info, opts)
  return {
    schema = M.SCHEMA,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", M.deps.now()),
    workflow = opts.workflow,
    token_source = info.token_source,
    token_error = info.token_error,
    repos = records,
  }
end

---@type table<string, string>
local CELL = {
  success = "ok",
  failure = "FAIL",
  cancelled = "cancelled",
  running = "running",
  queued = "queued",
  waiting_runner = "no-runner",
  skipped = "skip",
  unknown = "?",
}

---The exit code of a set of records.
---@param records table[]
---@return integer
function M.exit_code(records)
  local code = M.EXIT_OK
  for _, rec in ipairs(records) do
    if RED[rec.overall] then
      return M.EXIT_RED
    elseif rec.overall == "unknown" then
      code = M.EXIT_INFRA
    end
  end
  return code
end

---The name of a row: the repository, and the directory when that is named otherwise (a checkout of a renamed
---repository: two rows of the same repository are told apart).
---@param rec table
---@return string
local function label(rec)
  local base = vim.fs.basename(rec.dir)
  return base == rec.repo and rec.repo or ("%s (%s)"):format(base, rec.repo)
end

---The table: one row per repository (repo, ubuntu, windows, macos, note).
---@param records table[]
---@return string[]
function M.render(records)
  local width = 24
  for _, rec in ipairs(records) do
    width = math.max(width, #label(rec) + 1)
  end
  local fmt = "%-" .. width .. "s %-10s %-10s %-10s %s"
  local lines = { (fmt:format("REPO", "UBUNTU", "WINDOWS", "MACOS", "NOTE")) }
  local green = 0
  for _, rec in ipairs(records) do
    local cells = {}
    for i, sys in ipairs(M.OS) do
      local cell = rec.os and rec.os[sys]
      if cell then
        cells[i] = CELL[cell.state] or cell.state
      elseif rec.overall == "rejected" then
        cells[i] = "!"
      elseif rec.overall == "unknown" then
        cells[i] = "?"
      else
        cells[i] = "-"
      end
    end
    local note = rec.note or ""
    if rec.overall ~= "success" and not note:find(rec.overall, 1, true) then
      note = note == "" and rec.overall or (rec.overall .. ": " .. note)
    end
    if rec.config_error then
      note = (note == "" and "" or note .. "; ") .. rec.config_error
    end
    if rec.overall == "success" and note == "" then
      green = green + 1
    end
    lines[#lines + 1] = fmt:format(label(rec), cells[1], cells[2], cells[3], note)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("fully green: %d / %d"):format(green, #records)
  return lines
end

---`testing ci remote ...`.
---@param argv string[] The arguments after `remote`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci remote: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  if not pcall(require, "lib.nvim.net.github") then
    sv.err("testing ci remote: lib.nvim has no net.github (update lib.nvim)")
    return M.EXIT_INFRA
  end
  local repos, why = M.resolve(args)
  if not repos then
    sv.err("testing ci remote: " .. tostring(why))
    return M.EXIT_USAGE
  end
  local state_dir = args.state_dir or sv.state_dir or vim.fn.stdpath("state")
  local records, info = M.collect(repos, { workflow = args.workflow, state_dir = state_dir })
  if #records == 0 then
    sv.err("testing ci remote: no repository with a GitHub origin and .github/workflows found")
    return M.EXIT_USAGE
  end
  if args.json then
    sv.out(
      require("lib.nvim.json.canonical").encode(
        M.document(records, info, { workflow = args.workflow })
      )
    )
  else
    for _, line in ipairs(M.render(records)) do
      sv.out(line)
    end
  end
  if info.token_error then
    sv.err(
      ("testing ci remote: no GitHub token (%s); set $%s (read-only) or run `gh auth login`"):format(
        info.token_error,
        M.TOKEN_ENV
      )
    )
  end
  return M.exit_code(records)
end

return M
