-- TESTS/testing/explain_spec.lua -- `testing explain`: why a spec file is selected, taken from the cache, run or
-- left out. The explanation is made from the SAME call that makes the key (one function), it names what changed
-- since the stored entry (a file with its hashes, an environment variable by name, the configuration, the Neovim
-- version), the file and line of what makes a spec uncacheable, and it changes nothing (display only).

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type, redundant-parameter

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local cli = require("testing.cli")
  local cache = require("testing.cache")
  local explain = require("testing.cache.explain")
  local scan = require("testing.affected.scan")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-explainspec"
  vim.fn.mkdir(tmp, "p")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end

  ---@param root string
  ---@param ... string
  local function git(root, ...)
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
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end

  local cache_dir = tmp .. "/cache"
  local state_dir = tmp .. "/state"

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string }
  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      cache_dir = cache_dir,
      color = false,
      affected = { getenv = function() end, provider = false },
    })
    package.loaded["proj.mod"] = nil
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local function json(argv)
    local res = run(argv)
    local good, doc = pcall(vim.json.decode, res.out)
    ok(
      good and type(doc) == "table",
      "explain --json prints one JSON document: " .. res.out:sub(1, 300)
    )
    return good and doc or {}, res
  end

  ---a pure, b clock (line 2), c loads proj.mod, d starts a process (line 2), e reads an environment variable with a
  ---hostile name (an ESC byte in it).
  local root = tmp .. "/p"
  write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
  write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n")
  write(
    root .. "/TESTS/b_spec.lua",
    "return function(H)\n  H.ok(os.time() > 0, 'the clock')\nend\n"
  )
  write(
    root .. "/TESTS/c_spec.lua",
    "return function(H)\n  H.ok(require('proj.mod').value >= 1, 'the module')\nend\n"
  )
  write(
    root .. "/TESTS/d_spec.lua",
    "return function(H)\n  H.ok(type(vim.system) == 'function', 'the process api')\nend\n"
  )
  write(
    root .. "/TESTS/e_spec.lua",
    "return function(H)\n  H.ok(os.getenv('EVIL\27[31m') == nil, 'hostile name')\nend\n"
  )
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  git(root, "init", "-q", "-b", "main")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "init")

  local function entries()
    return cache.stats({ root = root, cache_dir = cache_dir }).entries
  end

  -- ---------------------------------------------------------------- nothing stored yet: miss, nothing to compare
  local cold = json({ "explain", root, "a_spec", "--json" })
  eq(#cold.specs, 1, "one spec asked about, one record")
  eq(cold.specs[1].status, "miss", "nothing stored: a miss")
  eq(cold.specs[1].compare, "none", "and there is nothing to compare with")
  has(cold.specs[1].compare_why, "no earlier entry", "the comparison says why it is not possible")
  eq(entries(), 0, "explain stored nothing")

  local first = run({ root, "--cached", "--env-allow", "PROJ_FLAG" })
  eq(first.code, 0, "the cached run that stores the entries is green\n" .. first.err .. first.out)
  local stored = entries()
  ok(stored >= 2, "entries were stored (a and c): " .. stored)

  -- ---------------------------------------------------------------- a hit; the explanation IS the key
  local hit = json({ "explain", root, "a_spec", "--json", "--env-allow", "PROJ_FLAG" })
  local a = hit.specs[1]
  eq(a.status, "hit", "an unchanged pure spec is a hit")
  eq(#a.key, 64, "the key is shown")
  eq(
    vim.fn.sha256(table.concat(a.parts, "\n")),
    a.key,
    "the key lines ARE what the key is the hash of (one function makes both)"
  )
  local on_disk = vim.json.decode(
    read(
      cache_dir
        .. "/testing/"
        .. vim.fn.readdir(cache_dir .. "/testing")[1]
        .. "/entries/"
        .. a.key
        .. ".json"
    )
  )
  eq(on_disk.key, a.key, "the key explain shows is the name of the entry the run stored")
  eq(
    on_disk.parts,
    a.parts,
    "and the entry carries the same key lines (hashes and names, no content)"
  )
  for _, line in ipairs(a.parts) do
    ok(#line <= 400 and not line:find("%c"), "a key line is short and clean: " .. line:sub(1, 60))
  end
  has(hit.specs[1].selection.text, "every spec file runs", "no selection flag: every spec runs")

  -- explain changes nothing: no entry, not even the age of the one it looked at
  local entry_path = ("%s/testing/%s/entries/%s.json"):format(
    cache_dir,
    vim.fn.readdir(cache_dir .. "/testing")[1],
    a.key
  )
  local before = vim.uv.fs_stat(entry_path).mtime
  local n_before = entries()
  vim.wait(1100)
  eq(
    run({ "explain", root, "a_spec", "--env-allow", "PROJ_FLAG" }).out:match("cache:%s+(%a+)"),
    "hit",
    "(the entry looked at is a hit)"
  )
  run({ "explain", root, "--all", "--env-allow", "PROJ_FLAG" })
  eq(entries(), n_before, "explain writes no entry")
  local after = vim.uv.fs_stat(entry_path).mtime
  eq(
    { after.sec, after.nsec },
    { before.sec, before.nsec },
    "and does not refresh the age of an entry"
  )

  -- ---------------------------------------------------------------- uncacheable: file, line and the way out
  local b = json({ "explain", root, "b_spec", "--json" }).specs[1]
  eq(b.status, "uncacheable", "a spec that reads the clock has no key")
  eq(b.kind, "clock", "the kind of the reason")
  eq(
    b.location,
    { file = "TESTS/b_spec.lua", line = 2, source = "H.ok(os.time() > 0, 'the clock')" },
    "file, line and the source line"
  )
  has(b.way_out, "-- @cache-allow time", "the way out names the declaration")
  has(b.way_out, "-- @cache off", "and the other one")
  local d = json({ "explain", root, "d_spec", "--json" }).specs[1]
  eq(d.kind, "process", "a spec that starts a process")
  eq(d.location.line, 2, "with its line")
  has(d.way_out, "-- @cache-allow spawn", "and its way out")
  local text_b = run({ "explain", root, "b_spec" })
  has(text_b.out, "uncacheable: reads the clock", "the terminal text says it")
  has(text_b.out, "at: TESTS/b_spec.lua:2", "with file and line")

  -- hostile input: the name of an environment variable carries an ESC byte
  local hostile_text = run({ "explain", root, "e_spec" })
  has(hostile_text.out, "EVIL", "the reason names the variable")
  lacks(
    hostile_text.out:gsub("\n", ""),
    "\27",
    "the terminal text carries no escape sequence of the project"
  )
  ok(not hostile_text.out:gsub("\n", ""):find("%c"), "and no control character at all")
  local hostile_json = run({ "explain", root, "e_spec", "--json" })
  ok(not hostile_json.out:find("\27", 1, true), "the JSON escapes it as well")
  eq(
    vim.json.decode(hostile_json.out).specs[1].status,
    "uncacheable",
    "and it is still decoded as one record"
  )

  -- ---------------------------------------------------------------- a miss says what changed
  write(root .. "/lua/proj/mod.lua", "return { value = 2 }\n")
  local c = json({ "explain", root, "c_spec", "--json", "--env-allow", "PROJ_FLAG" }).specs[1]
  eq(c.status, "miss", "a changed dependency: a miss")
  eq(c.compare, "ok", "compared with the stored entry")
  local dep
  for _, ch in ipairs(c.changes) do
    if ch.kind == "dep" and ch.name == "lua/proj/mod.lua" then
      dep = ch
    end
  end
  ok(dep ~= nil, "the dependency that changed is named: " .. vim.inspect(c.changes))
  eq(dep.change, "changed", "as changed")
  ok(
    dep.old:match("^%x+$") and dep.new:match("^%x+$") and dep.old ~= dep.new,
    "with its old and its new hash"
  )
  eq(#c.changes, 1, "and nothing else")
  local text_c = run({ "explain", root, "c_spec", "--env-allow", "PROJ_FLAG" })
  has(text_c.out, "lua/proj/mod.lua", "the terminal names the file")
  has(text_c.out, dep.old .. " -> " .. dep.new, "with old and new hash")
  write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")

  -- an environment variable: its NAME is shown, never its value
  vim.fn.setenv("PROJ_FLAG", "s3cr3t-value-42")
  local e1 = run({ "explain", root, "a_spec", "--json", "--env-allow", "PROJ_FLAG" })
  lacks(e1.out, "s3cr3t-value-42", "the value of an environment variable is never printed")
  local env_change
  for _, ch in ipairs(vim.json.decode(e1.out).specs[1].changes or {}) do
    if ch.kind == "env" then
      env_change = ch
    end
  end
  ok(env_change ~= nil, "a changed environment variable is a change: " .. e1.out:sub(1, 400))
  eq(env_change.name, "PROJ_FLAG", "named")
  eq(env_change.old, "<unset>", "it was not set when the entry was stored")
  ok(env_change.new:match("^%x+$") ~= nil, "and the new state is a hash")
  local e1_text = run({ "explain", root, "a_spec", "--env-allow", "PROJ_FLAG" })
  lacks(e1_text.out, "s3cr3t-value-42", "nor in the terminal text")
  vim.fn.setenv("PROJ_FLAG", vim.NIL)

  -- the configuration of the project
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } } -- edited\n"
  )
  local cfg = json({ "explain", root, "a_spec", "--json", "--env-allow", "PROJ_FLAG" }).specs[1]
  local cfg_kinds = {}
  for _, ch in ipairs(cfg.changes or {}) do
    cfg_kinds[ch.kind] = true
  end
  ok(cfg_kinds["project-config"], "a changed .testing.lua is named: " .. vim.inspect(cfg.changes))
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )

  -- an entry of an older version has no key lines: no comparison, never an error
  local latest = cache.latest({ root = root, cache_dir = cache_dir })
  local old_key = latest["TESTS/a_spec.lua"].key
  local old_path = ("%s/testing/%s/entries/%s.json"):format(
    cache_dir,
    vim.fn.readdir(cache_dir .. "/testing")[1],
    old_key
  )
  local old_entry = vim.json.decode(read(old_path))
  old_entry.parts = nil
  write(old_path, vim.json.encode(old_entry))
  write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 2 == 3, 'arithmetic')\nend\n")
  local legacy = json({ "explain", root, "a_spec", "--json", "--env-allow", "PROJ_FLAG" }).specs[1]
  eq(legacy.status, "miss", "the spec changed: a miss")
  eq(legacy.compare, "none", "an entry without key lines: the comparison is not possible")
  has(legacy.compare_why, "older version", "and it says why")
  has(
    run({ "explain", root, "a_spec", "--env-allow", "PROJ_FLAG" }).out,
    "comparison not possible",
    "also in the text"
  )
  write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n")

  -- ---------------------------------------------------------------- selection: left out by --changed
  write(root .. "/lua/proj/mod.lua", "return { value = 3 }\n")
  local left = run({ "explain", root, "a_spec", "c_spec", "--changed" })
  eq(left.code, 0, "explain with --changed\n" .. left.err)
  local a_block, c_block =
    left.out:match("^(.-)\n\nTESTS/c_spec"), left.out:match("\n\n(TESTS/c_spec.*)$")
  has(a_block, "left out by --changed", "a spec the change does not reach is left out")
  has(c_block, "selected by --changed", "a spec it reaches is selected")
  has(c_block, "proj.mod", "with the reason of the selection (the module that reaches it)")
  write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")

  -- ---------------------------------------------------------------- --all
  local all = run({ "explain", root, "--all", "--env-allow", "PROJ_FLAG" })
  has(all.out, "testing explain --all: 5 spec files", "every spec file")
  has(all.out, "hit rate", "the hit rate")
  has(all.out, "why the files have no key", "and the ranking of the reasons")
  has(all.out, "reads the clock", "with the clock in it")
  local all_json = json({ "explain", root, "--all", "--json", "--env-allow", "PROJ_FLAG" })
  eq(all_json.summary.specs, 5, "the summary counts the files")
  eq(
    all_json.summary.hit
      + all_json.summary.miss
      + all_json.summary.uncacheable
      + all_json.summary.off,
    5,
    "and every file is in one class"
  )
  eq(all_json.summary.uncacheable, 3, "b, d and e have no key")
  eq(all_json.summary.reasons[1].count >= 1, true, "the ranking has counts")
  for _, s in ipairs(all_json.specs) do
    eq(s.parts, nil, "--all leaves the key lines out unless --parts is given")
  end
  eq(
    json({ "explain", root, "--all", "--json", "--parts", "--env-allow", "PROJ_FLAG" }).specs[1].parts
      ~= nil,
    true,
    "--parts brings them back"
  )

  -- usage
  local none = run({ "explain", root })
  eq(none.code, 2, "no spec and no --all is a usage error")
  local missing = run({ "explain", root, "no_such_spec" })
  eq(missing.code, 2, "a spec that matches nothing is a usage error")
  has(missing.err, "no spec file matches", "and says so")
  local bare = run({ "explain", "--all", "--json" })
  ok(bare.code == 0 or bare.code == 2 or bare.code == 3, "a missing root does not raise")

  -- ---------------------------------------------------------------- unit: the explanation comes from ONE call of key
  local calls = 0
  local fake = {
    key = function(info, ctx)
      calls = calls + 1
      return ("%064x"):format(1234),
        nil,
        { "key-version 1", "file " .. info.file, "nvim 1" },
        { allow_nondeterministic = false }
    end,
    peek = function()
      return nil, "absent"
    end,
    latest = function()
      return {
        ["TESTS/x_spec.lua"] = {
          key = ("%064x"):format(1),
          run = "r1",
          ts = 5,
          parts = { "key-version 1", "file TESTS/x_spec.lua", "nvim 0" },
        },
      }
    end,
  }
  local rec = explain.explain(
    { file = "TESTS/x_spec.lua" },
    { root = root },
    { cache = fake, root = root }
  )
  eq(calls, 1, "the key function is called exactly once for an explanation")
  eq(rec.key, ("%064x"):format(1234), "the key is the one it returned")
  eq(
    rec.parts,
    { "key-version 1", "file TESTS/x_spec.lua", "nvim 1" },
    "the lines are the ones it returned"
  )
  eq(
    rec.changes,
    { { kind = "nvim", name = "nvim", old = "0", new = "1", change = "changed" } },
    "the Neovim version change"
  )

  -- the diff: files with old and new hash, version, environment, configuration, removed and added lines
  local h1, h2 = ("a"):rep(64), ("b"):rep(64)
  local d1 = explain.diff({
    "nvim 0.12.2|api1",
    "config " .. h1,
    "env A=" .. h1,
    "dep lua/x.lua=" .. h1,
    "dep lua/gone.lua=" .. h1,
  }, {
    "nvim 0.12.3|api1",
    "config " .. h2,
    "env A=" .. h1,
    "dep lua/x.lua=" .. h2,
    "dep lua/new.lua=" .. h2,
  })
  local by = {}
  for _, ch in ipairs(d1) do
    by[ch.kind .. " " .. ch.name] = ch
  end
  eq(
    by["nvim nvim"],
    { kind = "nvim", name = "nvim", old = "0.12.2|api1", new = "0.12.3|api1", change = "changed" },
    "Neovim version"
  )
  eq(by["config config"].change, "changed", "configuration")
  eq(by["dep lua/x.lua"], {
    kind = "dep",
    name = "lua/x.lua",
    old = ("a"):rep(12),
    new = ("b"):rep(12),
    change = "changed",
  }, "file hash shortened")
  eq(by["dep lua/gone.lua"].change, "removed", "a dependency that is gone")
  eq(by["dep lua/new.lua"].change, "added", "a dependency that is new")
  eq(by["env A"], nil, "an unchanged environment variable is no change")

  -- ---------------------------------------------------------------- the scanner knows the line
  local info =
    scan.analyze("local a = 1\nlocal b = 2\nlocal t = os.time()\nlocal p = vim.system({ 'x' })\n")
  eq(info.where.time, 3, "the scanner records the line of the clock")
  eq(info.where.spawn, 4, "and of the process")
  eq(info.where.random, nil, "and nothing for what is not there")
  local round = scan.valid_info(vim.json.decode(vim.json.encode(info)))
  eq(round and round.where, info.where, "the lines survive the index (validated when read back)")
  ok(
    scan.valid_info(
      vim.tbl_extend(
        "force",
        vim.deepcopy(info),
        { where = { time = "x", random = -1, spawn = 1.5 } }
      )
    ).where.time == nil,
    "a bad line number is dropped, not trusted"
  )

  vim.fn.delete(tmp, "rf")
end
