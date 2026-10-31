-- TESTS/testing/export_shallow_spec.lua -- the limits of the repository key (`<basename>-<12 hex>` of the basename
-- and the root commit, kept as it is): a shallow clone has another key than a full clone, which `testing export`
-- and `testing call --export` say on stderr (never in a document); two clones of the same repository in one export
-- have the same key, and the error says that this is the cause.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local export = require("testing.export")
  local cli = require("testing.cli")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local base = fixture.base("shallow")
  local fx = fixture.build(base)

  local function git(cwd, ...)
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
      }, { cwd = cwd, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end

  -- ── the real seam: a shallow clone is told apart, and its key differs ──
  do
    local origin = base .. "/origin/deep.nvim"
    fixture.write(origin .. "/a.txt", "a\n")
    git(origin, "init", "-q")
    git(origin, "add", "-A")
    git(origin, "commit", "-q", "-m", "one")
    fixture.write(origin .. "/a.txt", "b\n")
    git(origin, "commit", "-q", "-am", "two")
    local full = base .. "/full/deep.nvim"
    local shallow = base .. "/shallow/deep.nvim"
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    vim.fn.mkdir(vim.fs.dirname(shallow), "p")
    git(base, "clone", "-q", origin, full)
    -- --depth needs a transport that honours it: file:// (a plain path makes a local, full clone)
    local url = "file://" .. (origin:sub(1, 1) == "/" and "" or "/") .. origin
    git(base, "clone", "-q", "--depth", "1", url, shallow)
    eq(export.deps.shallow(full), false, "a full clone is not shallow")
    eq(export.deps.shallow(shallow), true, "a --depth 1 clone is shallow")
    eq(export.deps.shallow(fx.gamma), false, "outside git: not shallow")
    eq(export.deps.key(full), export.deps.key(origin), "a full clone: the key of the repository")
    ok(
      export.deps.key(shallow) ~= export.deps.key(full),
      "a shallow clone: another key (the limit the warning is about)"
    )
  end

  -- ── `testing call --export` and `testing export`: the warning on stderr, nothing in a document ──
  local function run(args)
    local out, err = {}, {}
    local restore = fixture.install()
    local saved_shallow = export.deps.shallow
    export.deps.shallow = function(dir)
      return vim.fs.basename(dir) == "alpha.nvim"
    end
    local saved_env = vim.env.TASKS_DESKTOP_CONFIG_DIR
    vim.env.TASKS_DESKTOP_CONFIG_DIR = vim.fs.dirname(fx.areas)
    local pass, code = pcall(cli.main, args, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = fx.state,
    })
    vim.env.TASKS_DESKTOP_CONFIG_DIR = saved_env
    export.deps.shallow = saved_shallow
    restore()
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  do
    local f = run({ "call", "fleet", "--repos-root=" .. fx.root, "--export" })
    eq(f.code, 0, "call fleet --export: exit 0: " .. f.err)
    has(f.err, "testing call: warning: alpha.nvim is a shallow clone", "call fleet --export warns")
    has(f.err, "git fetch --unshallow", "and says what to do")
    eq(f.out:find("shallow", 1, true), nil, "the warning is in no document")
    eq(select(2, f.err:gsub("is a shallow clone", "")), 1, "only the shallow one")

    local r = run({ "call", "repo", fx.alpha, "--export" })
    eq(r.code, 0, "call repo --export: exit 0: " .. r.err)
    has(r.err, "alpha.nvim is a shallow clone", "call repo --export warns")
    eq(r.out:find("shallow", 1, true), nil, "repo: the warning is in no document")

    local l = run({ "call", "fleet", "--repos-root=" .. fx.root })
    eq(l.code, 0, "the local form: exit 0")
    eq(l.err:find("shallow", 1, true), nil, "the local form (stays on this machine) does not warn")

    local out = base .. "/out"
    local e = run({ "export", "--out", out, "--repos-root=" .. fx.root })
    eq(e.code, 0, "export --out: exit 0: " .. e.err)
    has(e.err, "testing export: warning: alpha.nvim is a shallow clone", "testing export warns")
    for _, name in ipairs(vim.fn.readdir(out .. "/repos")) do
      local text = fixture.read(out .. "/repos/" .. name)
      eq(text:find("shallow", 1, true), nil, name .. ": the warning is in no file")
    end
    eq(fixture.read(out .. "/fleet.json"):find("shallow", 1, true), nil, "fleet.json: neither")
  end

  -- ── two clones of the same repository: the error names the cause ──
  do
    local a = base .. "/one/dup.nvim"
    local b = base .. "/two/dup.nvim"
    fixture.write(a .. "/.testing.lua", "return {}\n")
    fixture.write(b .. "/.testing.lua", "return {}\n")
    local restore = fixture.install()
    local doc, err = export.fleet({ roots = { a, b }, form = "local", state_dir = fx.state })
    restore()
    eq(doc, nil, "no document")
    has(tostring(err), "two clones of the same repository", "the cause")
    has(tostring(err), "root commit", "what the key is made of")
    has(tostring(err), "export only one of them", "what to do")
  end

  vim.fn.delete(base, "rf")
end
