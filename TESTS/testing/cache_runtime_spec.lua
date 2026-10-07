-- TESTS/testing/cache_runtime_spec.lua -- the runtime directories of the project root (`ftplugin/`, `indent/`,
-- `queries/`, `after/`, ...) are loaded by an editor without a `require`: a digest of each is part of EVERY key, and the
-- `require`s of their Lua files are edges of every closure. A spec that never names them (it sets a filetype and looks at
-- what the filetype plugin did) must not keep a green result after one of them changed. The Neovim part of the key
-- is made once per process.

---@diagnostic disable: need-check-nil, missing-fields

-- @cache-allow env
-- (the fixtures of this spec are project files that mention the environment)
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
      unresolved = "error",
    }, over or {})
  end
  local function key_of(root, file, over)
    local k, why, parts = cache.key({ file = file }, ctx(root, over))
    return k, why, parts
  end
  local SPEC = "TESTS/p_spec.lua"
  -- a spec that is pure: no file read, no require
  local PURE = "return function(H) H.ok(true, 'p') end\n"

  ---Lines of the key that start with `runtime`.
  local function runtime_parts(parts)
    local out = {}
    for _, l in ipairs(parts or {}) do
      if l:find("^runtime ") then
        out[#out + 1] = l:match("^runtime (%S+)=")
      end
    end
    return out
  end

  -- ---------------------------------------------------------------- every runtime directory is an input
  -- (a file is added, edited, and an unrelated one next to the project is edited: only the first two change the key)
  local dirs = {
    { "ftplugin/mylang.lua", "vim.b.my_ft = 1\n", "vim.b.my_ft = 2\n" },
    { "after/ftplugin/mylang.lua", "vim.b.my_after = 1\n", "vim.b.my_after = 2\n" },
    { "indent/mylang.lua", "vim.b.my_indent = 1\n", "vim.b.my_indent = 2\n" },
    { "syntax/mylang.vim", "syn keyword Foo foo\n", "syn keyword Foo bar\n" },
    { "queries/mylang/highlights.scm", "(identifier) @variable\n", "(identifier) @constant\n" },
    { "ftdetect/mylang.lua", "-- detect 1\n", "-- detect 2\n" },
    { "colors/mine.lua", "vim.g.colors_name = 'a'\n", "vim.g.colors_name = 'b'\n" },
    { "compiler/mine.vim", "CompilerSet makeprg=a\n", "CompilerSet makeprg=b\n" },
    {
      "autoload/mine.vim",
      "function! mine#f()\nendfunction\n",
      "function! mine#g()\nendfunction\n",
    },
    { "lsp/mine.lua", "return { cmd = { 'a' } }\n", "return { cmd = { 'b' } }\n" },
    { "plugin/mycmd.lua", "vim.g.mycmd = 1\n", "vim.g.mycmd = 2\n" },
    { "keymap/mine.vim", "let b:keymap_name = 'a'\n", "let b:keymap_name = 'b'\n" },
  }
  for _, d in ipairs(dirs) do
    local rel, v1, v2 = d[1], d[2], d[3]
    section("runtime file " .. rel, function()
      local root = S.project({ [SPEC] = PURE })
      local k0 = key_of(root, SPEC)
      ok(k0 ~= nil, "a pure spec has a key")
      S.write(root .. "/" .. rel, v1)
      local k1, _, parts = key_of(root, SPEC)
      ok(k1 ~= k0, rel .. ": a new file in a runtime directory changes the key")
      local top = rel:match("^([^/]+)/")
      ok(
        vim.tbl_contains(runtime_parts(parts), top .. "/"),
        rel
          .. ": the key has a `runtime "
          .. top
          .. "/=` line: "
          .. vim.inspect(runtime_parts(parts))
      )
      eq(key_of(root, SPEC), k1, rel .. ": and it is stable")
      S.edit(root, rel, v2)
      local k2 = key_of(root, SPEC)
      ok(k2 ~= k1, rel .. ": an edit of it changes the key")
      -- what is not an input stays out
      S.edit(root, "docs/x.md", "unrelated edit\n")
      S.edit(root, "TESTS/other_spec.lua", "return function(H) H.ok(true, 'other') end\n")
      eq(key_of(root, SPEC), k2, rel .. ": a document and another spec do not change the key")
      S.remove(root)
    end)
  end

  -- ---------------------------------------------------------------- a directory that does not exist is no line
  section("absent directories", function()
    local root = S.project({ [SPEC] = PURE })
    local _, _, parts = key_of(root, SPEC)
    -- the fixture project has a `plugin/` and nothing else of the list
    eq(runtime_parts(parts), { "plugin/" }, "only the directories that exist have a line")
    vim.fn.delete(root .. "/plugin", "rf")
    local k_without, _, parts2 = key_of(root, SPEC)
    eq(runtime_parts(parts2), {}, "a project without one has no line")
    S.write(root .. "/plugin/proj.lua", "-- plugin entry\n")
    ok(key_of(root, SPEC) ~= k_without, "creating the directory changes the key")
    -- `lua/` is the closure, `doc/` and `README.md` are no runtime input of an editor session
    S.write(root .. "/doc/x.txt", "help\n")
    local k_doc = key_of(root, SPEC)
    S.edit(root, "doc/x.txt", "help 2\n")
    eq(key_of(root, SPEC), k_doc, "doc/ is no runtime directory of the key")
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- the layout of the key changed
  section("key version", function()
    local root = S.project({ [SPEC] = PURE })
    local _, _, parts = key_of(root, SPEC)
    ok(cache.KEY_VERSION >= 2, "the key layout has a new version: " .. tostring(cache.KEY_VERSION))
    eq(parts[1], "key-version " .. cache.KEY_VERSION, "and the first line names it")
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- what a runtime file requires joins the closure
  section("requires of a runtime file", function()
    local FT = 'local ft = require("proj.ft")\nvim.b.my_ft = ft.v\n'
    for _, where in ipairs({
      "ftplugin/mylang.lua",
      "after/ftplugin/mylang.lua",
      "indent/mylang.lua",
    }) do
      local root = S.project({
        [SPEC] = PURE,
        ["lua/proj/ft.lua"] = "return { v = 1 }\n",
        [where] = FT,
      })
      local k0, _, parts = key_of(root, SPEC)
      ok(k0 ~= nil, where .. ": a key")
      ok(
        table.concat(parts, "\n"):find("dep lua/proj/ft.lua=", 1, true) ~= nil,
        where .. ": the module the runtime file requires is a dependency of the spec"
      )
      S.edit(root, "lua/proj/ft.lua", "return { v = 2 }\n")
      ok(key_of(root, SPEC) ~= k0, where .. ": an edit of the module changes the key")
      S.remove(root)
    end
    -- without the runtime file nothing leads to the module: the key does not follow it
    local root = S.project({ [SPEC] = PURE, ["lua/proj/ft.lua"] = "return { v = 1 }\n" })
    local k0 = key_of(root, SPEC)
    S.edit(root, "lua/proj/ft.lua", "return { v = 2 }\n")
    eq(key_of(root, SPEC), k0, "a module nobody loads is no input")
    S.remove(root)
    -- `plugin/` is not sourced by an editor that starts with `-u NONE`: its requires are no edges
    root = S.project({
      [SPEC] = PURE,
      ["lua/proj/ft.lua"] = "return { v = 1 }\n",
      ["plugin/mycmd.lua"] = FT,
    })
    k0 = key_of(root, SPEC)
    S.edit(root, "lua/proj/ft.lua", "return { v = 2 }\n")
    eq(key_of(root, SPEC), k0, "the requires of plugin/ are not edges of every closure")
    S.remove(root)
  end)

  section("unresolved require of a runtime file", function()
    local root = S.project({
      [SPEC] = PURE,
      ["ftplugin/mylang.lua"] = 'local x = require("optional.dep")\n',
    })
    local k, why = key_of(root, SPEC)
    ok(k == nil, "a runtime file with a require nobody resolves has no key")
    ok(
      type(why) == "string" and why:find("optional.dep", 1, true) ~= nil,
      "and names the module: " .. tostring(why)
    )
    ok(
      type(why) == "string" and why:find("ftplugin/mylang.lua", 1, true) ~= nil,
      "and the file that requires it: " .. tostring(why)
    )
    local ka, _, parts = key_of(root, SPEC, { unresolved = "absent" })
    ok(ka ~= nil, "where the absence is part of the key, there is one")
    ok(
      table.concat(parts, "\n"):find("absent optional.dep", 1, true) ~= nil,
      "and the absence is a line"
    )
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- a runtime Lua file is a MEMBER of the closure
  -- What a module the spec requires reads or declares counts for the spec: the same holds for a Lua file the editor
  -- loads by itself (`ftplugin/mylang.lua` is run by `:set filetype=mylang` of a spec that names nothing).

  ---Is there a key line that starts with `prefix`? (`env X=` is not `child-env X=`)
  ---@param parts string[]|nil
  ---@param prefix string
  ---@return boolean
  local function has_line(parts, prefix)
    for _, l in ipairs(parts or {}) do
      if l:sub(1, #prefix) == prefix then
        return true
      end
    end
    return false
  end
  local RT_FILES = { "ftplugin/mylang.lua", "after/ftplugin/mylang.lua", "indent/mylang.lua" }
  local function with_env(value)
    return {
      environ = function()
        return { MYLANG_INDENT = value }
      end,
    }
  end

  section("runtime file: the environment variable it reads joins the key", function()
    for _, where in ipairs(RT_FILES) do
      local root = S.project({
        [SPEC] = PURE,
        [where] = "vim.bo.shiftwidth = tonumber(vim.env.MYLANG_INDENT) or 2\n",
      })
      local k2, why, parts = key_of(root, SPEC, with_env("2"))
      ok(k2 ~= nil, where .. ": a key: " .. tostring(why))
      ok(
        has_line(parts, "env MYLANG_INDENT="),
        where .. ": the key has a line for the variable the file reads"
      )
      local k4 = key_of(root, SPEC, with_env("4"))
      ok(k4 ~= nil and k4 ~= k2, where .. ": another value of the variable is another key")
      eq(key_of(root, SPEC, with_env("2")), k2, where .. ": and the key is stable")
      -- `-- @cache-env` of the file names a variable it reads by a computed name
      S.edit(
        root,
        where,
        "-- @cache-env MYLANG_*\nlocal n = 'MYLANG_' .. 'INDENT'\nvim.bo.shiftwidth = tonumber(vim.env[n]) or 2\n"
      )
      local d2, why_d, parts_d = key_of(root, SPEC, with_env("2"))
      ok(d2 ~= nil, where .. ": a declared computed read has a key: " .. tostring(why_d))
      ok(
        has_line(parts_d, "env MYLANG_INDENT="),
        where .. ": the variable that `-- @cache-env` of the runtime file names is in the key"
      )
      ok(key_of(root, SPEC, with_env("4")) ~= d2, where .. ": and its value changes the key")
      S.edit(
        root,
        where,
        "local n = 'MYLANG_' .. 'INDENT'\nvim.bo.shiftwidth = tonumber(vim.env[n]) or 2\n"
      )
      local k_dyn, why_dyn = key_of(root, SPEC, with_env("2"))
      ok(k_dyn == nil, where .. ": a computed read without a declaration has no key")
      ok(
        type(why_dyn) == "string" and why_dyn:find("computed name", 1, true) ~= nil,
        where .. ": and says why: " .. tostring(why_dyn)
      )
      S.remove(root)
    end
  end)

  section("runtime file: a child editor sees the environment as a whole", function()
    local root = S.project({
      [SPEC] = PURE,
      ["ftplugin/mylang.lua"] = "vim.bo.shiftwidth = tonumber(vim.env.MYLANG_INDENT) or 2\n",
    })
    local fi = { file = SPEC, child_env = { "MYLANG_INDENT=aaaa" } }
    local k2, why, parts = cache.key(fi, ctx(root, with_env("2")))
    ok(k2 ~= nil, "a file that runs in a child editor has a key: " .. tostring(why))
    ok(
      not has_line(parts, "env MYLANG_INDENT="),
      "the parent's value is no extra line: the child's environment is in the key already"
    )
    ok(has_line(parts, "child-env MYLANG_INDENT=aaaa"), "the child's environment is")
    eq(cache.key(fi, ctx(root, with_env("4"))), k2, "and the parent's value does not matter")
    ok(
      cache.key({ file = SPEC, child_env = { "MYLANG_INDENT=bbbb" } }, ctx(root)) ~= k2,
      "the child's value does"
    )
    S.remove(root)
  end)

  section("runtime file: `-- @cache off` is the author's word", function()
    for _, where in ipairs(RT_FILES) do
      local root = S.project({
        [SPEC] = PURE,
        [where] = "-- @cache off\nvim.b.my_ft = 1\n",
      })
      local k, why, parts, detail = cache.key({ file = SPEC }, ctx(root))
      ok(k == nil, where .. ": a runtime file that opts out leaves every spec without a key")
      ok(parts == nil, where .. ": and without key lines")
      ok(
        type(why) == "string" and why:find("@cache off", 1, true) ~= nil,
        where .. ": and says why: " .. tostring(why)
      )
      ok(
        type(why) == "string" and why:find("mylang.lua", 1, true) ~= nil,
        where .. ": and which file: " .. tostring(why)
      )
      eq(detail and detail.kind, "off", where .. ": the reason as data")
      eq(detail and detail.file, "mylang.lua", where .. ": names the file")
      S.remove(root)
    end
  end)

  section("runtime file: the files it reads are inputs", function()
    local root = S.project({
      [SPEC] = PURE,
      ["data/words.txt"] = "alpha\n",
      ["ftplugin/mylang.lua"] = "local f = io.open('data/words.txt', 'rb')\nvim.b.words = f and f:read('*a')\n",
    })
    local k0, why = key_of(root, SPEC)
    ok(k0 ~= nil, "a runtime file that reads a file has a key: " .. tostring(why))
    S.edit(root, "data/words.txt", "beta\n")
    ok(key_of(root, SPEC) ~= k0, "an edit of the file it reads changes the key")
    S.remove(root)
    -- a file the editor loads by `:runtime` is a file nobody can follow: the whole project is an input
    root = S.project({
      [SPEC] = PURE,
      ["lib/helper.lua"] = "return 1\n",
      ["ftplugin/mylang.lua"] = "vim.cmd('runtime lib/helper.lua')\n",
    })
    local kd = key_of(root, SPEC)
    ok(kd ~= nil, "a runtime file with a `:runtime` has a key")
    S.edit(root, "lib/helper.lua", "return 2\n")
    ok(key_of(root, SPEC) ~= kd, "an edit of what it loads by `:runtime` changes the key")
    S.remove(root)
  end)

  section("runtime file that a module also requires is one member", function()
    -- `spec_roots = { 'ftplugin' }`: `require('mylang')` of the spec finds the very file the editor loads
    local root = S.project({
      [SPEC] = 'local m = require("mylang")\nreturn function(H) H.ok(m, "m") end\n',
      ["ftplugin/mylang.lua"] = "-- @cache-allow env\nreturn { v = 1 }\n",
    })
    local k, why, _, detail = cache.key({ file = SPEC }, ctx(root, { spec_roots = { "ftplugin" } }))
    ok(k ~= nil, "a key: " .. tostring(why))
    eq(
      detail and detail.vouched,
      { { directive = "@cache-allow env", file = "ftplugin/mylang.lua" } },
      "the directive of the file is listed once"
    )
    S.remove(root)
  end)

  -- ---------------------------------------------------------------- explain names it
  section("explain", function()
    local explain = require("testing.cache.explain")
    local diff = explain.diff(
      { "runtime ftplugin/=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
      { "runtime ftplugin/=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
    )
    eq(#diff, 1, "one change")
    eq(diff[1].kind, "runtime", "of the kind runtime")
    eq(diff[1].name, "ftplugin/", "named by the directory")
    eq(diff[1].change, "changed", "changed")
  end)

  -- ---------------------------------------------------------------- the Neovim part of the key is made once
  section("nvim version memo", function()
    cache.reset()
    local root = S.project({ [SPEC] = PURE })
    local calls = { version = 0, api_info = 0 }
    local real_version, real_api_info = vim.version, vim.fn.api_info
    vim.version = setmetatable({}, {
      __index = real_version,
      __call = function(_, ...)
        calls.version = calls.version + 1
        return real_version(...)
      end,
    })
    vim.fn.api_info = function(...)
      calls.api_info = calls.api_info + 1
      return real_api_info(...)
    end
    local function line_of(parts)
      for _, l in ipairs(parts) do
        if l:find("^nvim ") then
          return l
        end
      end
    end
    local good, err = pcall(function()
      local _, _, p1 = key_of(root, SPEC, { nvim = false })
      local after_first = vim.deepcopy(calls)
      ok(after_first.version >= 1, "the first key asks for the version")
      for _ = 1, 5 do
        local _, _, pn = key_of(root, SPEC, { nvim = false })
        eq(line_of(pn), line_of(p1), "the same nvim line every time")
      end
      eq(calls.version, after_first.version, "five more keys do not ask for the version again")
      eq(calls.api_info, after_first.api_info, "nor for the API information")
      -- a reset (a new process in effect) makes it again; a spec override never reaches the memo
      local _, _, over = key_of(root, SPEC, { nvim = "9.9.9-test" })
      eq(line_of(over), "nvim 9.9.9-test", "the override of a spec wins")
      eq(
        line_of(select(3, key_of(root, SPEC, { nvim = false }))),
        line_of(p1),
        "and is not remembered"
      )
      cache.reset()
      key_of(root, SPEC, { nvim = false })
      ok(calls.version > after_first.version, "`reset` forgets it")
    end)
    vim.version = real_version
    vim.fn.api_info = nil -- the field of the stub: the lookup goes back to the real function
    cache.reset()
    S.remove(root)
    if not good then
      error(err, 0)
    end
  end)

  ok(#failed == 0, "sections that are red:\n" .. table.concat(failed, "\n"))
end
