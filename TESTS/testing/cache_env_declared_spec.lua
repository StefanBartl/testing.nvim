-- TESTS/testing/cache_env_declared_spec.lua -- `-- @cache-env`: a file that reads the environment by a computed name
-- names the variables the read can reach, and their (hashed) values join the key. Every rule has its mutation here: a
-- module that really reads the variable still blocks (no directive, or a name the directive does not cover), a changed
-- value changes the key, and the scanner's precision (what is NOT a hidden input) never loosens what is.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-allow env
-- @cache-env A DECL_A
-- (the fixtures of this spec spell out every way to read the environment, among them `vim.fn['environ']`: the scanner
-- takes the text for a read of the whole environment)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")
  local scan = require("testing.affected.scan")

  local env = {}
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
        return env
      end,
      hasher = hash.new(),
      spec_roots = { "TESTS" },
      unresolved = "absent",
    }, over or {})
  end
  local function key_of(root, file, over)
    local k, why, parts = cache.key({ file = file }, ctx(root, over))
    return k, why, parts
  end

  ---A module that computes the names it reads, behind a header, and a spec that loads it.
  local function project(header, body)
    return S.project({
      ["lua/dmod.lua"] = header .. body,
      ["TESTS/d_spec.lua"] = 'local m = require("dmod")\nreturn function(H) H.ok(m, "d") end\n',
    })
  end
  local COMPUTED =
    'local NAMES = { "DECL_" .. "A", "DECL_" .. "B" }\nreturn { get = function(getenv) for _, n in ipairs(NAMES) do local v = getenv(n) if v then return v end end end }\n'
  local SPEC = "TESTS/d_spec.lua"

  -- ---------------------------------------------------------------- without the directive: no key (the baseline)
  do
    env = {}
    local root = project("", COMPUTED)
    local k, why = key_of(root, SPEC)
    ok(k == nil, "a computed name without a declaration has no key")
    ok(
      type(why) == "string" and why:find("computed name", 1, true) ~= nil,
      "and says why: " .. tostring(why)
    )
    S.remove(root)
  end

  -- ---------------------------------------------------------------- with the names: a key that follows their values
  do
    env = { DECL_A = "1", DECL_B = "1", OTHER_VAR = "x" }
    local root = project("-- @cache-env DECL_A DECL_B\n", COMPUTED)
    local k1, why = key_of(root, SPEC)
    ok(k1 ~= nil, "a declared computed read has a key: " .. tostring(why))
    eq(key_of(root, SPEC), k1, "and it is stable")
    env.DECL_A = "2"
    local k2 = key_of(root, SPEC)
    ok(k2 ~= nil and k2 ~= k1, "a changed value of a declared name changes the key")
    env.DECL_B = "2"
    ok(key_of(root, SPEC) ~= k2, "also the second name")
    local k3 = key_of(root, SPEC)
    env.OTHER_VAR = "y"
    eq(key_of(root, SPEC), k3, "a variable that is not declared does not")
    local _, _, parts = key_of(root, SPEC)
    ok(
      vim.tbl_contains(parts, "env DECL_A=" .. vim.fn.sha256("2")),
      "the key lines hold the hashed value, never the value"
    )
    ok(
      not table.concat(parts, "\n"):find("OTHER_VAR", 1, true),
      "and not the names of other variables"
    )
    -- a declaration only counts in the header
    S.remove(root)
    root = project(string.rep("-- filler\n", 40) .. "-- @cache-env DECL_A DECL_B\n", COMPUTED)
    ok(key_of(root, SPEC) == nil, "a declaration after the first 30 lines does not count")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- patterns
  do
    env = { LIB_DIR = "/a", OTHER_VAR = "x" }
    local root = project(
      "-- @cache-env *_DIR PRE_*\n",
      'return { get = function(getenv, n) return getenv(n .. "_DIR") end }\n'
    )
    local k1 = key_of(root, SPEC)
    ok(k1 ~= nil, "a suffix pattern is a declaration")
    env.LIB_DIR = "/b"
    local k2 = key_of(root, SPEC)
    ok(k2 ~= k1, "a changed value of a variable the pattern matches changes the key")
    env.NEW_DIR = "/c"
    local k3 = key_of(root, SPEC)
    ok(k3 ~= k2, "a new variable the pattern matches changes it")
    env.PRE_X = "1"
    ok(key_of(root, SPEC) ~= k3, "also a prefix pattern")
    local k4 = key_of(root, SPEC)
    env.OTHER_VAR = "z"
    eq(key_of(root, SPEC), k4, "a variable no pattern matches does not")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- the whole environment: only `*` covers it
  do
    local WHOLE = "return { all = function() return vim.fn.environ() end }\n"
    env = { DECL_A = "1" }
    local root = project("", WHOLE)
    local k, why = key_of(root, SPEC)
    ok(k == nil, "a module that reads the whole environment has no key")
    ok(
      type(why) == "string" and why:find("whole environment", 1, true) ~= nil,
      "and says so: " .. tostring(why)
    )
    S.remove(root)
    root = project("-- @cache-env DECL_A DECL_B\n", WHOLE)
    ok(key_of(root, SPEC) == nil, "names do not cover a read of the whole environment")
    S.remove(root)
    root = project("-- @cache-env *\n", WHOLE)
    local k1 = key_of(root, SPEC)
    ok(k1 ~= nil, "`*` declares it")
    env.ANYTHING = "1"
    local k2 = key_of(root, SPEC)
    ok(k2 ~= k1, "and a new variable changes the key")
    env.ANYTHING = "2"
    ok(key_of(root, SPEC) ~= k2, "so does a changed value of any variable")
    local k3 = key_of(root, SPEC)
    env["=C:"] = "C:\\one"
    local k4 = key_of(root, SPEC)
    env["=C:"] = "C:\\two"
    eq(
      key_of(root, SPEC),
      k4,
      "the hidden per-drive directory of Windows (`=C:`) moves with every chdir: not in the key"
    )
    eq(k4, k3, "and never was")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- `-- @cache-allow env`: the author's statement
  do
    env = { DECL_A = "1" }
    local root = project("-- @cache-allow env\n", COMPUTED)
    local k1 = key_of(root, SPEC)
    ok(k1 ~= nil, "a vouched computed read has a key")
    env.DECL_A = "2"
    eq(
      key_of(root, SPEC),
      k1,
      "which does not follow the variables (that is what the author vouches for)"
    )
    S.remove(root)
    root =
      project("-- @cache-allow env\n", "return { all = function() return vim.fn.environ() end }\n")
    ok(key_of(root, SPEC) ~= nil, "also for a read of the whole environment")
    S.remove(root)
    root = project(
      "-- @cache-allow env\n-- @cache-env DECL_A\n",
      "return { get = function(getenv, n) return getenv(n) end }\n"
    )
    local k2 = key_of(root, SPEC)
    env.DECL_A = "3"
    ok(key_of(root, SPEC) ~= k2, "a name declared next to it still joins the key")
    S.remove(root)
    root = project("-- @cache-allow time\n", COMPUTED)
    ok(key_of(root, SPEC) == nil, "another vouching does not cover the environment")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- vouching is visible (explain, audit)
  do
    env = { DECL_A = "1" }
    local root = project(
      "-- @cache-allow time\n-- @cache-env *\n",
      "return { get = function(getenv, n) return getenv(n) end }\n"
    )
    local c = ctx(root)
    local k, _, _, detail = cache.key({ file = SPEC }, c)
    ok(k ~= nil, "a vouched file has a key")
    local seen = {}
    for _, v in ipairs(detail.vouched or {}) do
      seen[#seen + 1] = v.directive .. " (" .. v.file .. ")"
    end
    eq(
      seen,
      { "@cache-allow time (lua/dmod.lua)", "@cache-env * (lua/dmod.lua)" },
      "the detail names every directive and the file that carries it"
    )
    local rec = require("testing.cache.explain").explain(
      { file = SPEC },
      c,
      { cache = cache, root = root, cache_dir = c.cache_dir }
    )
    eq(#(rec.vouched or {}), 2, "the explain record carries them")
    local text = table.concat(
      require("testing.explain").render(rec, { selected = true, text = "x" }, {}),
      "\n"
    )
    ok(
      text:find("vouched: @cache-env * (lua/dmod.lua)", 1, true) ~= nil,
      "and `testing explain` prints a vouched line: " .. text
    )
    local lines = require("testing.run.cached").audit_lines({
      findings = {
        {
          code = "cache.stale_pass",
          file = SPEC,
          key = "k",
          message = "m",
          vouched = detail.vouched,
        },
      },
    })
    ok(
      table.concat(lines, "\n"):find("vouched: @cache-env * (lua/dmod.lua)", 1, true) ~= nil,
      "the audit finding prints it too"
    )
    S.remove(root)
    root = project("", "return {}\n")
    local _, _, _, d2 = cache.key({ file = SPEC }, ctx(root))
    eq(d2.vouched, nil, "a file without directives vouches for nothing")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- the spec itself
  do
    env = { DECL_A = "1" }
    local root = S.project({
      ["TESTS/own_spec.lua"] = 'return function(H) H.ok(os.getenv("DECL_A") == nil, "own") end\n',
      ["TESTS/own2_spec.lua"] = '-- @cache-env DECL_A\nreturn function(H) H.ok(os.getenv("DECL_A") == nil, "own") end\n',
      ["TESTS/own3_spec.lua"] = '-- @cache-env DECL_B\nreturn function(H) H.ok(os.getenv("DECL_A") == nil, "own") end\n',
    })
    ok(
      key_of(root, "TESTS/own_spec.lua") == nil,
      "a spec that reads a name nobody lists has no key"
    )
    local k1 = key_of(root, "TESTS/own2_spec.lua")
    ok(k1 ~= nil, "a spec that declares the name has a key")
    env.DECL_A = "2"
    ok(key_of(root, "TESTS/own2_spec.lua") ~= k1, "which follows the value")
    ok(
      key_of(root, "TESTS/own3_spec.lua") == nil,
      "a declaration of ANOTHER name does not cover the read"
    )
    S.remove(root)
  end

  -- ---------------------------------------------------------------- `-- @cache-allow outside`
  do
    -- `".."` is a place outside the project that exists, so a file that names it and reads files has no key
    local reads = 'local f = io.open(vim.fs.joinpath(root, ".."), "rb")\n'
    local root = S.project({
      ["lua/omod.lua"] = "local root = ...\n" .. reads .. "return {}\n",
      ["lua/omod2.lua"] = "-- @cache-allow outside\nlocal root = ...\n" .. reads .. "return {}\n",
      ["TESTS/o1_spec.lua"] = 'local m = require("omod")\nreturn function(H) H.ok(m, "o") end\n',
      ["TESTS/o2_spec.lua"] = 'local m = require("omod2")\nreturn function(H) H.ok(m, "o") end\n',
    })
    ok(
      key_of(root, "TESTS/o1_spec.lua") == nil,
      "a module that joins `..` and reads files has no key"
    )
    ok(key_of(root, "TESTS/o2_spec.lua") ~= nil, "unless the author vouches for it")
    S.remove(root)
  end

  -- ---------------------------------------------------------------- the scanner: what is, and what is no hidden input
  ---@param text string
  ---@return Testing.Scan.Info
  local function info(text)
    return scan.analyze(text)
  end
  local function flags(text)
    local m = info(text).markers
    return { computed = m.env_computed, whole = m.env_whole, dynamic = m.env_dynamic }
  end
  eq(
    flags("local e = vim.fn.environ()"),
    { computed = false, whole = true, dynamic = true },
    "vim.fn.environ()"
  )
  eq(flags("local e = vim.uv.os_environ()").whole, true, "os_environ()")
  eq(
    flags("local function environ() return {} end; return environ()").whole,
    true,
    "a bare environ() call is read as the real one"
  )
  eq(flags("return vim.fn['environ']()").whole, true, "vim.fn['environ']")
  eq(flags('return vim.fn.call("environ", {})').whole, true, 'call("environ")')
  eq(flags("local env = vim.env\nreturn env").whole, true, "vim.env handed on")
  eq(flags("if vim and vim.env then return 1 end").whole, false, "`vim.env then` only tests it")
  eq(flags("return vim.env and vim.env.A").whole, false, "`vim.env and` too")
  eq(flags("return vim.env == nil").whole, false, "and a comparison")
  eq(flags("for k in pairs(vim.env) do end").whole, true, "pairs(vim.env) reads it all")
  eq(flags("local e = vim.env or {}").whole, true, "`vim.env or {}` is a use of the table")
  eq(
    flags("local ctx = { environ = function() return {} end }").whole,
    false,
    "a table field named environ is an injected fake, no read"
  )
  eq(flags("return ctx.environ()").whole, false, "ctx.environ() is a member of a context, no read")
  eq(
    flags("return (ctx.environ or vim.fn.environ)()").whole,
    true,
    "but its default is the real one"
  )
  eq(
    flags("local function f(getenv) return getenv(name) end").computed,
    true,
    "getenv(name) is a computed name"
  )
  eq(flags('return os.getenv("A")').dynamic, false, "a literal name is not")
  -- a getenv that is not called with a parenthesis right away is still a read of the environment
  local function named(text)
    return info(text).markers.env
  end
  eq(
    named('return pcall(os.getenv, "HOME")'),
    { "HOME" },
    "pcall(os.getenv, name) names the variable"
  )
  eq(flags('return pcall(os.getenv, "HOME")').dynamic, false, "and it is not dynamic then")
  eq(named('return os.getenv"HOME"'), { "HOME" }, 'os.getenv"NAME" names the variable')
  eq(flags('return os.getenv"HOME"').dynamic, false, "and is no computed read")
  eq(
    flags('local g = os.getenv\nreturn g("HOME")').computed,
    true,
    "an alias of os.getenv is a read under a name nobody can see: computed"
  )
  eq(
    flags("return pcall(os.getenv, name)").computed,
    true,
    "pcall(os.getenv, name) with a computed name is computed"
  )
  eq(
    flags("local get = seam.getenv or vim.uv.os_getenv\nreturn get(1)").computed,
    true,
    "a bare vim.uv.os_getenv is a read"
  )
  eq(flags("return seam.getenv(n)").computed, true, "(getenv(name) as before)")
  eq(flags("local t = { getenv = seam.getenv }").computed, false, "an injected member is no read")
  -- `os = "x"` is a field name, no alias of the `os` table; the clock stays a hidden input where it is read
  eq(info('local t = { a = 1, os = "x" }').markers.time, false, "a field named os is no alias")
  eq(info("local t = f(1, os)").markers.time, true, "os handed on is an alias")
  eq(info("local o = os").markers.time, true, "local o = os is an alias")
  -- `".."` compared with something is the test of a validator, any other use names the parent directory
  local function outside(text)
    return info(text).markers.outside
  end
  eq(outside('if seg == ".." then return end'), false, 'seg == ".."')
  eq(outside('if ".." ~= seg then return end'), false, '".." ~= seg')
  eq(outside('return ref:find("..", 1, true)'), false, "a plain find of `..`")
  eq(outside('return rel:sub(1, 3) == "../"'), false, 'rel:sub(1, 3) == "../"')
  eq(
    outside('return lib.starts_with(rest, "~/")'),
    false,
    "starts_with(rest, ...) asks for a prefix"
  )
  eq(outside('return vim.endswith(name, "..")'), false, "so does endswith")
  eq(outside('return "~/" .. rest'), true, "but a path built from it stays one")
  eq(outside('return vim.fs.joinpath(root, "..")'), true, "joined as a path it names the parent")
  eq(outside('return vim.fn.readfile("../x")'), true, "../x names a file outside")
  eq(outside('vim.cmd("edit ..")'), true, "`edit ..` in a command string names the parent")
  eq(
    outside('return "a .. b"'),
    false,
    "a Lua concatenation operator inside a command string is no path"
  )
  eq(outside('return s:gsub("\\\\", "/")'), false, 'a single backslash ("\\\\") is no UNC path')
  eq(
    outside('return "\\\\\\\\server\\\\share"'),
    true,
    "a UNC path written with doubled backslashes"
  )
  eq(outside('return "C:/Windows"'), true, "a drive path")

  -- ---------------------------------------------------------------- the persisted form of an analysis
  do
    local i = info("-- @cache-env A_* B\nreturn vim.fn.environ()\n")
    eq(i.directives.env, { "A_*", "B" }, "the declaration is read")
    local back = scan.valid_info(vim.json.decode(vim.json.encode(i)))
    ok(back ~= nil, "an analysis with a declaration survives the index")
    eq(back.directives.env, { "A_*", "B" }, "with its declaration")
    eq(back.markers.env_whole, true, "and its flags")
    -- an analysis stored before the split of the flag is read as the worse of the two
    local old = vim.json.decode(vim.json.encode(info("return 1\n")))
    old.markers.env_whole, old.markers.env_computed, old.directives.env = nil, nil, nil
    old.markers.env_dynamic = true
    local conv = scan.valid_info(old)
    ok(
      conv ~= nil and conv.markers.env_whole and conv.markers.env_computed,
      "an old analysis stays blocked"
    )
    -- a hostile declaration is bounded
    local many = {}
    for n = 1, 200 do
      many[n] = "V" .. n
    end
    eq(
      #info("-- @cache-env " .. table.concat(many, " ") .. "\n").directives.env,
      scan.MAX_ENV_DECLARED,
      "bounded"
    )
    eq(info("-- @cache-env a;b $(x) A*B\n").directives.env, { "A*B" }, "only names and patterns")
  end

  -- ---------------------------------------------------------------- the runner's own files declare what they read
  do
    local function head_of(mod)
      local path = vim.api.nvim_get_runtime_file("lua/" .. mod:gsub("%.", "/") .. ".lua", false)[1]
      path = path
        or vim.api.nvim_get_runtime_file("lua/" .. mod:gsub("%.", "/") .. "/init.lua", false)[1]
      return info(table.concat(vim.fn.readfile(path), "\n"))
    end
    local ci = head_of("testing.affected")
    eq(
      vim.list_extend({}, ci.directives.env),
      require("testing.affected").CI_ENV,
      "affected: the declaration lists every name of CI_ENV, in order"
    )
    eq(head_of("testing.deps").directives.env, { "*_DIR" }, "deps: the `<NAME>_DIR` overrides")
    -- and the names are the ones the code computes
    ok(
      vim.deep_equal(require("testing.deps").env_name("lib.nvim"), "LIB_NVIM_DIR"),
      "deps: env_name still ends in _DIR (the pattern covers it)"
    )
  end
end
