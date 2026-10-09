-- TESTS/testing/watch_cli_spec.lua -- `testing --watch` through `testing.cli` on a fixture project: the first run,
-- a real edit that the (polling) source sees, the re-run of only the edited spec with failed files first,
-- the status lines, history-derived red files, and the exit code of the last completed run at Ctrl-C
-- (`vim.wait` interrupted). The driver is a stub that reads a marker out of the spec file, so a spec
-- can be turned red and green by rewriting it.

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
  local cli = require("testing.cli")
  local result_mod = require("testing.core.result")
  local real_inproc = require("testing.run.inproc")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local root = vim.fs.normalize(vim.fn.tempname())
  local state = vim.fs.normalize(vim.fn.tempname())
  write(root .. "/TESTS/a_spec.lua", "-- GREEN\nreturn function(H) H.ok(true, 'x') end\n")
  write(root .. "/TESTS/b_spec.lua", "-- GREEN b\nreturn function(H) H.ok(true, 'x') end\n")
  write(root .. "/lua/m.lua", "return {}\n")

  ---@type string[][]
  local ran = {}
  local function driver()
    return setmetatable({
      run = function(opts)
        local files = {}
        for _, f in ipairs(opts.files) do
          files[#files + 1] = f.rel
        end
        ran[#ran + 1] = files
        local res = result_mod.new({ root = root })
        local bad = 0
        for _, f in ipairs(opts.files) do
          local text = io.open(root .. "/" .. f.rel, "rb"):read("*a")
          local c = result_mod.new_case({ file = f.rel, name = vim.fs.basename(f.rel) })
          c.assertions[1] = { ok = not text:find("RED", 1, true), kind = "eq", msg = "marker" }
          if text:find("RED", 1, true) then
            bad = bad + 1
          end
          result_mod.add_case(res, result_mod.finish_case(c))
        end
        result_mod.finalize(res)
        return {
          result = res,
          failed = bad,
          failed_files = bad,
          total = #res.cases,
          files_run = #opts.files,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 1,
          exit_code = bad > 0 and 1 or 0,
        }
      end,
    }, { __index = real_inproc })
  end

  local out, err = {}, {}
  local function text()
    return table.concat(out, "\n")
  end
  local stage, finished = 0, false
  local waits = 0
  local function leave_handlers()
    local n = 0
    for _, au in ipairs(vim.api.nvim_get_autocmds({ event = "VimLeavePre" })) do
      if (au.group_name or ""):find("^TestingWatchLeave") then
        n = n + 1
      end
    end
    return n
  end
  local seen_handlers = 0
  local seams = {
    poll_ms = 15,
    wait = function(ms, cond)
      waits = waits + 1
      seen_handlers = math.max(seen_handlers, leave_handlers())
      local t = text()
      if stage == 0 and t:find("run 1 finished", 1, true) then
        stage = 1
        write(root .. "/TESTS/a_spec.lua", "-- RED now\nreturn function(H) H.ok(true, 'x') end\n")
      elseif stage == 1 and t:find("run 2 finished", 1, true) then
        stage = 2
        write(
          root .. "/TESTS/b_spec.lua",
          "-- GREEN b, edited\nreturn function(H) H.ok(true, 'x') end\n"
        )
      elseif stage == 2 and t:find("run 3 finished", 1, true) then
        stage = 3
        write(
          root .. "/TESTS/a_spec.lua",
          "-- GREEN again\nreturn function(H) H.ok(true, 'x') end\n"
        )
      elseif stage == 3 and t:find("run 4 finished", 1, true) then
        finished = true
      end
      if finished then
        return nil, -2
      end
      -- give up after a generous time: an infinite loop must not hang the whole suite
      if waits > 4000 then
        finished = true
      end
      return vim.wait(ms, cond, 5)
    end,
  }

  local stream = vim.fs.normalize(vim.fn.tempname()) .. "-events.ndjson"
  local code = cli.main({
    root,
    "--watch",
    "--watch-poll",
    "--watch-debounce",
    "20",
    "--watch-max-wait",
    "5000",
    "--events",
    stream,
    "--no-timings",
  }, {
    out = function(s)
      out[#out + 1] = s
    end,
    err = function(s)
      err[#err + 1] = s
    end,
    state_dir = state,
    color = false,
    inproc = driver(),
    watch = seams,
  })
  local all = text()
  eq(stage, 3, "the script went through every stage (" .. all:sub(-500) .. ")")
  eq(code, 0, "the last completed run was green, so is the exit code")

  eq(#ran >= 4, true, "four runs happened")
  eq(#ran[1], 2, "the first run is every spec")
  eq(ran[2], { "TESTS/a_spec.lua" }, "a rewritten spec runs alone")
  eq(
    ran[3],
    { "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
    "the red spec runs again FIRST when another one changes"
  )
  eq(ran[4], { "TESTS/a_spec.lua" }, "a fixed spec runs by itself again")

  has(all, "watching", "the status line announces the watch")
  has(all, "polling every 15 ms", "and the source")
  has(all, "run 2 finished (exit 1, failing: TESTS/a_spec.lua)", "a red run names the red file")
  has(
    all,
    "run 3 finished (exit 1, failing: TESTS/a_spec.lua)",
    "which stays red until it is fixed"
  )
  has(all, "run 4 finished (exit 0)", "and the fix is seen")
  has(all, "Ctrl-C quits", "the status line says how to end it")
  has(all, "watch: stopped; exit code 0", "the end is announced with the exit code")
  eq(
    seen_handlers,
    1,
    "while watching, ONE VimLeavePre handler answers for a Ctrl-C that kills the run"
  )
  eq(leave_handlers(), 0, "and it is removed again when the watch ends")

  -- `--events` with `--watch`: one stream, run numbers 1..4, a `watch_change` before every re-run
  do
    local json = require("lib.nvim.json")
    local kinds, changes = {}, {}
    for line in io.lines(stream) do
      local obj = json.decode(line)
      kinds[#kinds + 1] = ("%s:%d"):format(obj.event, obj.run)
      if obj.event == "watch_change" then
        changes[#changes + 1] = obj.files
      end
    end
    eq(kinds, {
      "run_start:1",
      "run_done:1",
      "watch_change:2",
      "run_start:2",
      "run_done:2",
      "watch_change:3",
      "run_start:3",
      "run_done:3",
      "watch_change:4",
      "run_start:4",
      "run_done:4",
    }, "the stream tells the whole watch session in order, one file, run numbers counting up")
    eq(changes[1], { "TESTS/a_spec.lua" }, "the first change names the rewritten spec")
    vim.fn.delete(stream)
  end

  -- plugin modules loaded by a run are forgotten before the next run (in-process runs see edits)
  -- (the purge itself is specified in watch_loop_spec; here: the loop restored what it must)
  ok(package.loaded["testing.run.watch"] ~= nil, "the runner stays loaded")

  -- the selection seam of the glue: the contract of `testing.affected.select` (specs in, a Result out)
  do
    local watch = require("testing.run.watch")
    local cfg = { roots = { "TESTS" }, dialect = "auto", spec_pattern = { "_spec%.lua$" } }
    local seen
    local function fake(res, ferr)
      return {
        select = function(opts)
          seen = opts
          return res, ferr
        end,
      }
    end
    local files, note = watch.select_affected(root, cfg, { "lua/m.lua" }, {
      affected = fake({ files = { "TESTS/a_spec.lua" }, all = false }),
    })
    eq(files, { "TESTS/a_spec.lua" }, "the selected specs come back")
    eq(note, nil, "without a note")
    eq(seen.root, root, "the root is passed")
    eq(
      seen.specs,
      { "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
      "with EVERY spec of the project (discovery), not nothing"
    )
    eq(seen.changed, { "lua/m.lua" }, "and the changed files")
    eq(seen.implicit, false, "an explicit use")
    eq(seen.no_cache, false, "the analysis index is allowed on disk by default")
    watch.select_affected(root, cfg, { "lua/m.lua" }, {
      affected = fake({ files = {}, all = false }),
      no_cache = true,
    })
    eq(seen.no_cache, true, "--no-cache reaches the selection (the index stays off the disk)")
    files, note = watch.select_affected(root, cfg, { "lua/m.lua" }, {
      affected = fake({
        files = { "TESTS/a_spec.lua" },
        all = true,
        all_reason = "the graph is stale",
      }),
    })
    eq(files, nil, "all = true: the answer is 'unknown', every spec runs")
    eq(note, "the graph is stale", "with the reason")
    files, note = watch.select_affected(
      root,
      cfg,
      { "lua/m.lua" },
      { affected = fake(nil, "boom") }
    )
    eq(files, nil, "no answer: unknown")
    eq(note, "boom", "with the reason")
    files = watch.select_affected(
      root,
      cfg,
      { "lua/m.lua" },
      { affected = fake({ files = {}, all = false }) }
    )
    eq(files, {}, "an empty selection stays empty: no spec reaches the change, nothing is invented")
    files, note = watch.select_affected(root, cfg, { "lua/m.lua" }, { affected = {} })
    eq(files, nil, "a module without `select`: unknown")
    has(note, "no affected-module", "and says so")
    -- the real module on a fixture: one spec requires the changed module, the other does not
    local root2 = vim.fs.normalize(vim.fn.tempname())
    write(root2 .. "/lua/m.lua", "return {}\n")
    write(
      root2 .. "/TESTS/uses_spec.lua",
      "local m = require('m')\nreturn function(H)\n  H.ok(m, 'x')\nend\n"
    )
    write(root2 .. "/TESTS/other_spec.lua", "return function(H)\n  H.ok(true, 'y')\nend\n")
    local real, why = watch.select_affected(root2, cfg, { "lua/m.lua" })
    eq(
      real,
      { "TESTS/uses_spec.lua" },
      "the real testing.affected picks the spec that requires the module (" .. tostring(why) .. ")"
    )
    vim.fn.delete(root2, "rf")
  end

  -- the combination rules
  local function refused(argv)
    local o, e = {}, {}
    local c = cli.main(argv, {
      out = function(s)
        o[#o + 1] = s
      end,
      err = function(s)
        e[#e + 1] = s
      end,
      state_dir = state,
    })
    return c, table.concat(e, "\n")
  end
  local c, e = refused({ root, "--watch", "--list" })
  eq(c, 2, "--watch --list is refused")
  has(e, "--list", "naming the other option")
  c, e = refused({ root, "--watch-debounce", "20" })
  eq(c, 2, "--watch-debounce needs --watch")
  has(e, "--watch", "and says so")
  c, e = refused({ root, "--watch-poll" })
  eq(c, 2, "--watch-poll needs --watch")
  has(e, "--watch", "and says so")
  c, e = refused({ root, "--watch", "--profile" })
  eq(c, 2, "--watch --profile is refused")
  has(e, "--profile", "and names the option")
  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
end
