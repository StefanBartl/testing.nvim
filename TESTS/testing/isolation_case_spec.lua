-- TESTS/testing/isolation_case_spec.lua -- `isolated = "case"`: a fresh child editor per CASE (busted files), through the
-- real isolated driver and real children. The fixture is order dependent on purpose: it only passes when every
-- case gets its own editor. Merged results are deterministic whatever `jobs` says; every other dialect degrades
-- to a child per file, with a note.

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
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local options = require("testing.run.options")
  local project = require("testing.config.project")
  local isolated = require("testing.run.isolated")
  local select_mod = require("testing.run.select")
  local result = require("testing.core.result")
  local real_child = require("testing.child")

  local ORDER = [[
describe("order", function()
  local state = 0
  it("first sets the state", function()
    state = state + 1
    rawset(_G, "iso_order_flag", true)
    assert.is_true(state == 1)
  end)
  it("second sees nothing of the first", function()
    assert.is_nil(rawget(_G, "iso_order_flag"))
  end)
  describe("nested", function()
    it("third has a fresh upvalue", function()
      assert.is_true(state == 0)
    end)
  end)
end)
]]
  local PLAIN = 'return function(H)\n  H.eq(1, 1, "plain")\nend\n'
  local ORDER_IDS = {
    "TESTS/a_order_spec.lua::order::first sets the state",
    "TESTS/a_order_spec.lua::order::second sees nothing of the first",
    "TESTS/a_order_spec.lua::order::nested::third has a fresh upvalue",
  }

  local function case_options(over)
    local o = options.of({ project = project.validate({ isolated = "case" }) })
    return vim.tbl_extend("force", o, over or {})
  end
  local function ids_of(report)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      out[#out + 1] = c.id
    end
    return out
  end
  local function statuses(report)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      out[#out + 1] = c.status
    end
    return out
  end
  ---The IR without what legitimately differs between two runs (durations).
  local function stable(report)
    local copy = vim.deepcopy(report.result.cases)
    for _, c in ipairs(copy) do
      c.duration_ms = nil
    end
    return copy
  end

  -- ================================================================== the order-dependent fixture
  local root = S.new_root()
  local entries = S.project(
    root,
    { ["TESTS/a_order_spec.lua"] = ORDER },
    { "TESTS/a_order_spec.lua" },
    "busted"
  )

  -- control: one child for the whole file shares its state between the cases, and fails
  local shared = S.run(root, entries, { options = { isolated = "file" } })
  eq(
    statuses(shared),
    { "pass", "fail", "fail" },
    "control: isolated=file runs the file's cases in ONE editor: the later cases see the earlier ones"
  )

  -- a child per case is exact
  local calls = {}
  local spy_child = setmetatable({
    build = function(spec)
      calls[#calls + 1] = spec
      return real_child.build(spec)
    end,
  }, { __index = real_child })
  local per_case = S.run(root, entries, { options = case_options(), child = spy_child })
  eq(
    statuses(per_case),
    { "pass", "pass", "pass" },
    "isolated=case: every case gets its own editor and passes"
  )
  eq(ids_of(per_case), ORDER_IDS, "the ids are the ones of the file, in source order")
  eq(per_case.exit_code, 0, "green")
  eq(
    { per_case.files_run, per_case.files_unrun, per_case.total },
    { 1, 0, 3 },
    "one file, three cases"
  )
  eq(#calls, 3, "three children were started")
  for i, spec in ipairs(calls) do
    eq(spec.lf_ids, { ORDER_IDS[i] }, "child " .. i .. " is told to run exactly its case")
    eq(spec.entry.rel, "TESTS/a_order_spec.lua", "of the file")
    eq(spec.deterministic, true, "the determinism switch reaches the child build")
    eq(spec.trace, true, "and the trace switch")
    eq(spec.guard, nil, "no guard configuration unless the driver was given one")
  end
  local valid, problems = result.validate(per_case.result, { allow_abs_paths = true })
  eq({ valid, problems }, { true, {} }, "the merged IR is valid")

  -- guard configuration and the switches are forwarded to the child spec
  calls = {}
  local forwarded = S.run(root, entries, {
    options = case_options({ determinism = false, trace = false }),
    guard_cfg = {},
    child = spy_child,
  })
  eq(forwarded.exit_code, 0, "still green")
  eq(calls[1].deterministic, false, "determinism = false is forwarded")
  eq(calls[1].trace, false, "trace = false is forwarded")
  eq(calls[1].guard.guards.prompt.mode, "error", "the guard configuration travels as `guard`")
  eq(calls[1].guard.repo, root, "with the root")
  eq(calls[1].guard.restore, false, "and the soft isolation stays the runner's")
  ok(vim.json.encode(calls[1].guard) ~= nil, "and it is JSON-safe")

  -- ================================================================== deterministic merge
  local second = S.project(root, {
    ["TESTS/b_other_spec.lua"] = ORDER:gsub("order", "other"):gsub("first sets the state", "alpha"),
    ["TESTS/c_plain_spec.lua"] = PLAIN,
  }, { "TESTS/b_other_spec.lua", "TESTS/c_plain_spec.lua" })
  second[1].dialect = "busted"
  local all = { entries[1], second[1], second[2] }
  local serial = S.run(root, all, { options = case_options({ jobs = 1 }) })
  local parallel = S.run(root, all, { options = case_options({ jobs = 4 }) })
  eq(stable(serial), stable(parallel), "the merged IR is the same for jobs = 1 and jobs = 4")
  eq(#serial.result.cases, 3 + 3 + 1, "three + three + the plain file")
  eq(ids_of(serial), {
    ORDER_IDS[1],
    ORDER_IDS[2],
    ORDER_IDS[3],
    "TESTS/b_other_spec.lua::other::alpha",
    "TESTS/b_other_spec.lua::other::second sees nothing of the first",
    "TESTS/b_other_spec.lua::other::nested::third has a fresh upvalue",
    "TESTS/c_plain_spec.lua::c_plain_spec.lua",
  }, "file order, then source order inside a file")
  eq(
    { serial.files_run, parallel.files_run },
    { 3, 3 },
    "files are counted once, not once per case"
  )
  eq(serial.exit_code, 0, "all green")

  -- ================================================================== other dialects degrade
  local plain_case = serial.result.cases[7]
  local note_text = table.concat(plain_case.notes, "\n")
  has(note_text, "isolated=case degraded to file", "a dialect-a file says it degraded")
  for _, c in ipairs({ serial.result.cases[1], serial.result.cases[4] }) do
    ok(
      not table.concat(c.notes, "\n"):find("degraded", 1, true),
      "a busted case has no degrade note: " .. c.id
    )
  end
  calls = {}
  S.run(root, { second[2] }, { options = case_options(), child = spy_child })
  eq(#calls, 1, "a dialect-a file gets ONE child")
  eq(calls[1].lf_ids, nil, "that is not told to run a single case")

  -- ================================================================== a crash is the case's, not the file's
  local crash_root = S.new_root()
  local crash_entries = S.project(crash_root, {
    ["TESTS/crash_spec.lua"] = [[
describe("crashy", function()
  it("fine before", function() assert.is_true(true) end)
  it("kills the editor", function() vim.cmd("cquit 3") end)
  it("fine after", function() assert.is_true(true) end)
end)
]],
  }, { "TESTS/crash_spec.lua" }, "busted")
  local crashed = S.run(crash_root, crash_entries, { options = case_options() })
  eq(
    statuses(crashed),
    { "pass", "crash", "pass" },
    "only the case that killed its editor is a crash"
  )
  eq(crashed.result.cases[2].id, "TESTS/crash_spec.lua::crashy::kills the editor", "under ITS id")
  has(crashed.result.cases[2].error.message, "exit code 3", "with the exit code")
  eq(crashed.exit_code, 1, "and the run is red")
  local one_child = S.run(crash_root, crash_entries, { options = { isolated = "file" } })
  eq(
    #one_child.result.cases,
    2,
    "control: in one child the crash also ends the cases that never ran"
  )

  -- classify: the synthetic case of a kill takes the id of the case (pure)
  local CASE = "TESTS/x_spec.lua::d::the case"
  local function classify(over, without_case)
    local input = vim.tbl_extend("force", {
      rel = "TESTS/x_spec.lua",
      kind = "cases",
      frag = { cases = {}, done = nil, bad_lines = 0, missing = true },
      code = 1,
      signal = 0,
      out = "",
      stdout = "",
      err = "",
      wall_ms = 5,
      file_ms = 1000,
      case_ms = 500,
      grace_ms = 200,
      describe_exit = "exit code 1",
      case_id = CASE,
    }, over or {})
    if without_case then
      input.case_id = nil
    end
    return isolated.classify(input)
  end
  local killed = classify({ reason = "file" })
  eq({ killed[1].status, killed[1].id }, { "timeout", CASE }, "a hard timeout carries the case id")
  killed = classify({ reason = "stall" })
  eq({ killed[1].status, killed[1].id }, { "timeout", CASE }, "so does a stall")
  killed = classify({})
  eq({ killed[1].status, killed[1].id }, { "crash", CASE }, "so does a crash")
  killed = classify({}, true)
  eq(
    killed[1].id,
    "TESTS/x_spec.lua::x_spec.lua",
    "without a case id the file id (unchanged behaviour)"
  )
  local taken = result.new_case({ file = "TESTS/x_spec.lua", describe = "d", name = "the case" })
  taken.assertions[1] = { ok = true, kind = "eq" }
  local both = classify({
    frag = { cases = { taken }, done = { k = "done" }, bad_lines = 0, missing = false },
    code = 139,
    describe_exit = "exit code 139",
  })
  eq(#both, 2, "a death after the case's own record: both")
  ok(both[1].id ~= both[2].id, "with different ids (no duplicate in the IR)")

  -- ================================================================== listing problems are visible
  local ghost = S.run(root, entries, {
    options = case_options(),
    list_cases = function(entry)
      return { entry.rel .. "::order::a case that does not exist" }
    end,
  })
  eq(#ghost.result.cases, 1, "a listed case that its child did not report: one case")
  eq(ghost.result.cases[1].status, "error", "an error, never a silent drop")
  eq(
    ghost.result.cases[1].id,
    "TESTS/a_order_spec.lua::order::a case that does not exist",
    "under the listed id"
  )
  has(
    ghost.result.cases[1].error.message,
    "listed but its child did not report it",
    "says what happened"
  )

  local broken_root = S.new_root()
  local broken_entries = S.project(broken_root, {
    ["TESTS/broken_spec.lua"] = 'describe("x", function()\n  error("describe exploded")\nend)\n',
  }, { "TESTS/broken_spec.lua" }, "busted")
  local broken = S.run(broken_root, broken_entries, { options = case_options() })
  eq(#broken.result.cases, 1, "a file whose describe body raises: one case")
  eq(broken.result.cases[1].status, "error", "an error")
  has(
    broken.result.cases[1].error.message,
    "cannot list the cases for isolated=case",
    "names the mode"
  )
  has(broken.result.cases[1].error.message, "describe exploded", "and the reason")
  eq(broken.exit_code, 1, "red")

  local empty_root = S.new_root()
  local empty_entries = S.project(
    empty_root,
    { ["TESTS/empty_spec.lua"] = "-- nothing here\n" },
    { "TESTS/empty_spec.lua" },
    "busted"
  )
  calls = {}
  local empty = S.run(empty_root, empty_entries, { options = case_options(), child = spy_child })
  eq(#calls, 1, "a file with no case at all: one child for the file")
  eq(#empty.result.cases, 1, "whose empty-file policy decides")
  ok(empty.result.cases[1].status ~= "pass", "an empty busted file is never a pass")

  -- ================================================================== selection and --maxfail
  local filter = { "second sees" }
  local filtered = S.run(root, entries, {
    options = case_options(),
    selector = select_mod.new({ filter = filter }),
    selector_spec = { filter = filter },
  })
  eq(ids_of(filtered), { ORDER_IDS[2] }, "--filter: only the selected case gets a child")
  calls = {}
  S.run(root, entries, {
    options = case_options(),
    selector = select_mod.new({ filter = filter }),
    selector_spec = { filter = filter },
    child = spy_child,
  })
  eq(#calls, 1, "and only one child was started")

  local fail_root = S.new_root()
  local fail_entries = S.project(fail_root, {
    ["TESTS/a_fail_spec.lua"] = 'describe("f", function()\n  it("bad", function() assert.is_true(false) end)\n  it("good", function() assert.is_true(true) end)\n  it("good too", function() assert.is_true(true) end)\nend)\n',
    ["TESTS/b_plain_spec.lua"] = PLAIN,
  }, { "TESTS/a_fail_spec.lua", "TESTS/b_plain_spec.lua" })
  fail_entries[1].dialect = "busted"
  local stopped = S.run(fail_root, fail_entries, { options = case_options(), maxfail = 1 })
  eq(#stopped.result.cases, 1, "--maxfail 1: the merge stops at the first red case")
  eq(stopped.stopped, true, "stopped")
  eq(
    stopped.files_unrun,
    1,
    "the other FILE is unrun (the later cases of the failing file are not files)"
  )
  eq(stopped.files_run, 1, "and the failing file counts once")
  eq(stopped.exit_code, 1, "red")

  -- output of a case's child is shown under the case
  local out_root = S.new_root()
  local out_entries = S.project(out_root, {
    ["TESTS/out_spec.lua"] = 'describe("o", function()\n  it("talks", function()\n    print("hello from the child")\n    assert.is_true(true)\n  end)\nend)\n',
  }, { "TESTS/out_spec.lua" }, "busted")
  local labels = {}
  S.run(out_root, out_entries, {
    options = case_options(),
    on_output = function(label, text)
      labels[#labels + 1] = label .. "|" .. text
    end,
  })
  eq(#labels, 1, "the output of the child is passed on once")
  has(labels[1], "TESTS/out_spec.lua [o::talks]|", "labelled with file and case")
  has(labels[1], "hello from the child", "with what it printed")

  S.cleanup()
end
