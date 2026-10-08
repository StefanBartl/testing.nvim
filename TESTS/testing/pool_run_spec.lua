---@diagnostic disable: need-check-nil
-- TESTS/testing/pool_run_spec.lua -- the WARM POOL with real editors (`testing.run.pool`, `testing.child.pool_boot`,
-- `testing.run.isolated` with `pool.reuse`), the lifecycle of a member: files run one after the other in a member,
-- none sees the litter of another, what a file writes below stdpath() does not survive it, the verdict is the one a
-- child per file gives, a crash or a timeout kills only its member and the next file gets a new one. The rest of the
-- pool is in the pool_run_*_spec files next to it (reset and verification, the member as an editor and the driver
-- around it, the order across pool sizes): real editors are slow on a busy machine, so the specs are several files,
-- each well inside the file deadline of the project.

-- @cache-env LC_ALL NVIM TZ
-- (the variables the child environment of the pool run is built from: their values join the key)
return function(H)
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local P = dofile(dir .. "/pool_run_support.lua")(H)
  local ok, eq, has, S, run, findings, leaky_files, statuses =
    P.ok, P.eq, P.has, P.S, P.run, P.findings, P.leaky_files, P.statuses

  -- ===================================================================
  -- 1. ONE member runs six files that litter the editor; none of them sees the litter of another
  do
    local files, order = leaky_files(6)
    local rep = run(files, order, { size = 1 })
    local expected = {}
    for _, rel in ipairs(order) do
      expected[#expected + 1] = rel .. ":pass"
    end
    eq(statuses(rep), expected, "pool: every file passes and sees a clean editor")
    ok(rep.pool ~= nil, "the report carries the pool statistics")
    eq(rep.pool.spawned, 1, "pool: ONE editor was started for six files")
    eq(rep.pool.reused, 5, "pool: five files reused it")
    eq(rep.pool.discarded, 0, "pool: nothing had to be discarded")
    eq(#findings(rep, "pool"), 0, "pool: no discard finding")

    -- the control: a child per file gives the same verdict (the pool is a speed-up, not another judge)
    local ctrl = run(files, order, { reuse = false })
    eq(statuses(ctrl), expected, "control: a child per file, the same verdict")
    ok(ctrl.pool == nil, "control: no pool, no pool statistics")
  end

  -- ===================================================================
  -- 2. a crash kills ONLY its member: the next file gets a new one, the files before it are untouched
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/b_spec.lua"] = "return function(H) H.ok(true, 'b') end",
      ["TESTS/c_spec.lua"] = "return function(H) vim.cmd('cquit 3') end",
      ["TESTS/d_spec.lua"] = "return function(H) H.ok(true, 'd') end",
      ["TESTS/e_spec.lua"] = "return function(H) H.ok(true, 'e') end",
    }
    local order = {
      "TESTS/a_spec.lua",
      "TESTS/b_spec.lua",
      "TESTS/c_spec.lua",
      "TESTS/d_spec.lua",
      "TESTS/e_spec.lua",
    }
    local rep, root = run(files, order, { size = 1 })
    eq(statuses(rep), {
      "TESTS/a_spec.lua:pass",
      "TESTS/b_spec.lua:pass",
      "TESTS/c_spec.lua:crash",
      "TESTS/d_spec.lua:pass",
      "TESTS/e_spec.lua:pass",
    }, "crash: only the file that crashed is red")
    eq(rep.pool.spawned, 2, "crash: a second member took over after the crash")
    eq(rep.pool.discarded, 1, "crash: exactly the member that crashed was discarded")
    local c = S.case_of(rep, "TESTS/c_spec.lua")
    has(c.error.message, "exit code 3", "crash: the exit code is named")
    local artifact = c.artifacts[1]
    ok(artifact and artifact.kind == "trace", "crash: the case carries a trace artifact")
    local path = artifact.path:gsub("^<TMP>", vim.fs.dirname(vim.fn.tempname()))
    local trace_dir = root .. "/traces"
    local found
    for name in vim.fs.dir(trace_dir) do
      found = name
    end
    ok(
      found ~= nil and found:find("%.trace%.json$") ~= nil,
      "crash: the trace file is on disk (" .. tostring(path) .. ")"
    )
    local trace = vim.json.decode(S.slurp(trace_dir .. "/" .. found) --[[@as string]])
    eq(trace.reason, "crash", "crash: the trace says why it was written")
    ok(#trace.calls >= 3, "crash: the trace holds the calls of the member (boot, init, the file)")
  end

  -- ===================================================================
  -- 2b. the cases a file finished BEFORE its member died are kept (the member's sandbox is gone with its
  --     process; the records are not in it)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[describe("dies", function()
  it("one", function() assert.is_true(true) end)
  it("two", function() assert.is_true(true) end)
  it("three", function() vim.cmd("cquit 3") end)
end)]==],
      ["TESTS/b_spec.lua"] = [==[describe("after", function()
  it("still runs in a new member", function() assert.is_true(true) end)
end)]==],
    }
    local rep = run(
      files,
      { "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
      { size = 1, dialect = "busted" }
    )
    local got = {}
    for _, c in ipairs(rep.result.cases) do
      got[#got + 1] = c.id:match("::(.-)$") .. ":" .. c.status
    end
    ok(
      vim.tbl_contains(got, "dies::one:pass") and vim.tbl_contains(got, "dies::two:pass"),
      "crash mid-file: the cases that finished are kept: " .. vim.inspect(got)
    )
    local crashed = false
    for _, c in ipairs(rep.result.cases) do
      crashed = crashed or (c.file == "TESTS/a_spec.lua" and c.status == "crash")
    end
    ok(crashed, "crash mid-file: and the file ends in a crash case: " .. vim.inspect(got))
    ok(
      vim.tbl_contains(got, "after::still runs in a new member:pass"),
      "the next file ran in a new member"
    )
    eq(rep.pool.spawned, 2, "crash mid-file: a new member for the next file")
  end

  -- ===================================================================
  -- 3. a file that hangs in C (the file's own best-effort guard cannot interrupt it) is a timeout, killed
  --    with its member; the next file is not delayed by it
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/b_spec.lua"] = "return function(H) vim.uv.sleep(120000) end",
      ["TESTS/c_spec.lua"] = "return function(H) H.ok(true, 'c') end",
    }
    local order = { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" }
    local rep, root = run(files, order, {
      size = 1,
      extra = { timeouts = { file_ms = 1500 }, grace_ms = 300 },
    })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:timeout", "TESTS/c_spec.lua:pass" },
      "timeout: only the hung file is red"
    )
    eq(rep.pool.discarded, 1, "timeout: the member that hung was discarded")
    eq(rep.pool.spawned, 2, "timeout: the next file got a new member")
    local b = S.case_of(rep, "TESTS/b_spec.lua")
    has(b.error.message, "process tree was killed", "timeout: killed from outside")
    ok(b.artifacts[1] and b.artifacts[1].kind == "trace", "timeout: a trace artifact")
    local n = 0
    for name in vim.fs.dir(root .. "/traces") do
      if name:find("%.trace%.json$") then
        n = n + 1
      end
    end
    eq(n, 1, "timeout: one trace file")
  end

  -- ===================================================================
  -- 6. what a file writes below stdpath() does not survive it (a respawned child loses its sandbox)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  local dir = vim.fn.stdpath("data") .. "/leakdir"
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/x.txt", "wb"))
  f:write("x")
  f:close()
  vim.fn.mkdir(vim.fn.stdpath("state") .. "/sub", "p")
  H.ok(vim.uv.fs_stat(dir .. "/x.txt") ~= nil, "a wrote below stdpath('data')")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  H.ok(vim.uv.fs_stat(vim.fn.stdpath("data") .. "/leakdir/x.txt") == nil, "b does not see the file of a")
  H.ok(vim.uv.fs_stat(vim.fn.stdpath("state") .. "/sub") == nil, "b does not see the directory of a")
end]==],
    }
    local rep = run(files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }, { size = 1 })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass" },
      "sandbox: emptied between files"
    )
    eq(rep.pool.spawned, 1, "sandbox: cleaning it needed no new member")
  end

  S.cleanup()
end
