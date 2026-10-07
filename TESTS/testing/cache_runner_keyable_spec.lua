-- TESTS/testing/cache_runner_keyable_spec.lua -- the runner's own modules keep a cache key. A module of the project
-- that reads the whole environment (`vim.fn.environ()`) without a header directive (`-- @cache-allow env`, as
-- `testing.run.cached` and `testing.stamp.collect` have it) takes the key away from EVERY spec whose require closure
-- reaches it: `testing.run.project` loads `testing.stamp.write` and through it `testing.stamp.collect`, so most of
-- this suite would run again on each `--cached` run and each CI job. A missing key is the safe direction (no false
-- green), but the hit rate of the suite is gone without a word: this spec says it.
--
-- The check runs on a copy of this checkout's `lua/` tree (the files as they are right now), with the same context
-- shape a run uses (`unresolved = "absent"`), so what it asserts is what `testing explain` would print.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-inputs lua/
-- (the copy is made from the checkout of the runner: a directory the spec reads by a computed path)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local cache = require("testing.cache")
  local hash = require("testing.cache.hash")
  local deps = require("testing.deps")

  local self_dir = deps.self_dir()
  local lib = deps.resolve("lib.nvim", self_dir)
  ok(lib ~= nil, "fixture: lib.nvim is found")
  if not lib then
    return
  end

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-runner-keyable"
  local root = tmp .. "/proj"

  ---Copy a file of the checkout into the project.
  ---@param rel string Path below the root of the checkout.
  local function copy(rel)
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
    local done, err = vim.uv.fs_copyfile(self_dir .. "/" .. rel, root .. "/" .. rel)
    ok(done, "fixture: copy of " .. rel .. ": " .. tostring(err))
  end
  local n_files = 0
  for name, kind in vim.fs.dir(self_dir .. "/lua", { depth = 12 }) do
    if kind == "file" then
      copy("lua/" .. name)
      n_files = n_files + 1
    end
  end
  ok(n_files > 50, "fixture: the runner's tree is copied (" .. n_files .. " files)")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  ---@param path string
  ---@return string
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end

  ---A spec file of the copy that requires `mod`.
  ---@param mod string
  ---@return string rel
  local function spec_of(mod)
    local rel = "TESTS/" .. mod:gsub("%.", "_") .. "_spec.lua"
    write(
      root .. "/" .. rel,
      ("local m = require(%q)\nreturn function(H)\n  H.ok(m ~= nil, 'loads')\nend\n"):format(mod)
    )
    return rel
  end

  ---A context like the one of a run (`testing.run.cached.key_inputs`); one per question, because its memo holds
  ---the analyses of the files it has seen (and so makes every later key cheap).
  ---@return Testing.Cache.Ctx
  local function new_ctx(name)
    return {
      root = root,
      cache_dir = tmp .. "/cache-" .. name,
      dep_roots = { lib.dir },
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
    }
  end

  -- ---------------------------------------------------------------- the runner modules have a key
  local MODULES = {
    "testing.stamp.collect",
    "testing.stamp.write",
    "testing.stamp.verify",
    "testing.run.project",
    "testing.run.cached",
    "testing.cli",
  }
  local specs = {}
  for _, mod in ipairs(MODULES) do
    specs[mod] = spec_of(mod) -- all written before the first key: the context lists the tree once
  end
  local shared = new_ctx("all")
  local failed = {}
  for _, mod in ipairs(MODULES) do
    local key, why = cache.key({ file = specs[mod] }, shared)
    if key == nil then
      failed[#failed + 1] = mod .. ": " .. tostring(why)
    end
  end
  eq(failed, {}, "a spec that requires a runner module has a cache key")

  -- ---------------------------------------------------------------- the control: the scenario is real
  -- the same copy without the directive loses the key of a spec that loads the runner, and the reason names the file
  local collect = root .. "/lua/testing/stamp/collect.lua"
  local text = read(collect)
  ok(
    text:find("-- @cache-allow env", 1, true) ~= nil,
    "the header of collect.lua declares `-- @cache-allow env`"
  )
  local stripped = text:gsub("%-%- @cache%-allow env\n", "", 1)
  ok(stripped ~= text, "fixture: the directive is removed in the copy")
  write(collect, stripped)
  local key, why = cache.key({ file = specs["testing.run.project"] }, new_ctx("control"))
  eq(key, nil, "control: without the directive a spec that loads the runner has no key")
  ok(
    tostring(why):find("reads the whole environment", 1, true) ~= nil
      and tostring(why):find("collect.lua", 1, true) ~= nil,
    "control: and the reason names the whole environment and collect.lua: " .. tostring(why)
  )

  vim.fn.delete(tmp, "rf")
end
