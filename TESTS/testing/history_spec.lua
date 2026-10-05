-- TESTS/testing/history_spec.lua -- the run history behind --lf/--ff: where it lives, the cumulative
-- failed set, the bounds, and a history file that is untrusted input (corrupted, hostile, huge).

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
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
  local history = require("testing.history")
  local result = require("testing.core.result")

  local state = vim.fs.normalize(vim.fn.tempname())
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local opts = { state_dir = state }

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---An IR with the given cases: `{ id, status }` pairs (the file is the part before `::`).
  ---@param cases string[][]
  ---@param id? string
  ---@return Testing.Result
  local function ir(cases, id)
    local res = result.new({ root = root, id = id or "2026-01-01T00:00:00Z-0001", seed = 5 })
    for _, c in ipairs(cases) do
      local case = result.new_case({ file = c[1]:match("^(.-)::"), name = c[1]:match("::(.*)$") })
      case.id = c[1]
      case.status = c[2]
      result.add_case(res, case)
    end
    return result.finalize(res)
  end

  -- where it lives: <state>/testing/<name>-<12 hex>/runs.jsonl, derived from the project, stable
  local path = history.path(root, opts)
  ok(vim.startswith(path, state .. "/testing/"), "below the state directory: " .. path)
  ok(
    path:match("/testing/[%w_.%-]+%-%x%x%x%x%x%x%x%x%x%x%x%x/runs%.jsonl$") ~= nil,
    "name-hash/runs.jsonl: " .. path
  )
  eq(history.path(root, opts), path, "stable")
  local other = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(other, "p")
  ok(history.path(other, opts) ~= path, "another project, another directory")
  ok(
    vim.fs.normalize(history.dir(root)):find(vim.fs.normalize(vim.fn.stdpath("state")), 1, true)
      == 1,
    "default: stdpath('state')"
  )

  -- nothing yet
  local loaded = history.load(root, opts)
  eq(loaded.failed, {}, "no file, no failures")
  eq(loaded.records, 0, "no records")
  eq(loaded.notes, {}, "and no complaint about a file that never existed")

  -- record and read back; failed = the bad statuses only
  local a_one, a_two, b_file =
    "TESTS/a_spec.lua::d::one", "TESTS/a_spec.lua::d::two", "TESTS/b_spec.lua::b_spec.lua"
  local rok, rerr = history.record(
    root,
    ir({
      { a_one, "fail" },
      { a_two, "pass" },
      { b_file, "error" },
      { "TESTS/c_spec.lua::c_spec.lua", "skip" },
    }),
    {},
    opts
  )
  ok(rok, "record: " .. tostring(rerr))
  loaded = history.load(root, opts)
  eq(loaded.failed, { a_one, b_file }, "fail and error are remembered, pass and skip are not")
  eq(loaded.records, 1, "one record")
  local lines = vim.fn.readfile(path)
  eq(#lines, 1, "one line per run")
  local rec = vim.json.decode(lines[1])
  eq(rec.v, 1, "versioned")
  eq(rec.run, "2026-01-01T00:00:00Z-0001", "run id")
  eq(rec.seed, 5, "seed")
  eq(rec.summary.fail, 1, "summary")
  eq(type(rec.ts), "number", "timestamp")
  eq(
    vim.fn.glob(vim.fs.dirname(path) .. "/*.atomic-tmp*", false, true),
    {},
    "no temp file left behind (atomic write)"
  )

  -- cumulative: a case that ran and passed leaves; others stay although they did not run
  history.record(root, ir({ { a_one, "pass" } }, "r2"), {}, opts)
  eq(history.load(root, opts).failed, { b_file }, "a_one passed now; b_file did not run and stays")

  -- more failures are added, an unseen id is appended, nothing is duplicated
  history.record(
    root,
    ir({ { "TESTS/d_spec.lua::d_spec.lua", "timeout" }, { b_file, "fail" } }, "r3"),
    {},
    opts
  )
  eq(
    history.load(root, opts).failed,
    { "TESTS/d_spec.lua::d_spec.lua", b_file },
    "timeout counts, no duplicates"
  )
  history.record(
    root,
    ir({ { "TESTS/e_spec.lua::e::x", "xpass" }, { "TESTS/f_spec.lua::f", "crash" } }, "r3b"),
    {},
    opts
  )
  eq(#history.load(root, opts).failed, 4, "xpass and crash are failures as well")

  -- a file that ran completely forgets the ids it no longer produces; one that did not run keeps them
  history.record(
    root,
    ir({ { "TESTS/a_spec.lua::d::other", "pass" } }, "r4"),
    { ran_files = { ["TESTS/e_spec.lua"] = true } },
    opts
  )
  local failed = history.load(root, opts).failed
  ok(
    not vim.tbl_contains(failed, "TESTS/e_spec.lua::e::x"),
    "e_spec ran completely and no longer produces the id: forgotten"
  )
  ok(vim.tbl_contains(failed, b_file), "b_spec did not run: kept")

  -- files that no longer exist are dropped
  history.record(
    root,
    ir({ { "TESTS/a_spec.lua::d::other", "pass" } }, "r5"),
    { known_files = { ["TESTS/b_spec.lua"] = true } },
    opts
  )
  eq(
    history.load(root, opts).failed,
    { b_file },
    "ids of files that are not known any more are dropped"
  )

  -- the file is bounded: runs and bytes
  for i = 1, history.MAX_RUNS + 6 do
    history.record(root, ir({ { b_file, "fail" } }, "run" .. i), {}, opts)
  end
  eq(#vim.fn.readfile(path), history.MAX_RUNS, "at most MAX_RUNS lines")
  eq(history.load(root, opts).records, history.MAX_RUNS, "and all of them read back")
  local many = {}
  for i = 1, history.MAX_FAILED + 50 do
    many[#many + 1] = { ("TESTS/g_spec.lua::case %d"):format(i), "fail" }
  end
  history.record(root, ir(many, "big"), {}, opts)
  local big = history.load(root, opts)
  ok(#big.failed <= history.MAX_FAILED, "the failed list is capped: " .. #big.failed)
  ok(
    vim.tbl_contains(big.failed, ("TESTS/g_spec.lua::case %d"):format(history.MAX_FAILED + 50)),
    "the newest failures are the ones kept"
  )
  ok(
    (vim.uv.fs_stat(path) or { size = math.huge }).size <= history.MAX_BYTES,
    "the file stays within MAX_BYTES"
  )
  history.record(
    root,
    ir({ { "TESTS/h_spec.lua::" .. ("x"):rep(history.MAX_ID_BYTES + 10), "fail" } }, "long"),
    {},
    opts
  )
  for _, id in ipairs(history.load(root, opts).failed) do
    ok(#id <= history.MAX_ID_BYTES, "no id above the cap is stored")
  end

  -- an untrusted file: garbage lines are dropped, the valid ones survive, nothing raises
  local good = vim.json.encode({
    v = 1,
    run = "good",
    ts = 1700000000,
    failed = { a_one },
    summary = { fail = 1 },
  })
  write(path, table.concat({
    "not json at all",
    "{broken",
    "[1,2,3]",
    '"a string"',
    "null",
    good,
    vim.json.encode({ v = 2, run = "future", ts = 1, failed = { "x::y" } }),
    vim.json.encode({ v = 1, run = "badids", ts = 1, failed = { 7, { "x" }, true } }),
    vim.json.encode({ v = 1, run = "badts", ts = "yesterday", failed = {} }),
    vim.json.encode({ v = 1, run = "nofailed", ts = 1 }),
    "\0\0\0 binary \255\254",
  }, "\n") .. "\n")
  local ok_load, hist = pcall(history.load, root, opts)
  ok(ok_load, "load never raises on a hostile file")
  eq(hist.failed, { a_one }, "the last VALID record decides")
  eq(hist.records, 1, "exactly one valid record in there")
  has(table.concat(hist.notes, "\n"), "unusable line(s) ignored", "the dropped lines are announced")
  has(table.concat(hist.notes, "\n"), "10 unusable", "and counted")

  -- a file with nothing usable: empty, a note, no raise
  write(path, "garbage\nmore garbage\n")
  hist = history.load(root, opts)
  eq(hist.failed, {}, "nothing valid: nothing remembered")
  eq(hist.records, 0, "no record")
  has(table.concat(hist.notes, "\n"), "2 unusable", "the note says how many")
  -- and the next record starts a clean file
  ok(
    history.record(root, ir({ { a_one, "fail" } }, "fresh"), {}, opts),
    "record over a corrupted file"
  )
  eq(history.load(root, opts).failed, { a_one }, "the corrupted lines are gone after a rewrite")
  eq(#vim.fn.readfile(path), 1, "one clean line")

  -- a huge file is not even read
  write(path, ("x"):rep(history.MAX_BYTES * 2 + 1))
  hist = history.load(root, opts)
  eq(hist.failed, {}, "a file above the size cap is ignored")
  has(table.concat(hist.notes, "\n"), "larger than", "and says why")

  -- a directory where the file should be: a note, no raise, the record fails visibly
  vim.fn.delete(path)
  vim.fn.mkdir(path, "p")
  hist = history.load(root, opts)
  eq(hist.failed, {}, "a directory is ignored")
  has(table.concat(hist.notes, "\n"), "not a regular file", "with a note")
  local wrote, werr = history.record(root, ir({ { a_one, "fail" } }, "blocked"), {}, opts)
  eq(wrote, false, "a record that cannot be written says so")
  ok(type(werr) == "string" and #werr > 0, "with a reason: " .. tostring(werr))
  vim.fn.delete(path, "rf")

  -- validate: the single-line rules
  eq(select(1, history.validate(7)), nil, "not a table")
  eq(
    select(2, history.validate({ v = 1, run = "x", ts = 1, failed = "no" })),
    "bad failed list",
    "failed must be a list"
  )
  local v = assert(history.validate({
    v = 1,
    run = "x",
    ts = 1,
    failed = { "a::b", "a::b" },
    seed = -3,
    summary = { pass = 1, [5] = 2, evil = "x" },
  }))
  eq(v.failed, { "a::b" }, "duplicates collapse")
  eq(v.seed, nil, "a bad seed is dropped, not trusted")
  eq(v.summary, { pass = 1 }, "only name = number pairs of the summary survive")

  vim.fn.delete(state, "rf")
  vim.fn.delete(root, "rf")
  vim.fn.delete(other, "rf")
end
