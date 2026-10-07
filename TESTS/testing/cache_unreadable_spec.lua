-- TESTS/testing/cache_unreadable_spec.lua -- a directory that cannot be listed is NOT an empty one. The walk that
-- builds a digest (`Hasher:tree`) and the listings of the closure (a computed `require` prefix, the Lua files of the
-- runtime directories) used to drop the "could not read" answer of `collect_recursive`: the files below the directory
-- were missing from the key, and an edit of one of them (a spec may open it by name: the directory can be traversed
-- but not listed) kept serving a stale green. Now there is no key, and the reason names the directory.
--
-- The directory that cannot be listed is made by a stub of `uv.fs_scandir`: no permission trick, so the spec runs
-- the same on every platform.

---@diagnostic disable: need-check-nil, missing-fields

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

  ---Run `fn` as one section: a failure is collected, so one run names every section that is red.
  local failed = {}
  local function section(name, fn)
    local good, err = pcall(fn)
    if not good then
      failed[#failed + 1] = name .. ": " .. tostring(err)
    end
  end

  ---Run `fn` while `uv.fs_scandir` refuses every directory whose path ends with `suffix`.
  ---@param suffix string
  ---@param fn fun()
  local function unreadable(suffix, fn)
    local uv = vim.uv
    local real = uv.fs_scandir
    uv.fs_scandir = function(path, ...)
      if type(path) == "string" and vim.fs.normalize(path):sub(-#suffix) == suffix then
        return nil, "EPERM: permission denied: " .. path
      end
      return real(path, ...)
    end
    local good, err = pcall(fn)
    uv.fs_scandir = real
    if not good then
      error(err, 0)
    end
  end

  local function ctx(root)
    return {
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
      unresolved = "error",
    }
  end
  local SPEC = "TESTS/p_spec.lua"
  local PURE = "return function(H) H.ok(true, 'p') end\n"
  ---@param root string
  ---@param file? string
  local function key_of(root, file)
    return cache.key({ file = file or SPEC }, ctx(root))
  end

  -- ---------------------------------------------------------------- the digest of a tree
  section("tree digest", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    S.write(root .. "/fx/top.txt", "top\n")
    S.write(root .. "/fx/sub/x.txt", "v1\n")
    local h = hash.new()
    local d0, why0 = h:tree(root .. "/fx")
    ok(type(d0) == "string", "a tree that can be listed has a digest: " .. tostring(why0))
    unreadable("/fx/sub", function()
      local d, why = hash.new():tree(root .. "/fx")
      ok(d == nil, "a subdirectory that cannot be listed is no empty one: no digest")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "and the reason says so: " .. tostring(why)
      )
      ok(
        type(why) == "string" and why:find("fx/sub", 1, true) ~= nil,
        "and names the directory: " .. tostring(why)
      )
      -- the root itself
      d, why = hash.new():tree(root .. "/fx/sub")
      ok(d == nil and type(why) == "string", "the same for the directory asked for itself")
    end)
    -- the answer is not remembered: the directory can be listed again
    eq(
      hash.new():tree(root .. "/fx"),
      d0,
      "a directory that can be listed again has its digest back"
    )
    S.remove(root)
  end)

  section("tree digest: a linked directory", function()
    local root = vim.fs.normalize(vim.fn.tempname())
    S.write(root .. "/real/inner.txt", "inner\n")
    S.write(root .. "/fx/top.txt", "top\n")
    local made = pcall(function()
      assert(vim.uv.fs_symlink(root .. "/real", root .. "/fx/lnk", { dir = true }))
    end)
    if made then
      local d0 = hash.new():tree(root .. "/fx")
      ok(type(d0) == "string", "a tree with a link has a digest")
      unreadable("/fx/lnk", function()
        local d, why = hash.new():tree(root .. "/fx")
        ok(d == nil, "a linked directory that cannot be listed gives no digest")
        ok(
          type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
          "and the reason says so: " .. tostring(why)
        )
      end)
    end
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- an input directory of a spec
  section("key: a declared input directory", function()
    local root = S.project({
      [SPEC] = "-- @cache-inputs data/\n" .. PURE,
      ["data/top.txt"] = "top\n",
      ["data/sub/x.txt"] = "v1\n",
    })
    local k0, why0 = key_of(root)
    ok(k0 ~= nil, "a spec with a declared input has a key: " .. tostring(why0))
    unreadable("/data/sub", function()
      local k, why, parts, detail = key_of(root)
      ok(k == nil, "an input directory with a subdirectory that cannot be listed has no key")
      ok(parts == nil, "and no key lines")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "the reason says so: " .. tostring(why)
      )
      eq(detail and detail.kind, "inputs", "the reason as data")
    end)
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- the whole project, a data directory
  section("key: the directory of a module that reads files", function()
    local root = S.project({
      [SPEC] = 'local r = require("proj.reader")\nreturn function(H) H.ok(r, "r") end\n',
      ["lua/proj/reader.lua"] = 'local f = io.open("data/x.txt", "rb")\nreturn f\n',
      ["data/x.txt"] = "x\n",
      ["lua/proj/extra/note.txt"] = "n1\n",
      ["lua/proj/extra/deeper/note.txt"] = "n2\n",
    })
    local k0, why0 = key_of(root)
    ok(k0 ~= nil, "a key: " .. tostring(why0))
    unreadable("/lua/proj/extra/deeper", function()
      local k, why = key_of(root)
      ok(k == nil, "the data next to a module has a subdirectory that cannot be listed: no key")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "the reason says so: " .. tostring(why)
      )
    end)
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- the runtime directories
  section("key: a runtime directory", function()
    local root = S.project({
      [SPEC] = PURE,
      ["ftplugin/mylang.lua"] = "vim.b.my_ft = 1\n",
      ["ftplugin/sub/x.lua"] = "vim.b.sub = 1\n",
      ["queries/mylang/highlights.scm"] = "(identifier) @variable\n",
    })
    local k0, why0 = key_of(root)
    ok(k0 ~= nil, "a key: " .. tostring(why0))
    unreadable("/ftplugin/sub", function()
      local k, why, _, detail = key_of(root)
      ok(k == nil, "a runtime directory with a subdirectory that cannot be listed has no key")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "the reason says so: " .. tostring(why)
      )
      ok(
        type(why) == "string" and why:find("ftplugin/sub", 1, true) ~= nil,
        "and names it: " .. tostring(why)
      )
      eq(detail and detail.kind, "dependency", "the reason as data")
    end)
    -- a directory without Lua files is read by the digest alone
    unreadable("/queries/mylang", function()
      local k, why = key_of(root)
      ok(k == nil, "the digest of a runtime directory refuses on its own")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "and says so: " .. tostring(why)
      )
    end)
    eq(key_of(root), k0, "the key is the same again when the directories can be listed")
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- a computed require prefix
  section("key: the modules below a computed prefix", function()
    local root = S.project({
      ["lua/proj/sub/inner/y.lua"] = "return { y = 1 }\n",
    })
    local lazy = "TESTS/proj/lazy_spec.lua"
    local k0, why0 = key_of(root, lazy)
    ok(k0 ~= nil, "a spec that requires below a computed prefix has a key: " .. tostring(why0))
    unreadable("/lua/proj/sub/inner", function()
      local k, why, _, detail = key_of(root, lazy)
      ok(k == nil, "a directory below the prefix that cannot be listed leaves no key")
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "the reason says so: " .. tostring(why)
      )
      eq(detail and detail.kind, "dependency", "the reason as data")
    end)
    -- a spec that does not reach the directory is not touched by it
    unreadable("/lua/proj/sub/inner", function()
      local k = key_of(root, "TESTS/proj/pure_spec.lua")
      ok(k ~= nil, "a spec that never lists the directory keeps its key")
    end)
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- the runner itself
  -- (the digest of `lua/testing` is a key line: when it cannot be made, the line would be a constant and an edit of
  -- the runner would not change any key)
  section("key: a runner that cannot be hashed", function()
    local root = S.project({ [SPEC] = PURE })
    cache.reset()
    local good, err = pcall(function()
      local c = ctx(root)
      c.runner_version = nil
      local real_tree = c.hasher.tree
      c.hasher.tree = function(self, d, opts)
        if vim.fs.normalize(d):sub(-12) == "/lua/testing" then
          return nil, "unreadable directory: " .. d .. "/sub: EPERM"
        end
        return real_tree(self, d, opts)
      end
      local k, why, parts, detail = cache.key({ file = SPEC }, c)
      ok(k == nil, "a runner that cannot be hashed leaves no key")
      ok(parts == nil, "and no key lines")
      ok(
        type(why) == "string" and why:find("runner cannot be hashed", 1, true) ~= nil,
        "the reason says so: " .. tostring(why)
      )
      ok(
        type(why) == "string" and why:find("unreadable directory", 1, true) ~= nil,
        "and why: " .. tostring(why)
      )
      eq(detail and detail.kind, "inputs", "the reason as data")
      -- the answer is the process's: a runner that can be hashed again has a key again
      cache.reset()
      c = ctx(root)
      c.runner_version = nil
      local k2, why2 = cache.key({ file = SPEC }, c)
      ok(k2 ~= nil, "a runner that can be hashed has a key: " .. tostring(why2))
    end)
    cache.reset()
    S.remove(root)
    if not good then
      error(err, 0)
    end
  end)

  ok(#failed == 0, "sections that are red:\n" .. table.concat(failed, "\n"))
end
