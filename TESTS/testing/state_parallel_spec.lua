-- TESTS/testing/state_parallel_spec.lua -- the state files beside runs.jsonl (order.json, timings.json,
-- durations.json, last_green.json, runs.jsonl) are read-modify-write: two runs of one project at the same time
-- must not drop each other's entries. The lock itself (exclusive, bounded wait, stale takeover) is checked in
-- this process; the end-to-end claim is checked with real parallel editors that all write at once.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local uv = vim.uv
  local lock = require("testing.statelock")
  local timings = require("testing.run.timings")
  local order = require("testing.run.order")
  local shard = require("testing.run.shard")
  local green = require("testing.run.green")
  local history = require("testing.history")

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local root = vim.fs.dirname(vim.fs.dirname(dir))
  local state = vim.fn.tempname()
  vim.fn.mkdir(state, "p")
  local opts = { state_dir = state }

  -- a Result with one finished case per file
  local function result(files, id)
    local cases = {}
    for _, f in ipairs(files) do
      cases[#cases + 1] = { file = f, duration_ms = 5, status = "pass", id = f .. "::case" }
    end
    return { cases = cases, summary = { pass = #cases }, run = { id = id or "r1" } }
  end

  -- ------------------------------------------------------------------ the lock
  local target = state .. "/lock-target.json"
  local ran = false
  local locked, inner_locked, note = lock.with(target, function()
    -- a second writer cannot get in while the first holds the lock, and gives up with a note
    return lock.with(target, function()
      ran = true
    end, { timeout_ms = 120, poll_ms = 5 })
  end)
  ok(locked, "the first writer gets the lock")
  ok(inner_locked == false, "the second one does not while the first holds it")
  ok(not ran, "and its function did not run")
  ok(
    type(note) == "string" and note:find("locked by another run", 1, true) ~= nil,
    "it says why: " .. tostring(note)
  )
  eq(uv.fs_stat(target .. ".lock"), nil, "the lock is gone afterwards")

  local _, a, b, c = lock.with(target, function()
    return "x", "y", "z"
  end)
  eq({ a, b, c }, { "x", "y", "z" }, "the values of the function are handed through")

  -- a function that raises releases the lock and the error reaches the caller
  local pok, perr = pcall(lock.with, target, function()
    error("boom", 0)
  end)
  ok(not pok and perr == "boom", "an error in the function is rethrown")
  eq(uv.fs_stat(target .. ".lock"), nil, "and the lock is released")

  -- a lock a crashed run left behind is taken over; a fresh one is respected
  local fd = assert(uv.fs_open(target .. ".lock", "w", 420))
  uv.fs_write(fd, "99999 1\n", 0)
  uv.fs_close(fd)
  uv.fs_utime(target .. ".lock", os.time() - 3600, os.time() - 3600)
  local took = lock.with(target, function()
    return true
  end, { timeout_ms = 200, stale_ms = 10000 })
  ok(took, "a lock older than stale_ms is taken over")
  fd = assert(uv.fs_open(target .. ".lock", "w", 420))
  uv.fs_close(fd)
  local respected = lock.with(target, function()
    return true
  end, { timeout_ms = 100, stale_ms = 10000, poll_ms = 5 })
  ok(respected == false, "a fresh lock of somebody else is respected")
  uv.fs_unlink(target .. ".lock")

  -- A directory that cannot be written is no lock held by somebody: the refusal (EACCES on POSIX, EPERM from libuv
  -- on Windows) is reported as it is after a short grace, not as "locked by another run" after the full timeout
  -- (up to 3 s per state file, five files per run). The failure is simulated at the open of the lock file, because a
  -- directory without write permission cannot be made the same way on every platform.
  do
    local real_open = uv.fs_open
    local refuse
    uv.fs_open = function(p, ...)
      if refuse and type(p) == "string" and p:find(".lock", 1, true) then
        return nil, refuse
      end
      return real_open(p, ...)
    end
    local guarded_ok, guarded_err = pcall(function()
      for _, why in ipairs({ "EACCES: permission denied", "EPERM: operation not permitted" }) do
        refuse = why
        local t0 = uv.hrtime()
        local got, msg = lock.with(target, function()
          ran = true
        end, { grace_ms = 40, timeout_ms = 2500, poll_ms = 5 })
        local ms = (uv.hrtime() - t0) / 1e6
        ok(got == false and not ran, why .. ": the function did not run")
        ok(
          type(msg) == "string" and msg:find("cannot lock", 1, true) and msg:find(why, 1, true),
          why .. ": the note names the error, not another run: " .. tostring(msg)
        )
        ok(
          ms < 1500,
          ("%s: reported after the grace (%.0f ms), not after the timeout"):format(why, ms)
        )
      end

      -- a lock file that is there while the open is refused IS a lock somebody holds: it is waited for
      refuse = "EPERM: operation not permitted"
      local held = io.open(target .. ".lock", "wb")
      assert(held):close()
      local got, msg = lock.with(target, function()
        ran = true
      end, { grace_ms = 20, timeout_ms = 150, poll_ms = 5 })
      ok(
        got == false and tostring(msg):find("locked by another run", 1, true) ~= nil,
        "a lock file in sight: the usual note, " .. tostring(msg)
      )
      uv.fs_unlink(target .. ".lock")

      -- a refusal that goes away within the grace (a delete that was still pending) takes the lock
      local refusals = 3
      uv.fs_open = function(p, ...)
        if refusals > 0 and type(p) == "string" and p:find(".lock", 1, true) then
          refusals = refusals - 1
          return nil, "EPERM: operation not permitted"
        end
        return real_open(p, ...)
      end
      local took_it = lock.with(target, function()
        return true
      end, { grace_ms = 500, timeout_ms = 2500, poll_ms = 5 })
      ok(took_it, "a refusal that ends within the grace is waited out")
    end)
    uv.fs_open = real_open
    ok(guarded_ok, tostring(guarded_err))
    eq(uv.fs_stat(target .. ".lock"), nil, "no lock is left behind")
  end

  -- a writer that cannot get the lock reports a note and leaves the file alone
  local tpath = timings.path(root, opts)
  vim.fn.mkdir(vim.fs.dirname(tpath), "p")
  fd = assert(uv.fs_open(tpath .. ".lock", "w", 420))
  uv.fs_close(fd)
  local wrote, werr = timings.record(root, {}, { ["held_spec.lua"] = 1 }, opts)
  ok(
    wrote == false and tostring(werr):find("locked by another run", 1, true) ~= nil,
    "held: a note, not a write"
  )
  eq(uv.fs_stat(tpath), nil, "held: nothing was written")
  uv.fs_unlink(tpath .. ".lock")

  -- the run says so on stderr when it could not update a state file: durations.json used to be the silent one
  -- (`record_durations` answers `false, note` instead of raising, and the caller only looked for a raise)
  do
    local proj = vim.fs.normalize(vim.fn.tempname()) .. "-durnote"
    vim.fn.mkdir(proj .. "/TESTS", "p")
    vim.fn.writefile(
      { "return function(H)", '  H.ok(true, "x")', "end" },
      proj .. "/TESTS/x_spec.lua"
    )
    local pstate = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(pstate, "p")
    local dpath = shard.durations_path(proj, { state_dir = pstate })
    vim.fn.mkdir(vim.fs.dirname(dpath), "p")
    vim.fn.writefile({}, dpath .. ".lock")
    local errs = {}
    local before = lock.TIMEOUT_MS
    lock.TIMEOUT_MS = 100
    local cli_ok, code = pcall(require("testing.cli").main, { proj }, {
      out = function() end,
      err = function(s)
        errs[#errs + 1] = s
      end,
      state_dir = pstate,
      cache_dir = pstate .. "/cache",
      color = false,
    })
    lock.TIMEOUT_MS = before
    ok(cli_ok and code == 0, "the run itself is green: " .. tostring(code))
    local said = table.concat(errs, "\n")
    ok(
      said:find("durations not updated: durations.json is locked by another run", 1, true),
      "a durations.json that is locked is a note: " .. said
    )
    eq(uv.fs_stat(dpath), nil, "and nothing was written")
    vim.fn.delete(proj, "rf")
    vim.fn.delete(pstate, "rf")
  end

  -- ------------------------------------------------------------------ one process, stale reads
  -- timings: the caller read the history, a second run wrote, the first one records: both samples stay
  local seen = timings.read(tpath) -- empty: nothing recorded yet
  ok(timings.record(root, {}, { ["a_spec.lua"] = 10 }, opts), "the second run records a_spec")
  ok(
    timings.record(root, seen, { ["b_spec.lua"] = 20 }, opts),
    "the first run records with a stale history"
  )
  local files = timings.read(tpath)
  eq(files["a_spec.lua"], { 10 }, "timings: the entry of the run that wrote in between survived")
  eq(files["b_spec.lua"], { 20 }, "timings: and the entry of the stale writer is there")

  -- durations.json: the same with a stale `previous`
  local dres = result({ "a_spec.lua" })
  ok(shard.record_durations(root, dres, nil, opts), "durations a")
  ok(
    shard.record_durations(root, result({ "b_spec.lua" }), { previous = {} }, opts),
    "durations b with a stale `previous`"
  )
  local durations = shard.read_durations(shard.durations_path(root, opts))
  ok(durations["a_spec.lua"] and durations["b_spec.lua"], "durations: both files are remembered")

  -- order.json: two results recorded one after the other keep both files
  ok(
    order.record_state(root, result({ "a_spec.lua" }), { state_dir = state, time = 100 }),
    "order a"
  )
  ok(
    order.record_state(root, result({ "b_spec.lua" }), { state_dir = state, time = 200 }),
    "order b"
  )
  local ofiles = order.load_state(root, opts)
  ok(ofiles["a_spec.lua"] and ofiles["b_spec.lua"], "order: both files are remembered")

  -- last_green.json: the later green run stays, an earlier one that finishes last does not replace it
  ok(
    green.record(root, { run = { id = "later" } }, { state_dir = state, time = 20 }),
    "green: later run"
  )
  ok(
    green.record(root, { run = { id = "earlier" } }, { state_dir = state, time = 10 }),
    "green: earlier run"
  )
  local rec = green.load(root, opts)
  eq(rec and rec.run, "later", "green: the record of the later run stays")

  -- a record dated in the future (a clock that jumped ahead, a planted file) does not pin the file: the next green
  -- run of the real clock replaces it (a state directory of its own: the workers below stamp small times)
  local fstate = vim.fn.tempname()
  vim.fn.mkdir(fstate, "p")
  local fopts = { state_dir = fstate }
  ok(
    green.record(root, { run = { id = "wrong-clock" } }, { state_dir = fstate, time = 4000000000 }),
    "green: a run with a clock far ahead"
  )
  eq(
    (green.load(root, fopts) or {}).run,
    "wrong-clock",
    "green: it is the record (nothing later exists)"
  )
  ok(green.record(root, { run = { id = "now" } }, { state_dir = fstate }), "green: a run of today")
  eq((green.load(root, fopts) or {}).run, "now", "green: the future-dated record is replaced")
  vim.fn.delete(fstate, "rf")

  -- ------------------------------------------------------------------ real parallel editors
  local workers, rounds = 4, 6
  local go = state .. "/go"
  local libfile = vim.api.nvim_get_runtime_file("lua/lib/nvim/json/init.lua", false)[1]
    or package.searchpath("lib.nvim.json", package.path)
  ok(libfile ~= nil, "lib.nvim is findable")
  local lib_root = (libfile or ""):gsub("\\", "/"):gsub("/lua/lib/nvim/json/init%.lua$", "")
  local procs = {}
  for w = 1, workers do
    procs[w] = vim.system({
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      dir .. "/fixtures/state_parallel_worker.lua",
      tostring(w),
      state,
      go,
      root,
      lib_root,
      tostring(rounds),
    }, { text = true })
  end
  vim.fn.writefile({ "go" }, go)
  local expected = {}
  for w = 1, workers do
    local res = procs[w]:wait(90000)
    ok(res.code == 0, ("worker %d ran: %s"):format(w, tostring(res.stderr)))
    eq(res.stdout, "", ("worker %d: no write failed"):format(w))
    for k = 1, rounds do
      expected[#expected + 1] = ("w%d_%d_spec.lua"):format(w, k)
    end
  end
  table.sort(expected)

  ---The expected files that the state file holds, sorted.
  ---@param held table<string, any>
  ---@return string[]
  local function present(held)
    local out = {}
    for _, f in ipairs(expected) do
      if held[f] then
        out[#out + 1] = f
      end
    end
    return out
  end
  eq(present(timings.read(tpath)), expected, "timings.json: every sample of every worker survived")
  eq(
    present(order.load_state(root, opts)),
    expected,
    "order.json: every file of every worker survived"
  )
  eq(
    present(shard.read_durations(shard.durations_path(root, opts))),
    expected,
    "durations.json: every file of every worker survived"
  )

  -- runs.jsonl keeps the last MAX_RUNS lines, the last one knows every failure of every worker
  local records = history.read_records(history.path(root, opts))
  eq(#records, math.min(history.MAX_RUNS, workers * rounds), "runs.jsonl: no run line was lost")
  eq(
    #records[#records].failed,
    #expected,
    "runs.jsonl: the last line knows every failure of every worker"
  )

  -- last_green.json: the record with the latest time won
  local final = green.load(root, opts)
  eq(
    final and final.ts,
    1000 + workers * 100 + rounds,
    "last_green.json: the latest green run stays"
  )
  for _, state_file in ipairs({
    timings.path(root, opts),
    order.path(root, opts),
    history.path(root, opts),
  }) do
    eq(
      uv.fs_stat(state_file .. ".lock"),
      nil,
      "no lock file is left behind: " .. vim.fs.basename(state_file)
    )
  end

  vim.fn.delete(state, "rf")
end
