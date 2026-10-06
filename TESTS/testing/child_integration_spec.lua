-- TESTS/testing/child_integration_spec.lua -- the seams between the child driver, the guard layer, the run options and
-- the IR, for a child editor per file: the guard configuration reaches the child (job `guard`) and what
-- the guards found comes back in the cases; `deterministic` and `trace` do what the options say; a
-- child that timed out or died leaves a trace artifact (and none with `trace = false`).

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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local child = require("testing.child")
  local options_mod = require("testing.run.options")
  local isolated = require("testing.run.isolated")

  ---@param project? table
  ---@return Testing.Run.Options
  local function options(project)
    local o = options_mod.of({
      project = vim.tbl_extend("force", { isolated = "file" }, project or {}),
      args = {},
    })
    o.host_given = false
    return o
  end

  ---@param root string
  ---@param files table<string, string>
  ---@param order string[]
  ---@param project? table
  ---@param extra? table
  ---@return Testing.Inproc.Report
  local function run(root, files, order, project, extra)
    local o = options(project)
    local entries = S.project(root, files, order)
    local opts = vim.tbl_extend("force", {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      guard_cfg = options_mod.guard_config(o, { root = root }),
    }, extra or {})
    if opts.guard_cfg == false then
      opts.guard_cfg = nil -- no guard layer wanted
    end
    return S.run(root, entries, opts)
  end

  -- ===================================================================
  -- 1. the job carries what the parent decided (pure: nothing is started)
  do
    local guard =
      { repo = "/r", strict = false, restore = false, guards = { fs = { mode = "warn" } } }
    local plan = child.build({
      entry = { path = "/r/TESTS/a_spec.lua", rel = "TESTS/a_spec.lua", dialect = "a" },
      root = "/r",
      guard = guard,
      trace = false,
      deterministic = false,
      parent_env = { PATH = "p", LANG = "de_DE.UTF-8", TZ = "Europe/Vienna" },
    })
    eq(plan.job.guard, guard, "job: the guard configuration travels to the child")
    eq(plan.job.trace, false, "job: trace = false")
    eq(plan.env.LANG, "de_DE.UTF-8", "deterministic = false: the parent's LANG is passed on")
    eq(plan.env.TZ, "Europe/Vienna", "deterministic = false: and its TZ")
    local fixed = child.build({
      entry = { path = "/r/a", rel = "a", dialect = "a" },
      root = "/r",
      parent_env = { PATH = "p", LANG = "de_DE.UTF-8", TZ = "Europe/Vienna" },
    })
    eq(fixed.env.LANG, "C.UTF-8", "default: LANG is fixed")
    eq(fixed.env.TZ, "UTC", "default: TZ is fixed")
    eq(fixed.job.trace, true, "default: trace on")
    ok(fixed.job.guard == nil, "default: no guard configuration unless given")
    local job = child.job({ entry = { rel = "a" }, root = "/r", guard = guard }, "/f.ndjson")
    eq(job.fragment, "/f.ndjson", "child.job: the fragment path")
    eq(job.guard, guard, "child.job: the guard configuration")
  end

  -- ===================================================================
  -- 2. the guards run in the per-file child; what they found comes back in the cases
  do
    local root = S.new_root()
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) vim.fn.input('name? ') end",
      ["TESTS/b_spec.lua"] = [==[return function(H)
  local r = vim.system({ vim.v.progpath, "--version" }):wait()
  H.ok(r.code == 0, "the child process ran")
end]==],
      ["TESTS/c_spec.lua"] = "return function(H) H.ok(true, 'c') end",
    }
    local rep = run(root, files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" }, {
      guards = { process_net = "warn" },
    })
    local a, b, c =
      S.case_of(rep, "TESTS/a_spec.lua"),
      S.case_of(rep, "TESTS/b_spec.lua"),
      S.case_of(rep, "TESTS/c_spec.lua")
    ok(a.status == "error" or a.status == "fail", "prompt guard in the child: the case is red")
    local ids = {}
    for _, g in ipairs(a.guards) do
      ids[g.id or g.guard] = g.severity
    end
    eq(ids["prompt.unanswered"], "error", "prompt guard in the child: finding with its stable id")
    eq(b.status, "pass", "the spawning spec passes (warn mode)")
    ok(#b.effects.spawned >= 1, "effects ledger: the spawn is in the case's effects")
    has(table.concat(b.effects.spawned, " "), "nvim", "effects ledger: names the executable")
    eq(c.status, "pass", "a clean spec is untouched")
    eq(#c.effects.spawned, 0, "a clean spec has an empty ledger")
    for _, case in ipairs({ a, b, c }) do
      for _, n in ipairs(case.notes) do
        ok(
          not n:find("effects: not collected", 1, true),
          "measured effects: no 'not collected' note on " .. case.id
        )
      end
    end
    -- what the ledger cannot see under this configuration is said on the case too: with
    -- `process_net = "off"` an empty `spawned` list is not a measurement
    local guards_mod = require("testing.run.guards")
    eq(
      #guards_mod.unmeasured_notes(
        options_mod.guard_config(options({ guards = { process_net = "warn" } }), {})
      ),
      0,
      "process_net warn + fs warn: everything the ledger holds is measured"
    )
    local blind = guards_mod.unmeasured_notes(
      options_mod.guard_config(options({ guards = { process_net = "off", fs = "off" } }), {})
    )
    eq(#blind, 2, "process_net off and fs off: two notes")
    has(blind[1], "spawned and network are not measured", "the process note names what is blind")
    has(blind[2], "fs_outside_tmp is not measured", "the fs note names what is blind")
    eq(
      #guards_mod.unmeasured_notes(nil),
      0,
      "no configuration: nothing to add (the 'not collected' note covers it)"
    )
    local quiet = run(
      S.new_root(),
      { ["TESTS/c_spec.lua"] = files["TESTS/c_spec.lua"] },
      { "TESTS/c_spec.lua" }
    )
    local saw = false
    for _, n in ipairs(S.case_of(quiet, "TESTS/c_spec.lua").notes) do
      saw = saw or n:find("spawned and network are not measured", 1, true) ~= nil
    end
    ok(
      saw,
      "the default (process_net off): the case in the IR says spawned/network are not measured"
    )

    -- without a guard configuration nothing is measured, and the case says so
    local plain = run(
      S.new_root(),
      { ["TESTS/c_spec.lua"] = files["TESTS/c_spec.lua"] },
      { "TESTS/c_spec.lua" },
      nil,
      {
        guard_cfg = false,
      }
    )
    local noted = false
    for _, n in ipairs(S.case_of(plain, "TESTS/c_spec.lua").notes) do
      noted = noted or n:find("effects: not collected", 1, true) ~= nil
    end
    ok(noted, "no guard layer: the case says 'effects: not collected'")
  end

  -- ===================================================================
  -- 3. a per-file child that crashed or hung leaves a trace artifact; `trace = false` leaves none
  do
    local files = {
      ["TESTS/ok_spec.lua"] = "return function(H) H.ok(true, 'ok') end",
      ["TESTS/crash_spec.lua"] = "return function(H) vim.cmd('cquit 3') end",
      ["TESTS/hang_spec.lua"] = "return function(H) while true do end end",
    }
    local order = { "TESTS/ok_spec.lua", "TESTS/crash_spec.lua", "TESTS/hang_spec.lua" }
    local root = S.new_root()
    local rep = run(root, files, order, nil, { timeouts = { file_ms = 1500 }, grace_ms = 300 })
    eq(
      S.statuses(rep),
      { "TESTS/ok_spec.lua:pass", "TESTS/crash_spec.lua:crash", "TESTS/hang_spec.lua:timeout" },
      "crash and timeout are red, the rest is green"
    )
    local traces = {}
    for name in vim.fs.dir(root .. "/traces") do
      traces[#traces + 1] = name
    end
    eq(#traces, 2, "two trace files: one per dead child")
    for _, rel in ipairs({ "TESTS/crash_spec.lua", "TESTS/hang_spec.lua" }) do
      local case = S.case_of(rep, rel)
      local art = case.artifacts[1]
      ok(art and art.kind == "trace", rel .. ": the case carries a trace artifact")
      ok(art.path:find("trace.json", 1, true) ~= nil, rel .. ": it names the trace file")
    end
    ok(#S.case_of(rep, "TESTS/ok_spec.lua").artifacts == 0, "a green file has no artifact")
    -- the case the PARENT makes for a dead child says what the ledger could not see as well
    local dead_notes = table.concat(S.case_of(rep, "TESTS/crash_spec.lua").notes, "\n")
    has(
      dead_notes,
      "spawned and network are not measured",
      "the synthetic crash case carries the ledger note"
    )
    local crash_trace
    for _, name in ipairs(traces) do
      local t = vim.json.decode(S.slurp(root .. "/traces/" .. name) --[[@as string]])
      if t.reason == "crash" then
        crash_trace = t
      end
    end
    ok(crash_trace ~= nil, "the crash trace says reason = crash")
    eq(
      crash_trace.child.exit.code,
      3,
      "the trace has the exit code (the run guard ends a quit editor with 3)"
    )
    ok(crash_trace.child.file == "TESTS/crash_spec.lua", "the trace names the file")
    local text = vim.json.encode(crash_trace)
    ok(not text:find(root, 1, true), "the trace is redacted: the project root is a placeholder")

    local root2 = S.new_root()
    local off = run(
      root2,
      files,
      order,
      { trace = false },
      { timeouts = { file_ms = 1500 }, grace_ms = 300 }
    )
    eq(
      #S.case_of(off, "TESTS/crash_spec.lua").artifacts,
      0,
      "trace = false: no artifact on the crash"
    )
    eq(
      #S.case_of(off, "TESTS/hang_spec.lua").artifacts,
      0,
      "trace = false: no artifact on the timeout"
    )
    eq(vim.fn.isdirectory(root2 .. "/traces"), 0, "trace = false: no trace directory either")
  end

  -- ===================================================================
  -- 4. the trace directory is bounded: the oldest files go
  do
    local tdir = S.new_root() .. "/t"
    vim.fn.mkdir(tdir, "p")
    for i = 1, isolated.KEEP_TRACES + 6 do
      S.write(("%s/old-%03d.trace.json"):format(tdir, i), "{}")
      -- distinct, increasing modification times
      vim.uv.fs_utime(("%s/old-%03d.trace.json"):format(tdir, i), 1000000 + i, 1000000 + i)
    end
    local frag = { cases = {}, progress = {}, bad_lines = 0, missing = false }
    local art = isolated.write_trace({
      dir = tdir,
      root = tdir,
      rel = "TESTS/x_spec.lua",
      reason = "timeout",
      ---@diagnostic disable-next-line: missing-fields
      h = { pid = 4242, exit = { code = 1 } },
      frag = frag,
      describe = "exit code 1",
      err = "boom",
    })
    ok(art and art.kind == "trace", "write_trace: an artifact")
    local n, oldest = 0, nil
    for name in vim.fs.dir(tdir) do
      n = n + 1
      if name == "old-001.trace.json" then
        oldest = name
      end
    end
    eq(n, isolated.KEEP_TRACES, "the directory holds at most KEEP_TRACES files")
    ok(oldest == nil, "the oldest file was removed")
    has(isolated.trace_dir(nil), "testing-traces", "the default trace directory")
    eq(isolated.trace_dir(tdir .. "/"), tdir, "an explicit directory is normalized")
  end

  S.cleanup()
end
