-- TESTS/testing/dialect_registry_spec.lua -- the dialect registry: one run_file per dialect, a name that
-- is no dialect becomes a visible error case, dialect A through the registry collects every failure.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local assert_mod = require("testing.core.assert")
  local dialect = require("testing.dialect")
  local sniff = require("testing.discover.sniff")

  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  ---@param path string
  ---@param mark string
  ---@return integer
  local function line_of(path, mark)
    for i, line in ipairs(vim.fn.readfile(path)) do
      if line:find("MARK:" .. mark, 1, true) then
        return i
      end
    end
    error("mark not found: " .. mark)
  end

  -- every name of the registry has a run_file; the names the sniffer knows are all runnable
  eq(dialect.NAMES, { "a", "b", "c", "d", "h", "busted" }, "the registry names")
  for _, name in ipairs(dialect.NAMES) do
    eq(type(dialect.get(name)), "function", "dialect " .. name .. " has a run_file")
  end
  for _, name in ipairs(sniff.DIALECTS) do
    ok(
      vim.tbl_contains(dialect.NAMES, name),
      "the sniffer's dialect " .. name .. " is in the registry"
    )
  end
  eq(dialect.get("unknown"), nil, "`unknown` is no dialect")
  eq(dialect.get("testing"), nil, "`testing` (the native dialect) is not a shim")
  eq(dialect.get("klingon"), nil, "a typo is no dialect")

  -- a name that is no dialect: one visible error case, the progress hook is told
  local told = {}
  local cases = dialect.run_file("klingon", assert_mod.new(), {
    path = here .. "/fixtures/a_fail.fixture.lua",
    rel = "TESTS/a_fail_spec.lua",
  }, {
    on_case = function(c)
      told[#told + 1] = c.id
    end,
  })
  eq(#cases, 1, "an unknown dialect yields one case, never zero")
  eq(cases[1].status, "error", "an error, not a pass and not a drop")
  has(cases[1].error.message, 'dialect "klingon"', "naming the dialect")
  eq(told, { "TESTS/a_fail_spec.lua::a_fail_spec.lua" }, "on_case was called with it")

  -- unrunnable(): the driver's tool for listed-but-missing and unknown files
  cases = dialect.unrunnable(
    assert_mod.new(),
    { path = "x", rel = "TESTS/ghost_spec.lua" },
    "listed in TESTS/run.lua but not on disk"
  )
  eq(cases[1].status, "error", "unrunnable() is an error case")
  eq(cases[1].id, "TESTS/ghost_spec.lua::ghost_spec.lua", "with the file's id")
  eq(
    cases[1].error.message,
    "listed in TESTS/run.lua but not on disk",
    "and the reason as its message"
  )

  -- dialect A through the registry: all failures of the file, with the fixture's own lines
  local path = here .. "/fixtures/a_fail.fixture.lua"
  local progress = 0
  cases = dialect.run_file("a", assert_mod.new(), { path = path, rel = "TESTS/a_fail_spec.lua" }, {
    on_case = function()
      progress = progress + 1
    end,
  })
  eq(progress, 1, "on_case is called once for a one-case dialect")
  eq(cases[1].status, "fail", "dialect a: failed checks fail the file")
  local failed = {}
  for _, rec in ipairs(cases[1].assertions) do
    if not rec.ok then
      failed[#failed + 1] = rec
    end
  end
  eq(#cases[1].assertions, 4, "all four checks of the fixture ran")
  eq(#failed, 2, "BOTH failures are visible (P1)")
  eq(failed[1].line, line_of(path, "a1"), "first failure: the fixture's own line")
  eq(failed[2].line, line_of(path, "a2"), "second failure: the fixture's own line")
  eq(failed[1].msg, "first wrong", "message")
end
