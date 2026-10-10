-- TESTS/testing/dialect_project_conventions_spec.lua -- dialect h and the failure conventions of the
-- project's own harness: a collector (`H.check`), a failure list (`H.failures`), counters, printed
-- failure lines. The runner is never greener than the project's own harness.

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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local assert_mod = require("testing.core.assert")
  local dialect = require("testing.dialect")
  local project = require("testing.dialect.harness_project")
  local conventions = require("testing.dialect.harness_conventions")

  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local fx = here .. "/fixtures/hc"
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
  ---@param name string
  ---@param opts? table
  ---@return Testing.Result.Case case
  local function run(name, opts)
    -- the fixtures print their [OK]/[FAIL]/skip lines: keep them off the log of this very run
    local real_print = print
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function() end
    local called, cases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = fx .. "/" .. name .. ".fixture.lua",
      rel = "TESTS/" .. name .. "_spec.lua",
      harness = fx .. "/harness.lua",
    }, opts)
    _G.print = real_print
    assert(called, cases)
    eq(#cases, 1, name .. ": one case per file")
    return cases[1]
  end
  ---@param case Testing.Result.Case
  ---@return table[] failed
  ---@return integer passed
  local function split(case)
    local failed, passed = {}, 0
    for _, rec in ipairs(case.assertions) do
      if rec.ok then
        passed = passed + 1
      else
        failed[#failed + 1] = rec
      end
    end
    return failed, passed
  end

  -- ------------------------------------------------------------------ which conventions apply
  local resolved = conventions.resolve(dofile(fx .. "/harness.lua"))
  eq(
    resolved.names,
    { "fail_text", "check_collector", "failure_list", "counters", "printed_failures" },
    "the gopath-shaped harness follows every convention"
  )
  eq(resolved.collectors, { check = true }, "H.check is a collector")
  eq(resolved.lists, { "failures" }, "H.failures is a failure list (named once)")
  eq(resolved.pass_counters, { "checks", "assertions" }, "H.checks and H.assertions count")
  eq(resolved.fail_line("[FAIL] x: y"), true, "a [FAIL] line is a failure notice")
  eq(resolved.fail_line("  FAIL name"), true, "so is FAIL name")
  eq(resolved.fail_line("not ok 3 - x"), true, "and not ok")
  eq(resolved.fail_line("[ OK ] x"), false, "an OK line is not")
  eq(resolved.fail_line("this FAIL is in the middle"), false, "nor is a FAIL in the middle of text")
  local fixture_h = conventions.resolve(dofile(here .. "/fixtures/h/harness.lua"))
  eq(
    fixture_h.names,
    { "fail_text", "printed_failures" },
    "a FAIL-raising harness: only the text convention"
  )
  eq(fixture_h.collectors, {}, "no collector")
  eq(fixture_h.classify("a.lua:3: FAIL x: y").msg, "FAIL x: y", "classify strips the position")
  eq(fixture_h.classify("a.lua:3: FAIL x: y").line, 3, "and keeps the line")
  eq(
    fixture_h.classify("E:/x/a.lua:30: FAIL boom").file,
    "E:/x/a.lua",
    "a drive letter is no separator"
  )
  eq(fixture_h.classify("some other error"), nil, "any other error is not a failure")
  eq(fixture_h.classify({ "FAIL" }), nil, "a non-string error is not a failure")

  -- ------------------------------------------------------------------ the collector (gopath's H.check)
  -- a spec that tests the harness takes an EXPECTED failure back out of the failure list: the failure the collector
  -- recorded (and the line it printed) is withdrawn, and the check after it is judged on its own
  do
    local trimmed = run("trim")
    local trim_failed, trim_passed = split(trimmed)
    eq(#trim_failed, 0, "a failure taken back out of the list is gone")
    eq(trim_passed, 2, "the check after it holds (the collector and the assertion inside it)")
    eq(trimmed.status, "pass", "so the file passes")
  end

  local path = fx .. "/check_fail.fixture.lua"
  local case = run("check_fail")
  eq(case.status, "fail", "failed checks fail the file (the old false green)")
  eq(case.error, nil, "no error: the file ran to its end")
  local failed, passed = split(case)
  eq(#failed, 2, "both failing checks are visible, the passing one is not a failure")
  has(
    failed[1].msg,
    "fails first: first wrong: expected 2, got 1",
    "the callback's error text is the message"
  )
  eq(failed[1].line, line_of(path, "c1"), "the line is the failing assertion inside the check")
  eq(failed[1].kind, "check", "kind check")
  has(failed[1].file, "check_fail.fixture.lua", "in the spec file")
  has(
    failed[2].msg,
    "fails by raise: callback blew up",
    "a raise inside the callback is a failed check"
  )
  ok(
    not failed[1].msg:find("never reached", 1, true),
    "the assertion after the first failure never ran"
  )
  local kinds = {}
  for _, rec in ipairs(case.assertions) do
    kinds[#kinds + 1] = (rec.ok and "+" or "-") .. rec.kind
  end
  eq(
    kinds,
    { "+eq", "+check", "-check", "-check", "+eq" },
    "assertions in order: the eq inside a check, the check, two failed checks, the direct eq (double is no assertion)"
  )
  eq(passed, 3, "three passed records")

  -- nested assertion helpers: one failure, not two
  case = run("nested")
  failed = split(case)
  eq(case.status, "fail", "nested: red")
  eq(#failed, 1, "a failure inside a helper that calls assertions is ONE failure")
  has(failed[1].msg, "nested helper fails: twice wrong", "with the message")

  -- ------------------------------------------------------------------ never greener than the project
  case = run("direct_list")
  failed = split(case)
  eq(case.status, "fail", "a failure the harness collected behind the adapter's back is red")
  eq(#failed, 1, "exactly one record for it")
  eq(failed[1].kind, "project_failures", "of its own kind")
  has(failed[1].msg, "collected 1 failure(s) in H.failures", "saying what the harness did")
  has(failed[1].msg, "recorded behind the adapter's back", "and what it collected")

  case = run("printed")
  failed = split(case)
  eq(case.status, "fail", "a failure line the harness printed and recorded nowhere is red")
  eq(failed[1].kind, "project_failures", "of its own kind")
  has(failed[1].msg, "printed 1 failure line(s)", "naming the lines")
  has(failed[1].msg, "[FAIL] lost: shouted", "and showing the first")

  -- a failure line printed by the SPEC itself (outside the harness) is no harness failure
  local rel = "TESTS/own_print_spec.lua"
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.fn.readfile(fx .. "/harness.lua"), dir .. "/harness.lua")
  vim.fn.writefile({
    "return function(H)",
    '  H.eq(1, 1, "pass")',
    '  print("[FAIL] a report the spec is testing")',
    "end",
  }, dir .. "/own_print_spec.lua")
  local real_print = print
  ---@diagnostic disable-next-line: duplicate-set-field
  _G.print = function() end
  local called, own = pcall(
    dialect.run_file,
    "h",
    assert_mod.new(),
    { path = dir .. "/own_print_spec.lua", rel = rel, root = dir }
  )
  _G.print = real_print
  assert(called, own)
  case = own[1]
  eq(case.status, "pass", "a [FAIL] line the spec prints itself does not make the file red")

  -- ------------------------------------------------------------------ the assertion policy through dialect h
  case = run("empty")
  eq(case.status, "fail", "assertions = error (default): nothing asserted is a failure")
  has(case.assertions[1].msg, "no assertions", "and says so")
  case = run("empty", { assertions = "warn" })
  eq(case.status, "pass", "assertions = warn: a pass")
  eq(case.assertions[1].ok, true, "with a passing synthetic assertion (the IR stays valid)")
  eq(case.notes[#case.notes], "warning: case made no assertions", "and a warning note")
  case = run("skip")
  eq(case.status, "skip", "no assertions + a printed skip line: a skip, never green")
  has(case.reason, "optional dependency not found", "with the printed line as its reason")
  eq(#case.assertions, 0, "and no synthetic failure left")
  case = run("skip", { assertions = "warn" })
  eq(case.status, "skip", "the skip convention wins over the warn policy")

  -- ------------------------------------------------------------------ the adapter on a hand-built harness
  local function new_case_ctx()
    local a = assert_mod.new()
    a.begin_case({ file = "TESTS/x_spec.lua", name = "x" })
    return a
  end
  local a = new_case_ctx()
  local harness
  harness = {
    checks = 0,
    failures = {},
    check = function(name, fn)
      local fine = pcall(fn)
      if not fine then
        harness.failures[#harness.failures + 1] = name
      end
    end,
    boom = function()
      error("helper bug", 0)
    end,
  }
  local H2, state = project.new(a, harness, {})
  ok(rawequal(H2, harness), "the harness table is wrapped IN PLACE: one coherent object")
  H2.checks = H2.checks + 5
  eq(harness.checks, 5, "so a counter the spec bumps is the counter the harness sees")
  H2.check("one", function() end)
  eq(a.current().assertions[1].ok, true, "a collector call that collected nothing is a pass")
  H2.check("two", function()
    error("x", 0)
  end)
  eq(a.current().assertions[2].ok, false, "and one that collected a failure is a failure")
  has(a.current().assertions[2].msg, "two: x", "with the callback's error")
  local raised = pcall(H2.boom)
  eq(raised, false, "an error that is no failure propagates")
  eq(#a.current().assertions, 2, "and records nothing")
  project.reconcile(state)
  eq(#a.current().assertions, 2, "reconcile: every collected failure was seen, nothing is added")
  -- after the file ended the wrappers pass straight through
  local before = #a.current().assertions
  H2.check("late", function() end)
  eq(#a.current().assertions, before, "a late call is not recorded on whatever case is open")
  a.end_case()
  eq(
    select("#", H2.check("after the case", function() end)),
    0,
    "and survives with no case open at all"
  )

  -- a failure counter the harness bumps itself
  a = new_case_ctx()
  local counted = { failed = 0, bump = function() end }
  counted.bump = function()
    counted.failed = counted.failed + 1
  end
  local H3, state3 = project.new(a, counted, {})
  H3.bump()
  project.reconcile(state3)
  local f3 = split(a.current() --[[@as Testing.Result.Case]])
  eq(#f3, 1, "a failure counter that grew is a failure")
  has(f3[1].msg, "counted 1 failure(s)", "named")
  a.end_case()

  -- ------------------------------------------------------------------ a new convention is data
  local size = #conventions.CONVENTIONS
  conventions.register({
    name = "table_errors",
    classify = function(err)
      if type(err) == "table" and err.assertion then
        return { msg = "ASSERT " .. tostring(err.assertion) }
      end
      return nil
    end,
  })
  a = new_case_ctx()
  local custom = {
    must = function()
      error({ assertion = "custom shape" })
    end,
  }
  local H4 = project.new(a, custom, { must = true })
  eq(H4.must(), false, "a registered convention classifies a table error as a failed check")
  local f4 = split(a.current() --[[@as Testing.Result.Case]])
  eq(f4[1].msg, "ASSERT custom shape", "with its own message")
  a.end_case()
  for i = #conventions.CONVENTIONS, size + 1, -1 do
    conventions.CONVENTIONS[i] = nil
  end
  eq(#conventions.CONVENTIONS, size, "the registry is restored")
  assert(not pcall(conventions.register, "nope"), "register wants a table with a name")

  -- ------------------------------------------------------------------ a harness no convention knows
  -- (review V3): the project's own bookkeeping says "bad", the runner must too. Every one of these was
  -- GREEN before the generic net and the wider output capture.
  local unknown = here .. "/fixtures/hc_unknown"
  ---@param name string
  ---@return Testing.Result.Case
  local function run_unknown(name)
    local saved_print, saved_write = print, io.write
    local methods = getmetatable(io.stdout).__index
    local real_method = methods.write
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function() end
    rawset(io, "write", function() end)
    methods.write = function(self, ...)
      if self == io.stdout or self == io.stderr then
        return self
      end
      return real_method(self, ...)
    end
    local ran, cases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = unknown .. "/" .. name .. ".fixture.lua",
      rel = "TESTS/" .. name .. "_spec.lua",
      harness = unknown .. "/harness.lua",
    })
    _G.print, methods.write = saved_print, real_method
    rawset(io, "write", saved_write)
    assert(ran, cases)
    return cases[1]
  end
  local swallow = run_unknown("swallow")
  eq(
    swallow.status,
    "fail",
    "H.t swallows the error, bumps H.n_bad and io.writes FAIL: the file is red"
  )
  local sf = split(swallow)
  ok(#sf >= 1, "with at least one recorded failure")
  local texts = {}
  for _, rec in ipairs(sf) do
    texts[#texts + 1] = tostring(rec.msg)
  end
  has(table.concat(texts, " | "), "secretly broken", "that names the printed failure line")
  local lazy = run_unknown("lazy")
  eq(lazy.status, "fail", "a failure list that comes into existence during the file is caught")
  has(
    table.concat(
      vim.tbl_map(function(rec)
        return tostring(rec.msg)
      end, split(lazy)),
      " | "
    ),
    "H.late_errors",
    "and the field is named"
  )
  local quiet = run_unknown("quiet")
  eq(quiet.status, "fail", "a failure line written with io.stdout:write is seen")
  local failing = run_unknown("failing_check")
  eq(failing.status, "fail", "a harness check that counts and prints (no raise) is red")
  eq(#(split(failing)), 1, "as exactly one failure (counter and printed line are not added up)")
  local green = run_unknown("green")
  eq(green.status, "pass", "the same harness on a spec that fails nothing stays green")
  ok(
    conventions.looks_like_failure_field("n_bad") and conventions.looks_like_failure_field("Errors"),
    "the field name heuristic: bad / errors"
  )
  ok(
    not conventions.looks_like_failure_field("passed")
      and not conventions.looks_like_failure_field(3),
    "and does not take passed counters or non-names"
  )

  vim.fn.delete(dir, "rf")
end
