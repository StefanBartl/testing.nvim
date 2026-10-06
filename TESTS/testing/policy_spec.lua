-- TESTS/testing/policy_spec.lua -- the assertion policy: a case without assertions is an error, a warning
-- or (after a printed `skip` line) a skip; print capture; the policy inside the busted dialect.

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
  local policy = require("testing.policy")
  local result = require("testing.core.result")
  local assert_mod = require("testing.core.assert")
  local dialect = require("testing.dialect")

  -- ------------------------------------------------------------------ skip lines
  for _, line in ipairs({
    "skip  git_spec.lua: git not usable",
    "  skip ui.cycle (telescope.nvim not on runtimepath)",
    "SKIP: no network",
    "Skipped: optional",
    "skipping the live part",
    "[skip] reason",
    "\tskip",
  }) do
    eq(policy.is_skip_line(line), true, ("%q is a skip line"):format(line))
  end
  for _, line in ipairs({
    "",
    "skipper",
    "do not skip this",
    "ok   skip handling works",
    "it skips",
    "no skip",
  }) do
    eq(policy.is_skip_line(line), false, ("%q is not a skip line"):format(line))
  end
  eq(policy.is_skip_line(nil), false, "nil is not")
  eq(policy.is_skip_line(3), false, "nor is a number")
  eq(
    policy.skip_reason({ "a", "  skip  because", "skip later" }),
    "skip  because",
    "the first, trimmed"
  )
  eq(policy.skip_reason({ "a" }), nil, "none")
  eq(policy.skip_reason(nil), nil, "no lines")
  eq(
    #policy.skip_reason({ "skip " .. ("x"):rep(1000) }),
    policy.MAX_LINE_BYTES,
    "a long one is cut"
  )

  -- ------------------------------------------------------------------ apply
  ---@param build fun(c: Testing.Result.Case)
  ---@return Testing.Result.Case
  local function finished(build)
    local c = result.new_case({ file = "TESTS/x_spec.lua", name = "x" })
    build(c)
    return result.finish_case(c)
  end
  local empty = finished(function() end)
  eq(empty.status, "fail", "the kernel fails a case without assertions")
  eq(empty.assertions[1].kind, "no_assertions", "with the synthetic assertion")

  local c, changed = policy.apply(finished(function() end), {})
  eq(c.status, "fail", "default policy: stays a failure")
  eq(changed, nil, "and nothing was changed")
  c, changed = policy.apply(finished(function() end), { assertions = "error" })
  eq(c.status, "fail", "assertions = error: stays a failure")
  eq(changed, nil, "unchanged")

  c, changed = policy.apply(finished(function() end), { assertions = "warn" })
  eq(c.status, "pass", "assertions = warn: a pass")
  eq(changed, "warn", "reported as warn")
  eq(#c.assertions, 1, "with exactly one assertion left")
  eq(
    c.assertions[1],
    { ok = true, kind = "no_assertions", msg = policy.WARN_MSG },
    "a PASSING synthetic one"
  )
  eq(c.notes, { "warning: case made no assertions" }, "and the warning note")
  local valid, problems = result.validate({
    schema_version = 1,
    run = result.new_run({
      id = "i",
      root = "<REPO>",
      project_key = "k",
      nvim = "0.12",
      os = "windows",
    }),
    cases = { c },
    summary = result.summarize({ c }),
  })
  eq(problems, {}, "the IR with such a case validates")
  ok(valid, "the IR with such a case is valid")

  c, changed = policy.apply(finished(function() end), { printed = { "skip  no git" } })
  eq(c.status, "skip", "a printed skip line: skip")
  eq(changed, "skip", "reported as skip")
  eq(c.reason, "skip  no git", "the line is the reason")
  eq(c.assertions, {}, "no synthetic failure is left")
  has(c.notes[1], "skip convention", "and the note says why")
  c = policy.apply(finished(function() end), { printed = { "skip  x" }, assertions = "warn" })
  eq(c.status, "skip", "the skip convention beats warn")
  c = policy.apply(finished(function() end), { printed = { "all fine", "info: skip count 0" } })
  eq(c.status, "fail", "a line that merely mentions skip is no skip")

  -- what it never touches
  c, changed = policy.apply(
    finished(function(case)
      case.assertions[1] = { ok = true, kind = "eq" }
    end),
    { printed = { "skip x" }, assertions = "warn" }
  )
  eq(c.status, "pass", "a case with an assertion keeps its verdict, skip line or not")
  eq(changed, nil, "unchanged")
  c = policy.apply(
    finished(function(case)
      case.assertions[1] = { ok = false, kind = "eq", msg = "no" }
    end),
    { printed = { "skip x" } }
  )
  eq(c.status, "fail", "a failed assertion is never turned into a skip")
  c = policy.apply(
    finished(function(case)
      case.status = "error"
      case.error = { message = "boom", traceback = "boom" }
    end),
    { printed = { "skip x" }, assertions = "warn" }
  )
  eq(c.status, "error", "an error stays an error")
  c = policy.apply(
    finished(function(case)
      case.status = "timeout"
    end),
    { printed = { "skip x" }, assertions = "warn" }
  )
  eq(c.status, "timeout", "a timeout stays a timeout")

  -- ------------------------------------------------------------------ capture
  local real_print = print
  local seen = {}
  ---@diagnostic disable-next-line: duplicate-set-field
  _G.print = function(...)
    seen[#seen + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
  end
  local outer = policy.capture()
  print("one")
  local inner = policy.capture()
  print("two", 3, nil)
  print("multi\nline")
  eq(
    inner.stop(),
    { "two\t3\tnil", "multi", "line" },
    "the inner capture has its own lines, tab-separated"
  )
  print("three")
  eq(
    outer.stop(),
    { "one", "two\t3\tnil", "multi", "line", "three" },
    "the outer one saw everything"
  )
  eq(seen, { "one", "two 3", "multi\nline", "three" }, "the text still reached the original print")
  ok(_G.print ~= real_print, "stop() restored the previous print (here: the test's own)")
  print("after")
  eq(seen[#seen], "after", "and it works")
  -- out-of-order stop: the outer one must not clobber a function somebody installed meanwhile
  local first = policy.capture()
  local replaced = function() end
  _G.print = replaced
  first.stop()
  ok(_G.print == replaced, "stop() leaves a print that is not its own alone")
  first.stop()
  ok(_G.print == replaced, "and a second stop() is harmless")
  -- the cap
  ---@diagnostic disable-next-line: duplicate-set-field
  _G.print = function() end
  local capped = policy.capture()
  for i = 1, policy.MAX_LINES + 50 do
    print(i)
  end
  eq(#capped.stop(), policy.MAX_LINES, "a capture keeps at most MAX_LINES lines")
  _G.print = real_print

  -- the other output channels a project's own harness prints its failure lines with
  local file_methods = getmetatable(io.stdout).__index
  ---@diagnostic disable-next-line: deprecated
  local orig_write, orig_method, orig_api = io.write, file_methods.write, vim.api.nvim_out_write
  local cap = policy.capture()
  ok(io.write ~= orig_write, "capture hooks io.write")
  io.write("io.write ")
  io.write("in two parts\n")
  io.stdout:write("stdout ", "method\n")
  io.stderr:write("stderr method\n")
  ---@diagnostic disable-next-line: deprecated
  vim.api.nvim_out_write("api out\n")
  ---@diagnostic disable-next-line: deprecated
  vim.api.nvim_err_write("api err\n")
  local sidefile = vim.fn.tempname()
  local sf = assert(io.open(sidefile, "wb"))
  sf:write("a file of the spec itself\n")
  sf:close()
  io.write("no newline at the end")
  local seen_lines = cap.stop()
  vim.fn.delete(sidefile)
  eq(
    seen_lines,
    {
      "io.write in two parts",
      "stdout method",
      "stderr method",
      "api out",
      "api err",
      "no newline at the end",
    },
    "io.write (also in parts), io.stdout/io.stderr methods and the nvim writers are captured; the spec's own files are not; stop() flushes the open line"
  )
  ok(io.write == orig_write, "stop() restored io.write")
  ok(file_methods.write == orig_method, "stop() restored the file write method")
  ---@diagnostic disable-next-line: deprecated
  ok(vim.api.nvim_out_write == orig_api, "stop() restored nvim_out_write")
  eq(#cap.stop(), #seen_lines, "a second stop() is harmless")

  -- guard: print captured while the case runs, policy applied to the case it returns
  local a = assert_mod.new()
  ---@diagnostic disable-next-line: duplicate-set-field
  _G.print = function() end
  local guarded = policy.guard({ assertions = "error" }, function()
    return a.run_case({ file = "TESTS/g_spec.lua", name = "g" }, function()
      print("skip  guarded")
    end)
  end)
  eq(guarded.status, "skip", "guard: the printed skip line made it a skip")
  local ok_called, err = pcall(policy.guard, {}, function()
    error("inner raise", 0)
  end)
  _G.print = real_print
  eq(ok_called, false, "guard re-raises what the runner raises")
  eq(err, "inner raise", "untouched")
  ok(_G.print == real_print, "and always restores print")

  -- ------------------------------------------------------------------ the busted dialect
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local function run_busted(opts)
    ---@diagnostic disable-next-line: duplicate-set-field
    _G.print = function() end
    local called, cases = pcall(dialect.run_file, "busted", assert_mod.new(), {
      path = here .. "/fixtures/busted_policy.fixture.lua",
      rel = "TESTS/busted_policy_spec.lua",
    }, opts)
    _G.print = real_print
    assert(called, cases)
    local by_name = {}
    for _, case in ipairs(cases) do
      by_name[case.id:match("([^:]+)$")] = case
    end
    return by_name
  end
  local cases = run_busted({})
  eq(
    cases["skips by early return"].status,
    "skip",
    "busted: an it that prints skip and returns is a skip"
  )
  has(cases["skips by early return"].reason, "optional sibling", "with the printed line")
  eq(cases["asserts nothing"].status, "fail", "busted: an it without assertions fails by default")
  eq(cases["asserts"].status, "pass", "busted: an it that asserts passes")
  cases = run_busted({ assertions = "warn" })
  eq(cases["asserts nothing"].status, "pass", "busted: assertions = warn passes it")
  eq(
    cases["asserts nothing"].notes[#cases["asserts nothing"].notes],
    "warning: case made no assertions",
    "with the note"
  )
  eq(cases["skips by early return"].status, "skip", "and the skip stays")
end
