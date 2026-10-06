-- TESTS/testing/timeout_suspend_spec.lua -- `Guard:suspend`: the runner's own bookkeeping after a case (what the guard layer checks)
-- is not cut off by the deadline the spec has just exceeded; the deadline is still there afterwards.

return function(H)
  local ok, eq = H.ok, H.eq
  local timeout = require("testing.run.timeout")

  local function busy()
    local x = 0
    for i = 1, 400000 do
      x = x + i
    end
    return x
  end

  local g = timeout.start({ label = "suspend", file_ms = 30 })
  vim.uv.sleep(80) -- C code: nothing interrupts it, the deadline has passed when it returns

  local worked, a, b = pcall(g.suspend, g, function()
    return busy(), "second"
  end)
  ok(worked, "suspended work is not stopped by the passed deadline: " .. tostring(a))
  ok(type(a) == "number" and b == "second", "suspend returns the results of the function")

  local failed, err = pcall(g.suspend, g, function()
    error("boom", 0)
  end)
  ok(not failed and err == "boom", "an error of the function is raised again")

  -- the deadline is persistent: the spec is stopped again as soon as the bookkeeping is over
  local raised, message = pcall(busy)
  ok(not raised, "the deadline stops the spec again after suspend")
  ok(timeout.is_timeout(message), "...with the timeout error: " .. tostring(message))
  eq(g:stop(), true, "the file deadline is reported as fired")
  eq(g:stop(), true, "stop is idempotent")

  -- a guard that was stopped inside suspend does not get its deadlines back
  local g2 = timeout.start({ label = "stopped inside", file_ms = 100000 })
  g2:suspend(function()
    g2:stop()
  end)
  ok(g2.file_deadline == nil and g2.stopped, "a guard stopped inside suspend stays stopped")
end
