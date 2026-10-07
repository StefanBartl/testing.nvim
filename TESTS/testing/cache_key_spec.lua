-- TESTS/testing/cache_key_spec.lua -- the cache key (`testing.cache.key`): every input of the key changes
-- it, an unrelated edit does not, and a spec whose inputs cannot be known has no key at all
-- (never trust a cached pass when the inputs are incomplete).

-- @cache-allow env
-- @cache-env TN_CI_PROBE
-- (hands the real environment to the key code to look up one variable it sets itself: the variable joins the key)
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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")

  local root = S.project()
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local env = { PROJ_TOKEN = "t1", PROJ_A = "1" }

  ---A context of one run (a new one per call: the directory memo belongs to the run).
  local function ctx(over)
    return vim.tbl_extend("force", {
      root = root,
      cache_dir = cdir,
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
    }, over or {})
  end
  local function key_of(file, over, info)
    return cache.key(vim.tbl_extend("force", { file = file }, info or {}), ctx(over))
  end
  local A = "TESTS/proj/a_spec.lua"

  -- ---------------------------------------------------------------- stable, hex, deterministic
  local k1, why, parts = key_of(A)
  ok(k1 ~= nil, "a pure spec has a key: " .. tostring(why))
  k1, parts = assert(k1), assert(parts)
  eq(#k1, 64, "a sha256 hex string")
  ok(k1:match("^%x+$") ~= nil, "hex")
  eq(key_of(A), k1, "the same inputs give the same key")
  ok(type(parts) == "table" and #parts > 5, "the parts of the key are returned for diagnostics")
  local joined = table.concat(parts, "\n")
  has(joined, "runner runner-1", "runner version is a part")
  has(joined, "nvim 0.12.0-test", "nvim version is a part")
  has(joined, "dep lua/proj/b.lua=", "the transitive dependency is a part")

  -- the real Neovim part of the key (no `nvim` override) names the API level, never the string of a nil
  do
    local _, _, real_parts = key_of(A, { nvim = false })
    local nvim_line
    for _, l in ipairs(real_parts or {}) do
      nvim_line = nvim_line or l:match("^nvim (.*)$")
    end
    ok(nvim_line ~= nil, "a real nvim line is part of the key")
    local level = vim.fn.api_info().version.api_level
    ok(
      type(nvim_line) == "string" and not nvim_line:find("nil", 1, true),
      "the nvim line holds no nil: " .. tostring(nvim_line)
    )
    has(nvim_line, "|api" .. tostring(level) .. "|", "the nvim line names the API level")
  end

  -- ---------------------------------------------------------------- each input changes the key
  local function differs(label, k)
    ok(k ~= nil and k ~= k1, label .. ": the key changes")
  end
  differs("runner version", (key_of(A, { runner_version = "runner-2" })))
  differs("neovim version", (key_of(A, { nvim = "0.13.0" })))
  differs("config digest", (key_of(A, { config_digest = "cfg-2" })))
  differs("config table", (key_of(A, { config_digest = false, config = { a = 1 } })))
  differs("dialect (ctx)", (key_of(A, { dialect = "b" })))
  differs("dialect (file_info)", (key_of(A, nil, { dialect = "busted" })))
  differs("another file with the same content", (key_of("TESTS/proj/pure_spec.lua")))
  eq(
    key_of(A, { config = { a = 1 }, config_digest = false }),
    key_of(A, { config = { a = 1 }, config_digest = false }),
    "an equal config table gives an equal key"
  )
  ok(
    key_of(A, { config = { a = 1 }, config_digest = false })
      ~= key_of(A, { config = { a = 2 }, config_digest = false }),
    "a changed config table changes the key"
  )

  -- the seed only counts when the run is shuffled
  eq(key_of(A, { seed = 1 }), k1, "seed without shuffle: same key")
  local s1 = key_of(A, { seed = 1, shuffled = true })
  local s2 = key_of(A, { seed = 2, shuffled = true })
  ok(s1 ~= k1 and s1 ~= s2, "seed with shuffle: part of the key")

  -- spec content
  S.edit(root, A, 'local a = require("proj.a")\nreturn function(H) H.eq(a.v, 1, "a2") end\n')
  local k_spec = key_of(A)
  ok(k_spec ~= k1, "the spec content changes the key")

  -- a transitive dependency (a -> b)
  S.edit(root, "lua/proj/b.lua", "return { v = 2 }\n")
  local k_dep = key_of(A)
  ok(k_dep ~= k_spec, "a transitive dependency changes the key")
  -- an unrelated module does not
  S.edit(root, "lua/proj/c.lua", "return { c = 2 }\n")
  eq(key_of(A), k_dep, "an unrelated module does not change the key")
  -- a same-size edit with a moved mtime is still seen (the stat differs, the content is hashed)
  S.edit(root, "lua/proj/b.lua", "return { v = 3 }\n")
  ok(key_of(A) ~= k_dep, "a same-size edit is seen")

  -- .testing.lua
  local k_before_cfg = key_of(A)
  S.edit(root, ".testing.lua", "return { roots = { 'TESTS' }, jobs = 4 }\n")
  ok(key_of(A) ~= k_before_cfg, "the content of .testing.lua changes the key")

  -- ---------------------------------------------------------------- environment
  local E = "TESTS/proj/env_spec.lua"
  local why_env = select(2, key_of(E))
  has(
    why_env,
    "PROJ_TOKEN",
    "an environment variable that is not in the key makes the file uncacheable"
  )
  local ke1 = key_of(E, { env_names = { "PROJ_TOKEN" } })
  ok(ke1 ~= nil, "a listed variable is part of the key")
  env.PROJ_TOKEN = "t2"
  ok(key_of(E, { env_names = { "PROJ_TOKEN" } }) ~= ke1, "its value changes the key")
  env.PROJ_TOKEN = nil
  ok(key_of(E, { env_names = { "PROJ_TOKEN" } }) ~= ke1, "unset differs from set")
  env.PROJ_TOKEN = "t1"
  eq(key_of(E, { env_names = { "PROJ_TOKEN" } }), ke1, "back to the same value: the same key")
  -- a prefix entry expands over the names that are set, and a new variable changes the key
  local kp1 = key_of(A, { env_names = { "PROJ_*" } })
  env.PROJ_NEW = "n"
  ok(
    key_of(A, { env_names = { "PROJ_*" } }) ~= kp1,
    "a new variable below a listed prefix changes the key"
  )
  env.PROJ_NEW = nil
  -- a value is hashed, never stored in the key text
  local _, _, p_env = key_of(A, { env_names = { "PROJ_TOKEN" } })
  local text = table.concat(assert(p_env), "\n")
  ok(not text:find("PROJ_TOKEN=t1", 1, true), "the value itself is not in the key text")
  has(text, "env PROJ_TOKEN=" .. vim.fn.sha256("t1"), "its hash is")

  -- names are case-insensitive where the system says so (Windows reports them in upper case): `MyVar` listed,
  -- `MYVAR` set, a changed value must change the key (`<unset>` before and after would be a stale hit)
  local mixed = { env_names = { "Proj_Token" }, env_case_insensitive = true }
  local kc1 = key_of(E, mixed)
  ok(kc1 ~= nil, "a listed name in mixed case has a key")
  env.PROJ_TOKEN = "t2"
  ok(
    key_of(E, mixed) ~= kc1,
    "case-insensitive: the value of PROJ_TOKEN changes the key of 'Proj_Token'"
  )
  env.PROJ_TOKEN = "t1"
  eq(key_of(E, mixed), kc1, "and back again")
  local _, _, p_ci = key_of(E, mixed)
  has(
    table.concat(assert(p_ci), "\n"),
    "env PROJ_TOKEN=" .. vim.fn.sha256("t1"),
    "the line carries the system's spelling"
  )
  local sensitive = { env_names = { "Proj_Token" }, env_case_insensitive = false }
  local ks1 = key_of(A, sensitive)
  ok(ks1 ~= nil, "a pure spec has a key whatever the case")
  env.PROJ_TOKEN = "t2"
  eq(
    key_of(A, sensitive),
    ks1,
    "case-sensitive (Linux, macOS): 'Proj_Token' is another variable, unset both times"
  )
  env.PROJ_TOKEN = "t1"
  -- a prefix in another case expands over the names that are set
  local kpp1 = key_of(A, { env_names = { "proj_*" }, env_case_insensitive = true })
  env.PROJ_NEW = "n"
  ok(
    key_of(A, { env_names = { "proj_*" }, env_case_insensitive = true }) ~= kpp1,
    "a prefix matches names in another case where names are case-insensitive"
  )
  env.PROJ_NEW = nil
  -- the real environment: the system's own lookup decides (case-insensitive on Windows only)
  vim.env.TN_CI_PROBE = "one"
  local real =
    { env_names = { "Tn_Ci_Probe" }, environ = vim.fn.environ, env_case_insensitive = false }
  local kr1 = key_of(A, real)
  vim.env.TN_CI_PROBE = "two"
  real.env_case_insensitive = nil
  local kr_two = key_of(A, real)
  vim.env.TN_CI_PROBE = "one"
  local kr_one = key_of(A, real)
  vim.env.TN_CI_PROBE = nil
  if vim.fn.has("win32") == 1 then
    ok(
      kr_two ~= kr_one,
      "Windows: a changed value of a variable listed in another case changes the key"
    )
  else
    eq(kr_two, kr_one, "elsewhere the name is case-sensitive: 'Tn_Ci_Probe' is unset both times")
  end
  ok(kr1 ~= nil, "fixture")
  has(
    select(2, key_of("TESTS/proj/envdyn_spec.lua", { env_names = { "PROJ_TOKEN" } })),
    "computed name",
    "a computed name"
  )

  -- ---------------------------------------------------------------- no key: inputs that cannot be known
  local no_key = {
    { "TESTS/proj/proc_spec.lua", "process" },
    { "TESTS/proj/time_spec.lua", "clock" },
    { "TESTS/proj/random_spec.lua", "random" },
    { "TESTS/proj/off_spec.lua", "@cache off" },
    { "TESTS/proj/unresolved_spec.lua", "unresolved module 'nonexistent.mod'" },
    { "TESTS/proj/escape_spec.lua", "outside the project" },
    { "TESTS/proj/missing_spec.lua", "spec file" },
  }
  for _, c in ipairs(no_key) do
    local k, reason = key_of(c[1])
    eq(k, nil, c[1] .. " has no key")
    has(reason, c[2], c[1] .. " names the reason")
  end
  eq(
    select(1, cache.key({ file = "../x_spec.lua" }, ctx())),
    nil,
    "a spec path that leaves the project"
  )
  eq(select(1, cache.key({ file = "/abs/x_spec.lua" }, ctx())), nil, "an absolute spec path")
  ---@diagnostic disable-next-line: missing-fields
  eq(select(1, cache.key({}, ctx())), nil, "no file")

  -- optional modules: with `unresolved = "absent"` the absence is part of the key
  local ku1 = key_of("TESTS/proj/unresolved_spec.lua", { unresolved = "absent" })
  ok(ku1 ~= nil, "an unresolved module can be an input that is absent")
  has(
    table.concat(
      select(3, key_of("TESTS/proj/unresolved_spec.lua", { unresolved = "absent" })),
      "\n"
    ),
    "absent nonexistent.mod",
    "named in the key"
  )
  local optional = vim.fs.normalize(vim.fn.tempname())
  S.write(optional .. "/lua/nonexistent/mod.lua", "return {}\n")
  ok(
    key_of("TESTS/proj/unresolved_spec.lua", { unresolved = "absent", dep_roots = { optional } })
      ~= ku1,
    "installing the module changes the key"
  )
  S.remove(optional)

  -- ---------------------------------------------------------------- computed requires
  local L = "TESTS/proj/lazy_spec.lua"
  local kl = key_of(L)
  ok(kl ~= nil, "a computed prefix is resolved to the modules below it")
  has(
    table.concat(select(3, key_of(L)), "\n"),
    "lua/proj/sub/x.lua",
    "the module below the prefix is a part"
  )
  S.edit(root, "lua/proj/sub/x.lua", "return { x = 2 }\n")
  ok(key_of(L) ~= kl, "a module below a computed prefix changes the key")

  -- ---------------------------------------------------------------- files the spec reads
  local R = "TESTS/proj/reads_spec.lua"
  local kr = key_of(R)
  ok(kr ~= nil, "a spec that reads files has a key")
  S.edit(root, "README.md", "# proj changed\n")
  local kr2 = key_of(R)
  ok(kr2 ~= kr, "a file named by a path literal is part of the key")
  S.edit(root, "TESTS/proj/helper.lua", "return { helper = 2 }\n")
  ok(key_of(R) ~= kr2, "the support files of the spec root are part of the key")
  -- a spec edit elsewhere in the tree is NOT a support file
  local kr3 = key_of(R)
  S.edit(root, "TESTS/proj/c_spec.lua", "return function(H) H.ok(true, 'c2') end\n")
  eq(key_of(R), kr3, "another spec is not an input")

  local I = "TESTS/proj/inputs_spec.lua"
  local ki = key_of(I)
  ok(ki ~= nil, "a declared input exists")
  S.edit(root, "docs/data.txt", "data v2\n")
  ok(key_of(I) ~= ki, "a declared input is part of the key")
  vim.fn.delete(root .. "/docs/data.txt")
  local ka = key_of(I)
  ok(ka ~= nil and ka ~= ki, "a declared input that is gone is part of the key (as absent)")

  -- ---------------------------------------------------------------- explicit dependency list (graph)
  local kg1 = key_of(A, nil, { deps = { "lua/proj/b.lua" }, deps_complete = true })
  S.edit(root, "lua/proj/b.lua", "return { v = 4 }\n")
  ok(
    kg1 ~= key_of(A, nil, { deps = { "lua/proj/b.lua" }, deps_complete = true }),
    "a listed dep is hashed"
  )
  local kg2 = key_of(A, nil, { deps = { "lua/proj/b.lua" }, deps_complete = true })
  S.edit(root, "lua/proj/a.lua", "return { v = 5 }\n")
  eq(
    key_of(A, nil, { deps = { "lua/proj/b.lua" }, deps_complete = true }),
    kg2,
    "an unlisted dep is not"
  )

  -- ---------------------------------------------------------------- dependency roots (another checkout)
  local dep = vim.fs.normalize(vim.fn.tempname())
  S.write(dep .. "/lua/ext/m.lua", "return { m = 1 }\n")
  S.edit(
    root,
    "TESTS/proj/ext_spec.lua",
    'local m = require("ext.m")\nreturn function(H) H.ok(m, "ext") end\n'
  )
  local e_none = select(2, key_of("TESTS/proj/ext_spec.lua"))
  has(
    e_none,
    "unresolved module 'ext.m'",
    "a module of an unknown checkout makes the file uncacheable"
  )
  local ke = key_of("TESTS/proj/ext_spec.lua", { dep_roots = { dep } })
  ok(ke ~= nil, "a module found in a dependency root is part of the key")
  S.edit(dep, "lua/ext/m.lua", "return { m = 2 }\n")
  ok(
    key_of("TESTS/proj/ext_spec.lua", { dep_roots = { dep } }) ~= ke,
    "a change in the dependency checkout changes the key"
  )
  S.remove(dep)

  -- ---------------------------------------------------------------- stat pre-check
  local h = hash.new()
  local c1 = ctx({ hasher = h })
  local ka1 = cache.key({ file = A }, c1)
  local hashed = h.hashed
  ok(hashed > 0, "files were hashed the first time")
  local ka2 = cache.key({ file = A }, ctx({ hasher = h }))
  eq(ka2, ka1, "same key")
  eq(h.hashed, hashed, "the second key hashes nothing: size and mtime still match")
  ok(h.reused > 0, "the hashes came from the index")
  -- a file younger than the racy window is hashed every time (an edit inside one tick would be missed)
  S.write(root .. "/lua/proj/a.lua", "return { v = 7 }\n", false)
  local hy = hash.new()
  local before = hy.hashed
  cache.key({ file = A }, ctx({ hasher = hy }))
  local after1 = hy.hashed
  cache.key({ file = A }, ctx({ hasher = hy }))
  ok(hy.hashed > after1 and after1 > before, "a young file is hashed again every time")

  -- ---------------------------------------------------------------- the runner version
  local rv = cache.runner_version({ root = root, cache_dir = cdir, hasher = hash.new() })
  eq(#rv, 64, "the runner digest is a sha256")
  eq(cache.runner_version({}), rv, "memoized")

  cache.reset()
  S.remove(root)
  S.remove(cdir)
end
