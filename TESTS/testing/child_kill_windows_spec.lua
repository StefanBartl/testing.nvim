-- TESTS/testing/child_kill_windows_spec.lua -- the Windows branch of `testing.child.kill_tree`, driven on every
-- platform through `child.platform` and a stubbed `vim.system`: the process table is read BEFORE
-- anything is killed, a failing `taskkill /T` falls back to killing the root at once, and the
-- descendants that `/T` left behind are ended one by one.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local child = require("testing.child")

  ---Run `kill_tree` against a fake Windows with the given taskkill exit code; returns what was started.
  ---@param taskkill_code integer
  ---@param table_text string
  ---@return { calls: string[][], root_killed: boolean }
  local function drive(taskkill_code, table_text)
    local calls, root_killed = {}, false
    local real_system, real_process_kill = vim.system, vim.uv.process_kill
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(argv)
      calls[#calls + 1] = argv
      local code, out = 0, ""
      if argv[1] == "taskkill" and argv[4] == "/T" then
        code = taskkill_code
      elseif argv[1] ~= "taskkill" then
        out = table_text
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
    vim.system, vim.uv.process_kill = real_system, real_process_kill
    ok(pok, "kill_tree does not raise: " .. tostring(err))
    return { calls = calls, root_killed = root_killed }
  end

  local TABLE = "100 1\n200 100\n300 200\n400 999\n"

  local good = drive(0, TABLE)
  eq(good.calls[1][1], "powershell.exe", "the process table is read first, with an argv (no shell)")
  eq(
    good.calls[2],
    { "taskkill", "/PID", "100", "/T", "/F" },
    "then the tree is taken by taskkill /T"
  )
  eq(good.calls[3], { "taskkill", "/PID", "200", "/F" }, "a descendant is ended on its own")
  eq(good.calls[4], { "taskkill", "/PID", "300", "/F" }, "and its child too")
  eq(#good.calls, 4, "a process that is not below the child (400) is left alone")
  eq(good.root_killed, false, "taskkill succeeded: the root is not killed a second time")

  local bad = drive(1, TABLE)
  eq(bad.root_killed, true, "taskkill /T failed (access denied): the root is killed at once")
  eq(#bad.calls, 4, "and the descendants are still ended by pid")

  local no_table = drive(0, "")
  eq(#no_table.calls, 2, "no process table: only the tree kill acts, as before")
end
