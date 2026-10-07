-- TESTS/testing/slowest_timings_spec.lua -- `--order slowest-first` (the heaviest files start first, the report
-- stays in file order) and the history of durations (`timings.json`) with the warning for a file that took three
-- times its median.

return function(H)
  local ok = H.ok
  local eq = H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local slowest = require("testing.run.slowest")
  local timings = require("testing.run.timings")
  local shard = require("testing.run.shard")
  local options_mod = require("testing.run.options")
  local cli = require("testing.cli")
  local args_mod = require("testing.args")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  -- ====================================================================== the start order
  local function weights_of(list)
    return function(i)
      return list[i]
    end
  end
  eq(slowest.order(4, weights_of({ 1, 50, 10 })), { 2, 3, 1, 4 }, "heaviest first, unknown last")
  eq(slowest.order(3, weights_of({ 5, 5, 5 })), { 1, 2, 3 }, "equal weights keep file order")
  eq(slowest.order(3, weights_of({})), { 1, 2, 3 }, "no weight at all: file order")
  eq(slowest.order(0, weights_of({})), {}, "nothing")
  do
    -- a permutation of its input, whatever the weights are (a heuristic orders, it never drops a file)
    local seed = 12345
    local function rnd(n)
      seed = (seed * 1103515245 + 12345) % 2147483648
      return seed % n
    end
    for _ = 1, 200 do
      local n = rnd(30)
      local w = {}
      for i = 1, n do
        w[i] = rnd(4) == 0 and nil or rnd(100)
      end
      local got = slowest.order(n, weights_of(w))
      local seen = {}
      for _, i in ipairs(got) do
        seen[i] = (seen[i] or 0) + 1
      end
      local complete = #got == n
      for i = 1, n do
        complete = complete and seen[i] == 1
      end
      if not complete then
        ok(false, "not a permutation for " .. vim.inspect(w))
        break
      end
    end
    ok(true, "200 random weight lists: always a permutation")
  end

  -- the weights come from the remembered durations (never from the project's own claims)
  do
    local state = tmp .. "/state"
    local root = tmp .. "/wproj"
    vim.fn.mkdir(root, "p")
    local w, notes = slowest.weights(root, { shard = {} }, state)
    eq(w, {}, "nothing remembered")
    ok(notes[1]:find("no remembered duration", 1, true) ~= nil, "and it says so")
    S.write(
      shard.durations_path(root, { state_dir = state }),
      '{"TESTS/a_spec.lua": 120, "TESTS/b_spec.lua": "x", "../evil": 5}'
    )
    w, notes = slowest.weights(root, { shard = {} }, state)
    eq(
      w,
      { ["TESTS/a_spec.lua"] = 120, ["../evil"] = 5 },
      "a number is kept (the hostile entry is only a weight)"
    )
    ok(#notes >= 1, "an unusable entry is a note")
    S.write(root .. "/dur.json", '{"TESTS/c_spec.lua": 7}')
    w = slowest.weights(root, { shard = { durations = "dur.json" } }, state)
    eq(w, { ["TESTS/c_spec.lua"] = 7 }, "`shard.durations` names a file of the repository instead")
  end

  -- the CLI knows the value
  eq(
    select(1, args_mod.parse({ ".", "--order", "slowest-first" })).order,
    "slowest-first",
    "--order slowest-first"
  )
  eq(
    select(1, args_mod.parse({ ".", "--order", "priority" })).order,
    "priority",
    "--order priority is still there"
  )
  local bad, why = args_mod.parse({ ".", "--order", "fastest" })
  ok(
    bad == nil and why:find("slowest-first", 1, true) ~= nil,
    "another value is refused: " .. tostring(why)
  )
  bad = args_mod.parse({ ".", "--order", "slowest-first", "--shuffle" })
  ok(bad == nil, "--order and --shuffle exclude each other")

  -- with real children: the start order follows the weights, the report stays in file order
  do
    local root = S.new_root()
    local log = root .. "/start.log"
    local function spec(name)
      return ([[
return function(H)
  local f = io.open(%q, "ab")
  f:write(%q .. "\n")
  f:close()
  H.ok(true, %q)
end
]]):format(log, name, name)
    end
    local files, order = {}, {}
    for _, n in ipairs({ "a", "b", "c", "d" }) do
      local rel = ("TESTS/%s_spec.lua"):format(n)
      files[rel] = spec(n)
      order[#order + 1] = rel
    end
    local entries = S.project(root, files, order)
    local o = options_mod.of({ project = { isolated = "file" }, args = { jobs = 1 } })
    local report = S.run(root, entries, {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      dispatch_weights = {
        ["TESTS/a_spec.lua"] = 1,
        ["TESTS/b_spec.lua"] = 50,
        ["TESTS/c_spec.lua"] = 10,
      },
    })
    eq(S.slurp(log), "b\nc\na\nd\n", "the heaviest started first, the unweighted file last")
    local got = {}
    for _, c in ipairs(report.result.cases) do
      got[#got + 1] = c.file
    end
    eq(got, order, "the IR is in file order")
    eq(report.exit_code, 0, "green")
    os.remove(log)
    S.run(
      root,
      entries,
      { options = o, timeouts = { file_ms = 30000 }, trace_dir = root .. "/traces" }
    )
    eq(S.slurp(log), "a\nb\nc\nd\n", "without weights: file order, as before")
  end

  -- ====================================================================== the timings history
  eq(timings.median({ 5, 1, 3 }), 3, "median of three")
  eq(timings.median({ 1, 2, 3, 10 }), 2.5, "median of four")
  eq(timings.median({}), nil, "median of nothing")

  local res = require("testing.core.result").new({ root = "/p" })
  for _, spec_case in ipairs({
    { "a_spec.lua", 100 },
    { "a_spec.lua", 50 },
    { "b_spec.lua", 40 },
    { "c_spec.lua", 900, true },
    { "c_spec.lua", 5 },
  }) do
    local c =
      require("testing.core.result").new_case({ file = spec_case[1], name = tostring(#res.cases) })
    c.duration_ms = spec_case[2]
    c.cached = spec_case[3]
    c.assertions[1] = { ok = true, kind = "ok" }
    require("testing.core.result").add_case(res, c)
  end
  eq(
    timings.per_file(res),
    { ["a_spec.lua"] = 150, ["b_spec.lua"] = 40 },
    "per file; a file with a cached case is left out"
  )

  -- a regression: more than 3x the median of at least 3 runs, and at least 100 ms more
  local history = {
    ["a_spec.lua"] = { 100, 110, 90 },
    ["tiny_spec.lua"] = { 2, 2, 3 },
    ["young_spec.lua"] = { 100, 100 },
    ["steady_spec.lua"] = { 1000, 1000, 1000 },
  }
  local regs = timings.regressions(history, {
    ["a_spec.lua"] = 301,
    ["tiny_spec.lua"] = 40,
    ["young_spec.lua"] = 5000,
    ["steady_spec.lua"] = 2900,
    ["new_spec.lua"] = 9000,
  })
  eq(#regs, 1, "one regression: " .. vim.inspect(regs))
  eq(regs[1].file, "a_spec.lua", "the file")
  eq(regs[1].median, 100, "against its median")
  eq(regs[1].runs, 3, "of three runs")
  eq(
    #timings.regressions(history, { ["a_spec.lua"] = 300 }),
    0,
    "exactly three times is not more than three times"
  )
  ok(
    timings
      .line(regs[1])
      :find("a_spec.lua took 0.3 s, 3.0x its median of 0.1 s over 3 run(s)", 1, true) ~= nil,
    "the line: " .. timings.line(regs[1])
  )

  -- the history is bounded, and a file that is gone is forgotten
  local state = { state_dir = tmp .. "/tstate" }
  local root = tmp .. "/tproj"
  vim.fn.mkdir(root, "p")
  local hist = {}
  for i = 1, 15 do
    local done, why_not =
      timings.record(root, hist, { ["a_spec.lua"] = i * 10, ["gone_spec.lua"] = 1 }, state)
    ok(done, "record: " .. tostring(why_not))
    hist = timings.read(timings.path(root, state))
  end
  eq(#hist["a_spec.lua"], timings.SAMPLES, "at most SAMPLES per file")
  eq(hist["a_spec.lua"][1], 70, "the oldest go first")
  eq(hist["a_spec.lua"][timings.SAMPLES], 150, "the newest is last")
  timings.record(
    root,
    hist,
    { ["a_spec.lua"] = 1 },
    { state_dir = state.state_dir, known_files = { ["a_spec.lua"] = true } }
  )
  hist = timings.read(timings.path(root, state))
  eq(hist["gone_spec.lua"], nil, "a file that is no longer a spec is dropped")

  -- untrusted on the way back
  do
    local path = timings.path(root, state)
    local function put(text)
      S.write(path, text)
      return timings.read(path)
    end
    local f, note = put(
      '{"v":1,"files":{"x_spec.lua":[1,2,3],"bad":[1,"x"],"neg":[-1],"huge":[1e12],"hole":{"1":1,"3":3},"ctl\\u0001":[1]}}'
    )
    eq(f, { ["x_spec.lua"] = { 1, 2, 3 } }, "only the clean entry survives")
    ok(note ~= nil and note:find("unusable", 1, true) ~= nil, "and the rest is counted")
    f, note = put('{"v":2,"files":{"x_spec.lua":[1]}}')
    eq(f, {}, "another version: nothing")
    ok(note ~= nil, "with a note")
    f, note = put("{not json")
    eq(f, {}, "not JSON: nothing")
    ok(note ~= nil and note:find("not valid JSON", 1, true) ~= nil, "and why")
    f = put('{"v":1,"files":{"x_spec.lua":[1,2,3,4,5,6,7,8,9,10]}}')
    eq(f, {}, "too many samples: the entry is refused")
    S.write(path, string.rep("x", timings.MAX_BYTES + 1))
    f, note = timings.read(path)
    eq(f, {}, "larger than the cap: ignored")
    ok(note ~= nil and note:find("larger than", 1, true) ~= nil, "and said")
    eq(select(1, timings.read(tmp .. "/nothing.json")), {}, "no file: nothing, no note")
    eq(select(2, timings.read(tmp .. "/nothing.json")), nil, "no file: no note")
    vim.fn.delete(path)
  end

  -- end to end: three ordinary runs, then a slow one: a warning on stderr, never a failure
  do
    local proj = tmp .. "/e2e"
    local flag = proj .. "/slow.flag"
    S.write(proj .. "/.testing.lua", "return { guards = { fs = 'off' }, isolated = 'none' }\n")
    S.write(
      proj .. "/TESTS/drift_spec.lua",
      ([[
return function(H)
  if vim.uv.fs_stat(%q) then
    vim.wait(700)
  end
  H.ok(true, "drift")
end
]]):format(flag)
    )
    local function go()
      local out, err = {}, {}
      local code = cli.main({ proj }, {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = tmp .. "/e2e-state",
        cache_dir = tmp .. "/e2e-cache",
        color = false,
      })
      return code, table.concat(out, "\n"), table.concat(err, "\n")
    end
    for i = 1, 3 do
      local code, _, err = go()
      eq(code, 0, "run " .. i .. " is green")
      ok(
        err:find("slower than usual", 1, true) == nil,
        "run " .. i .. ": no warning while there is no history"
      )
    end
    S.write(flag, "x")
    local code, out, err = go()
    eq(code, 0, "the slow run is still green (a warning is not a failure)")
    ok(
      err:find("warning: slower than usual: TESTS/drift_spec.lua took", 1, true) ~= nil,
      "the warning names the file: " .. err
    )
    ok(out:find("TESTING_OK", 1, true) ~= nil, "and the sentinel stays")
    os.remove(flag)
    local code2, _, err2 = go()
    eq(code2, 0, "back to normal")
    ok(err2:find("slower than usual", 1, true) == nil, "no warning when it is fast again")
  end

  S.cleanup()
  vim.fn.delete(tmp, "rf")
end
