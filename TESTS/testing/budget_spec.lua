-- TESTS/testing/budget_spec.lua -- `testing budget`: the harness (warm-up, median, injectable clock), the check
-- against a baseline with a factor and a slack, the baseline file as untrusted input, the whole command through
-- `testing.cli` with a FAKE SLOW FUNCTION (a clock the case advances), and the real cases at toy size so that none
-- of them rots.

-- @cache-env USER USERNAME
-- (read for the redaction of the user name: the values join the key)
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
      msg .. " (got " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  ---@param path string
  ---@return string
  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end
  local budget = require("testing.budget")
  local harness = require("testing.budget.harness")
  local cli = require("testing.cli")

  -- median
  eq(harness.median({ 3, 1, 2 }), 2, "median of three")
  eq(harness.median({ 4, 1, 3, 2 }), 2.5, "median of four is the middle pair's mean")
  eq(harness.median({}), 0, "median of nothing")

  -- measure: warm-up calls are not timed, `runs` calls are; the median counts
  do
    local now, calls = 0, 0
    local durations = { 999, 10, 50, 30, 20, 40 } -- the first call is the warm-up
    local m = assert(harness.measure(function()
      calls = calls + 1
      now = now + durations[calls]
    end, {
      clock = function()
        return now
      end,
      warmup = 1,
      runs = 5,
    }))
    eq(calls, 6, "one warm-up plus five timed calls")
    eq(m.samples, { 10, 50, 30, 20, 40 }, "the warm-up is not a sample")
    eq(m.median_ms, 30, "median")
    eq(m.min_ms, 10, "min")
    eq(m.max_ms, 50, "max")
    eq(m.runs, 5, "runs")
    -- a raise is an error, never a number
    local none, err = harness.measure(function()
      error("setup broke", 0)
    end, { warmup = 0, runs = 2 })
    eq(none, nil, "a raising function measures nothing")
    eq(err, "setup broke", "and says why")
    local warm_none
    warm_none, err = harness.measure(function()
      error("only in the warm-up", 0)
    end, { warmup = 1, runs = 2 })
    eq(warm_none, nil, "no measure either")
    eq(err, "only in the warm-up", "also when it raises in the warm-up")
  end

  -- check: factor AND slack
  do
    local base =
      { fast = { median_ms = 10 }, tiny = { median_ms = 0.3 }, same = { median_ms = 100 } }
    local rows, exceeded = budget.check(
      base,
      { fast = 25, tiny = 0.9, same = 100, extra = 5 },
      { factor = 2 }
    )
    local by = {}
    for _, r in ipairs(rows) do
      by[r.name] = r
    end
    eq(by.fast.status, "exceeded", "25 ms against a baseline of 10 ms at factor 2 is over")
    eq(by.fast.limit_ms, 20, "the limit is baseline x factor")
    eq(by.fast.ratio, 2.5, "and the ratio is reported")
    eq(
      by.tiny.status,
      "ok",
      "0.9 ms against 0.3 ms is three times but under the 1 ms slack: not a failure"
    )
    eq(by.same.status, "ok", "unchanged is fine")
    eq(by.extra.status, "new", "a case without a baseline is new, not green and not red")
    eq(exceeded, 1, "one case exceeded")
    eq(
      vim.tbl_map(function(r)
        return r.name
      end, rows),
      { "extra", "fast", "same", "tiny" },
      "rows are sorted by name"
    )
    -- exactly at the limit is fine; one hair above is not
    local r2 = budget.check({ x = { median_ms = 10 } }, { x = 20 }, { factor = 2 })
    eq(r2[1].status, "ok", "exactly baseline x factor is within the budget")
    r2 = budget.check({ x = { median_ms = 10 } }, { x = 20.001 }, { factor = 2 })
    eq(r2[1].status, "exceeded", "above it is not")
    -- the slack is absolute and does not hide a real regression of a bigger case
    r2 = budget.check({ x = { median_ms = 1000 } }, { x = 2500 }, { factor = 2 })
    eq(r2[1].status, "exceeded", "a big case over the factor fails whatever the slack")
  end

  -- baseline file as untrusted input
  do
    local good, why = budget.validate_baseline({
      version = 1,
      cases = {
        ok_case = { median_ms = 3.5, min_ms = 3, max_ms = 4, runs = 5 },
        negative = { median_ms = -1 },
        text = { median_ms = "fast" },
        nan = { median_ms = 0 / 0 },
        huge = { median_ms = 1e12 },
        [7] = { median_ms = 1 },
      },
    })
    ok(good ~= nil, tostring(why))
    good = assert(good)
    eq(vim.tbl_keys(good.cases), { "ok_case" }, "only sane entries survive")
    eq(good.cases.ok_case.median_ms, 3.5, "value kept")
    local bad, bad_why = budget.validate_baseline({ version = 2, cases = {} })
    eq(bad, nil, "another version is refused")
    has(bad_why, "unknown version", "and says so")
    eq((budget.validate_baseline("text")), nil, "not an object")
    local no_cases, no_why = budget.validate_baseline({ version = 1 })
    eq(no_cases, nil, "no cases")
    has(no_why, "cases", "and says so")

    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    local function write(path, text)
      local f = assert(io.open(path, "wb"))
      f:write(text)
      f:close()
    end
    local b, e = budget.read_baseline(dir .. "/missing.json")
    eq(b, nil, "missing file")
    has(e, "no baseline", "says so")
    write(dir .. "/broken.json", "{oops")
    b, e = budget.read_baseline(dir .. "/broken.json")
    eq(b, nil, "broken JSON")
    has(e, "not valid JSON", "says so")
    write(dir .. "/big.json", string.rep(" ", budget.MAX_BYTES + 1))
    b, e = budget.read_baseline(dir .. "/big.json")
    eq(b, nil, "an oversized file is never read")
    has(e, "larger than", "and the limit is named")
    vim.fn.delete(dir, "rf")
  end

  -- machine: identifies the hardware, never the person
  do
    local m = budget.machine()
    for _, key in ipairs({ "os", "arch", "cpu", "cpus", "nvim" }) do
      ok(m[key] ~= nil, "machine." .. key)
    end
    local blob = vim.json.encode(m):lower()
    ok(
      not blob:find((vim.uv.os_gethostname() or "?"):lower(), 1, true)
        or #(vim.uv.os_gethostname() or "") < 4,
      "no host name in the machine record"
    )
    ok(
      not blob:find((vim.env.USERNAME or vim.env.USER or "?"):lower(), 1, true)
        or #(vim.env.USERNAME or vim.env.USER or "") < 4,
      "no user name"
    )
  end

  -- run() with fake cases and a fake clock: the fake slow function
  local now = 0
  local cost = { fast = 5, slow = 40 }
  local cases = {
    {
      name = "fast",
      desc = "fast",
      kind = "inproc",
      setup = function()
        return function()
          now = now + cost.fast
        end
      end,
    },
    {
      name = "slow",
      desc = "slow",
      kind = "inproc",
      setup = function()
        return function()
          now = now + cost.slow
        end
      end,
    },
  }
  local function fake_run(o)
    return budget.run(vim.tbl_extend("force", o, {
      cases = cases,
      clock = function()
        return now
      end,
    }))
  end
  local results = budget.run({
    cases = cases,
    clock = function()
      return now
    end,
    runs = 3,
    warmup = 1,
  })
  eq(
    vim.tbl_map(function(r)
      return r.name .. "=" .. r.measure.median_ms
    end, results),
    { "fast=5", "slow=40" },
    "the fake functions are measured with the fake clock"
  )
  results = budget.run({
    cases = cases,
    filter = { "slo" },
    clock = function()
      return now
    end,
  })
  eq(#results, 1, "--filter keeps the matching case")
  -- a setup that raises is an error row
  results = budget.run({
    cases = {
      {
        name = "broken",
        desc = "",
        kind = "inproc",
        setup = function()
          error("no fixture", 0)
        end,
      },
    },
  })
  eq(results[1].error, "setup failed: no fixture", "a failing setup is reported, not skipped")
  eq(results[1].measure, nil, "and measures nothing")

  -- the command through the CLI
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local function budget_cmd(argv, extra)
    local out, errl = {}, {}
    local code = cli.main(vim.list_extend({ "budget", root }, argv), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        errl[#errl + 1] = s
      end,
      budget = vim.tbl_extend(
        "force",
        { run = fake_run, machine = { os = "T", cpu = "fake", arch = "x", cpus = 1, nvim = "0" } },
        extra or {}
      ),
    })
    return code, table.concat(out, "\n"), table.concat(errl, "\n")
  end
  local baseline = root .. "/TESTS/bench/baseline.json"

  local code, _, err = budget_cmd({})
  local out
  eq(code, 2, "no baseline: usage error, never a pass")
  has(err, "budget --update", "and it says how to make one")
  eq(vim.uv.fs_stat(baseline), nil, "nothing was written without --update")

  code, out, err = budget_cmd({ "--update" })
  eq(code, 0, "--update writes the baseline\n" .. err)
  has(out, "baseline written", "and says where")
  local written = vim.json.decode(slurp(baseline))
  eq(written.version, 1, "baseline version")
  eq(written.cases.fast.median_ms, 5, "baseline: the fast case")
  eq(written.cases.slow.median_ms, 40, "baseline: the slow case")
  eq(written.machine.cpu, "fake", "baseline: the machine is recorded")
  eq(written.method.runs, 5, "baseline: the method is recorded")
  ok(written.date:match("^%d%d%d%d%-%d%d%-%d%dT"), "baseline: a UTC date")

  code, out, err = budget_cmd({})
  eq(code, 0, "unchanged: within budget\n" .. out .. err)
  has(out, "OK", "rows say OK")

  cost.slow = 70 -- 1.75x: within the default factor of 2
  code = budget_cmd({})
  eq(code, 0, "1.75x is within the default factor 2.0")

  cost.slow = 100 -- 2.5x: over
  code, out = budget_cmd({})
  eq(code, 1, "2.5x fails the check (exit 1)")
  has(out, "EXCEEDED", "the row says EXCEEDED")
  has(out, "slow", "and names the case")
  has(out, "1 case(s) exceeded", "and counts")

  code = budget_cmd({ "--factor", "3" })
  eq(code, 0, "--factor 3 allows 2.5x")
  code = budget_cmd({ "--factor=2.4" })
  eq(code, 1, "--factor 2.4 does not")

  -- budget.factor from .testing.lua
  local conf = assert(io.open(root .. "/.testing.lua", "wb"))
  conf:write("return { budget = { factor = 3.0 } }\n")
  conf:close()
  code = budget_cmd({})
  eq(code, 0, "budget.factor of .testing.lua applies")
  code = budget_cmd({ "--factor", "2" })
  eq(code, 1, "--factor beats the config")

  -- another baseline path
  code, _, err = budget_cmd({ "--baseline", root .. "/other.json" })
  eq(code, 2, "--baseline names another file: missing means usage error")
  has(err, "other.json", "the message names it")

  -- --filter + --update keeps the cases that were not measured
  cost.slow = 40
  code, _, err = budget_cmd({ "--update", "--filter", "fast" })
  eq(code, 0, "partial update: " .. err)
  written = vim.json.decode(slurp(baseline))
  eq(written.cases.slow.median_ms, 40, "the case that was not measured keeps its baseline")
  code = budget_cmd({ "--filter", "nothing-like-this" })
  eq(code, 2, "a filter that matches nothing is a usage error")

  -- a case that cannot be measured: exit 3, and the baseline is NOT rewritten
  local failing = {
    run = function()
      return {
        {
          name = "fast",
          measure = { median_ms = 5, min_ms = 5, max_ms = 5, runs = 1, samples = { 5 } },
        },
        { name = "slow", error = "setup failed: boom" },
      }
    end,
  }
  code, out = budget_cmd({}, failing)
  eq(code, 3, "an unmeasurable case is infrastructure (exit 3), never a pass")
  has(out, "ERROR", "the row says ERROR")
  has(out, "boom", "with the reason")
  local before = slurp(baseline)
  code, _, err = budget_cmd({ "--update" }, failing)
  eq(code, 3, "--update with an unmeasurable case fails")
  has(err, "NOT written", "and says the baseline stayed")
  eq(slurp(baseline), before, "the baseline file is untouched")

  -- another machine is a note, not a failure
  code, out = budget_cmd(
    {},
    { machine = { os = "Other", cpu = "other", arch = "x", cpus = 1, nvim = "0" } }
  )
  eq(code, 0, "a baseline from another machine still checks")
  has(out, "another machine", "and says so")

  -- a gate that compared nothing is not green: a measured case without a baseline entry is exit 2
  local renamed = {
    run = function()
      return {
        {
          name = "fast",
          measure = { median_ms = 5, min_ms = 5, max_ms = 5, runs = 1, samples = { 5 } },
        },
        {
          name = "renamed",
          measure = { median_ms = 5, min_ms = 5, max_ms = 5, runs = 1, samples = { 5 } },
        },
      }
    end,
  }
  code, out, err = budget_cmd({}, renamed)
  eq(code, 2, "a case with no baseline entry compared nothing: not a pass")
  has(out, "no baseline entry", "the note says what happened")
  has(err, "nothing was compared", "and so does the error")
  has(out, "nobody measures any more", "a baseline entry that is not measured any more is reported")
  has(out, "slow", "by name")
  code = budget_cmd({ "--allow-new" }, renamed)
  eq(code, 0, "--allow-new accepts it")
  _, out = budget_cmd({ "--filter", "fast" }, renamed)
  ok(not out:find("nobody measures", 1, true), "a filtered run does not report unmeasured entries")

  -- a baseline file is untrusted text: the machine is plain and bounded in the note
  local f = assert(io.open(baseline, "rb"))
  local raw = vim.json.decode(f:read("*a"))
  f:close()
  raw.machine = { os = "Evil\n::error::INJECTED", cpu = "\27]0;TITLE\7" .. string.rep("x", 500) }
  f = assert(io.open(baseline, "wb"))
  f:write(vim.json.encode(raw))
  f:close()
  _, out = budget_cmd({})
  has(out, "another machine", "the other machine is noted")
  ok(not out:find("\27", 1, true), "no escape character reaches the output")
  ok(not out:find("\n::error::", 1, true), "no line of the output starts a workflow command")
  ok(#out < 2000, "and the text is bounded")

  -- the budget options belong to `budget`
  local o, e2 = {}, {}
  local c = cli.main({ root, "--factor", "2" }, {
    out = function(s)
      o[#o + 1] = s
    end,
    err = function(s)
      e2[#e2 + 1] = s
    end,
  })
  eq(c, 2, "--factor on a normal run is refused")
  has(table.concat(e2, "\n"), "belongs to `budget`", "and says where it belongs")

  -- the real cases, at toy size: every one of them runs and measures
  do
    local before_dirs = vim.fn.glob(vim.fs.dirname(vim.fn.tempname()) .. "/*-budget-*", false, true)
    local real = budget.run({
      runs = 1,
      warmup = 0,
      sizes = { spec_files = 6, ir_cases = 40, history_cases = 12, hash_files = 8, key_specs = 6 },
    })
    local names = {}
    for _, r in ipairs(real) do
      names[#names + 1] = r.name
      ok(r.measure ~= nil, ("%s measured: %s"):format(r.name, tostring(r.error)))
      ok(r.measure and r.measure.median_ms >= 0, r.name .. " has a time")
    end
    eq(names, {
      "doctor_startup",
      "discover_100",
      "ir_encode_10k",
      "history_append",
      "cache_hash_500",
      "cache_key_100",
      "child_spawn_cold",
      "child_kill",
      "child_spawn_warm",
    }, "the real cases, in order")
    local after_dirs = vim.fn.glob(vim.fs.dirname(vim.fn.tempname()) .. "/*-budget-*", false, true)
    eq(#after_dirs, #before_dirs, "the scratch directories are removed")
  end

  vim.fn.delete(root, "rf")
end
