-- TESTS/testing/child_clipboard_spec.lua -- the fake clipboard of a throwaway editor (testing.child.clipboard): the
-- provider keeps `+`/`*` in the process; every child has it before the project's minit (RPC child, which is
-- how a warm pool member starts too, and the per-file child); a minit that sets `g:clipboard` itself wins; a
-- second install and an editor that decided are refused. Why: a spec's `setreg("+", marker)` used to land on
-- the developer's system clipboard (win32yank), and came out of Ctrl+V in a browser.

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local clipboard = require("testing.child.clipboard")
  local NAME = clipboard.NAME

  -- ===================================================================
  -- 1. the provider, pure: two stores, lines and type round-trip, copies not references
  do
    local p = clipboard.provider()
    eq(p.name, NAME, "the provider carries the name")
    eq(p.paste["+"](), { {}, "v" }, "+ starts empty")
    local lines = { "one", "two" }
    p.copy["+"](lines, "V")
    lines[1] = "changed"
    eq(p.paste["+"](), { { "one", "two" }, "V" }, "+ gives the lines and the type back, copied")
    eq(p.paste["*"](), { {}, "v" }, "* is a store of its own")
    p.copy["*"]({ "x" }, "v")
    eq(p.paste["+"](), { { "one", "two" }, "V" }, "writing * leaves + alone")
    p.copy["+"]({ "a" })
    eq(p.paste["+"](), { { "a" }, "v" }, "no type means characterwise")
    local other = clipboard.provider()
    eq(other.paste["+"](), { {}, "v" }, "every provider() has stores of its own")
  end

  -- ===================================================================
  -- 2. install(): this file runs in a throwaway editor of this repository (dogfood), so the fake is in
  -- place already; a second install is refused and says why
  if #vim.api.nvim_list_uis() == 0 then
    eq(
      vim.g.clipboard and vim.g.clipboard.name,
      NAME,
      "the editor this file runs in has the fake clipboard"
    )
    local again, why = clipboard.install()
    eq(again, false, "a second install is refused")
    has(why, "g:clipboard is set", "with the reason")
  end

  -- ===================================================================
  -- 3. a real RPC child (the start of a warm pool member is the same file): the fake is there before the
  -- minit, `+` round-trips inside the child and never reaches this editor's `+`
  local S = dofile(dir .. "/fixtures/child/support.lua")
  S.run(function()
    local c = S.spawn({})
    eq(
      c.lua_get("vim.g.clipboard and vim.g.clipboard.name"),
      NAME,
      "an RPC child has the fake clipboard"
    )
    local marker = "testing_child_clipboard_spec_marker_" .. tostring(vim.uv.hrtime())
    c.lua(("vim.fn.setreg('+', {%q, 'two'}, 'V')"):format(marker))
    eq(c.lua_get("vim.fn.getreg('+', 1, 1)"), { marker, "two" }, "+ round-trips in the child")
    eq(c.lua_get("vim.fn.getregtype('+')"), "V", "with its type")
    eq(c.lua_get("vim.fn.getreg('*')"), "", "* is a register of its own")
    ok(
      vim.fn.getreg("+") ~= marker .. "\ntwo\n" and vim.fn.getreg("+") ~= marker .. "\ntwo",
      "what the child wrote to + did not reach this editor's +"
    )

    -- the project's minit decides: a `g:clipboard` it sets is the one the spec sees
    local minit = S.new_dir() .. "/minit.lua"
    local f = assert(io.open(minit, "wb"))
    f:write(
      "vim.g.clipboard = { name = 'project-own', copy = { ['+'] = function() end, ['*'] = function() end },",
      " paste = { ['+'] = function() return {} end, ['*'] = function() return {} end } }\n"
    )
    f:close()
    local own = S.spawn({ minit = minit })
    eq(own.lua_get("vim.g.clipboard.name"), "project-own", "a minit that sets g:clipboard wins")
  end)

  -- ===================================================================
  -- 4. the per-file child (`testing.child.boot`): the spec sees the fake, and a project minit wins there too
  local CS = dofile(dir .. "/child_support.lua")
  local cok, cerr = xpcall(function()
    local root = CS.new_root()
    local files = {
      ["TESTS/clip_spec.lua"] = ([[
return function(H)
  H.eq(vim.g.clipboard and vim.g.clipboard.name, %q, "the fake clipboard is installed before the spec")
  vim.fn.setreg("+", "testing_child_clipboard_spec_file_marker")
  H.eq(vim.fn.getreg("+"), "testing_child_clipboard_spec_file_marker", "+ round-trips")
end
]]):format(NAME),
    }
    local report = CS.run(root, CS.project(root, files, { "TESTS/clip_spec.lua" }))
    eq(
      CS.statuses(report),
      { "TESTS/clip_spec.lua:pass" },
      "the per-file child has the fake clipboard"
    )
    local case = CS.case_of(report, "TESTS/clip_spec.lua")
    eq(case and case.status, "pass", "and the case passed: " .. vim.inspect(case and case.message))

    local root2 = CS.new_root()
    local files2 = {
      ["TESTS/minimal_init.lua"] = "vim.g.clipboard = { name = 'project-own', copy = { ['+'] = function() end,"
        .. " ['*'] = function() end }, paste = { ['+'] = function() return {} end, ['*'] = function() return {} end } }\n",
      ["TESTS/own_spec.lua"] = [[
return function(H)
  H.eq(vim.g.clipboard and vim.g.clipboard.name, "project-own", "the minit's provider is the one in place")
end
]],
    }
    -- `CS.project` writes the entries only: the minit is written on its own
    CS.write(root2 .. "/TESTS/minimal_init.lua", files2["TESTS/minimal_init.lua"])
    local report2 = CS.run(
      root2,
      CS.project(root2, files2, { "TESTS/own_spec.lua" }),
      { minit = root2 .. "/TESTS/minimal_init.lua" }
    )
    eq(
      CS.statuses(report2),
      { "TESTS/own_spec.lua:pass" },
      "a project minit wins in the per-file child: "
        .. vim.inspect(CS.case_of(report2, "TESTS/own_spec.lua"))
    )
  end, debug.traceback)
  CS.cleanup()
  if not cok then
    error(cerr, 0)
  end
end
