-- TESTS/testing/affected_wrapped_spec.lua -- the call sites of a `require` wrapper are edges
-- (`lazy.require("a")`), and the wrapper is no dependency on every module, but ONLY for a module that
-- declares `-- @require-wrapper` and only for the uses the scanner can follow. Every other use of the
-- wrapper stays a dependency on everything: the selection never gets smaller by a use it did not understand.

-- @cache-env X
-- (the variable the spec sets and reads itself: its outer value joins the key)
return function(H)
  local ok = H.ok
  local eq = H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local affected = require("testing.affected")
  local scan = require("testing.affected.scan")
  local wrapped = require("testing.affected.wrapped")

  -- ---- the reader: which uses of a module it can follow ------------------------------------------
  ---@param src string
  ---@return table
  local function uses(src)
    return scan.analyze(src).wrapped
  end
  local W = 'local lazy = require("w")\n'

  do
    local u = uses(W .. 'local a = lazy.require("a")\nlocal b = lazy.module("b")\n')
    eq(u.w.members, { "module", "require" }, "an alias used only as alias.member(literal): members")
    eq(u.w.names, { "a", "b" }, "an alias used only as alias.member(literal): names")
  end
  do
    local u = uses('M.f = require("w").require("a")\nM.g = require "w" .require("b")\n')
    eq(u.w and u.w.names, { "a", "b" }, "the inline form require(X).member(literal)")
  end
  do
    local u = uses(W .. 'local s = "lazy"\n-- foo(lazy)\nlocal a = lazy.require("a") -- lazy\n')
    eq(u.w and u.w.names, { "a" }, "the alias in a string or a comment is not a use")
  end
  do
    local u = uses(W .. 'local x = obj.lazy\nlocal a = lazy.require("a")\n')
    eq(u.w and u.w.names, { "a" }, "a field of that name (obj.lazy) is another thing")
  end

  -- every use below is one the reader cannot follow: the module must NOT be listed
  local loose = {
    ["passed on"] = W .. "foo(lazy)\n",
    ["returned"] = 'return require("w")\n',
    ["stored in a field"] = 'M.lazy = require("w")\n',
    ["computed argument"] = W .. "lazy.require(name)\n",
    ["concatenated argument"] = W .. 'lazy.require("a." .. name)\n',
    ["method call"] = W .. 'lazy:require("a")\n',
    ["indexed"] = W .. 'lazy["require"]("a")\n',
    ["member taken apart"] = 'local r = require("w").require\nr("a")\n',
    ["pcall(require, ...)"] = W .. 'lazy.require("a")\nlocal ok, l = pcall(require, "w")\n',
    ["required twice with an alias"] = W
      .. 'local function f() local lazy = require("w"); return lazy.require("a") end\n',
    ["alias shadowed by a parameter"] = W .. "local function f(lazy) return lazy.require(n) end\n",
    ["alias concatenated"] = W .. 'local s = "a" ..lazy\n',
    ["alias called"] = W .. "lazy()\n",
    ["a second argument is a name"] = W .. 'lazy.require("a")\nlazy.require(x, "a")\n',
    ["required with a second argument"] = 'local lazy = require("w", y)\nlazy.require("a")\n',
    ["string call"] = 'require("w")"a"\n',
    ["required inside a command string"] = W
      .. 'vim.cmd("lua require(\'w\')")\nlazy.require("a")\n',
  }
  local names = vim.tbl_keys(loose)
  table.sort(names)
  for _, label in ipairs(names) do
    ok(uses(loose[label]).w == nil, "not followed: " .. label)
  end

  do
    -- limits and hostile data of an index on disk
    ok(
      wrapped.valid({ w = { members = { "x" }, names = { "a" } } }) ~= nil,
      "a clean entry is accepted"
    )
    ok(wrapped.valid({ w = { members = { 1 }, names = {} } }) == nil, "a member that is no string")
    ok(wrapped.valid({ w = { members = {}, names = { {} } } }) == nil, "a name that is no string")
    ok(wrapped.valid({ w = { members = {} } }) == nil, "names missing")
    ok(wrapped.valid("x") == nil, "not a table")
    ok(
      wrapped.valid({ w = { members = {}, names = { string.rep("x", 201) } } }) == nil,
      "an oversized name"
    )
    local many = {}
    for i = 1, wrapped.MAX_NAMES + 1 do
      many[i] = "m" .. i
    end
    ok(wrapped.valid({ w = { members = {}, names = many } }) == nil, "too many names")
    local info = scan.analyze(W .. 'lazy.require("a")\n')
    info.wrapped = { w = { members = { "require" }, names = { "a" } } }
    local round = scan.valid_info(vim.json.decode(vim.json.encode(info)))
    eq(round and round.wrapped, info.wrapped, "the analysis survives the index file")
    local hostile = vim.json.decode(vim.json.encode(info))
    hostile.wrapped = { w = { members = "require", names = { "a" } } }
    ok(scan.valid_info(hostile) == nil, "a hostile `wrapped` drops the analysis")
    eq(
      scan.analyze("-- @require-wrapper require module fn\nreturn {}\n").directives.wrapper,
      { "require", "module", "fn" },
      "the directive"
    )
    eq(
      scan.analyze("local x = 1\n-- @require-wrapper require\n").directives.wrapper,
      { "require" },
      "the directive in the header"
    )
  end

  -- ---- the selection --------------------------------------------------------------------------------
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local function select_in(root, specs, changed)
    return affected.select({
      root = root,
      specs = specs,
      changed = changed,
      provider = false,
      getenv = function()
        return nil
      end,
      cache_dir = cdir,
      roots = { "TESTS" },
    })
  end
  local function has(r, spec)
    return vim.tbl_contains(r.files, spec)
  end

  local WRAPPER = table.concat({
    "-- @require-wrapper require module",
    "local LAZY = {}",
    "function LAZY.require(module_name) return require(module_name) end",
    "function LAZY.module(module_name) return { get = function() return require(module_name) end } end",
    "function LAZY.load_all(list) for _, n in ipairs(list) do require(n) end end",
    "return LAZY",
    "",
  }, "\n")
  local function project(wrapper_text, extra)
    local files = {
      ["lua/w.lua"] = wrapper_text,
      ["lua/leaf_a.lua"] = "return { a = 1 }\n",
      ["lua/leaf_b.lua"] = "return { b = 1 }\n",
      ["lua/user_a.lua"] = 'local lazy = require("w")\nreturn lazy.require("leaf_a")\n',
      ["lua/user_b.lua"] = 'return require("w").module("leaf_b")\n',
      ["TESTS/a_spec.lua"] = 'return function(H) require("user_a"); H.ok(true, "a") end\n',
      ["TESTS/b_spec.lua"] = 'return function(H) require("user_b"); H.ok(true, "b") end\n',
      ["TESTS/none_spec.lua"] = "return function(H) H.ok(true, 'none') end\n",
    }
    for k, v in pairs(extra or {}) do
      files[k] = v
    end
    return S.project(files)
  end
  local SPECS = { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/none_spec.lua" }

  do
    -- without the declaration nothing changes: the wrapper computes a name, every user of it is "everything"
    local plain = WRAPPER:gsub("^%-%- @require%-wrapper[^\n]*\n", "")
    local root = project(plain)
    local r = select_in(root, SPECS, { "lua/leaf_a.lua" })
    ok(has(r, "TESTS/a_spec.lua"), "undeclared: the spec of the changed leaf")
    ok(
      has(r, "TESTS/b_spec.lua"),
      "undeclared: the spec of ANOTHER leaf too (the wrapper computes a name)"
    )
    S.remove(root)
  end

  do
    -- declared: the call sites are the edges
    local root = project(WRAPPER)
    local r = select_in(root, SPECS, { "lua/leaf_a.lua" })
    ok(not r.all, "declared: not everything")
    ok(has(r, "TESTS/a_spec.lua"), "declared: the spec that reaches leaf_a through lazy.require")
    ok(not has(r, "TESTS/b_spec.lua"), "declared: a spec that reaches only leaf_b is not selected")
    ok(not has(r, "TESTS/none_spec.lua"), "declared: a spec without a require is not selected")
    r = select_in(root, SPECS, { "lua/leaf_b.lua" })
    ok(
      has(r, "TESTS/b_spec.lua"),
      "declared: the inline form require(w).module(leaf_b) is an edge too"
    )
    ok(not has(r, "TESTS/a_spec.lua"), "declared: and a_spec is not selected by leaf_b")
    r = select_in(root, SPECS, { "lua/w.lua" })
    ok(
      has(r, "TESTS/a_spec.lua") and has(r, "TESTS/b_spec.lua"),
      "a change of the wrapper selects its users"
    )
    ok(
      not has(r, "TESTS/none_spec.lua"),
      "a change of the wrapper does not select a spec without it"
    )
    S.remove(root)
  end

  -- a use the reader cannot follow makes that file a dependency on everything again
  local uncovered = {
    ["a computed name"] = 'local lazy = require("w")\nreturn lazy.require(os.getenv("X"))\n',
    ["the wrapper passed on"] = 'local lazy = require("w")\nreturn setmetatable({}, { __index = function(_, k) return lazy.require(k) end })\n',
    ["a member the wrapper did not declare"] = 'local lazy = require("w")\nlazy.load_all({ "leaf_a" })\n',
    ["a member that is not declared, with a literal"] = 'local lazy = require("w")\nlazy.load_all("leaf_b")\n',
    ["the wrapper named by a prefix"] = 'local n = ...\nreturn require("w" .. n)\n',
    ["pcall(require, wrapper)"] = 'local ok, lazy = pcall(require, "w")\nreturn lazy.require(x)\n',
  }
  local labels = vim.tbl_keys(uncovered)
  table.sort(labels)
  for _, label in ipairs(labels) do
    local root = project(WRAPPER, {
      ["lua/user_b.lua"] = uncovered[label],
    })
    local r = select_in(root, SPECS, { "lua/leaf_a.lua" })
    ok(has(r, "TESTS/a_spec.lua"), label .. ": the spec of the changed leaf")
    ok(
      has(r, "TESTS/b_spec.lua"),
      label .. ": a module that uses the wrapper in a way no one can follow depends on every module"
    )
    S.remove(root)
  end

  do
    -- a spec that uses the wrapper itself
    local root = project(WRAPPER, {
      ["TESTS/direct_spec.lua"] = 'return function(H)\n  local lazy = require("w")\n  lazy.require("leaf_b")\n  H.ok(true, "d")\nend\n',
      ["TESTS/computed_spec.lua"] = 'return function(H)\n  local lazy = require("w")\n  lazy.require(H.name)\n  H.ok(true, "c")\nend\n',
    })
    local specs =
      vim.list_extend(vim.deepcopy(SPECS), { "TESTS/direct_spec.lua", "TESTS/computed_spec.lua" })
    local r = select_in(root, specs, { "lua/leaf_a.lua" })
    ok(
      not has(r, "TESTS/direct_spec.lua"),
      "a spec that names leaf_b through the wrapper is not reached by leaf_a"
    )
    ok(
      has(r, "TESTS/computed_spec.lua"),
      "a spec that gives the wrapper a computed name is reached by anything"
    )
    r = select_in(root, specs, { "lua/leaf_b.lua" })
    ok(
      has(r, "TESTS/direct_spec.lua"),
      "a spec that names leaf_b through the wrapper is reached by leaf_b"
    )
    S.remove(root)
  end
end
