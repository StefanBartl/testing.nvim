-- TESTS/testing/dialect_d_spec.lua -- dialect D (spotlight.nvim): `M.run()` specs on the plugin's own
-- harness module; its counters become recorded assertions with the spec's call sites.

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

  local path_before = package.path
  local loaded_before = package.loaded["harness"]

  -- the failing fixture: passes counted, ALL failures recorded, call sites of the spec
  local a = assert_mod.new()
  local fixture = here .. "/fixtures/d/d_fail.fixture.lua"
  local cases = dialect.run_file("d", a, { path = fixture, rel = "TESTS/d_fail_spec.lua" })
  eq(#cases, 1, "dialect d: one case per file")
  local case = cases[1]
  eq(case.id, "TESTS/d_fail_spec.lua::d_fail_spec.lua", "case id is <file>::<file name>")
  eq(case.status, "fail", "failed checks make the file fail")
  eq(case.error, nil, "no error: M.run ran to its end")
  local passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(passed, 4, "the passing checks are counted as recorded assertions (incl. one inside a helper)")
  eq(#failed, 3, "all three failures are recorded")
  eq(failed[1].msg, "eq fails: expected 2, got 1", "the plugin harness' own failure text is kept")
  eq(
    failed[2].msg,
    "inside the helper fails: custom reason",
    "a failure inside a helper is recorded once"
  )
  has(failed[3].msg, "contains fails", "third failure")
  eq(failed[1].line, line_of(fixture, "d1"), "first failure: the spec's own line")
  eq(failed[2].line, line_of(fixture, "d2"), "failure inside a helper: the line of the inner call")
  eq(failed[3].line, line_of(fixture, "d3"), "third failure: the spec's own line")
  has(failed[1].file, "d_fail.fixture.lua", "the call site is the spec, not the adapter")

  -- nothing leaks: package.path and package.loaded.harness are as before
  eq(package.path, path_before, "package.path is restored")
  eq(
    package.loaded["harness"],
    loaded_before,
    "package.loaded.harness is restored (a later file loads its own)"
  )

  -- a second run starts from fresh counters: the same numbers again
  local again =
    dialect.run_file("d", assert_mod.new(), { path = fixture, rel = "TESTS/d_fail_spec.lua" })[1]
  eq(#again.assertions, #case.assertions, "a second run records the same checks (no counter leaks)")

  -- a passing module is a pass
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  end
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  vim.fn.writefile(vim.fn.readfile(here .. "/fixtures/d/harness.lua"), root .. "/harness.lua")
  write(
    root .. "/pass_spec.lua",
    'local t = require("harness")\nlocal M = {}\nfunction M.run()\n  t.ok("one", true)\n  t.eq("two", 2, 2)\nend\nreturn M\n'
  )
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = root .. "/pass_spec.lua", rel = "TESTS/pass_spec.lua" }
  )
  eq(cases[1].status, "pass", "a module whose checks hold passes")
  eq(#cases[1].assertions, 2, "two checks, two records")

  -- a spec that tests the harness takes an EXPECTED failure back out of the list: it is withdrawn from the case,
  -- and the next real failure is still seen
  write(
    root .. "/trim_spec.lua",
    'local t = require("harness")\nlocal M = {}\nfunction M.run()\n  t.ok("expected to fail", false)\n  table.remove(t.failures)\n  t.ok("holds", true)\n  t.eq("real", 1, 2)\nend\nreturn M\n'
  )
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = root .. "/trim_spec.lua", rel = "TESTS/trim_spec.lua" }
  )
  eq(cases[1].status, "fail", "the real failure after a trimmed one fails the file")
  local trim_failed, trim_passed = {}, 0
  for _, rec in ipairs(cases[1].assertions) do
    if rec.ok then
      trim_passed = trim_passed + 1
    else
      trim_failed[#trim_failed + 1] = rec.msg
    end
  end
  eq(
    trim_failed,
    { "real: expected 2, got 1" },
    "only the real failure is recorded, the trimmed one is gone"
  )
  eq(trim_passed, 1, "and the passing check")

  -- a module that checks nothing fails (P4); one that raises is an error with the earlier checks kept
  write(root .. "/none_spec.lua", "local M = {}\nfunction M.run()\nend\nreturn M\n")
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = root .. "/none_spec.lua", rel = "TESTS/none_spec.lua" }
  )
  eq(cases[1].status, "fail", "no check at all fails")
  write(
    root .. "/raise_spec.lua",
    'local t = require("harness")\nlocal M = {}\nfunction M.run()\n  t.ok("before", true)\n  error("run exploded", 0)\nend\nreturn M\n'
  )
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = root .. "/raise_spec.lua", rel = "TESTS/raise_spec.lua" }
  )
  eq(cases[1].status, "error", "a raise of run() is an error")
  eq(#cases[1].assertions, 1, "the check before the raise is kept")
  has(cases[1].error.message, "run exploded", "its message")

  -- a module without run(), and a harness that is not a dialect-D harness: clear errors
  write(root .. "/norun_spec.lua", "return { }\n")
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = root .. "/norun_spec.lua", rel = "TESTS/norun_spec.lua" }
  )
  eq(cases[1].status, "error", "no run() is an error")
  has(cases[1].error.message, "run() function", "the message names run()")

  local other = vim.fs.normalize(vim.fn.tempname())
  write(other .. "/harness.lua", "return { eq = function() end }\n")
  write(
    other .. "/x_spec.lua",
    'local M = {}\nfunction M.run()\n  require("harness").eq()\nend\nreturn M\n'
  )
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = other .. "/x_spec.lua", rel = "TESTS/x_spec.lua" }
  )
  eq(cases[1].status, "error", "a harness without counters is refused")
  has(cases[1].error.message, "not a dialect-D harness", "the message says why")

  -- no harness reachable at all
  local lonely = vim.fs.normalize(vim.fn.tempname())
  write(lonely .. "/y_spec.lua", 'local t = require("harness_that_is_nowhere")\nreturn {}\n')
  cases = dialect.run_file(
    "d",
    assert_mod.new(),
    { path = lonely .. "/y_spec.lua", rel = "TESTS/y_spec.lua" }
  )
  eq(cases[1].status, "error", "a missing harness is an error")
  has(cases[1].error.message, "cannot load the plugin's harness", "the message names the problem")

  eq(package.path, path_before, "package.path is restored after the error paths too")
  eq(
    package.loaded["harness"],
    loaded_before,
    "package.loaded.harness is restored after the error paths too"
  )
  for _, dir in ipairs({ root, other, lonely }) do
    vim.fn.delete(dir, "rf")
  end
end
