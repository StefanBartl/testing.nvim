-- TESTS/testing/core_assert_spec.lua -- testing.core.assert: collecting assertions, case binding,
-- location capture, thrown errors, and the zero-assertion rule.

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

  ---A context with a deterministic clock: every reading is 5 ms after the previous one.
  ---@return Testing.Assert.Context
  local function new_ctx()
    local t = -5
    return assert_mod.new({
      clock = function()
        t = t + 5
        return t
      end,
    })
  end

  ---@param ctx Testing.Assert.Context
  ---@param body Testing.Assert.CaseBody
  ---@param finish? Testing.Result.FinishOpts
  ---@return Testing.Result.Case
  local function run(ctx, body, finish)
    return ctx.run_case({ file = "TESTS/x_spec.lua", name = "case" }, body, finish)
  end

  -- ---------------------------------------------------------------------------------------------
  -- P1: every failure of a file is visible, the body keeps running
  local a = new_ctx()
  local reached_end = false
  local case = run(a, function(c)
    c.eq(1, 2, "first")
    c.eq("a", "a", "holds")
    c.eq({ 1 }, { 1 }, "tables are compared by identity with eq")
    c.ok(false, "third")
    c.same({ x = { 1, 2 } }, { x = { 1, 3 } }, "fourth")
    reached_end = true
  end)
  ok(reached_end, "a failed assertion does not stop the body")
  eq(case.status, "fail", "a failed assertion makes the case fail")
  eq(#case.assertions, 5, "all assertions are recorded")
  local failed = {}
  for _, rec in ipairs(case.assertions) do
    if not rec.ok then
      failed[#failed + 1] = rec.msg
    end
  end
  eq(
    failed,
    { "first", "tables are compared by identity with eq", "third", "fourth" },
    "four failures, in order"
  )
  eq(case.assertions[1].expected, "2", "the failing record carries the printable expected value")
  eq(case.assertions[1].actual, "1", "the failing record carries the printable actual value")
  eq(case.assertions[1].kind, "eq", "the record names the kind")
  eq(case.assertions[2].expected, nil, "a passing record carries no expected (cheap)")
  eq(case.assertions[2].actual, nil, "a passing record carries no actual (cheap)")
  eq(case.assertions[5].expected, "{x = {1, 3}}", "nested values print deterministically")
  eq(case.assertions[5].actual, "{x = {1, 2}}", "nested actual prints deterministically")
  eq(case.duration_ms, 5, "the injected clock drives the duration")

  -- the generated message when the caller gives none
  a = new_ctx()
  case = run(a, function(c)
    c.eq(1, 2)
  end)
  eq(
    case.assertions[1].msg,
    "expected 2, got 1",
    "a failure without a message gets a generated one"
  )

  -- return values
  a = new_ctx()
  local returns = {}
  run(a, function(c)
    returns[1] = c.eq(1, 1)
    returns[2] = c.eq(1, 2)
    returns[3] = c.ok(nil)
  end)
  eq(returns, { true, false, false }, "every assertion returns whether it held")

  -- ---------------------------------------------------------------------------------------------
  -- Location: file and line of the caller, per call
  a = new_ctx()
  local line_of_call
  case = run(a, function(c)
    line_of_call = debug.getinfo(1, "l").currentline + 1
    c.eq(1, 2, "located")
  end)
  eq(case.assertions[1].line, line_of_call, "the line is the one of the assertion call")
  has(case.assertions[1].file, "core_assert_spec.lua", "the file is the one of the assertion call")
  ok(not case.assertions[1].file:find("\\", 1, true), "the file uses forward slashes")

  -- a wrapper that is not a tail call: depth skips its frame
  a = new_ctx()
  a.depth = 1
  local wrapper_line
  local function wrapper(actual, expected, msg)
    local r = a.eq(actual, expected, msg)
    return r
  end
  case = run(a, function()
    wrapper_line = debug.getinfo(1, "l").currentline + 1
    wrapper(1, 2, "via wrapper")
  end)
  eq(case.assertions[1].line, wrapper_line, "depth = 1 reports the caller of the wrapper")

  -- ---------------------------------------------------------------------------------------------
  -- Every kind: a pass and a failure, never an exception
  a = new_ctx()
  case = run(a, function(c)
    c.same({ 1, { b = 2 } }, { 1, { b = 2 } }, "same ok")
    c.deep_eq({ b = 2 }, { b = 2 }, "deep_eq ok")
    c.ok(1, "ok ok")
    c.not_ok(false, "not_ok ok")
    c.is_nil(nil, "is_nil ok")
    c.not_nil(0, "not_nil ok")
    c.matches("hello 42", "%d+", "matches ok")
    c.has("hello world", "o w", "has ok")
    c.error(function()
      error("kaboom")
    end, "kab", "error ok")
    c.error(function()
      error({ code = 1 })
    end, nil, "error with a table value ok")
    local passed, value = c.no_error(function()
      return 7
    end, "no_error ok")
    c.eq(value, 7, "no_error returns the result")
    c.ok(passed, "no_error returns true")
  end)
  eq(case.status, "pass", "all kinds hold -> pass")
  eq(#case.assertions, 13, "13 assertions recorded")
  for _, rec in ipairs(case.assertions) do
    ok(rec.ok, "passing: " .. tostring(rec.msg))
  end

  a = new_ctx()
  local results = {}
  case = run(a, function(c)
    results.same = c.same({ 1 }, { 2 })
    results.deep_eq = c.deep_eq({ a = 1 }, { a = 1, b = 2 })
    results.not_ok = c.not_ok("x")
    results.is_nil = c.is_nil(false)
    results.not_nil = c.not_nil(nil)
    results.matches = c.matches("abc", "%d")
    results.matches_type = c.matches(12, "%d")
    results.matches_bad = c.matches("abc", "[")
    results.has = c.has("abc", "z")
    results.has_type = c.has(nil, "z")
    results.err_none = c.error(function() end)
    results.err_pattern = c.error(function()
      error("one")
    end, "two")
    results.no_err, results.no_err_value = c.no_error(function()
      error("two")
    end)
    results.fail = c.fail("explicit")
  end)
  eq(case.status, "fail", "failing kinds -> fail, no exception escaped")
  eq(#case.assertions, 14, "14 failures recorded")
  for kind, held in pairs(results) do
    if kind ~= "no_err_value" then
      eq(held, false, "failed: " .. kind)
    end
  end
  eq(results.no_err_value, nil, "a failed no_error returns false, nil")
  for _, rec in ipairs(case.assertions) do
    ok(not rec.ok, "recorded as failure: " .. rec.kind)
    ok(type(rec.msg) == "string" and rec.msg ~= "", "a failure always has a message: " .. rec.kind)
  end
  eq(case.assertions[14].kind, "fail", "fail() has its own kind")
  eq(case.assertions[14].msg, "explicit", "fail() keeps the message")
  has(case.assertions[8].msg, "invalid pattern", "a malformed pattern is reported, not raised")
  has(case.assertions[11].msg, "got no error", "error() without a raise says so")

  -- eq is strict (identity for tables), same is deep
  a = new_ctx()
  run(a, function(c)
    results.eq_tables = c.eq({}, {})
    results.same_tables = c.same({}, {})
  end)
  eq(results.eq_tables, false, "eq compares tables by identity")
  eq(results.same_tables, true, "same compares tables deeply")

  -- ---------------------------------------------------------------------------------------------
  -- P4: no assertion at all is a failure with a clear message
  a = new_ctx()
  case = run(a, function() end)
  eq(case.status, "fail", "a case without assertions fails")
  eq(#case.assertions, 1, "one synthetic assertion explains why")
  eq(case.assertions[1].kind, "no_assertions", "the synthetic record names the rule")
  eq(case.assertions[1].ok, false, "the synthetic record is a failure")
  has(case.assertions[1].msg, "no assertions", "the message says what is wrong")

  case = run(new_ctx(), function() end, { expect_fail = true })
  eq(case.status, "fail", "an empty case is not an expected failure (xfail would hide the hole)")

  -- ---------------------------------------------------------------------------------------------
  -- A thrown error in the body: status error, traceback, earlier assertions kept
  a = new_ctx()
  local after_throw = false
  case = run(a, function(c)
    c.eq(1, 1, "before")
    error("boom")
    after_throw = true ---@diagnostic disable-line: unreachable-code
  end)
  eq(after_throw, false, "the body stops at the thrown error")
  eq(case.status, "error", "a thrown error is status=error, not fail")
  has(case.error.message, "boom", "the error carries its message")
  ok(not case.error.message:find("\n", 1, true), "the message is one line")
  has(
    case.error.traceback,
    "stack traceback",
    "the error carries a traceback (lib.lua.error.safe_call)"
  )
  eq(#case.assertions, 1, "assertions recorded before the throw are kept")
  eq(case.assertions[1].ok, true, "and keep their verdict")

  -- an error with no assertions is an error, not a no_assertions failure
  case = run(new_ctx(), function()
    error("early")
  end)
  eq(case.status, "error", "an error before any assertion stays an error")
  eq(#case.assertions, 0, "no synthetic assertion is added to an error")

  -- a non-string error value must not escape run_case
  case = run(new_ctx(), function()
    error({ code = 1 })
  end)
  eq(case.status, "error", "a table thrown by the body becomes status=error")
  has(case.error.message, "non-string", "and says it was not a string")

  -- the context is usable after an error
  a = new_ctx()
  run(a, function()
    error("first")
  end)
  case = run(a, function(c)
    c.ok(true, "second case")
  end)
  eq(case.status, "pass", "a thrown error leaves no case bound")

  -- ---------------------------------------------------------------------------------------------
  -- Case binding
  a = new_ctx()
  eq(a.current(), nil, "no case bound initially")
  local ok_call, err = pcall(a.eq, 1, 1, "orphan")
  eq(ok_call, false, "an assertion outside a case raises (a silent drop would hide failures)")
  has(err, "outside a case", "with a clear message")
  local end_raised, end_err = pcall(a.end_case)
  eq(end_raised, false, "end_case without begin_case raises")
  has(end_err, "without an open case", "with a clear message")

  local bound =
    a.begin_case({ file = "TESTS/y_spec.lua", describe = { "d1", "d2" }, name = "n", param = 3 })
  eq(a.current(), bound, "current() is the bound case")
  eq(bound.id, "TESTS/y_spec.lua::d1::d2::n#3", "the id follows file::describe::case#param")
  local begin_raised, begin_err = pcall(a.begin_case, { file = "z", name = "nested" })
  eq(begin_raised, false, "begin_case while a case is open raises")
  has(begin_err, "still open", "with a clear message")
  a.ok(true, "kept")
  local done = a.end_case()
  eq(done, bound, "end_case returns the same case table")
  eq(done.status, "pass", "and has finished it")
  eq(a.current(), nil, "end_case unbinds")

  -- inspect and deep_equal, the pure helpers
  local t1 = { b = 1, a = 2, 10, 20 }
  local t2 = { 10, 20, a = 2, b = 1 }
  eq(assert_mod.inspect(t1), assert_mod.inspect(t2), "inspect ignores insertion order")
  eq(assert_mod.inspect(t1), "{10, 20, a = 2, b = 1}", "array part first, then sorted keys")
  eq(assert_mod.inspect("a\nb"), '"a\\nb"', "strings are quoted and escaped")
  eq(assert_mod.inspect(1.5), "1.5", "floats keep their fraction")
  eq(assert_mod.inspect(3), "3", "integral numbers print without .0")
  eq(assert_mod.inspect(print), "<function>", "functions print without an address")
  local cyc = {}
  cyc.self = cyc
  eq(assert_mod.inspect(cyc), "{self = <cycle>}", "cycles are cut")
  ok(#assert_mod.inspect(string.rep("x", 5000)) < 2100, "long values are truncated")
  ok(assert_mod.deep_equal({ 1, { 2 } }, { 1, { 2 } }), "deep_equal: equal trees")
  ok(not assert_mod.deep_equal({ 1 }, { 1, 2 }), "deep_equal: extra element")
  ok(not assert_mod.deep_equal({ a = 1 }, { a = 1, b = 2 }), "deep_equal: extra key on the right")
  ok(not assert_mod.deep_equal({ a = 1, b = 2 }, { a = 1 }), "deep_equal: extra key on the left")
  ok(not assert_mod.deep_equal({ 1 }, "x"), "deep_equal: different types")
  local ca, cb = {}, {}
  ca.me, cb.me = ca, cb
  ok(assert_mod.deep_equal(ca, cb), "deep_equal terminates on cycles")
end
