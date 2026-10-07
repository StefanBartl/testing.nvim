-- TESTS/testing/verdict_run_spec.lua -- the run driver end to end: the three-valued verdict in every reporter and in the
-- IR, the sentinel only with `green`, the last green run of a red verdict, the agent reporter and how it is chosen
-- (`--reporter`, `TESTING_REPORTER`, an agent environment handed down by the entry script), `--order priority`
-- (the run order changes, the set and the IR order do not), and exit codes that are the same as before.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      ("%s: %q found in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end

  local cli = require("testing.cli")
  local root = vim.fs.normalize(vim.fn.tempname())
  local state = root .. "-state"
  vim.fn.mkdir(root .. "/TESTS", "p")
  vim.fn.mkdir(state, "p")
  local function put(rel, text)
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  local function drop(rel)
    vim.fn.delete(root .. "/" .. rel)
  end
  put("TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  put("TESTS/b_spec.lua", "return function(H)\n  H.ok(true, 'b')\nend\n")

  local function run(argv, seams)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
    }
    for k, v in pairs(seams or {}) do
      sv[k] = v
    end
    local code = cli.main(vim.list_extend({ root }, argv), sv)
    local text = table.concat(out, "\n")
    local last = vim.trim(out[#out] or "")
    return { code = code, out = text, err = table.concat(err, "\n"), last = last }
  end
  local function ir_of(path)
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("a")
    fh:close()
    return vim.json.decode(text)
  end

  -- green: the verdict line, the sentinel, the record of the green run -----------------------------------------------
  local r = run({})
  eq(r.code, 0, "two green specs: exit 0\n" .. r.err)
  has(
    r.out,
    "verdict: green (0 from cache, 2 ran, 0 skipped on purpose; 2 spec file(s))",
    "term: green with n from cache, m ran, k skipped"
  )
  eq(r.last, "TESTING_OK", "the sentinel is still the last line of a green run")
  ok(
    vim.uv.fs_stat(require("testing.run.green").path(root, { state_dir = state })) ~= nil,
    "the green run is recorded"
  )
  local rec = require("testing.run.green").load(root, { state_dir = state })
  ok(rec ~= nil and rec.run ~= nil, "the record names the run")

  -- the verdict is in the IR ---------------------------------------------------------------------------------------------
  local jpath = root .. "/out.json"
  run({ "--json", jpath })
  local ir = ir_of(jpath)
  eq(ir.run.verdict.kind, "green", "--json: run.verdict.kind")
  eq(ir.run.verdict.files.total, 2, "--json: run.verdict.files.total")
  eq(ir.run.verdict.exit_code, 0, "--json: the exit code")

  -- green-partial: a selection never prints the sentinel -----------------------------------------------------------------------
  r = run({ "--file", "a_spec" })
  eq(r.code, 0, "a selection that is green: exit 0 as before")
  has(
    r.out,
    "verdict: green-partial (0 from cache, 1 ran, 1 skipped on purpose; 2 spec file(s))",
    "term: partial"
  )
  has(r.out, "1 spec file(s) not selected (--file)", "with the reason")
  lacks(r.out, "TESTING_OK", "and no sentinel")
  r = run({ "--filter", "a_spec" })
  has(r.out, "verdict: green-partial", "a case filter is partial")
  has(r.out, "a case selection", "with that reason")
  lacks(r.out, "TESTING_OK", "and no sentinel")

  -- red: exit 1, the last green run, what changed since
  rec = require("testing.run.green").load(root, { state_dir = state })
  put("TESTS/c_spec.lua", "return function(H)\n  H.eq(1, 2, 'one is not two')\nend\n")
  r = run({ "--json", jpath })
  eq(r.code, 1, "a red spec: exit 1 as before")
  has(
    r.out,
    "verdict: red (0 from cache, 3 ran, 0 skipped on purpose; 3 spec file(s))",
    "term: red"
  )
  has(r.out, "last green run: ", "a red verdict names the last green run")
  has(r.out, "what changed since is unknown (no git facts)", "and says what it cannot know")
  lacks(r.out, "TESTING_OK", "no sentinel")
  ir = ir_of(jpath)
  eq(ir.run.verdict.kind, "red", "--json: red")
  eq(ir.run.verdict.exit_code, 1, "--json: exit code 1")
  ok(type(ir.run.verdict.last_green.ts) == "number", "--json: the last green run")
  local rec2 = require("testing.run.green").load(root, { state_dir = state })
  eq(rec2.run, rec.run, "a red run does not replace the record of the last green run")

  -- the sentinel is printed exactly when the verdict is green ---------------------------------------------------------------------
  drop("TESTS/c_spec.lua")
  for _, argv in ipairs({ {}, { "--file", "a_spec" }, { "--filter", "b" }, { "-x" } }) do
    local x = run(vim.list_extend(vim.deepcopy(argv), { "--json", jpath }))
    local kind = ir_of(jpath).run.verdict.kind
    eq(
      x.last == "TESTING_OK",
      kind == "green",
      ("sentinel <=> green for %s (%s)"):format(table.concat(argv, " "), kind)
    )
  end

  -- --maxfail + --retry-failed + --allow-flaky: a fails, passes on the retry, b and c never run -> green-partial, no sentinel
  do
    local root2 = vim.fs.normalize(vim.fn.tempname())
    local counter = root2 .. "/counter.txt"
    vim.fn.mkdir(root2 .. "/TESTS", "p")
    local function put2(rel, text)
      local fh = assert(io.open(root2 .. "/" .. rel, "wb"))
      fh:write(text)
      fh:close()
    end
    put2(".testing.lua", "return { guards = { fs = 'off' }, isolated = 'none' }" .. string.char(10))
    put2(
      "TESTS/a_spec.lua",
      ([[
return function(H)
  local n = 0
  local f = io.open(%q, "rb")
  if f then
    n = tonumber(f:read("*a")) or 0
    f:close()
  end
  f = assert(io.open(%q, "wb"))
  f:write(tostring(n + 1))
  f:close()
  H.ok(n + 1 >= 2, "attempt " .. (n + 1))
end
]]):format(counter, counter)
    )
    put2("TESTS/b_spec.lua", "return function(H) H.ok(true, 'b') end" .. string.char(10))
    put2("TESTS/c_spec.lua", "return function(H) H.ok(true, 'c') end" .. string.char(10))
    local function go2(argv)
      local out, err = {}, {}
      local code = cli.main(vim.list_extend({ root2 }, argv), {
        out = function(l)
          out[#out + 1] = l
        end,
        err = function(l)
          err[#err + 1] = l
        end,
        state_dir = state .. "2",
        color = false,
      })
      return { code = code, out = table.concat(out, string.char(10)), err = table.concat(err) }
    end
    for _, reporter in ipairs({ "term", "agent" }) do
      vim.fn.delete(counter)
      local x = go2({
        "--maxfail",
        "1",
        "--retry-failed",
        "2",
        "--allow-flaky",
        "--reporter",
        reporter,
        "--json",
        root2 .. "/ir.json",
      })
      eq(x.code, 0, reporter .. ": the flaky case is accepted: exit 0" .. x.err)
      lacks(x.out, "TESTING_OK", reporter .. ": no sentinel after a --maxfail stop")
      local v = ir_of(root2 .. "/ir.json").run.verdict
      eq(v.kind, "green-partial", reporter .. ": the verdict is green-partial")
      eq(v.files.unrun, 2, reporter .. ": b and c never ran")
      eq(v.cases.flaky, 1, reporter .. ": the accepted flaky case is a fact of the verdict")
      has(table.concat(v.reasons, ";"), "not run (stopped)", reporter .. ": the stop is a reason")
      has(
        table.concat(v.reasons, ";"),
        "1 flaky case(s) accepted",
        reporter .. ": so is the flaky case"
      )
      if reporter == "term" then
        has(x.out, "partial run:", "term: the partial line comes from the verdict")
        has(x.out, "no sentinel", "term: and says there is none")
      else
        ok(x.out:find("^PARTIAL |"), "agent: PARTIAL, never GREEN")
        has(x.out, "flaky", "agent: the flaky case is on stdout")
      end
      ok(
        not require("testing.run.green").load(root2, { state_dir = state .. "2" }),
        reporter .. ": a run that accepted a flaky case is not recorded as the last green run"
      )
    end
    -- without --maxfail the same flaky case is accepted and the run is still no plain green
    vim.fn.delete(counter)
    local y = go2({ "--retry-failed", "2", "--allow-flaky", "--json", root2 .. "/ir.json" })
    eq(y.code, 0, "--allow-flaky without --maxfail: exit 0")
    eq(
      ir_of(root2 .. "/ir.json").run.verdict.kind,
      "green-partial",
      "accepted flaky: green-partial"
    )
    lacks(y.out, "TESTING_OK", "no sentinel for an accepted flaky case")
    vim.fn.delete(root2, "rf")
    vim.fn.delete(state .. "2", "rf")
  end

  -- a skipped case is never green ----------------------------------------------------------------------------------------------------
  put(
    "TESTS/s_spec.lua",
    "describe('s', function()\n  it('later')\n  it('now', function() assert.is_true(true) end)\nend)\n"
  )
  r = run({ "--isolated", "none", "--file", "s_spec", "--json", jpath })
  eq(r.code, 0, "a skip is exit 0, as before\n" .. r.err)
  eq(ir_of(jpath).run.verdict.kind, "green-partial", "but the verdict is green-partial")
  has(r.out, "case(s) skipped: a skip is never green", "with the reason")
  lacks(r.out, "TESTING_OK", "and no sentinel")
  drop("TESTS/s_spec.lua")

  -- the agent reporter ------------------------------------------------------------------------------------------------------------------
  put("TESTS/c_spec.lua", "return function(H)\n  H.eq(1, 2, 'one is not two')\nend\n")
  r = run({ "--reporter", "agent" })
  eq(r.code, 1, "agent: exit code 1 on red, the same as term")
  ok(
    r.out:find("^RED | 1 fail, 2 pass | 0 from cache, 3 ran, 0 skipped on purpose | "),
    "agent: the first line is the verdict"
  )
  has(r.out, "FAIL TESTS/c_spec.lua:2", "agent: the failure with file:line")
  has(r.out, "one is not two", "agent: the message")
  has(
    r.out,
    "rerun: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua ",
    "agent: the repeat command"
  )
  has(r.out, "--file TESTS/c_spec.lua", "agent: for that file")
  lacks(r.out, "ok    ", "agent: no line for a green file")
  lacks(r.out, "timings:", "agent: no timing line")
  lacks(r.out, "TESTING_OK", "agent: no sentinel")
  -- the script path is a word of the line like any other: a space in it must not split it
  r = run({ "--reporter", "agent" }, { script = "my dir/scripts/testing.lua" })
  has(r.out, "-l 'my dir/scripts/testing.lua' ", "agent: a script path with a space is quoted")
  -- a report file that cannot be written: the agent line must not claim an exit code the run does not have
  put("blocker", "a file, not a directory")
  r = run({ "--reporter", "agent", "--json", root .. "/blocker/x.json" })
  eq(r.code, 3, "agent: a --json file that cannot be written is exit 3")
  ok(r.out:find("^INFRA | "), "agent: the line says INFRA, not RED/GREEN with another exit code")
  lacks(r.out, "RED |", "agent: no verdict line with a wrong exit code")
  has(r.out, "| exit 3", "agent: and the exit code it really has")
  r = run({ "--reporter", "agent", "--format", "jsonl", "--json", root .. "/blocker/x.json" })
  eq(vim.json.decode(vim.split(r.out, "\n")[1]).kind, "infra", "agent jsonl: an infra object")
  drop("blocker")
  r = run({ "--reporter", "agent", "--format", "jsonl", "--agent-budget", "800" })
  local first = vim.json.decode(vim.split(r.out, "\n")[1])
  eq(first.kind, "verdict", "agent --format jsonl: the first object is the verdict")
  eq(first.verdict, "red", "agent --format jsonl: red")
  drop("TESTS/c_spec.lua")
  r = run({ "--reporter", "agent" })
  eq(r.code, 0, "agent: green exit 0")
  eq(
    r.out,
    "GREEN | 2 pass | 0 from cache, 2 ran, 0 skipped on purpose | "
      .. r.out:match("| ([%d%.]+ s) |")
      .. " | exit 0",
    "agent: green is one line"
  )
  r = run({ "--reporter", "agent", "--file", "a_spec" })
  has(r.out, "PARTIAL |", "agent: a selection is PARTIAL")
  has(r.out, "no sentinel", "agent: and says so")

  -- how the reporter is chosen ---------------------------------------------------------------------------------------------------------
  put("TESTS/c_spec.lua", "return function(H)\n  H.eq(1, 2, 'one is not two')\nend\n")
  r = run({}, { env = { CLAUDECODE = "1" } })
  ok(
    r.out:find("^RED | "),
    "an agent environment handed down by the entry script selects the agent reporter"
  )
  r = run({}, { env = { CLAUDECODE = "1", TESTING_AGENT = "0" } })
  has(r.out, "summary:", "TESTING_AGENT=0 keeps the terminal reporter")
  r = run({}, { env = { TESTING_REPORTER = "agent" } })
  ok(r.out:find("^RED | "), "TESTING_REPORTER=agent")
  r = run({ "--reporter", "term" }, { env = { CLAUDECODE = "1" } })
  has(r.out, "summary:", "--reporter term wins over the environment")
  r = run({}, { env = { TESTING_REPORTER = "bogus" } })
  eq(r.code, 2, "an unknown TESTING_REPORTER is a usage error")
  has(r.err, "TESTING_REPORTER", "and says which variable")
  r = run({})
  has(
    r.out,
    "summary:",
    "without an environment from the entry script the library never switches (specs stay stable)"
  )
  r = run({ "--format", "jsonl" })
  eq(r.code, 2, "--format without the agent reporter is a usage error")
  has(r.err, "agent reporter", "and says why")
  r = run({ "--agent-budget", "500" })
  eq(r.code, 2, "--agent-budget without the agent reporter is a usage error")
  r = run({ "--agent-budget", "10", "--reporter", "agent" })
  eq(r.code, 2, "--agent-budget below the minimum is a usage error")
  r = run({ "--format", "jsonl" }, { env = { CLAUDECODE = "1" } })
  eq(r.code, 1, "--format jsonl is fine when the environment selects the agent reporter")

  -- --order priority: the run order changes, nothing else ----------------------------------------------------------------------------------
  r = run({ "--order", "priority", "--list" })
  eq(r.code, 0, "--order priority --list\n" .. r.err)
  local at = {}
  for i, l in ipairs(vim.split(r.out, "\n")) do
    local f = l:match("^order %d+  (%S+)  %(")
    if f then
      at[#at + 1] = { i = i, file = f, line = l }
    end
  end
  eq(#at, 3, "--list names rank and reason of every file")
  eq(at[1].file, "TESTS/c_spec.lua", "what failed last time is first")
  has(at[1].line, "order 1  TESTS/c_spec.lua  (failed last time)", "with its reason")
  r = run({ "--order", "priority", "--json", jpath })
  eq(r.code, 1, "the verdict does not depend on the order")
  local ids = {}
  for _, c in ipairs(ir_of(jpath).cases) do
    ids[#ids + 1] = c.file
  end
  eq(
    ids,
    { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" },
    "the IR stays in discovery order"
  )
  run({ "-x", "--order", "priority", "--json", jpath })
  local n_prio = #ir_of(jpath).cases
  run({ "-x", "--json", jpath })
  local n_plain = #ir_of(jpath).cases
  eq(
    { n_prio, n_plain },
    { 1, 3 },
    "with --order priority the red file runs first, so -x stops after one file"
  )
  -- the IR does not depend on --jobs either: results are merged in file order whatever order the children finished in
  local function files_of(jobs)
    local x = run({
      "--order",
      "priority",
      "--isolated",
      "file",
      "--jobs",
      tostring(jobs),
      "--json",
      jpath,
    })
    local list = {}
    for _, c in ipairs(ir_of(jpath).cases) do
      list[#list + 1] = c.file
    end
    return list, x.code, ir_of(jpath).run.verdict.kind
  end
  local one, code1, kind1 = files_of(1)
  local two, code2, kind2 = files_of(2)
  eq(
    one,
    { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" },
    "--jobs 1: discovery order in the IR"
  )
  eq(
    { two, code2, kind2 },
    { one, code1, kind1 },
    "--jobs 2: the same IR order, exit code and verdict"
  )
  r = run({ "--order", "priority", "--shuffle" })
  eq(r.code, 2, "--order and --shuffle exclude each other")
  has(r.err, "exclude each other", "and the message says it")
  r = run({ "--order", "random" })
  eq(r.code, 2, "an unknown --order is a usage error")
  r = run({ "--order", "priority", "--ff", "--list" })
  eq(r.code, 0, "--ff stays a valid option next to it")
  r = run({ "--order", "priority", "--file", "a_spec", "--list" })
  local listed = 0
  for _ in r.out:gmatch("\norder %d+  ") do
    listed = listed + 1
  end
  ok(
    listed + (r.out:find("^order %d+  ") and 1 or 0) == 1,
    "--order never adds files to a selection"
  )

  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
end
