---@diagnostic disable: need-check-nil
-- TESTS/testing/pool_run_order_spec.lua -- the WARM POOL with real editors: the same files give the same verdicts and
-- the same ORDER whatever the pool size and the number of jobs (and the same as a child per file). Four runs of five
-- files that litter the editor: the heaviest block of the pool specs, so it has a file of its own.

-- @cache-env LC_ALL NVIM TZ
-- (the variables the child environment of the pool run is built from: their values join the key)
return function(H)
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local P = dofile(dir .. "/pool_run_support.lua")(H)
  local eq, S, run, leaky_files, statuses = P.eq, P.S, P.run, P.leaky_files, P.statuses

  -- ===================================================================
  -- 10. the same files, the same verdicts and the same ORDER whatever the pool size and the jobs
  do
    local files, order = leaky_files(5)
    local expected
    for _, c in ipairs({
      { size = 1, jobs = 1 },
      { size = 2, jobs = 3 },
      { size = 3, jobs = 3 },
      { reuse = false, jobs = 3 },
    }) do
      local rep = run(files, order, c)
      local got = statuses(rep)
      expected = expected or got
      eq(
        got,
        expected,
        ("pool size=%s jobs=%s reuse=%s: same IR order and verdicts"):format(
          tostring(c.size),
          tostring(c.jobs),
          tostring(c.reuse)
        )
      )
    end
  end

  S.cleanup()
end
