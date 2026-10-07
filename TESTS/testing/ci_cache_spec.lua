-- TESTS/testing/ci_cache_spec.lua -- what the CI cache recipe (docs/CI-CACHE.md) stands on: the keys contain no
-- absolute path (the same project in two checkouts has the same keys), the cache folder can be named by
-- `cache.project_key` and placed by `--cache-dir` / TESTING_CACHE_HOME, so a restored folder is found on a runner
-- with another checkout path, and a stamp made in one checkout verifies in the other.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end

  local cli = require("testing.cli")
  local stamp = require("testing.stamp")
  local cache = require("testing.cache")
  local store = require("testing.cache.store")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-cicache"
  vim.fn.mkdir(tmp, "p")
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
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
    ok(res.code == 0, "git: " .. tostring(res.stderr))
  end
  ---Same content in every checkout.
  local function checkout(name, cfg)
    local root = tmp .. "/" .. name .. "/deeper/checkout"
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'a')\nend\n")
    write(
      root .. "/TESTS/c_spec.lua",
      "return function(H)\n  H.ok(require('proj.mod').value == 1, 'c')\nend\n"
    )
    write(
      root .. "/.testing.lua",
      cfg or "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end
  local state = tmp .. "/state"
  local function run(argv, extra)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
      affected = { getenv = function() end, provider = false },
      stamp = { getenv = function() end },
    }
    for k, v in pairs(extra or {}) do
      sv[k] = v
    end
    local code = cli.main(argv, sv)
    package.loaded["proj.mod"] = nil
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local function dirs(base)
    local list = {}
    for name, kind in vim.fs.dir(base .. "/testing") do
      if kind == "directory" then
        list[#list + 1] = name
      end
    end
    return list
  end

  -- the same project at two paths: the keys are the same, and no key line holds a path of the checkout
  local a = checkout("one")
  local b = checkout("two-and-longer-path")
  local ra = run({ "explain", a, "--all", "--json", "--parts" })
  local rb = run({ "explain", b, "--all", "--json", "--parts" })
  local da, db = vim.json.decode(ra.out), vim.json.decode(rb.out)
  eq(#da.specs, 2, "two spec files")
  for i, s in ipairs(da.specs) do
    ok(s.key and #s.key == 64, "a key exists for " .. s.file)
    eq(s.key, db.specs[i].key, "the key of " .. s.file .. " is the same in both checkouts")
    for _, line in ipairs(s.parts) do
      ok(
        not line:find(a, 1, true) and not line:find(b, 1, true),
        "no checkout path in: " .. line:sub(1, 80)
      )
    end
  end

  -- a stamp of one checkout verifies in the other
  eq(run({ "stamp", a }).code, 0, "stamp in checkout one")
  local sp = stamp.path(a, { state_dir = state })
  local v = run({ "verify", b, "--stamp", sp, "--allow-dirty" })
  eq(v.code, 0, "verified in another checkout: " .. v.out)
  has(v.out, "verified:", "says verified")

  -- the folder name follows the path, unless cache.project_key says otherwise
  local base1, base2 = tmp .. "/cache-1", tmp .. "/cache-2"
  eq(run({ a, "--cached", "--cache-dir", base1 }).code, 0, "a cached run into --cache-dir")
  eq(#dirs(base1), 1, "the cache is below --cache-dir")
  eq(run({ b, "--cached", "--cache-dir", base1 }).code, 0, "another checkout, same base")
  eq(#dirs(base1), 2, "by default the folder depends on the checkout path (two folders)")

  local ka = checkout(
    "keyed-one",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, cache = { project_key = 'proj-ci' } }\n"
  )
  local kb = checkout(
    "keyed-two-longer",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, cache = { project_key = 'proj-ci' } }\n"
  )
  eq(run({ ka, "--cached", "--cache-dir", base2 }).code, 0, "a run with cache.project_key")
  eq(
    dirs(base2),
    { "proj-ci-" .. vim.fn.sha256("proj-ci"):sub(1, 12) },
    "the folder is named after the key"
  )
  local second = run({ kb, "--cached", "--cache-dir", base2 })
  eq(second.code, 0, "the same project in another checkout path")
  eq(#dirs(base2), 1, "uses the same folder")
  has(second.out, "2 from cache", "and finds the results the first run stored")
  eq(
    store.dir(ka, { cache_dir = base2 }),
    store.dir(kb, { cache_dir = base2 }),
    "store.dir agrees (the key is still set)"
  )
  run({ a }) -- a run without the key resets it
  ok(store.project_key == nil, "a project without the key does not inherit it")

  -- TESTING_CACHE_HOME (handed down by the entry script) and the precedence
  local base3, base4 = tmp .. "/cache-3", tmp .. "/cache-4"
  eq(run({ a, "--cached" }, { env = { TESTING_CACHE_HOME = base3 } }).code, 0, "TESTING_CACHE_HOME")
  eq(#dirs(base3), 1, "is the base of the cache")
  eq(
    run({ a, "--cached", "--cache-dir", base4 }, { env = { TESTING_CACHE_HOME = base3 } }).code,
    0,
    "both"
  )
  eq(#dirs(base4), 1, "--cache-dir wins")

  -- a bad key is a configuration problem, not a folder name
  local bad =
    checkout("bad", "return { plugin = 'proj', minit = false, cache = { project_key = '../x' } }\n")
  local r = run({ "doctor", bad })
  has(r.err, "project_key", "a path-like key is reported")

  vim.fn.delete(tmp, "rf")
  cache.reset()
end
