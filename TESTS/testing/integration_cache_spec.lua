-- TESTS/testing/integration_cache_spec.lua -- `--cached`, `--no-cache`, `--cache-refresh`, `--cache-clear` and the
-- `cache` key of `.testing.lua` through the real command line (`testing.cli.main`) on a throwaway project: a spec
-- that did not change does not run and says so (never greener than a full run), a changed dependency re-runs
-- exactly the spec that loads it, a red file is never stored, a damaged entry is a miss, and nothing is cached
-- under a case selection or in CI.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

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
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end

  local cli = require("testing.cli")
  local cache = require("testing.cache")
  local cached = require("testing.run.cached")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-cachespec"
  vim.fn.mkdir(tmp, "p")
  local seq = 0

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---A project of three specs: `a` is pure, `b` reads the clock (never cached), `c` loads `proj.mod`.
  ---@return string root
  local function project()
    seq = seq + 1
    local root = tmp .. "/p" .. seq
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(
      root .. "/TESTS/a_spec.lua",
      "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n"
    )
    write(
      root .. "/TESTS/b_spec.lua",
      "return function(H)\n  H.ok(os.time() > 0, 'the clock')\nend\n"
    )
    write(
      root .. "/TESTS/c_spec.lua",
      "return function(H)\n  H.ok(require('proj.mod').value == 1, 'the module')\nend\n"
    )
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    return root
  end

  local function cache_dir()
    return tmp .. "/cache"
  end

  ---@param root string
  ---@param argv string[]
  ---@param more? table service overrides
  ---@return { code: integer, out: string, err: string }
  local function run(root, argv, more)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = cache_dir(),
      color = false,
      affected = { getenv = function() end },
    }
    for k, v in pairs(more or {}) do
      sv[k] = v
    end
    local args = { root }
    vim.list_extend(args, argv)
    -- the specs of the project must find `proj.mod`
    local code = cli.main(args, sv)
    package.loaded["proj.mod"] = nil
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local root = project()

  local function entries()
    return cache.stats({ root = root, cache_dir = cache_dir() }).entries
  end

  -- ---------------------------------------------------------------- off unless asked for
  local plain = run(root, {})
  eq(plain.code, 0, "a plain run is green\n" .. plain.err)
  lacks(plain.out, "cache (", "a plain run does not mention the cache")
  lacks(plain.out, "(cached)", "and nothing is cached")
  eq(entries(), 0, "and nothing is stored")
  has(plain.out, "TESTING_OK", "the sentinel is printed on a complete green run")

  -- ---------------------------------------------------------------- cold, then warm
  local cold = run(root, { "--cached" })
  eq(cold.code, 0, "--cached, cold, is green\n" .. cold.err)
  has(cold.out, "cache (use): 0 of 3 spec file(s) were not run", "cold: nothing from the cache")
  has(cold.out, "3 ran", "cold: all three ran")
  has(cold.out, "reads the clock", "the file that reads the clock says why it has no key")
  has(cold.out, "2 stored", "the two files with a key are stored")
  eq(entries(), 2, "two entries on disk")

  local warm = run(root, { "--cached" })
  eq(warm.code, 0, "--cached, warm, is green\n" .. warm.err)
  has(
    warm.out,
    "cache (use): 2 of 3 spec file(s) were not run",
    "warm: two files come from the cache"
  )
  has(warm.out, "1 ran", "warm: only the clock spec ran")
  has(warm.out, "a_spec.lua (cached)", "the terminal marks a cached file")
  has(warm.out, "c_spec.lua (cached)", "and the other one")
  lacks(warm.out, "b_spec.lua (cached)", "but not the file that ran")
  has(warm.out, "2 cached, not run", "the summary counts what was not executed")
  has(
    warm.out,
    "TESTING_OK",
    "a green, complete, cached run keeps the sentinel: the verdict is the full run's"
  )
  has(warm.out, "--no-cache runs everything", "and says how to run everything")

  -- the verdict of a cached run is the verdict of a full run (same counts)
  local full = run(root, { "--no-cache" })
  eq(full.code, warm.code, "--no-cache: same exit code as the cached run")
  lacks(full.out, "cache (", "--no-cache prints no cache line")
  local function counts(text)
    return text:match("summary: ([^\n]-) %(")
  end
  eq(
    counts(full.out),
    counts(warm.out),
    "the summary counts are the same with and without the cache"
  )
  eq(entries(), 2, "--no-cache neither reads nor writes")

  -- ---------------------------------------------------------------- the IR says what was cached
  local ir_path = tmp .. "/ir.json"
  local with_ir = run(root, { "--cached", "--json", ir_path })
  eq(with_ir.code, 0, "--json with --cached is green")
  local ir = vim.json.decode(assert(io.open(ir_path, "rb")):read("*a"))
  eq(ir.run.cache.mode, "use", "run.cache.mode")
  eq(ir.run.cache.files_cached, 2, "run.cache.files_cached")
  local flagged = {}
  for _, c in ipairs(ir.cases) do
    flagged[c.file] = c.cached == true
  end
  eq(
    flagged,
    { ["TESTS/a_spec.lua"] = true, ["TESTS/b_spec.lua"] = false, ["TESTS/c_spec.lua"] = true },
    "cases[].cached marks exactly the files that were not executed"
  )
  for _, c in ipairs(ir.cases) do
    if c.cached then
      eq(c.status, "pass", "a cached case keeps the status pass")
      ok(
        vim.iter(c.notes):any(function(n)
          return n:find("cached from", 1, true) ~= nil
        end),
        "and a note says where it came from"
      )
    end
  end

  -- ---------------------------------------------------------------- a changed dependency re-runs exactly its spec
  write(root .. "/lua/proj/mod.lua", "return { value = 1, extra = true }\n")
  local after_dep = run(root, { "--cached" })
  eq(after_dep.code, 0, "after a dependency changed: green\n" .. after_dep.err)
  has(
    after_dep.out,
    "cache (use): 1 of 3 spec file(s) were not run",
    "only the spec that loads it re-runs"
  )
  has(after_dep.out, "a_spec.lua (cached)", "the unrelated spec is still cached")
  lacks(after_dep.out, "c_spec.lua (cached)", "the spec that loads the changed module ran")

  -- ---------------------------------------------------------------- never greener: a red file is red, and never stored
  write(root .. "/lua/proj/mod.lua", "return { value = 2 }\n")
  local red = run(root, { "--cached" })
  eq(red.code, 1, "the changed module breaks c_spec: the run is RED, not cached-green\n" .. red.out)
  lacks(red.out, "TESTING_OK", "no sentinel on a red run")
  local red_again = run(root, { "--cached" })
  eq(red_again.code, 1, "and it is still red the next time: a red file is never stored")
  lacks(red_again.out, "c_spec.lua (cached)", "c_spec.lua is not taken from the cache")
  write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
  local healed = run(root, { "--cached" })
  eq(healed.code, 0, "back to the green content: green\n" .. healed.out)

  -- ---------------------------------------------------------------- --cache-refresh runs everything and stores
  local refresh = run(root, { "--cache-refresh" })
  eq(refresh.code, 0, "--cache-refresh is green")
  has(refresh.out, "cache (refresh): 0 of 3 spec file(s) were not run", "refresh reads nothing")
  lacks(refresh.out, "(cached)", "and shows nothing as cached")

  -- ---------------------------------------------------------------- --no-cache wins
  local before = entries()
  local no = run(root, { "--cached", "--no-cache" })
  eq(no.code, 0, "--cached --no-cache is green")
  lacks(no.out, "cache (", "--no-cache wins over --cached (either order)")
  local no2 = run(root, { "--no-cache", "--cached" })
  lacks(no2.out, "cache (", "in the other order too")
  eq(entries(), before, "and the cache was not touched")

  -- ---------------------------------------------------------------- a case selection turns the cache off, loudly
  local filtered = run(root, { "--cached", "--filter", "arithmetic" })
  has(
    filtered.err,
    "cache not used: a case selection",
    "--filter: the cache is not used and the note says why"
  )
  lacks(filtered.out, "(cached)", "and nothing is shown as cached")
  local listed = run(root, { "--cached", "--list" })
  lacks(listed.out, "cache (", "--list runs nothing and does not use the cache")

  -- ---------------------------------------------------------------- a damaged entry is a miss
  local entries_dir = cache.stats({ root = root, cache_dir = cache_dir() }).dir .. "/entries"
  local damaged_n = 0
  for f2, k2 in vim.fs.dir(entries_dir) do
    if k2 == "file" then
      write(entries_dir .. "/" .. f2, "{ this is not json")
      damaged_n = damaged_n + 1
    end
  end
  ok(damaged_n > 0, "there were entries to damage")
  local damaged = run(root, { "--cached" })
  eq(damaged.code, 0, "damaged entries: the run is still green (they are misses)\n" .. damaged.err)
  has(
    damaged.out,
    "cache (use): 0 of 3 spec file(s) were not run",
    "damaged entries are never a partial hit"
  )

  -- ---------------------------------------------------------------- `.testing.lua` `cache.enabled`, and CI
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, cache = { enabled = true } }\n"
  )
  run(root, {})
  local by_config = run(root, {})
  has(by_config.out, "cache (use): 2 of 3", "cache.enabled = true uses the cache without a flag")
  local no_ci = function() end
  local in_ci = function(name)
    return name == "CI" and "true" or nil
  end
  ---@param getenv fun(name: string): string|nil
  ---@param argv string[]
  local function mode_of(getenv, argv)
    local args = assert(require("testing.args").parse(vim.list_extend({ root }, argv)))
    return (cached.mode_of({ args = args, project = { cache = { enabled = true } } }, nil, getenv))
  end
  eq(mode_of(no_ci, {}), "use", "a configured cache is used outside CI")
  eq(
    mode_of(in_ci, {}),
    "off",
    "a configured cache is NOT used in CI (a default never decides there)"
  )
  eq(mode_of(in_ci, { "--cached" }), "use", "an explicit --cached is used in CI")
  eq(mode_of(in_ci, { "--cached", "--no-cache" }), "off", "--no-cache wins in CI too")

  -- ---------------------------------------------------------------- every driver: a child per file, the warm pool
  for _, extra in ipairs({
    { "--isolated", "file" },
    { "--isolated", "file", "--pool-reuse" },
  }) do
    local label = table.concat(extra, " ")
    local proot = project()
    local cold_args = vim.list_extend({ "--cached" }, extra)
    local c1 = run(proot, cold_args)
    eq(c1.code, 0, label .. ": cold is green\n" .. c1.err .. c1.out)
    has(c1.out, "cache (use): 0 of 3 spec file(s) were not run", label .. ": cold runs everything")
    local c2 = run(proot, cold_args)
    eq(c2.code, 0, label .. ": warm is green\n" .. c2.err .. c2.out)
    has(
      c2.out,
      "cache (use): 2 of 3 spec file(s) were not run",
      label .. ": the two cacheable files do not start a child editor"
    )
    has(c2.out, "a_spec.lua (cached)", label .. ": and are marked")
    write(proot .. "/lua/proj/mod.lua", "return { value = 7 }\n")
    local c3 = run(proot, cold_args)
    eq(
      c3.code,
      1,
      label .. ": a changed module that breaks its spec is red, not cached-green\n" .. c3.out
    )
    lacks(c3.out, "c_spec.lua (cached)", label .. ": and the spec that loads it ran")
  end

  -- ---------------------------------------------------------------- --cache-clear
  local cleared = run(root, { "--cache-clear" })
  eq(cleared.code, 0, "--cache-clear is green")
  has(cleared.out, "cache cleared:", "and says what it did")
  eq(entries(), 0, "the cache is empty")
  local again = run(root, { "--cache-clear" })
  has(again.out, "0 entries removed", "clearing an empty cache is not an error")

  -- ---------------------------------------------------------------- flags that cannot be combined
  local bad = run(root, { "--cache-clear", "--cached" })
  eq(bad.code, 2, "--cache-clear --cached is a usage error")
  has(bad.err, "--cache-clear", "and names the option")
  local bad2 = run(root, { "--watch", "--cached" })
  eq(bad2.code, 2, "--watch --cached is a usage error")

  vim.fn.delete(tmp, "rf")
end
