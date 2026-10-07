-- TESTS/testing/retry_spec.lua -- `--retry-failed <n>` and `--allow-flaky`: a red case runs again, one that passes
-- is FLAKY and the run stays red, `--allow-flaky` is the explicit choice to count it as green (and the list says
-- so), a case that never passes stays red, nothing flaky is ever cached. End to end through `cli.main` on a
-- project whose spec fails a number of times (a counter file), once in this editor and once in a child editor.

return function(H)
  local ok = H.ok
  local eq = H.eq
  local cli = require("testing.cli")
  local result = require("testing.core.result")
  local retry = require("testing.run.retry")
  local args_mod = require("testing.args")
  local json = require("lib.nvim.json")

  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. needle .. " in " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function slurp(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end

  ---A spec that counts its own executions in `counter` and passes from the `from`-th on.
  local function counting_spec(counter, from)
    return ([[
return function(H)
  local path = %q
  local n = 0
  local f = io.open(path, "rb")
  if f then
    n = tonumber(f:read("*a")) or 0
    f:close()
  end
  f = assert(io.open(path, "wb"))
  f:write(tostring(n + 1))
  f:close()
  H.ok(n + 1 >= %d, "attempt " .. (n + 1))
end
]]):format(counter, from)
  end
  local ALWAYS_GREEN = "return function(H) H.ok(true, 'green') end\n"

  local n_roots = 0
  ---@param files table<string, string>
  ---@return string root
  local function project(files)
    n_roots = n_roots + 1
    local root = tmp .. "/proj" .. n_roots
    write(root .. "/.testing.lua", "return { guards = { fs = 'off' }, isolated = 'none' }\n")
    for rel, text in pairs(files) do
      write(root .. "/" .. rel, text)
    end
    return root
  end

  ---@param root string
  ---@param argv string[]
  local function go(root, argv)
    local out, err = {}, {}
    local list = { root }
    vim.list_extend(list, argv)
    local code = cli.main(list, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      affected = { getenv = function() end },
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  ---@param root string
  ---@param argv string[]
  ---@return table r, table ir
  local function go_json(root, argv)
    local path = root .. "/ir.json"
    vim.fn.delete(path)
    local list = vim.list_extend({ "--json", path }, argv)
    local r = go(root, list)
    local text = slurp(path)
    local ir = text and json.decode(text) or {}
    return r, ir
  end
  local function case_of(ir, file)
    for _, c in ipairs(ir.cases or {}) do
      if c.file == file then
        return c
      end
    end
  end

  -- ---------------------------------------------------------------------------------------- the CLI
  local function parse(...)
    return args_mod.parse({ ".", ... })
  end
  eq(select(1, parse("--retry-failed", "3")).retry_failed, 3, "--retry-failed 3")
  ok(select(1, parse("--retry-failed", "10")) ~= nil, "10 is the largest")
  local bad, why = parse("--retry-failed", "11")
  ok(bad == nil and why:find("at most 10", 1, true) ~= nil, "11 is refused: " .. tostring(why))
  bad, why = parse("--retry-failed", "0")
  ok(bad == nil, "0 is refused: " .. tostring(why))
  bad, why = parse("--retry-failed", "x")
  ok(bad == nil, "a word is refused: " .. tostring(why))
  bad, why = parse("--allow-flaky")
  ok(
    bad == nil and why:find("needs --retry-failed", 1, true) ~= nil,
    "--allow-flaky alone: " .. tostring(why)
  )
  bad, why = parse("--retry-failed", "2", "--list")
  ok(bad == nil and why:find("cannot be combined", 1, true) ~= nil, "not with --list")
  bad = parse("--retry-failed", "2", "--watch")
  ok(bad == nil, "not with --watch")
  eq(select(1, parse("--retry-failed", "2", "--allow-flaky")).allow_flaky, true, "the pair")
  eq(select(1, parse()).allow_flaky, false, "off by default")

  -- ------------------------------------------------------------------- passes on the second attempt
  do
    local counter = tmp .. "/c1.txt"
    local root = project({
      ["TESTS/flaky_spec.lua"] = counting_spec(counter, 2),
      ["TESTS/steady_spec.lua"] = ALWAYS_GREEN,
    })
    local r, ir = go_json(root, { "--retry-failed", "2", "--cached" })
    eq(r.code, 1, "flaky stays RED: exit 1\n" .. r.out .. r.err)
    lacks(r.out, "TESTING_OK", "no sentinel")
    has(
      r.out,
      "flaky: 1 case(s) failed and then passed on a retry: the run stays RED",
      "the list says it"
    )
    has(r.out, "flaky_spec.lua", "and names the case")
    has(r.out, "passed on retry 1 of 2", "and the retry")
    eq(slurp(counter), "2", "the file ran twice")
    local c = case_of(ir, "TESTS/flaky_spec.lua")
    eq(c.status, "fail", "the case is still a failure in the IR")
    eq(c.flaky, true, "marked flaky")
    eq(c.retries, 1, "with the retry that passed")
    ok(
      vim.tbl_contains(
        c.notes,
        "flaky: failed, then passed on retry 1 of 2: the run stays red (--allow-flaky counts it as green)"
      ),
      "and a note"
    )
    eq(ir.summary.fail, 1, "the summary counts it as failed")
    eq(case_of(ir, "TESTS/steady_spec.lua").status, "pass", "the other file is green")
    local valid, problems = result.validate(ir)
    ok(valid, "the IR with a flaky case is valid: " .. vim.inspect(problems))
    -- the second run: the flaky file was never cached, the steady one was
    write(counter, "0")
    r = go(root, { "--retry-failed", "2", "--cached" })
    eq(slurp(counter), "2", "a flaky file is never taken from the cache: it ran again")
    has(r.out, "1 cached, not run", "while the steady file came from the cache")
  end

  -- --------------------------------------------------------------------------------- --allow-flaky
  do
    local counter = tmp .. "/c2.txt"
    local root = project({
      ["TESTS/flaky_spec.lua"] = counting_spec(counter, 2),
      ["TESTS/steady_spec.lua"] = ALWAYS_GREEN,
    })
    local r, ir = go_json(root, { "--retry-failed", "3", "--allow-flaky", "--cached" })
    eq(r.code, 0, "--allow-flaky: green\n" .. r.out .. r.err)
    has(r.out, "--allow-flaky counts them as green, they are never cached", "but the list is there")
    has(r.out, "flaky_spec.lua", "naming the case")
    local c = case_of(ir, "TESTS/flaky_spec.lua")
    eq(c.status, "pass", "the passing result replaces the red one")
    eq(c.flaky, true, "and says it was flaky")
    eq(c.retries, 1, "after one retry")
    ok(c.notes[#c.notes]:find("failed first", 1, true) ~= nil, "the note holds the first failure")
    eq(ir.summary.fail, 0, "nothing failed any more")
    eq(ir.summary.pass, 2, "both pass")
    ok((result.validate(ir)), "valid")
    write(counter, "0")
    go(root, { "--retry-failed", "3", "--allow-flaky", "--cached" })
    eq(slurp(counter), "2", "a flaky case that was counted as green is not cached either")
  end

  -- ----------------------------------------------------------------------------- never passes
  do
    local counter = tmp .. "/c3.txt"
    local root = project({ ["TESTS/broken_spec.lua"] = counting_spec(counter, 99) })
    local r, ir = go_json(root, { "--retry-failed", "2" })
    eq(r.code, 1, "never passes: red")
    eq(slurp(counter), "3", "the first run and two retries")
    local c = case_of(ir, "TESTS/broken_spec.lua")
    eq(c.status, "fail", "fail")
    eq(c.flaky, nil, "not flaky")
    eq(c.retries, 2, "retries = the bound")
    lacks(r.out, "flaky:", "no flaky list")
    has(
      r.out,
      "retry: 1 case(s) failed on all 2 retries as well (red, not flaky)",
      "but it says what happened"
    )
    -- with --allow-flaky it stays red too
    write(counter, "0")
    r = go(root, { "--retry-failed", "2", "--allow-flaky" })
    eq(r.code, 1, "--allow-flaky does not make a failure green")
  end

  -- the bound is the bound: passes on the third attempt, one retry is not enough
  do
    local counter = tmp .. "/c4.txt"
    local root = project({ ["TESTS/late_spec.lua"] = counting_spec(counter, 3) })
    local r, ir = go_json(root, { "--retry-failed", "1" })
    eq(r.code, 1, "one retry is not enough")
    eq(slurp(counter), "2", "ran twice, not three times")
    eq(case_of(ir, "TESTS/late_spec.lua").flaky, nil, "not flaky: it never passed")
    write(counter, "1")
    r = go(root, { "--retry-failed", "2" })
    eq(r.code, 1, "the second attempt fails, the third passes: flaky, red")
    eq(slurp(counter), "3", "three attempts in all")
    has(r.out, "flaky: 1 case(s)", "flaky and red")
  end

  -- ----------------------------------------------------------- a green run repeats nothing; only red files run again
  do
    local counter = tmp .. "/c5.txt"
    local other = tmp .. "/c5b.txt"
    local root = project({
      ["TESTS/green_spec.lua"] = counting_spec(counter, 1),
      ["TESTS/red_spec.lua"] = counting_spec(other, 2),
    })
    local r = go(root, { "--retry-failed", "3" })
    eq(r.code, 1, "one flaky file")
    eq(slurp(counter), "1", "the green file ran once")
    eq(slurp(other), "2", "the red file ran twice")
    local green = project({ ["TESTS/green_spec.lua"] = counting_spec(tmp .. "/c5c.txt", 1) })
    r = go(green, { "--retry-failed", "3" })
    eq(r.code, 0, "a green run with --retry-failed")
    has(r.out, "TESTING_OK", "keeps its sentinel")
    eq(slurp(tmp .. "/c5c.txt"), "1", "and ran once")
    lacks(r.out, "flaky", "says nothing about flaky")
  end

  -- a timeout is a verdict about the time, not luck: it is not repeated
  do
    local counter = tmp .. "/c6.txt"
    local root = project({
      ["TESTS/slow_spec.lua"] = ([[
return function(H)
  local f = io.open(%q, "ab")
  f:write("x")
  f:close()
  vim.wait(3000)
  H.ok(true, "slow")
end
]]):format(counter),
    })
    local r = go(root, { "--retry-failed", "2", "--file-timeout", "300" })
    ok(r.code ~= 0, "the file timed out")
    eq(slurp(counter), "x", "and was not run again")
  end

  -- ------------------------------------------------------------------------------ child editors
  do
    local counter = tmp .. "/c7.txt"
    local root = project({ ["TESTS/flaky_spec.lua"] = counting_spec(counter, 2) })
    write(root .. "/.testing.lua", "return { guards = { fs = 'off' }, isolated = 'file' }\n")
    local r, ir = go_json(root, { "--retry-failed", "2", "--jobs", "2" })
    eq(r.code, 1, "in a child editor: red\n" .. r.out .. r.err)
    eq(slurp(counter), "2", "the child ran twice")
    eq(case_of(ir, "TESTS/flaky_spec.lua").flaky, true, "flaky")
  end

  -- ------------------------------------------------------------------------- the module on its own
  do
    ---A report with the given cases (the shape the drivers return).
    local function report_of(cases)
      local res = result.new({ root = "/p" })
      for _, c in ipairs(cases) do
        result.add_case(res, c)
      end
      result.finalize(res)
      return {
        result = res,
        failed = 0,
        failed_files = 0,
        skipped = 0,
        exit_code = 1,
        stopped = false,
      }
    end
    local function case(file, name, status)
      local c = result.new_case({ file = file, name = name })
      c.status = status
      if status == "fail" then
        c.assertions[1] = { ok = false, kind = "ok", msg = "boom" }
      elseif status == "pass" then
        c.assertions[1] = { ok = true, kind = "ok" }
      end
      return c
    end
    local files = { { rel = "a_spec.lua" }, { rel = "b_spec.lua" } }
    local calls = {}
    local rep = report_of({ case("a_spec.lua", "x", "fail"), case("b_spec.lua", "y", "pass") })
    local info = retry.apply(rep, {
      retries = 2,
      files = files,
      bad = require("testing.run.inproc").BAD,
      rerun = function(list)
        calls[#calls + 1] = #list
        return report_of({ case("a_spec.lua", "x", "pass") })
      end,
    })
    eq(calls, { 1 }, "only the red file ran again, once")
    eq(#info.flaky, 1, "one flaky")
    eq(
      rep.flaky_files,
      { ["a_spec.lua"] = true },
      "the file is reported as flaky (the cache refuses it)"
    )
    eq(rep.result.cases[1].status, "fail", "the case stays red")

    -- a runner that raises ends the retries and says so; the verdict is the red one
    rep = report_of({ case("a_spec.lua", "x", "fail") })
    info = retry.apply(rep, {
      retries = 3,
      files = files,
      bad = require("testing.run.inproc").BAD,
      rerun = function()
        return nil, "the pool broke"
      end,
    })
    eq(info.error, "the pool broke", "the reason is kept")
    eq(rep.result.cases[1].status, "fail", "and the case is red")
    eq(#info.flaky, 0, "nothing flaky")

    -- the bound is never more than MAX
    local runs = 0
    rep = report_of({ case("a_spec.lua", "x", "fail") })
    retry.apply(rep, {
      retries = 1000,
      files = files,
      bad = require("testing.run.inproc").BAD,
      rerun = function()
        runs = runs + 1
        return report_of({ case("a_spec.lua", "x", "fail") })
      end,
    })
    eq(runs, retry.MAX, "at most MAX retries, whatever was asked")

    -- an error and a timeout: only `fail` and `error` are repeated
    rep = report_of({ case("a_spec.lua", "x", "timeout"), case("b_spec.lua", "y", "crash") })
    runs = 0
    retry.apply(rep, {
      retries = 2,
      files = files,
      bad = require("testing.run.inproc").BAD,
      rerun = function()
        runs = runs + 1
        return report_of({})
      end,
    })
    eq(runs, 0, "a timeout and a crash are not repeated")
  end

  vim.fn.delete(tmp, "rf")
end
