-- TESTS/testing/affected_sound_spec.lua -- the selection never omits a spec that a full run would turn red:
-- a spec that lists directories or loads files by path can see any file, a support file is an input of
-- every spec below its spec root (not only of the specs next to it), and a module that does so reaches
-- the specs that require it. Every scenario here was a spec that a full run turned red while
-- `--changed` said "no spec is affected".

return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local affected = require("testing.affected")

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
    for _, f in ipairs(r.files) do
      if f == spec then
        return true
      end
    end
    return false
  end

  -- a meta spec that lists the module directory and loads every file
  do
    local root = S.project({
      ["lua/other.lua"] = "return { v = 1 }\n",
      ["TESTS/meta_spec.lua"] = 'return function(H)\n  for name, kind in vim.fs.dir(H.root .. "/lua") do\n    if kind == "file" then dofile(H.root .. "/lua/" .. name) end\n  end\n  H.ok(true, "meta")\nend\n',
      ["TESTS/plain_spec.lua"] = "return function(H) H.ok(true, 'plain') end\n",
    })
    local specs = { "TESTS/meta_spec.lua", "TESTS/plain_spec.lua" }
    local r = select_in(root, specs, { "lua/other.lua" })
    ok(has(r, "TESTS/meta_spec.lua"), "a spec that lists lua/ is selected by a change of a module")
    ok(not has(r, "TESTS/plain_spec.lua") or r.all, "an unrelated spec is not")
    r = select_in(root, specs, { "docs/x.md" })
    ok(
      has(r, "TESTS/meta_spec.lua") or r.all,
      "a spec that lists directories sees a doc file as well"
    )
    S.remove(root)
  end

  -- a spec that loads a file with an ex command
  do
    local root = S.project({
      ["plugin/p.lua"] = "vim.g.p = 1\n",
      ["TESTS/rt_spec.lua"] = 'return function(H)\n  vim.opt.rtp:append(H.root)\n  vim.cmd("runtime plugin/p.lua")\n  H.ok(vim.g.p, "rt")\nend\n',
      ["TESTS/plain_spec.lua"] = "return function(H) H.ok(true, 'plain') end\n",
    })
    local r = select_in(root, { "TESTS/rt_spec.lua", "TESTS/plain_spec.lua" }, { "lua/proj/b.lua" })
    ok(
      has(r, "TESTS/rt_spec.lua"),
      "a spec that loads files by `:runtime` is selected by any module change"
    )
    S.remove(root)
  end

  -- a support file that a spec of ANOTHER directory requires through package.path
  do
    local root = S.project({
      ["TESTS/a/helper.lua"] = "return { v = 1 }\n",
      ["TESTS/a/a_spec.lua"] = "return function(H) H.ok(true, 'a') end\n",
      ["TESTS/b/use_spec.lua"] = 'package.path = "TESTS/a/?.lua;" .. package.path\nlocal h = require("helper")\nreturn function(H) H.ok(h.v, "use") end\n',
      ["TESTS/c/other_spec.lua"] = "return function(H) H.ok(true, 'other') end\n",
    })
    local specs = { "TESTS/a/a_spec.lua", "TESTS/b/use_spec.lua", "TESTS/c/other_spec.lua" }
    local r = select_in(root, specs, { "TESTS/a/helper.lua" })
    ok(has(r, "TESTS/b/use_spec.lua"), "the spec that requires the support module is selected")
    ok(has(r, "TESTS/a/a_spec.lua"), "and the spec next to it")
    S.remove(root)
  end

  -- a module that lists directories reaches the specs that require it
  do
    local root = S.project({
      ["lua/scanner.lua"] = 'local M = {}\nfunction M.all() return vim.fn.glob("lua/*.lua", false, true) end\nreturn M\n',
      ["lua/other.lua"] = "return { v = 1 }\n",
      ["TESTS/s_spec.lua"] = 'local s = require("scanner")\nreturn function(H) H.eq(#s.all(), 2, "two") end\n',
      ["TESTS/plain_spec.lua"] = "return function(H) H.ok(true, 'plain') end\n",
    })
    local r = select_in(root, { "TESTS/s_spec.lua", "TESTS/plain_spec.lua" }, { "lua/other.lua" })
    ok(
      has(r, "TESTS/s_spec.lua"),
      "a module that lists directories counts as changed with anything"
    )
    S.remove(root)
  end

  -- a utility that lists what its CALLER hands it is not the project: its specs are not selected by any change
  do
    local root = S.project({
      ["lua/lister.lua"] = "return function(dir) local out = {} for name in vim.fs.dir(dir) do out[#out + 1] = name end return out end\n",
      ["lua/other.lua"] = "return { v = 1 }\n",
      ["TESTS/l_spec.lua"] = 'local list = require("lister")\nreturn function(H) H.ok(list(vim.fn.tempname()), "l") end\n',
      ["TESTS/plain_spec.lua"] = "return function(H) H.ok(true, 'plain') end\n",
    })
    local r = select_in(root, { "TESTS/l_spec.lua", "TESTS/plain_spec.lua" }, { "lua/other.lua" })
    ok(
      r.all == false and not has(r, "TESTS/l_spec.lua"),
      "a utility that lists its argument does not reach its specs"
    )
    S.remove(root)
  end

  -- a directory literal covers the files below it
  do
    local root = S.project({
      ["fixtures/data/a.json"] = "{}\n",
      ["TESTS/d_spec.lua"] = 'return function(H) H.ok(vim.fn.readfile("fixtures/data/a.json"), "d") end\n',
      ["TESTS/plain_spec.lua"] = "return function(H) H.ok(true, 'plain') end\n",
    })
    local r = select_in(
      root,
      { "TESTS/d_spec.lua", "TESTS/plain_spec.lua" },
      { "fixtures/data/a.json" }
    )
    ok(has(r, "TESTS/d_spec.lua"), "a spec that names the file is selected")
    S.remove(root)
  end

  require("testing.cache").reset()
  S.remove(cdir)
end
