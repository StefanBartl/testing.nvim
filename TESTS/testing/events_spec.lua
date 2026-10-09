-- TESTS/testing/events_spec.lua -- `--events` (`testing.run.events`): the NDJSON stream of a run.
--
-- A supervisor reads this file while the run is going, so what matters is: every line is one self-contained JSON
-- object, the text of the code under test (case ids, file names) cannot break a line or smuggle control
-- characters into a reader, a broken stream never touches the run, and a second run in the same process
-- (`--watch`) appends instead of erasing the first.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local events = require("testing.run.events")
  local json = require("lib.nvim.json")

  ---@param path string
  ---@return table[] objects
  local function read_lines(path)
    local out = {}
    for line in io.lines(path) do
      local obj, err = json.decode(line)
      ok(obj ~= nil, "every line is JSON: " .. tostring(err) .. " in " .. line)
      out[#out + 1] = obj
    end
    return out
  end

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  -- the shape of a line
  do
    local line = events.line(
      "case",
      { file = "a_spec.lua", id = "a::b", status = "pass" },
      { run = 3, ts = 7 }
    )
    local obj = json.decode(line)
    eq(obj.v, events.VERSION, "version")
    eq(obj.event, "case", "event")
    eq(obj.run, 3, "run number")
    eq(obj.ts, 7, "time")
    eq(obj.id, "a::b", "fields travel")
    ok(not line:find("[\r\n]"), "one physical line")
  end

  -- hostile text: control characters, bidi overrides, invalid UTF-8 and size
  do
    local evil = "a\nb\r\27[31m\226\128\174c\255d"
    local line = events.line("case", { id = evil }, { run = 1 })
    ok(line ~= nil, "a hostile id still encodes")
    ok(not line:find("[\r\n]"), "no raw line break")
    local obj = json.decode(line)
    ok(not obj.id:find("[%c]"), "no control character reaches a reader")
    ok(not obj.id:find("\226\128\174", 1, true), "no bidi override")
    ok(obj.id:find("\\x0A", 1, true) ~= nil, "a line break in an id stays visible as text")
    local long = events.line("case", { id = string.rep("x", 5000) }, { run = 1 })
    eq(#json.decode(long).id <= events.MAX_STRING, true, "a long id is capped")
    local files = {}
    for i = 1, 3 do
      files[i] = "f\n" .. i
    end
    local listed = json.decode(events.line("watch_change", { files = files }, { run = 1 }))
    ok(not table.concat(listed.files):find("%c"), "strings inside a list are defused too")
  end

  -- a stream over a writer: events in order; a failing writer switches it off once, never raises
  do
    local lines = {}
    local em = events.new(function(line)
      lines[#lines + 1] = line
      return true
    end, { run = 2 })
    em:emit("run_start", { files_total = 3 })
    em:case({ file = "a", id = "a::x", status = "fail", duration_ms = 1.5 })
    em:case({ file = "b", id = "b::y", status = "pass", duration_ms = 0, cached = true })
    em:done(1, { run = { verdict = { kind = "red" } }, summary = { pass = 1, fail = 1 } })
    eq(#lines, 4, "four events")
    local last = json.decode(lines[4])
    eq(last.event, "run_done", "the last event")
    eq(last.exit_code, 1, "exit code")
    eq(last.verdict, "red", "verdict kind")
    eq(last.summary.fail, 1, "summary")
    eq(json.decode(lines[3]).cached, true, "a cached case says so")
    eq(json.decode(lines[2]).cached, nil, "an executed case does not")
    eq(json.decode(lines[1]).run, 2, "run number of the emitter")

    local failures = {}
    local broken = events.new(function()
      return false, "disk full"
    end, {
      on_error = function(msg)
        failures[#failures + 1] = msg
      end,
    })
    broken:emit("run_start", {})
    broken:emit("run_start", {})
    eq(#failures, 1, "a failing writer is reported once")
    eq(broken.alive, false, "and the stream is off")
    local thrown = events.new(function()
      error("boom")
    end)
    thrown:emit("run_start", {})
    eq(thrown.alive, false, "a writer that raises is contained")

    local nodone = events.new(function(line)
      lines[#lines + 1] = line
      return true
    end)
    nodone:done(3, nil)
    local d = json.decode(lines[#lines])
    eq(d.exit_code, 3, "a run that ended before its result still says how")
    eq(d.verdict, nil, "without a verdict")
  end

  -- files: the first run truncates, a later one appends, a note joins the run it leads to
  do
    events.reset()
    local path = tmp .. "/run.ndjson"
    vim.fn.writefile({ "stale line from an older process" }, path)
    local first = assert(events.open(path))
    first:emit("run_start", { files_total = 1 })
    first:close()
    local objs = read_lines(path)
    eq(#objs, 1, "the first run replaced the stale content")
    eq(objs[1].run, 1, "first run")

    events.note(path, "watch_change", { files = { "lua/a.lua" }, count = 1 })
    local second = assert(events.open(path))
    second:emit("run_start", { files_total = 1 })
    second:close()
    objs = read_lines(path)
    eq(#objs, 3, "the second run appended")
    eq(objs[2].event, "watch_change", "the change event sits between the runs")
    eq(objs[2].run, 2, "tagged with the run it leads to")
    eq(objs[3].run, 2, "the second run is run 2 (the note was not counted as a run)")

    events.note(tmp .. "/never_opened.ndjson", "watch_change", {})
    eq(vim.uv.fs_stat(tmp .. "/never_opened.ndjson"), nil, "a note never creates a stream")

    local bad, err = events.open(tmp .. "/no/such/dir/run.ndjson")
    eq(bad, nil, "an unopenable file gives no stream")
    ok(tostring(err):find("--events", 1, true) ~= nil, "and says which option it was")
  end

  -- one real run end to end (through `cli.main`, real discovery and driver): run_start, one case per spec, run_done
  do
    events.reset()
    local cli = require("testing.cli")
    local state_dir = tmp .. "/state"
    local root = tmp .. "/proj"
    vim.fn.mkdir(root .. "/TESTS", "p")
    vim.fn.writefile(
      { "return function(H)", '  H.eq(1, 1, "a")', "end" },
      root .. "/TESTS/a_spec.lua"
    )
    vim.fn.writefile(
      { "return function(H)", '  H.eq(1, 2, "b")', "end" },
      root .. "/TESTS/b_spec.lua"
    )
    local out, err = {}, {}
    local function go(argv)
      out, err = {}, {}
      return cli.main(argv, {
        out = function(s)
          out[#out + 1] = s
        end,
        err = function(s)
          err[#err + 1] = s
        end,
        state_dir = state_dir,
        color = false,
      })
    end
    local stream = tmp .. "/e2e.ndjson"
    local code = go({ root, "--no-cache", "--events", stream })
    eq(code, 1, "the red project is exit 1 (the stream does not change it)")
    local objs = read_lines(stream)
    eq(objs[1].event, "run_start", "first event")
    eq(objs[1].files_total, 2, "two spec files")
    eq(objs[1].project, "proj", "the project name, never a path")
    local cases = {}
    for _, o in ipairs(objs) do
      if o.event == "case" then
        cases[o.file] = o.status
        ok(o.run == 1, "case events carry the run number")
      end
    end
    eq(
      cases,
      { ["TESTS/a_spec.lua"] = "pass", ["TESTS/b_spec.lua"] = "fail" },
      "a case event per spec"
    )
    eq(objs[#objs].event, "run_done", "last event")
    eq(objs[#objs].exit_code, 1, "exit code")
    eq(objs[#objs].verdict, "red", "verdict")
    eq(objs[#objs].summary.fail, 1, "summary")
    ok(not table.concat(objs[1]):find(root, 1, true), "no absolute path in the first event")

    -- a second run in the same process (what --watch does) appends as run 2
    go({ root, "--no-cache", "--events", stream })
    local again = read_lines(stream)
    ok(#again > #objs, "the second run appended")
    eq(again[#again].run, 2, "and is run 2")

    -- cached files announce their cases too
    local cache = tmp .. "/cache"
    local cstream = tmp .. "/cached.ndjson"
    go({ root, "--cache-dir", cache, "--cached" })
    go({ root, "--cache-dir", cache, "--cached", "--events", cstream })
    local hit = false
    for _, o in ipairs(read_lines(cstream)) do
      if o.event == "case" and o.cached then
        hit = true
      end
    end
    ok(hit, "a case that came from the result cache is announced with cached = true")

    -- --list runs nothing and opens no stream
    local lstream = tmp .. "/list.ndjson"
    go({ root, "--list", "--events", lstream })
    eq(vim.uv.fs_stat(lstream), nil, "--list writes no events")

    -- an unwritable target is a note, not a failure of the run
    code = go({ root, "--no-cache", "--events", tmp .. "/no/such/dir/e.ndjson" })
    eq(code, 1, "the verdict does not depend on the stream")
    ok(table.concat(err, "\n"):find("--events", 1, true) ~= nil, "the note names the option")
  end

  vim.fn.delete(tmp, "rf")
end
