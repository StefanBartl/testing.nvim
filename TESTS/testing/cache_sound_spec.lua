-- TESTS/testing/cache_sound_spec.lua -- the cache never serves a stale pass: for every hidden input that a
-- review or a fleet measurement found, the key either changes when that input changes or does not exist at
-- all (a cached green that a full run would turn red is the one failure the cache must not have).
--
-- Each scenario builds a project in a temporary directory, takes the key of one spec, changes the hidden
-- input, and takes the key again. The key must be nil (the spec cannot be cached) or different.

---@diagnostic disable: need-check-nil, missing-fields
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")
  local scan = require("testing.affected.scan")

  local function ctx(root, over)
    return vim.tbl_extend("force", {
      root = root,
      cache_dir = vim.fs.normalize(vim.fn.tempname()),
      dep_roots = {},
      runner_version = "runner-1",
      nvim = "0.12.0-test",
      config_digest = "cfg-1",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
      spec_roots = { "TESTS" },
      unresolved = "absent",
    }, over or {})
  end

  ---@param root string
  ---@param file string
  ---@param over? table
  ---@return string|nil key
  ---@return string|nil why
  local function key_of(root, file, over)
    local k, why = cache.key({ file = file }, ctx(root, over))
    return k, why
  end

  ---The key must change, or vanish, when `mutate` runs.
  ---@param label string
  ---@param files table<string, string>
  ---@param spec string
  ---@param mutate fun(root: string)
  ---@param over? table
  ---@return string|nil key_before nil when the spec has no key to begin with
  local function sound(label, files, spec, mutate, over)
    local root = S.project(files)
    local before, why = key_of(root, spec, over)
    mutate(root)
    local after = key_of(root, spec, over)
    ok(
      before == nil or after == nil or before ~= after,
      label
        .. ": the key must change or vanish (before: "
        .. tostring(before and "key" or why)
        .. ")"
    )
    S.remove(root)
    return before
  end

  -- ---------------------------------------------------------------- a dependency reads a file (R1-1)
  sound(
    "dependency reads a named file",
    {
      ["lua/mod.lua"] = 'local M = {}\nfunction M.read(p) local f = io.open(p, "rb") local s = f:read("*a") f:close() return s end\nreturn M\n',
      ["fix/a.txt"] = "one\n",
      ["TESTS/r1_spec.lua"] = 'local m = require("mod")\nreturn function(H) H.eq(m.read("fix/a.txt"), "one\\n", "r1") end\n',
    },
    "TESTS/r1_spec.lua",
    function(root)
      S.edit(root, "fix/a.txt", "two\n")
    end
  )

  -- every form of a hidden input is seen by the scanner (a spec that has one has no key). A MODULE of the
  -- project that reads the clock or starts a process does not block its specs: the effects ledger of the
  -- run refuses a file that really started a process or a connection, and a clock in a module is far more
  -- often a timer than the value a spec asserts on (docs/CACHE.md names this limit).
  for _, c in ipairs({
    { "clock", "local t = os.time()" },
    { "random", "local t = math.random(2)" },
    { "process", 'local t = vim.fn.system("echo 1")' },
    { "network", "local t = vim.uv.new_tcp()" },
    { "hrtime", "local t = vim.uv.hrtime()" },
    { "uv.now (loop alias)", "local t = vim.loop.now()" },
    { "uv.random", "local t = vim.uv.random(4)" },
  }) do
    local root = S.project({
      ["TESTS/d1_spec.lua"] = "return function(H) " .. c[2] .. " H.ok(t, 'd') end\n",
    })
    local k, why = key_of(root, "TESTS/d1_spec.lua")
    ok(k == nil, "a spec that uses the " .. c[1] .. " has no key (got " .. tostring(why) .. ")")
    S.remove(root)
  end
  -- ... and a spec that only touches the clock through an alias
  for _, code in ipairs({
    "local o = os; local t = o.time()",
    "local t = os['time']()",
    "local t = vim.fn['localtime']()",
  }) do
    local root = S.project({
      ["TESTS/alias_spec.lua"] = "return function(H) " .. code .. " H.ok(t, 'x') end\n",
    })
    ok(key_of(root, "TESTS/alias_spec.lua") == nil, "an aliased clock call has no key: " .. code)
    S.remove(root)
  end

  -- the author can vouch for a clock that does not decide anything; a dependency checkout is not judged
  do
    local root = S.project({
      ["lua/vmod.lua"] = "-- @cache-allow time\nlocal M = {}\nfunction M.stamp() return os.time() end\nreturn M\n",
      ["TESTS/v1_spec.lua"] = 'local m = require("vmod")\nreturn function(H) H.ok(m, "v") end\n',
      [".deps/ext/lua/extmod.lua"] = "return { stamp = os.time, run = vim.system }\n",
      ["TESTS/v2_spec.lua"] = 'package.path = "x;" .. package.path\nlocal m = require("extmod")\nreturn function(H) H.ok(m, "v") end\n',
    })
    ok(key_of(root, "TESTS/v1_spec.lua") ~= nil, "a vouched clock does not block the key")
    ok(
      key_of(root, "TESTS/v2_spec.lua", { dep_roots = { root .. "/.deps/ext" } }) ~= nil,
      "a dependency checkout below .deps/ is not judged for its clock or processes"
    )
    S.remove(root)
  end

  -- a module of the project reads a variable by its literal name: the value is part of the key
  do
    local env = { MODENV = "a" }
    local k = sound(
      "a module reads a literal environment variable",
      {
        ["lua/lmod.lua"] = 'return { get = function() return os.getenv("MODENV") end }\n',
        ["TESTS/l1_spec.lua"] = 'local m = require("lmod")\nreturn function(H) H.ok(m, "l") end\n',
      },
      "TESTS/l1_spec.lua",
      function()
        env.MODENV = "b"
      end,
      {
        environ = function()
          return env
        end,
      }
    )
    ok(k ~= nil, "such a spec still has a key")
  end

  -- a file that runs in a CHILD editor sees an allowlisted environment: all of it is in the key, so a variable
  -- that is read by a computed name (or not listed at all) is no hidden input there
  do
    local root = S.project({
      ["lua/cmod.lua"] = 'local NAME = "SOME_" .. "VAR"\nreturn { get = function() return vim.env[NAME] end }\n',
      ["TESTS/c1_spec.lua"] = 'local m = require("cmod")\nreturn function(H) H.ok(m, "c") end\n',
      ["TESTS/c2_spec.lua"] = 'return function(H) H.ok(os.getenv("UNLISTED") == nil, "c") end\n',
    })
    for _, spec in ipairs({ "TESTS/c1_spec.lua", "TESTS/c2_spec.lua" }) do
      ok(
        cache.key({ file = spec }, ctx(root)) == nil,
        spec .. ": in this editor an unlisted read has no key"
      )
      local k1 = cache.key({ file = spec, child_env = "env-a" }, ctx(root))
      ok(k1 ~= nil, spec .. ": in a child editor the allowlisted environment is the key's")
      ok(
        k1 ~= cache.key({ file = spec, child_env = "env-b" }, ctx(root)),
        spec .. ": and another environment is another key"
      )
    end
    S.remove(root)
  end

  -- a dependency that lists the environment by a computed name: no key
  do
    local root = S.project({
      ["lua/emod.lua"] = 'return { get = function(n) return os.getenv("X_" .. n) end }\n',
      ["TESTS/e1_spec.lua"] = 'local m = require("emod")\nreturn function(H) H.ok(m, "e") end\n',
    })
    ok(key_of(root, "TESTS/e1_spec.lua") == nil, "a dependency with a computed environment name")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- reads outside the project (R1-2)
  -- A literal that names a place outside the project counts when it names something that EXISTS there (a string
  -- like "../x" is often the test of a path function); one that names nothing yet is in the key as absent.
  do
    local parent = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(parent, "p")
    S.write(parent .. "/outside.txt", "A\n")
    local root = parent .. "/proj"
    S.write(root .. "/.testing.lua", "return { roots = { 'TESTS' } }\n")
    S.write(
      root .. "/TESTS/out_spec.lua",
      'return function(H) local f = io.open(H.root .. "/../outside.txt", "rb") H.ok(f, "o") end\n'
    )
    S.write(
      root .. "/TESTS/abs_spec.lua",
      'return function(H) local f = io.open("'
        .. parent
        .. '/outside.txt", "rb") H.ok(f, "o") end\n'
    )
    S.write(
      root .. "/TESTS/rel_spec.lua",
      'return function(H) local f = io.open("../outside.txt", "rb") H.ok(f, "o") end\n'
    )
    S.write(
      root .. "/TESTS/home_spec.lua",
      'return function(H) local f = io.open("~/does-not-exist-anywhere.txt", "rb") H.ok(f, "o") end\n'
    )
    S.write(
      root .. "/TESTS/path_fn_spec.lua",
      'return function(H) H.eq(vim.fs.normalize("../nothing/x.txt"), "../nothing/x.txt", "p") local f = io.open("fixtures/a.txt") H.ok(not f, "p") end\n'
    )
    for _, spec in ipairs({ "out", "abs", "rel" }) do
      local k, why = key_of(root, "TESTS/" .. spec .. "_spec.lua")
      ok(
        k == nil and tostring(why):find("outside the project", 1, true) ~= nil,
        spec
          .. ": a spec that reads a file outside the project has no key (got "
          .. tostring(why)
          .. ")"
      )
    end
    -- a literal that names nothing is no read of anything outside: it has a key, and the key knows it is absent
    for _, spec in ipairs({ "home", "path_fn" }) do
      local k, why = key_of(root, "TESTS/" .. spec .. "_spec.lua")
      ok(
        k ~= nil,
        spec
          .. ": a literal that names nothing outside is no hidden input (got "
          .. tostring(why)
          .. ")"
      )
    end
    local before = key_of(root, "TESTS/path_fn_spec.lua")
    S.write(parent .. "/nothing/x.txt", "now it exists\n")
    local after, why_after = key_of(root, "TESTS/path_fn_spec.lua")
    ok(
      after == nil or after ~= before,
      "when the place appears, the key changes or vanishes (" .. tostring(why_after) .. ")"
    )
    S.remove(parent)
  end

  -- ---------------------------------------------------------------- directory scans take the specs in (R1-3)
  sound(
    "a lint spec that lists the spec directory",
    {
      ["TESTS/lint_spec.lua"] = 'return function(H)\n  for _, f in ipairs(vim.fn.glob(H.root .. "/TESTS/*_spec.lua", false, true)) do\n    local s = table.concat(vim.fn.readfile(f), "\\n")\n    H.ok(not s:find("FIXME"), f)\n  end\nend\n',
      ["TESTS/other_spec.lua"] = "return function(H) H.ok(true, 'other') end\n",
    },
    "TESTS/lint_spec.lua",
    function(root)
      S.edit(root, "TESTS/other_spec.lua", "-- FIXME\nreturn function(H) H.ok(true, 'other') end\n")
    end
  )

  -- ---------------------------------------------------------------- stale passes of the fleet measurement
  -- the spec sets package.path to a directory outside its spec root and requires a module from there
  sound(
    "package.path pointing at a vendor directory",
    {
      ["vendor/vend05.lua"] = 'return { v = "ok" }\n',
      ["TESTS/p05_spec.lua"] = 'return function(H)\n  package.path = H.root .. "/vendor/?.lua;" .. package.path\n  H.eq(require("vend05").v, "ok", "p05")\nend\n',
    },
    "TESTS/p05_spec.lua",
    function(root)
      S.edit(root, "vendor/vend05.lua", 'return { v = "changed" }\n')
    end
  )

  -- a module that reads a data file that lives next to it
  sound(
    "a module reads a data file next to it",
    {
      ["lua/probe/p06.lua"] = 'local d = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")\nlocal f = io.open(d .. "/p06" .. ".json", "rb")\nreturn { s = f and f:read("*a") }\n',
      ["lua/probe/p06.json"] = '{"v":1}',
      ["TESTS/p06_spec.lua"] = 'return function(H) H.ok(require("probe.p06").s, "p06") end\n',
    },
    "TESTS/p06_spec.lua",
    function(root)
      S.edit(root, "lua/probe/p06.json", '{"v":2}')
    end
  )

  -- a runtime file loaded by an ex command with a literal path
  sound(
    "`:runtime plugin/x.lua`",
    {
      ["plugin/p01b.lua"] = "vim.g.p01b = 1\n",
      ["TESTS/p03_spec.lua"] = 'return function(H)\n  vim.opt.rtp:append(H.root)\n  vim.cmd("runtime plugin/p01b.lua")\n  H.ok(vim.g.p01b, "p03")\nend\n',
    },
    "TESTS/p03_spec.lua",
    function(root)
      S.edit(root, "plugin/p01b.lua", "vim.g.p01b = nil\n")
    end
  )
  sound(
    "`:source` with a glob",
    {
      ["plugin/p21.lua"] = "vim.g.p21 = 1\n",
      ["TESTS/p21_spec.lua"] = 'return function(H)\n  vim.cmd("runtime! plugin/p2*.lua")\n  H.ok(vim.g.p21, "p21")\nend\n',
    },
    "TESTS/p21_spec.lua",
    function(root)
      S.edit(root, "plugin/p21.lua", "vim.g.p21 = nil\n")
    end
  )

  -- a literal that names a sibling outside the project
  do
    local parent = vim.fs.normalize(vim.fn.tempname())
    S.write(parent .. "/probe_sibling/s25.txt", "x\n")
    S.write(parent .. "/proj/.testing.lua", "return { roots = { 'TESTS' } }\n")
    S.write(
      parent .. "/proj/TESTS/s25_spec.lua",
      "return function(H) H.ok(vim.fn.readfile('../probe_sibling/s25.txt')[1], 's25') end\n"
    )
    ok(
      key_of(parent .. "/proj", "TESTS/s25_spec.lua") == nil,
      "a spec that reads a sibling directory of the project has no key"
    )
    S.remove(parent)
  end

  -- ---------------------------------------------------------------- the stat pre-check sees a reset mtime
  do
    local root = S.project({ ["lua/t.lua"] = "return 1\n" })
    local abs = root .. "/lua/t.lua"
    local before = vim.uv.fs_stat(abs)
    local h = hash.new()
    local s1 = h:file(abs)
    -- same size, same mtime, other content (`touch -r`)
    local f = assert(io.open(abs, "wb"))
    f:write("return 2\n")
    f:close()
    vim.uv.fs_utime(abs, before.mtime.sec, before.mtime.sec)
    local s2 = h:file(abs)
    local after = vim.uv.fs_stat(abs)
    local c0, c1 = before.ctime, after.ctime
    if c0.sec ~= c1.sec or c0.nsec ~= c1.nsec then
      ok(s1 ~= s2, "a content change with a restored size and mtime is seen (ctime)")
    end
    S.remove(root)
  end

  -- ---------------------------------------------------------------- the scanner
  do
    local info = scan.analyze('return function() vim.cmd("runtime plugin/a.lua") end\n')
    ok(info.markers.dynload == true, "`:runtime` in a command string is a dynamic load")
    ok(info.markers.io == true, "`:runtime` in a command string is a file read")
    ok(
      vim.tbl_contains(info.paths, "plugin/a.lua"),
      "the path of a command string is a path literal"
    )
    info = scan.analyze('local x = vim.fs.dir("lua")\n')
    ok(info.markers.dirscan == true, "a directory listing is marked")
    info = scan.analyze('local p = "../x/y.txt"\n')
    ok(info.markers.outside == true, "a `..` literal is marked as outside")
    info = scan.analyze('local p = "C:\\\\Users\\\\x"\n')
    ok(info.markers.outside == true, "a drive path is marked as outside")
    info = scan.analyze('local p = "docs/x.md"\n')
    ok(info.markers.outside == false and info.markers.dynload == false, "a plain path is neither")
    ok(type(scan.VERSION) == "number", "the scanner has a version (the index depends on it)")
  end

  -- ---------------------------------------------------------------- the persistent index follows the scanner
  do
    local root = S.project({ ["lua/t.lua"] = "return 1\n" })
    local idx = root .. "/index.json"
    local h = hash.new(idx)
    local _, info = h:analyzed(root .. "/lua/t.lua")
    ok(type(info) == "table", "analyzed")
    ok(h:flush(), "flushed")
    -- an index written by an older scanner keeps its hashes but not its analysis
    local raw = S.read(idx)
    local decoded = vim.json.decode(raw)
    decoded.scan = (scan.VERSION or 1) - 1
    S.write(idx, vim.json.encode(decoded), false)
    local h2 = hash.new(idx)
    h2:load()
    local e = h2.entries[vim.fs.normalize(root .. "/lua/t.lua")]
    ok(e ~= nil and e.x == nil, "the analysis of an older scanner is dropped")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- an input edited while the run goes
  do
    local cached = require("testing.run.cached")
    local result = require("testing.core.result")
    local root = S.project()
    local cdir = vim.fs.normalize(vim.fn.tempname())
    local file = "TESTS/proj/a_spec.lua"
    local c = ctx(root, { cache_dir = cdir, hasher = false })
    local info = { file = file }
    local key = assert(cache.key(info, c))
    local res = require("testing.run.inproc").begin_result(root, { argv = {}, jobs = 1 })
    res.cases = { S.case(file, "a") }
    result.finalize(res)
    local prep = {
      mode = "use",
      files = { { rel = file } },
      run_files = { { rel = file } },
      hits = {},
      keys = { [file] = key },
      infos = { [file] = info },
      uncacheable = {},
      stored = 0,
      not_stored = {},
      ctx = c,
    }
    -- the dependency is edited after the key was computed and before the result is stored
    S.edit(root, "lua/proj/b.lua", "return { v = 99 }\n")
    cached.finish(prep, { result = res, stopped = false }, { root = root, cache_dir = cdir })
    H.eq(prep.stored, 0, "a result is not stored under the key of the old content")
    ok(
      prep.not_stored["an input changed while the run was going"] == 1,
      "the reason is named: " .. vim.inspect(prep.not_stored)
    )
    -- and without an edit the same result is stored
    local c2 = ctx(root, { cache_dir = cdir, hasher = false })
    local key2 = assert(cache.key(info, c2))
    local res2 = require("testing.run.inproc").begin_result(root, { argv = {}, jobs = 1 })
    res2.cases = { S.case(file, "a") }
    result.finalize(res2)
    local prep2 = vim.tbl_extend("force", prep, {
      keys = { [file] = key2 },
      ctx = c2,
      stored = 0,
      not_stored = {},
    })
    cached.finish(prep2, { result = res2, stopped = false }, { root = root, cache_dir = cdir })
    H.eq(prep2.stored, 1, "an unchanged input stores the result: " .. vim.inspect(prep2.not_stored))
    cache.reset()
    S.remove(root)
    S.remove(cdir)
  end
end
