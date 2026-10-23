-- TESTS/testing/events_stream_spec.lua -- the run event stream as an editor consumes it (UI slice 2): the plan in
-- `run_start`, `file_start` / `file_end` around the cases of a file, and `testing.run.events_reader`, which turns the
-- bytes of `--events -` into validated events (chunk boundaries, over-long and hostile lines, an aborted stream).
---@diagnostic disable: missing-fields, need-check-nil, param-type-mismatch

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local events = require("testing.run.events")
  local reader_mod = require("testing.run.events_reader")
  local plan_mod = require("testing.run.plan")
  local json = require("lib.nvim.json")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---An emitter over a list, and a way to read it back as objects.
  local function recording()
    local lines = {}
    local em = events.new(function(line)
      lines[#lines + 1] = line
      return true
    end, { run = 1 })
    local function objs()
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = json.decode(l)
      end
      return out
    end
    return em, lines, objs
  end

  ---@param objs table[]
  ---@return string[]
  local function kinds_of(objs)
    local out = {}
    for i, o in ipairs(objs) do
      out[i] = o.event .. (o.file and (":" .. o.file) or "")
    end
    return out
  end

  -- plan: the estimate of the cases ---------------------------------------------------
  do
    local described = table.concat({
      'describe("g", function()',
      '  it("one", function() end)',
      '  it("two", function() end)',
      "end)",
      'it("three", function() end)',
    }, "\n")
    eq(plan_mod.estimate_text(described), 3, "plan: it() positions are counted")
    eq(
      plan_mod.estimate_text("return function(H) H.eq(1, 1) end"),
      1,
      "plan: a file without them is one case"
    )
    eq(plan_mod.estimate_text(""), 1, "plan: an empty file is one case")

    write(tmp .. "/p/TESTS/a_spec.lua", described)
    write(tmp .. "/p/TESTS/b_spec.lua", "return function(H) end")
    local big = tmp .. "/p/TESTS/big_spec.lua"
    write(big, ("-- x\n"):rep(math.floor(plan_mod.MAX_FILE_BYTES / 5) + 10))
    local p = plan_mod.build(tmp .. "/p", {
      { rel = "TESTS/b_spec.lua" },
      { rel = "TESTS/a_spec.lua" },
      { rel = "TESTS/big_spec.lua" },
      { rel = "TESTS/missing_spec.lua" },
    })
    eq(
      p.files,
      { "TESTS/b_spec.lua", "TESTS/a_spec.lua", "TESTS/big_spec.lua", "TESTS/missing_spec.lua" },
      "plan: run order"
    )
    eq(p.estimates["TESTS/a_spec.lua"], 3, "plan: per file")
    eq(p.estimates["TESTS/b_spec.lua"], 1, "plan: a script is one")
    eq(p.estimates["TESTS/big_spec.lua"], 1, "plan: a file over the cap is not scanned")
    eq(p.estimates["TESTS/missing_spec.lua"], 1, "plan: a file that cannot be read is one")
    eq(p.cases_estimate, 6, "plan: the sum")
  end

  -- the emitter: the plan, file_start / file_end ------------------------------------------
  do
    local em, _, objs = recording()
    em:start({
      project = "proj",
      files_total = 5,
      files_selected = 2,
      files = { "a", "b" },
      estimates = { a = 3, b = 1 },
    })
    em:file_start("a")
    em:case({ file = "a", id = "a::x", status = "pass", duration_ms = 1 })
    em:case({ file = "a", id = "a::y", status = "fail", duration_ms = 2.5 })
    em:case({ file = "b", id = "b::z", status = "pass", duration_ms = 1 })
    em:done(1, nil)
    local o = objs()
    eq(kinds_of(o), {
      "run_start",
      "file_start:a",
      "case:a",
      "case:a",
      "file_end:a",
      "file_start:b",
      "case:b",
      "file_end:b",
      "run_done",
    }, "a file is closed when the next begins, and the last one when the run is done")
    eq(o[1].files, { "a", "b" }, "run_start: the plan lists the files in run order")
    eq(o[1].cases_estimate, 4, "run_start: the estimate")
    eq(o[1].cases_estimated, true, "run_start: and says it is an estimate")
    eq(o[2].cases_estimate, 3, "file_start: the estimate of the file")
    eq(o[2].cases_estimated, true, "file_start: marked")
    eq(o[5].cases, 2, "file_end: cases")
    eq(o[5].failed, 1, "file_end: red cases")
    eq(o[5].duration_ms, 3.5, "file_end: duration")
    eq(o[6].cases_estimate, 1, "the second file's estimate")
  end

  -- file_start is once per file, hooks and cases alike -------------------------------------
  do
    local em, _, objs = recording()
    em:start({ files = { "a" }, estimates = { a = 1 } })
    em:file_start("a")
    em:file_start("a")
    em:case({ file = "a", id = "a::x", status = "pass", duration_ms = 1 })
    em:done(0, nil)
    local n = 0
    for _, o in ipairs(objs()) do
      if o.event == "file_start" then
        n = n + 1
      end
    end
    eq(n, 1, "file_start: once per file")
  end

  -- with --jobs several files start before the first case; their cases and ends stay in order ---
  do
    local em, _, objs = recording()
    em:start({ files = { "a", "b", "c" }, estimates = {} })
    em:file_start("a")
    em:file_start("b")
    em:file_start("c")
    em:case({ file = "a", id = "a::1", status = "pass", duration_ms = 1 })
    em:case({ file = "b", id = "b::1", status = "pass", duration_ms = 1 })
    em:done(0, nil)
    eq(
      kinds_of(objs()),
      {
        "run_start",
        "file_start:a",
        "file_start:b",
        "file_start:c",
        "case:a",
        "file_end:a",
        "case:b",
        "file_end:b",
        "file_end:c",
        "run_done",
      },
      "jobs: starts first, then each file's cases and end in order; a file without cases is closed at the end"
    )
  end

  -- an abort closes the files that began ------------------------------------------------
  do
    events.reset()
    local lines = {}
    local sink = function(line)
      lines[#lines + 1] = line
      return true
    end
    local running = assert(events.open("-", nil, sink))
    running:start({ files = { "a", "b" }, estimates = {} })
    running:case({ file = "a", id = "a::1", status = "pass", duration_ms = 1 })
    running:file_start("b")
    events.abort()
    local last = {}
    for i, l in ipairs(lines) do
      last[i] = json.decode(l)
    end
    eq(kinds_of(last), {
      "run_start",
      "file_start:a",
      "case:a",
      "file_start:b",
      "file_end:a",
      "file_end:b",
      "run_done",
    }, "abort: every file that began is closed before run_done")
    eq(last[#last].aborted, true, "abort: run_done says aborted")
    running:close()
    events.reset()
  end

  -- a plan with more files than the cap says so ----------------------------------------------
  do
    local em, _, objs = recording()
    local many = {}
    for i = 1, events.MAX_PLAN_FILES + 5 do
      many[i] = "f" .. i
    end
    em:start({ files = many, estimates = {} })
    local first = objs()[1]
    eq(#first.files, events.MAX_PLAN_FILES, "the plan is capped")
    eq(first.plan_truncated, true, "and says it was cut")
    eq(first.cases_estimate, events.MAX_PLAN_FILES + 5, "the estimate still covers every file")
  end

  -- end to end: a real run, read back through the reader ------------------------------------------
  do
    events.reset()
    local cli = require("testing.cli")
    local root = tmp .. "/proj"
    write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.eq(1, 1, 'a')\nend\n")
    write(root .. "/TESTS/b_spec.lua", "return function(H)\n  H.eq(1, 2, 'b')\nend\n")
    -- with `--events -` the stream is what `out` receives (one call per line); the reporter goes to `err`
    local sunk = {}
    local code = cli.main({ root, "--no-cache", "--events", "-" }, {
      out = function(line)
        sunk[#sunk + 1] = line
      end,
      err = function() end,
      state_dir = tmp .. "/state",
      color = false,
    })
    eq(code, 1, "e2e: the red project is exit 1")
    local got, problems = {}, {}
    local rd = reader_mod.new({
      on_event = function(ev)
        got[#got + 1] = ev
      end,
      on_problem = function(msg)
        problems[#problems + 1] = msg
      end,
    })
    -- feed the stream byte by byte: the worst chunking there is
    local text = table.concat(sunk, "\n") .. "\n"
    for i = 1, #text do
      rd:feed(text:sub(i, i))
    end
    rd:finish(code)
    eq(problems, {}, "e2e: nothing the reader refused")
    eq(rd.ended, true, "e2e: the stream ended with its own run_done")
    eq(kinds_of(got), {
      "run_start",
      "file_start:TESTS/a_spec.lua",
      "case:TESTS/a_spec.lua",
      "file_start:TESTS/b_spec.lua", -- announced when the file begins, before the end of the one before
      "file_end:TESTS/a_spec.lua",
      "case:TESTS/b_spec.lua",
      "file_end:TESTS/b_spec.lua",
      "run_done",
    }, "e2e: the order of a real run")
    eq(got[1].files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }, "e2e: the plan names the files")
    eq(got[1].cases_estimate, 2, "e2e: and estimates the cases")
    eq(got[#got].verdict, "red", "e2e: verdict")
    eq(got[#got].exit_code, 1, "e2e: exit code")
    eq(got[#got].synthetic, nil, "e2e: not synthesized")
    eq(got[7].failed, 1, "e2e: file_end of the red file counts it")
    eq(got[5].cases, 1, "e2e: and of the green one")
  end

  -- end to end with --jobs: the files start in child editors, several before the first case ------------------------
  do
    events.reset()
    local cli = require("testing.cli")
    local root = tmp .. "/jobs"
    write(root .. "/.testing.lua", "return { isolated = 'file' }\n")
    for _, n in ipairs({ "a", "b", "c" }) do
      write(
        root .. "/TESTS/" .. n .. "_spec.lua",
        ("return function(H)\n  H.eq(1, 1, '%s')\nend\n"):format(n)
      )
    end
    local sunk = {}
    local code = cli.main({ root, "--no-cache", "--jobs", "2", "--events", "-" }, {
      out = function(line)
        sunk[#sunk + 1] = line
      end,
      err = function() end,
      state_dir = tmp .. "/state-jobs",
      color = false,
    })
    eq(code, 0, "jobs: green")
    local at, order = {}, {}
    for i, l in ipairs(sunk) do
      local o = json.decode(l)
      order[#order + 1] = o.event
      at[o.event .. ":" .. (o.file or "")] = i
    end
    for _, n in ipairs({ "a", "b", "c" }) do
      local f = "TESTS/" .. n .. "_spec.lua"
      ok(
        at["file_start:" .. f] and at["case:" .. f] and at["file_end:" .. f],
        "jobs: " .. f .. " is announced completely"
      )
      ok(at["file_start:" .. f] < at["case:" .. f], "jobs: " .. f .. " starts before its case")
      ok(at["case:" .. f] < at["file_end:" .. f], "jobs: " .. f .. " ends after its case")
    end
    eq(order[#order], "run_done", "jobs: the stream ends with run_done")
    eq(order[1], "run_start", "jobs: and begins with run_start")
  end

  -- the reader ------------------------------------------------------------------------------------
  local function new_reader(opts)
    local got, problems = {}, {}
    local rd = reader_mod.new(vim.tbl_extend("force", {
      on_event = function(ev)
        got[#got + 1] = ev
      end,
      on_problem = function(msg)
        problems[#problems + 1] = msg
      end,
    }, opts or {}))
    return rd, got, problems
  end
  local function L(kind, fields)
    return events.line(kind, fields, { run = 1, ts = 5 })
  end

  do -- chunk boundaries, CRLF and a last line without a newline
    local rd, got = new_reader()
    local a = L("file_start", { file = "x" })
    local b = L("case", { file = "x", id = "x::c", status = "pass", duration_ms = 3 })
    local text = a
      .. "\r\n"
      .. b
      .. "\n"
      .. L("file_end", { file = "x", cases = 1, failed = 0, duration_ms = 3 })
    rd:feed(text:sub(1, 10))
    rd:feed(text:sub(11, #a + 3))
    rd:feed(text:sub(#a + 4))
    eq(#got, 2, "reader: two complete lines delivered, the third waits for its newline")
    eq(got[1].event, "file_start", "reader: a CRLF line end is a line end")
    eq(got[2].duration_ms, 3, "reader: fields survive")
    rd:finish()
    eq(got[3].event, "file_end", "reader: finish reads the last line")
    eq(got[4].event, "run_done", "reader: and a stream without run_done ends with a synthetic one")
    eq(got[4].aborted, true, "reader: aborted")
    eq(got[4].synthetic, true, "reader: and marked synthetic")
  end

  do -- the driver dies: the cases announced before stay, the end is synthesized with the exit code
    local rd, got = new_reader()
    rd:feed(L("run_start", { files_total = 1 }) .. "\n")
    rd:feed(L("case", { file = "x", id = "x::c", status = "fail", duration_ms = 1 }) .. "\n")
    rd:feed('{"v":1,"event":"case","file":"x","id":"x::half') -- killed mid-line
    rd:finish(137)
    eq(#got, 3, "reader: run_start, the case, and the synthetic end; the half line is not an event")
    eq(got[2].status, "fail", "reader: the announced case stays")
    eq(got[3].exit_code, 137, "reader: the synthetic end carries the exit code of the process")
  end

  do -- a stream that ended properly gets no second end
    local rd, got = new_reader()
    rd:feed(
      L("run_start", {}) .. "\n" .. L("run_done", { exit_code = 0, verdict = "green" }) .. "\n"
    )
    rd:finish(0)
    eq(#got, 2, "reader: no synthetic end after a real one")
    eq(got[2].verdict, "green", "reader: verdict")
  end

  do -- an over-long line is dropped as a whole, also when its end comes later, and the next line is fine
    local rd, got, problems = new_reader({ max_line = 200 })
    local ok_line = L("file_start", { file = "after" })
    rd:feed(("x"):rep(150))
    rd:feed(("y"):rep(150)) -- over the limit here
    rd:feed(("z"):rep(500) .. "\n" .. ok_line .. "\n")
    eq(#got, 1, "reader: only the line after the long one")
    eq(got[1].file, "after", "reader: and it is intact")
    eq(#problems, 1, "reader: the long line is reported once")
    ok(problems[1]:find("longer than 200", 1, true), "reader: and says why")

    local rd2, got2, problems2 = new_reader({ max_line = 100 })
    rd2:feed(("q"):rep(300) .. "\n" .. ok_line .. "\n")
    eq(#got2, 1, "reader: a long line inside one chunk")
    eq(#problems2, 1, "reader: reported")
  end

  do -- hostile and wrong lines are problems, never events and never errors
    local rd, got = new_reader()
    local hostile = {
      "not json at all",
      "[1,2,3]",
      '"a string"',
      '{"v":2,"event":"case","file":"x","id":"x::y","status":"pass","duration_ms":1}',
      '{"v":1,"event":"case","file":"x","id":"x::y","status":"weird","duration_ms":1}',
      '{"v":1,"event":"case","file":"x","id":"x::y","status":"pass","duration_ms":-5}',
      '{"v":1,"event":"case","file":"x","id":"","status":"pass","duration_ms":1}',
      '{"v":1,"event":"case","file":5,"id":"x::y","status":"pass","duration_ms":1}',
      '{"v":1,"event":"run_start","files":"not a list"}',
      '{"v":1,"event":"file_start"}',
      '{"v":1}',
    }
    rd:feed(table.concat(hostile, "\n") .. "\n")
    eq(#got, 0, "reader: no hostile line becomes an event")
    eq(rd.problems, #hostile, "reader: every one is counted")

    local unknown = new_reader()
    unknown:feed('{"v":1,"event":"from_the_future","x":1}\n')
    eq(unknown.ignored, 1, "reader: an unknown kind is ignored, not a problem")
    eq(unknown.problems, 0, "reader: and not counted as one")
  end

  do -- words of the project under test are defused, whatever the emitter did
    local rd, got = new_reader()
    local evil = "a\\u001b[31mred\\u0000\\u202eb\\u009bx"
    rd:feed(
      '{"v":1,"event":"case","file":"'
        .. evil
        .. '","id":"'
        .. evil
        .. '","status":"pass","duration_ms":1}\n'
    )
    eq(#got, 1, "reader: the event is delivered")
    ok(not got[1].file:find("[%c]"), "reader: no control character in a file")
    ok(not got[1].id:find("\226\128\174", 1, true), "reader: no bidi override in an id")
    ok(not got[1].id:find("\194\155", 1, true), "reader: no C1 control in an id")
    ok(got[1].id:find("red", 1, true), "reader: the readable part stays")
    local rd2, got2 = new_reader()
    rd2:feed(json.encode({
      v = 1,
      event = "case",
      file = "f",
      id = ("i"):rep(5000),
      status = "pass",
      duration_ms = 1,
    }) .. "\n")
    ok(#got2[1].id <= events.MAX_STRING, "reader: a long id is capped")
  end

  do -- the plan is validated: files must be strings and are capped
    local rd, got = new_reader()
    local many = {}
    for i = 1, events.MAX_PLAN_FILES + 10 do
      many[i] = "f" .. i
    end
    rd:feed(json.encode({
      v = 1,
      event = "run_start",
      files = many,
      cases_estimate = 7,
      cases_estimated = true,
    }) .. "\n")
    eq(#got[1].files, events.MAX_PLAN_FILES, "reader: the plan is capped")
    eq(got[1].cases_estimate, 7, "reader: the estimate")
    eq(got[1].cases_estimated, true, "reader: marked as an estimate")
    local bad, gotbad = new_reader()
    bad:feed('{"v":1,"event":"run_start","files":["a",5]}\n')
    eq(#gotbad, 0, "reader: a plan with a non-string file is refused")
  end

  do -- a consumer that raises does not break the stream
    local count = 0
    local rd = reader_mod.new({
      on_event = function()
        count = count + 1
        error("consumer bug")
      end,
    })
    rd:feed(L("file_start", { file = "a" }) .. "\n" .. L("file_start", { file = "b" }) .. "\n")
    eq(count, 2, "reader: both events were offered")
  end

  do -- problems are reported to the callback only up to a bound
    local rd, _, problems = new_reader()
    local junk = {}
    for i = 1, reader_mod.MAX_PROBLEMS + 30 do
      junk[i] = "junk " .. i
    end
    rd:feed(table.concat(junk, "\n") .. "\n")
    eq(#problems, reader_mod.MAX_PROBLEMS, "reader: the callback hears at most MAX_PROBLEMS")
    eq(rd.problems, reader_mod.MAX_PROBLEMS + 30, "reader: the count is complete")
  end

  vim.fn.delete(tmp, "rf")
end
