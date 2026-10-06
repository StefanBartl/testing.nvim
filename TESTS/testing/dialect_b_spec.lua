-- TESTS/testing/dialect_b_spec.lua -- dialect B (markdown.nvim / diff.nvim): the fixture copies the
-- calling convention, ALL failures are collected, the helpers behave like the originals.

return function(H)
  -- the specs of the shim open buffers; the editor is left as found
  local bufs_before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    bufs_before[b] = true
  end
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
  local shim = require("testing.dialect.harness_b")

  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  ---@param name string
  ---@return string
  local function fixture(name)
    return here .. "/fixtures/" .. name
  end
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
  ---@param text string
  ---@return string
  local function temp_spec(name, text)
    local path = vim.fn.tempname() .. "_" .. name .. ".lua"
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
    return path
  end

  -- the failing fixture: every failure is collected, the file runs to its end
  local a = assert_mod.new()
  local path = fixture("b_fail.fixture.lua")
  local cases = dialect.run_file("b", a, { path = path, rel = "TESTS/b_fail_spec.lua" })
  eq(#cases, 1, "dialect b: one case per file")
  local case = cases[1]
  eq(case.id, "TESTS/b_fail_spec.lua::b_fail_spec.lua", "case id is <file>::<file name>")
  eq(case.status, "fail", "a failed check makes the file fail")
  eq(case.error, nil, "no error: the file ran to its end")
  local failed = {}
  for _, rec in ipairs(case.assertions) do
    if not rec.ok then
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 2, "BOTH failures are visible, not only the first")
  eq(failed[1].msg, "b first wrong", "first failure message")
  eq(failed[2].msg, "b second wrong", "second failure message")
  eq(failed[1].line, line_of(path, "b1"), "first failure: the fixture's own line")
  eq(failed[2].line, line_of(path, "b2"), "second failure: the fixture's own line")
  has(failed[1].file, "b_fail.fixture.lua", "the call site is the fixture, not the shim")
  ok(#case.assertions >= 9, "the checks around the failures ran and were recorded")

  -- a file whose checks all hold passes (negative control: the verdict can be green)
  a = assert_mod.new()
  cases = dialect.run_file("b", a, {
    path = temp_spec(
      "b_pass",
      'return function(H)\n  H.eq(1, 1, "one")\n  H.ok(true, "two")\nend\n'
    ),
    rel = "TESTS/b_pass_spec.lua",
  })
  eq(cases[1].status, "pass", "all checks hold: pass")
  eq(#cases[1].assertions, 2, "two checks, two records")

  -- a file with no check is a failure (P4), a raise is an error and keeps the earlier records
  a = assert_mod.new()
  cases = dialect.run_file("b", a, {
    path = temp_spec("b_none", "return function(H)\n  local _ = H\nend\n"),
    rel = "TESTS/b_none_spec.lua",
  })
  eq(cases[1].status, "fail", "no assertion at all fails")
  a = assert_mod.new()
  cases = dialect.run_file("b", a, {
    path = temp_spec(
      "b_raise",
      'return function(H)\n  H.eq(1, 1, "before")\n  error("boom")\nend\n'
    ),
    rel = "TESTS/b_raise_spec.lua",
  })
  eq(cases[1].status, "error", "a raise ends the file as error")
  eq(#cases[1].assertions, 1, "the record before the raise survives")
  has(cases[1].error.message, "boom", "the message of the raise")
  -- a spec that returns no function is named, not a crash of the driver
  a = assert_mod.new()
  cases = dialect.run_file("b", a, {
    path = temp_spec("b_nofn", "return 5\n"),
    rel = "TESTS/b_nofn_spec.lua",
  })
  eq(cases[1].status, "error", "a spec without function(H) is an error")
  has(cases[1].error.message, "must return `function(H)`", "the message says what was expected")
  has(cases[1].error.message, "number", "and what it got")

  -- helpers, directly
  a = assert_mod.new()
  local seen = {}
  a.run_case({ file = "TESTS/x_spec.lua", name = "helpers" }, function()
    local h = shim.new(a.scope())
    h.eq(1, 1, "needs one assertion")
    local buf = h.scratch()
    seen.current = vim.api.nvim_get_current_buf() == buf
    seen.buftype = vim.bo[buf].buftype
    seen.ft_default = vim.bo[buf].filetype
    local typed = h.scratch("markdown")
    seen.ft = vim.bo[typed].filetype

    seen.root = h.tmproot("testing_b_spec_root")
    seen.root_again = h.tmproot("testing_b_spec_root")

    seen.dir = h.tmpdir()
    seen.dir2 = h.tmpdir()
    local target = seen.dir .. "a/b/c.txt"
    h.write_file(target, { "x", "y", "z" })
    seen.lines = vim.fn.readfile(target)

    seen.unknown = h.not_in_the_harness
    seen.inspected = type(vim.inspect(h))
    seen.canon_missing = h.canonical(seen.dir .. "does/not/exist.txt")
  end)
  eq(seen.current, true, "scratch() makes the buffer current")
  eq(seen.buftype, "nofile", "scratch() is a scratch buffer")
  eq(seen.ft_default, "", "scratch() without a filetype sets none")
  eq(seen.ft, "markdown", "scratch(ft) sets the filetype")
  eq(vim.fn.isdirectory(seen.root), 1, "tmproot() creates the directory")
  eq(seen.root, seen.root_again, "tmproot() is stable for one name")
  eq(seen.root:find("\\", 1, true), nil, "tmproot() uses forward slashes")
  ok(seen.dir ~= seen.dir2, "tmpdir() answers a fresh directory each time")
  eq(vim.fn.isdirectory(seen.dir), 1, "tmpdir() creates it")
  ok(seen.dir:sub(-1) == "/" or seen.dir:sub(-1) == "\\", "tmpdir() ends with a separator")
  eq(seen.lines, { "x", "y", "z" }, "write_file() creates parents and writes the lines")
  eq(seen.unknown, nil, "an unknown key reads nil")
  eq(seen.inspected, "string", "vim.inspect(H) does not raise")
  has(
    seen.canon_missing,
    "exist.txt",
    "canonical() of a missing path falls back to the absolute path"
  )
  eq(seen.canon_missing:find("\\", 1, true), nil, "canonical() answers forward slashes")
  vim.fn.delete(seen.root, "rf")
  vim.fn.delete(seen.dir, "rf")
  vim.fn.delete(seen.dir2, "rf")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not bufs_before[b] then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end
