-- TESTS/testing/dialect_harness_a_spec.lua -- the dialect A shim: lib.nvim's `H` on collecting
-- assertions (collect instead of raise, call sites, helpers, restore-then-reraise).

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
  local shim = require("testing.dialect.harness_a")

  ---@return Testing.Assert.Context, table
  local function new()
    local a = assert_mod.new()
    return a, shim.new(a)
  end

  ---@param a Testing.Assert.Context
  ---@param body fun(h: table)
  ---@param h table
  ---@return Testing.Result.Case
  local function run(a, h, body)
    return a.run_case({ file = "TESTS/x_spec.lua", name = "x" }, function()
      body(h)
    end)
  end

  -- every failed H.eq / H.ok of a file is recorded, the body keeps running (P1)
  local a, h = new()
  local reached = false
  local case = run(a, h, function(S)
    S.eq(1, 2, "first")
    S.eq("a", "a", "holds")
    S.ok(nil, "second")
    S.eq({ 1 }, { 1 }, "tables are compared by identity, like the old H.eq")
    reached = true
  end)
  ok(reached, "a failed H.eq does not stop the spec")
  eq(case.status, "fail", "a failed check makes the file fail")
  eq(#case.assertions, 4, "all four checks are recorded")
  eq(case.assertions[1].ok, false, "first failed")
  eq(case.assertions[2].ok, true, "second held")
  eq(case.assertions[3].ok, false, "third failed")
  eq(case.assertions[4].ok, false, "strict equality: equal tables are not ==")
  eq(case.assertions[1].msg, "first", "the caller message is kept")

  -- the recorded call site is the spec's own line (H.eq is not wrapped: a.depth stays 0)
  a, h = new()
  local line
  case = run(a, h, function(S)
    line = debug.getinfo(1, "l").currentline + 1
    S.eq(1, 2, "located")
  end)
  eq(case.assertions[1].line, line, "line of the H.eq call")
  has(case.assertions[1].file, "dialect_harness_a_spec.lua", "file of the H.eq call")

  -- aliases like `local eq, ok = H.eq, H.ok` work (the specs use them everywhere)
  a, h = new()
  case = run(a, h, function(S)
    local e, o = S.eq, S.ok
    e(1, 1, "alias eq")
    o(true, "alias ok")
  end)
  eq(case.status, "pass", "aliased calls record on the bound case")
  eq(#case.assertions, 2, "two aliased calls, two records")

  -- a raise of the spec itself ends the file as an error, earlier records survive
  a, h = new()
  case = run(a, h, function(S)
    S.eq(1, 1, "before")
    error("boom")
  end)
  eq(case.status, "error", "a thrown error is status error")
  eq(#case.assertions, 1, "records before the raise are kept")
  has(case.error.message, "boom", "message of the raise")

  -- helpers
  local path = h.tmpfile(".txt")
  has(path, ".txt", "tmpfile: suffix")
  eq(vim.uv.fs_stat(path), nil, "tmpfile: not created on disk")
  has(h.tmpfile(), ".tmp", "tmpfile: default suffix")
  local f = assert(io.open(path, "wb"))
  f:write("one\r\ntwo\nthree")
  f:close()
  local lines = h.read_lines(path)
  eq(#lines, 3, "read_lines: three lines")
  eq(lines[3], "three", "read_lines: last line without newline")
  eq(#h.read_lines(path .. ".missing"), 0, "read_lines: a missing file is an empty list")
  os.remove(path)

  -- with_patched: restores, and re-raises the raise of its body
  local target = { k = "orig" }
  h.with_patched(target, "k", "patched", function()
    eq(target.k, "patched", "patched inside")
  end)
  eq(target.k, "orig", "restored after a normal run")
  local called, err = pcall(h.with_patched, target, "k", "patched", function()
    error("inner boom", 0)
  end)
  eq(called, false, "with_patched re-raises")
  eq(err, "inner boom", "the original message arrives untouched")
  eq(target.k, "orig", "restored after a raise too")

  -- a failed H.eq INSIDE with_patched is collected, not raised, and the original comes back
  a, h = new()
  case = run(a, h, function(S)
    S.with_patched(target, "k", "p2", function()
      S.eq(target.k, "nope", "inside")
    end)
  end)
  eq(case.status, "fail", "the collected failure fails the file")
  eq(target.k, "orig", "restored")

  -- with_stdpath_config answers config only
  local real_config = vim.fn.stdpath("config")
  h.with_stdpath_config("X:/fake", function()
    eq(vim.fn.stdpath("config"), "X:/fake", "config is redirected")
    eq(vim.fn.stdpath("data"), vim.fn.stdpath("data"), "other kinds still answer")
  end)
  eq(vim.fn.stdpath("config"), real_config, "stdpath is restored")

  -- an unknown H key answers nil, like the old table: feature detection and inspection must not raise
  local detected, value = pcall(function()
    if h.has then
      return "present"
    end
    return h.has
  end)
  eq(detected, true, "reading an unknown key does not raise")
  eq(value, nil, "an unknown key is nil")
  eq(type(vim.inspect(h)), "string", "vim.inspect(H) works")
  eq(rawget(h, "has"), nil, "nothing was added by the read")
  -- calling a key the shim lacks fails at the call and names the key
  local call_ok, called_err = pcall(function()
    return h.has("a", "a", "x")
  end)
  eq(call_ok, false, "calling a missing key fails")
  has(called_err, "has", "the message names the key")
end
