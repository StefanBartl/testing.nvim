---@diagnostic disable: need-check-nil
-- TESTS/testing/rpc_async_spec.lua -- the calls that do not block (`spawn_async`, `child.exec_async`, `child.proc`):
-- what the warm pool needs so that its supervisor keeps running while a spec file runs in a member.

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
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local rpc = require("testing.rpc")
  local wire_mod = require("testing.rpc.wire")

  -- ===================================================================
  -- wire: a request can carry a callback that runs when its answer arrives
  do
    local sent = {}
    local w = wire_mod.new({
      write = function(bytes)
        sent[#sent + 1] = bytes
        return true
      end,
    })
    local got
    local id = w:request("nvim_eval", { "1+1" }, function(slot)
      got = { ok = slot.ok, result = slot.result }
    end)
    ok(id ~= nil, "wire: the request was sent")
    w:feed(vim.mpack.encode({ 1, id, vim.NIL, 2 }))
    eq(got, { ok = true, result = 2 }, "wire: the callback runs with the answer")

    local failed
    local id2 = w:request("nvim_eval", { "bad" }, function(slot)
      failed = slot.err and slot.err.message
    end)
    w:feed(vim.mpack.encode({ 1, id2, { 0, "boom" }, vim.NIL }))
    eq(failed, "boom", "wire: an error answer reaches the callback too")

    -- the blocking path is unchanged: no callback, the slot is simply done
    local id3 = assert(w:request("nvim_eval", { "3" }))
    w:feed(vim.mpack.encode({ 1, id3, vim.NIL, 3 }))
    eq(w:take(id3).result, 3, "wire: a request without a callback still works")
  end

  S.run(function()
    -- ===================================================================
    -- spawn_async: the editor starts without blocking, the callback gets the child
    local started, err
    local t0 = vim.uv.hrtime()
    rpc.spawn_async({ root = S.repo, guard = false, trace_dir = S.new_dir() }, function(c, e)
      started, err = c, e
    end)
    local blocked_ms = (vim.uv.hrtime() - t0) / 1e6
    ok(started == nil, "spawn_async returns before the editor is up")
    ok(blocked_ms < 200, ("spawn_async does not wait for the boot (%.0f ms)"):format(blocked_ms))
    ok(
      S.wait(20000, function()
        return started ~= nil or err ~= nil
      end),
      "spawn_async: the callback ran"
    )
    ok(started ~= nil, "spawn_async: a child (" .. tostring(err) .. ")")
    local c = started --[[@as Testing.Rpc.Child]]
    ok(c.alive(), "the child runs")
    eq(c.boot_info().guard ~= nil, true, "the boot ran (boot_info)")

    -- ===================================================================
    -- exec_async: result and error arrive through the callback, the caller is not blocked
    local res
    c.exec_async("local a, b = ...; return a + b", { 2, 3 }, function(okk, r)
      res = { ok = okk, result = r }
    end)
    ok(res == nil, "exec_async returns at once")
    ok(
      S.wait(5000, function()
        return res ~= nil
      end),
      "exec_async: the callback ran"
    )
    eq(res, { ok = true, result = 5 }, "exec_async: the result")

    local bad
    c.exec_async("error('nope')", {}, function(okk, r)
      bad = { ok = okk, result = r }
    end)
    S.wait(5000, function()
      return bad ~= nil
    end)
    eq(bad.ok, false, "exec_async: a Lua error in the child is ok = false")
    has(bad.result, "nope", "exec_async: and says what it was")
    ok(c.alive(), "the child survives a Lua error")

    -- a long call keeps the main loop free: a timer fires while the child is busy
    local ticks, long = 0, nil
    local timer = vim.uv.new_timer()
    timer:start(0, 20, function()
      ticks = ticks + 1
    end)
    c.exec_async("vim.uv.sleep(300); return 'slept'", {}, function(okk, r)
      long = { ok = okk, result = r }
    end)
    S.wait(5000, function()
      return long ~= nil
    end)
    timer:stop()
    timer:close()
    eq(long, { ok = true, result = "slept" }, "exec_async: a slow call completes")
    ok(ticks >= 5, ("the parent's loop kept running during the call (%d ticks)"):format(ticks))

    -- ===================================================================
    -- a process that dies while a call is pending completes the call (never a hang)
    local dead
    c.exec_async("vim.uv.sleep(60000)", {}, function(okk, r)
      dead = { ok = okk, result = r }
    end)
    vim.wait(100)
    ok(dead == nil, "the call is pending")
    local proc = c.proc()
    ok(proc and proc.pid == c.pid, "proc() is the process handle")
    require("testing.child").kill_tree(proc)
    ok(
      S.wait(15000, function()
        return dead ~= nil
      end),
      "the pending call completed when the process died"
    )
    eq(dead.ok, false, "dead: ok = false")
    has(dead.result, "child died", "dead: the death message")
    has(c.death_text(), "", "death_text() is a string")

    -- a call on a dead child fails asynchronously too
    local after
    c.exec_async("return 1", {}, function(okk, r)
      after = { ok = okk, result = r }
    end)
    S.wait(5000, function()
      return after ~= nil
    end)
    eq(after.ok, false, "a call on a dead child fails")
    has(after.result, "child died", "and says so")
    c.kill()

    -- ===================================================================
    -- a start that cannot succeed reports to the callback, not by raising
    local e2, c2
    rpc.spawn_async({
      root = S.repo,
      guard = false,
      trace_dir = S.new_dir(),
      nvim = S.repo .. "/does-not-exist.exe",
    }, function(cc, ee)
      c2, e2 = cc, ee
    end)
    ok(
      S.wait(15000, function()
        return c2 ~= nil or e2 ~= nil
      end),
      "a bad executable: the callback ran"
    )
    ok(c2 == nil and type(e2) == "string", "a bad executable: an error string")
  end)
end
