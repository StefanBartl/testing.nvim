-- TESTS/testing/export_folder_spec.lua -- `testing export --out <dir>` and `testing ci --repos ... --export=<dir>`: the
-- layout of the export folder (manifest, fleet.json, repos/<key>.json), the manifest's sums against the files, the
-- same bytes for an unchanged state, atomicity (a failure at every single step leaves the old manifest valid and true
-- to its files), the refusals that keep foreign files safe, the data classes fail-closed (an explicit areas.json of
-- the fixture, never the real one of this device), no absolute path for a fixture below $HOME (with a positive
-- control), and the workstation (no local results read, no run started).

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

return function(H)
  local ok, eq, has = H.ok, H.eq, H.has
  local export = require("testing.export")
  local folder = require("testing.export.folder")
  local cli = require("testing.cli")
  local fixture = dofile(
    vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))) .. "/export_fixture.lua"
  )

  local bases = {}
  local function build(tag, base)
    base = base or fixture.base(tag)
    bases[#bases + 1] = base
    return fixture.build(base), base
  end

  ---Every file below `dir`, relative, sorted.
  local function listing(dir)
    local out = {}
    for name, kind in vim.fs.dir(dir, { depth = 4 }) do
      if kind == "file" then
        out[#out + 1] = name
      end
    end
    table.sort(out)
    return out
  end

  ---The manifest of `dir` and whether every file it lists is there with its sum and size.
  local function check(dir)
    local text = fixture.read(dir .. "/" .. export.MANIFEST)
    local m = text and export.read(text)
    if not m or m.kind ~= "manifest" then
      return false, "no manifest"
    end
    for _, f in ipairs(m.files) do
      local t = fixture.read(dir .. "/" .. f.path)
      if not t then
        return false, f.path .. " is missing"
      end
      if vim.fn.sha256(t) ~= f.sha256 or #t ~= f.bytes then
        return false, f.path .. " does not match its sum"
      end
    end
    return true, m, text
  end

  local function no_tmp(dir)
    for name in vim.fs.dir(dir) do
      if name:match("^%.tmp%-") then
        return false
      end
    end
    return true
  end

  ---`testing export ...` through the CLI, with the fixture's fakes, its areas.json and a chosen machine role.
  ---@param fx table
  ---@param args string[]
  ---@param o? { role?: string, config?: string, install?: table, after?: fun() }
  local function cli_export(fx, args, o)
    o = o or {}
    local out, err = {}, {}
    local restore = fixture.install(o.install)
    if o.after then
      o.after()
    end
    local saved_env = vim.env.TASKS_DESKTOP_CONFIG_DIR
    vim.env.TASKS_DESKTOP_CONFIG_DIR = o.config or vim.fs.dirname(fx.areas)
    local saved_getenv = folder.deps.getenv
    folder.deps.getenv = function(name)
      if name == "NVIM_MACHINE_ROLE" then
        return o.role
      end
      return vim.env[name]
    end
    local pass, code = pcall(cli.main, vim.list_extend({ "export" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = fx.state,
    })
    folder.deps.getenv = saved_getenv
    vim.env.TASKS_DESKTOP_CONFIG_DIR = saved_env
    restore()
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  ---`folder.write` with the fixture's fakes (the Lua API, an explicit areas.json).
  local function write(fx, out, extra, install)
    local restore = fixture.install(install)
    local okw, res, err = pcall(folder.write, out, fixture.opts(fx, extra))
    restore()
    ok(okw, "folder.write raised: " .. tostring(res))
    return res, err
  end

  local fx = build("folder-a")

  -- ── the layout: manifest, fleet.json, repos/<key>.json; the sums are true; no temporary folder is left ──
  local out = fx.root .. "/../export-a"
  do
    local r = cli_export(fx, { "--out", out, "--repos-root=" .. fx.root, "--remote" })
    eq(r.code, 0, "exit 0: " .. r.err)
    has(r.out, "export: 3 repositories", "the summary line")
    has(r.out, "left out 1 (selection 1, private 0, unclassified 0)", "the vault, counted")
    local files = listing(out)
    eq(#files, 5, "manifest, fleet and three repositories: " .. table.concat(files, ", "))
    eq(files[1], "fleet.json", "fleet.json")
    ok(files[2]:match("^repos/alpha%.nvim%-%x+%.json$"), "repos/<key>.json of alpha")
    eq(files[5], export.MANIFEST, "the manifest")
    local good, m = check(out)
    ok(good, "every file matches the manifest: " .. tostring(good or m))
    eq(#m.files, 4, "the manifest lists the four documents, not itself")
    for _, f in ipairs(files) do
      local valid, problems = export.validate(fixture.read(out .. "/" .. f))
      ok(valid, f .. " is valid: " .. table.concat(problems or {}, "; "))
    end
    ok(no_tmp(out), "no .tmp-* left")
    local fleet = vim.json.decode(fixture.read(out .. "/fleet.json"))
    eq(fleet.form, "export", "the export form")
    eq(fleet.local_read, true, "the local results were read")
    eq(fleet.classes, { checked = true, problem = vim.NIL }, "the data classes were asked")
  end

  -- ── an unchanged state: the same bytes, the same digest, nothing moved (also at another time) ──
  do
    local before = {}
    for _, f in ipairs(listing(out)) do
      before[f] = fixture.read(out .. "/" .. f)
    end
    local r = cli_export(fx, { "--out=" .. out, "--repos-root", fx.root, "--remote" }, {
      install = { no_clock = true },
      after = function()
        export.clock = function()
          return "2031-01-01T00:00:00Z"
        end
      end,
    })
    eq(r.code, 0, "second export: exit 0: " .. r.err)
    has(r.out, "(0 written, 5 unchanged, 0 removed)", "nothing written the second time")
    local after = listing(out)
    local names = vim.tbl_keys(before)
    table.sort(names)
    eq(after, names, "the same files")
    for _, f in ipairs(after) do
      ok(fixture.read(out .. "/" .. f) == before[f], f .. ": the same bytes")
    end
    eq(
      vim.json.decode(fixture.read(out .. "/" .. export.MANIFEST)).digest,
      vim.json.decode(before[export.MANIFEST]).digest,
      "the same digest"
    )
  end

  -- ── atomic: a failure at any single step of the move leaves the old manifest valid and true to its files ──
  do
    local good, _, old_manifest = check(out)
    ok(good, "the folder before")
    -- a changed state: alpha and beta change (fleet, both repo files and the manifest are replaced)
    for _, dir in ipairs({ fx.alpha, fx.beta }) do
      local sdir = require("testing.history").dir(dir, { state_dir = fx.state })
      local ci = vim.json.decode(fixture.read(sdir .. "/ci.json"))
      ci.verdict = ci.verdict == "red" and "green" or "red"
      fixture.write(sdir .. "/ci.json", vim.json.encode(ci))
    end
    local real_write, real_rename = folder.deps.write, folder.deps.rename
    -- a failure while the temporary folder is written
    local writes = 0
    folder.deps.write = function(path, text)
      writes = writes + 1
      if writes == 2 then
        return nil, "injected write failure"
      end
      return real_write(path, text)
    end
    local res, err = write(fx, out)
    folder.deps.write = real_write
    eq(res, nil, "write failure: no result")
    eq(err and err.code, 3, "write failure: exit 3")
    has(err and err.message or "", "injected write failure", "write failure: named")
    eq(fixture.read(out .. "/" .. export.MANIFEST), old_manifest, "write failure: the old manifest")
    ok(check(out), "write failure: the old manifest is true to its files")
    ok(no_tmp(out), "write failure: the temporary folder is gone")
    -- a failure at the n-th move, for every n until the write gets through
    local points, committed = 0, false
    for n = 1, 40 do
      local renames = 0
      folder.deps.rename = function(from, to)
        renames = renames + 1
        if renames == n then
          return nil, "injected rename failure"
        end
        return real_rename(from, to)
      end
      res, err = write(fx, out)
      folder.deps.rename = real_rename
      if res then
        committed = true
        break
      end
      points = points + 1
      eq(err.code, 3, ("move %d: exit 3"):format(n))
      has(err.message, "the folder is as it was", ("move %d: put back"):format(n))
      eq(
        fixture.read(out .. "/" .. export.MANIFEST),
        old_manifest,
        ("move %d: the old manifest, byte for byte"):format(n)
      )
      local true_, why = check(out)
      ok(true_, ("move %d: the old manifest is true to its files (%s)"):format(n, tostring(why)))
      ok(no_tmp(out), ("move %d: the temporary folder is gone"):format(n))
    end
    ok(committed, "the write gets through once nothing fails")
    ok(points >= 6, "every move was tried as a failure point: " .. points)
    local after, m = check(out)
    ok(after, "the new folder is true to its manifest")
    ok(fixture.read(out .. "/" .. export.MANIFEST) ~= old_manifest, "the new manifest")
    eq(#m.files, 4, "four documents")
  end

  -- ── the data classes, fail-closed: only public and internal; the rest counted by reason, never named ──
  do
    local fx2 = build("folder-classes")
    local out2 = fx2.root .. "/../export-classes"
    -- everything released first, a file of someone else next to it
    local res = write(fx2, out2)
    ok(res, "all three released")
    eq(#listing(out2), 5, "three repositories")
    fixture.write(out2 .. "/README.md", "the results repository\n")
    fixture.write(out2 .. "/repos/notes.txt", "mine\n")
    -- then beta private and gamma without any entry
    fixture.write(
      fx2.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    res = write(fx2, out2)
    ok(res, "written again")
    eq(res.removed, 2, "the files of beta and gamma are removed")
    local files = listing(out2)
    eq(
      #files,
      5,
      "alpha, fleet, manifest, and the two foreign files: " .. table.concat(files, ", ")
    )
    eq(fixture.read(out2 .. "/README.md"), "the results repository\n", "a foreign file is kept")
    eq(fixture.read(out2 .. "/repos/notes.txt"), "mine\n", "a foreign file in repos/ is kept")
    local fleet = vim.json.decode(fixture.read(out2 .. "/fleet.json"))
    eq(#fleet.repos, 1, "one repository")
    eq(fleet.repos[1].name, "alpha.nvim", "alpha")
    eq(fleet.excluded_by, { selection = 1, private = 1, unclassified = 1 }, "counted by reason")
    eq(fleet.excluded, 3, "excluded counts them all")
    for _, f in ipairs(files) do
      local text = fixture.read(out2 .. "/" .. f)
      if f ~= "README.md" and f ~= "repos/notes.txt" then
        ok(not text:find("beta", 1, true), f .. ": beta is not named")
        ok(not text:find("gamma", 1, true), f .. ": gamma is not named")
        ok(not text:find("notes-vault", 1, true), f .. ": the vault is not named")
      end
    end
    ok(check(out2), "true to its manifest")

    -- no areas.json on this device: everything unclassified, nothing exported, the fleet says why
    local missing = fx2.root .. "/../no-config/areas.json"
    res = write(fx2, out2, { classes = { path = missing } })
    ok(res, "written without areas.json")
    fleet = vim.json.decode(fixture.read(out2 .. "/fleet.json"))
    eq(fleet.repos, {}, "no repository")
    eq(fleet.excluded_by, { selection = 1, private = 0, unclassified = 3 }, "all unclassified")
    eq(fleet.classes.problem, export.NO_AREAS, "the fleet says why")
    local listed_ok, mm = check(out2)
    ok(listed_ok, "without areas.json: true to its manifest")
    eq(#mm.files, 1, "only fleet.json is listed")
    eq(
      listing(out2),
      { "README.md", "fleet.json", "repos/notes.txt", export.MANIFEST },
      "no repo file left, the foreign files kept"
    )
    -- the CLI tells the person on stderr, and still exits 0
    local r = cli_export(fx2, { "--out", out2, "--repos-root", fx2.root }, {
      config = fx2.root .. "/../no-config",
    })
    eq(r.code, 0, "CLI without areas.json: exit 0")
    has(r.err, "no areas.json on this device", "CLI: the note")
    has(r.out, "export: 0 repositories", "CLI: zero repositories")

    -- an areas.json that cannot be used: fail-closed, the kind is named, no area
    fixture.write(fx2.areas, '{"schema":1,"areas":{"beta.nvim":{"clas":"public"}}}')
    ok(write(fx2, out2), "written with an unusable areas.json")
    fleet = vim.json.decode(fixture.read(out2 .. "/fleet.json"))
    eq(fleet.repos, {}, "unusable areas.json: nothing")
    has(fleet.classes.problem, "cannot be used (invalid)", "unusable areas.json: the kind")
    ok(not fleet.classes.problem:find("beta", 1, true), "unusable areas.json: no area named")

    -- a lib.nvim without the reader: fail-closed
    local saved_loaded, saved_preload =
      package.loaded["lib.nvim.data_classes"], package.preload["lib.nvim.data_classes"]
    package.loaded["lib.nvim.data_classes"] = nil
    package.preload["lib.nvim.data_classes"] = function()
      error("module 'lib.nvim.data_classes' not found")
    end
    local released, classed = export.release({ fx2.alpha }, { path = fx2.areas })
    package.preload["lib.nvim.data_classes"] = saved_preload
    package.loaded["lib.nvim.data_classes"] = saved_loaded
    eq(released, {}, "no reader: nothing released")
    eq(classed.n_unclassified, 1, "no reader: unclassified")
    has(classed.problem, "no data_classes", "no reader: said")

    -- the export form of `testing call` asks the data classes like the folder does; the local form, which stays on
    -- this machine, does not, and says so (null, never 0)
    fixture.write(
      fx2.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    local restore = fixture.install()
    local doc = export.fleet(fixture.opts(fx2, { remote = false }))
    local ldoc = export.fleet(fixture.opts(fx2, { remote = false, form = "local" }))
    restore()
    local names = {}
    for _, row in ipairs(doc.repos) do
      names[#names + 1] = row.name
    end
    eq(names, { "alpha.nvim" }, "call, export form: only the released repository")
    eq(
      doc.excluded_by,
      { selection = 1, private = 1, unclassified = 1 },
      "call, export form: counted by reason"
    )
    eq(doc.classes, { checked = true, problem = vim.NIL }, "call, export form: checked")
    eq(#ldoc.repos, 3, "call, local form: every repository")
    eq(
      ldoc.excluded_by,
      { selection = 1, private = vim.NIL, unclassified = vim.NIL },
      "call, local form: null"
    )
    eq(ldoc.classes, { checked = false, problem = vim.NIL }, "call, local form: not checked")
  end

  -- ── refusals: nothing is touched that the manifest does not own ──
  do
    local fx3 = build("folder-refuse")
    local busy = fx3.root .. "/../busy"
    fixture.write(busy .. "/README.md", "keep me\n")
    local r = cli_export(fx3, { "--out", busy, "--repos-root", fx3.root })
    eq(r.code, 2, "a folder that is not empty and has no manifest: exit 2")
    has(r.err, "not empty and has no testing-export.json", "... says why")
    eq(listing(busy), { "README.md" }, "... and adds nothing")

    fixture.write(busy .. "/" .. export.MANIFEST, "{ not json")
    r = cli_export(fx3, { "--out", busy, "--repos-root", fx3.root })
    eq(r.code, 2, "a manifest that is none: exit 2")
    eq(listing(busy), { "README.md", export.MANIFEST }, "... nothing added")

    local evil = vim.json.decode(fixture.read(fixture.GOLDEN_DIR .. "/" .. export.MANIFEST))
    evil.files[1].path = "../outside.json"
    fixture.write(busy .. "/" .. export.MANIFEST, vim.json.encode(evil))
    fixture.write(fx3.root .. "/../outside.json", "not yours\n")
    r = cli_export(fx3, { "--out", busy, "--repos-root", fx3.root })
    eq(r.code, 2, "a manifest that names a foreign path: exit 2")
    has(r.err, "names a file this command never writes", "... says so")
    eq(fixture.read(fx3.root .. "/../outside.json"), "not yours\n", "... the file outside is kept")

    -- a file in the way that the manifest does not list is someone else's
    local way = fx3.root .. "/../way"
    fixture.write(fx3.areas, fixture.areas({ ["alpha.nvim"] = "public" }))
    ok(write(fx3, way), "only alpha first")
    fixture.write(fx3.areas, fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "public" }))
    local restore = fixture.install()
    local beta_key = export.deps.key(fx3.beta)
    restore()
    fixture.write(way .. "/repos/" .. beta_key .. ".json", "someone else's\n")
    local res, err = write(fx3, way)
    eq(res, nil, "a file in the way: refused")
    eq(err.code, 2, "... exit 2")
    eq(fixture.read(way .. "/repos/" .. beta_key .. ".json"), "someone else's\n", "... and kept")
    ok(check(way), "... the folder is as it was")

    local file_out = fx3.root .. "/../a-file"
    fixture.write(file_out, "x")
    r = cli_export(fx3, { "--out", file_out, "--repos-root", fx3.root })
    eq(r.code, 2, "--out is a file: exit 2")
    r = cli_export(fx3, { "--repos-root", fx3.root })
    eq(r.code, 2, "no --out: exit 2")
    has(r.err, "--out <dir> is required", "... says so")
    r = cli_export(fx3, { "--out", way, "--bogus" })
    eq(r.code, 2, "an unknown option: exit 2")
    r = cli_export(fx3, { "--out", way, "--repos-root", fx3.root .. "/absent" })
    eq(r.code, 2, "a root that is not there: exit 2")
    r = cli_export(fx3, { "--help" })
    eq(r.code, 0, "--help: exit 0")
    has(r.out, "usage: testing export --out <dir>", "--help: the usage")
  end

  -- ── no absolute path, no root: a fixture below $HOME, then a grep of the folder (and a positive control) ──
  do
    -- $HOME is pointed at a folder of the sandbox (the guard keeps a spec out of the real one); libuv's homedir reads
    -- HOME first on every system, so the redaction and the leak detector see the fixture below $HOME
    -- (USERPROFILE on Windows, where libuv reads that one)
    local saved_home, saved_profile = vim.uv.os_getenv("HOME"), vim.uv.os_getenv("USERPROFILE")
    local function restore_home()
      for name, value in pairs({ HOME = saved_home or false, USERPROFILE = saved_profile or false }) do
        if value then
          vim.uv.os_setenv(name, value)
        else
          vim.uv.os_unsetenv(name)
        end
      end
    end
    local home = fixture.base("home") .. "/home"
    bases[#bases + 1] = vim.fs.dirname(home)
    vim.fn.mkdir(home, "p")
    vim.uv.os_setenv("HOME", home)
    if vim.fn.has("win32") == 1 then
      vim.uv.os_setenv("USERPROFILE", home)
    end
    ok(vim.fs.normalize(vim.uv.os_homedir()) == home, "$HOME is the fixture's home")
    local base = home .. "/repos"
    vim.fn.mkdir(base, "p")
    local okb, fxh = pcall(build, "folder-home", base)
    if not okb then
      restore_home()
      error(fxh, 0)
    end
    local outh = base .. "/export"
    local okr, r = pcall(cli_export, fxh, { "--out", outh, "--repos-root", fxh.root, "--remote" })
    restore_home()
    ok(okr, "below $HOME: raised: " .. tostring(r))
    eq(r.code, 0, "below $HOME: exit 0: " .. r.err)
    local okp, pw = pcall(vim.uv.os_get_passwd)
    local user = okp and type(pw) == "table" and pw.username or vim.env.USERNAME or vim.env.USER
    local homes = { home:lower(), vim.fs.normalize(vim.uv.os_homedir()):lower() }
    ---What of this machine a text holds.
    local function grep(text)
      local hits = {}
      for _, h in ipairs(homes) do
        if text:gsub("\\\\", "/"):gsub("\\", "/"):lower():find(h, 1, true) then
          hits[#hits + 1] = "a home directory"
        end
      end
      if text:find("%f[%a]%a:[\\/]") then
        hits[#hits + 1] = "a drive letter"
      end
      if text:find("/home/", 1, true) then
        hits[#hits + 1] = "/home/"
      end
      if text:find("/Users/", 1, true) then
        hits[#hits + 1] = "/Users/"
      end
      if type(user) == "string" and #user >= 3 and text:lower():find(user:lower(), 1, true) then
        hits[#hits + 1] = "the user name"
      end
      if text:find('"root"', 1, true) then
        hits[#hits + 1] = "a root"
      end
      return hits
    end
    local files = listing(outh)
    eq(#files, 5, "the folder below $HOME")
    for _, f in ipairs(files) do
      local hits = grep(fixture.read(outh .. "/" .. f))
      eq(hits, {}, f .. ": nothing of this machine")
    end
    -- the positive control: the same grep finds a path of this machine put into a file
    local injected = fixture
      .read(outh .. "/fleet.json")
      :gsub('"plugin"', '"x": "' .. fxh.home_file .. '", "plugin"', 1)
    ok(
      #grep(injected) > 0,
      "the grep finds an injected path: " .. table.concat(grep(injected), ", ")
    )
    has(table.concat(grep(injected), ", "), "a home directory", "... as the home directory")
  end

  -- ── the workstation: no local result is read, nothing is run ──
  do
    local fx4 = build("folder-ws")
    local out4 = fx4.root .. "/../export-ws"
    local started = {}
    local real_system = vim.system
    vim.system = function(cmd, ...)
      started[#started + 1] = type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
      return real_system(cmd, ...)
    end
    local okc, r = pcall(cli_export, fx4, { "--out", out4, "--repos-root", fx4.root, "--remote" }, {
      role = "Workstation ",
    })
    vim.system = real_system
    ok(okc, "workstation export raised: " .. tostring(r))
    eq(r.code, 0, "workstation: exit 0: " .. r.err)
    has(r.out, "local results not read (workstation)", "workstation: the summary says so")
    for _, cmd in ipairs(started) do
      ok(
        not cmd:find(vim.v.progpath, 1, true) and not cmd:find("--headless", 1, true),
        "workstation: no editor was started: " .. cmd
      )
    end
    local fleet = vim.json.decode(fixture.read(out4 .. "/fleet.json"))
    eq(fleet.local_read, false, "workstation: local_read false")
    eq(#fleet.repos, 3, "workstation: the repositories are there")
    for _, row in ipairs(fleet.repos) do
      eq(row["local"], vim.NIL, row.name .. ": local is null")
      eq(row.last_green, vim.NIL, row.name .. ": last_green is null")
      eq(row.ci_local, vim.NIL, row.name .. ": ci_local is null")
      eq(row.counts, vim.NIL, row.name .. ": counts are null")
      ok(row.ci_remote ~= vim.NIL, row.name .. ": the CI adapter's record is there (D2)")
    end
    for _, f in ipairs(listing(out4)) do
      local text = fixture.read(out4 .. "/" .. f)
      local valid, problems = export.validate(text)
      ok(valid, "workstation: " .. f .. " is valid: " .. table.concat(problems or {}, "; "))
      local doc = vim.json.decode(text)
      if doc.kind == "repo" then
        eq(doc.cases, {}, f .. ": no case")
        -- required integers of version 1 (a reader of version 1 does arithmetic with them): never widened to null;
        -- local_read false says they are unknown
        eq(doc.cases_red, 0, f .. ": cases_red stays an integer")
        eq(doc.cases_omitted, 0, f .. ": cases_omitted stays an integer")
        eq(doc.local_read, false, f .. ": local_read false")
        local widened = vim.deepcopy(doc)
        widened.cases_red = vim.NIL
        ok(
          not export.validate(widened),
          f .. ": the schema keeps cases_red an integer (null is invalid)"
        )
        widened.cases_red, widened.cases_omitted = 0, vim.NIL
        ok(not export.validate(widened), f .. ": the schema keeps cases_omitted an integer")
      end
    end
    local bad = fx4.root .. "/../export-ws-typo"
    r = cli_export(fx4, { "--out", bad, "--repos-root", fx4.root }, { role = "wrkstation" })
    eq(r.code, 2, "a role that is neither workstation nor default: exit 2")
    has(r.err, "neither workstation nor default", "... says so")
    eq(vim.uv.fs_stat(bad), nil, "... nothing written")
    r = cli_export(fx4, { "--out", bad, "--repos-root", fx4.root }, { role = "default" })
    eq(r.code, 0, "default: exit 0")
    eq(vim.json.decode(fixture.read(bad .. "/fleet.json")).local_read, true, "default: read")
  end

  -- ── `testing ci --repos ... --export=<dir>`: the folder at the end of a fleet run (D1) ──
  do
    local repos = require("testing.ci.repos")
    local fx5 = build("folder-ci")
    local out5 = fx5.root .. "/../export-ci"
    local seen = {}
    local function run(args, role)
      local outl, errl = {}, {}
      local real = repos.system
      local saved_getenv = folder.deps.getenv
      folder.deps.getenv = function(name)
        if name == "NVIM_MACHINE_ROLE" then
          return role
        end
        return vim.env[name]
      end
      repos.system = function(argv, opts, on_exit)
        seen[#seen + 1] = table.concat(argv, " ")
        opts.stdout(nil, "child\n")
        vim.defer_fn(function()
          on_exit({ code = 0, stdout = "", stderr = "" })
        end, 10)
        return {}
      end
      local restore = fixture.install()
      local saved_env = vim.env.TASKS_DESKTOP_CONFIG_DIR
      vim.env.TASKS_DESKTOP_CONFIG_DIR = vim.fs.dirname(fx5.areas)
      local pass, code = pcall(cli.main, vim.list_extend({ "ci" }, args), {
        out = function(s)
          outl[#outl + 1] = s
        end,
        err = function(s)
          errl[#errl + 1] = s
        end,
        state_dir = fx5.state,
      })
      vim.env.TASKS_DESKTOP_CONFIG_DIR = saved_env
      restore()
      repos.system = real
      folder.deps.getenv = saved_getenv
      if not pass then
        error(code, 0)
      end
      return { code = code, out = table.concat(outl, "\n"), err = table.concat(errl, "\n") }
    end
    local list = table.concat({ fx5.alpha, fx5.beta, fx5.gamma }, ",")
    local r = run({ "--repos=" .. list, "--force", "--export=" .. out5 })
    eq(r.code, 0, "ci --export: exit 0: " .. r.err)
    has(r.out, "export: 3 repositories", "ci --export: the summary")
    ok(check(out5), "ci --export: the folder is true to its manifest")
    eq(#listing(out5), 5, "ci --export: three repositories")
    ok(#seen == 3, "ci --export: the three runs happened")
    -- a shallow clone among the repositories: ci --export warns on stderr, as testing export does
    local saved_shallow = export.deps.shallow
    export.deps.shallow = function(dir)
      return vim.fs.basename(dir) == "alpha.nvim"
    end
    seen = {}
    local rs = run({ "--repos=" .. list, "--force", "--export=" .. out5 })
    export.deps.shallow = saved_shallow
    eq(rs.code, 0, "ci --export with a shallow clone: exit 0: " .. rs.err)
    has(
      rs.err,
      "testing ci: export: warning: alpha.nvim is a shallow clone",
      "ci --export: the shallow warning"
    )
    -- a folder the export would refuse: before anything runs
    seen = {}
    local busy = fx5.root .. "/../busy-ci"
    fixture.write(busy .. "/x.txt", "x")
    r = run({ "--repos=" .. list, "--force", "--export=" .. busy })
    eq(r.code, 2, "ci --export into a foreign folder: exit 2")
    eq(#seen, 0, "... nothing ran")
    -- a file in the way that the manifest does not list: refused before anything runs, not exit 3 after the runs
    local stranger = out5 .. "/repos/zzz.nvim-000000000000.json"
    fixture.write(stranger, "someone else's\n")
    r = run({ "--repos=" .. list, "--force", "--export=" .. out5 })
    eq(r.code, 2, "ci --export with a file in the way: exit 2")
    has(r.err, "in the way", "... says why")
    eq(#seen, 0, "... before anything ran")
    eq(fixture.read(stranger), "someone else's\n", "... the file is kept")
    vim.uv.fs_unlink(stranger)
    -- a typo in NVIM_MACHINE_ROLE: refused before anything runs
    r = run({ "--repos=" .. list, "--force", "--export=" .. out5 }, "wrkstation")
    eq(r.code, 2, "ci --export with a role typo: exit 2")
    has(r.err, "neither workstation nor default", "... says so")
    eq(#seen, 0, "... nothing ran")
    -- the workstation: the export of the run reads no local result
    r = run({ "--repos=" .. list, "--force", "--export=" .. out5 }, "workstation")
    eq(r.code, 0, "ci --export on the workstation: exit 0: " .. r.err)
    has(r.out, "local results not read (workstation)", "... the summary says so")
    eq(
      vim.json.decode(fixture.read(out5 .. "/fleet.json")).local_read,
      false,
      "... local_read false"
    )
    seen = {}
    -- an export that cannot be written makes the run infrastructure
    local real_rename = folder.deps.rename
    folder.deps.rename = function()
      return nil, "injected"
    end
    local okr, r2 =
      pcall(run, { "--repos=" .. list, "--force", "--export=" .. fx5.root .. "/../ci-fail" })
    folder.deps.rename = real_rename
    ok(okr, "ci --export failing raised: " .. tostring(r2))
    eq(r2.code, 3, "ci --export that cannot be written: exit 3")
    ok(not r2.out:find(require("testing.ci").SENTINEL, 1, true), "... no sentinel")
    -- a folder that changed during the run and is refused only at the end: the refusal it is (2), not 3
    local real_folder_write = folder.write
    folder.write = function()
      return nil, { code = folder.EXIT_USAGE, message = "x is in the way and not listed: refused" }
    end
    local okw, r3 = pcall(run, { "--repos=" .. list, "--force", "--export=" .. out5 })
    folder.write = real_folder_write
    ok(okw, "ci --export refused at the end raised: " .. tostring(r3))
    eq(r3.code, 2, "ci --export refused at the end: exit 2")
    has(r3.err, "in the way", "... says why")
  end

  -- ── a repository that is no longer exported: its file never stays next to a manifest that does not own it ──
  do
    local fx6 = build("folder-stale")
    local out6 = fx6.root .. "/../export-stale"
    fixture.write(fx6.areas, fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "public" }))
    ok(write(fx6, out6), "alpha and beta exported")
    local restore = fixture.install()
    local beta_rel = "repos/" .. export.deps.key(fx6.beta) .. ".json"
    restore()
    local beta_file = out6 .. "/" .. beta_rel
    ok(fixture.read(beta_file), "beta's file is there")
    local _, _, old_manifest = check(out6)

    -- beta turns private and its file cannot be moved aside (a reader holds it on Windows): put back, exit 3, and
    -- the old manifest still owns it, so the next export tries again
    fixture.write(
      fx6.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    local real_rename, real_delete = folder.deps.rename, folder.deps.delete
    local function fail_beta(also_back)
      folder.deps.rename = function(from, to)
        if vim.fs.normalize(from) == vim.fs.normalize(beta_file) then
          return nil, "injected: held by a reader"
        end
        if also_back and from:find("/old/", 1, true) then
          return nil, "injected: cannot put back"
        end
        return real_rename(from, to)
      end
    end
    fail_beta(false)
    local res, err = write(fx6, out6)
    folder.deps.rename = real_rename
    eq(res, nil, "stale file held: no result")
    eq(err and err.code, 3, "stale file held: exit 3, never a green export that leaves it")
    has(err and err.message or "", "cannot move " .. beta_rel .. " aside", "... names the file")
    has(err and err.message or "", "the folder is as it was", "... put back")
    eq(
      fixture.read(out6 .. "/" .. export.MANIFEST),
      old_manifest,
      "... the old manifest, which owns it"
    )
    ok(check(out6), "... true to its files")
    ok(no_tmp(out6), "... no temporary folder")

    -- the next export, nothing held: the file is gone, nothing else of it is left
    res = write(fx6, out6)
    ok(res, "the next export")
    eq(res.removed, 1, "... removes beta's file")
    eq(fixture.read(beta_file), nil, "... beta's file is gone")
    ok(no_tmp(out6), "... no temporary folder")
    for _, f in ipairs(listing(out6)) do
      ok(not fixture.read(out6 .. "/" .. f):find("beta", 1, true), f .. ": beta is not named")
    end

    -- beta public again: exported again, never refused as "in the way"
    fixture.write(fx6.areas, fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "public" }))
    res, err = write(fx6, out6)
    ok(res, "beta public again: exported: " .. tostring(err and err.message))
    ok(fixture.read(beta_file), "... its file is back")
    ok(check(out6), "... true to its manifest")

    -- a file of the shape this command writes that the manifest does not list: refused by inspect, kept
    local stranger = out6 .. "/repos/zzz.nvim-000000000000.json"
    fixture.write(stranger, "someone else's\n")
    local st, problem = folder.inspect(out6)
    eq(st, nil, "inspect: a file in the way is refused")
    has(tostring(problem), "repos/zzz.nvim-000000000000.json is in the way", "... named")
    local r = cli_export(fx6, { "--out", out6, "--repos-root", fx6.root })
    eq(r.code, 2, "... the CLI: exit 2")
    eq(fixture.read(stranger), "someone else's\n", "... kept")
    vim.uv.fs_unlink(stranger)

    -- the temporary folder cannot be removed at the end: a warning that names it
    folder.deps.delete = function()
      return -1
    end
    fixture.write(
      fx6.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    res = write(fx6, out6)
    folder.deps.delete = real_delete
    ok(res, "the temporary folder kept: still written")
    has(table.concat(res.warnings, "\n"), ".tmp-", "... the warning names it")
    has(table.concat(res.warnings, "\n"), "remove it by hand", "... and says what to do")
    eq(fixture.read(beta_file), nil, "... beta's file is not in repos/")
    for name in vim.fs.dir(out6) do
      if name:match("^%.tmp%-") then
        vim.fn.delete(out6 .. "/" .. name, "rf")
      end
    end

    -- the folder cannot be put back either: .tmp-<id> is kept, named, and holds the old files
    fixture.write(fx6.areas, fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "public" }))
    ok(write(fx6, out6), "beta public once more")
    fixture.write(
      fx6.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    fail_beta(true)
    res, err = write(fx6, out6)
    folder.deps.rename = real_rename
    eq(res, nil, "not put back: no result")
    eq(err and err.code, 3, "not put back: exit 3")
    has(err and err.message or "", "could not be put back", "... says so")
    local kept = (err and err.message or ""):match("the old files are in (.-%.tmp%-[^/]+)/old$")
    ok(kept, "... names the temporary folder: " .. tostring(err and err.message))
    ok(kept and vim.fn.isdirectory(kept) == 1, "... which is kept")
    ok(kept and fixture.read(kept .. "/old/fleet.json"), "... with the old fleet.json in its old/")

    -- a failed write into a folder it created removes that folder again
    local fresh = fx6.root .. "/../export-fresh"
    local real_write = folder.deps.write
    folder.deps.write = function()
      return nil, "injected write failure"
    end
    _, err = write(fx6, fresh)
    folder.deps.write = real_write
    eq(err and err.code, 3, "a failed first write: exit 3")
    eq(vim.uv.fs_stat(fresh), nil, "... the folder it created is gone again")
  end

  -- ── the leftover .tmp-<id> of an earlier write: removed fail-closed, never anything unknown ──
  do
    local fx8 = build("folder-leftover")
    local out8 = fx8.root .. "/../export-leftover"
    fixture.write(
      fx8.areas,
      fixture.areas({ ["alpha.nvim"] = "public", ["beta.nvim"] = "private" })
    )
    ok(write(fx8, out8), "the first export (beta private)")
    local restore = fixture.install()
    local beta_key = export.deps.key(fx8.beta)
    restore()
    -- the pids of the made-up leftovers below run no write (pid 1 is init on POSIX); a spec says when one runs
    local real_alive = folder.deps.alive
    local running = {}
    folder.deps.alive = function(pid)
      return running[pid] == true
    end

    -- a crash left .tmp-<id> behind with beta's document of the time it was public in old/
    local crash = out8 .. "/.tmp-4242-deadbeef"
    fixture.write(
      crash .. "/old/repos/" .. beta_key .. ".json",
      '{"name":"beta.nvim","private":1}\n'
    )
    fixture.write(crash .. "/new/fleet.json", "{}\n")
    fixture.write(crash .. "/new/" .. export.MANIFEST, "{}\n")
    vim.fn.mkdir(crash .. "/new/repos", "p")
    local st = folder.inspect(out8)
    eq(st and st.leftovers, { ".tmp-4242-deadbeef" }, "inspect: the leftover is named")
    local res, err = write(fx8, out8)
    ok(res, "a leftover of the export's own shape: written: " .. tostring(err and err.message))
    eq(vim.uv.fs_lstat(crash), nil, "... the leftover is gone")
    ok(no_tmp(out8), "... no .tmp-* left")
    ok(check(out8), "... true to its manifest")
    for _, f in ipairs(listing(out8)) do
      ok(not fixture.read(out8 .. "/" .. f):find("beta", 1, true), f .. ": beta is not named")
    end
    -- never silent: it may be the one a failed write named as the place of the old files
    has(
      table.concat(res and res.warnings or {}, "\n"),
      "removed " .. out8 .. "/.tmp-4242-deadbeef, the temporary folder an earlier write left behind",
      "... a warning names the removed leftover"
    )
    fixture.write(crash .. "/old/fleet.json", "{}\n")
    local rw = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
    eq(rw.code, 0, "the CLI with a leftover: exit 0: " .. rw.err)
    has(rw.err, "warning: removed " .. out8 .. "/.tmp-4242-deadbeef", "... the warning on stderr")
    eq(vim.uv.fs_lstat(crash), nil, "... gone")

    -- the leftover of a write that still runs (another process): refused, untouched
    local live = out8 .. "/.tmp-4250-0badf00d"
    fixture.write(live .. "/old/fleet.json", "old fleet\n")
    running[4250] = true
    local manifest_live = fixture.read(out8 .. "/" .. export.MANIFEST)
    rw = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
    eq(rw.code, 2, "a .tmp-* of a running write: exit 2")
    has(
      rw.err,
      ".tmp-4250-0badf00d is the temporary folder of a write that is still running (process 4250)",
      "... says why"
    )
    eq(fixture.read(live .. "/old/fleet.json"), "old fleet\n", "... its old/ is kept")
    eq(fixture.read(out8 .. "/" .. export.MANIFEST), manifest_live, "... the manifest unchanged")
    running[4250] = nil
    ok(write(fx8, out8), "... once that process is gone it is a leftover")
    eq(vim.uv.fs_lstat(live), nil, "... and removed")
    -- a write of this process that is not done is never a leftover either (a second write meanwhile is refused)
    local nested
    local real_write8 = folder.deps.write
    folder.deps.write = function(path, text)
      if not nested then
        nested = { folder.inspect(out8) }
      end
      return real_write8(path, text)
    end
    fixture.write(
      fx8.areas,
      fixture.areas({ ["alpha.nvim"] = "internal", ["beta.nvim"] = "private" })
    )
    res = write(fx8, out8)
    folder.deps.write = real_write8
    ok(res, "a write with a second one meanwhile: written")
    eq(nested and nested[1], nil, "... the second one is refused")
    has(
      tostring(nested and nested[2]),
      "of a write that is still running (process " .. vim.uv.os_getpid() .. ")",
      "... names this process"
    )
    ok(no_tmp(out8), "... and the first removed its own temporary folder")
    -- the default seam: this process runs, a process that ended does not
    eq(real_alive(vim.uv.os_getpid()), true, "alive: this process")
    local proc = vim.system({ vim.v.progpath, "--headless", "--clean", "-c", "qa!" })
    local ended = proc.pid
    proc:wait()
    eq(real_alive(ended), false, "alive: not a process that ended")
    -- a name of another shape is someone else's: never a leftover, never touched
    local review = out8 .. "/.tmp-review"
    fixture.write(review .. "/new/fleet.json", "my scratch copy\n")
    fixture.write(out8 .. "/.tmp-notes", "mine\n")
    res, err = write(fx8, out8)
    ok(res, "a .tmp-review and a .tmp-notes: written: " .. tostring(err and err.message))
    eq(fixture.read(review .. "/new/fleet.json"), "my scratch copy\n", "... .tmp-review is kept")
    eq(fixture.read(out8 .. "/.tmp-notes"), "mine\n", "... .tmp-notes is kept")
    vim.fn.delete(review, "rf")
    vim.uv.fs_unlink(out8 .. "/.tmp-notes")

    -- a leftover that holds a file an export never writes: refused (exit 2), nothing removed
    local _, _, manifest_before = check(out8)
    local odd = out8 .. "/.tmp-4243-cafebabe"
    fixture.write(odd .. "/old/repos/" .. beta_key .. ".json", "beta\n")
    fixture.write(odd .. "/new/notes.txt", "someone's notes\n")
    local r = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
    eq(r.code, 2, "a leftover with an unknown file: exit 2")
    has(r.err, ".tmp-4243-cafebabe/new/notes.txt is nothing an export writes there", "... names it")
    has(r.err, "nothing is removed", "... and says nothing is removed")
    eq(fixture.read(odd .. "/new/notes.txt"), "someone's notes\n", "... the unknown file is kept")
    eq(
      fixture.read(odd .. "/old/repos/" .. beta_key .. ".json"),
      "beta\n",
      "... and the rest of it"
    )
    eq(fixture.read(out8 .. "/" .. export.MANIFEST), manifest_before, "... the manifest unchanged")
    -- a subdirectory of another name is unknown too
    vim.uv.fs_unlink(odd .. "/new/notes.txt")
    vim.fn.mkdir(odd .. "/old/repos/nested", "p")
    st, err = folder.inspect(out8)
    eq(st, nil, "a leftover with an unknown directory: refused")
    has(tostring(err), "old/repos/nested is nothing an export writes there", "... named")
    eq(vim.fn.isdirectory(odd .. "/old/repos/nested"), 1, "... kept")
    vim.fn.delete(odd, "rf")
    -- a .tmp-<pid>-<hex> that is no directory is no leftover of a write
    local odd_file = out8 .. "/.tmp-4244-0badcafe"
    fixture.write(odd_file, "mine\n")
    r = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
    eq(r.code, 2, "a .tmp-* file: exit 2")
    has(r.err, ".tmp-4244-0badcafe is no plain directory", "... says why")
    eq(fixture.read(odd_file), "mine\n", "... kept")
    vim.uv.fs_unlink(odd_file)

    -- one that turns into a file after the check (before it is removed): the same refusal, the same words
    local turned = out8 .. "/.tmp-4245-0ddba11e"
    fixture.write(turned .. "/new/fleet.json", "{}\n")
    local calls = 0
    folder.deps.alive = function()
      calls = calls + 1
      if calls == 2 then
        vim.fn.delete(turned, "rf")
        fixture.write(turned, "now a file\n")
      end
      return false
    end
    _, err = write(fx8, out8)
    folder.deps.alive = function(pid)
      return running[pid] == true
    end
    eq(err and err.code, 2, "a leftover that became a file meanwhile: exit 2")
    has(err and err.message or "", ".tmp-4245-0ddba11e is no plain directory", "... says why")
    ok(
      not (err and err.message or ""):find("nothing an export writes there", 1, true),
      "... not the words of an unknown entry: " .. tostring(err and err.message)
    )
    eq(fixture.read(turned), "now a file\n", "... kept")
    vim.uv.fs_unlink(turned)

    -- links: a leftover that is a link, or holds one, is refused, and nothing behind the link is touched
    -- a junction needs a target without `..` to resolve (else the sabotage `fs_stat` would not follow it)
    local behind = vim.fs.normalize(fx8.root .. "/../leftover-behind")
    fixture.write(behind .. "/repos/" .. beta_key .. ".json", "behind the link\n")
    local inner = out8 .. "/.tmp-4246-1eaf1eaf"
    vim.fn.mkdir(inner .. "/new", "p")
    if
      not vim.uv.fs_symlink(
        behind .. "/repos",
        inner .. "/new/repos",
        { dir = true, junction = true }
      )
    then
      print("n/a  no directory link can be created on this system")
    else
      r = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
      eq(r.code, 2, "a leftover that holds a link: exit 2")
      has(r.err, ".tmp-4246-1eaf1eaf/new/repos is nothing an export writes there", "... names it")
      eq(
        fixture.read(behind .. "/repos/" .. beta_key .. ".json"),
        "behind the link\n",
        "... nothing behind the link is touched"
      )
      if not vim.uv.fs_rmdir(inner .. "/new/repos") then
        vim.uv.fs_unlink(inner .. "/new/repos")
      end
    end
    vim.fn.delete(inner, "rf")
    -- its target holds only what a write creates there: the link alone is what makes it no leftover
    local outer, target = out8 .. "/.tmp-4247-1eaf1eaf", behind .. "/like-a-leftover"
    fixture.write(target .. "/new/fleet.json", "{}\n")
    fixture.write(target .. "/old/repos/" .. beta_key .. ".json", "behind the link\n")
    if not vim.uv.fs_symlink(target, outer, { dir = true, junction = true }) then
      print("n/a  no directory link can be created on this system")
    else
      r = cli_export(fx8, { "--out", out8, "--repos-root", fx8.root })
      eq(r.code, 2, "a leftover that is a link: exit 2")
      has(r.err, ".tmp-4247-1eaf1eaf is no plain directory", "... says why")
      eq(
        fixture.read(target .. "/new/fleet.json"),
        "{}\n",
        "... nothing behind the link is touched"
      )
      eq(
        fixture.read(target .. "/old/repos/" .. beta_key .. ".json"),
        "behind the link\n",
        "... nothing at all"
      )
      if not vim.uv.fs_rmdir(outer) then
        vim.uv.fs_unlink(outer)
      end
    end
    vim.fn.delete(behind, "rf")

    -- a leftover that cannot be removed: exit 3 before anything is written, the folder as it was
    fixture.write(crash .. "/old/fleet.json", "{}\n")
    local real_unlink = folder.deps.unlink
    folder.deps.unlink = function()
      return nil, "injected"
    end
    res, err = write(fx8, out8)
    folder.deps.unlink = real_unlink
    eq(res, nil, "a leftover that cannot be removed: no result")
    eq(err and err.code, 3, "... exit 3")
    has(err and err.message or "", "the temporary folder of an earlier write", "... says what")
    eq(fixture.read(out8 .. "/" .. export.MANIFEST), manifest_before, "... the manifest unchanged")
    ok(write(fx8, out8), "... the next write removes it")
    eq(vim.uv.fs_lstat(crash), nil, "... gone")

    -- the first export into a folder that holds nothing but a leftover: an empty folder
    local first = fx8.root .. "/../export-first"
    fixture.write(first .. "/.tmp-1-ab/old/repos/" .. beta_key .. ".json", "beta\n")
    res, err = write(fx8, first)
    ok(res, "only a leftover, no manifest: written: " .. tostring(err and err.message))
    ok(no_tmp(first), "... the leftover is gone")
    ok(check(first), "... true to its manifest")
    -- next to a foreign file it is still a folder that is not empty
    local busy8 = fx8.root .. "/../export-busy"
    fixture.write(busy8 .. "/.tmp-1-ab/new/fleet.json", "{}\n")
    fixture.write(busy8 .. "/README.md", "keep me\n")
    r = cli_export(fx8, { "--out", busy8, "--repos-root", fx8.root })
    eq(r.code, 2, "a leftover and a foreign file, no manifest: exit 2")
    has(r.err, "not empty and has no testing-export.json", "... says why")
    eq(fixture.read(busy8 .. "/.tmp-1-ab/new/fleet.json"), "{}\n", "... the leftover is kept")
    -- a .tmp-* of another shape is not the export's: it makes a folder without a manifest not empty
    local scratch = fx8.root .. "/../export-scratch"
    fixture.write(scratch .. "/.tmp-review/new/fleet.json", "{}\n")
    r = cli_export(fx8, { "--out", scratch, "--repos-root", fx8.root })
    eq(r.code, 2, "only a .tmp-review, no manifest: exit 2")
    has(r.err, "not empty and has no testing-export.json", "... says why")
    eq(fixture.read(scratch .. "/.tmp-review/new/fleet.json"), "{}\n", "... kept")
    folder.deps.alive = real_alive
  end

  -- ── a `repos` that is a link: refused, nothing behind it is touched ──
  do
    local fx7 = build("folder-link")
    local out7 = fx7.root .. "/../export-link"
    ok(write(fx7, out7), "the first export")
    local real_repos = fx7.root .. "/../repos-elsewhere"
    ok(vim.uv.fs_rename(out7 .. "/repos", real_repos), "repos moved away")
    local linked = vim.uv.fs_symlink(real_repos, out7 .. "/repos", { dir = true, junction = true })
    if not linked then
      vim.uv.fs_rename(real_repos, out7 .. "/repos")
      print("n/a  no directory link can be created on this system")
    else
      local before = listing(real_repos)
      local r = cli_export(fx7, { "--out", out7, "--repos-root", fx7.root })
      eq(r.code, 2, "a repos that is a link: exit 2")
      has(r.err, "is not a plain directory (a link?)", "... says why")
      eq(listing(real_repos), before, "... nothing behind the link is touched")
      if not vim.uv.fs_rmdir(out7 .. "/repos") then
        vim.uv.fs_unlink(out7 .. "/repos")
      end
    end
  end

  for _, base in ipairs(bases) do
    vim.fn.delete(base, "rf")
  end
end
