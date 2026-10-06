-- TESTS/testing/pool_unit_spec.lua -- `testing.run.pool` with fake editors: the lending rules (size, FIFO waiters,
-- reuse, discard, a failed start, shutdown) without a single real process.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local pool_mod = require("testing.run.pool")

  ---A fake `testing.rpc`: `spawn_async` hands out fake children; `fail` makes the next start fail.
  ---@return table rpc
  ---@return table log
  local function fake_rpc()
    local log = { started = 0, killed = {}, init_calls = 0, fail = 0, children = {} }
    local rpc = {}
    function rpc.spawn_async(_, cb)
      log.started = log.started + 1
      local n = log.started
      vim.schedule(function()
        if log.fail > 0 then
          log.fail = log.fail - 1
          cb(nil, "no editor " .. n)
          return
        end
        local child = { sandbox = "/fake/" .. n, up = true, id = n }
        function child.alive()
          return child.up
        end
        function child.kill()
          child.up = false
          log.killed[#log.killed + 1] = n
        end
        function child.proc()
          -- `ended`: the pool's shutdown does not try to kill a process tree of a fake
          return { ended = true, exited = not child.up }
        end
        function child.exec_async(code, args, done)
          if code:find("init", 1, true) then
            log.init_calls = log.init_calls + 1
          end
          vim.schedule(function()
            done(true, true)
          end)
        end
        log.children[n] = child
        cb(child, nil)
      end)
    end
    return rpc, log
  end

  ---Wait until `cond()`.
  local function wait(cond)
    vim.wait(2000, cond, 5)
    ok(cond(), "the pool answered in time")
  end

  -- ===================================================================
  -- size: at most `size` editors; the third caller waits and gets the first one that is given back
  do
    local rpc, log = fake_rpc()
    local pool = pool_mod.new({ size = 2, rpc = rpc, spawn_opts = {} })
    local got = {}
    for i = 1, 3 do
      pool:acquire(function(m, err)
        got[i] = m or err
      end)
    end
    wait(function()
      return got[1] ~= nil and got[2] ~= nil
    end)
    eq(log.started, 2, "size 2: two editors started")
    ok(got[3] == nil, "size 2: the third caller waits")
    eq(log.init_calls, 2, "every member is set up once (pool_boot.init)")
    pool:release(got[1])
    wait(function()
      return got[3] ~= nil
    end)
    eq(got[3], got[1], "the waiter got the member that was given back (reuse)")
    eq(log.started, 2, "reuse needs no new editor")
    eq(pool.stats.reused, 0, "stats: the first release was of a member's first file")
    pool:release(got[3])
    pool:acquire(function(m)
      got[4] = m
    end)
    wait(function()
      return got[4] ~= nil
    end)
    eq(pool.stats.reused, 1, "stats: the second file of a member counts as reused")
    pool:shutdown()
  end

  -- ===================================================================
  -- a reason discards the member (killed), the waiter gets a NEW editor
  do
    local rpc, log = fake_rpc()
    local pool = pool_mod.new({ size = 1, rpc = rpc, spawn_opts = {} })
    local got = {}
    pool:acquire(function(m)
      got[1] = m
    end)
    wait(function()
      return got[1] ~= nil
    end)
    pool:acquire(function(m)
      got[2] = m
    end)
    pool:release(got[1], "it leaks")
    wait(function()
      return got[2] ~= nil
    end)
    ok(got[2] ~= got[1], "discard: the next caller does not get the discarded member")
    eq(log.killed, { 1 }, "discard: the member was killed")
    eq(log.started, 2, "discard: a new editor was started")
    eq(pool.stats.discarded, 1, "stats: one discarded")
    pool:shutdown()
    eq(log.killed, { 1, 2 }, "shutdown kills what is left")
  end

  -- ===================================================================
  -- a member that died by itself is not lent out again
  do
    local rpc, log = fake_rpc()
    local pool = pool_mod.new({ size = 1, rpc = rpc, spawn_opts = {} })
    local m
    pool:acquire(function(x)
      m = x
    end)
    wait(function()
      return m ~= nil
    end)
    log.children[1].up = false -- it died while it was out
    pool:release(m)
    eq(pool.stats.discarded, 1, "a dead member is discarded, not reused")
    eq(#pool.idle, 0, "and not kept idle")
    pool:shutdown()
  end

  -- ===================================================================
  -- a failed start is reported to its caller; the next caller tries again
  do
    local rpc, log = fake_rpc()
    log.fail = 1
    local pool = pool_mod.new({ size = 1, rpc = rpc, spawn_opts = {} })
    local first, ferr
    pool:acquire(function(m, err)
      first, ferr = m, err
    end)
    wait(function()
      return first ~= nil or ferr ~= nil
    end)
    ok(first == nil and ferr == "no editor 1", "a failed start is an error for its caller")
    eq(pool.stats.failed_starts, 1, "stats: one failed start")
    local second
    pool:acquire(function(m)
      second = m
    end)
    wait(function()
      return second ~= nil
    end)
    ok(second ~= nil, "the pool recovers: the next start works")
    pool:shutdown()
  end

  -- ===================================================================
  -- a closed pool serves nobody
  do
    local rpc = fake_rpc()
    local pool = pool_mod.new({ size = 1, rpc = rpc, spawn_opts = {} })
    pool:shutdown()
    local answered, m, err = false, nil, nil
    pool:acquire(function(x, e)
      answered, m, err = true, x, e
    end)
    wait(function()
      return answered
    end)
    ok(m == nil and err == "the pool is closed", "acquire on a closed pool is an error")
  end
end
