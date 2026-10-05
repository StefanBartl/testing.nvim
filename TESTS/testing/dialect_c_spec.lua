-- TESTS/testing/dialect_c_spec.lua -- dialect C (images.nvim): falsy / contains / scratch(lines, ft) /
-- tmpdir(fn) / write on collecting assertions; a non-string haystack fails instead of raising.

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
  local shim = require("testing.dialect.harness_c")

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

  -- the failing fixture: every failure is collected (falsy, contains, a non-string haystack)
  local a = assert_mod.new()
  local path = here .. "/fixtures/c_fail.fixture.lua"
  local cases = dialect.run_file("c", a, { path = path, rel = "TESTS/c_fail_spec.lua" })
  eq(#cases, 1, "dialect c: one case per file")
  local case = cases[1]
  eq(case.status, "fail", "failed checks make the file fail")
  eq(case.error, nil, "no error: the file ran to its end, tmpdir(fn) included")
  local failed = {}
  for _, rec in ipairs(case.assertions) do
    if not rec.ok then
      failed[#failed + 1] = rec
    end
  end
  eq(#failed, 3, "ALL THREE failures are visible")
  eq(failed[1].line, line_of(path, "c1"), "falsy on a truthy value: the fixture's line")
  eq(failed[2].line, line_of(path, "c2"), "contains without the needle: the fixture's line")
  eq(failed[3].line, line_of(path, "c3"), "contains on nil: the fixture's line")
  eq(failed[1].msg, "falsy fails on a truthy value", "caller message kept")
  has(failed[2].msg, "contains fails", "caller message kept")
  has(failed[3].msg, "does not raise", "a nil haystack is a recorded failure, not a raise")
  ok(#case.assertions >= 10, "the checks between the failures were recorded as well")

  -- helpers, directly
  a = assert_mod.new()
  local seen = {}
  a.run_case({ file = "TESTS/x_spec.lua", name = "helpers" }, function()
    local h = shim.new(a.scope())
    h.eq(1, 1, "needs one assertion")
    local buf = h.scratch()
    seen.empty_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local buf2 = h.scratch({ "one", "two" }, "text")
    seen.lines = vim.api.nvim_buf_get_lines(buf2, 0, -1, false)
    seen.ft = vim.bo[buf2].filetype
    seen.current = vim.api.nvim_get_current_buf() == buf2

    -- tmpdir(fn): fn gets a slash path, the directory is removed even when fn raises, the raise comes back
    local kept
    local got, err = pcall(h.tmpdir, function(dir)
      kept = dir
      h.write(dir .. "/a/b.txt", "bytes\r\nkept")
      seen.bytes = table.concat(vim.fn.readfile(dir .. "/a/b.txt", "b"), "|")
      error("inside", 0)
    end)
    seen.raised = { got, err }
    seen.kept_gone = vim.fn.isdirectory(kept)
    seen.slash = kept:find("\\", 1, true)
    seen.unknown = h.no_such_key
    seen.inspected = type(vim.inspect(h))
  end)
  eq(seen.empty_lines, { "" }, "scratch() without lines leaves the empty buffer")
  eq(seen.lines, { "one", "two" }, "scratch(lines, ft) sets the lines")
  eq(seen.ft, "text", "scratch(lines, ft) sets the filetype")
  eq(seen.current, true, "scratch() makes the buffer current")
  eq(seen.raised, { false, "inside" }, "tmpdir(fn) re-raises what fn raised, untouched")
  eq(seen.kept_gone, 0, "tmpdir(fn) removed the directory although fn raised")
  eq(seen.slash, nil, "tmpdir(fn) hands over a forward-slash path")
  has(seen.bytes, "bytes", "write() wrote the content in binary mode")
  eq(seen.unknown, nil, "an unknown key reads nil")
  eq(seen.inspected, "string", "vim.inspect(H) does not raise")

  -- the aliases are the kernel's own functions: the recorded call site is the caller's line
  a = assert_mod.new()
  local h2 = shim.new(a)
  eq(h2.eq, a.eq, "H.eq is the context's eq")
  eq(h2.ok, a.ok, "H.ok is the context's ok")
  eq(h2.falsy, a.not_ok, "H.falsy is the context's not_ok")
  eq(h2.contains, a.has, "H.contains is the context's has")
end
