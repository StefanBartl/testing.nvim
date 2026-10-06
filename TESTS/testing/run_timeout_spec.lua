-- TESTS/testing/run_timeout_spec.lua -- the in-process timeout guard: a spec that spins or waits
-- forever is stopped (count hook + vim.wait clamp), the machinery is restored afterwards, the case
-- deadline is one-shot and re-armed, the file deadline is persistent, guards nest. The clock is
-- injected where the test must not depend on real time.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local timeout = require("testing.run.timeout")
  local hr = function()
    return vim.uv.hrtime() / 1e6
  end

  -- this spec may itself run under a guard (the project's own runner): measure against that
  local base_depth = timeout.depth()
  local hook_before, mask_before, count_before = debug.gethook()
  local wait_before = vim.wait
  local jit_before = jit and jit.status()

  local function restored(label)
    eq(timeout.depth(), base_depth, label .. ": no guard left behind")
    local hook, mask, count = debug.gethook()
    eq(
      { hook, mask, count },
      { hook_before, mask_before, count_before },
      label .. ": hook restored"
    )
    ok(vim.wait == wait_before, label .. ": vim.wait restored")
    eq(jit and jit.status(), jit_before, label .. ": the JIT state is restored")
  end

  -- a Lua loop that never ends is stopped, with the marker, within a bounded time
  local t0 = hr()
  local g = timeout.start({ file_ms = 100, label = "spin.lua" })
  local pok, perr = pcall(function()
    local x = 0
    while true do
      x = x + 1
    end
  end)
  local fired = g:stop()
  eq(pok, false, "a spinning loop raises")
  has(perr, timeout.MARKER, "the error carries the marker")
  has(perr, "file exceeded 100 ms", "and says which deadline")
  has(perr, "spin.lua", "and what was guarded")
  ok(timeout.is_timeout(perr), "is_timeout recognizes it")
  eq(fired, true, "stop() reports that the file deadline fired")
  ok(hr() - t0 < 5000, "within a bounded time, not after the loop finished by itself")
  restored("after a spin")

  -- calls and string work are interrupted too (not only an empty loop)
  g = timeout.start({ file_ms = 100, label = "calls" })
  pok, perr = pcall(function()
    local function f(a)
      return a + 1
    end
    local x = 0
    while true do
      local s = ("x"):rep(8) .. x
      x = f(x) + #s - #s
    end
  end)
  g:stop()
  eq(pok, false, "calls and string work are interrupted")
  has(perr, timeout.MARKER, "marker")
  restored("after call heavy work")

  -- a deadline that has not passed does not fire; a guard without deadlines never does
  g = timeout.start({ file_ms = 60000, label = "roomy" })
  pok = pcall(function()
    local x = 0
    for i = 1, 200000 do
      x = x + i
    end
    return x
  end)
  eq(g:stop(), false, "no fire inside the budget")
  eq(pok, true, "work inside the budget runs through")
  g = timeout.start({ label = "no deadline" })
  local quiet = pcall(function()
    for _ = 1, 100000 do
      local _ = 1
    end
  end)
  eq(g:stop(), false, "a guard without deadlines never fires")
  eq(quiet, true, "and its work runs through")
  restored("after quiet guards")

  -- deterministic with an injected clock: the deadline passes by the clock, not by waiting
  local now = 0
  g = timeout.start({
    file_ms = 1000,
    label = "fake clock",
    clock = function()
      return now
    end,
  })
  pok = pcall(function()
    for i = 1, 30000 do
      if i == 15000 then
        now = 5000
      end
    end
  end)
  eq(pok, false, "the injected clock decides")
  eq(g:stop(), true, "fired by the fake clock")
  restored("after the fake clock")

  -- vim.wait that can never succeed: clamped to the deadline, then raises
  t0 = hr()
  g = timeout.start({ file_ms = 150, label = "wait.lua" })
  pok, perr = pcall(function()
    vim.wait(60000, function()
      return false
    end, 10)
  end)
  g:stop()
  eq(pok, false, "a hopeless vim.wait raises")
  has(perr, timeout.MARKER, "marker")
  ok(hr() - t0 < 5000, "after the deadline, not after 60 s")
  restored("after a wait")

  -- a wait that succeeds in time is untouched, and returns what vim.wait returns
  g = timeout.start({ file_ms = 60000, label = "wait ok" })
  local flag = false
  vim.defer_fn(function()
    flag = true
  end, 20)
  local wok, wcode = vim.wait(5000, function()
    return flag
  end, 5)
  g:stop()
  eq({ wok, wcode }, { true, nil }, "a successful wait returns what vim.wait returns")
  restored("after a good wait")

  -- the file deadline is persistent: a spec that swallows the error with pcall is stopped again
  g = timeout.start({ file_ms = 80, label = "swallow" })
  local first = pcall(function()
    while true do
    end
  end)
  local second = pcall(function()
    while true do
    end
  end)
  eq(g:stop(), true, "fired")
  eq({ first, second }, { false, false }, "the second loop is stopped as well")
  restored("after swallowing")

  -- the case deadline is one-shot and re-armed
  g = timeout.start({ case_ms = 80, label = "cases" })
  pok = pcall(function()
    while true do
    end
  end)
  eq(pok, false, "the case deadline stops the case")
  eq(g:take_case(), true, "take_case reports it")
  eq(g:take_case(), false, "and only once")
  local until_t = hr() + 250
  pok = pcall(function()
    while hr() < until_t do
    end
  end)
  eq(
    pok,
    true,
    "after a fire the case deadline is off until it is re-armed (no raise in the bookkeeping)"
  )
  g:arm_case()
  pok = pcall(function()
    while true do
    end
  end)
  eq(pok, false, "re-armed, the next case is guarded again")
  eq(g:stop(), false, "a case timeout is not a file timeout")
  restored("after cases")

  -- guards nest: the inner one fires, the outer one survives it
  local outer = timeout.start({ file_ms = 60000, label = "outer" })
  local inner = timeout.start({ file_ms = 80, label = "inner" })
  local nested_ok, nested_err = pcall(function()
    while true do
    end
  end)
  eq(nested_ok, false, "the inner guard stops the loop")
  eq(inner:stop(), true, "the inner guard fired")
  has(nested_err, "inner", "and it is the inner label that is reported")
  eq(timeout.depth(), base_depth + 1, "the outer guard is still active")
  ok(debug.gethook() ~= nil, "and the hook is still installed")
  eq(outer:stop(), false, "the outer one did not fire")
  restored("after nesting")

  -- stop is idempotent
  g = timeout.start({ file_ms = 1000 })
  g:stop()
  g:stop()
  restored("after a double stop")

  -- a spec that stubs `vim.uv.hrtime` (first call 0, then far in the future) must not make the
  -- guard fire: the default clock is bound at load time and the hook never reads `vim.uv`
  do
    local real_hrtime = vim.uv.hrtime
    local real_count = timeout.HOOK_COUNT
    local stub_first = true
    timeout.HOOK_COUNT = 100
    vim.uv.hrtime = function()
      if stub_first then
        stub_first = false
        return 0
      end
      return 1e12
    end
    g = timeout.start({ file_ms = 60000, case_ms = 60000, label = "stubbed clock" })
    pok, perr = pcall(function()
      local x = 0
      for i = 1, 200000 do
        x = x + i
      end
      g:arm_case()
      return x
    end)
    vim.uv.hrtime = real_hrtime
    timeout.HOOK_COUNT = real_count
    local fired_stub = g:stop()
    ok(pok, "a stubbed vim.uv.hrtime does not raise a timeout (got " .. tostring(perr) .. ")")
    eq(fired_stub, false, "and the file deadline did not fire")
    ok(vim.uv.hrtime == real_hrtime, "the stub was removed again")
    restored("after a stubbed clock")
  end
end
