-- TESTS/testing/fast_loop_spec.lua -- `testing fast`, `--time-budget` and `--skip-uncacheable`: the duration parser, which
-- files are phase 1, the tracker that says when phase 1 is over, the verdict facts (budget, on purpose), the arguments, and
-- the run driver end to end (interim finding before the verdict, on stdout only for the terminal reporter, in the event
-- stream, never a sentinel; a budget leaves `green-partial`, a red file stays red; the CI refusal).

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 1800))
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      ("%s: %q found in %q"):format(msg, needle, tostring(haystack):sub(1, 1800))
    )
  end

  local fast = require("testing.run.fast")
  local verdict_mod = require("testing.report.verdict")
  local args_mod = require("testing.args")
  local cli = require("testing.cli")

  -- ------------------------------------------------------------------ duration
  eq(fast.parse_duration("90s"), 90, "duration: seconds")
  eq(fast.parse_duration("2m"), 120, "duration: minutes")
  eq(fast.parse_duration("1h"), 3600, "duration: hours")
  eq(fast.parse_duration("1500ms"), 1.5, "duration: milliseconds")
  eq(fast.parse_duration("45"), 45, "duration: a bare number is seconds")
  for _, bad in ipairs({ "", "abc", "0s", "10x", "-5s", "1.2.3s" }) do
    local value, problem = fast.parse_duration(bad)
    ok(value == nil and problem ~= nil, ("duration: %q is refused"):format(bad))
  end
  ok(fast.parse_duration(nil) == nil, "duration: nil is refused")

  -- ------------------------------------------------------------------ phase 1
  eq(
    fast.phase1({ "a", "b", "c", "d", "e" }, {
      a = { stage = "near" },
      b = { stage = "rest" },
      c = { stage = "red" },
      d = { stage = "stale" },
      e = { stage = "changed" },
    }),
    { "a", "c", "e" },
    "phase1: red, changed and near, in run order; stale and rest are phase 2"
  )
  eq(fast.phase1({ "a" }, nil), {}, "phase1: no order info, no phase 1")
  ok(fast.in_ci("true") and fast.in_ci("1") and fast.in_ci("yes"), "in_ci: a set value")
  ok(
    not fast.in_ci("")
      and not fast.in_ci("false")
      and not fast.in_ci("FALSE")
      and not fast.in_ci("0"),
    "in_ci: empty, false and 0 are not CI"
  )

  -- ------------------------------------------------------------------ tracker
  local function tracker(phase1, hits)
    local fired = {}
    local t = fast.tracker({
      phase1 = phase1,
      hits = hits,
      emit = function(s)
        fired[#fired + 1] = s
      end,
    })
    return t, fired
  end

  do
    local t, fired = tracker({ "a", "b" }, { a = true })
    t:begin()
    eq(#fired, 0, "tracker: a file that still has to run keeps phase 1 open")
    t:case({ file = "b", status = "pass" })
    eq(#fired, 1, "tracker: the last pending file ends phase 1")
    eq(
      { fired[1].kind, fired[1].specs, fired[1].cached, fired[1].ran, fired[1].failed },
      { "green", 2, 1, 1, 0 },
      "tracker: green, one from cache, one ran"
    )
    t:case({ file = "b", status = "fail" })
    t:file_start("z")
    eq(#fired, 1, "tracker: fires once")
  end
  do
    local t, fired = tracker({ "a", "b" })
    t:case({ file = "a", status = "fail" })
    eq(#fired, 1, "tracker: a bad case in phase 1 is red at once")
    eq(
      { fired[1].kind, fired[1].failed, fired[1].ran },
      { "red", 1, 1 },
      "tracker: red, b still owed"
    )
  end
  do
    local t, fired = tracker({ "a", "b" }, { a = true, b = true })
    t:begin()
    eq(#fired, 1, "tracker: every likely file from the cache: phase 1 is over before anything runs")
    eq(
      { fired[1].kind, fired[1].cached, fired[1].ran },
      { "green", 2, 0 },
      "tracker: ... green, none ran"
    )
  end
  do
    local t, fired = tracker({})
    t:begin()
    t:case({ file = "a", status = "pass" })
    t:file_start("a")
    eq(#fired, 0, "tracker: no phase 1, no interim finding")
  end
  do
    local t, fired = tracker({ "a", "b" })
    t:case({ file = "a", status = "pass" })
    t:file_start("z")
    eq(#fired, 1, "tracker: the first file of phase 2 ends phase 1 whatever it still owes")
    eq(fired[1].kind, "green-partial", "tracker: a file that never reported is not a plain green")
    local u, ufired = tracker({ "a" })
    u:case({ file = "a", status = "skip" })
    eq(ufired[1].kind, "green-partial", "tracker: a skipped case is never green")
  end
  has(
    fast.line({ kind = "red", specs = 4, cached = 1, ran = 3, failed = 2 }),
    "fast: red for the 4 likely spec(s) (1 from cache, 3 ran, 2 failed) -- not final",
    "line: red"
  )
  lacks(
    fast.line({ kind = "green", specs = 1, cached = 0, ran = 1, failed = 0 }),
    "failed",
    "line: green names no failures"
  )

  -- ------------------------------------------------------------------ verdict facts
  do
    local v = verdict_mod.build({
      exit_code = 0,
      files_total = 5,
      files_selected = 5,
      files_cached = 1,
      files_unrun = 2,
      files_unrun_budget = 2,
      cases_total = 3,
      cases_skipped = 0,
    })
    eq(v.kind, "green-partial", "verdict: a budget that ran out is never green")
    eq(v.reasons, { "2 spec file(s) not run (budget)" }, "verdict: ... and says so")
    eq(v.files.ran, 2, "verdict: ran = selected - cached - unrun")
    has(verdict_mod.counts(v), "2 not run (budget)", "verdict: the counts name the budget")
    local mixed = verdict_mod.build({
      exit_code = 0,
      files_total = 4,
      files_selected = 4,
      files_unrun = 3,
      files_unrun_budget = 1,
      cases_total = 1,
      cases_skipped = 0,
    })
    eq(
      mixed.reasons,
      { "2 spec file(s) not run (stopped)", "1 spec file(s) not run (budget)" },
      "verdict: a stop and a budget are told apart"
    )
    local on_purpose = verdict_mod.build({
      exit_code = 0,
      files_total = 5,
      files_selected = 5,
      files_cached = 3,
      files_deliberate = 2,
      cases_total = 3,
      cases_skipped = 0,
    })
    eq(on_purpose.kind, "green-partial", "verdict: files left out on purpose are not green")
    eq(on_purpose.files.ran, 0, "verdict: ... and did not run")
    has(
      on_purpose.reasons[1],
      "2 spec file(s) skipped on purpose (--skip-uncacheable)",
      "verdict: ... the reason"
    )
    has(
      verdict_mod.counts(on_purpose),
      "0 ran, 2 skipped on purpose",
      "verdict: counted as skipped"
    )
    local red = verdict_mod.build({
      exit_code = 1,
      files_total = 3,
      files_selected = 3,
      files_unrun = 1,
      files_unrun_budget = 1,
      cases_total = 1,
      cases_skipped = 0,
    })
    eq(red.kind, "red", "verdict: a red file stays red when the budget ran out")
    lacks(
      verdict_mod.counts(verdict_mod.build({
        exit_code = 0,
        files_total = 1,
        files_selected = 1,
        cases_total = 1,
        cases_skipped = 0,
      })),
      "budget",
      "verdict: nothing about a budget when none was used"
    )
  end

  -- ------------------------------------------------------------------ arguments
  do
    local a = args_mod.parse({ "fast", "." })
    ok(a ~= nil and a.fast == true, "args: fast")
    eq(
      { a.cache, a.order, a.command },
      { true, "priority", "run" },
      "args: fast = --cached --order priority"
    )
    a = args_mod.parse({ "fast", ".", "--no-cache" })
    ok(a.fast and not a.cache, "args: --no-cache wins over fast")
    a = args_mod.parse({ "fast", ".", "--order", "slowest-first" })
    eq(a.order, "slowest-first", "args: an order given explicitly stays")
    local bad, problem = args_mod.parse({ "fast", ".", "--shuffle" })
    ok(
      bad == nil and problem:find("shuffle", 1, true) ~= nil,
      "args: fast and --shuffle exclude each other"
    )
    a = args_mod.parse({ ".", "--time-budget", "2m", "--skip-uncacheable" })
    eq(
      { a.time_budget, a.skip_uncacheable },
      { 120, true },
      "args: --time-budget and --skip-uncacheable"
    )
    bad, problem = args_mod.parse({ ".", "--time-budget", "soon" })
    ok(bad == nil and problem:find("--time-budget", 1, true) ~= nil, "args: a bad budget is named")
    ok(args_mod.parse({ "." }).fast == false, "args: fast is off by default")
    has(args_mod.usage(), "fast ", "args: the usage names fast")
  end

  -- ------------------------------------------------------------------ the run driver
  local root = vim.fs.normalize(vim.fn.tempname())
  local state, cache = root .. "-state", root .. "-cache"
  vim.fn.mkdir(root .. "/TESTS", "p")
  vim.fn.mkdir(state, "p")
  local function put(rel, text)
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  local GREEN = "return function(H)\n  H.ok(true, 'ok')\nend\n"
  local RED = "return function(H)\n  H.eq(1, 2, 'one is not two')\nend\n"
  put("TESTS/a_spec.lua", GREEN)
  put("TESTS/b_spec.lua", GREEN)
  put("TESTS/c_spec.lua", RED)

  ---@param argv string[] The whole argument list (the command first for `fast`).
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
    local code = cli.main(argv, sv)
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end
  local function at(text, needle)
    return (text:find(needle, 1, true))
  end
  local NOCI = { env = { CI = "" } }

  -- one red run records the failure the priority order starts with
  local r = run({ root })
  eq(r.code, 1, "setup: c_spec is red\n" .. r.err)

  -- phase 1 is red: the interim finding comes before the verdict of the whole run
  r = run({ "fast", root, "--cache-dir", cache }, NOCI)
  eq(r.code, 1, "fast: the run is red\n" .. r.err)
  has(r.out, "fast: red for the 1 likely spec(s)", "fast: the interim finding")
  has(r.out, "-- not final, the run goes on", "fast: ... says it is not final")
  ok(
    at(r.out, "fast: red") ~= nil
      and at(r.out, "verdict: red") ~= nil
      and at(r.out, "fast: red") < at(r.out, "verdict: red"),
    "fast: ... and comes before the verdict"
  )
  ok(r.last ~= "TESTING_OK", "fast: no sentinel after a red run")
  has(r.out, "3 spec file(s)", "fast: the verdict covers every file (phase 2 ran)")

  -- -x: the stop after the red file of phase 1 still gives the interim finding and a red verdict
  r = run({ "fast", root, "-x", "--cache-dir", cache }, NOCI)
  eq(r.code, 1, "fast -x: red")
  has(r.out, "fast: red for the 1 likely spec(s)", "fast -x: the interim finding")

  -- the agent reporter keeps its first stdout line: the interim finding goes to stderr
  r = run({ "fast", root, "--cache-dir", cache }, { env = { CLAUDECODE = "1", CI = "" } })
  ok(
    r.out:find("^RED | ") ~= nil,
    "fast: the agent reporter's first line is still its verdict\n" .. r.out
  )
  lacks(r.out, "fast: red", "fast: ... no interim finding on its stdout")
  has(r.err, "fast: red for the 1 likely spec(s)", "fast: ... it is on stderr")

  -- the event stream: one phase_done, before run_done
  local events = root .. "-events.ndjson"
  run({ "fast", root, "--cache-dir", cache, "--events", events }, NOCI)
  local lines = vim.fn.readfile(events)
  local phase_at, done_at, phase
  for i, line in ipairs(lines) do
    local obj = vim.json.decode(line)
    if obj.event == "phase_done" then
      phase_at, phase = i, obj
    elseif obj.event == "run_done" then
      done_at = i
    end
  end
  ok(
    phase_at ~= nil and done_at ~= nil and phase_at < done_at,
    "events: phase_done comes before run_done"
  )
  eq(
    { phase.phase, phase.verdict, phase.specs, phase.failed },
    { 1, "red", 1, 1 },
    "events: phase_done carries the interim finding"
  )

  -- no signal, no interim finding: everything green and cached, the sentinel
  put("TESTS/c_spec.lua", GREEN)
  r = run({ root })
  eq(r.code, 0, "setup: all green\n" .. r.err)
  r = run({ "fast", root, "--cache-dir", cache }, NOCI)
  lacks(r.out, "fast:", "fast: nothing is likely, no interim finding")
  eq(r.last, "TESTING_OK", "fast: a green run keeps the sentinel")

  -- a file that failed last time and is green now: interim green, then the verdict
  put("TESTS/c_spec.lua", RED)
  run({ root })
  put("TESTS/c_spec.lua", GREEN .. "-- fixed\n")
  r = run({ "fast", root, "--cache-dir", cache }, NOCI)
  eq(r.code, 0, "fast: the fixed file is green\n" .. r.err)
  has(r.out, "fast: green for the 1 likely spec(s) (0 from cache, 1 ran)", "fast: interim green")
  eq(r.last, "TESTING_OK", "fast: the sentinel only after the whole run")

  -- ------------------------------------------------------------------ --time-budget
  ---A clock that has used no time for the first two readings (the start and the first file), a minute for the rest.
  local function clock()
    local calls = 0
    return function()
      calls = calls + 1
      return calls <= 2 and 0 or 100
    end
  end
  r = run({ root, "--no-cache", "--time-budget", "60s" }, { budget_clock = clock() })
  eq(r.code, 0, "budget: a green file ran, the rest is not run: exit 0\n" .. r.err)
  has(r.out, "verdict: green-partial", "budget: green-partial")
  has(r.out, "2 spec file(s) not run (budget)", "budget: the reason")
  has(r.out, "budget: 2 file(s) not run (--time-budget 60s ran out)", "budget: the line")
  has(r.out, "2 not run (budget)", "budget: the counts")
  ok(r.last ~= "TESTING_OK", "budget: never the sentinel")
  r = run(
    { root, "--no-cache", "--isolated", "file", "--time-budget", "60s" },
    { budget_clock = clock() }
  )
  eq(r.code, 0, "budget, isolated: exit 0\n" .. r.err)
  has(r.out, "2 spec file(s) not run (budget)", "budget, isolated: the reason")
  ok(r.last ~= "TESTING_OK", "budget, isolated: never the sentinel")
  -- a generous budget changes nothing
  r = run({ root, "--no-cache", "--time-budget", "1h" })
  eq(r.last, "TESTING_OK", "budget: a budget that is not used up keeps the sentinel")
  -- red stays red: the file that failed last time runs first (priority) and the rest is out of budget
  put("TESTS/c_spec.lua", RED)
  run({ root })
  r = run(
    { root, "--no-cache", "--order", "priority", "--time-budget", "60s" },
    { budget_clock = clock() }
  )
  eq(r.code, 1, "budget: a red file stays red\n" .. r.err)
  has(r.out, "verdict: red", "budget: ... the verdict")
  put("TESTS/c_spec.lua", GREEN)

  -- ------------------------------------------------------------------ --skip-uncacheable
  -- a spec that reads an environment variable that is not part of the cache key has no key
  put(
    "TESTS/d_spec.lua",
    "return function(H)\n  H.ok(os.getenv('FAST_LOOP_SPEC_NOKEY') == nil, 'unset')\nend\n"
  )
  r = run({ root, "--cached", "--cache-dir", cache }, NOCI)
  eq(r.code, 0, "skip-uncacheable setup: green\n" .. r.err)
  r = run({ root, "--cached", "--cache-dir", cache }, NOCI)
  eq(r.last, "TESTING_OK", "without the option the uncacheable file runs and the run is green")
  r = run({ root, "--cached", "--cache-dir", cache, "--skip-uncacheable" }, NOCI)
  eq(r.code, 0, "skip-uncacheable: exit 0\n" .. r.err)
  has(r.out, "verdict: green-partial", "skip-uncacheable: green-partial")
  has(
    r.out,
    "1 spec file(s) skipped on purpose (--skip-uncacheable)",
    "skip-uncacheable: the reason"
  )
  ok(r.last ~= "TESTING_OK", "skip-uncacheable: never the sentinel")
  r = run(
    { root, "--cached", "--cache-dir", cache, "--skip-uncacheable" },
    { env = { CI = "true" } }
  )
  eq(r.code, 2, "skip-uncacheable: refused when CI is set")
  has(r.err, "--skip-uncacheable is refused when CI is set", "skip-uncacheable: ... says why")
  r = run({ root, "--no-cache", "--skip-uncacheable" }, NOCI)
  eq(r.last, "TESTING_OK", "skip-uncacheable without a cache leaves nothing out")
  has(r.err, "no cache is in use", "skip-uncacheable: ... and says so")

  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
  vim.fn.delete(cache, "rf")
  vim.fn.delete(events)
end
