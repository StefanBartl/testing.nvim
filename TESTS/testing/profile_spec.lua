-- TESTS/testing/profile_spec.lua -- `testing.run.profile`: the numbers of `--profile` (phases, slowest files and cases,
-- histogram, spawn cost, pool utilisation), the additive `run.profile` of the IR (still valid, still encodable),
-- the text report, and the end-to-end flag through `testing.cli`.

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local profile = require("testing.run.profile")
  local result = require("testing.core.result")

  ---@param spec { [1]: string, [2]: string, [3]: number, [4]?: string }[] file, name, ms, status
  ---@return Testing.Result
  local function ir(spec, jobs)
    local res = result.new({
      root = "<REPO>",
      project_key = "p@1",
      nvim = "0.12.0",
      os = "x",
      jobs = jobs or 1,
    })
    for _, row in ipairs(spec) do
      local c = result.new_case({ file = row[1], name = row[2] })
      c.assertions[1] = { ok = row[4] ~= "fail", kind = "eq" }
      c.duration_ms = row[3]
      result.add_case(res, result.finish_case(c))
    end
    result.finalize(res)
    return res
  end

  -- collector: phases with a fake clock, nested begin/finish, a phase that raises is still closed
  do
    local now = 0
    local c = profile.new({
      clock = function()
        return now
      end,
    })
    c:begin("discovery")
    now = 30
    c:finish("discovery")
    c:begin("run")
    now = 130
    c:finish("run")
    c:begin("run") -- a phase of two parts adds up
    now = 150
    c:finish("run")
    eq(c:ms("discovery"), 30, "discovery ms")
    eq(c:ms("run"), 120, "run adds its two parts")
    eq(c:ms("never"), nil, "a phase nobody marked is absent, not zero")
    c:finish("never") -- no-op
    c:finish("discovery") -- a second finish is a no-op
    eq(c:ms("discovery"), 30, "finish twice does not double count")
    local value = c:time("select", function(a, b)
      now = now + 5
      return a + b, "two"
    end, 1, 2)
    eq(value, 3, "time returns what the function returned")
    eq(c:ms("select"), 5, "and measured it")
    local okc, e = pcall(c.time, c, "boom", function()
      now = now + 7
      error("bang", 0)
    end)
    eq(okc, false, "time re-raises")
    eq(e, "bang", "the same error")
    eq(c:ms("boom"), 7, "and the phase is closed")
  end

  -- histogram: the upper bounds belong to their class, the last class is open, bad durations count as 0
  do
    local cases = {}
    for _, ms in ipairs({
      0.2,
      1,
      1.01,
      5,
      5.5,
      10,
      49,
      50,
      99,
      100,
      101,
      500,
      501,
      1000,
      4999,
      5000,
      5001,
      90000,
    }) do
      cases[#cases + 1] = { duration_ms = ms }
    end
    cases[#cases + 1] = {}
    local h = profile.histogram(cases)
    eq(h.edges_ms, { 1, 5, 10, 50, 100, 500, 1000, 5000 }, "the edges")
    eq(
      h.counts,
      { 3, 2, 2, 2, 2, 2, 2, 2, 2 },
      "every case in exactly one class (the case without a duration counts as 0)"
    )
    local total = 0
    for _, n in ipairs(h.counts) do
      total = total + n
    end
    eq(total, #cases, "the histogram holds every case")
  end

  -- build: slowest files and cases, in order, with ties broken by name; durations summed per file
  local res = ir({
    { "TESTS/a_spec.lua", "one", 10 },
    { "TESTS/a_spec.lua", "two", 30 },
    { "TESTS/b_spec.lua", "slow", 500, "fail" },
    { "TESTS/c_spec.lua", "x", 2 },
    { "TESTS/d_spec.lua", "x", 2 },
  })
  local p = profile.build(res, { phases = { discovery = 12.3456, run = 600, total = 700 } })
  eq(p.version, 1, "version")
  eq(
    p.phases,
    { discovery = 12.346, run = 600, total = 700 },
    "phases are rounded to microseconds and nothing is invented"
  )
  eq(
    vim.tbl_map(function(f)
      return f.file
    end, p.files),
    { "TESTS/b_spec.lua", "TESTS/a_spec.lua", "TESTS/c_spec.lua", "TESTS/d_spec.lua" },
    "files: slowest first, ties by name"
  )
  eq(p.files[2].ms, 40, "a file's time is the sum of its cases")
  eq(p.files[2].cases, 2, "and it counts them")
  eq(p.files[2].source, "cases", "the source of the number is named")
  eq(
    p.cases[1],
    { id = "TESTS/b_spec.lua::slow", ms = 500, status = "fail" },
    "cases: the slowest first, with status"
  )
  eq(p.spawn, nil, "an in-process run has no spawn section")
  eq(p.pool, nil, "and no pool section")
  eq(p.histogram.counts[2], 2, "histogram: two cases in (1, 5] ms")

  -- caps
  do
    local rows = {}
    for i = 1, 80 do
      rows[#rows + 1] = { ("TESTS/f%03d_spec.lua"):format(i), "c", i }
    end
    local big = profile.build(ir(rows), {})
    eq(#big.files, profile.MAX_FILES, "files are capped")
    eq(#big.cases, profile.MAX_CASES, "cases are capped")
    eq(big.files[1].file, "TESTS/f080_spec.lua", "and the slowest are the ones kept")
  end

  -- an isolated run: spawn cost from the pool statistics and the driver's per-file split, utilisation
  do
    local iso = ir({
      { "TESTS/a_spec.lua", "x", 100 },
      { "TESTS/b_spec.lua", "y", 100 },
    }, 2)
    local q = profile.build(iso, {
      phases = { run = 200 },
      jobs = 2,
      pool = { boot_ms = 90, spawned = 2, reused = 0, discarded = 1, files = 2 },
      file_timings = {
        ["TESTS/a_spec.lua"] = { wall_ms = 160, spawn_ms = 45, load_ms = 10, run_ms = 100 },
        ["TESTS/b_spec.lua"] = { wall_ms = 150, spawn_ms = 45, load_ms = 5, run_ms = 100 },
      },
    })
    eq(q.spawn.measured, true, "spawn is measured")
    eq(q.spawn.count, 4, "count: pool members plus per-file spawns the driver reported")
    eq(q.spawn.total_ms, 180, "total: pool boot plus per-file spawn")
    eq(q.spawn.mean_ms, 45, "mean")
    eq(q.files[1].file, "TESTS/a_spec.lua", "the driver's wall time orders the files")
    eq(q.files[1].ms, 160, "and replaces the sum of the cases")
    eq(q.files[1].source, "driver", "saying so")
    eq(q.files[1].spawn_ms, 45, "the split is kept")
    eq(q.files[1].load_ms, 10, "load")
    eq(q.files[1].run_ms, 100, "run")
    eq(q.pool.jobs, 2, "pool: jobs")
    eq(q.pool.spawned, 2, "pool: members")
    eq(q.pool.discarded, 1, "pool: discarded")
    eq(q.pool.utilisation, 0.775, "utilisation = busy / (jobs * run wall): (160+150) / (2*200)")
    eq(q.pool.approx, false, "exact when every file has the driver's wall time")

    -- without per-file timings: honest about it
    local r = profile.build(iso, {
      phases = { run = 400 },
      jobs = 2,
      pool = { boot_ms = 50, spawned = 2, reused = 0, discarded = 0 },
    })
    eq(r.pool.approx, true, "utilisation from case time only is marked approximate")
    eq(r.pool.utilisation, 0.25, "(100+100) / (2*400)")
    local d = profile.build(
      iso,
      { phases = { run = 400 }, jobs = 2, file_timings = { ["TESTS/a_spec.lua"] = {} } }
    )
    eq(
      d.spawn,
      { measured = false },
      "a driver that reports no spawn time says it does not measure"
    )
  end

  -- the IR: the profile is additive, the IR stays valid and encodable
  do
    local p2 = profile.build(res, { phases = { run = 5 } })
    profile.attach(res, p2)
    ok((res.run --[[@as table]]).profile == p2, "attach puts the profile at run.profile")
    local valid, problems = result.validate(res)
    ok(valid, "the IR with a profile validates: " .. vim.inspect(problems))
    local text, err = result.encode(res)
    ok(text ~= nil, "and encodes: " .. tostring(err))
    local back = vim.json.decode(text --[[@as string]])
    eq(
      back.run.profile.files[1].file,
      "TESTS/b_spec.lua",
      "the profile survives the JSON round trip"
    )
    eq(back.run.profile.histogram.edges_ms[1], 1, "with its histogram")
    eq(back.schema_version, 1, "the schema version did not change")
  end

  -- the text report
  do
    local p3 =
      profile.build(res, { phases = { discovery = 12, run = 600, report = 3, total = 700 } })
    local lines = profile.lines(p3, { top = 2 })
    local text = table.concat(lines, "\n")
    eq(lines[1], "profile:", "header")
    has(text, "discovery 12.0 ms", "phase: discovery")
    has(text, "run 600.0 ms", "phase: run")
    has(text, "total 700.0 ms", "phase: total")
    has(text, "slowest files:", "files section")
    has(text, "TESTS/b_spec.lua", "slowest file named")
    ok(not text:find("TESTS/d_spec.lua", 1, true), "top = 2 shows two rows")
    has(text, "slowest cases:", "cases section")
    has(text, "case durations:", "histogram section")
    has(text, "#", "with bars")
    has(
      profile.lines({
        version = 1,
        phases = { run = 2500 },
        files = {},
        cases = {},
        histogram = { edges_ms = {}, counts = {} },
      })[2],
      "2.50 s",
      "seconds above one second"
    )
  end

  -- end to end: `--profile` writes the text to stderr, `run.profile` into the IR, and changes no verdict
  do
    local cli = require("testing.cli")
    local real_inproc = require("testing.run.inproc")
    local root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/TESTS", "p")
    local f = assert(io.open(root .. "/TESTS/x_spec.lua", "wb"))
    f:write("return function(H)\n  H.ok(true, 'x')\nend\n")
    f:close()
    local out, errl = {}, {}
    local json = root .. "/out.json"
    local stub = setmetatable({
      run = function(opts)
        local r = ir({ { "TESTS/x_spec.lua", "x_spec.lua", 12 } })
        return {
          result = r,
          failed = 0,
          failed_files = 0,
          total = 1,
          files_run = #opts.files,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 12,
          exit_code = 0,
          pool = { boot_ms = 40, spawned = 1, reused = 0, discarded = 0, files = 1 },
          file_timings = {
            ["TESTS/x_spec.lua"] = { wall_ms = 60, spawn_ms = 40, load_ms = 3, run_ms = 12 },
          },
        }
      end,
    }, { __index = real_inproc })
    local code = cli.main({ root, "--profile", "--json", json }, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        errl[#errl + 1] = s
      end,
      state_dir = root .. "/state",
      color = false,
      inproc = stub,
    })
    eq(code, 0, "--profile does not change the verdict\n" .. table.concat(errl, "\n"))
    local e = table.concat(errl, "\n")
    has(e, "profile:", "the report is on stderr (stdout keeps the sentinel last)")
    has(e, "discovery", "with the discovery phase")
    has(e, "report", "and the report phase")
    has(e, "child editors: 2 started", "and the spawn cost: pool member plus per-file spawn")
    local o = table.concat(out, "\n")
    ok(not o:find("profile:", 1, true), "nothing of the profile on stdout")
    local text = assert(io.open(json, "rb")):read("*a")
    local doc = vim.json.decode(text)
    ok(doc.run.profile ~= nil, "the IR carries run.profile")
    eq(doc.run.profile.phases.run ~= nil, true, "with the run phase")
    eq(doc.run.profile.phases.discovery ~= nil, true, "and the discovery phase")
    eq(
      doc.run.profile.phases.report,
      nil,
      "the report phase is only in the text (the IR was written before it ended)"
    )
    eq(doc.run.profile.files[1].source, "driver", "the driver's timings are used")
    vim.fn.delete(root, "rf")
  end
end
