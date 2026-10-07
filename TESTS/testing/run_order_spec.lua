-- TESTS/testing/run_order_spec.lua -- testing.run.order: `--order priority` orders the spec files (last failed, changed,
-- requirer distance, stale, rest), never filters them, falls back to the discovery order without signals, keeps the
-- Result-IR in discovery order, and reads its state file as untrusted input.

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack))
    )
  end

  local order = require("testing.run.order")
  local result = require("testing.core.result")
  local DAY = 86400
  local NOW = 1800000000

  -- the stages, in order ---------------------------------------------------------------------------------------------------
  local files = { "a", "b", "c", "d", "e", "f", "g", "h" }
  local history = {
    failed = { g = true },
    last_run = {
      a = NOW - 1 * DAY,
      b = NOW - 1 * DAY,
      c = NOW - 1 * DAY,
      d = NOW - 30 * DAY,
      e = NOW - 1 * DAY,
      f = NOW - 1 * DAY,
      g = NOW - 1 * DAY,
      h = NOW - 1 * DAY,
    },
    ms = {},
    known = true,
    now = NOW,
  }
  local changed = { f = true }
  local graph = { distance = { c = 2, e = 1, b = order.UNKNOWN_DISTANCE } }
  local ordered, info, signal = order.priority(files, history, changed, graph)
  eq(
    ordered,
    { "g", "f", "e", "c", "b", "d", "a", "h" },
    "red, changed, distance 1, 2, unknown reach, stale, rest"
  )
  eq(signal, true, "there was something to tell the files apart")
  eq(info.g.stage, "red", "the failed file is stage red")
  eq(info.g.reason, "failed last time", "with its reason")
  eq(info.f.stage, "changed", "a changed spec")
  eq(info.e.distance, 1, "the distance is kept")
  has(info.c.reason, "distance 2", "and named")
  eq(info.b.reason, "reached by a change", "a reach without a chain says so")
  has(info.d.reason, "not run for 30 day(s)", "stale: how long")
  eq(info.h.stage, "rest", "the rest")
  eq(info.g.rank, 1, "the rank is the position")
  eq(info.h.rank, 8, "also at the end")

  -- inside a stage: the shortest duration first, an unknown one after the known ones, then discovery order ------------------
  local o2 = order.priority({ "a", "b", "c", "d" }, {
    failed = { a = true, b = true, c = true, d = true },
    ms = { a = 50, b = 5, d = 5 },
    now = NOW,
  }, {}, {})
  eq(
    o2,
    { "b", "d", "a", "c" },
    "equal durations keep the discovery order, an unknown duration comes last"
  )

  -- never run: a file the state does not know, when there is a state ------------------------------------------------------------
  local o3, i3 = order.priority(
    { "old", "new" },
    { last_run = { old = NOW - DAY }, known = true, now = NOW },
    {},
    {}
  )
  eq(o3, { "new", "old" }, "a file the run state has never seen is stage stale ('never run')")
  eq(i3.new.reason, "never run", "with that reason")
  local o4 = order.priority({ "old", "new" }, { last_run = {}, known = false, now = NOW }, {}, {})
  eq(o4, { "old", "new" }, "without a run state nothing is 'never run'")

  -- no signal: the discovery order is kept, durations alone must not shuffle it ----------------------------------------------------
  local o5, _, s5 = order.priority({ "z", "y", "x" }, { ms = { z = 9, y = 1, x = 5 } }, nil, nil)
  eq(o5, { "z", "y", "x" }, "no history, no change, no graph: discovery order")
  eq(s5, false, "and the caller is told that nothing told the files apart")
  local o6, _, s6 = order.priority({}, nil, nil, nil)
  eq(o6, {}, "no files")
  eq(s6, false, "no signal")
  eq(order.priority({ "a" }, nil, nil, nil), { "a" }, "one file")

  -- the SET never changes: a permutation, for any input --------------------------------------------------------------------------------
  local seed = 20261007
  local function rnd(n)
    seed = (seed * 48271) % 2147483647
    return (seed % n) + 1
  end
  for _ = 1, 200 do
    local n = rnd(30) - 1
    local fl, hist, chg, gr =
      {},
      { failed = {}, last_run = {}, ms = {}, known = rnd(2) == 1, now = NOW },
      {},
      { distance = {} }
    for i = 1, n do
      local rel = ("TESTS/f%02d_spec.lua"):format(i)
      fl[i] = rel
      if rnd(5) == 1 then
        hist.failed[rel] = true
      end
      if rnd(5) == 1 then
        chg[rel] = true
      end
      if rnd(4) == 1 then
        gr.distance[rel] = rnd(4)
      end
      if rnd(3) == 1 then
        hist.last_run[rel] = NOW - rnd(20) * DAY
      end
      if rnd(3) == 1 then
        hist.ms[rel] = rnd(1000)
      end
    end
    -- inputs that name files that are not in the list (a removed file in the history) must not add anything
    hist.failed["TESTS/gone_spec.lua"] = true
    chg["lua/not_a_spec.lua"] = true
    gr.distance["TESTS/gone_spec.lua"] = 1
    local out, inf = order.priority(fl, hist, chg, gr)
    local a, b = vim.deepcopy(fl), vim.deepcopy(out)
    table.sort(a)
    table.sort(b)
    if not vim.deep_equal(a, b) or #out ~= #fl then
      ok(false, "priority is not a permutation of " .. vim.inspect(fl) .. ": " .. vim.inspect(out))
      break
    end
    for i, rel in ipairs(out) do
      if inf[rel].rank ~= i then
        ok(false, "the rank is the position")
        break
      end
    end
  end
  ok(true, "200 random inputs: the output is always a permutation of the input")

  -- the require distance in the reason text of the affected heuristic -------------------------------------------------------------------------
  eq(
    order.distance_of("reaches a.b (lua/a/b.lua changed)"),
    1,
    "a spec that requires the changed module: 1"
  )
  eq(
    order.distance_of("reaches a.b <- c.d <- e.f (lua/e/f.lua changed)"),
    3,
    "a chain of three modules: 3"
  )
  eq(order.distance_of("changed"), nil, "another reason names no chain")
  eq(order.distance_of(nil), nil, "no reason")

  -- the state file --------------------------------------------------------------------------------------------------------------------------
  local state = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(state, "p")
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local res = result.new({
    id = "r1",
    root = root,
    project_key = "k",
    nvim = "0.12.0",
    os = "linux",
    duration_ms = 1,
  })
  local function add(file, ms, cached)
    local c = result.new_case({ file = file, name = "c" })
    c.duration_ms = ms
    c.assertions = { { ok = true, kind = "ok" } }
    result.finish_case(c)
    c.cached = cached
    result.add_case(res, c)
  end
  add("TESTS/a_spec.lua", 10)
  add("TESTS/a_spec.lua", 5)
  add("TESTS/b_spec.lua", 7, true)
  local rok = order.record_state(root, res, { state_dir = state, time = 1000 })
  ok(rok, "the state is written")
  local files_state = order.load_state(root, { state_dir = state })
  eq(
    files_state,
    { ["TESTS/a_spec.lua"] = { ts = 1000, ms = 15 } },
    "an executed file: when and how long; a cached one did not run"
  )
  order.record_state(root, res, { state_dir = state, time = 2000, partial = true })
  files_state = order.load_state(root, { state_dir = state })
  eq(
    files_state["TESTS/a_spec.lua"],
    { ts = 2000, ms = 15 },
    "a partial run (case filter) keeps the old duration"
  )
  order.record_state(
    root,
    res,
    { state_dir = state, time = 3000, known_files = { ["TESTS/b_spec.lua"] = true } }
  )
  files_state = order.load_state(root, { state_dir = state })
  eq(files_state["TESTS/a_spec.lua"], nil, "a file that is gone is forgotten")

  -- untrusted: garbage, a huge file, wrong shapes ----------------------------------------------------------------------------------------
  local path = order.path(root, { state_dir = state })
  local function put(text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put("not json at all {{{")
  local g, note = order.load_state(root, { state_dir = state })
  eq(g, {}, "garbage gives an empty state")
  has(note, "not usable", "and a note")
  put('{"v":2,"files":{}}')
  eq((order.load_state(root, { state_dir = state })), {}, "an unknown version is ignored")
  put(
    '{"v":1,"files":{"ok.lua":{"ts":5,"ms":1},"bad\\u0001.lua":{"ts":5},"x.lua":{"ts":"no"},"y.lua":7,"z.lua":{"ts":-4}}}'
  )
  eq(
    order.load_state(root, { state_dir = state }),
    { ["ok.lua"] = { ts = 5, ms = 1 } },
    "only valid entries survive"
  )
  put(("x"):rep(order.MAX_BYTES + 10))
  local _, big_note = order.load_state(root, { state_dir = state })
  has(big_note, "too large", "a file over the size cap is not read")

  -- the report order: cases go back to discovery order ------------------------------------------------------------------------------------
  local rr = result.new({
    id = "r2",
    root = root,
    project_key = "k",
    nvim = "0.12.0",
    os = "linux",
    duration_ms = 1,
  })
  for _, spec in ipairs({
    { "TESTS/c_spec.lua", "c1" },
    { "TESTS/a_spec.lua", "a1" },
    { "TESTS/a_spec.lua", "a2" },
    { "TESTS/b_spec.lua", "b1" },
  }) do
    local c = result.new_case({ file = spec[1], name = spec[2] })
    c.assertions = { { ok = true, kind = "ok" } }
    result.finish_case(c)
    result.add_case(rr, c)
  end
  order.restore(rr, { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" })
  local ids = {}
  for _, c in ipairs(rr.cases) do
    ids[#ids + 1] = c.id:match("::(.*)$")
  end
  eq(ids, { "a1", "a2", "b1", "c1" }, "files in discovery order, cases inside a file keep theirs")
  -- table.sort is not stable: many cases of two files must keep their own order too
  local rm = result.new({
    id = "r3",
    root = root,
    project_key = "k",
    nvim = "0.12.0",
    os = "linux",
    duration_ms = 1,
  })
  for i = 1, 60 do
    local c = result.new_case({
      file = i % 2 == 0 and "TESTS/a_spec.lua" or "TESTS/b_spec.lua",
      name = ("n%02d"):format(i),
    })
    c.assertions = { { ok = true, kind = "ok" } }
    result.finish_case(c)
    result.add_case(rm, c)
  end
  order.restore(rm, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" })
  local seq = {}
  for _, c in ipairs(rm.cases) do
    seq[#seq + 1] = c.id:match("::(.*)$")
  end
  local expect = {}
  for i = 2, 60, 2 do
    expect[#expect + 1] = ("n%02d"):format(i)
  end
  for i = 1, 59, 2 do
    expect[#expect + 1] = ("n%02d"):format(i)
  end
  eq(
    seq,
    expect,
    "sixty cases of two files: the files in discovery order, each file's cases in their own order"
  )

  -- facts: injected affected selection ----------------------------------------------------------------------------------------------------------
  local stub = {
    select = function(o)
      eq(o.mode, "changed", "the working tree against HEAD is what is looked at")
      return {
        files = { "TESTS/s1_spec.lua", "TESTS/s2_spec.lua", "TESTS/s3_spec.lua" },
        reason = {
          ["TESTS/s1_spec.lua"] = "reaches m.a (lua/m/a.lua changed)",
          ["TESTS/s2_spec.lua"] = "reaches m.b <- m.a (lua/m/a.lua changed)",
          ["TESTS/s3_spec.lua"] = "starts a process: the code it runs is invisible to the graph",
        },
        changed = { "lua/m/a.lua", "TESTS/s1_spec.lua" },
        all = false,
        unknown = {},
        source = "heuristic",
        warnings = {},
        ci = false,
      }
    end,
  }
  local hist2, chg2, gr2, notes2 = order.facts({
    root = root,
    specs = { "TESTS/s1_spec.lua", "TESTS/s2_spec.lua", "TESTS/s3_spec.lua" },
    state_dir = state,
    affected = stub,
  })
  eq(chg2["TESTS/s1_spec.lua"], true, "a changed spec is in the changed set")
  eq(gr2.distance["TESTS/s2_spec.lua"], 2, "the distance comes from the reason of the selection")
  eq(
    gr2.distance["TESTS/s3_spec.lua"],
    order.UNKNOWN_DISTANCE,
    "a reach without a chain has the unknown distance"
  )
  eq(type(hist2.failed), "table", "the history is there")
  eq(type(notes2), "table", "and the notes")
  local all_stub = {
    select = function()
      return {
        files = {},
        reason = {},
        changed = {},
        all = true,
        all_reason = "git failed",
        source = "none",
        unknown = {},
        warnings = {},
        ci = false,
      }
    end,
  }
  local _, chg3, gr3, notes3 =
    order.facts({ root = root, specs = {}, state_dir = state, affected = all_stub })
  eq(chg3, {}, "when the selection could not be trusted there is no changed set")
  eq(gr3.distance, {}, "and no distance")
  has(table.concat(notes3, "\n"), "no diff proximity: git failed", "and the note says why")
  local boom = {
    select = function()
      error("boom")
    end,
  }
  local _, _, _, notes4 =
    order.facts({ root = root, specs = {}, state_dir = state, affected = boom })
  has(
    table.concat(notes4, "\n"),
    "cannot be looked at",
    "a failing selection is a note, never an error"
  )

  vim.fn.delete(state, "rf")
  vim.fn.delete(root, "rf")
end
