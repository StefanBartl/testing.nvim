-- TESTS/testing/child_kill_windows_spec.lua -- the Windows branch of `testing.child.kill_tree`, driven on every
-- platform through `child.platform` and a stubbed `vim.system`: the process table (with the creation times) is read
-- BEFORE anything is killed, a failing `taskkill /T` falls back to killing the root at once, a process that `/T`
-- took is not looked at again (no `taskkill` start per descendant), and a descendant that `/T` left behind is ended
-- in ONE call, and only when a fresh table names the same process (a pid is handed out again soon after its
-- process ended).

-- @cache-allow spawn
-- (`vim.system` is replaced by a stub: no process starts)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local child = require("testing.child")

  ---Run `kill_tree` against a fake Windows; returns what was started.
  ---@param taskkill_code integer Exit code of `taskkill /T`.
  ---@param tables string[] The answers of the successive process table reads (the last one repeats).
  ---@param alive table<integer, true> The pids that still exist after `/T` (`vim.uv.kill(pid, 0)`).
  ---@return { calls: string[][], root_killed: boolean }
  local function drive(taskkill_code, tables, alive)
    local calls, root_killed, reads = {}, false, 0
    local real_system, real_process_kill, real_kill = vim.system, vim.uv.process_kill, vim.uv.kill
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv)
      calls[#calls + 1] = argv
      local code, out = 0, ""
      if argv[1] == "taskkill" then
        if argv[4] == "/T" then
          code = taskkill_code
        end
      else
        reads = reads + 1
        out = tables[math.min(reads, #tables)]
      end
      return {
        wait = function()
          return { code = code, stdout = out, stderr = "" }
        end,
      }
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.process_kill = function()
      root_killed = true
      return 0
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.uv.kill = function(pid)
      if alive[pid] then
        return 0
      end
      return nil, "ESRCH: no such process", "ESRCH"
    end
    child.platform.windows = true
    local handle = {
      pid = 100,
      ended = false,
      uv_handle = {
        is_closing = function()
          return false
        end,
      },
    }
    local pok, err = pcall(child.kill_tree, handle)
    child.platform.windows = vim.fn.has("win32") == 1
    vim.system, vim.uv.process_kill, vim.uv.kill = real_system, real_process_kill, real_kill
    ok(pok, "kill_tree does not raise: " .. tostring(err))
    return { calls = calls, root_killed = root_killed }
  end

  -- pid, parent pid, creation time (ms). 100 is the child; 200 and 300 hang below it; 400 is somebody else's;
  -- 500 names the pid 100 as its parent but is OLDER than 100: its real parent ended and its number went to the child.
  local TABLE = table.concat({
    "100 1 5000",
    "200 100 5100",
    "300 200 5200",
    "400 999 4000",
    "500 100 1000",
    "",
  }, "\n")

  local good = drive(0, { TABLE }, {})
  eq(good.calls[1][1], "powershell.exe", "the process table is read first, with an argv (no shell)")
  eq(
    good.calls[2],
    { "taskkill", "/PID", "100", "/T", "/F" },
    "then the tree is taken by taskkill /T"
  )
  eq(#good.calls, 2, "what /T took is not killed again: no taskkill start per descendant")
  eq(good.root_killed, false, "taskkill succeeded: the root is not killed a second time")

  -- a descendant that /T could not reach is ended with all the others in one call, after a fresh table named it
  local left = drive(0, { TABLE, TABLE }, { [200] = true, [300] = true })
  eq(#left.calls, 4, "table, /T, a fresh table, one taskkill")
  eq(left.calls[3][1], "powershell.exe", "the survivors are looked up in a fresh table first")
  eq(
    left.calls[4],
    { "taskkill", "/F", "/PID", "200", "/PID", "300" },
    "then ended in one call: the child's descendants, not 400 (unrelated) and not 500 (older than its parent)"
  )

  -- the number went to another process in the meantime (a new creation time): it is left alone
  local reused = drive(0, { TABLE, "100 1 5000\n200 100 9900\n300 200 5200\n" }, {
    [200] = true,
    [300] = true,
  })
  eq(
    reused.calls[4],
    { "taskkill", "/F", "/PID", "300" },
    "a pid that now belongs to a younger process is not killed"
  )

  -- the number is gone from the fresh table (the process ended meanwhile): nothing is started
  local gone = drive(0, { TABLE, "100 1 5000\n" }, { [200] = true })
  eq(#gone.calls, 3, "a survivor that has ended since is not killed: no third taskkill")

  -- the fresh table cannot be read: no identity, no kill (a process that stays is better than a stranger that goes)
  local blind = drive(0, { TABLE, "" }, { [200] = true })
  eq(#blind.calls, 3, "an unreadable fresh table: the survivor is left, nothing is guessed")

  local bad = drive(1, { TABLE }, {})
  eq(bad.root_killed, true, "taskkill /T failed (access denied): the root is killed at once")
  eq(#bad.calls, 2, "and nothing else is started for descendants that are gone")

  local no_table = drive(0, { "" }, { [200] = true })
  eq(#no_table.calls, 2, "no process table: only the tree kill acts, as before")
end
