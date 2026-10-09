-- TESTS/testing/watch_loop_spec.lua -- the loop of `--watch` (`testing.run.watch`) driven with a fake clock,
-- fake file-system events, a fake scanner and a fake runner: debounce, burst merging, what runs for which
-- change, failed-first, events during a run, polling fallback, Ctrl-C and the exit code. No editor timers,
-- no real files.

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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local watch = require("testing.run.watch")

  ---@param over? table
  ---@return table h
  local function harness(over)
    ---@type table<string, any>
    local h = { now = 0, fs = {}, said = {}, runs = {}, stops = 0, killed = 0, waits = 0 }
    h.opts = {
      root = "/proj",
      clock = function()
        return h.now
      end,
      debounce_ms = 100,
      say = function(line)
        h.said[#h.said + 1] = line
      end,
      scan = function()
        return vim.deepcopy(h.fs)
      end,
      source = function(on_event)
        h.on_event = on_event
        return {
          mode = "events",
          stop = function()
            h.stops = h.stops + 1
          end,
        }
      end,
      is_spec = function(rel)
        return rel:match("_spec%.lua$") ~= nil
      end,
      exists = function(rel)
        return h.gone == nil or not h.gone[rel]
      end,
      run = function(files, ctx)
        h.runs[#h.runs + 1] = { files = files, ctx = ctx }
        if h.on_run then
          h.on_run(files, ctx)
        end
        if h.result then
          return h.result(files, ctx)
        end
        return { exit_code = 0, failed = {} }
      end,
      wait = function(ms, cond)
        h.waits = h.waits + 1
        h.now = h.now + ms
        if h.script then
          h.script(h.waits)
        end
        if cond() then
          return true, nil
        end
        return false, -1
      end,
      kill_children = function()
        h.killed = h.killed + 1
      end,
    }
    for k, v in pairs(over or {}) do
      h.opts[k] = v
    end
    h.w = watch.new(h.opts)
    return h
  end

  ---Touch a file in the fake file system (a new signature = a change).
  local function touch(h, rel)
    h.fs["/proj/" .. rel] = tostring((tonumber(h.fs["/proj/" .. rel]) or 0) + 1)
  end

  -- the pure helpers
  eq(
    watch.diff({ a = "1", b = "1", c = "1" }, { a = "1", b = "2", d = "1" }),
    { "b", "c", "d" },
    "diff: changed, removed and added, sorted"
  )
  eq(watch.diff({ a = "1" }, { a = "1" }), {}, "diff: nothing changed")
  eq(watch.rel_of("/proj", "/proj/TESTS/a_spec.lua"), "TESTS/a_spec.lua", "rel_of strips the root")
  eq(
    watch.rel_of("C:/Proj", "c:\\proj\\TESTS\\a.lua"),
    "TESTS/a.lua",
    "rel_of: backslashes and case on Windows paths"
  )
  eq(
    watch.failed_first({ "a", "b", "c", "d" }, { c = true, a = true }),
    { "a", "c", "b", "d" },
    "failed_first: failed files first, both groups stable"
  )

  -- start: the first run is a full run, the source is started, the state is announced
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    eq(#h.runs, 1, "start runs once")
    eq(h.runs[1].files, nil, "the first run is every spec")
    eq(h.runs[1].ctx.first, true, "and is marked first")
    ok(h.on_event ~= nil, "the source was started")
    has(table.concat(h.said, "\n"), "watching", "a status line says what is watched")
    has(table.concat(h.said, "\n"), "fs events", "and how")
    has(table.concat(h.said, "\n"), "Waiting for changes", "and that it waits")
  end

  -- debounce: nothing runs before the quiet time, one run after it
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    eq(h.w:due(), false, "not due right after the event")
    h.now = 99
    eq(h.w:due(), false, "not due 1 ms before the quiet time")
    h.now = 100
    eq(h.w:due(), true, "due when the quiet time has passed")
    eq(h.w:cycle(), true, "the cycle ran")
    eq(#h.runs, 2, "one more run")
    eq(h.runs[2].files, { "TESTS/a_spec.lua" }, "only the changed spec runs")
    eq(h.runs[2].ctx.first, false, "not the first run any more")
    eq(h.w:due(), false, "nothing pending after the cycle")
  end

  -- a burst: events at 0, 50 and 120 ms; every event moves the quiet time; ONE run with every changed file
  do
    local h = harness()
    for _, f in ipairs({ "a", "b", "c" }) do
      h.fs["/proj/TESTS/" .. f .. "_spec.lua"] = "1"
    end
    h.w:start()
    touch(h, "TESTS/a_spec.lua")
    h.now = 0
    h.on_event()
    touch(h, "TESTS/b_spec.lua")
    h.now = 50
    h.on_event()
    h.now = 120
    touch(h, "TESTS/c_spec.lua")
    h.on_event()
    h.now = 219
    eq(
      h.w:due(),
      false,
      "the last event restarted the quiet time (generation, not the first timer)"
    )
    h.now = 220
    eq(h.w:due(), true, "due 100 ms after the LAST event")
    h.w:cycle()
    eq(#h.runs, 2, "a burst is one run")
    eq(
      h.runs[2].files,
      { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" },
      "with every file the burst changed (the debounce alone would have kept only the last name)"
    )
    eq(h.w.gen, 3, "the generation counter counted the events")
  end

  -- noise: an event without a content change does not run anything and does not shout
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    local said = #h.said
    h.on_event()
    h.now = 500
    eq(h.w:cycle(), false, "no change: no run")
    eq(#h.runs, 1, "still only the first run")
    eq(#h.said, said, "and silence")
    eq(h.w:due(), false, "the flag is cleared")
  end

  -- failed first, and failed files run again with the next change
  do
    local h = harness()
    for _, f in ipairs({ "a", "b", "c" }) do
      h.fs["/proj/TESTS/" .. f .. "_spec.lua"] = "1"
    end
    local fixed = false
    h.result = function()
      if fixed then
        return { exit_code = 0, failed = {} }
      end
      return { exit_code = 1, failed = { ["TESTS/c_spec.lua"] = true } }
    end
    h.w:start()
    eq(h.w.last_exit, 1, "the first run was red")
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    eq(
      h.runs[2].files,
      { "TESTS/c_spec.lua", "TESTS/a_spec.lua" },
      "the failed file runs FIRST, then the changed one"
    )
    eq(h.runs[2].ctx.failed_first, { "TESTS/c_spec.lua" }, "the context names what failed before")
    has(
      table.concat(h.said, "\n"),
      "failing: TESTS/c_spec.lua",
      "the status line names the red file"
    )
    -- c gets fixed: it is no longer red, the next change runs only what changed
    fixed = true
    touch(h, "TESTS/c_spec.lua")
    h.on_event()
    h.now = 400
    h.w:cycle()
    eq(h.runs[3].files, { "TESTS/c_spec.lua" }, "the fixed file runs once more")
    eq(h.w.last_exit, 0, "green again")
    eq(h.w:failed_list(), {}, "nothing is red")
    touch(h, "TESTS/b_spec.lua")
    h.on_event()
    h.now = 600
    h.w:cycle()
    eq(h.runs[4].files, { "TESTS/b_spec.lua" }, "and then only the changed file")
  end

  -- a module change: affected specs from the selection seam, every spec without one
  do
    local picked_args
    local h = harness({
      select = function(changed)
        picked_args = changed
        return { "TESTS/x_spec.lua" }
      end,
    })
    h.fs["/proj/lua/m/init.lua"] = "1"
    h.w:start()
    touch(h, "lua/m/init.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    eq(picked_args, { "lua/m/init.lua" }, "the selection seam gets the changed modules (relative)")
    eq(h.runs[2].files, { "TESTS/x_spec.lua" }, "the affected specs run")

    -- changed spec + changed module: the union
    touch(h, "lua/m/init.lua")
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 400
    h.w:cycle()
    eq(
      h.runs[3].files,
      { "TESTS/a_spec.lua", "TESTS/x_spec.lua" },
      "changed spec and affected specs together"
    )
  end
  do
    local h = harness({})
    h.fs["/proj/lua/m/init.lua"] = "1"
    h.w:start()
    touch(h, "lua/m/init.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    eq(h.runs[2].files, nil, "no selection at all: a lib change runs EVERY spec, never nothing")
    has(table.concat(h.said, "\n"), "every spec", "and says so")
  end
  do
    local h = harness({
      select = function()
        return nil, "the graph is stale"
      end,
    })
    h.fs["/proj/lua/m/init.lua"] = "1"
    h.w:start()
    touch(h, "lua/m/init.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    eq(h.runs[2].files, nil, "an unknown answer of the selection runs every spec")
    has(table.concat(h.said, "\n"), "the graph is stale", "and passes the reason on")
  end
  do
    local h = harness({
      select = function()
        error("boom")
      end,
    })
    h.fs["/proj/lua/m/init.lua"] = "1"
    h.w:start()
    touch(h, "lua/m/init.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    eq(h.runs[2].files, nil, "a selection that raises runs every spec")
    has(table.concat(h.said, "\n"), "boom", "and says why")
  end
  do
    -- non-Lua files (docs, json) never start a run
    local h = harness()
    h.w:start()
    h.fs["/proj/README.md"] = "1"
    h.fs["/proj/TESTS/data.json"] = "1"
    h.on_event()
    h.now = 200
    eq(h.w:cycle(), false, "a change outside .lua runs nothing")
  end

  -- a deleted spec: nothing to run (and no crash)
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    h.fs["/proj/TESTS/a_spec.lua"] = nil
    h.gone = { ["TESTS/a_spec.lua"] = true }
    h.on_event()
    h.now = 200
    eq(h.w:cycle(), false, "a deleted spec runs nothing")
    has(table.concat(h.said, "\n"), "nothing to run", "and says so")
    eq(#h.runs, 1, "no second run")
  end

  -- events during a run are kept, and announced
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    h.on_run = function()
      h.on_event() -- the user saved again while the run was going
      eq(h.w:due(h.now + 1000), false, "nothing is due while a run is active")
    end
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    h.on_run = nil
    has(table.concat(h.said, "\n"), "running again", "the status says the next run follows")
    eq(h.w.dirty, true, "the event of the run is not lost")
    h.now = 400
    eq(h.w:due(), true, "and starts the next cycle once the quiet time has passed")
  end

  -- a run that raises is reported, the loop lives on
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    h.result = function()
      error("driver exploded")
    end
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    has(table.concat(h.said, "\n"), "driver exploded", "the raise is shown")
    eq(h.w.last_exit, 3, "as an infrastructure exit")
    eq(h.w.running, false, "and the watcher is not stuck in 'running'")
  end

  -- the loop: runs, waits, reacts, ends on interrupt with the exit code of the last COMPLETED run
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.result = function(files)
      if files == nil then
        return { exit_code = 0, failed = {} }
      end
      return { exit_code = 1, failed = { ["TESTS/a_spec.lua"] = true } }
    end
    h.script = function(n)
      if n == 2 then
        touch(h, "TESTS/a_spec.lua")
        h.on_event()
      end
      if n == 12 then
        h.w:interrupt()
      end
    end
    local code = h.w:loop()
    eq(code, 1, "the exit code is the one of the last completed run")
    has(
      table.concat(h.said, "\n"),
      "watch: stopped; exit code 1",
      "the stop is announced with the exit code"
    )
    eq(#h.runs, 2, "the first run and one re-run")
    eq(h.stops, 1, "the source was closed")
    ok(h.killed >= 1, "what still runs was killed")
    eq(h.w.stopped, true, "stopped")
    eq(h.w.src, nil, "and the source reference is gone (stop is idempotent)")
    h.w:stop()
    eq(h.stops, 1, "a second stop closes nothing twice")
  end

  -- a run cut short by Ctrl-C does not replace the exit code
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.result = function(files)
      if files == nil then
        return { exit_code = 1, failed = { ["TESTS/a_spec.lua"] = true } }
      end
      return { exit_code = 0, interrupted = true, failed = {} }
    end
    h.script = function(n)
      if n == 2 then
        touch(h, "TESTS/a_spec.lua")
        h.on_event()
      end
      if n == 10 then
        h.w:interrupt()
      end
    end
    eq(h.w:loop(), 1, "an interrupted run leaves the earlier verdict")
    eq(h.w:failed_list(), { "TESTS/a_spec.lua" }, "and the failing set")
  end

  -- no run ever completed (Ctrl-C in the first run): an aborted run is never a green exit
  do
    local h = harness()
    h.result = function()
      return { exit_code = 0, interrupted = true }
    end
    h.script = function()
      h.w:interrupt()
    end
    eq(h.w:loop(), 3, "interrupted before anything finished: exit 3, not 0")
    local last = h.said[#h.said]
    ok(last:find("before a run completed", 1, true) ~= nil, "and the last line says why: " .. last)
  end

  -- a spec that writes a file below a watched root: after SELF_WRITE_LIMIT runs the file is ignored
  do
    local h = harness()
    h.on_run = function()
      -- every run (the first one included) rewrites the same Lua file: the event arrives while it runs
      touch(h, "lua/generated.lua")
      h.on_event()
    end
    h.script = function(n)
      if n > 400 then
        h.w:interrupt()
      end
    end
    h.result = function()
      return { exit_code = 0, failed = {} }
    end
    eq(h.w:loop(), 0, "the loop ends by itself being interrupted, green")
    eq(
      #h.runs,
      watch.SELF_WRITE_LIMIT,
      "the writer re-triggers the watcher a bounded number of times"
    )
    eq(h.w.ignored["/proj/lua/generated.lua"], true, "and is ignored")
    local told = false
    for _, line in ipairs(h.said) do
      if line:find("generated.lua", 1, true) and line:find("ignored from now on", 1, true) then
        told = true
      end
    end
    eq(told, true, "the status line names the ignored file")
  end

  -- a file that changes in ONE run only (a person saved during it) is never ignored
  do
    local h = harness()
    h.result = function()
      return { exit_code = 0, failed = {} }
    end
    local n_runs = 0
    h.on_run = function()
      n_runs = n_runs + 1
      if n_runs % 2 == 1 then
        touch(h, "lua/edited.lua")
        h.on_event()
      end
    end
    h.script = function(n)
      if n >= 10 then
        h.w:interrupt()
      end
    end
    h.w:loop()
    eq(next(h.w.ignored), nil, "a file written during every other run is not a self-writer")
  end

  -- `vim.wait` interrupted (Ctrl-C reaches it as `nil, -2`) ends the loop too
  do
    local h = harness({
      wait = function()
        return nil, -2
      end,
    })
    h.result = function()
      return { exit_code = 1, failed = {} }
    end
    eq(h.w:loop(), 1, "an interrupted wait ends the loop with the last exit code")
    eq(h.stops, 1, "after closing the source")
  end

  -- nothing starts after a stop
  do
    local h = harness()
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    h.w:stop()
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 1000
    eq(h.w:due(), false, "a stopped watcher is never due")
  end

  -- the source cannot start: polling, said out loud
  do
    local polled
    local h = harness({
      source = function()
        return nil, "ENOSPC: inotify watches exhausted"
      end,
      poll_source = function(on_event, popts)
        polled = popts
        return {
          mode = "poll",
          stop = function() end,
        }
      end,
    })
    h.w:start()
    ok(polled ~= nil, "the polling source took over")
    eq(polled.interval_ms, watch.DEFAULT_POLL_MS, "with the default interval")
    local said = table.concat(h.said, "\n")
    has(said, "ENOSPC", "the reason is shown")
    has(said, "polling", "and the fallback is named")
  end
  do
    local called = false
    local interval
    local h = harness({
      poll = true,
      source = function()
        called = true
        return nil, "must not be asked"
      end,
      poll_ms = 250,
      poll_source = function(_, popts)
        interval = popts.interval_ms
        return { mode = "poll", stop = function() end }
      end,
    })
    h.w:start()
    eq(called, false, "--watch-poll never asks for fs events")
    eq(interval, 250, "and uses the configured interval")
    has(table.concat(h.said, "\n"), "polling every 250 ms", "the status line says so")
  end

  -- a real poll source ticks (and stops cleanly)
  do
    local ticks = 0
    local src = watch.poll_source(function()
      ticks = ticks + 1
    end, { interval_ms = 10 })
    eq(src.mode, "poll", "poll source mode")
    ok(
      vim.wait(2000, function()
        return ticks >= 2
      end, 5),
      "the poll source ticks"
    )
    src.stop()
    local after = ticks
    vim.wait(60)
    ok(ticks <= after + 1, "and stops ticking after stop()")
    src.stop() -- idempotent
  end

  -- the cooldown (`max_wait_ms`): a debounce alone never fires while someone keeps saving; with a maximum wait the
  -- run comes once the FIRST pending change is that old, however fresh the last one is
  do
    local h = harness({ max_wait_ms = 1000 })
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    for t = 0, 900, 50 do
      h.now = t
      touch(h, "TESTS/a_spec.lua")
      h.on_event()
    end
    h.now = 950
    eq(
      h.w:due(),
      false,
      "saving every 50 ms keeps the debounce from firing, and 1000 ms are not over"
    )
    h.now = 1000
    eq(h.w:due(), true, "due once the first pending change waited max_wait_ms")
    eq(h.w:cycle(), true, "the cooldown run happens")
    eq(#h.runs, 2, "one run for the whole burst")
    eq(h.w:due(), false, "nothing pending afterwards")
    -- the next wait starts with the next change, not with the old one
    for t = 1100, 2050, 50 do
      h.now = t
      touch(h, "TESTS/a_spec.lua")
      h.on_event()
    end
    h.now = 2099
    eq(h.w:due(), false, "the clock of max_wait_ms restarted with the new first change")
    h.now = 2100
    eq(h.w:due(), true, "and fires a full max_wait_ms after it")
  end

  -- without `max_wait_ms` (or with 0) nothing changes: only the quiet time decides
  for _, off in ipairs({ 0, false }) do
    local h = harness({ max_wait_ms = off or nil })
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    for t = 0, 5000, 50 do
      h.now = t
      touch(h, "TESTS/a_spec.lua")
      h.on_event()
    end
    eq(h.w:due(), false, "max_wait_ms " .. tostring(off) .. ": continuous saving never fires")
  end

  -- an event DURING a run starts its own wait, so the next run is not due at once
  do
    local h = harness({ max_wait_ms = 1000 })
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    h.on_run = function()
      h.now = h.now + 3000
      touch(h, "TESTS/a_spec.lua")
      h.on_event()
    end
    h.now = 10
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 200
    h.w:cycle()
    h.on_run = nil
    eq(h.w:due(), false, "the event of the run is fresh: not due the moment the run ends")
    h.now = h.now + 100
    eq(h.w:due(), true, "due after the quiet time")
  end

  -- the machine-readable side: `watch_change` goes to the event seam with the project-relative files
  do
    local seen = {}
    local h = harness({
      event = function(kind, fields)
        seen[#seen + 1] = { kind = kind, fields = fields }
      end,
    })
    h.fs["/proj/TESTS/a_spec.lua"] = "1"
    h.w:start()
    touch(h, "TESTS/a_spec.lua")
    h.on_event()
    h.now = 500
    h.w:cycle()
    eq(#seen, 1, "one event for one cycle")
    eq(seen[1].kind, "watch_change", "its kind")
    eq(seen[1].fields, { files = { "TESTS/a_spec.lua" }, count = 1 }, "its files")
  end

  -- module purge: what the run loaded is forgotten, the runner's own and the baseline are not
  do
    local baseline = watch.loaded_set()
    package.loaded["watch_spec_fake.mod"] = { stale = true }
    package.loaded["watch_spec_fake"] = {}
    package.loaded["lib.nvim.watch_spec_fake"] = {}
    local n = watch.purge_modules(baseline)
    eq(n, 2, "two new plugin modules were forgotten")
    eq(package.loaded["watch_spec_fake.mod"], nil, "the plugin module is gone")
    ok(package.loaded["testing.run.watch"] ~= nil, "the runner itself stays")
    ok(package.loaded["lib.nvim.watch_spec_fake"] ~= nil, "lib.nvim stays even when it is new")
    package.loaded["lib.nvim.watch_spec_fake"] = nil
  end
end
