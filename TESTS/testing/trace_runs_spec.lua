-- TESTS/testing/trace_runs_spec.lua -- the trace artifacts of a run live in a folder of their own
-- (`<state>/testing-traces/<run-id>/`): another run's artifacts are never pruned while they are young, only
-- whole old run folders go, and two artifacts of the same pid never overwrite each other.

-- @cache-allow time
-- (ages are built relative to now (a run folder N seconds old): the result does not depend on the time of day)
return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local isolated = require("testing.run.isolated")

  local base = S.new_root() .. "/testing-traces"
  vim.fn.mkdir(base, "p")
  local now = os.time()
  local function make_run(name, age_s)
    local d = base .. "/" .. name
    S.write(d .. "/x_spec_lua-1.trace.json", "{}")
    vim.uv.fs_utime(d .. "/x_spec_lua-1.trace.json", now - age_s, now - age_s)
    vim.uv.fs_utime(d, now - age_s, now - age_s)
  end
  make_run("20200101-000000-111", 30 * 24 * 3600) -- an old run
  make_run("20990101-000000-222", 60) -- another run that is going right now
  make_run("20200102-000000-333", 3600) -- a young run
  S.write(base .. "/notes/keep.txt", "not a run folder")

  local frag = { cases = {}, progress = {}, bad_lines = 0, missing = false }
  local function write()
    return isolated.write_trace({
      base = base,
      root = base,
      rel = "TESTS/x_spec.lua",
      reason = "timeout",
      ---@diagnostic disable-next-line: missing-fields
      h = { pid = 4242, exit = { code = 1 } },
      frag = frag,
      describe = "exit code 1",
      err = "boom",
    })
  end
  local a, b = assert(write()), assert(write())
  ok(a.path ~= b.path, "two artifacts of the same pid do not overwrite each other")
  ok(
    a.path:find("/" .. isolated.run_id() .. "/", 1, true) ~= nil,
    "the artifact is in this run's folder: " .. tostring(a.path)
  )
  eq(
    vim.fn.isdirectory(base .. "/20200101-000000-111"),
    0,
    "a run folder older than a week is gone"
  )
  eq(
    vim.fn.isdirectory(base .. "/20990101-000000-222"),
    1,
    "the folder of another, running run is untouched"
  )
  eq(vim.fn.isdirectory(base .. "/20200102-000000-333"), 1, "and so is a young one")
  eq(
    vim.fn.isdirectory(base .. "/notes"),
    1,
    "a folder that is not named like a run is never touched"
  )
  S.cleanup()
end
