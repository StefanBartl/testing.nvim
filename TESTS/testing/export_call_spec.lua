-- TESTS/testing/export_call_spec.lua -- `testing call fleet|repo`: the dispatcher of `testing-export/1` on the
-- command line (argv, one line of JSON on stdout, the exit codes 0/2/3), the CI adapter through its own fakes (no
-- network), what happens when the adapter fails, and the real key and head of a repository (no fakes).

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local export = require("testing.export")
  local cli = require("testing.cli")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local base = fixture.base("call")
  local fx = fixture.build(base)

  local function call(args, install, config)
    local out, err = {}, {}
    local restore = fixture.install(install)
    if install and install.after then
      install.after()
    end
    -- the data classes of the fixture's "device" (never the real areas.json of this machine)
    local saved_env = vim.env.TASKS_DESKTOP_CONFIG_DIR
    vim.env.TASKS_DESKTOP_CONFIG_DIR = config or vim.fs.dirname(fx.areas)
    local pass, code = pcall(cli.main, vim.list_extend({ "call" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = fx.state,
    })
    vim.env.TASKS_DESKTOP_CONFIG_DIR = saved_env
    restore()
    if not pass then
      error(code, 0)
    end
    local doc
    if #out == 1 then
      local okd, d = pcall(vim.json.decode, out[1])
      doc = okd and d or nil
    end
    return { code = code, out = out, err = table.concat(err, "\n"), doc = doc }
  end

  -- ── fleet, local form (the default) ──
  do
    local r = call({ "fleet", "--repos-root=" .. fx.root })
    eq(r.code, 0, "exit 0: " .. r.err)
    eq(#r.out, 1, "one line on stdout")
    eq(r.doc.kind, "fleet", "kind")
    eq(r.doc.form, "local", "the local form by default")
    eq(r.doc.root, fx.root, "with the repos root")
    local names = {}
    for _, row in ipairs(r.doc.repos) do
      names[#names + 1] = row.name
      eq(row.root, fx.root .. "/" .. row.name, row.name .. ": its root")
      eq(row.ci_remote, vim.NIL, row.name .. ": the CI adapter is not asked without --remote")
    end
    eq(names, { "alpha.nvim", "beta.nvim", "gamma.nvim" }, "the index: sorted, the vault left out")
    eq(r.doc.excluded, 1, "the vault is counted, not named")
    eq(r.doc.remote, { asked = false, error = vim.NIL }, "not asked")
    local valid, problems = export.validate(r.out[1])
    ok(valid, "valid: " .. table.concat(problems, "; "))
    eq(r.out[1]:find("\n"), nil, "compact: one line")
  end

  -- ── fleet, export form, with the CI adapter: the same document as the Lua API gives ──
  do
    local r = call({ "fleet", "--repos-root", fx.root, "--export", "--remote" })
    eq(r.code, 0, "exit 0: " .. r.err)
    eq(r.doc.form, "export", "the export form")
    eq(r.out[1]:find('"root"', 1, true), nil, "no root")
    local restore = fixture.install()
    local doc = export.fleet(fixture.opts(fx))
    restore()
    eq(r.out[1], export.encode(doc), "the bytes of testing.export.fleet")
    eq(r.doc.repos[1].ci_remote.state, "success", "alpha: the adapter's record")
    eq(r.doc.repos[2].ci_remote.os.windows.state, "failure", "beta: red on windows")
    eq(r.doc.repos[2].ci_remote.os.macos, vim.NIL, "beta: no job for macos is null")
    eq(r.doc.repos[3].ci_remote.state, "no_github", "gamma: no origin")
    eq(r.doc.remote, { asked = true, error = vim.NIL }, "asked, no error")
  end

  -- ── repo ──
  do
    local r = call({ "repo", fx.beta, "--export", "--remote" })
    eq(r.code, 0, "exit 0: " .. r.err)
    eq(r.doc.kind, "repo", "kind")
    eq(r.doc.cases_red, 2, "the red cases")
    eq(r.doc.cases[1].status, "fail", "by file and line: the fail first")
    eq(r.doc.cases[2].status, "timeout", "then the timeout")
    eq(r.doc.repo.counts, { fail = 2, flaky = 1 }, "counts")
    eq(r.doc.repo["local"].stale, 1, "the file that is gone is stale")
    local valid, problems = export.validate(r.out[1])
    ok(valid, "valid: " .. table.concat(problems, "; "))
    local l = call({ "repo", fx.gamma })
    eq(l.code, 0, "a repository without any result: exit 0")
    eq(l.doc.repo["local"], vim.NIL, "local is null (unknown), not zero")
    eq(l.doc.repo.counts, vim.NIL, "counts too")
    eq(l.doc.cases, {}, "no red case")
    eq(l.doc.root, fx.gamma, "the local form names the root")
  end

  -- ── the CI adapter fails: the document is still there, the failure said, the token never ──
  do
    local r = call(
      { "fleet", "--repos-root=" .. fx.root, "--export", "--remote" },
      { remote_fail = "proxy said: Authorization: Bearer fixture-token refused at " .. fx.root }
    )
    eq(r.code, 0, "exit 0: the adapter is a source, not the verdict")
    eq(
      r.doc.repos[1].ci_remote.state,
      "unknown",
      "a repository that could not be fetched is unknown"
    )
    eq(r.out[1]:find("fixture-token", 1, true), nil, "the token is in no document")
    local saved = export.deps.remote
    export.deps.remote = function()
      error("boom in " .. fx.root .. "/alpha.nvim")
    end
    local r2 = call({ "fleet", "--repos-root=" .. fx.root, "--export", "--remote" })
    export.deps.remote = saved
    eq(r2.code, 0, "an adapter that raises: still exit 0")
    eq(r2.doc.remote.asked, true, "asked")
    has(r2.doc.remote.error, "the CI adapter failed: ", "the failure is said")
    eq(r2.doc.remote.error:find(fx.root, 1, true), nil, "redacted")
    eq(
      r2.doc.repos[1].ci_remote.state,
      "unknown",
      "asked, no record: unknown, not null (null is not asked)"
    )
    eq(r2.doc.repos[1].ci_remote.note, export.NO_RECORD, "and the note says so")
    eq(r2.doc.repos[1].ci_remote.run, vim.NIL, "no run")
    local valid, problems = export.validate(r2.out[1])
    ok(valid, "asked, no record: valid: " .. table.concat(problems, "; "))
    -- a bare token of the environment (not a NAME=value pair) in an error of the adapter: never in a document
    local secret = "ghp_" .. string.rep("Zq9", 12)
    local saved_env = vim.env[require("testing.ci.remote").TOKEN_ENV]
    vim.env[require("testing.ci.remote").TOKEN_ENV] = secret
    export.deps.remote = function()
      error("token " .. secret .. " refused")
    end
    local r3 = call({ "fleet", "--repos-root=" .. fx.root, "--export", "--remote" })
    export.deps.remote = saved
    vim.env[require("testing.ci.remote").TOKEN_ENV] = saved_env
    eq(r3.code, 0, "an adapter that names the token: exit 0")
    eq(r3.out[1]:find(secret, 1, true), nil, "the bare token is in no document")
    has(r3.doc.remote.error, "token <ENV> refused", "it is <ENV>")
  end

  -- ── usage: exit 2 ──
  do
    local cases = {
      { { "nope" }, "unknown method" },
      { { "fleet", "--bogus" }, "unknown argument" },
      { { "fleet", base .. "/does-not-exist" }, "is not a directory" },
      { { "fleet", "--repos-root=" .. base .. "/does-not-exist" }, "is not a directory" },
      { { "fleet", "--include=../x" }, "is not a directory name" },
      { { "fleet", "--state-dir" }, "needs a value" },
      { { "repo", fx.alpha, fx.beta }, "one directory" },
      { { "repo", "--repos-root=" .. fx.root }, "an option of fleet" },
    }
    for _, c in ipairs(cases) do
      local r = call(c[1])
      eq(r.code, 2, table.concat(c[1], " ") .. ": exit 2")
      has(r.err, c[2], table.concat(c[1], " ") .. ": the reason")
      eq(#r.out, 0, table.concat(c[1], " ") .. ": nothing on stdout")
    end
    local h = call({})
    eq(h.code, 0, "no method: the usage, exit 0")
    has(h.out[1], "testing call fleet", "the usage")
    eq(call({ "fleet", "--help" }).code, 0, "--help")
  end

  -- ── a document that would leak: exit 3, nothing on stdout ──
  do
    local saved = export.clean
    export.clean = function(s)
      return type(s) == "string" and s or nil
    end
    local r = call({ "repo", fx.beta, "--export" })
    export.clean = saved
    eq(r.code, 3, "exit 3")
    has(r.err, "would leak", "the reason")
    eq(#r.out, 0, "nothing on stdout")
    -- the fleet document is checked too: a branch named after a path of this machine (no repo document involved)
    local saved_head = export.deps.head
    export.clean = function(s)
      return type(s) == "string" and s or nil
    end
    local rf = call({ "fleet", "--repos-root=" .. fx.root, "--export" }, {
      after = function()
        export.deps.head = function(dir)
          return { sha = string.rep("3", 40), branch = dir .. "/branch", dirty = false }
        end
      end,
    })
    export.clean = saved
    export.deps.head = saved_head
    eq(rf.code, 3, "a fleet that would leak: exit 3")
    has(rf.err, "the fleet document would leak", "the fleet document is refused")
    has(rf.err, "$.repos[0].head.branch", "and where")
    eq(#rf.out, 0, "nothing on stdout")
  end

  -- ── the real key and head (no fakes) ──
  do
    local dir = base .. "/real.nvim"
    fixture.write(dir .. "/a.txt", "a\n")
    local function git(...)
      local res = vim
        .system({
          "git",
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "-c",
          "init.defaultBranch=main",
          ...,
        }, { cwd = dir, text = true })
        :wait(30000)
      ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    end
    git("init", "-q")
    git("add", "-A")
    git("commit", "-q", "-m", "init")
    local doc = export.repo(dir, { form = "local", state_dir = fx.state })
    ok(doc.repo.key:match("^real%.nvim%-%x%x%x%x%x%x%x%x%x%x%x%x$"), "<basename>-<12 hex>")
    -- the same repository below another folder (a second clone): the same key, nothing of the path in it
    local other = base .. "/elsewhere/real.nvim"
    vim.fn.mkdir(vim.fs.dirname(other), "p")
    local cl = vim.system({ "git", "clone", "-q", dir, other }, { text = true }):wait(30000)
    ok(cl.code == 0, "git clone: " .. tostring(cl.stderr))
    local cdoc = export.repo(other, { form = "local", state_dir = fx.state })
    eq(cdoc.repo.key, doc.repo.key, "a clone in another folder has the same key")
    ok(
      doc.repo.key ~= vim.fs.basename(require("testing.history").dir(dir, { state_dir = fx.state })),
      "the key is not the state directory's name (that one hashes the absolute path)"
    )
    eq(
      doc.repo.key,
      export.repo_key(dir, export.deps.identity(dir)),
      "the key is the basename and the root commit"
    )
    eq(#export.deps.identity(dir), 40, "the identity is the root commit")
    ok(doc.repo.head ~= vim.NIL and #doc.repo.head.sha == 40, "the head commit")
    eq(doc.repo.head.branch, "main", "the branch")
    eq(doc.repo.head.dirty, false, "a clean tree is dirty = false, not unknown")
    fixture.write(dir .. "/a.txt", "b\n")
    local doc2 = export.repo(dir, { form = "local", state_dir = fx.state })
    eq(doc2.repo.head.dirty, true, "a change makes it dirty")
    local plain = export.repo(fx.gamma, { form = "local", state_dir = fx.state })
    if vim.system({ "git", "-C", fx.gamma, "rev-parse", "HEAD" }):wait().code == 0 then
      print("n/a  the temporary directory is inside a git checkout: no head = null to see")
    else
      eq(plain.repo.head, vim.NIL, "not a checkout: head is null")
    end
  end

  -- ── the data classes: the export form releases what testing export --out releases, the local form all ──
  do
    local cfg = base .. "/classes-call"
    fixture.write(
      cfg .. "/areas.json",
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    local f = call({ "fleet", "--repos-root=" .. fx.root, "--export" }, nil, cfg)
    eq(f.code, 0, "fleet --export: exit 0: " .. f.err)
    local names = {}
    for _, row in ipairs(f.doc.repos) do
      names[#names + 1] = row.name
    end
    eq(names, { "alpha.nvim" }, "fleet --export: only the released repository")
    eq(
      f.doc.excluded_by,
      { selection = 1, private = 1, unclassified = 1 },
      "fleet --export: by reason"
    )
    eq(f.doc.classes.checked, true, "fleet --export: checked")
    eq(f.out[1]:find("beta.nvim", 1, true), nil, "fleet --export: beta is not named")
    eq(f.out[1]:find("gamma.nvim", 1, true), nil, "fleet --export: gamma is not named")

    local p = call({ "repo", fx.beta, "--export" }, nil, cfg)
    eq(p.code, 2, "repo --export of a private repository: exit 2")
    eq(#p.out, 0, "repo --export of a private repository: nothing on stdout")
    has(p.err, "(private)", "repo --export of a private repository: says why")
    local u = call({ "repo", fx.gamma, "--export" }, nil, cfg)
    eq(u.code, 2, "repo --export of an unclassified repository: exit 2")
    eq(#u.out, 0, "repo --export of an unclassified repository: nothing on stdout")
    has(u.err, "(unclassified)", "repo --export of an unclassified repository: says why")
    local a = call({ "repo", fx.alpha, "--export" }, nil, cfg)
    eq(a.code, 0, "repo --export of a public repository: exit 0: " .. a.err)
    -- the refusal names neither the repository nor a path of this machine
    for _, r in ipairs({ p, u }) do
      eq(r.err:find("beta", 1, true), nil, "the refusal does not name beta")
      eq(r.err:find("gamma", 1, true), nil, "the refusal does not name gamma")
      eq(r.err:find(fx.root, 1, true), nil, "the refusal names no path")
    end

    -- the CI adapter is never asked about a repository that is not released (no request about a private one)
    local asked = {}
    local saved_remote = export.deps.remote
    export.deps.remote = function(list)
      for _, item in ipairs(list) do
        asked[#asked + 1] = vim.fs.basename(item.dir)
      end
      return {}, {}
    end
    local fr = call({ "fleet", "--repos-root=" .. fx.root, "--export", "--remote" }, nil, cfg)
    local pr = call({ "repo", fx.beta, "--export", "--remote" }, nil, cfg)
    export.deps.remote = saved_remote
    eq(fr.code, 0, "fleet --export --remote: exit 0: " .. fr.err)
    eq(pr.code, 2, "repo --export --remote of a private repository: exit 2")
    eq(asked, { "alpha.nvim" }, "the adapter is asked about the released repository only")

    local none = base .. "/classes-none"
    vim.fn.mkdir(none, "p")
    local n = call({ "fleet", "--repos-root=" .. fx.root, "--export" }, nil, none)
    eq(n.code, 0, "no areas.json: fleet --export: exit 0")
    eq(n.doc.repos, {}, "no areas.json: fleet --export: no repository")
    eq(n.doc.excluded_by.unclassified, 3, "no areas.json: all unclassified")
    has(n.err, "note: no areas.json", "no areas.json: fleet --export says why on stderr")
    local nr = call({ "repo", fx.alpha, "--export" }, nil, none)
    eq(nr.code, 2, "no areas.json: repo --export: exit 2")
    has(nr.err, "no areas.json", "no areas.json: repo --export: says why")

    local l = call({ "repo", fx.beta }, nil, cfg)
    eq(l.code, 0, "the local form of a private repository: exit 0 (it stays on this machine)")
    eq(
      #call({ "fleet", "--repos-root=" .. fx.root }, nil, none).doc.repos,
      3,
      "the local form: all"
    )
  end

  vim.fn.delete(base, "rf")
end
