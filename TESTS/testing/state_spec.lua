-- TESTS/testing/state_spec.lua -- testing.state: the last result per case (what an explorer, a hover, a quickfix
-- list and a statusline read): the round trip, the merge over partial runs, staleness against the file system,
-- `prev.json` for "newly red", and a result file that is untrusted input (corrupt, hostile, huge).

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local state = require("testing.state")
  local result = require("testing.core.result")

  local sdir = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/TESTS", "p")
  local opts = { state_dir = sdir }

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local spec_a, spec_b = "TESTS/a_spec.lua", "TESTS/b_spec.lua"
  write(root .. "/" .. spec_a, "return function() end\n")
  write(root .. "/" .. spec_b, "return function() end\n")

  ---An IR with cases `{ file, name, status, line?, message? }`.
  ---@param cases table[]
  ---@param id? string
  ---@return Testing.Result
  local function ir(cases, id)
    local res = result.new({ root = root, id = id or "2026-01-01T00:00:00Z-0001" })
    for _, c in ipairs(cases) do
      local case = result.new_case({
        file = c[1],
        name = c[2],
        describe = c.describe,
        line = c.line,
      })
      case.status = c[3]
      case.duration_ms = c.ms or 1
      if c.message then
        case.assertions = {
          { ok = false, kind = "eq", msg = c.message, expected = c.expected, actual = c.actual },
        }
      end
      result.add_case(res, case)
    end
    return result.finalize(res)
  end

  local function files_of(...)
    local set = {}
    for _, f in ipairs({ ... }) do
      set[f] = true
    end
    return set
  end

  -- IR fields: describe and name ------------------------------------------------
  do
    local c =
      result.new_case({ file = spec_a, describe = { "outer", "inner" }, name = "works", line = 7 })
    eq(c.describe, { "outer", "inner" }, "IR: describe is the list of titles")
    eq(c.name, "works", "IR: name")
    eq(
      result.new_case({ file = spec_a, describe = "one", name = "x" }).describe,
      { "one" },
      "IR: a string describe is one title"
    )
    eq(result.new_case({ file = spec_a, name = "x" }).describe, nil, "IR: absent without describe")
    local res = ir({ { spec_a, "works", "pass", describe = { "outer" } } })
    res.cases[1].assertions = { { ok = true, kind = "ok" } }
    -- the validator refuses a real home path in the root (the temp directory of a Windows runner is one)
    res.run.root = "<REPO>"
    ok(result.validate(res), "IR: a result with the new fields validates")
    res.cases[1].describe = "not a list"
    local valid, problems = result.validate(res)
    ok(
      not valid and table.concat(problems, "\n"):find("describe", 1, true),
      "IR: a describe that is no list is a problem"
    )
    res.cases[1].describe = nil
    res.cases[1].name = ""
    valid = result.validate(res)
    ok(not valid, "IR: an empty name is a problem")
  end

  -- round trip -----------------------------------------------------------------
  local first = ir({
    { spec_a, "alpha", "pass", line = 3, ms = 2 },
    {
      spec_a,
      "beta",
      "fail",
      line = 9,
      ms = 5,
      message = "values differ\nsecond line",
      expected = "1",
      actual = "2",
      describe = { "group" },
    },
    { spec_b, "gamma", "skip", line = 4 },
  }, "run-1")
  local rok, rerr, st = state.record(root, first, {
    ran_files = files_of(spec_a, spec_b),
    known_files = files_of(spec_a, spec_b),
    time = 1700000000,
  }, opts)
  ok(rok, "record: " .. tostring(rerr))
  ok(vim.uv.fs_stat(state.path(root, opts)), "last.json is written")
  eq(st.run, "run-1", "record returns the state")

  local loaded = state.load(root, opts)
  eq(loaded.run, "run-1", "load: the run id")
  eq(#loaded.cases, 3, "load: every case")
  eq(loaded.notes, {}, "load: nothing to note")
  local snap = state.snapshot(loaded)
  eq(snap.summary.pass, 1, "snapshot: pass")
  eq(snap.summary.fail, 1, "snapshot: fail")
  eq(snap.summary.skip, 1, "snapshot: skip")
  eq(snap.failed, 1, "snapshot: red cases")
  eq(snap.files, 2, "snapshot: files")
  eq(snap.partial, false, "snapshot: a full run")
  eq(snap.stale, 0, "snapshot: nothing is stale right after the run")

  local beta = state.case(loaded, spec_a .. "::group::beta")
  ok(beta, "case: by id")
  eq(beta.status, "fail", "case: status")
  eq(beta.message, "values differ", "case: the first line of the first failing assertion")
  eq(beta.expected, "1", "case: expected")
  eq(beta.actual, "2", "case: actual")
  eq(beta.describe, { "group" }, "case: describe survives the file")
  eq(beta.name, "beta", "case: name survives the file")
  eq(state.case_at(loaded, spec_a, 9).id, beta.id, "case_at: on the line")
  eq(state.case_at(loaded, spec_a, 12).id, beta.id, "case_at: below a case belongs to it")
  eq(
    state.case_at(loaded, spec_a, 5).id,
    spec_a .. "::alpha",
    "case_at: between two cases belongs to the first"
  )
  eq(state.case_at(loaded, spec_a, 2), nil, "case_at: above every case")
  eq(
    state.case_at(loaded, spec_a, 12, { exact = true }),
    nil,
    "case_at: exact wants the definition line"
  )
  eq(
    state.case_at(loaded, "TESTS\\a_spec.lua", 9).id,
    beta.id,
    "case_at: a Windows path is normalised"
  )
  eq(#state.failures(loaded), 1, "failures: one")
  eq(state.failures(loaded)[1].id, beta.id, "failures: the red case")

  local fsum = state.file_summary(loaded, spec_a)
  eq(fsum.total, 2, "file_summary: cases")
  eq(fsum.counts, { pass = 1, fail = 1 }, "file_summary: counts")
  eq(fsum.failed, { beta.id }, "file_summary: red ids")
  eq(fsum.ts, 1700000000, "file_summary: when it ran")
  eq(fsum.stale, false, "file_summary: current")
  eq(state.file_summary(loaded, "TESTS/none_spec.lua"), nil, "file_summary: an unknown file")

  -- staleness ------------------------------------------------------------------
  local stale, why = state.is_stale(loaded, spec_a)
  ok(stale == false and why == nil, "is_stale: untouched since the run")
  write(root .. "/" .. spec_a, "return function() end -- edited, longer\n")
  stale, why = state.is_stale(loaded, spec_a)
  ok(stale == true and why == "changed", "is_stale: a changed file is stale (size)")
  eq(state.file_summary(loaded, spec_a).stale, true, "file_summary says so too")
  eq(state.snapshot(loaded).stale, 1, "snapshot counts it")
  -- same size, other time
  write(root .. "/" .. spec_b, "return function() end\n")
  vim.uv.fs_utime(root .. "/" .. spec_b, 1000000000, 1000000000)
  stale, why = state.is_stale(loaded, spec_b)
  ok(stale == true and why == "changed", "is_stale: the same size with another mtime is stale")
  vim.uv.fs_unlink(root .. "/" .. spec_b)
  stale, why = state.is_stale(loaded, spec_b)
  ok(stale == true and why == "gone", "is_stale: a deleted file is stale")
  stale, why = state.is_stale(loaded, "TESTS/never_spec.lua")
  ok(
    stale == true and why == "no result",
    "is_stale: a file without a record has no current result"
  )

  -- the mtime compares equal after a trip through the file (a decimal string, not a double)
  write(root .. "/" .. spec_b, "return function() end\n")
  local recorded = state.record(root, ir({ { spec_b, "gamma", "pass" } }, "run-2"), {
    ran_files = files_of(spec_b),
    known_files = files_of(spec_a, spec_b),
    partial = true,
  }, opts)
  ok(recorded, "record: a partial run")
  local reread = state.load(root, opts)
  eq(
    state.is_stale(reread, spec_b),
    false,
    "mtime_ns survives JSON: the file is not stale after a reload"
  )
  ok(type(reread.files[spec_b].mtime_ns) == "string", "mtime_ns is a string")

  -- merge over partial runs ------------------------------------------------------
  eq(reread.run, "run-2", "merge: the latest run")
  eq(reread.partial, true, "merge: marked partial")
  eq(
    state.case(reread, spec_a .. "::group::beta").status,
    "fail",
    "merge: a file that did not run keeps its cases"
  )
  eq(state.case(reread, spec_b .. "::gamma").status, "pass", "merge: the case that ran is replaced")
  eq(state.case(reread, spec_a .. "::alpha").status, "pass", "merge: the other cases stay")
  eq(#reread.cases, 3, "merge: no case is lost or duplicated")

  -- a file that ran completely forgets the ids it no longer produces
  state.record(root, ir({ { spec_a, "alpha", "pass" } }, "run-3"), {
    ran_files = files_of(spec_a),
    known_files = files_of(spec_a, spec_b),
  }, opts)
  reread = state.load(root, opts)
  eq(
    state.case(reread, spec_a .. "::group::beta"),
    nil,
    "merge: a case the full file run no longer produces is gone"
  )
  ok(state.case(reread, spec_b .. "::gamma"), "merge: the other file is untouched")
  eq(reread.partial, false, "merge: a full run clears partial")

  -- a case restriction does not forget the rest of the file
  state.record(root, ir({ { spec_a, "delta", "fail", message = "x" } }, "run-4"), {
    ran_files = {},
    known_files = files_of(spec_a, spec_b),
    partial = true,
  }, opts)
  reread = state.load(root, opts)
  ok(state.case(reread, spec_a .. "::alpha"), "merge: --filter keeps the other cases of the file")
  ok(state.case(reread, spec_a .. "::delta"), "merge: and adds the one that ran")

  -- a file that no longer exists is dropped
  state.record(root, ir({ { spec_a, "alpha", "pass" } }, "run-5"), {
    ran_files = files_of(spec_a),
    known_files = files_of(spec_a),
  }, opts)
  reread = state.load(root, opts)
  eq(state.case(reread, spec_b .. "::gamma"), nil, "merge: the cases of a deleted file are dropped")
  eq(reread.files[spec_b], nil, "merge: and its file record")

  -- an aborted run: the cases that finished are recorded, the rest stays ----------
  state.record(root, ir({ { spec_a, "alpha", "fail", message = "boom" } }, "run-6"), {
    ran_files = {},
    known_files = files_of(spec_a),
    partial = true,
  }, opts)
  reread = state.load(root, opts)
  eq(state.case(reread, spec_a .. "::alpha").status, "fail", "abort: the finished case is recorded")
  eq(reread.partial, true, "abort: the state says the run was partial")

  -- prev.json: newly red -----------------------------------------------------------
  local prev = state.load_prev(root, opts)
  ok(prev, "prev.json exists after a second record")
  eq(prev.run, "run-5", "prev: the run before the last one")
  local newly = state.newly_failed(reread, prev)
  ok(newly[spec_a .. "::alpha"], "newly red: green before, red now")
  eq(state.newly_failed(reread, reread), {}, "newly red: nothing against itself")
  eq(
    state.newly_failed(reread, nil)[spec_a .. "::alpha"],
    true,
    "newly red: without a previous result every red case is new"
  )

  -- subscribe ----------------------------------------------------------------------
  do
    local calls = {}
    local live = state.load(root, opts)
    local off = state.subscribe(live, function(s, event)
      calls[#calls + 1] = event .. ":" .. #s.cases
    end)
    state.subscribe(live, function()
      error("a broken subscriber")
    end)
    state.apply(
      live,
      ir({ { spec_a, "alpha", "pass" } }, "run-7"),
      { ran_files = files_of(spec_a) }
    )
    eq(calls, { "apply:1" }, "subscribe: called on apply, a broken subscriber hurts nobody")
    off()
    state.apply(
      live,
      ir({ { spec_a, "alpha", "pass" } }, "run-8"),
      { ran_files = files_of(spec_a) }
    )
    eq(#calls, 1, "subscribe: unsubscribed")
  end

  -- hostile result files -------------------------------------------------------------
  local hdir = vim.fs.normalize(vim.fn.tempname())
  local hopts = { state_dir = hdir }
  local hpath = state.path(root, hopts)
  local function load_with(text)
    write(hpath, text)
    return state.load(root, hopts)
  end

  local bad = load_with("{ this is not json")
  eq(#bad.cases, 0, "hostile: not JSON -> empty")
  has(bad.notes[1], "not valid JSON", "hostile: and says so")

  bad = load_with("[1,2,3]")
  eq(#bad.cases, 0, "hostile: an array is no result file")
  ok(#bad.notes == 1, "hostile: noted")

  bad = load_with('{"v":99,"cases":[]}')
  eq(#bad.cases, 0, "hostile: an unknown version is ignored")
  has(bad.notes[1], "unknown version", "hostile: named")

  bad = load_with('{"v":1,"cases":"nope"}')
  eq(#bad.cases, 0, "hostile: cases of the wrong type")

  write(hpath, string.rep("x", state.MAX_BYTES + 1))
  bad = state.load(root, hopts)
  eq(#bad.cases, 0, "hostile: a file over the cap is not read")
  has(bad.notes[1], "larger than", "hostile: and says so")

  vim.fn.delete(hpath)
  vim.fn.mkdir(hpath, "p")
  bad = state.load(root, hopts)
  eq(#bad.cases, 0, "hostile: a directory in place of the file")
  has(bad.notes[1], "not a regular file", "hostile: named")
  vim.fn.delete(hpath, "rf")

  -- a file name that points out of the project is never kept (it would be stat'ed by is_stale / snapshot)
  bad = load_with(vim.json.encode({
    v = 1,
    cases = {
      { id = "../x::a", file = "../x", status = "pass", duration_ms = 1 },
      { id = "/etc/passwd::a", file = "/etc/passwd", status = "pass", duration_ms = 1 },
      { id = "C:/w::a", file = "C:/w", status = "pass", duration_ms = 1 },
      { id = "TESTS/a/../../b::a", file = "TESTS/a/../../b", status = "pass", duration_ms = 1 },
      { id = "TESTS/ok_spec.lua::a", file = "TESTS/ok_spec.lua", status = "pass", duration_ms = 1 },
    },
    files = {
      ["../x"] = { mtime_ns = "1", size = 1, run = "r", ts = 1 },
      ["/etc/passwd"] = { mtime_ns = "1", size = 1, run = "r", ts = 1 },
      ["TESTS/ok_spec.lua"] = { mtime_ns = "1", size = 1, run = "r", ts = 1 },
    },
  }))
  eq(#bad.cases, 1, "hostile: only the case inside the project stays")
  eq(bad.cases[1].file, "TESTS/ok_spec.lua", "hostile: the one that stays")
  ok(
    bad.files["../x"] == nil and bad.files["/etc/passwd"] == nil,
    "hostile: no record for a path outside"
  )
  ok(bad.files["TESTS/ok_spec.lua"] ~= nil, "hostile: the record inside stays")

  local esc = "\27[31mred\27[0m\0nul"
  local mixed = vim.json.encode({
    v = 1,
    run = "r",
    ts = 5,
    files = {},
    cases = {
      {
        id = "TESTS/x_spec.lua::ok",
        file = "TESTS/x_spec.lua",
        status = "fail",
        duration_ms = 1,
        message = esc,
        name = esc,
        describe = { esc },
      },
      {
        id = "TESTS/x_spec.lua::bad status",
        file = "TESTS/x_spec.lua",
        status = "weird",
        duration_ms = 1,
      },
      {
        id = "TESTS/x_spec.lua::bad duration",
        file = "TESTS/x_spec.lua",
        status = "pass",
        duration_ms = -1,
      },
      { id = "", file = "TESTS/x_spec.lua", status = "pass", duration_ms = 1 },
      { id = "TESTS/x_spec.lua::ok", file = "TESTS/x_spec.lua", status = "pass", duration_ms = 1 },
      "a string",
      {
        id = ("i"):rep(state.MAX_ID_BYTES + 1),
        file = "TESTS/x_spec.lua",
        status = "pass",
        duration_ms = 1,
      },
    },
  })
  local m = load_with(mixed)
  eq(#m.cases, 1, "hostile: only the one valid, first case of that id survives")
  has(m.notes[1], "6 unusable case(s) ignored", "hostile: the rest is counted")
  local hc = m.cases[1]
  ok(not hc.message:find("[%c]"), "hostile: no control character in a message")
  ok(not hc.name:find("[%c]"), "hostile: nor in a name")
  ok(not hc.describe[1]:find("[%c]"), "hostile: nor in a describe title")
  has(hc.message, "red", "hostile: the readable part stays")

  local long = vim.json.encode({
    v = 1,
    cases = {
      {
        id = "TESTS/x_spec.lua::long",
        file = "TESTS/x_spec.lua",
        status = "fail",
        duration_ms = 1,
        message = ("m"):rep(state.MAX_TEXT * 3),
        expected = ("e"):rep(state.MAX_TEXT * 3),
      },
    },
  })
  m = load_with(long)
  ok(
    #m.cases[1].message <= state.MAX_TEXT and #m.cases[1].expected <= state.MAX_TEXT,
    "hostile: texts are cut"
  )

  local badfiles = vim.json.encode({
    v = 1,
    cases = {},
    files = {
      ["TESTS/a_spec.lua"] = { mtime_ns = "123", size = 4, run = "r", ts = 1 },
      ["TESTS/b_spec.lua"] = { mtime_ns = 123, size = 4, run = "r" },
      ["TESTS/c_spec.lua"] = { mtime_ns = "12x", size = 4, run = "r" },
      ["TESTS/d_spec.lua"] = "string",
    },
  })
  m = load_with(badfiles)
  ok(m.files["TESTS/a_spec.lua"], "hostile: a valid file record stays")
  eq(
    m.files["TESTS/b_spec.lua"],
    nil,
    "hostile: a numeric mtime_ns is refused (it would not round trip)"
  )
  eq(m.files["TESTS/c_spec.lua"], nil, "hostile: a non-digit mtime_ns")
  eq(m.files["TESTS/d_spec.lua"], nil, "hostile: a record of the wrong type")
  has(m.notes[1], "3 unusable file record(s) ignored", "hostile: counted")

  -- a record that cannot be written is reported, never raised ------------------------
  local blocker = vim.fs.normalize(vim.fn.tempname())
  write(blocker, "a file where the state directory should be")
  local wok, werr = state.record(
    root,
    ir({ { spec_a, "alpha", "pass" } }, "run-9"),
    {},
    { state_dir = blocker }
  )
  ok(wok == false and werr, "record: a state directory that is a file is reported, not raised")
end
