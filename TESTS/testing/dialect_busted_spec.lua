-- TESTS/testing/dialect_busted_spec.lua -- dialect E (plenary.busted): describe/it cases are reported
-- one by one with stable ids, hooks run in the plenary order, every failure of a body is collected,
-- unsupported constructs fail loudly, nothing leaks into the globals.
---@diagnostic disable: need-check-nil

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
  local result = require("testing.core.result")
  local dialect = require("testing.dialect")
  local busted = require("testing.dialect.busted")

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

  ---@param name string
  ---@param opts? table
  ---@return Testing.Result.Case[] cases, table[]|nil list, string[] trace
  local function run(name, opts)
    _G.__TESTING_FIXTURE_TRACE = {}
    local a = assert_mod.new()
    local cases, list = dialect.run_file("busted", a, {
      path = here .. "/fixtures/" .. name .. ".fixture.lua",
      rel = "TESTS/" .. name .. "_spec.lua",
    }, opts)
    local trace = _G.__TESTING_FIXTURE_TRACE
    _G.__TESTING_FIXTURE_TRACE = nil
    return cases, list, trace
  end
  ---@param cases Testing.Result.Case[]
  ---@return table<string, Testing.Result.Case>
  local function by_id(cases)
    local map = {}
    for _, c in ipairs(cases) do
      map[c.id] = c
    end
    return map
  end

  -- ------------------------------------------------------------------ a framework of another file wraps the it body
  local wrap_path = here .. "/fixtures/busted_wrap.fixture.lua"
  local wrap_cases = run("busted_wrap")
  local W = "TESTS/busted_wrap_spec.lua::wrapped::"
  local wmap = by_id(wrap_cases)
  local swallowed = wmap[W .. "swallowed by the framework"]
  eq(
    swallowed.status,
    "fail",
    "the framework's pcall is not the spec's: the failed check is recorded"
  )
  eq(swallowed.assertions[1].line, line_of(wrap_path, "w1"), "with the spec's line")
  eq(wmap[W .. "asks itself"].status, "pass", "a question the spec asks itself is answered")

  -- ------------------------------------------------------------------ a check in the message handler of an xpcall
  local handler_path = here .. "/fixtures/busted_handler.fixture.lua"
  local hmap = by_id(run("busted_handler"))
  local HP = "TESTS/busted_handler_spec.lua::handler::"
  for _, row in ipairs({
    { "after error", "h1" },
    { "after a wrap rethrow", "h2" },
    { "after a failing require", "h3" },
  }) do
    local handled = hmap[HP .. row[1]]
    eq(handled.status, "fail", row[1] .. ": the failed check in the handler is recorded, not lost")
    eq(
      handled.assertions[1].line,
      line_of(handler_path, row[2]),
      row[1] .. ": with the spec's line"
    )
  end
  eq(
    hmap[HP .. "in the body"].status,
    "pass",
    "a check in the body of the xpcall is raised and answered"
  )

  local globals_before = {}
  for _, name in ipairs({
    "describe",
    "it",
    "assert",
    "pending",
    "before_each",
    "after_each",
    "stub",
  }) do
    globals_before[name] = rawget(_G, name)
  end
  local loaded_luassert = package.loaded["luassert"]

  -- ------------------------------------------------------------------ the mixed fixture
  local path = here .. "/fixtures/busted_mixed.fixture.lua"
  local cases, _, trace = run("busted_mixed")
  local P = "TESTS/busted_mixed_spec.lua::"
  local ids = {}
  for _, c in ipairs(cases) do
    ids[#ids + 1] = c.id
  end
  eq(
    ids,
    {
      P .. "outer::passes",
      P .. "outer::collects every failure of the body",
      P .. "outer::inner::nested pass",
      P .. "outer::inner::raises",
      P .. "outer::inner::skips",
      P .. "outer::inner::same name",
      P .. "outer::inner::same name#2",
      P .. "outer::registered pending",
      P .. "outer::without a function",
      P .. "second::uses has_no.errors and is_not",
    },
    "describe/it cases are reported separately, with stable ids file::describe::case, in source order"
  )
  local map = by_id(cases)
  eq(map[P .. "outer::passes"].status, "pass", "a passing it is a pass")
  eq(#map[P .. "outer::passes"].assertions, 2, "its two assertions are recorded")

  local collect = map[P .. "outer::collects every failure of the body"]
  eq(collect.status, "fail", "a failed assertion fails the case")
  local lines = {}
  for _, rec in ipairs(collect.assertions) do
    if not rec.ok then
      lines[#lines + 1] = rec.line
    end
  end
  eq(#collect.assertions, 4, "all four assertions of the body ran (a failure does not stop it)")
  eq(
    lines,
    { line_of(path, "e1"), line_of(path, "e2"), line_of(path, "e3") },
    "the three failures carry the spec's own lines"
  )
  has(
    collect.assertions[1].msg,
    "expected 1",
    "luassert's expected comes first: the message says it"
  )
  eq(collect.assertions[1].expected, "1", "expected = the first argument of are.equal")
  eq(collect.assertions[1].actual, "2", "actual = the second argument of are.equal")
  eq(collect.line, line_of(path, "e1") - 1, "the case carries the line of its it() call")

  local raises = map[P .. "outer::inner::raises"]
  eq(raises.status, "error", "a raise ends the case as error")
  eq(#raises.assertions, 1, "the assertion before the raise is kept")
  has(raises.error.message, "boom", "the message of the raise")
  eq(
    map[P .. "outer::inner::skips"].status,
    "skip",
    "pending() inside a body skips the case (never green)"
  )
  eq(map[P .. "outer::inner::skips"].reason, "not today", "with the reason")
  eq(
    #map[P .. "outer::inner::skips"].assertions,
    0,
    "the body stopped at pending(): the assertion after it never ran"
  )
  eq(
    map[P .. "outer::registered pending"].status,
    "skip",
    "pending(name) outside a body registers a skipped case"
  )
  eq(map[P .. "outer::without a function"].status, "skip", "it(name) without a function is skipped")
  eq(
    map[P .. "outer::inner::same name"].status,
    "pass",
    "the first of two same-named cases keeps the plain id"
  )
  eq(map[P .. "outer::inner::same name#2"].status, "pass", "the second gets #2: ids stay unique")
  eq(
    map[P .. "second::uses has_no.errors and is_not"].status,
    "pass",
    "negations and has_no.errors hold"
  )
  eq(
    #map[P .. "second::uses has_no.errors and is_not"].assertions,
    6,
    "all six of them were recorded"
  )

  -- hook order: before_each outermost first, after_each in plenary's order (outermost first), always
  eq(vim.list_slice(trace, 1, 8), {
    "outer:before",
    "outer:after",
    "outer:before",
    "outer:after",
    "outer:before",
    "inner:before",
    "outer:after",
    "inner:after",
  }, "before_each / after_each run around every it, outer block first")

  -- the IR is the real one: ids unique, a summary that counts all statuses
  local res = result.new({})
  for _, c in ipairs(cases) do
    result.add_case(res, c)
  end
  result.finalize(res)
  eq(res.summary.pass, 5, "summary: five passes")
  eq(res.summary.fail, 1, "summary: one fail")
  eq(res.summary.error, 1, "summary: one error")
  eq(res.summary.skip, 3, "summary: three skips (skips are counted, never green)")
  -- the recorded assertion files are real paths of this checkout: normalize them as a report does
  -- (a checkout below /home/<user> or /Users/<user> is a home path until it is a placeholder)
  local host_ci = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
  -- the traceback also names lib.nvim's frames: a checkout outside the repo and outside $HOME (HOME set elsewhere:
  -- sudo, a sandbox) would keep its /home/<user> path; the roots have no name for a dependency, <TMP> is "elsewhere"
  local deps = require("testing.deps")
  local lib = assert(deps.resolve("lib.nvim", deps.self_dir()))
  local encoded = assert(result.encode(res, {
    roots = {
      repo = vim.fs.dirname(vim.fs.dirname(here)),
      home = vim.uv.os_homedir(),
      tmp = lib.dir,
    },
    case_insensitive = host_ci,
  }))
  local good, problems = result.validate(vim.json.decode(encoded))
  ok(good, "the busted cases validate as IR: " .. table.concat(problems or {}, "; "))

  -- ------------------------------------------------------------------ select and dry
  local selected = run("busted_mixed", {
    select = function(id)
      return id:find("::inner::", 1, true) ~= nil and not id:find("same name", 1, true)
    end,
  })
  eq(#selected, 3, "select() runs only the cases it accepts")
  local _, listed, dry_trace = run("busted_mixed", { dry = true })
  eq(#listed, 10, "dry mode lists every case that would run")
  eq(listed[1].id, P .. "outer::passes", "dry mode: ids as in a real run")
  eq(listed[1].name, "passes", "dry mode: the case name")
  eq(listed[1].describe, { "outer" }, "dry mode: the describe path")
  eq(dry_trace, {}, "dry mode runs no it() body and no hook")
  local progress = {}
  run("busted_mixed", {
    on_case = function(c)
      progress[#progress + 1] = c.status
    end,
  })
  eq(#progress, 10, "on_case is called once per case")

  -- ------------------------------------------------------------------ hooks and everything outside an it
  cases, _, trace = run("busted_hooks")
  local H_ = "TESTS/busted_hooks_spec.lua::"
  map = by_id(cases)
  eq(
    map[H_ .. "broken setup block::<setup>"].status,
    "error",
    "a raising setup() is an error case of its own"
  )
  has(map[H_ .. "broken setup block::<setup>"].error.message, "setup exploded", "with the message")
  local never = map[H_ .. "broken setup block::never gets to pass"]
  eq(never.status, "error", "an it() below a failed setup() is an error, never a pass")
  has(never.error.message, "setup() of an enclosing block failed", "and says why")
  local before = map[H_ .. "raising before_each::ends as an error"]
  eq(before.status, "error", "a raising before_each ends the case as error")
  has(before.error.message, "before_each exploded", "with the message")
  local body = map[H_ .. "describe body raises::<describe body>"]
  eq(body ~= nil and body.status, "error", "a raising describe body is an error case of its own")
  eq(
    map[H_ .. "teardown runs when the block ends::a"].status,
    "pass",
    "cases after the broken blocks still run"
  )
  eq(trace, { "a", "b", "teardown" }, "teardown() runs when its block ends")

  cases = run("busted_toplevel_error")
  eq(#cases, 2, "a raise at the top level keeps the cases that ran before it")
  eq(cases[1].status, "pass", "the case before the raise passed")
  eq(cases[2].status, "error", "the raise itself is an error case")
  has(cases[2].error.message, "top-level boom", "with its message")

  cases = run("busted_empty")
  eq(#cases, 1, "a file without cases yields one case")
  eq(cases[1].status, "fail", "which fails: a spec that runs nothing proves nothing")
  has(cases[1].notes[1], "registered no", "and says why")

  cases = run("busted_empty", { assertions = "error" })
  eq(cases[1].status, "fail", 'assertions = "error" keeps it red')

  cases = run("busted_empty", { assertions = "warn" })
  eq(#cases, 1, 'assertions = "warn": still exactly one case, never silent')
  eq(cases[1].status, "skip", "which is a skip, not a pass (never green under --strict)")
  eq(cases[1].reason, "no case registered on this platform", "with the reason")
  eq(cases[1].notes[1], busted.NO_CASE_WARNING, "and a warning note the terminal lists")
  eq(#cases[1].assertions, 0, "and it asserts nothing")

  -- a file that does not even load
  local broken = vim.fn.tempname() .. "_broken.lua"
  vim.fn.writefile({ "describe('x', function(" }, broken)
  cases =
    dialect.run_file("busted", assert_mod.new(), { path = broken, rel = "TESTS/broken_spec.lua" })
  eq(cases[1].status, "error", "a syntax error is an error case")
  eq(#cases, 1, "and only that")

  -- ------------------------------------------------------------------ unsupported constructs
  cases = run("busted_unsupported")
  eq(#cases, 4, "four cases, none silently dropped")
  for _, c in ipairs(cases) do
    eq(c.status, "error", "an unsupported construct is an error, never a pass: " .. c.id)
    has(c.error.message, "not supported", "the message says so: " .. c.id)
  end
  has(cases[1].error.message, "stub", "the stub case names stub")
  has(cases[2].error.message, "spy", "the spy case names spy")
  has(cases[3].error.message, "unique", "an unknown luassert assertion is named")

  -- ------------------------------------------------------------------ plain assert and luassert module
  cases = run("busted_globals")
  map = by_id(cases)
  local G = "TESTS/busted_globals_spec.lua::plain assert::"
  eq(
    map[G .. "counts as an assertion of the case"].status,
    "pass",
    "a spec that only uses assert() did assert"
  )
  eq(
    #map[G .. "counts as an assertion of the case"].assertions,
    2,
    "both plain assert calls were recorded"
  )
  eq(
    map[G .. "the luassert module is the same object"].status,
    "pass",
    "require('luassert') is the shim's assert"
  )
  local plain = map[G .. "a failing plain assert ends the body"]
  eq(plain.status, "error", "a failing plain assert raises like the builtin")
  eq(plain.error.message, "plain assert message", "with the builtin's message, untouched")

  -- ------------------------------------------------------------------ nothing leaks
  for name, before_value in pairs(globals_before) do
    eq(rawget(_G, name), before_value, "global " .. name .. " is restored")
  end
  eq(package.loaded["luassert"], loaded_luassert, "package.loaded.luassert is restored")
  eq(busted.UNSUPPORTED.stub ~= nil, true, "the unsupported list is data a driver can print")

  -- restoring also happens when the file raises at the top level
  _G.__TESTING_FIXTURE_TRACE = {}
  run("busted_toplevel_error")
  _G.__TESTING_FIXTURE_TRACE = nil
  eq(
    rawget(_G, "describe"),
    globals_before.describe,
    "globals are restored after a top-level raise too"
  )
end
