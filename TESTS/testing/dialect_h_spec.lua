-- TESTS/testing/dialect_h_spec.lua -- dialect h: `return function(H)` on the project's own harness.lua;
-- harness failures (`error("FAIL ...")`) are collected, every other error is not an assertion.

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
  local project = require("testing.dialect.harness_project")

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

  -- which harness functions are assertions: read from the source
  local names =
    project.assertion_names(table.concat(vim.fn.readfile(here .. "/fixtures/h/harness.lua"), "\n"))
  eq(
    names,
    { eq = true, ok = true, match = true },
    "functions whose body says FAIL are assertions, helpers are not"
  )

  -- the failing fixture: all three failures collected, the helper `match` that no fixed shim has works
  local a = assert_mod.new()
  local fixture = here .. "/fixtures/h/h_fail.fixture.lua"
  local cases = dialect.run_file("h", a, {
    path = fixture,
    rel = "TESTS/h_fail_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })
  local case = cases[1]
  eq(#cases, 1, "dialect h: one case per file")
  eq(case.status, "fail", "failed checks make the file fail")
  eq(case.error, nil, "no error: the file ran to its end")
  local passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 3, "all three failures are visible")
  eq(passed, 3, "the three checks that hold are recorded as passes")
  eq(failed[1].line, line_of(fixture, "h1"), "first failure: the spec's own line")
  eq(
    failed[2].line,
    line_of(fixture, "h2"),
    "failure of a project-only helper: the spec's own line"
  )
  eq(failed[3].line, line_of(fixture, "h3"), "third failure: the spec's own line")
  has(failed[1].msg, "first wrong", "the harness' failure text is kept")
  has(failed[1].msg, "FAIL", "and says it is a failure")
  has(failed[1].file, "h_fail.fixture.lua", "the call site is the spec")

  -- the harness is found by walking up from the spec when no path is given
  cases = dialect.run_file("h", assert_mod.new(), {
    path = fixture,
    rel = "TESTS/h_fail_spec.lua",
    root = here,
  })
  eq(cases[1].status, "fail", "the harness next to the spec is found without a path")
  eq(
    project.find_harness(fixture, here),
    vim.fs.normalize(here .. "/fixtures/h/harness.lua"),
    "find_harness"
  )
  eq(
    project.find_harness(fixture, here .. "/fixtures/h/"),
    vim.fs.normalize(here .. "/fixtures/h/harness.lua"),
    "find_harness, root with a slash"
  )

  -- an error that is not a harness failure is NOT collected: it ends the file as an error
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  end
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  vim.fn.writefile(vim.fn.readfile(here .. "/fixtures/h/harness.lua"), root .. "/harness.lua")
  write(
    root .. "/bug_spec.lua",
    'return function(H)\n  H.eq(1, 1, "before")\n  H.boom()\n  H.eq(1, 2, "never reached")\nend\n'
  )
  cases = dialect.run_file(
    "h",
    assert_mod.new(),
    { path = root .. "/bug_spec.lua", rel = "TESTS/bug_spec.lua", root = root }
  )
  eq(cases[1].status, "error", "a helper's own error ends the file as error")
  has(cases[1].error.message, "helper bug", "its message arrives untouched")
  eq(#cases[1].assertions, 1, "the check before it is kept, the one after never ran")

  -- a passing file passes (negative control), a file with no check fails
  write(
    root .. "/pass_spec.lua",
    'return function(H)\n  H.eq(1, 1, "one")\n  H.match("x", "x", "two")\nend\n'
  )
  cases = dialect.run_file(
    "h",
    assert_mod.new(),
    { path = root .. "/pass_spec.lua", rel = "TESTS/pass_spec.lua", root = root }
  )
  eq(cases[1].status, "pass", "all checks hold: pass")
  write(root .. "/none_spec.lua", "return function(H)\n  local _ = H.LIMIT\nend\n")
  cases = dialect.run_file(
    "h",
    assert_mod.new(),
    { path = root .. "/none_spec.lua", rel = "TESTS/none_spec.lua", root = root }
  )
  eq(cases[1].status, "fail", "no check at all fails")

  -- no harness at all, and a harness that is not a table: named errors
  local lonely = vim.fs.normalize(vim.fn.tempname())
  write(lonely .. "/x_spec.lua", "return function(H) end\n")
  cases = dialect.run_file(
    "h",
    assert_mod.new(),
    { path = lonely .. "/x_spec.lua", rel = "TESTS/x_spec.lua", root = lonely }
  )
  eq(cases[1].status, "error", "no harness.lua is an error")
  has(cases[1].error.message, "no harness.lua found", "the message says so")
  write(lonely .. "/harness.lua", "return 7\n")
  cases = dialect.run_file(
    "h",
    assert_mod.new(),
    { path = lonely .. "/x_spec.lua", rel = "TESTS/x_spec.lua", root = lonely }
  )
  eq(cases[1].status, "error", "a harness that is not a table is an error")
  has(cases[1].error.message, "must return the harness table", "the message says so")
  for _, dir in ipairs({ root, lonely }) do
    vim.fn.delete(dir, "rf")
  end
end
