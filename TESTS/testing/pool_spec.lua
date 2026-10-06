-- TESTS/testing/pool_spec.lua -- the pool of child editors: `jobs` children at once on a
-- lib.nvim.async.Semaphore, results merged in FILE order whatever order the children finish in, the
-- terminal output in the same order, a failing / crashing / hanging child never aborts the others,
-- `--maxfail` is decided on the merged order and kills what is still running.

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

  -- ===================================================================
  -- the primitive: Semaphore:with (lib.nvim commit 89cb912) limits, is FIFO and releases on error
  local async = require("lib.nvim.async")
  do
    local sem = async.Semaphore.new(2)
    local running, peak, order, done = 0, 0, {}, 0
    for i = 1, 5 do
      async.run(function()
        local sok = sem:with(function()
          running = running + 1
          peak = math.max(peak, running)
          order[#order + 1] = i
          async.await(function(resume)
            vim.defer_fn(resume, 20)
          end)
          running = running - 1
          if i == 2 then
            error("body " .. i .. " failed")
          end
        end)
        eq(sok, i ~= 2, "body " .. i .. ": with() reports whether the body threw")
        done = done + 1
      end)
    end
    vim.wait(5000, function()
      return done == 5
    end, 10)
    eq(done, 5, "all five bodies ran, the failing one did not starve the rest")
    eq(peak, 2, "at most two ran at once")
    eq(order, { 1, 2, 3, 4, 5 }, "permits are handed out first come, first served")
    eq(sem.permits, 2, "every permit is back, also the one of the body that threw")
  end

  -- ===================================================================
  -- a project whose files finish in REVERSE order
  local N = 6
  ---@param extra? table<integer, string> Body of file `i` (replaces the default).
  ---@return table files
  ---@return string[] order
  local function files_of(extra)
    local files, order = {}, {}
    for i = 1, N do
      local rel = ("TESTS/f%d_spec.lua"):format(i)
      order[#order + 1] = rel
      files[rel] = (extra or {})[i]
        or ([==[
return function(H)
  local sec, usec = vim.uv.gettimeofday()
  local start = sec * 1000 + math.floor(usec / 1000)
  vim.uv.sleep(%d)
  local sec2, usec2 = vim.uv.gettimeofday()
  local f = assert(io.open("t%d.txt", "wb"))
  f:write(start, " ", sec2 * 1000 + math.floor(usec2 / 1000), "\n")
  f:close()
  print("output of file %d")
  H.ok(true, "f%d")
end
]==]):format((N - i + 1) * 120, i, i, i)
    end
    return files, order
  end

  ---@param root string
  ---@return { s: integer, e: integer }[]
  local function intervals(root)
    local out = {}
    for i = 1, N do
      local text = S.slurp(root .. ("/t%d.txt"):format(i))
      if text then
        local s, e = text:match("(%d+) (%d+)")
        out[#out + 1] = { s = tonumber(s), e = tonumber(e) }
      end
    end
    return out
  end

  ---@param iv { s: integer, e: integer }[]
  ---@return integer
  local function peak_overlap(iv)
    local peak = 0
    for _, a in ipairs(iv) do
      local n = 0
      for _, b in ipairs(iv) do
        if b.s <= a.s and a.s < b.e then
          n = n + 1
        end
      end
      peak = math.max(peak, n)
    end
    return peak
  end

  local tmp_base = vim.fs.normalize(vim.fs.dirname(vim.fn.tempname()))
  local function sandboxes()
    local n = 0
    for name in vim.fs.dir(tmp_base) do
      if name:find("^testing%-child%-") then
        n = n + 1
      end
    end
    return n
  end
  local sandboxes_before = sandboxes()

  local function run_with(jobs, extra_files)
    local root = S.new_root()
    local files, order = files_of(extra_files)
    local entries = S.project(root, files, order)
    local printed = {}
    local oncase = {}
    local rep = S.run(root, entries, {
      options = { jobs = jobs },
      timeouts = { file_ms = 20000 },
      on_output = function(rel, text)
        printed[#printed + 1] = rel .. "|" .. vim.trim(text)
      end,
      on_case = function(case)
        oncase[#oncase + 1] = case.file
      end,
    })
    return rep, root, order, printed, oncase
  end

  local rep1, root1, order, printed1, oncase1 = run_with(1)
  local rep3, root3, _, printed3, oncase3 = run_with(3)

  local expected = {}
  for _, rel in ipairs(order) do
    expected[#expected + 1] = rel .. ":pass"
  end
  eq(S.statuses(rep1), expected, "jobs = 1: cases in file order")
  eq(
    S.statuses(rep3),
    expected,
    "jobs = 3: cases in file order although the last file finishes first"
  )
  local function ids(rep)
    local out = {}
    for _, c in ipairs(rep.result.cases) do
      out[#out + 1] = c.id
    end
    return out
  end
  eq(ids(rep3), ids(rep1), "the same case ids in the same order for jobs 1 and 3")
  eq(rep1.result.run.jobs, 1, "the IR header says jobs = 1")
  eq(rep3.result.run.jobs, 3, "the IR header says jobs = 3")

  local printed_expected = {}
  for i, rel in ipairs(order) do
    printed_expected[i] = rel .. "|output of file " .. i
  end
  eq(printed1, printed_expected, "jobs = 1: the child output arrives in file order")
  eq(printed3, printed_expected, "jobs = 3: the child output arrives in file order too")
  eq(oncase3, order, "the progress hook sees the cases in file order")
  eq(oncase1, order, "also for jobs = 1")

  local iv1, iv3 = intervals(root1), intervals(root3)
  eq(#iv1, N, "jobs = 1 ran all files")
  eq(#iv3, N, "jobs = 3 ran all files")
  eq(peak_overlap(iv1), 1, "jobs = 1: never two children at once")
  local peak3 = peak_overlap(iv3)
  ok(peak3 >= 2, "jobs = 3: children really overlap (peak " .. peak3 .. ")")
  ok(peak3 <= 3, "jobs = 3: never more than 3 at once (peak " .. peak3 .. ")")

  -- ===================================================================
  -- a failing / crashing / hanging child never aborts the others; order and verdicts are stable
  local mixed = {
    [2] = 'return function(H) H.eq(1, 2, "red") end\n',
    [3] = [==[
return function(H)
  H.ok(true, "x")
  require("ffi").cast("int*", 0)[0] = 1
end
]==],
    [4] = "return function(H) vim.uv.sleep(600000) end\n",
    [5] = 'return function(H) error("raised") end\n',
  }
  local want_mixed = {
    "TESTS/f1_spec.lua:pass",
    "TESTS/f2_spec.lua:fail",
    "TESTS/f3_spec.lua:crash",
    "TESTS/f4_spec.lua:timeout",
    "TESTS/f5_spec.lua:error",
    "TESTS/f6_spec.lua:pass",
  }
  for _, jobs in ipairs({ 1, 4 }) do
    local root = S.new_root()
    local files, o = files_of(mixed)
    local rep = S.run(root, S.project(root, files, o), {
      options = { jobs = jobs },
      timeouts = { file_ms = 1500 },
      grace_ms = 300,
    })
    eq(
      S.statuses(rep),
      want_mixed,
      "jobs = " .. jobs .. ": every file reports, the bad ones do not stop the rest"
    )
    eq(rep.exit_code, 1, "jobs = " .. jobs .. ": the run is red")
    eq(rep.failed, 4, "jobs = " .. jobs .. ": four red cases")
    eq(rep.failed_files, 4, "jobs = " .. jobs .. ": four red files")
    eq(rep.files_run, 6, "jobs = " .. jobs .. ": six files ran")
  end

  -- ===================================================================
  -- --maxfail is decided on the merged order; running children are killed, nothing is left
  do
    local root = S.new_root()
    local slow = [==[
return function(H)
  local f = assert(io.open("pid_" .. vim.fn.getpid() .. ".txt", "wb"))
  f:write("x")
  f:close()
  vim.uv.sleep(60000)
  H.ok(true, "never reached")
end
]==]
    local files, o = files_of({
      [1] = 'return function(H) H.ok(true, "first") end\n',
      [2] = 'return function(H) H.eq(1, 2, "red") end\n',
      [3] = slow,
      [4] = slow,
      [5] = slow,
      [6] = slow,
    })
    local t0 = vim.uv.hrtime()
    local rep = S.run(root, S.project(root, files, o), {
      options = { jobs = 3 },
      maxfail = 1,
      timeouts = { file_ms = 30000 },
    })
    local took = (vim.uv.hrtime() - t0) / 1e9
    eq(
      S.statuses(rep),
      { "TESTS/f1_spec.lua:pass", "TESTS/f2_spec.lua:fail" },
      "maxfail: the merged result ends at the failure, whatever else was running"
    )
    eq(rep.stopped, true, "the run says it stopped")
    eq(rep.files_unrun, 4, "four files were not run")
    ok(
      took < 20,
      "the slow children were killed, not waited for (" .. string.format("%.1f", took) .. " s)"
    )
    -- every child that started wrote its pid file; none may still be alive
    local alive = 0
    for name in vim.fs.dir(root) do
      local pid = name:match("^pid_(%d+)%.txt$")
      if pid and S.alive(tonumber(pid)) then
        alive = alive + 1
      end
    end
    eq(alive, 0, "no child is left running after a stop")
  end

  -- ===================================================================
  -- all sandboxes are gone
  eq(sandboxes(), sandboxes_before, "no sandbox directory is left behind")

  S.cleanup()
end
