-- TESTS/testing/dialect_luassert_spec.lua -- the luassert subset of the busted dialect: argument order
-- (expected first), negations, messages, call sites, unsupported names, plain assert(), outside a case.

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
  local luassert = require("testing.dialect.luassert")

  ---Run `fn(A)` inside a case with the shim's `assert` object; answer the finished case.
  ---@param fn fun(A: table)
  ---@param is_spec_frame? fun(source: string): boolean
  ---@return Testing.Result.Case
  local function run(fn, is_spec_frame)
    local a = assert_mod.new()
    return a.run_case({ file = "TESTS/l_spec.lua", name = "x" }, function()
      local scope = a.scope()
      local A = luassert.new({
        scope = function()
          return scope
        end,
        is_spec_frame = is_spec_frame or function(source)
          return source:find("dialect_luassert_spec.lua", 1, true) ~= nil
        end,
      })
      fn(A)
    end)
  end
  ---@param case Testing.Result.Case
  ---@return boolean[]
  local function verdicts(case)
    local out = {}
    for _, rec in ipairs(case.assertions) do
      out[#out + 1] = rec.ok
    end
    return out
  end

  -- every assertion, holding and failing: (label, code, expected verdict). The code is compiled with
  -- the shim's `assert` object as `A`; one assertion each, so the verdict list has exactly one entry.
  local TABLE = {
    { "equal holds", "A.are.equal(1, 1)", true },
    { "equal fails", "A.are.equal(1, 2)", false },
    { "equals holds", 'A.equals("a", "a")', true },
    { "equals fails", 'A.equals("a", "b")', false },
    { "equal is strict: tables by identity", "A.are.equal({}, {})", false },
    { "same holds (deep)", "A.are.same({ 1, { 2 } }, { 1, { 2 } })", true },
    { "same fails", "A.same({ 1 }, { 2 })", false },
    { "is_true holds", "A.is_true(true)", true },
    { "is_true is strict: 1 is not true", "A.is_true(1)", false },
    { "is_false holds", "A.is_false(false)", true },
    { "is_false is strict: nil is not false", "A.is_false(nil)", false },
    { "truthy holds", "A.is_truthy(0)", true },
    { "truthy fails", "A.truthy(false)", false },
    { "falsy holds", "A.is_falsy(nil)", true },
    { "falsy fails", "A.falsy(1)", false },
    { "is_nil holds", "A.is_nil(nil)", true },
    { "is_nil fails", "A.is_nil(false)", false },
    { "is_not_nil holds", "A.is_not_nil(0)", true },
    { "is_not_nil fails", "A.is_not_nil(nil)", false },
    { "is_table holds", "A.is_table({})", true },
    { "is_table fails", 'A.is_table("x")', false },
    { "is_string holds", 'A.is_string("x")', true },
    { "is_string fails", "A.is_string(1)", false },
    { "is_function holds", "A.is_function(print)", true },
    { "is_function fails", "A.is_function({})", false },
    { "is_boolean holds", "A.is_boolean(false)", true },
    { "is_boolean fails", "A.is_boolean(nil)", false },
    { "is_number holds", "A.is_number(1.5)", true },
    { "is_number fails", 'A.is_number("1")', false },
    { "is_not.table holds", 'A.is_not.table("x")', true },
    { "matches: the PATTERN comes first", 'A.matches("^ab", "abc")', true },
    { "matches fails", 'A.matches("^z", "abc")', false },
    { "matches fails on the swapped order", 'A.matches("abc", "^ab")', false },
    { "matches takes a number", 'A.matches("^12", 123)', true },
    { "matches fails on a table", 'A.matches("x", {})', false },
    { "matches: plain flag", 'A.matches("a.c", "a.c", 1, true)', true },
    { "matches: plain flag is literal", 'A.matches("a.c", "abc", 1, true)', false },
    { "is_not.matches holds", 'A.is_not.matches("^z", "abc")', true },
    { "is_not.matches fails", 'A.is_not.matches("^a", "abc")', false },
    { "has_error holds", 'A.has_error(function() error("x") end)', true },
    { "has_error fails without an error", "A.has_error(function() end)", false },
    { "has_errors is the same", 'A.has_errors(function() error("x") end)', true },
    {
      "has_error with the message (position prefix stripped)",
      'A.has_error(function() error("boom") end, "boom")',
      true,
    },
    {
      "has_error with a message that differs",
      'A.has_error(function() error("boom") end, "other")',
      false,
    },
    {
      "has_error with a table error",
      "A.has_error(function() error({ code = 1 }) end, { code = 1 })",
      true,
    },
    { "has_no.errors holds", "A.has_no.errors(function() end)", true },
    { "has_no.errors fails", 'A.has_no.errors(function() error("x") end)', false },
    { "has_no.errors with a message", 'A.has_no.errors(function() end, "should not throw")', true },
    { "has.no.errors (dotted)", "A.has.no.errors(function() end)", true },
    { "are_not.equal holds", "A.are_not.equal(1, 2)", true },
    { "are_not.equal fails", "A.are_not.equal(1, 1)", false },
    { "is_not.equals holds", "A.is_not.equals(1, 2)", true },
    { "not_equals holds", "A.not_equals(1, 2)", true },
    { "is_not.same holds", "A.is_not.same({ 1 }, { 2 })", true },
    { "is_not.same fails", "A.is_not.same({ 1 }, { 1 })", false },
    {
      "is_not.same on a table that raises while it is compared fails",
      "A.is_not.same(setmetatable({ a = 1 }, { __index = function() error('strict') end }), { a = 1, b = 2 })",
      false,
    },
    { "is_not.truthy holds", "A.is_not.truthy(nil)", true },
    { "is_not_true holds", "A.is_not_true(1)", true },
    { "is_not_false fails", "A.is_not_false(false)", false },
    { "near holds", "A.near(1.0, 1.05, 0.1)", true },
    { "near fails", "A.near(1.0, 2.0, 0.1)", false },
    { "double negation: is_not.not_equal", "A.is_not.not_equal(1, 1)", true },
  }
  for _, row in ipairs(TABLE) do
    local label, code, want = row[1], row[2], row[3]
    local chunk = assert(loadstring("local A = ... " .. code, "=" .. label))
    local case = run(function(A)
      chunk(A)
    end)
    eq(case.error, nil, label .. ": the assertion itself never raises")
    eq(verdicts(case), { want }, label)
  end

  -- argument order: luassert's expected comes first, the kernel's actual first
  local case = run(function(A)
    A.are.equal("EXPECTED", "ACTUAL")
    A.are.same({ 1 }, { 2 })
  end)
  eq(case.assertions[1].expected, '"EXPECTED"', "equal: expected = first argument")
  eq(case.assertions[1].actual, '"ACTUAL"', "equal: actual = second argument")
  eq(case.assertions[2].expected, "{1}", "same: expected = first argument")
  eq(case.assertions[2].actual, "{2}", "same: actual = second argument")

  -- messages: the caller's message survives, a generated one names both values
  case = run(function(A)
    A.are.equal(1, 2, "custom message")
    A.is_true(false, "custom true")
    A.are_not.equal(3, 3, "custom negation")
    A.are_not.equal(3, 3)
    A.has_error(function() end, nil, "custom error")
  end)
  eq(case.assertions[1].msg, "custom message", "equal: caller message")
  eq(case.assertions[2].msg, "custom true", "is_true: caller message")
  eq(case.assertions[3].msg, "custom negation", "negated equal: caller message")
  has(case.assertions[4].msg, "expected values to differ", "negated equal: generated message")
  eq(case.assertions[5].msg, "custom error", "has_error: caller message")

  -- the call site is the caller's own line, also through the negation chain and has_no
  local lines = {}
  case = run(function(A)
    lines[1] = debug.getinfo(1, "l").currentline + 1
    A.are.equal(1, 2)
    lines[2] = debug.getinfo(1, "l").currentline + 1
    A.is_not.equal(1, 1)
    lines[3] = debug.getinfo(1, "l").currentline + 1
    A.has_no.errors(function()
      error("x")
    end)
    lines[4] = debug.getinfo(1, "l").currentline + 1
    A.is_true(false)
  end)
  eq(
    vim.tbl_map(function(rec)
      return rec.line
    end, case.assertions),
    lines,
    "every failure carries the line of the call"
  )
  has(case.assertions[1].file, "dialect_luassert_spec.lua", "and this file")

  -- unsupported assertions raise a clear error naming them; they never pass
  for _, name in ipairs({ "unique", "spy", "stub", "True" }) do
    local got, err = pcall(function()
      return run(function(A)
        local _ = A.are[name]
      end).error
    end)
    ok(got, "reading an unsupported name inside a case does not take the runner down: " .. name)
    has(err and err.message or "", "not supported", "the case ends in an error naming it: " .. name)
    has(err and err.message or "", name, "the message names " .. name)
  end
  local supported = luassert.supported()
  ok(vim.tbl_contains(supported, "equal"), "supported() lists equal")
  ok(not vim.tbl_contains(supported, "spy"), "supported() does not list spy")

  -- plain assert(): the builtin's contract; calls from the spec file are recorded
  case = run(function(A)
    local a, b = A(1, "two")
    local fh = A(io.open(vim.fn.tempname(), "wb"))
    fh:close()
    ok(a == 1 and b == "two", "assert returns its arguments")
  end)
  eq(#case.assertions, 2, "two plain assert() calls from the spec file, two records")
  eq(verdicts(case), { true, true }, "both held")
  case = run(function(A)
    A(true)
  end, function()
    return false
  end)
  eq(
    vim.tbl_map(function(rec)
      return rec.kind
    end, case.assertions),
    { "no_assertions" },
    "a call from another file (plugin code) is not the test's assertion: only the kernel's no-assertion record remains"
  )
  eq(case.status, "fail", "so a case whose only assertions came from plugin code fails (P4)")
  case = run(function(A)
    A(false, "plain failure")
  end)
  eq(case.status, "error", "a failing plain assert raises")
  eq(case.error.message, "plain failure", "with its own message")
  case = run(function(A)
    A(nil)
  end)
  eq(case.error.message, "assertion failed!", "the builtin's default message")

  -- outside any case: a held check is silent, a failed one raises (what luassert did there)
  local A_outside = luassert.new({
    scope = function()
      return nil
    end,
    is_spec_frame = function()
      return true
    end,
  })
  local called = pcall(function()
    A_outside.is_true(true)
    A_outside.are.equal(1, 1)
  end)
  eq(called, true, "held checks outside a case are silent")
  local err
  called, err = pcall(function()
    A_outside.are.equal(1, 2)
  end)
  eq(called, false, "a failed check outside a case raises")
  has(err, "expected 1, got 2", "with the generated message")
  called = pcall(function()
    A_outside.has_no.errors(function()
      error("inner")
    end)
  end)
  eq(called, false, "has_no.errors outside a case raises when the function raises")
end
