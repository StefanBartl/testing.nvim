-- TESTS/testing/ci_remote_spec.lua -- `testing ci remote`: the latest GitHub Actions run of the CI workflow per
-- repository and system, through a fake git and a fake GitHub (the transport of lib.nvim.net.github): the workflow
-- filter, a run with zero jobs, a self-hosted job without a runner, cancelled, skipped, no run, a host that is not
-- GitHub, the ETag cache, no token, and that the token never reaches an output or a file. No real network call.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local remote = require("testing.ci.remote")
  local cli = require("testing.cli")
  local project = require("testing.config.project")

  -- ------------------------------------------------------------------ pure parts

  do
    local function origin(url)
      return { remote.parse_origin(url) }
    end
    eq(
      origin("https://github.com/WKDSteve/testing.nvim.git"),
      { "WKDSteve", "testing.nvim" },
      "origin: https"
    )
    eq(
      origin("https://github.com/WKDSteve/lib.nvim"),
      { "WKDSteve", "lib.nvim" },
      "origin: https without .git"
    )
    eq(
      origin("https://user@github.com/a-b/c_d/\n"),
      { "a-b", "c_d" },
      "origin: user, trailing slash and newline"
    )
    eq(origin("git@github.com:WKDSteve/beta.git"), { "WKDSteve", "beta" }, "origin: scp-like ssh")
    eq(
      origin("ssh://git@github.com:22/WKDSteve/gamma.nvim.git"),
      { "WKDSteve", "gamma.nvim" },
      "origin: ssh://"
    )
    eq(origin("https://gitlab.com/WKDSteve/x.git"), {}, "origin: another host is not GitHub")
    eq(origin("E:/repos/bare.git"), {}, "origin: a local path is not GitHub")
    eq(origin("https://github.com/a/b/c"), {}, "origin: a path that is not owner/repo")
    eq(origin(""), {}, "origin: empty")

    eq(remote.epoch("1970-01-02T00:00:00Z"), 86400, "epoch: one day")
    eq(remote.epoch("2000-03-01T00:00:00Z"), 951868800, "epoch: after a leap day")
    eq(remote.epoch("not a time"), nil, "epoch: garbage")

    local now = remote.epoch("2026-10-31T12:00:00Z")
    local function job(t)
      t.id = t.id or 1
      t.name = t.name or "j"
      t.labels = t.labels or {}
      return t
    end
    eq(
      remote.job_state(job({ status = "completed", conclusion = "timed_out" }), now),
      "failure",
      "job: timed out"
    )
    eq(
      remote.job_state(job({ status = "completed", conclusion = "neutral" }), now),
      "skipped",
      "job: neutral"
    )
    eq(remote.job_state(job({ status = "in_progress" }), now), "running", "job: in progress")
    eq(
      remote.job_state(
        job({ status = "queued", labels = { "ubuntu-latest" }, created_at = "2026-10-31T11:00:00Z" }),
        now
      ),
      "queued",
      "job: a hosted queued job is queued however long it waits"
    )
    eq(
      remote.job_state(job({ status = "weird" }), now),
      "unknown",
      "job: an unknown status is never green"
    )
    eq(remote.job_os(job({ name = "test (windows-latest)" })), "windows", "os: by name")
    eq(
      remote.job_os(job({ name = "build", labels = { "self-hosted", "Linux" } })),
      "ubuntu",
      "os: by label"
    )
    eq(remote.job_os(job({ name = "luacheck" })), "other", "os: none is other")
    eq(
      remote.job_os(job({ name = "stylua", labels = { "ubuntu-latest" } })),
      "other",
      "os: a hosted gate job is other, whatever image it runs on"
    )
    eq(
      remote.pick_run({ { id = 1, name = "ci", created_at = "2026-10-31T11:00:00Z" } }, "CI").id,
      1,
      "pick: the workflow name is compared without case"
    )
  end

  do
    local cfg, problems = project.validate({ ci_remote = { workflow = "Build", branch = "trunk" } })
    eq(problems, {}, "config: ci_remote is a known key")
    eq(
      cfg.ci_remote,
      { workflow = "Build", branch = "trunk", non_gating = { "nightly" } },
      "config: merged"
    )
    local _, bad = project.validate({ ci_remote = { workflow = "", branch = "-x", nope = 1 } })
    eq(
      #bad,
      3,
      "config: an empty workflow, a branch like an option and an unknown key: " .. vim.inspect(bad)
    )
  end

  -- ------------------------------------------------------------------ a fake fleet

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-remote"
  local state = tmp .. "/state"
  local NOW = remote.epoch("2026-10-31T12:00:00Z")
  local TOKEN = "ghp_SECRET_test_token_0123456789"

  local function sha(c)
    return c:rep(40)
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---dir -> { url, sha, msg }
  local GIT = {}
  local function repo(name, url, head, msg, opts)
    local dir = tmp .. "/repos/" .. name
    vim.fn.mkdir(dir, "p")
    if opts and opts.workflows then
      vim.fn.mkdir(dir .. "/.github/workflows", "p")
    end
    GIT[dir] = { url = url, sha = head, msg = msg or "a commit" }
    return dir
  end

  local function run_(id, name, status, conclusion, created, extra)
    local r = {
      id = id,
      name = name,
      status = status,
      conclusion = conclusion == nil and vim.NIL or conclusion,
      created_at = created,
      updated_at = created,
      html_url = "https://github.com/x/runs/" .. id,
      event = "push",
    }
    return vim.tbl_extend("force", r, extra or {})
  end
  local function job_(id, name, status, conclusion, extra)
    local j = {
      id = id,
      name = name,
      status = status,
      conclusion = conclusion == nil and vim.NIL or conclusion,
      html_url = "https://github.com/x/jobs/" .. id,
      labels = {},
      created_at = "2026-10-31T11:00:00Z",
    }
    return vim.tbl_extend("force", j, extra or {})
  end

  local dirs = {
    alpha = repo("alpha", "https://github.com/WKDSteve/alpha.nvim.git", sha("a")),
    beta = repo("beta", "git@github.com:WKDSteve/beta.git", sha("b")),
    gamma = repo("gamma", "ssh://git@github.com/WKDSteve/gamma.nvim", sha("c")),
    delta = repo("delta", "https://github.com/WKDSteve/delta", sha("d")),
    eps = repo("eps", "https://github.com/WKDSteve/eps", sha("e")),
    skipci = repo(
      "skipci",
      "https://github.com/WKDSteve/skipci",
      sha("f"),
      "docs: map\n\n[skip ci]\n"
    ),
    allskip = repo("allskip", "https://github.com/WKDSteve/allskip", sha("1")),
    zeta = repo("zeta", "https://gitlab.com/WKDSteve/zeta.git", sha("2")),
  }

  local R = "/repos/WKDSteve/"
  ---path -> { etag, body } (body: a table to encode or a JSON text)
  local API = {
    [R .. "alpha.nvim/actions/runs"] = {
      etag = '"runs-alpha"',
      body = {
        workflow_runs = {
          run_(10, "CI", "completed", "success", "2026-10-31T11:00:00Z"),
          -- a path-filtered sibling workflow, created later for the same push: must not be the verdict
          run_(11, "pages", "completed", "failure", "2026-10-31T11:30:00Z"),
          run_(9, "CI", "completed", "failure", "2026-10-31T10:00:00Z"),
        },
      },
    },
    [R .. "alpha.nvim/actions/runs/10/jobs"] = {
      etag = '"jobs-alpha"',
      body = {
        jobs = {
          job_(101, "test (ubuntu-latest)", "completed", "success"),
          job_(102, "test (windows-latest)", "completed", "success"),
          job_(103, "test (macos-latest)", "completed", "success"),
          job_(104, "luacheck", "completed", "success", { labels = { "ubuntu-latest" } }),
          job_(105, "nightly (ubuntu-latest)", "completed", "failure"),
        },
      },
    },
    [R .. "beta/actions/runs"] = {
      etag = '"runs-beta"',
      body = { workflow_runs = { run_(20, "CI", "completed", "failure", "2026-10-31T11:00:00Z") } },
    },
    [R .. "beta/actions/runs/20/jobs"] = {
      etag = '"jobs-beta"',
      body = '{"total_count":0,"jobs":[]}',
    },
    [R .. "gamma.nvim/actions/runs"] = {
      etag = '"runs-gamma"',
      body = { workflow_runs = { run_(30, "CI", "queued", nil, "2026-10-31T11:50:00Z") } },
    },
    [R .. "gamma.nvim/actions/runs/30/jobs"] = {
      etag = '"jobs-gamma"',
      body = {
        jobs = {
          -- ten minutes in the queue of a self-hosted runner: the runner is off
          job_(
            301,
            "build",
            "queued",
            nil,
            { labels = { "self-hosted", "Windows" }, created_at = "2026-10-31T11:50:00Z" }
          ),
          -- thirty seconds: still just queued
          job_(
            302,
            "build-linux",
            "queued",
            nil,
            { labels = { "self-hosted", "Linux" }, created_at = "2026-10-31T11:59:30Z" }
          ),
        },
      },
    },
    [R .. "delta/actions/runs"] = {
      etag = '"runs-delta"',
      body = {
        workflow_runs = { run_(40, "CI", "completed", "cancelled", "2026-10-31T11:00:00Z") },
      },
    },
    [R .. "delta/actions/runs/40/jobs"] = {
      etag = '"jobs-delta"',
      body = {
        jobs = {
          job_(401, "test (ubuntu-latest)", "completed", "cancelled"),
          job_(402, "test (windows-latest)", "completed", "success"),
        },
      },
    },
    [R .. "eps/actions/runs"] = {
      etag = '"runs-eps"',
      body = '{"total_count":0,"workflow_runs":[]}',
    },
    [R .. "skipci/actions/runs"] = {
      etag = '"runs-skipci"',
      body = {
        workflow_runs = { run_(60, "pages", "completed", "success", "2026-10-31T11:00:00Z") },
      },
    },
    [R .. "allskip/actions/runs"] = {
      etag = '"runs-allskip"',
      body = { workflow_runs = { run_(70, "CI", "completed", "skipped", "2026-10-31T11:00:00Z") } },
    },
    [R .. "allskip/actions/runs/70/jobs"] = {
      etag = '"jobs-allskip"',
      body = { jobs = { job_(701, "test (ubuntu-latest)", "completed", "skipped") } },
    },
  }

  local requests = {}
  local transport_fail = nil
  local function transport(url, copts, done)
    local path = url:gsub("^https://api%.github%.com", "")
    requests[#requests + 1] = {
      path = path,
      url = url,
      query = copts.query,
      etag = copts.headers and copts.headers["If-None-Match"],
      token = copts.bearer_token,
    }
    if transport_fail then
      return done(false, transport_fail)
    end
    local entry = API[path]
    if not entry then
      return done(
        true,
        { status = 404, status_text = "Not Found", headers = {}, body = '{"message":"Not Found"}' }
      )
    end
    local headers = { etag = entry.etag, ["x-ratelimit-remaining"] = "4999" }
    if copts.headers and copts.headers["If-None-Match"] == entry.etag then
      return done(
        true,
        { status = 304, status_text = "Not Modified", headers = headers, body = "" }
      )
    end
    local body = type(entry.body) == "string" and entry.body or vim.json.encode(entry.body)
    done(true, { status = 200, status_text = "OK", headers = headers, body = body })
  end

  local function git(dir, args)
    local g = GIT[dir]
    local res
    if not g then
      res = { code = 128, stdout = "", stderr = "not a git repository" }
    elseif args[1] == "remote" then
      res = g.url and { code = 0, stdout = g.url .. "\n" }
        or { code = 2, stdout = "", stderr = "no such remote" }
    elseif args[1] == "log" then
      eq(
        args[#args - 1],
        "origin/" .. (g.branch or "main"),
        "git: the head of origin/<branch> is asked for"
      )
      res = { code = 0, stdout = g.sha .. "\n" .. g.msg }
    end
    return {
      wait = function()
        return res
      end,
    }
  end

  local function run(args, opts)
    opts = opts or {}
    local out, err = {}, {}
    local real = remote.deps
    remote.deps = {
      git = git,
      transport = transport,
      now = function()
        return NOW
      end,
      token = opts.token or function()
        return TOKEN, "env:" .. remote.TOKEN_ENV
      end,
    }
    requests = {}
    local pass, code = pcall(cli.main, vim.list_extend({ "ci", "remote" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
    })
    remote.deps = real
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n"), lines = out }
  end

  local function by_repo(doc)
    local t = {}
    for _, r in ipairs(doc.repos) do
      t[r.repo] = r
    end
    return t
  end

  local all = {}
  for _, name in ipairs({ "zeta", "alpha", "beta", "gamma", "delta", "eps", "skipci", "allskip" }) do
    all[#all + 1] = dirs[name]
  end

  -- ------------------------------------------------------------------ the first fetch

  local first = run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
  eq(
    first.code,
    remote.EXIT_RED,
    "exit: a rejected and a cancelled repository are red (" .. first.err .. ")"
  )
  local doc = vim.json.decode(first.out)
  eq(doc.schema, "testing-ci-remote/1", "doc: schema")
  eq(doc.generated_at, "2026-10-31T12:00:00Z", "doc: generated_at")
  eq(
    doc.token_source,
    "env:TESTING_GITHUB_TOKEN",
    "doc: where the token came from (never the token)"
  )
  local names = vim.tbl_map(function(r)
    return r.repo
  end, doc.repos)
  eq(
    names,
    { "allskip", "alpha.nvim", "beta", "delta", "eps", "gamma.nvim", "skipci", "zeta" },
    "doc: sorted by name"
  )
  local rec = by_repo(doc)

  local a = rec["alpha.nvim"]
  eq(
    { a.owner, a.sha, a.branch, a.workflow },
    { "WKDSteve", sha("a"), "main", "CI" },
    "alpha: owner, sha, branch, workflow"
  )
  eq(a.run.id, 10, "alpha: the newest CI run, not the later pages run nor the older CI run")
  eq(a.overall, "success", "alpha: green")
  eq(
    a.os.ubuntu,
    { state = "success", url = "https://github.com/x/jobs/101", job = "test (ubuntu-latest)" },
    "alpha: ubuntu cell"
  )
  eq(
    { a.os.windows.state, a.os.macos.state, a.os.other.state },
    { "success", "success", "success" },
    "alpha: cells"
  )
  eq(a.non_gating, {
    { name = "nightly (ubuntu-latest)", state = "failure", url = "https://github.com/x/jobs/105" },
  }, "alpha: nightly listed apart")
  has(a.note, "non-gating red: nightly", "alpha: ... and noted, without turning the repository red")

  eq(
    rec.beta.overall,
    "rejected",
    "beta: a completed run with zero jobs is a rejected workflow, not a pass"
  )
  has(rec.beta.note, "0 jobs", "beta: ... said so")
  eq(rec["gamma.nvim"].overall, "waiting_runner", "gamma: a self-hosted job queued for ten minutes")
  eq(rec["gamma.nvim"].os.windows.state, "waiting_runner", "gamma: ... in the windows cell")
  eq(
    rec["gamma.nvim"].os.ubuntu.state,
    "queued",
    "gamma: thirty seconds in the queue is just queued"
  )
  eq(rec.delta.overall, "cancelled", "delta: cancelled")
  eq(rec.eps.overall, "no_run", "eps: no run for the commit")
  has(rec.eps.note, "eeeeeee", "eps: ... names the commit")
  eq(
    rec.skipci.overall,
    "skipped",
    "skipci: a [skip ci] head without a CI run (the pages run does not count)"
  )
  eq(rec.allskip.overall, "skipped", "allskip: every job skipped")
  eq(rec.zeta.overall, "no_github", "zeta: a GitLab origin")
  eq(rec.zeta.owner, nil, "zeta: no owner")
  for _, r in ipairs(requests) do
    eq(r.token, TOKEN, "request: the token goes to curl's options")
    lacks(r.url, TOKEN, "request: never into the URL")
    ok(
      not r.path:find("zeta", 1, true),
      "request: nothing is asked about a repository that is not on GitHub"
    )
  end
  local runs_q = vim.tbl_filter(function(r)
    return r.path == R .. "alpha.nvim/actions/runs"
  end, requests)
  eq(
    runs_q[1].query,
    { head_sha = sha("a"), per_page = "20" },
    "request: the runs of the head commit, not of the branch"
  )
  eq(runs_q[1].etag, nil, "request: nothing stored yet, no If-None-Match")
  lacks(first.out, TOKEN, "the token is not in the output")
  lacks(first.err, TOKEN, "the token is not in the errors")

  -- ------------------------------------------------------------------ the cache: 304 and unchanged jobs

  local second = run(vim.list_extend({ "--json" }, vim.deepcopy(all)))
  eq(
    second.out,
    first.out,
    "deterministic: the same answers give the same bytes (the second from the cache)"
  )
  local asked = {}
  for _, r in ipairs(requests) do
    asked[r.path] = r.etag or "none"
  end
  eq(
    asked[R .. "alpha.nvim/actions/runs"],
    '"runs-alpha"',
    "cache: the runs are asked with If-None-Match"
  )
  eq(
    asked[R .. "alpha.nvim/actions/runs/10/jobs"],
    nil,
    "cache: the jobs of an unchanged completed run are not asked"
  )
  eq(
    asked[R .. "gamma.nvim/actions/runs/30/jobs"],
    '"jobs-gamma"',
    "cache: the jobs of an open run are asked again, conditionally"
  )
  for _, f in ipairs(vim.fn.glob(state .. "/testing/ci-remote/*.json", true, true)) do
    local fh = assert(io.open(f, "rb"))
    local text = fh:read("*a")
    fh:close()
    lacks(text, TOKEN, "cache: the token is in no cache file (" .. f .. ")")
  end
  eq(
    #vim.fn.glob(state .. "/testing/ci-remote/*.json", true, true),
    7,
    "cache: one file per GitHub repository"
  )

  -- a new run (a re-run: updated_at moved) fetches the jobs again
  API[R .. "alpha.nvim/actions/runs"].etag = '"runs-alpha-2"'
  API[R .. "alpha.nvim/actions/runs"].body.workflow_runs[1].updated_at = "2026-10-31T11:45:00Z"
  API[R .. "alpha.nvim/actions/runs/10/jobs"].body.jobs[2].conclusion = "failure"
  API[R .. "alpha.nvim/actions/runs/10/jobs"].etag = '"jobs-alpha-2"'
  local third = run({ "--json", dirs.alpha })
  asked = {}
  for _, r in ipairs(requests) do
    asked[r.path] = r.etag or "none"
  end
  eq(
    asked[R .. "alpha.nvim/actions/runs/10/jobs"],
    '"jobs-alpha"',
    "cache: a changed run asks for its jobs again"
  )
  eq(third.code, remote.EXIT_RED, "a red windows leg is exit 1")
  eq(vim.json.decode(third.out).repos[1].os.windows.state, "failure", "... in the windows cell")

  -- ------------------------------------------------------------------ the human table

  local tbl = run({ dirs.eps, dirs.zeta, dirs.allskip })
  eq(tbl.code, remote.EXIT_OK, "exit: no run, not GitHub and skipped are not red")
  has(tbl.lines[1], "REPO", "table: header")
  has(tbl.lines[1], "UBUNTU", "table: header names the systems")
  local row
  for _, l in ipairs(tbl.lines) do
    if l:match("^eps ") then
      row = l
    end
  end
  has(row, "no_run", "table: the eps row says no_run")
  has(tbl.out, "fully green: 0 / 3", "table: the summary line")
  local renamed = run({ dirs.alpha })
  ok(
    renamed.lines[2]:match("^alpha %(alpha%.nvim%) ") ~= nil,
    "table: a checkout named otherwise shows both names"
  )

  -- ------------------------------------------------------------------ no token, no network

  local none = run({ "--json", dirs.alpha, dirs.zeta }, {
    token = function()
      return nil, "$TESTING_GITHUB_TOKEN is not set; `gh auth token` failed (exit 1)"
    end,
  })
  eq(none.code, remote.EXIT_INFRA, "no token: exit 3")
  eq(#requests, 0, "no token: nothing is asked")
  local nd = by_repo(vim.json.decode(none.out))
  eq(nd["alpha.nvim"].overall, "unknown", "no token: unknown, never green")
  has(nd["alpha.nvim"].error, "no GitHub token", "no token: ... said so")
  eq(nd.zeta.overall, "no_github", "no token: a repository that needs none is still reported")
  has(none.err, "TESTING_GITHUB_TOKEN", "no token: the error names the variable to set")

  transport_fail = "curl: (6) Could not resolve host: api.github.com"
  local offline = run({ "--json", dirs.delta })
  transport_fail = nil
  eq(offline.code, remote.EXIT_INFRA, "offline: exit 3")
  local od = vim.json.decode(offline.out).repos[1]
  eq(od.overall, "unknown", "offline: unknown, never the cached state")
  has(od.error, "Could not resolve host", "offline: the error is kept")

  -- an API error (a 404 for a repository the token cannot see)
  local hidden = repo("hidden", "https://github.com/WKDSteve/hidden", sha("3"))
  local h = run({ "--json", hidden })
  eq(h.code, remote.EXIT_INFRA, "404: exit 3")
  has(vim.json.decode(h.out).repos[1].error, "404", "404: the status is in the error")

  -- ------------------------------------------------------------------ configuration and --workflow

  local cfgd = repo("cfgd", "https://github.com/WKDSteve/cfgd", sha("4"))
  write(
    cfgd .. "/.testing.lua",
    'return { ci_remote = { workflow = "Build", non_gating = { "Lib Suite" } } }\n'
  )
  API[R .. "cfgd/actions/runs"] = {
    etag = '"runs-cfgd"',
    body = {
      workflow_runs = {
        run_(80, "CI", "completed", "failure", "2026-10-31T11:00:00Z"),
        run_(81, "Build", "completed", "success", "2026-10-31T10:00:00Z"),
      },
    },
  }
  API[R .. "cfgd/actions/runs/81/jobs"] = {
    etag = '"jobs-cfgd"',
    body = {
      jobs = {
        job_(811, "test (ubuntu-latest)", "completed", "success"),
        job_(812, "lib suite via testing.nvim (ubuntu-latest)", "completed", "failure"),
      },
    },
  }
  API[R .. "cfgd/actions/runs/80/jobs"] = {
    etag = '"jobs-cfgd-80"',
    body = { jobs = { job_(801, "test (ubuntu-latest)", "completed", "failure") } },
  }
  local c = run({ "--json", cfgd })
  local cr = vim.json.decode(c.out).repos[1]
  eq(
    { cr.workflow, cr.run.id, cr.overall },
    { "Build", 81, "success" },
    "config: the workflow of .testing.lua"
  )
  eq(cr.os.ubuntu.job, "test (ubuntu-latest)", "config: a non-gating job is not in the OS cell")
  eq(c.code, remote.EXIT_OK, "config: exit 0")
  local w = run({ "--json", "--workflow", "CI", cfgd })
  eq(vim.json.decode(w.out).repos[1].run.id, 80, "--workflow wins over the configuration")
  eq(w.code, remote.EXIT_RED, "--workflow: ... and that run is red")

  -- ------------------------------------------------------------------ --repos-root

  local root = tmp .. "/fleet"
  local function fleet(name, url, workflows)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    if workflows then
      vim.fn.mkdir(dir .. "/.github/workflows", "p")
    end
    GIT[dir] = { url = url, sha = sha("e"), msg = "x" }
  end
  fleet("eps", "https://github.com/WKDSteve/eps", true)
  fleet("tasks-vault", "https://github.com/WKDSteve/tasks-vault", true)
  fleet("noflows", "https://github.com/WKDSteve/noflows", false)
  fleet("elsewhere", "https://gitlab.com/WKDSteve/elsewhere", true)
  local f = run({ "--json", "--repos-root", root })
  local fr = vim.json.decode(f.out).repos
  eq(
    vim.tbl_map(function(r)
      return r.repo
    end, fr),
    { "eps" },
    "--repos-root: GitHub repositories with workflows, no vault, no other host (and not `testing ci --repos-root`)"
  )

  -- ------------------------------------------------------------------ usage

  local u = run({ "--frobnicate" })
  eq(u.code, remote.EXIT_USAGE, "usage: an unknown flag is exit 2")
  has(u.err, "--frobnicate", "usage: ... named")
  eq(run({ "--help" }).code, 0, "usage: --help")
  eq(run({ tmp .. "/absent" }).code, remote.EXIT_USAGE, "usage: a root that is not a directory")

  vim.fn.delete(tmp, "rf")
end
