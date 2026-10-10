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

  -- a failed check inside a protected call the SPEC wrote raises (nothing recorded); outside one it is recorded
  local pctx = new_ctx()
  local asked_ok, asked_err
  local pcase = run(pctx, function()
    asked_ok, asked_err = pcall(function()
      pctx.eq(1, 2, "demo")
    end)
    pctx.eq(1, 2, "outside") -- recorded
    pctx.eq(1, 1, "holds")
  end)
  eq(asked_ok, false, "a failed eq inside the spec's pcall raises")
  eq(asked_err, "FAIL demo: expected 2, got 1", "with the message of the old harnesses")
  eq(#pcase.assertions, 2, "the raised check is not recorded, the other two are")
  eq(pcase.assertions[1].ok, false, "the failed check outside the pcall is recorded")
  eq(pctx.entry, nil, "the entry marker is gone with the case")
  local plain
  run(pctx, function()
    plain = pctx.eq(1, 2, "plain")
  end)
  eq(plain, false, "a failed eq in a plain body (only the runner's pcalls below) is recorded")

  -- a protected call of CODE UNDER TEST (another chunk than the spec) swallows the error: a raise there
  -- would make the failed check vanish and the case pass, so it is recorded. `load` gives the library a
  -- chunk name of its own, as a file of the plugin would have.
  local emitter = assert(load("local cb = ...; local ok = pcall(cb); return ok", "=plugin_emitter"))
  local lctx = new_ctx()
  local emitted
  local lcase = run(lctx, function()
    emitted = emitter(function()
      lctx.eq(1, 2, "in a callback the plugin protects")
    end)
    lctx.eq(1, 1, "holds")
  end)
  eq(emitted, true, "the plugin's pcall saw no error: the check did not raise")
  eq(lcase.status, "fail", "the failed check inside a plugin's pcall is not lost")
  eq(#lcase.assertions, 2, "it is recorded next to the check that holds")
  eq(lcase.assertions[1].ok, false, "as a failure")
  -- the protected call that CATCHES the raise decides, not any protected call of the spec on the stack:
  -- the plugin's pcall inside the spec's pcall would swallow the error and the check would vanish
  local nested_ok
  local ncase = run(new_ctx(), function(c)
    nested_ok = pcall(function()
      emitter(function()
        c.eq(1, 2, "the plugin's pcall is between the check and the spec's")
      end)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(
    nested_ok,
    true,
    "the spec's pcall saw no error: the plugin's pcall is the one that would catch it"
  )
  eq(ncase.status, "fail", "so the check was recorded, not lost")
  -- and a spec's pcall INSIDE the plugin's callback is the one that answers
  local inner_ok
  local icase = run(new_ctx(), function(c)
    emitter(function()
      inner_ok = pcall(function()
        c.eq(1, 2, "asked inside the callback")
      end)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(inner_ok, false, "a spec's pcall inside a plugin's protected call is asked, and answers")
  eq(icase.status, "pass", "nothing is recorded for the check that was asked")

  -- ---------------------------------------------------------------------------------------------
  -- review of fbcba7d: what the rule must not guess. Every case below records (the loud, safe answer)
  -- except where it says the spec is answered.
  local protected = require("testing.core.protected")
  ---@param code string
  ---@param chunk string chunk name, as the loader of a plugin's file would give it
  ---@return function
  local function plugin(code, chunk)
    return assert(load(code, chunk))
  end
  -- non-tail recursion: every level keeps its frame
  local function descend(depth, fn)
    if depth == 0 then
      return fn()
    end
    local r = descend(depth - 1, fn)
    return r
  end

  eq(protected.inside(nil), false, "no entry point (outside of a case): nothing to answer")
  local function linear_size()
    local n = 1
    while debug.getinfo(n + 1, "l") do
      n = n + 1
    end
    return n
  end
  for _, depth in ipairs({ 0, 1, 2, 3, 7, 64, 100, 513 }) do
    eq(
      descend(depth, function()
        return protected.stack_size()
      end),
      descend(depth, function()
        return linear_size()
      end),
      "stack_size() found by halving counts what a walk counts, depth " .. depth
    )
  end

  -- xpcall asks as well, and the handler sees the message
  local xok, xerr
  run(new_ctx(), function(c)
    xok, xerr = xpcall(function()
      c.eq(1, 2, "via xpcall")
    end, function(e)
      return "handled: " .. tostring(e)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(xok, false, "a failed eq inside the spec's xpcall raises")
  eq(xerr, "handled: FAIL via xpcall: expected 2, got 1", "and reaches the message handler")

  -- a pcall that was not called as `pcall` cannot be attributed: a plugin's helper that ends in
  -- `return pcall(cb)` (LuaJIT has no istailcall; the call site names the helper), an alias, and a
  -- spec's own tail-calling helper (documented: the spec fails loudly, the question is not answered)
  local tail_emitter = plugin("local cb = ...; return pcall(cb)", "=plugin_tail")
  local tctx = new_ctx()
  local tcase = run(tctx, function()
    tail_emitter(function()
      tctx.eq(1, 2, "swallowed by a plugin's tail-called pcall")
    end)
    tctx.eq(1, 1, "holds")
  end)
  eq(
    tcase.status,
    "fail",
    "a plugin's tail-called pcall is not taken for the spec's: the check is recorded"
  )
  local function asks_by_tail(fn)
    return pcall(fn)
  end
  local tail_ok
  local ocase = run(new_ctx(), function(c)
    tail_ok = asks_by_tail(function()
      c.eq(1, 2, "asked through a tail call")
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(tail_ok, true, "a tail-called pcall of the spec is not recognised as a question (documented)")
  eq(ocase.status, "fail", "so the check is recorded and the spec fails where the author sees it")
  local try = pcall
  local alias_ok
  local acase = run(new_ctx(), function(c)
    alias_ok = try(function()
      c.eq(1, 2, "asked through an alias")
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(alias_ok, true, "a pcall under another name is not recognised as a question")
  eq(acase.status, "fail", "and the check is recorded")

  -- a check that runs in a plugin's chunk is still answered when the spec's pcall is the one that catches:
  -- the lowest frame of the spec decides, not the highest
  local plugin_check = plugin("local c = ...; c.eq(1, 2, 'from plugin code')", "=plugin_check")
  local pc_ok
  run(new_ctx(), function(c)
    pc_ok = pcall(function()
      plugin_check(c)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(pc_ok, false, "the check runs in the plugin, the spec's pcall asks and gets the raise")

  -- another coroutine than the one that started the case: stack heights cannot be compared, always record
  local cctx = new_ctx()
  local ccase = run(cctx, function()
    for depth = 0, 200 do
      coroutine.wrap(function()
        descend(depth, function()
          emitter(function()
            cctx.eq(1, 2, "coroutine depth " .. depth)
          end)
        end)
      end)()
    end
  end)
  local cfailed = 0
  for _, rec in ipairs(ccase.assertions) do
    if not rec.ok then
      cfailed = cfailed + 1
    end
  end
  eq(cfailed, 201, "no depth of a plugin's coroutine makes a failed check vanish")

  -- a plugin that recurses deeper than the search window: the answer is "record", at any depth
  local recursive = plugin(
    [[
    local depth, cb = ...
    local function go(n)
      if n == 0 then
        local ok = pcall(cb)
        return ok
      end
      local r = go(n - 1)
      return r
    end
    return go(depth)
  ]],
    "=plugin_recursive"
  )
  for _, depth in ipairs({ 5, 250, 1200 }) do
    local rctx = new_ctx()
    local rcase = run(rctx, function()
      recursive(depth, function()
        rctx.eq(1, 2, "deep in a plugin, depth " .. depth)
      end)
      rctx.eq(1, 1, "holds")
    end)
    eq(rcase.status, "fail", "a plugin " .. depth .. " frames deep does not swallow the check")
  end

  -- the runner is a directory, not a substring of the path
  local spec_below_testing = plugin(
    [[
    local c = ...
    local ok = pcall(function()
      c.eq(1, 2, "asked")
    end)
    c.ok(not ok, "a spec below a lua/testing/ path is answered")
  ]],
    "@/home/dev/neolua/testing/proj/TESTS/ask_spec.lua"
  )
  eq(
    run(new_ctx(), spec_below_testing).status,
    "pass",
    "the spec's own path does not make it the runner"
  )
  local plugin_below_testing = plugin(
    "local cb = ...; local ok = pcall(cb); return ok",
    "@/home/dev/plugins/foo/lua/testing/emit.lua"
  )
  local wctx = new_ctx()
  local wcase = run(wctx, function()
    pcall(function()
      plugin_below_testing(function()
        wctx.eq(1, 2, "swallowed by a plugin whose modules live in a lua/testing/")
      end)
    end)
    wctx.eq(1, 1, "holds")
  end)
  eq(wcase.status, "fail", "a plugin below lua/testing/ is not taken for the runner")

  -- an explicit failure (the negated checks of the luassert shim) answers the spec's question too
  local fail_ok, fail_err
  local fcase = run(new_ctx(), function(c)
    fail_ok, fail_err = pcall(function()
      c.fail("explicit")
    end)
    c.fail("recorded")
  end)
  eq(fail_ok, false, "a.fail inside the spec's pcall raises")
  eq(fail_err, "explicit", "with its message")
  eq(#fcase.assertions, 1, "and only the plain one is recorded")

  -- a protected call nobody can attribute ends the search: the spec's pcall further out must not take over
  -- (its raise would be swallowed by the pcall in between)
  local alias_plugin =
    plugin("local cb = ...; local try = pcall; local ok = try(cb); return ok", "=plugin_alias")
  local field_plugin = { pcall = plugin("local cb = ...; return pcall(cb)", "=plugin_field") }
  ---@param label string
  ---@param ask fun(c: Testing.Assert.Context)
  local function unattributed_inside_spec_pcall(label, ask)
    local uctx = new_ctx()
    local outer_ok
    local ucase = run(uctx, function(c)
      outer_ok = pcall(function()
        ask(c)
      end)
      c.eq(1, 1, "holds")
    end)
    eq(outer_ok, true, label .. ": the spec's pcall saw no error, the plugin's is the catch")
    eq(ucase.status, "fail", label .. ": the check is recorded, not lost")
  end
  unattributed_inside_spec_pcall("tail call", function(c)
    tail_emitter(function()
      c.eq(1, 2, "x")
    end)
  end)
  unattributed_inside_spec_pcall("alias", function(c)
    alias_plugin(function()
      c.eq(1, 2, "x")
    end)
  end)
  unattributed_inside_spec_pcall("a field called pcall", function(c)
    field_plugin.pcall(function()
      c.eq(1, 2, "x")
    end)
  end)
  unattributed_inside_spec_pcall("pcall(pcall, f)", function(c)
    pcall(pcall, function()
      c.eq(1, 2, "x")
    end)
  end)

  -- a case that starts on a coroutine and asks there is answered (the thread is the one that entered)
  local co_asked
  coroutine.wrap(function()
    run(new_ctx(), function(c)
      co_asked = pcall(function()
        c.eq(1, 2, "asked on the case's own coroutine")
      end)
      c.ok(true, "keeps the case valid")
    end)
  end)()
  eq(co_asked, false, "the question is answered on the coroutine that entered the case")

  -- a C function that only calls back (table.sort) passes the error on: it is not a protected call
  local sort_ok
  run(new_ctx(), function(c)
    sort_ok = pcall(function()
      table.sort({ 3, 2, 1 }, function(x, y)
        c.eq(1, 2, "in a comparator")
        return x < y
      end)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(sort_ok, false, "the question reaches the spec's pcall through table.sort")

  -- the runner is told by its directory, with the separators of any platform; a neighbour below lua/ is not it
  local runner_file = debug.getinfo(protected.inside, "S").source:sub(2):gsub("\\", "/")
  local runner_dir =
    assert(runner_file:match("^(.*/lua/testing/)core/protected%.lua$"), "runner directory")
  local runner_like = plugin(
    "local cb = ...; local ok, err = pcall(cb); if not ok then error(err, 0) end",
    "@" .. runner_dir:gsub("/", "\\") .. "run\\x.lua"
  )
  local passes_ok
  local pass_case = run(new_ctx(), function(c)
    passes_ok = pcall(function()
      runner_like(function()
        c.eq(1, 2, "through a runner chunk named with backslashes")
      end)
    end)
    c.ok(true, "keeps the case valid")
  end)
  eq(passes_ok, false, "a chunk below the runner directory passes the error on, backslashes or not")
  eq(pass_case.status, "pass", "and nothing was recorded for the question")
  local neighbour = plugin(
    "local cb = ...; local ok = pcall(cb); return ok",
    "@" .. runner_dir:match("^(.*/lua/)testing/$") .. "otherplugin/emit.lua"
  )
  local nctx = new_ctx()
  local ncase2 = run(nctx, function()
    pcall(function()
      neighbour(function()
        nctx.eq(1, 2, "swallowed by a plugin next to the runner")
      end)
    end)
    nctx.eq(1, 1, "holds")
  end)
  eq(ncase2.status, "fail", "a plugin in a sibling directory of lua/testing/ is not the runner")

  -- the search stops 500 frames above the entry point: a question further out records, one nearer is answered
  for _, row in ipairs({ { 100, false, "pass" }, { 700, true, "fail" } }) do
    local depth, kept, status = row[1], row[2], row[3]
    local got
    local dcase = run(new_ctx(), function(c)
      got = pcall(function()
        descend(depth, function()
          c.eq(1, 2, "asked " .. depth .. " frames deep")
        end)
      end)
      c.ok(true, "keeps the case valid")
    end)
    eq(got, kept, "a spec's pcall " .. depth .. " frames above the check")
    eq(dcase.status, status, "and the verdict of the case")
  end

  -- messages without a text of their own
  local bare_eq
  run(new_ctx(), function(c)
    local _, failure = pcall(function()
      c.eq(1, 2)
    end)
    bare_eq = failure
    c.ok(true, "keeps the case valid")
  end)
  eq(bare_eq, "FAIL : expected 2, got 1", "a failed eq without a message")
  local bare_fail
  run(new_ctx(), function(c)
    local _, failure = pcall(function()
      c.fail(nil)
    end)
    bare_fail = failure
    c.ok(true, "keeps the case valid")
  end)
  eq(bare_fail, "FAIL", "an explicit failure without a message")

  -- the dialect hands over the spec's file: a wrapper of another file that runs the spec under its own
  -- pcall is not the spec's pcall, whatever frame sits lowest; a question the spec asks itself is answered
  -- even when a foreign body starts it
  local make_wrapper = plugin(
    "local spec = ...; return function(c) local ok = pcall(spec, c); return ok end",
    "=support_wrapper"
  )
  local wrapped_spec = plugin(
    "local c = ...; c.eq(1, 1, 'a'); c.eq(1, 2, 'a failing check'); c.eq(2, 2, 'c')",
    "@/home/dev/proj/TESTS/wrapped_spec.lua"
  )
  local wrapped_case = new_ctx().run_case({
    file = "TESTS/wrapped_spec.lua",
    name = "wrapped",
    spec_path = "/home/dev/proj/TESTS/wrapped_spec.lua",
  }, make_wrapper(wrapped_spec))
  eq(
    wrapped_case.status,
    "fail",
    "the wrapper's pcall swallows nothing: the failed check is recorded"
  )
  local asking_spec = plugin(
    "local c = ...; local ok = pcall(function() c.eq(1, 2, 'asked') end); c.ok(not ok, 'answered')",
    "@/home/dev/proj/TESTS/asking_spec.lua"
  )
  local asking_case = new_ctx().run_case({
    file = "TESTS/asking_spec.lua",
    name = "asking",
    spec_path = "/home/dev/proj/TESTS/asking_spec.lua",
  }, function(c)
    asking_spec(c)
  end)
  eq(
    asking_case.status,
    "pass",
    "a question in the spec's file is answered, though a foreign body started it"
  )

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
