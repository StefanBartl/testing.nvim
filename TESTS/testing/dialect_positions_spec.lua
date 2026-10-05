-- TESTS/testing/dialect_positions_spec.lua -- case positions of describe/it files: the tree-sitter
-- backend and the regex fallback agree on formatted code, the fallback is reported, dynamic names
-- are kept as dynamic, comments and strings are no positions.

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
  local positions = require("testing.discover.positions")

  local TEXT = table.concat({
    "-- describe('commented out', function() end)", -- 1
    "describe('outer', function()", -- 2
    "  local s = \"it('in a string', function() end)\"", -- 3
    "  it('first', function()", -- 4
    "    assert.is_true(true)", -- 5
    "  end)", -- 6
    '  describe("inner", function()', -- 7
    "    it('deep one', function() end)", -- 8
    "    it('deep ' .. s, function() end)", -- 9
    "    pending('later')", -- 10
    "  end)", -- 11
    "  it('after inner', function() end)", -- 12
    "end)", -- 13
    "context('second', function()", -- 14
    "  xit('skipped', function() end)", -- 15
    "  it('it\\'s quoted', function() end)", -- 16
    "end)", -- 17
  }, "\n")

  ---@param list Testing.Position[]
  ---@return string[]
  local function summary(list)
    local out = {}
    for _, p in ipairs(list) do
      out[#out + 1] = ("%d:%s:%s:%s"):format(
        p.line,
        p.kind,
        p.dynamic and "<dynamic>" or p.name,
        table.concat(p.path, "/")
      )
    end
    return out
  end

  local EXPECTED = {
    "2:describe:outer:",
    "4:it:first:outer",
    "7:describe:inner:outer",
    "8:it:deep one:outer/inner",
    "9:it:<dynamic>:outer/inner",
    "10:pending:later:outer/inner",
    "12:it:after inner:outer",
    "14:describe:second:",
    "15:pending:skipped:second",
    "16:it:it's quoted:second",
  }

  -- the regex backend (always available)
  local rx = positions.scan(TEXT, { backend = "regex" })
  eq(rx.backend, "regex", "regex backend answers as regex")
  has(rx.fallback_reason, "requested", "and says why")
  eq(
    summary(rx.positions),
    EXPECTED,
    "regex: kinds, names, lines and describe paths; comments and strings are no positions"
  )

  -- the default backend: tree-sitter where a lua parser loads, else the regex fallback with its reason
  local can_parse = pcall(vim.treesitter.get_string_parser, "local x = 1", "lua")
  local def = positions.scan(TEXT)
  eq(
    def.backend,
    can_parse and "treesitter" or "regex",
    "the default backend is tree-sitter exactly when a parser loads"
  )
  if can_parse then
    eq(def.fallback_reason, nil, "tree-sitter needs no fallback reason")
    eq(summary(def.positions), EXPECTED, "tree-sitter and regex agree on formatted code")
    -- nesting by the syntax tree does not depend on indentation
    local flat = positions.scan(
      "describe('a', function()\nit('b', function() end)\nend)\n",
      { backend = "treesitter" }
    )
    eq(
      summary(flat.positions),
      { "1:describe:a:", "2:it:b:a" },
      "tree-sitter nests without indentation"
    )
    local rx_flat = positions.scan(
      "describe('a', function()\nit('b', function() end)\nend)\n",
      { backend = "regex" }
    )
    eq(
      summary(rx_flat.positions),
      { "1:describe:a:", "2:it:b:" },
      "the regex fallback nests by indentation (its documented limit)"
    )
  else
    ok(def.fallback_reason ~= nil, "without a parser the fallback says why")
    eq(summary(def.positions), EXPECTED, "the fallback still answers")
  end

  -- a forced tree-sitter scan that cannot parse reports it instead of answering from the regex
  local forced = positions.scan(TEXT, { backend = "treesitter" })
  eq(forced.backend, "treesitter", "forced tree-sitter says tree-sitter")
  if not can_parse then
    eq(#forced.positions, 0, "and answers nothing when it cannot parse")
    ok(forced.fallback_reason ~= nil, "with the reason")
  end

  -- cases(): only it/pending, with the describe path, plus the scan for the backend
  local cases, scan = positions.cases(TEXT)
  eq(#cases, 7, "seven cases: it and pending, no describe")
  eq(cases[1].name, "first", "first case")
  eq(cases[1].path, { "outer" }, "its describe path")
  eq(cases[3].dynamic, true, "a dynamic name is kept as dynamic")
  eq(cases[3].name, nil, "with no name")
  eq(scan.backend, def.backend, "cases() reports the backend of its scan")

  -- the real fixture: the positions are the cases a dry run would run
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local text = table.concat(vim.fn.readfile(here .. "/fixtures/busted_mixed.fixture.lua"), "\n")
  for _, backend in ipairs({ "regex", "treesitter" }) do
    if backend == "regex" or can_parse then
      local list = positions.cases(text, { backend = backend })
      local names = {}
      for _, p in ipairs(list) do
        names[#names + 1] = p.name
      end
      eq(names, {
        "passes",
        "collects every failure of the body",
        "nested pass",
        "raises",
        "skips",
        "same name",
        "same name",
        "registered pending",
        "without a function",
        "uses has_no.errors and is_not",
      }, "fixture busted_mixed (" .. backend .. "): the cases a run reports, in order")
    end
  end

  -- a file with a syntax error and an empty text do not raise
  local broken = positions.scan("describe('x', function(")
  ok(type(broken.positions) == "table", "a syntax error does not raise")
  eq(positions.scan("").positions, {}, "an empty text has no positions")
end
