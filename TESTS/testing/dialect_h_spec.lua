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
  -- an assertion inside a protected call the SPEC wrote raises (the spec asks "does this fail?"); a
  -- protected call of the harness itself (`guarded`) does not make it raise, and neither does the runner's
  local pfixture = here .. "/fixtures/h/h_pcall.fixture.lua"
  cases = dialect.run_file("h", assert_mod.new(), {
    path = pfixture,
    rel = "TESTS/h_pcall_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })
  case = cases[1]
  eq(case.error, nil, "pcall fixture: the file ran to its end")
  passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 1, "pcall fixture: only the check outside the spec's pcall is recorded as failed")
  eq(passed, 3, "pcall fixture: the two raising checks were asked for, the last check holds")
  eq(failed[1].line, line_of(pfixture, "p1"), "pcall fixture: the failure keeps the spec's line")
  has(failed[1].msg, "recorded", "pcall fixture: and the harness' text")

  -- a protected call of the PLUGIN under test swallows the error: the check inside its callback is recorded
  -- (a raise would make it vanish); a pcall of the spec inside that callback still answers
  local lfixture = here .. "/fixtures/h/h_pcall_lib.fixture.lua"
  cases = dialect.run_file("h", assert_mod.new(), {
    path = lfixture,
    rel = "TESTS/h_pcall_lib_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })
  case = cases[1]
  eq(case.error, nil, "plugin pcall fixture: the file ran to its end")
  eq(
    case.status,
    "fail",
    "plugin pcall fixture: the failed check inside the plugin's pcall is not lost"
  )
  passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 1, "plugin pcall fixture: one check failed")
  eq(passed, 2, "plugin pcall fixture: the two checks that hold")
  eq(failed[1].line, line_of(lfixture, "p2"), "plugin pcall fixture: it keeps the spec's line")
  has(failed[1].msg, "swallowed by the plugin", "plugin pcall fixture: and its message")

  -- a harness split over two files: the helper's pcall is in the second file, it still only passes the error on
  local sfixture = here .. "/fixtures/h_split/h_split.fixture.lua"
  cases = dialect.run_file("h", assert_mod.new(), {
    path = sfixture,
    rel = "TESTS/h_split_spec.lua",
    harness = here .. "/fixtures/h_split/harness.lua",
  })
  case = cases[1]
  eq(case.error, nil, "split harness fixture: the file ran to its end")
  eq(case.status, "pass", "split harness fixture: the question is answered through the second file")
  eq(
    #case.assertions,
    4,
    "split harness fixture: the four checks of the spec, the raised ones are not recorded"
  )

  -- the helper files of a split harness found through a path relative to the working directory (`dofile("./x.lua")`,
  -- a `./?.lua` entry of `package.path`): the chunk names are relative, the files are still the harness
  local cwd = vim.uv.cwd()
  vim.fn.chdir(here)
  local rel_ok, rel_cases = pcall(dialect.run_file, "h", assert_mod.new(), {
    path = sfixture,
    rel = "TESTS/h_split_rel_spec.lua",
    harness = here .. "/fixtures/h_split_rel/harness.lua",
  })
  vim.fn.chdir(cwd)
  eq(rel_ok, true, "relative split harness fixture: the run did not raise")
  case = rel_cases[1]
  eq(case.error, nil, "relative split harness fixture: the file ran to its end")
  eq(
    case.status,
    "pass",
    "relative split harness fixture: the question is answered through the helper files"
  )
  eq(#case.assertions, 4, "relative split harness fixture: the four checks of the spec")

  -- a split harness whose table outlives the file: the next run wraps the wrappers of the run before, the
  -- helper's chunk must stay part of the harness
  for run_no = 1, 3 do
    cases = dialect.run_file("h", assert_mod.new(), {
      path = sfixture,
      rel = "TESTS/h_split_shared_spec.lua",
      harness = here .. "/fixtures/h_split_rel/harness_shared.lua",
    })
    eq(
      cases[1].status,
      "pass",
      "shared split harness fixture: run " .. run_no .. " answers the spec's question"
    )
  end
  rawset(_G, "__testing_h_split_shared_fixture", nil)

  -- a function of `H` that is the code under test (exported from outside the harness directory) is not the harness:
  -- its pcall may swallow what the spec raises, so the check is recorded
  local xfixture = here .. "/fixtures/h_export/h_export.fixture.lua"
  cases = dialect.run_file("h", assert_mod.new(), {
    path = xfixture,
    rel = "TESTS/h_export_spec.lua",
    harness = here .. "/fixtures/h_export/harness.lua",
  })
  case = cases[1]
  eq(case.error, nil, "export fixture: the file ran to its end")
  eq(
    case.status,
    "fail",
    "export fixture: the failed check inside the exported plugin's pcall is not lost"
  )
  passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 1, "export fixture: one check failed")
  eq(passed, 2, "export fixture: two checks hold")
  eq(failed[1].line, line_of(xfixture, "x1"), "export fixture: the failure keeps the spec's line")

  -- the harness sits in the root of the project: the code under test below its `lua/` is not the harness, and
  -- neither is a file that only has the harness directory as a textual prefix (`<dir>/../other/x.lua`)
  for _, layout in ipairs({
    {
      "root harness",
      "h_root",
      "h_root",
      "r1",
      "swallowed by the plugin below the harness directory",
    },
    {
      "root harness, plugin in vendor/",
      "h_rootvendor",
      "h_rootvendor",
      "r1",
      "swallowed by the plugin in vendor/",
    },
    {
      "dot-dot path",
      "h_dotdot",
      "h_dotdot",
      "d1",
      "swallowed by the plugin behind a dot-dot path",
    },
  }) do
    local label, dir, name, mark, text = unpack(layout)
    local lfile = here .. "/fixtures/" .. dir .. "/" .. name .. ".fixture.lua"
    cases = dialect.run_file("h", assert_mod.new(), {
      path = lfile,
      rel = "TESTS/" .. name .. "_spec.lua",
      harness = here .. "/fixtures/" .. dir .. "/harness.lua",
      root = here .. "/fixtures/" .. dir,
    })
    case = cases[1]
    eq(case.error, nil, label .. ": the file ran to its end")
    eq(case.status, "fail", label .. ": the failed check inside the plugin's pcall is not lost")
    passed, failed = 0, {}
    for _, rec in ipairs(case.assertions) do
      if rec.ok then
        passed = passed + 1
      else
        failed[#failed + 1] = rec
      end
    end
    eq(#failed, 1, label .. ": one check failed")
    eq(passed, 2, label .. ": two checks hold")
    local first = failed[1] or {}
    eq(first.line, line_of(lfile, mark), label .. ": the failure keeps the spec's line")
    has(first.msg, text, label .. ": and its message")
  end

  -- the same export, its chunk name spelled with `..` (absolute, and relative to the working directory): textually
  -- below the harness directory, in fact outside it, so still the code under test
  for _, variant in ipairs({ "harness_dotdot.lua", "harness_dotdot_rel.lua" }) do
    local saved_cwd = vim.uv.cwd()
    vim.fn.chdir(here .. "/fixtures/h_export")
    local ran, dcases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = xfixture,
      rel = "TESTS/h_export_spec.lua",
      harness = here .. "/fixtures/h_export/" .. variant,
    })
    vim.fn.chdir(saved_cwd)
    eq(ran, true, variant .. ": the run did not raise")
    eq(
      dcases[1].status,
      "fail",
      variant .. ": the failed check inside the exported plugin's pcall is not lost"
    )
  end

  -- a harness table that outlives the file: what a spec left in it does not make the spec's own pcall part of the harness
  for run_no = 1, 3 do
    cases = dialect.run_file("h", assert_mod.new(), {
      path = here .. "/fixtures/h_shared/h_shared.fixture.lua",
      rel = "TESTS/h_shared_spec.lua",
      harness = here .. "/fixtures/h_shared/harness.lua",
    })
    eq(
      cases[1].status,
      "pass",
      "shared harness fixture: run " .. run_no .. " answers the spec's question"
    )
  end
  rawset(_G, "__testing_h_shared_fixture", nil)

  -- ... and what ANOTHER file left in the table is not the harness either: its pcall may swallow what the spec raises
  do
    local shared = here .. "/fixtures/h_shared"
    local leave = dialect.run_file("h", assert_mod.new(), {
      path = shared .. "/leave.fixture.lua",
      rel = "TESTS/leave_spec.lua",
      harness = shared .. "/harness.lua",
    })
    eq(leave[1].status, "pass", "shared harness, first file: leaves a helper behind and passes")
    local through = dialect.run_file("h", assert_mod.new(), {
      path = shared .. "/through.fixture.lua",
      rel = "TESTS/through_spec.lua",
      harness = shared .. "/harness.lua",
    })
    rawset(_G, "__testing_h_shared_fixture", nil)
    case = through[1]
    eq(case.error, nil, "shared harness, second file: ran to its end")
    eq(
      case.status,
      "fail",
      "shared harness, second file: the check swallowed by another file's helper is not lost"
    )
    failed = {}
    for _, rec in ipairs(case.assertions) do
      if not rec.ok then
        failed[#failed + 1] = rec
      end
    end
    eq(#failed, 1, "shared harness, second file: one check failed")
    eq(
      failed[1] and failed[1].line,
      line_of(shared .. "/through.fixture.lua", "t1"),
      "shared harness, second file: at the spec's line"
    )
  end

  -- a framework of another file starts the spec: its own pcall is not the spec's (dialect h and A, same entry)
  cases = dialect.run_file("h", assert_mod.new(), {
    path = here .. "/fixtures/h/h_wrap_ask.fixture.lua",
    rel = "TESTS/h_wrap_ask_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })
  eq(cases[1].status, "pass", "wrapped spec (h): the question the spec asks is answered")
  for _, wrapped in ipairs({
    { "h", here .. "/fixtures/h/h_wrap_swallow.fixture.lua", here .. "/fixtures/h/harness.lua" },
    { "a", here .. "/fixtures/a_wrap_swallow.fixture.lua", nil },
  }) do
    local wpath = wrapped[2]
    cases = dialect.run_file(wrapped[1], assert_mod.new(), {
      path = wpath,
      rel = "TESTS/wrap_swallow_spec.lua",
      harness = wrapped[3],
    })
    case = cases[1]
    eq(
      case.status,
      "fail",
      "wrapped spec (" .. wrapped[1] .. "): the framework's pcall swallows nothing"
    )
    passed, failed = 0, {}
    for _, rec in ipairs(case.assertions) do
      if rec.ok then
        passed = passed + 1
      else
        failed[#failed + 1] = rec
      end
    end
    eq(#failed, 1, "wrapped spec (" .. wrapped[1] .. "): the failed check is recorded")
    eq(passed, 2, "wrapped spec (" .. wrapped[1] .. "): the two checks that hold")
    eq(
      failed[1].line,
      line_of(wpath, "w1"),
      "wrapped spec (" .. wrapped[1] .. "): with the spec's line"
    )
  end

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

  -- the doc comment of the NEXT function is not part of the body of a helper: a cleanup helper that throws its
  -- callback's error away is no assertion because a comment below it says "FAIL" and "error("
  local comment_dir = here .. "/fixtures/h_comment"
  eq(
    project.assertion_names(table.concat(vim.fn.readfile(comment_dir .. "/harness.lua"), "\n")),
    { eq = true },
    "comments are not read as code: only H.eq is an assertion"
  )
  eq(
    project.strip_comments("a --[==[ x ]] ]==] b -- c\nd \"--e\" '--f' [[--g]] h"),
    "a   b  \nd \"--e\" '--f' [[--g]] h",
    "line and long comments go, string literals and long strings stay"
  )
  for _, row in ipairs({
    { "a - 1 -- c\nb", "a - 1  \nb", "a minus is not a comment" },
    { "x -- last line", "x  ", "a comment on the last line, no newline behind it" },
    { 's = "q\\" -- c"\nz', 's = "q\\" -- c"\nz', "an escaped quote does not end the string" },
    { 's = "a" -- c\nz', 's = "a"  \nz', "a comment after a string that ended" },
    { "s = 'a' -- c\nz", "s = 'a'  \nz", "a comment after a single-quoted string" },
    { "s = 'a\n-- c\nz", "s = 'a\n \nz", "an unterminated string ends at the line" },
    {
      "s = [==[ ]] -- x ]==] -- c\nz",
      "s = [==[ ]] -- x ]==]  \nz",
      "a long string of level 2 ends at its own bracket",
    },
    { "a --[[ x ]] b --[==[ y ]] ]==] c", "a   b   c", "long comments of level 0 and 2" },
    { "a --[[ never closed", "a  ", "an unterminated long comment ends the text" },
    { "a--[[x]]b", "a b", "a block comment separates tokens" },
    {
      's = "a\\z\n   b" -- c\nz',
      's = "a\\z\n   b"  \nz',
      "a string goes on after \\z and its line break",
    },
    {
      's = "a\\\r\nb" -- c\nz',
      's = "a\\\r\nb"  \nz',
      "a backslash before CRLF is one escaped line break",
    },
  }) do
    eq(project.strip_comments(row[1]), row[2], "strip_comments: " .. row[3])
  end
  eq(
    project.assertion_names('function H.a(x) if x - 1 > 0 then error("FAIL a") end end'),
    { a = true },
    "a minus before error( does not hide the rest of the line"
  )
  cases = dialect.run_file("h", assert_mod.new(), {
    path = comment_dir .. "/swallowed.fixture.lua",
    rel = "TESTS/swallowed_spec.lua",
    harness = comment_dir .. "/harness.lua",
  })
  case = cases[1]
  eq(case.error, nil, "comment fixture: the file ran to its end")
  eq(case.status, "fail", "comment fixture: the failed check inside the cleanup helper is not lost")
  passed, failed = 0, {}
  for _, rec in ipairs(case.assertions) do
    if rec.ok then
      passed = passed + 1
    else
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 1, "comment fixture: one check failed")
  eq(passed, 1, "comment fixture: one check holds")
  eq(
    failed[1] and failed[1].line,
    line_of(comment_dir .. "/swallowed.fixture.lua", "c1"),
    "comment fixture: the failure keeps the spec's line"
  )
  cases = dialect.run_file("h", assert_mod.new(), {
    path = comment_dir .. "/noassert.fixture.lua",
    rel = "TESTS/noassert_spec.lua",
    harness = comment_dir .. "/harness.lua",
  })
  eq(
    cases[1].status,
    "fail",
    "comment fixture: a helper that is no assertion does not count as a check"
  )
end
