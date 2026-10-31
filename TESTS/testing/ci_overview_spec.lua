-- TESTS/testing/ci_overview_spec.lua -- `testing ci overview`: one static HTML page of the fleet from what is already
-- there (`ci verify`, `ci.json`, the CI adapter), never a run: the repository list (vaults out, lib.nvim in, excludes),
-- that no pipeline or suite is started, HTML escaping, redaction (no absolute path), the red filter, determinism,
-- --no-remote, --json and the exit codes. A fake CI adapter; no network.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local overview = require("testing.ci.overview")
  local remote = require("testing.ci.remote")
  local cli = require("testing.cli")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-overview"
  local root = tmp .. "/fleet"
  local state = tmp .. "/state"
  local NOW = remote.epoch("2026-10-31T12:00:00Z")
  local HOME = vim.fs.normalize(vim.uv.os_homedir())

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(dir, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        ...,
      }, { cwd = dir, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end

  local CI_LUA =
    "return { plugin = 'proj', minit = false, ci = { profiles = { full = { 'suite' } } } }\n"
  -- delta's profile also has a step whose tool is asked for its version (when this machine has stylua)
  local DELTA_LUA = vim.fn.executable("stylua") == 1
      and "return { plugin = 'proj', minit = false, ci = { profiles = { full = { 'suite', 'stylua' } } } }\n"
    or CI_LUA
  ---@param name string
  ---@param o { ci?: boolean|string, testing?: boolean, workflows?: boolean, git?: boolean }
  local function repo(name, o)
    local dir = root .. "/" .. name
    vim.fn.mkdir(dir, "p")
    if o.ci then
      write(dir .. "/.testing.lua", type(o.ci) == "string" and o.ci or CI_LUA)
    elseif o.testing then
      -- a suite without a pipeline: no `ci` section
      write(dir .. "/.testing.lua", "return { plugin = 'proj', minit = false }\n")
    end
    if o.workflows then
      write(dir .. "/.github/workflows/ci.yml", "name: CI\n")
    end
    if o.git then
      git(dir, "init", "-q")
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", "init")
    end
    return dir
  end

  local alpha = repo("alpha.nvim", { ci = true, git = true })
  local beta = repo("beta.nvim", { ci = true, git = true })
  local delta = repo("delta.nvim", { ci = DELTA_LUA, git = true })
  local epsilon = repo("epsilon.nvim", { ci = true })
  repo("eta.nvim", { testing = true })
  repo("iota.nvim", { ci = true })
  repo("gamma.nvim", { workflows = true })
  repo("lib.nvim", {})
  repo("tasks-vault", { ci = true })
  repo("tricentis-vault", { workflows = true })
  repo("plain", {})

  local function sdir(dir)
    return require("testing.state").dir(dir, { state_dir = state })
  end
  -- alpha: the last run was red; beta: a complete green proof of another system and Neovim (verify reads the git facts
  -- and answers "rejected": the deepest path verify takes without running anything)
  write(
    sdir(alpha) .. "/ci.json",
    vim.json.encode({
      schema = "testing-ci/1",
      verdict = "red",
      first_red = "lint",
      tree = "0000",
      time = "2026-10-31T09:00:00Z",
    })
  )
  write(
    sdir(beta) .. "/ci-full.json",
    vim.json.encode({
      schema = "testing-ci/1",
      verdict = "green",
      partial = false,
      head_moved = false,
      tree_changed = false,
      dirty = false,
      tree = "1111",
      os = "plan9",
      nvim = "0.0.0",
      pipeline_sha = "x",
      steps = {},
      time = "2026-10-31T10:00:00Z",
    })
  )

  -- epsilon: the last complete run of the profile was red, a later partial run (ci.json) green; not a git repository
  write(
    sdir(epsilon) .. "/ci-full.json",
    vim.json.encode({
      schema = "testing-ci/1",
      verdict = "red",
      first_red = "luacheck",
      tree = "2222",
      time = "2026-10-31T08:00:00Z",
    })
  )
  write(
    sdir(epsilon) .. "/ci.json",
    vim.json.encode({
      schema = "testing-ci/1",
      verdict = "green",
      partial = true,
      tree = "2222",
      time = "2026-10-31T11:00:00Z",
    })
  )
  -- delta: a usable green proof of this system, this Neovim and this pipeline: verify goes as deep as it can without a
  -- run (the tool versions, the suite's stamp through `testing verify`)
  do
    local pipeline = assert(require("testing.ci.schema").load(delta))
    local tree = vim
      .system({ "git", "rev-parse", "HEAD^{tree}" }, { cwd = delta, text = true })
      :wait(30000).stdout
      :gsub("%s+$", "")
    write(
      sdir(delta) .. "/ci-full.json",
      vim.json.encode({
        schema = "testing-ci/1",
        verdict = "green",
        partial = false,
        head_moved = false,
        tree_changed = false,
        dirty = false,
        tree = tree,
        os = require("testing.ci").internal.this_os(),
        nvim = tostring(vim.version()),
        pipeline_sha = vim.fn.sha256(
          require("lib.nvim.json.canonical").encode(pipeline.digest_input)
        ),
        steps = {},
        time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      })
    )
  end

  local SECRET = HOME .. "/secret/project/file.lua"
  local SECRET_WIN = SECRET:gsub("/", "\\")
  local USER = vim.env.USERNAME or vim.env.USER or "nobody-at-all"
  vim.env.TESTING_OVERVIEW_SECRET = "s3cr3t-value"
  local remote_calls = 0
  ---The CI adapter's records, by directory name.
  local function fake_remote(repos)
    remote_calls = remote_calls + 1
    local out = {}
    for _, r in ipairs(repos) do
      local name = vim.fs.basename(r.dir)
      local rec = { repo = name, dir = r.dir, overall = "success" }
      if name == "alpha.nvim" then
        rec.overall = "failure"
        rec.run = { id = 7, url = "https://github.com/WKDSteve/alpha.nvim/actions/runs/7" }
        rec.os = {
          ubuntu = { state = "failure", url = "https://github.com/WKDSteve/alpha.nvim/job/1" },
          windows = { state = "success", url = "http://github.com/WKDSteve/alpha.nvim/job/2" },
        }
        rec.note = "<script>alert(1)</script> failed in "
          .. SECRET
          .. " and "
          .. SECRET_WIN
          .. " and E:/repos/other/x.lua"
          .. " see https://github.com/o/r and error:/x/y `/opt/q/y` [/srv/a/b] /single C:/My Dir/a"
      elseif name == "gamma.nvim" then
        -- no path in it: what only the IR's redaction removes (user, e-mail, an environment value)
        rec.note = "owner "
          .. USER
          .. ", mail t@example.invalid, TESTING_OVERVIEW_SECRET=s3cr3t-value"
        rec.run = { id = 9, url = "javascript:alert(1)" }
        rec.os = {
          ubuntu = { state = "success" },
          windows = { state = "success" },
          macos = { state = "success" },
        }
      else
        rec.overall = "no_github"
        rec.note = "origin is not on GitHub"
      end
      out[#out + 1] = rec
    end
    return out
  end

  local spawned = {}
  local function run(args, o)
    o = o or {}
    local out, err = {}, {}
    local real = overview.deps
    overview.deps = {
      now = function()
        return NOW
      end,
      verify = o.verify or real.verify,
      remote = o.remote or fake_remote,
    }
    -- nothing may start a pipeline or a suite: every entry point of a run fails loudly, and every process is recorded
    local ci, repos = require("testing.ci"), require("testing.ci.repos")
    local job = require("lib.nvim.system.job")
    local inproc = require("testing.run.inproc")
    local saved = {
      ci_main = ci.main,
      run_process = ci.internal.run_process,
      repos_main = repos.main,
      repos_system = repos.system,
      job_start = job.start,
      cli_main = cli.main,
      system = vim.system,
      spawn = vim.uv.spawn,
      jobstart = vim.fn.jobstart,
      fn_system = vim.fn.system,
      inproc_run = inproc.run,
      inproc_list = inproc.list,
    }
    local started = {}
    local function forbid(what)
      return function()
        started[#started + 1] = what
        error("a run was started: " .. what, 0)
      end
    end
    ci.internal.run_process = forbid("ci.internal.run_process")
    repos.main = forbid("ci.repos.main")
    repos.system = forbid("ci.repos.system")
    job.start = forbid("lib.nvim.system.job.start")
    inproc.run = forbid("testing.run.inproc.run")
    inproc.list = forbid("testing.run.inproc.list")
    -- every way to start a process is recorded: the executable and its arguments
    local function record(exe, rest)
      spawned[#spawned + 1] = { exe = tostring(exe), args = rest or {} }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv, ...)
      record(argv[1], vim.list_slice(argv, 2))
      return saved.system(argv, ...)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.spawn = function(path, opts, ...)
      record(path, opts and opts.args)
      return saved.spawn(path, opts, ...)
    end
    rawset(vim.fn, "jobstart", function(cmd, ...)
      record(
        type(cmd) == "table" and cmd[1] or cmd,
        type(cmd) == "table" and vim.list_slice(cmd, 2)
      )
      return saved.jobstart(cmd, ...)
    end)
    rawset(vim.fn, "system", function(cmd, ...)
      record(
        type(cmd) == "table" and cmd[1] or cmd,
        type(cmd) == "table" and vim.list_slice(cmd, 2)
      )
      return saved.fn_system(cmd, ...)
    end)
    local store = require("testing.cache.store")
    local rtp, key = vim.o.runtimepath, store.project_key
    local outer = saved.cli_main
    local depth, deep = 0, 0
    ---@diagnostic disable-next-line: duplicate-set-field
    cli.main = function(argv, sv)
      depth = depth + 1
      if depth > 1 and argv[1] == "verify" then
        deep = deep + 1
      end
      -- the outer call is this spec's; inside it only `testing verify` (the suite's stamp) may be asked
      if depth > 1 and argv[1] ~= "verify" then
        started[#started + 1] = "testing " .. tostring(argv[1])
        depth = depth - 1
        error("a run was started: testing " .. tostring(argv[1]), 0)
      end
      local res = { pcall(outer, argv, sv) }
      depth = depth - 1
      if not res[1] then
        error(res[2], 0)
      end
      return res[2]
    end
    ci.main = function(argv, sv)
      if argv[1] ~= "overview" then
        started[#started + 1] = "testing ci " .. tostring(argv[1])
        error("a run was started: testing ci", 0)
      end
      return saved.ci_main(argv, sv)
    end
    local pass, code = pcall(cli.main, vim.list_extend({ "ci", "overview" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
      stamp = {
        getenv = function()
          return nil
        end,
      },
    })
    ci.main, ci.internal.run_process = saved.ci_main, saved.run_process
    repos.main, repos.system, job.start = saved.repos_main, saved.repos_system, saved.job_start
    cli.main, vim.system, vim.uv.spawn = saved.cli_main, saved.system, saved.spawn
    rawset(vim.fn, "jobstart", saved.jobstart)
    rawset(vim.fn, "system", saved.fn_system)
    inproc.run, inproc.list = saved.inproc_run, saved.inproc_list
    overview.deps = real
    local leaked = { vim.o.runtimepath ~= rtp, store.project_key ~= key }
    vim.o.runtimepath, store.project_key = rtp, key
    if not pass then
      error(code, 0)
    end
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      started = started,
      deep = deep,
      leaked = leaked,
    }
  end

  local page = tmp .. "/out/fleet.html"

  -- ------------------------------------------------------------------ the page

  spawned = {}
  local r1 = run({ "--repos-root=" .. root, "--out=" .. page })
  eq(r1.code, overview.EXIT_OK, "page: exit 0 although a repository is red (" .. r1.err .. ")")
  eq(r1.started, {}, "no run: no pipeline, no suite, no multi-repository run was started")
  local others = {}
  for _, p in ipairs(spawned) do
    local is_git = vim.fs.basename(p.exe):lower():gsub("%.exe$", "") == "git"
    if not is_git and not vim.tbl_contains(p.args, "--version") then
      others[#others + 1] = p.exe .. " " .. table.concat(p.args, " ")
    end
  end
  eq(
    others,
    {},
    "no run: the only processes are git (the facts ci verify reads) and a tool's --version"
  )
  ok(#spawned > 0, "no run: ... and verify did read the git facts of a proof (" .. #spawned .. ")")
  ok(r1.deep > 0, "no run: ... verify went as deep as the suite's stamp (testing verify) for delta")
  eq(
    r1.leaked,
    { false, false },
    "isolation: no verify leaves 'runtimepath' or the cache key changed"
  )
  has(r1.out, "wrote " .. page, "page: the path is printed")
  has(r1.out, "left out: tasks-vault, tricentis-vault", "list: the vaults are left out and named")
  local html = read(page)
  ok(html ~= nil, "page: written")

  local doc_run = run({ "--repos-root=" .. root, "--json" })
  local doc = vim.json.decode(doc_run.out)
  eq(doc.schema, "testing-ci-overview/1", "json: the schema")
  eq(
    vim.tbl_map(function(r)
      return r.repo
    end, doc.repos),
    {
      "alpha.nvim",
      "beta.nvim",
      "delta.nvim",
      "epsilon.nvim",
      "eta.nvim",
      "gamma.nvim",
      "iota.nvim",
      "lib.nvim",
    },
    "list: sorted; a ci section, a .testing.lua without one (eta), workflows, lib.nvim; no vault, no plain directory"
  )
  eq(doc.excluded, { "tasks-vault", "tricentis-vault" }, "json: the names left out")
  local by = {}
  for _, r in ipairs(doc.repos) do
    by[r.repo] = r
  end
  eq(by["lib.nvim"]["local"].state, "none", "lib.nvim: no testing.nvim locally")
  eq(by["alpha.nvim"]["local"].state, "red", "alpha: the last run (ci.json) was red")
  eq(by["alpha.nvim"]["local"].age_s, 3 * 3600, "alpha: its age")
  has(by["alpha.nvim"]["local"].note, "lint", "alpha: the first red step")
  has(
    by["alpha.nvim"]["local"].note,
    "(an older tree)",
    "alpha: verify read no tree (no stamp), the page reads it: ci.json is of an older tree"
  )
  eq(
    { by["epsilon.nvim"]["local"].state, by["epsilon.nvim"]["local"].age_s },
    { "red", 4 * 3600 },
    "epsilon: the last complete run (ci-full.json) red, a later partial run green: red, with its age"
  )
  has(
    by["epsilon.nvim"]["local"].note,
    "red: luacheck (profile full) (tree unknown)",
    "epsilon: its first red step, the profile, no git tree to compare"
  )
  eq(by["delta.nvim"]["local"].verify, "no-stamp", "delta: the suite has no stamp")
  eq(by["eta.nvim"]["local"].state, "unknown", "eta: a .testing.lua without a ci section")
  has(
    by["iota.nvim"]["local"].note or "",
    "<STATE>",
    "iota: the state directory of the page (--state-dir) is <STATE> in a reason"
  )
  eq(by["beta.nvim"]["local"].state, "unknown", "beta: a proof of another system is no proof")
  eq(by["beta.nvim"]["local"].verify, "rejected", "beta: ... ci verify says rejected")
  eq(by["gamma.nvim"]["local"].state, "none", "gamma: workflows only")
  eq(by["gamma.nvim"].ci.overall, "success", "gamma: CI from the adapter")
  eq(by["gamma.nvim"].ci.run_url, nil, "gamma: a run URL that is not https://github.com is dropped")
  eq(by["alpha.nvim"].ci.os.windows.url, nil, "alpha: an http:// job URL is dropped")
  eq(by["alpha.nvim"].ci.os.macos.state, "none", "alpha: a system without a job is not configured")
  eq(
    { doc.counts["local"].red, doc.counts["local"].none, doc.counts.ci.red, doc.counts.ci.green },
    { 2, 2, 1, 1 },
    "json: the counts"
  )
  ok(read(state .. "/testing/overview.html") == nil, "json: no page unless --out is given")

  -- escaping, redaction, no absolute path, links
  lacks(html, "<script", "escaping: no script element (a note with <script> is text)")
  has(html, "&lt;script&gt;alert(1)&lt;/script&gt;", "escaping: ... shown escaped")
  lacks(html, HOME, "redaction: the home directory is not in the page")
  lacks(html, SECRET_WIN, "redaction: ... nor in its Windows spelling")
  lacks(html, (HOME:gsub("/", "\\")), "redaction: ... nor its prefix with backslashes")
  lacks(html, root, "redaction: no repository path, only names")
  lacks(html, tmp, "redaction: no temporary path")
  lacks(html, "E:/repos", "redaction: a drive path that is no known root goes too")
  has(html, "&lt;PATH&gt;", "redaction: ... as <PATH> (escaped)")
  lacks(html, "http://", "links: no http:// link")
  lacks(html, "javascript:", "links: no javascript: link")
  has(
    html,
    'href="https://github.com/WKDSteve/alpha.nvim/actions/runs/7"',
    "links: the run of alpha"
  )
  lacks(doc_run.out, root, "json: no repository path either")
  -- what only the IR's redaction takes out (gamma's note has no path in it)
  for _, text in ipairs({ html, doc_run.out }) do
    lacks(text, "owner " .. USER, "redaction: the user's name")
    lacks(text, "t@example.invalid", "redaction: an e-mail address")
    lacks(text, "s3cr3t-value", "redaction: the value of an environment variable")
  end
  -- the shapes of a path, and what is no path
  local an = by["alpha.nvim"].ci.note
  has(an, "https://github.com/o/r", "paths: a URL stays readable")
  has(an, "error:<PATH>", "paths: a path after a colon goes, the word stays")
  for _, gone in ipairs({ "/opt/q", "/srv/a", "/single", "Dir/a" }) do
    lacks(an, gone, "paths: in backticks, brackets, of one part, with a space")
  end

  -- self-contained, both schemes, the filter
  has(html, "default-src 'none'", "self-contained: a policy that forbids every request")
  lacks(html, "<link", "self-contained: no external stylesheet")
  lacks(html, "src=", "self-contained: nothing loaded")
  has(html, "prefers-color-scheme:dark", "page: a dark scheme")
  has(html, 'id="red-only"', "filter: the checkbox")
  has(html, "#red-only:checked~.wrap tbody tr:not(.red){display:none}", "filter: the rule")
  has(html, '<tr class="red"><td>alpha.nvim</td>', "filter: alpha's row is red")
  has(html, '<tr class="rest"><td>gamma.nvim</td>', "filter: gamma's row is not")
  has(html, '<tr class="red"><td>epsilon.nvim</td>', "filter: epsilon's row is red")
  has(html, 'datetime="2026-10-31T12:00:00Z"', "page: generated_at")

  -- determinism
  run({ "--repos-root=" .. root, "--out=" .. page })
  eq(read(page), html, "determinism: the same inputs give the same bytes")

  -- a verified proof (the answer of ci verify replaced): proven with the age of its document
  write(sdir(alpha) .. "/ci-full.json", vim.json.encode({ time = "2026-10-30T12:00:00Z" }))
  local pr = run({ alpha, "--json", "--no-remote" }, {
    verify = function()
      return { status = "verified", profile = "full", reasons = {} }
    end,
  })
  local pa = vim.json.decode(pr.out).repos[1]
  eq({ pa["local"].state, pa["local"].age_s }, { "proven", 86400 }, "proven: with its age")

  -- --no-remote
  remote_calls = 0
  local nr = run({ "--repos-root=" .. root, "--json", "--no-remote" })
  eq(remote_calls, 0, "--no-remote: the adapter is not asked")
  local nrd = vim.json.decode(nr.out)
  eq(nrd.repos[1].ci.overall, "unknown", "--no-remote: CI unknown")
  eq(nrd.repos[1].ci.os.ubuntu.state, "unknown", "--no-remote: ... per system")

  -- excludes and includes from the command line
  local ex =
    run({ "--repos-root=" .. root, "--json", "--exclude=gamma.nvim", "--include=tasks-vault" })
  local exd = vim.json.decode(ex.out)
  eq(
    vim.tbl_map(function(r)
      return r.repo
    end, exd.repos),
    {
      "alpha.nvim",
      "beta.nvim",
      "delta.nvim",
      "epsilon.nvim",
      "eta.nvim",
      "iota.nvim",
      "lib.nvim",
      "tasks-vault",
    },
    "--exclude leaves a name out, --include takes even a vault in"
  )
  eq(exd.excluded, { "gamma.nvim", "tricentis-vault" }, "--exclude: named as left out")
  local miss = run({ "--repos-root=" .. root, "--json", "--include=nowhere" })
  has(miss.err, "nowhere", "--include: a name below no root is reported")

  -- ci_overview in .testing.lua of the current directory
  do
    local cfgdir = tmp .. "/cfg"
    write(
      cfgdir .. "/.testing.lua",
      "return { ci_overview = { include = { 'x.nvim' }, exclude = { 'y.nvim' } } }\n"
    )
    local cfg = overview.config(cfgdir)
    eq({ cfg.include, cfg.exclude }, { { "x.nvim" }, { "y.nvim" } }, "config: ci_overview")
    eq(overview.config(tmp).include, { "lib.nvim" }, "config: the default includes lib.nvim")
  end

  -- the IR's redaction of a free text, reused: the roots become placeholders, the user's name goes
  do
    local inproc = require("testing.run.inproc")
    local text = inproc.redact_text("at " .. root .. "/a.lua and " .. HOME .. "/b.lua", root)
    eq(text, "at <REPO>/a.lua and <HOME>/b.lua", "redact_text: the roots of the IR")
    local user = vim.env.USERNAME or vim.env.USER
    if type(user) == "string" and #user >= 3 then
      lacks(inproc.redact_text("owner " .. user, root), user, "redact_text: the user's name")
    end
  end

  -- a note is cut at a character boundary: the page stays valid UTF-8
  eq(
    overview.clean(("a"):rep(296) .. "ääää", tmp),
    ("a"):rep(296) .. "...",
    "clean: a UTF-8 sequence is not cut"
  )

  -- the isolation of one verify: what it puts on 'runtimepath' and the cache key are restored
  do
    local vmod, store = require("testing.ci.verify"), require("testing.cache.store")
    local saved, rtp, key = vmod.main, vim.o.runtimepath, store.project_key
    vmod.main = function(_, sv)
      vim.opt.rtp:append(tmp .. "/elsewhere")
      store.project_key = "elsewhere@1"
      sv.out('{"status":"no-stamp"}')
      return 1
    end
    local okv, d = pcall(overview.deps.verify, alpha, state, {
      out = function() end,
      err = function() end,
    })
    vmod.main = saved
    local after = { vim.o.runtimepath == rtp, store.project_key == key }
    vim.o.runtimepath, store.project_key = rtp, key
    ok(okv, "isolation: verify answered (" .. tostring(d) .. ")")
    eq(after, { true, true }, "isolation: 'runtimepath' and the cache key are as before")
    eq(d.status, "no-stamp", "isolation: ... and the answer is kept")
  end

  -- one repository that cannot be read is unknown, the page is still written
  do
    local broken = tmp .. "/broken"
    local b1, b2, b3 = broken .. "/b1", broken .. "/b2", broken .. "/b3"
    for _, d in ipairs({ b1, b2, b3 }) do
      write(d .. "/.testing.lua", CI_LUA)
    end
    write(sdir(b1) .. "/ci.json", "not json {")
    vim.fn.mkdir(sdir(b2) .. "/ci.json", "p")
    write(sdir(b3) .. "/ci-full.json", "{")
    local br = run({ b1, b2, b3, "--json", "--no-remote" })
    eq(br.code, overview.EXIT_OK, "broken state: exit 0 (" .. br.err .. ")")
    local states = vim.tbl_map(function(r)
      return r["local"].state
    end, vim.json.decode(br.out).repos)
    eq(
      states,
      { "unknown", "unknown", "unknown" },
      "broken state: not JSON, a directory, a broken proof"
    )

    local th = run({ b1, "--json", "--no-remote" }, {
      verify = function()
        error("verify boom", 0)
      end,
    })
    eq(th.code, overview.EXIT_OK, "a throwing source: exit 0 (" .. th.err .. ")")
    local tl = vim.json.decode(th.out).repos[1]["local"]
    eq(tl.state, "unknown", "a throwing source: that repository is unknown")
    has(tl.note, "verify boom", "a throwing source: ... with the reason")

    local ad = run({ b1, "--json" }, {
      remote = function()
        error("adapter boom", 0)
      end,
    })
    local ac = vim.json.decode(ad.out).repos[1].ci
    eq(ac.overall, "unknown", "adapter: a failure is unknown, never green")
    has(ac.note, "the CI adapter failed: adapter boom", "adapter: ... named")

    local NG = "lib.nvim.net.github"
    local loaded, preload = package.loaded[NG], package.preload[NG]
    package.loaded[NG] = nil
    package.preload[NG] = function()
      error("no such module", 0)
    end
    local okn, ng = pcall(run, { b1, "--json" })
    package.loaded[NG], package.preload[NG] = loaded, preload
    ok(okn, "an old lib.nvim: the page is written (" .. tostring(ng) .. ")")
    local nc = vim.json.decode(ng.out).repos[1].ci
    eq(
      { nc.overall, nc.note },
      { "unknown", "lib.nvim has no net.github" },
      "an old lib.nvim: unknown"
    )
  end

  -- exit codes
  local u = run({ "--frobnicate" })
  eq(u.code, overview.EXIT_USAGE, "usage: an unknown flag is exit 2")
  has(u.err, "--frobnicate", "usage: ... named")
  eq(run({ "--help" }).code, 0, "usage: --help")
  eq(run({ tmp .. "/absent" }).code, overview.EXIT_USAGE, "usage: a root that is not a directory")
  eq(
    run({ "--repos-root=" .. tmp .. "/absent" }).code,
    overview.EXIT_USAGE,
    "usage: a --repos-root that is not a directory"
  )
  vim.fn.mkdir(tmp .. "/adir", "p")
  local w = run({ alpha, "--no-remote", "--out=" .. tmp .. "/adir" })
  eq(w.code, overview.EXIT_INFRA, "exit 3: the page cannot be written")
  for _, bad in ipairs({ "--include=..", "--include=../x", "--exclude=a/b" }) do
    local b = run({ "--repos-root=" .. root, "--json", bad })
    eq(b.code, overview.EXIT_USAGE, "usage: " .. bad .. " is no directory name below the root")
    has(b.err, "not a directory name", "usage: ... said")
  end

  vim.env.TESTING_OVERVIEW_SECRET = nil

  vim.fn.delete(tmp, "rf")
end
