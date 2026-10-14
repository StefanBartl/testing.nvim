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
      "root harness, plugin in a file of the root",
      "h_rootfile",
      "h_rootfile",
      "r1",
      "swallowed by the plugin in a file of the root",
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

  -- a failed check that escaped the spec's own pcall (cleanup, then the error is raised again) is a failure of that
  -- check with its line, not an error of the file; an error that is no failed check stays an error
  local escaped_dir = here .. "/fixtures/h_escaped"
  for _, row in ipairs({
    { "rethrow0", "e1", "error(err, 0)" },
    { "rethrow1", "e2", "error(err)" },
    { "rethrow_assert", "e3", "assert(ok, err)" },
  }) do
    local escaped_cases = dialect.run_file("h", assert_mod.new(), {
      path = escaped_dir .. "/" .. row[1] .. ".fixture.lua",
      rel = "TESTS/" .. row[1] .. "_spec.lua",
      harness = here .. "/fixtures/h/harness.lua",
    })
    local escaped = escaped_cases[1]
    eq(escaped.status, "fail", row[3] .. ": a failed check that escaped is a fail, not an error")
    eq(escaped.error, nil, row[3] .. ": the file has no error")
    local escaped_failed = {}
    for _, rec in ipairs(escaped.assertions) do
      if not rec.ok then
        escaped_failed[#escaped_failed + 1] = rec
      end
    end
    eq(#escaped_failed, 1, row[3] .. ": one failed check")
    ok(
      escaped_failed[1]
        and (escaped_failed[1].msg or ""):find("the check that fails", 1, true) ~= nil,
      row[3] .. ": the message is the check's own, without a traceback"
    )
    eq(
      escaped_failed[1] and escaped_failed[1].line,
      line_of(escaped_dir .. "/" .. row[1] .. ".fixture.lua", row[2]),
      row[3] .. ": the line is the check's, not the line that raised it again"
    )
  end
  for _, name in ipairs({ "boom", "nilindex" }) do
    local plain = dialect.run_file("h", assert_mod.new(), {
      path = escaped_dir .. "/" .. name .. ".fixture.lua",
      rel = "TESTS/" .. name .. "_spec.lua",
      harness = here .. "/fixtures/h/harness.lua",
    })[1]
    eq(
      plain.status,
      "error",
      name .. ": an error that is no failed check stays an error of the file"
    )
  end

  -- an error that reads like a failed check but did not come through a wrapped helper (the spec raised it itself, or
  -- code under test did) is a broken file, not a failed check: it ends the file as an error, and the check that was
  -- answered earlier is neither booked in its place nor takes the error's position
  local by_hand = dialect.run_file("h", assert_mod.new(), {
    path = escaped_dir .. "/by_hand.fixture.lua",
    rel = "TESTS/by_hand_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })[1]
  eq(
    by_hand.status,
    "error",
    "an error that reads like a failed check, raised by hand, is an error of the file"
  )
  has(by_hand.error and by_hand.error.message, "FAIL raised by hand", "with its own text")
  for _, rec in ipairs(by_hand.assertions) do
    ok(rec.ok, "no failed check is booked for it: " .. tostring(rec.msg))
  end
  local table_error = dialect.run_file("h", assert_mod.new(), {
    path = escaped_dir .. "/tablerr.fixture.lua",
    rel = "TESTS/tablerr_spec.lua",
    harness = here .. "/fixtures/h/harness.lua",
  })[1]
  eq(table_error.status, "error", "an error value that is no string is an error of the file")
  eq(
    table_error.error and table_error.error.message,
    "non-string error value (table)",
    "reported as what it is"
  )

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
    {
      's = "a\\\r\n" -- c\nz',
      's = "a\\\r\n"  \nz',
      "a string that ends right behind an escaped CRLF",
    },
    {
      's = "a\\\r" -- c\nz',
      's = "a\\\r"  \nz',
      "a string that ends right behind an escaped CR",
    },
    { 's = "a\\z   ', 's = "a\\z   ', "a \\z with nothing but blanks behind it" },
    {
      "x = [[abc -- no",
      "x = [[abc -- no",
      "an unterminated long string keeps the rest of the text, once",
    },
    { "x = [==[abc ]] -- no", "x = [==[abc ]] -- no", "an unterminated long string of level 2" },
  }) do
    eq(project.strip_comments(row[1]), row[2], "strip_comments: " .. row[3])
  end
  eq(
    project.assertion_names('function H.a(x) if x - 1 > 0 then error("FAIL a") end end'),
    { a = true },
    "a minus before error( does not hide the rest of the line"
  )

  -- the names of a harness text are remembered per text: every caller gets a copy (the adapter adds the names it
  -- learns while it runs), the key is the whole text, nothing is cut off a long one, and the memory is bounded
  do
    local text = 'function H.a(x) error("FAIL a") end'
    project.assertion_names(text).learned = true
    project.assertion_names(text).learned = true
    eq(
      project.assertion_names(text),
      { a = true },
      "a name one caller learned is not handed to the next"
    )
    local head = ("-- the same first line "):rep(8) .. "\n"
    eq(
      project.assertion_names(head .. 'function H.one(x) error("FAIL") end'),
      { one = true },
      "a text"
    )
    eq(
      project.assertion_names(head .. 'function H.two(x) error("FAIL") end'),
      { two = true },
      "a text that starts like the one before is another text"
    )
    eq(
      project.assertion_names(
        ("local filler = 1\n"):rep(400) .. 'function H.tail(x) error("FAIL") end'
      ),
      { tail = true },
      "an assertion at the end of a long harness is found"
    )

    local real_scan = project.scan_assertion_names
    local scans = 0
    project.scan_assertion_names = function(source)
      scans = scans + 1
      return real_scan(source)
    end
    local unique = tostring(vim.uv.hrtime())
    local function text_n(n)
      return ('-- memo test %s %d\nfunction H.f%d(x) error("FAIL") end'):format(unique, n, n)
    end
    local finished, problem = pcall(function()
      project.assertion_names(text_n(1))
      project.assertion_names(text_n(1))
      eq(scans, 1, "a text is scanned once")
      -- (the memory is shared by everything that ran in this process and clears itself now and then: of three tries
      -- one has the two texts in the same generation)
      local fewest = math.huge
      for try = 1, 3 do
        scans = 0
        for _ = 1, 3 do
          project.assertion_names(text_n(100 + 2 * try))
          project.assertion_names(text_n(101 + 2 * try))
        end
        fewest = math.min(fewest, scans)
      end
      eq(fewest, 2, "two texts that alternate are scanned once each")
      for n = 200, 270 do
        project.assertion_names(text_n(n))
      end
      scans = 0
      project.assertion_names(text_n(200))
      eq(scans, 1, "the memory is bounded: the first of 70 texts has been forgotten")
      scans = 0
      project.assertion_names(text_n(300))
      project.assertion_names(text_n(300))
      eq(scans, 1, "and it keeps working after it was cleared")
    end)
    project.scan_assertion_names = real_scan
    assert(finished, problem)
  end
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

  -- a spec that tests the harness takes an expected failure back out of `H.failures`: what is taken back is judged by
  -- WHAT is gone from the list, not by how many entries it has
  local trim_root = vim.fs.normalize(vim.fn.tempname())
  local collector = table.concat(vim.fn.readfile(here .. "/fixtures/hc/harness.lua"), "\n") .. "\n"
  -- (the fixture harness of the collector convention, plus a helper that runs a callback and a reset)
  collector = collector:gsub(
    "\nreturn H%s*$",
    "\nfunction H.group(fn)\n  fn()\nend\nfunction H.reset()\n  H.failures = {}\nend\nreturn H\n"
  )
  ---@param label string
  ---@param body string Lines of the spec (inside `return function(H)`).
  ---@param expect string[] Messages of the failed assertions that must remain (prefix match, in order).
  ---@param prelude? string Lines that run at the end of the harness file (state when the file starts).
  local function trims(label, body, expect, prelude)
    local text = prelude and collector:gsub("\nreturn H%s*$", "\n" .. prelude .. "\nreturn H\n")
      or collector
    write(trim_root .. "/harness.lua", text)
    write(trim_root .. "/row_spec.lua", "return function(H)\n" .. body .. "end\n")
    -- (the collector prints `[FAIL]` lines, the adapter reads them from `print`: keep them out of the log)
    local real_print = print
    rawset(_G, "print", function() end)
    local row_ok, row_cases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = trim_root .. "/row_spec.lua",
      rel = "TESTS/row_spec.lua",
      root = trim_root,
    })
    rawset(_G, "print", real_print)
    assert(row_ok, row_cases)
    local row_case = row_cases[1]
    local msgs = {}
    for _, rec in ipairs(row_case.assertions) do
      if not rec.ok then
        msgs[#msgs + 1] = (rec.msg or ""):sub(1, #(expect[#msgs + 1] or ""))
      end
    end
    eq(msgs, expect, label)
    eq(row_case.status, #expect > 0 and "fail" or "pass", label .. ": verdict")
  end
  local FAILING = function(name)
    return ('  H.check("%s", function()\n    H.eq(1, 2, "%s")\n  end)\n'):format(name, name)
  end
  trims(
    "a trim inside a group: the failure line it printed goes with it",
    "  H.group(function()\n"
      .. FAILING("exp")
      .. "  end)\n  table.remove(H.failures)\n  H.eq(1, 1, 'x')\n",
    {}
  )
  trims(
    "the oldest entry removed, the newer failure stays and is the one reported",
    FAILING("expected") .. FAILING("real") .. "  table.remove(H.failures, 1)\n",
    { "real: " }
  )
  trims(
    "the list replaced after an expected failure, then a real one",
    FAILING("expected") .. "  H.reset()\n" .. FAILING("real"),
    { "real: " }
  )
  trims(
    "a trim and a direct write in the same step: the direct write is seen",
    FAILING("expected") .. "  table.remove(H.failures)\n  H.failures[#H.failures + 1] = 'direct'\n",
    {
      "the project's harness collected 1 failure(s) in H.failures that the adapter did not see: direct",
    }
  )
  trims(
    "an entry that was in the list when the file started is removed, a failure of the file stays",
    FAILING("real") .. "  table.remove(H.failures, 1)\n",
    { "real: " },
    "H.failures[1] = 'earlier'"
  )
  trims(
    "the list replaced although it held an entry of the same name before",
    "  H.reset()\n" .. FAILING("same"),
    { "same: " },
    "H.failures[1] = 'same'"
  )
  vim.fn.delete(trim_root, "rf")

  -- a failed check that escaped the spec's pcall is booked at the line of the check, also when another check with the
  -- same text (the harness' error has no position of its own) was asked about before, or another question was
  -- answered in between; a message that only starts with FAIL but never passed a helper of the harness is no check
  local esc_root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(esc_root, "p")
  vim.fn.writefile(vim.fn.readfile(here .. "/fixtures/h/harness.lua"), esc_root .. "/harness.lua")
  ---@param body string
  ---@return Testing.Result.Case
  local function escapes(body)
    write(esc_root .. "/esc_spec.lua", "return function(H)\n" .. body .. "end\n")
    return dialect.run_file("h", assert_mod.new(), {
      path = esc_root .. "/esc_spec.lua",
      rel = "TESTS/esc_spec.lua",
      root = esc_root,
    })[1]
  end
  local same_text = escapes(table.concat({
    "  pcall(function() H.eq(1, 2, 'same') end)",
    "  local ok, err = pcall(function()",
    "    H.eq(1, 2, 'same')",
    "  end)",
    "  if not ok then error(err, 0) end",
    "",
  }, "\n"))
  eq(same_text.status, "fail", "escaped check with the text of an answered one: a failure")
  eq(
    same_text.assertions[#same_text.assertions].line,
    4,
    "escaped check with the text of an answered one: at its own line"
  )
  local between = escapes(table.concat({
    "  local ok, err = pcall(function() H.eq(1, 2, 'first') end)",
    "  pcall(function() H.eq(3, 4, 'second') end)",
    "  if not ok then error(err) end",
    "",
  }, "\n"))
  eq(between.status, "fail", "escaped check, another question answered in between: a failure")
  has(
    between.assertions[#between.assertions].file,
    "esc_spec.lua",
    "... in the spec file, not a garbled path"
  )
  eq(between.assertions[#between.assertions].line, 2, "... at the line of the check")
  local foreign =
    escapes('  H.eq(1, 1, "holds")\n  error("FAIL: the plugin could not connect", 0)\n')
  eq(
    foreign.status,
    "error",
    "a message that starts with FAIL but never passed the harness is an error"
  )
  vim.fn.delete(esc_root, "rf")

  -- gaps found by mutating the fixes: sites of nested helpers, the shapes of an escaped error, baseline entries that
  -- come back, unseen entries, root harnesses (also through a symlink), memory bound of the sites
  do
    local gap_root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(gap_root, "p")
    local h_text = table.concat(vim.fn.readfile(here .. "/fixtures/h/harness.lua"), "\n") .. "\n"
    local hc_text = table.concat(vim.fn.readfile(here .. "/fixtures/hc/harness.lua"), "\n") .. "\n"
    ---@param text string
    ---@param extra string Lines added before the harness returns its table.
    ---@return string
    local function with_extra(text, extra)
      -- (a function as the replacement: the text is taken literally, `%s` in it is no capture)
      return (
        text:gsub("\nreturn H%s*$", function()
          return "\n" .. extra .. "\nreturn H\n"
        end)
      )
    end
    ---@param harness_text string
    ---@param body string
    ---@param dir? string
    ---@return Testing.Result.Case
    local function gap_case(harness_text, body, dir)
      dir = dir or gap_root
      write(dir .. "/harness.lua", harness_text)
      write(dir .. "/gap_spec.lua", "return function(H)\n" .. body .. "end\n")
      local real_print = print
      rawset(_G, "print", function() end)
      local done, gap_cases = pcall(dialect.run_file, "h", assert_mod.new(), {
        path = dir .. "/gap_spec.lua",
        rel = "TESTS/gap_spec.lua",
        root = dir,
      })
      rawset(_G, "print", real_print)
      assert(done, gap_cases)
      return gap_cases[1]
    end
    ---@param gap Testing.Result.Case
    ---@return string[] msgs
    ---@return integer[] lines
    local function failures_of(gap)
      local msgs, lines = {}, {}
      for _, rec in ipairs(gap.assertions) do
        if not rec.ok then
          msgs[#msgs + 1] = rec.msg or ""
          lines[#lines + 1] = rec.line or -1
        end
      end
      return msgs, lines
    end
    -- a harness whose error carries the position of the harness itself (level 1)
    local positioned = with_extra(
      h_text,
      "function H.eq1(a, b, msg)\n  if a ~= b then\n    error(('FAIL %s: expected %q, got %q'):format(msg or '', tostring(b), tostring(a)), 1)\n  end\nend"
    )
    -- a helper of the harness that calls another one after the raise: the nested check keeps the place it was made at
    local tidy = with_extra(
      h_text,
      "function H.tidy(fn)\n  local ran, err = pcall(fn)\n  H.ok(true, 'cleaned up')\n  if not ran then\n    error(err, 0)\n  end\nend"
    )
    local nested_body = table.concat({
      "  local ran, err = pcall(function()",
      "    H.tidy(function()",
      '      H.eq(1, 2, "inner") -- MARK',
      "    end)",
      "  end)",
      "  if not ran then",
      "    error(err, 0)",
      "  end",
      "",
    }, "\n")
    local nested = gap_case(tidy, nested_body)
    local nested_msgs, nested_lines = failures_of(nested)
    eq(nested.status, "fail", "nested helper: the check that escaped is a failure")
    eq(
      nested_lines,
      { 4 },
      "nested helper: at the line of the inner check, not of the helper that ran it"
    )
    has(nested_msgs[1], "inner", "nested helper: with its own message")

    -- the shapes of an error that got out of the spec's protected call: whole text, a position in front, a traceback
    -- behind it, both; the message may have line breaks
    for _, row in ipairs({
      {
        "multi-line message, error(err, 0)",
        'H.eq(1, 2, "first\\nsecond")',
        "pcall(function()",
        "error(err, 0)",
      },
      {
        "multi-line message, error(err)",
        'H.eq(1, 2, "first\\nsecond")',
        "pcall(function()",
        "error(err)",
      },
      {
        "message positioned by the harness, error(err, 0)",
        'H.eq1(1, 2, "first\\nsecond")',
        "pcall(function()",
        "error(err, 0)",
        true,
      },
      {
        "traceback of a multi-line message, error(err)",
        'H.eq(1, 2, "first\\nsecond")',
        "xpcall(function()",
        "error(err)",
      },
      { "traceback, error(err, 0)", 'H.eq(1, 2, "traced")', "xpcall(function()", "error(err, 0)" },
      { "traceback, error(err)", 'H.eq(1, 2, "traced")', "xpcall(function()", "error(err)" },
    }) do
      local close = row[3]:find("^xpcall") and "end, debug.traceback)" or "end)"
      local body = table.concat({
        "  local ran, err = " .. row[3],
        "    " .. row[2],
        "  " .. close,
        "  if not ran then",
        "    " .. row[4],
        "  end",
        "",
      }, "\n")
      local escaped = gap_case(row[5] and positioned or h_text, body)
      local escaped_msgs, lines = failures_of(escaped)
      eq(escaped.status, "fail", row[1] .. ": a failed check that escaped is a fail, not an error")
      eq(escaped.error, nil, row[1] .. ": and the file has no error")
      eq(lines, { 3 }, row[1] .. ": booked at the line of the check")
      ok(
        not (escaped_msgs[1] or ""):find("stack traceback", 1, true),
        row[1] .. ": the message is the check's, without the traceback"
      )
    end

    -- many other checks were answered in between: the one that escapes is still known
    local crowded = gap_case(
      h_text,
      table.concat({
        '  local ran, err = pcall(function() H.eq(1, 2, "first") end)',
        "  for i = 1, 10 do",
        '    pcall(function() H.eq(1, 2, "other " .. i) end)',
        "  end",
        "  if not ran then",
        "    error(err, 0)",
        "  end",
        "",
      }, "\n")
    )
    local _, crowded_lines = failures_of(crowded)
    eq(crowded.status, "fail", "an escaped check among many answered ones is a failure")
    eq(crowded_lines, { 2 }, "at its own line")

    -- the entries of the list when the file started: an equal one added by the file is new, one that stays is not
    local function entry_messages(prelude, body)
      local text = with_extra(hc_text, prelude)
      local msgs = failures_of(gap_case(text, body))
      return msgs
    end
    eq(
      entry_messages(
        "H.failures[1] = 'e1'",
        '  H.eq(1, 1, "anchor")\n  H.failures[#H.failures + 1] = "e1"\n'
      ),
      {
        "the project's harness collected 1 failure(s) in H.failures that the adapter did not see: e1",
      },
      "an entry equal to one of the list at the start is still a new entry, shown once"
    )
    eq(
      entry_messages(
        "",
        '  H.eq(1, 1, "anchor")\n  H.failures[#H.failures + 1] = "d2"\n  H.check("n1", function() H.eq(1, 2, "m") end)\n'
      ),
      {
        "n1: m: expected 2, got 1",
        "the project's harness collected 1 failure(s) in H.failures that the adapter did not see: d2",
      },
      "an entry written by hand before a check that fails is not taken for the entry of the check"
    )
    eq(
      entry_messages(
        "",
        '  H.eq(1, 1, "anchor")\n  H.failures[#H.failures + 1] = ("x"):rep(300)\n  H.failures[#H.failures + 1] = "d2"\n  H.failures[#H.failures + 1] = "d3"\n  H.failures[#H.failures + 1] = "d4"\n'
      ),
      {
        "the project's harness collected 4 failure(s) in H.failures that the adapter did not see: "
          .. ("x"):rep(200)
          .. "; d2; d3",
      },
      "of the entries nobody saw the first three are shown, each cut at 200 characters"
    )
    eq(
      gap_case(
        with_extra(hc_text, ""),
        '  H.eq(1, 1, "anchor")\n  H.failures[#H.failures + 1] = 0 / 0\n'
      ).error,
      nil,
      "an entry that is not equal to itself does not end the file"
    )
    -- a check that put three entries into the list: when the spec takes one back, the check stays a failure of the file
    local multi = with_extra(
      hc_text,
      "function H.check(name, fn)\n  if not pcall(fn) then\n    H.failures[#H.failures + 1] = name\n  end\nend"
    )
    eq(
      failures_of(
        gap_case(
          multi,
          '  H.eq(1, 1, "anchor")\n  H.check("n", function()\n    H.failures[#H.failures + 1] = "x1"\n    H.failures[#H.failures + 1] = "x2"\n    error("boom", 0)\n  end)\n  table.remove(H.failures, 1)\n'
        )
      ),
      { "n: boom" },
      "a check that appended several entries stays recorded while one of them is still in the list"
    )
    -- a failure that is counted but not listed stays a failure
    local counted = with_extra(
      hc_text,
      "H.failed = 0\nfunction H.check(name, fn)\n  if not pcall(fn) then\n    H.failed = H.failed + 1\n  end\nend"
    )
    local counted_msgs = failures_of(
      gap_case(
        counted,
        '  H.eq(1, 1, "anchor")\n  H.check("x", function() H.eq(1, 2, "boom") end)\n'
      )
    )
    eq(
      counted_msgs,
      { "x: boom: expected 2, got 1" },
      "a failure the harness only counts is recorded"
    )

    -- a harness in the root: its own file is the harness (its pcall passes the error on)
    local own = gap_case(
      h_text,
      table.concat({
        "  local ran = pcall(function()",
        "    H.guarded(function()",
        '      H.eq(1, 2, "q")',
        "    end)",
        "  end)",
        '  H.ok(not ran, "answered")',
        "",
      }, "\n")
    )
    eq(
      own.status,
      "pass",
      "a root harness: its own helper that cleans up and raises again is passed over"
    )

    -- ... also when the root is reached through a symlink
    local real_root = vim.fs.normalize(vim.fn.tempname())
    local link_root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(real_root, "p")
    write(
      real_root .. "/emit.lua",
      table.concat(vim.fn.readfile(here .. "/fixtures/h_rootfile/emit.lua"), "\n")
    )
    if vim.uv.fs_symlink(real_root, link_root, { dir = true, junction = true }) then
      local link_harness =
        table.concat(vim.fn.readfile(here .. "/fixtures/h_rootfile/harness.lua"), "\n")
      write(real_root .. "/harness.lua", link_harness)
      write(
        real_root .. "/gap_spec.lua",
        table.concat(vim.fn.readfile(here .. "/fixtures/h_rootfile/h_rootfile.fixture.lua"), "\n")
      )
      local via_link = dialect.run_file("h", assert_mod.new(), {
        path = real_root .. "/gap_spec.lua",
        rel = "TESTS/gap_spec.lua",
        harness = real_root .. "/harness.lua",
        root = link_root,
      })[1]
      eq(
        via_link.status,
        "fail",
        "a root reached through a symlink is the root: the plugin in a file next to the harness is not the harness"
      )
      vim.uv.fs_unlink(link_root)
    end
    vim.fn.delete(real_root, "rf")

    -- the places remembered for the texts of answered checks are bounded
    local bounded = gap_case(
      h_text,
      table.concat({
        "  collectgarbage()",
        "  collectgarbage()",
        '  local before = collectgarbage("count")',
        "  for i = 1, 1500 do",
        '    pcall(function() H.eq(1, 2, ("x"):rep(8000) .. i) end)',
        "  end",
        "  collectgarbage()",
        "  collectgarbage()",
        '  H.ok(collectgarbage("count") - before < 4000, "the places of answered checks are not kept without limit")',
        "",
      }, "\n")
    )
    eq(bounded.status, "pass", "the memory of the places of answered checks is bounded")
    -- a long run of word characters (a blob in a harness file) is scanned in linear time
    local blob = ("a"):rep(40000)
    local started = vim.uv.hrtime()
    project.scan_assertion_names(
      "local " .. blob .. " = 1\nfunction H.eq() error('FAIL') end\n" .. blob .. "\n"
    )
    ok(
      (vim.uv.hrtime() - started) / 1e6 < 1500,
      "the scan for assertion names does not start at every letter of a long word"
    )
    vim.fn.delete(gap_root, "rf")
  end

  -- failure lines that a nested collector printed are given back once when the spec takes both failures out of the list
  do
    local root_f1 = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root_f1, "p")
    write(
      root_f1 .. "/harness.lua",
      table.concat(vim.fn.readfile(here .. "/fixtures/hc/harness.lua"), "\n") .. "\n"
    )
    write(
      root_f1 .. "/nested_spec.lua",
      table.concat({
        "return function(H)",
        '  H.eq(1, 1, "anchor")',
        '  H.check("outer", function()',
        '    H.check("inner", function() H.eq(1, 2, "in") end)',
        '    H.eq(1, 2, "out")',
        "  end)",
        "  H.failures = {}",
        '  H.shout("lost")',
        "end",
        "",
      }, "\n")
    )
    local real_print = print
    rawset(_G, "print", function() end)
    local done, nested_cases = pcall(dialect.run_file, "h", assert_mod.new(), {
      path = root_f1 .. "/nested_spec.lua",
      rel = "TESTS/nested_spec.lua",
      root = root_f1,
    })
    rawset(_G, "print", real_print)
    assert(done, nested_cases)
    eq(
      nested_cases[1].status,
      "fail",
      "nested collectors taken back: a failure line nobody recorded is still seen"
    )
    local shouted = false
    for _, rec in ipairs(nested_cases[1].assertions) do
      shouted = shouted
        or (not rec.ok and (rec.msg or ""):find("printed 1 failure line", 1, true) ~= nil)
    end
    ok(shouted, "and it is reported as the one failure line that was printed and not recorded")
    vim.fn.delete(root_f1, "rf")
  end
end
