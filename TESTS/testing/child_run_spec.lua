-- TESTS/testing/child_run_spec.lua -- REAL child editors (testing.run.isolated + testing.child): the
-- environment and the sandbox a spec sees, the host semantics (-c like plenary vs -l), stdin and
-- prompts, file isolation, crash classification, hard timeouts with a process-tree kill and no
-- leftover processes, self-running scripts. Windows-first: nothing here needs a POSIX tool.

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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")

  -- ===================================================================
  -- 1. what the spec sees: environment, sandbox, host, filetype
  local PROBE = [==[
return function(H)
  local info = {
    github_token = vim.env.GITHUB_TOKEN,
    api_key = vim.env.TESTING_PROBE_API_KEY,
    nvim_var = vim.env.NVIM,
    listen = vim.env.NVIM_LISTEN_ADDRESS,
    path_set = vim.env.PATH ~= nil or vim.env.Path ~= nil,
    kept = vim.env.TESTING_PROBE_KEEP,
    job_var = vim.env.TESTING_CHILD_JOB,
    boot_var = vim.env.TESTING_CHILD_BOOT,
    data = vim.fn.stdpath("data"),
    state = vim.fn.stdpath("state"),
    cache = vim.fn.stdpath("cache"),
    config = vim.fn.stdpath("config"),
    tmp = vim.fn.tempname(),
    did_enter = vim.v.vim_did_enter,
    cword_ok = (pcall(vim.fn.expand, "<cword>")),
    cfile_ok = (pcall(vim.fn.expand, "<cfile>")),
    ftplugin = vim.g.did_load_ftplugin,
    explore = vim.fn.exists(":Explore"),
    lib_dir = vim.env.LIB_NVIM_DIR,
    indent = vim.g.did_indent_on,
    cwd = vim.fn.getcwd(),
    argv = vim.v.argv,
  }
  local f = assert(io.open("probe.json", "wb"))
  f:write(vim.json.encode(info))
  f:close()
  H.ok(true, "probe written")
end
]==]

  ---@param root string
  ---@return table
  local function probe(root)
    return vim.json.decode(S.slurp(root .. "/probe.json") or "{}")
  end

  local function norm(s)
    return (tostring(s):gsub("\\", "/"):lower())
  end

  local saved = {}
  local function setenv(name, value)
    saved[name] = saved[name] == nil and (vim.env[name] or vim.NIL) or saved[name]
    vim.fn.setenv(name, value)
  end
  local function restore_env()
    for name, value in pairs(saved) do
      vim.fn.setenv(name, value)
    end
    saved = {}
  end

  setenv("GITHUB_TOKEN", "ghp_do_not_leak")
  setenv("TESTING_PROBE_API_KEY", "sk-do-not-leak")
  setenv("TESTING_PROBE_KEEP", "kept")
  setenv("NVIM", "fake-parent-address")
  setenv("NVIM_LISTEN_ADDRESS", "fake-parent-address")

  local root = S.new_root()
  local entries = S.project(root, { ["TESTS/probe_spec.lua"] = PROBE }, { "TESTS/probe_spec.lua" })
  local parent_data = vim.fn.stdpath("data")
  local parent_state = vim.fn.stdpath("state")
  local rep = S.run(root, entries, { options = { env_allow = { "TESTING_PROBE_KEEP" } } })
  restore_env()
  local c = S.case_of(rep, "TESTS/probe_spec.lua")
  eq(c and c.status, "pass", "the probe spec passes in a child: " .. vim.inspect(c))
  local info = probe(root)
  eq(info.github_token, nil, "child: GITHUB_TOKEN is not in the environment")
  eq(info.api_key, nil, "child: *_API_KEY is not in the environment")
  eq(info.nvim_var, nil, "child: $NVIM is not in the environment")
  eq(info.listen, nil, "child: $NVIM_LISTEN_ADDRESS is not in the environment")
  eq(info.path_set, true, "child: PATH is")
  eq(info.kept, "kept", "child: a variable named by env_allow is")
  eq(info.job_var, nil, "child: $TESTING_CHILD_JOB is removed before the spec runs")
  eq(info.boot_var, nil, "child: $TESTING_CHILD_BOOT is removed before the spec runs")
  -- the child reports its cwd symlink-resolved (macOS: /var/folders/... is /private/var/folders/...)
  eq(
    norm(vim.uv.fs_realpath(info.cwd) or info.cwd),
    norm(vim.uv.fs_realpath(root) or root),
    "child: the working directory is the project root"
  )
  ok(#info.argv >= 8 and info.argv[8] == "-c", "child: host c is started with -c")
  for _, key in ipairs({ "data", "state", "cache", "config" }) do
    ok(
      norm(info[key]):find("testing-child-", 1, true) ~= nil,
      key .. " dir is redirected into the sandbox: " .. info[key]
    )
  end
  ok(norm(info.data) ~= norm(parent_data), "stdpath('data') is not the parent's")
  ok(norm(info.state) ~= norm(parent_state), "stdpath('state') is not the parent's")
  ok(norm(info.tmp):find("testing-child-", 1, true) ~= nil, "tempname() lies in the sandbox")
  eq(
    vim.fn.isdirectory((info.data:gsub("[\\/]nvim%-data$", ""))),
    0,
    "the sandbox is removed afterwards"
  )

  -- host c = plenary-like: the spec runs from a -c command
  eq(info.did_enter, 0, "host c: v:vim_did_enter is 0 (plenary's value)")
  eq(info.cword_ok, true, "host c: expand('<cword>') works")
  eq(info.cfile_ok, true, "host c: expand('<cfile>') works")
  eq(info.ftplugin, 1, "filetype plugin is on by default")
  eq(info.indent, 1, "filetype indent is on by default")
  eq(
    info.explore,
    2,
    "the runtime plugins load (netrw's :Explore exists), as under plenary / --clean"
  )
  ok(
    type(info.lib_dir) == "string" and norm(info.lib_dir):find("lib.nvim", 1, true) ~= nil,
    "the resolved dependency is passed as $LIB_NVIM_DIR (an editor the spec starts finds it): "
      .. tostring(info.lib_dir)
  )

  -- host l = nvim -l
  vim.fn.delete(root .. "/probe.json")
  S.run(root, entries, { options = { host = "l", filetype = false } })
  local linfo = probe(root)
  eq(linfo.did_enter, 1, "host l: v:vim_did_enter is 1")
  eq(linfo.cword_ok, false, "host l: expand('<cword>') raises, as under nvim -l")
  ok(vim.tbl_contains(linfo.argv, "-l"), "host l is started with -l")
  ok(
    linfo.ftplugin == nil or linfo.ftplugin == vim.NIL or linfo.ftplugin == 0,
    "filetype = false: not enabled"
  )

  -- the IR of a child run is valid and sanitizes like an in-process one
  local inproc = require("testing.run.inproc")
  local ir, _, serr = inproc.sanitize(rep.result, root)
  ok(ir ~= nil, "the merged IR sanitizes and validates: " .. tostring(serr))

  -- ===================================================================
  -- 2. files do not see each other
  local root2 = S.new_root()
  local e2 = S.project(root2, {
    ["TESTS/1_spec.lua"] = [==[
return function(H)
  _G.leaked_global = "from file 1"
  package.loaded["leaky.module"] = { v = 1 }
  vim.api.nvim_create_autocmd("User", { pattern = "LeakyEvent", callback = function() end })
  H.ok(true, "file 1")
end
]==],
    ["TESTS/2_spec.lua"] = [==[
return function(H)
  H.eq(_G.leaked_global, nil, "no global from the file before")
  H.eq(package.loaded["leaky.module"], nil, "no module from the file before")
  H.eq(#vim.api.nvim_get_autocmds({ event = "User", pattern = "LeakyEvent" }), 0, "no autocmd either")
end
]==],
  }, { "TESTS/1_spec.lua", "TESTS/2_spec.lua" })
  local rep2 = S.run(root2, e2)
  eq(S.statuses(rep2), { "TESTS/1_spec.lua:pass", "TESTS/2_spec.lua:pass" }, "per-file isolation")

  -- ===================================================================
  -- 3. stdin is closed: prompts answer 'cancelled', deterministically
  local root3 = S.new_root()
  local e3 = S.project(root3, {
    ["TESTS/prompt_spec.lua"] = [==[
return function(H)
  H.eq(vim.fn.inputlist({ "pick one", "1. a", "2. b" }), 0, "inputlist is cancelled")
  H.eq(vim.fn.input("name? "), "", "input is cancelled")
  H.eq(vim.fn.confirm("sure?", "&Yes\n&No"), 0, "confirm is cancelled")
end
]==],
    ["TESTS/after_spec.lua"] = [==[
return function(H)
  H.ok(true, "the run went on")
end
]==],
  }, { "TESTS/prompt_spec.lua", "TESTS/after_spec.lua" })
  local t0 = vim.uv.hrtime()
  local rep3 = S.run(root3, e3, { timeouts = { file_ms = 20000 } })
  local pc = S.case_of(rep3, "TESTS/prompt_spec.lua")
  eq(pc and pc.status, "pass", "a spec that prompts passes deterministically: " .. vim.inspect(pc))
  local joined = table.concat(pc.notes, "\n")
  has(joined, "inputlist() was called 1 time(s)", "the note names the prompt")
  has(joined, "answered with 'cancelled'", "and what the child did")
  eq(S.case_of(rep3, "TESTS/after_spec.lua").status, "pass", "the next file is not affected")
  ok((vim.uv.hrtime() - t0) / 1e9 < 15, "and nothing waited for input")

  -- ===================================================================
  -- 4. a crashing child is a crash for that file only
  local root4 = S.new_root()
  local e4 = S.project(root4, {
    ["TESTS/1_ok_spec.lua"] = 'return function(H) H.ok(true, "fine") end\n',
    ["TESTS/2_crash_spec.lua"] = [==[
return function(H)
  H.ok(true, "about to die")
  io.stderr:write("last words before the native crash\n")
  io.stderr:flush()
  local ffi = require("ffi")
  ffi.cast("int*", 0)[0] = 1
end
]==],
    ["TESTS/3_quit_spec.lua"] = [==[
return function(H)
  H.ok(true, "about to quit the editor")
  vim.cmd("qa!")
end
]==],
    ["TESTS/4_ok_spec.lua"] = 'return function(H) H.ok(true, "still fine") end\n',
  }, {
    "TESTS/1_ok_spec.lua",
    "TESTS/2_crash_spec.lua",
    "TESTS/3_quit_spec.lua",
    "TESTS/4_ok_spec.lua",
  })
  local rep4 = S.run(root4, e4, { timeouts = { file_ms = 20000 } })
  eq(S.statuses(rep4), {
    "TESTS/1_ok_spec.lua:pass",
    "TESTS/2_crash_spec.lua:crash",
    "TESTS/3_quit_spec.lua:crash",
    "TESTS/4_ok_spec.lua:pass",
  }, "a crash is a crash for that file; the others report normally")
  local cr = S.case_of(rep4, "TESTS/2_crash_spec.lua")
  has(cr.error.message, "the editor died", "the crash says the editor died")
  has(cr.error.message, "exit code", "and with which exit code")
  has(cr.error.message, "last words before the native crash", "and carries the stderr tail")
  local q = S.case_of(rep4, "TESTS/3_quit_spec.lua")
  has(
    q.error.message,
    "run did not complete",
    "a spec that quits the editor is a crash with the reason"
  )
  eq(rep4.exit_code, 1, "the run is red")
  eq(rep4.failed, 2, "two red cases")

  -- ===================================================================
  -- 5. hard timeout: the process TREE is killed, nothing is left behind, the run goes on
  local root5 = S.new_root()
  local e5 = S.project(root5, {
    ["TESTS/1_hang_spec.lua"] = [==[
return function(H)
  H.ok(true, "started")
  -- a grandchild that would outlive its parent
  -- No pipes to the parent (it must not die just because the parent's end of a pipe is gone). On
  -- Windows libuv puts every process it spawns into a job that dies with its parent, so the
  -- grandchild breaks away from it (detached): only a tree kill reaches it there. On POSIX a
  -- detached process leaves the process group on purpose, so it stays in the group instead.
  local _, grandchild_pid = vim.uv.spawn(vim.v.progpath, {
    args = { "--headless", "-n", "-i", "NONE", "-u", "NONE", "-c", "sleep 100", "-c", "qa!" },
    stdio = { nil, nil, nil },
    detached = vim.fn.has("win32") == 1,
  }, function() end)
  local f = assert(io.open("pids.txt", "wb"))
  f:write(tostring(vim.fn.getpid()), "\n", tostring(grandchild_pid), "\n")
  f:close()
  -- blocks inside C: the in-process timeout cannot interrupt this, only the kill can
  vim.uv.sleep(600000)
end
]==],
    ["TESTS/2_after_spec.lua"] = 'return function(H) H.ok(true, "ran after the hang") end\n',
  }, { "TESTS/1_hang_spec.lua", "TESTS/2_after_spec.lua" })
  local t1 = vim.uv.hrtime()
  local rep5 = S.run(root5, e5, { timeouts = { file_ms = 800 }, grace_ms = 400 })
  local waited_ms = (vim.uv.hrtime() - t1) / 1e6
  eq(
    S.statuses(rep5),
    { "TESTS/1_hang_spec.lua:timeout", "TESTS/2_after_spec.lua:pass" },
    "the hung file is a timeout, the next one runs"
  )
  has(
    S.case_of(rep5, "TESTS/1_hang_spec.lua").error.message,
    "process tree was killed",
    "the message says what happened"
  )
  ok(
    waited_ms < 30000,
    "the run did not wait for the hung file (took " .. math.floor(waited_ms) .. " ms)"
  )
  eq(rep5.exit_code, 1, "a timeout is red")
  local pids = vim.split(vim.trim(S.slurp(root5 .. "/pids.txt") or ""), "\n")
  eq(#pids, 2, "the fixture recorded the child's and the grandchild's pid")
  local child_pid, grand_pid = tonumber(pids[1]), tonumber(pids[2])
  ok(child_pid ~= nil and grand_pid ~= nil, "both pids are numbers")
  vim.wait(3000, function()
    return not S.alive(child_pid) and not S.alive(grand_pid)
  end, 50)
  eq(S.alive(child_pid), false, "the child process is gone")
  eq(S.alive(grand_pid), false, "and so is the process it started (no zombie)")

  -- ===================================================================
  -- 5a. an ORPHAN that holds the child's pipes: a spec leaves a helper behind that inherited stdout and
  -- stderr and keeps running. The child itself ends at once; the run must end with it (the verdict is
  -- the file's, never a "timeout" because the pipes stay open) and take no longer than the drain.
  local roota = S.new_root()
  local ea = S.project(roota, {
    ["TESTS/1_orphan_spec.lua"] = [==[
return function(H)
  -- inherits the child's stdout/stderr (fds 1 and 2) and outlives it for a few seconds; on Windows it is
  -- detached so that it is not taken down with its parent; on POSIX it stays in the child's process
  -- group, which the driver kills once the child is gone
  local _, pid = vim.uv.spawn(vim.v.progpath, {
    args = { "--headless", "-n", "-i", "NONE", "-u", "NONE", "-c", "sleep 9000m", "-c", "qa!" },
    stdio = { nil, 1, 2 },
    detached = vim.fn.has("win32") == 1,
  }, function() end)
  local f = assert(io.open("orphan.txt", "wb"))
  f:write(tostring(pid))
  f:close()
  H.ok(true, "the spec itself passes")
end
]==],
    ["TESTS/2_after_spec.lua"] = 'return function(H) H.ok(true, "ran after the orphan") end\n',
  }, { "TESTS/1_orphan_spec.lua", "TESTS/2_after_spec.lua" })
  local ta = vim.uv.hrtime()
  local repa = S.run(roota, ea, { timeouts = { file_ms = 4000 }, grace_ms = 1000 })
  local orphan_ms = (vim.uv.hrtime() - ta) / 1e6
  eq(
    S.statuses(repa),
    { "TESTS/1_orphan_spec.lua:pass", "TESTS/2_after_spec.lua:pass" },
    "a file that left an orphan holding the pipes is judged by its own result, not by a timeout"
  )
  ok(
    orphan_ms < 7000,
    "the run did not wait for the orphan (took "
      .. math.floor(orphan_ms)
      .. " ms, the orphan lives 9 s)"
  )
  local orphan_pid = tonumber(vim.trim(S.slurp(roota .. "/orphan.txt") or ""))
  ok(orphan_pid ~= nil, "the fixture recorded the orphan's pid")
  if orphan_pid and S.alive(orphan_pid) then
    -- Windows: documented limit, an orphan that outlived a normally ended child is not killed; the
    -- test must not leave it behind
    pcall(vim.uv.kill, orphan_pid, "sigkill")
  end

  -- an abandoned process (the kill does not end it) cannot hold the run: `abandon` completes the
  -- handle once, whatever the process does
  do
    local childmod = require("testing.child")
    local fired = 0
    local plan = childmod.build({ entry = { rel = "x" }, root = roota })
    ok(childmod.prepare(plan), "the sandbox of the abandoned child is prepared")
    local handle = assert(childmod.spawn(plan, function()
      fired = fired + 1
    end))
    childmod.kill_tree(handle)
    childmod.abandon(handle)
    childmod.abandon(handle)
    vim.wait(500, function()
      return fired > 0
    end, 10)
    eq(fired, 1, "abandon completes the handle exactly once")
    eq(handle.abandoned, true, "and marks it as abandoned")
    vim.wait(500, function()
      return not childmod.alive(handle.pid)
    end, 20)
    childmod.cleanup(plan)
  end

  -- ===================================================================
  -- 5b. a busted case that blocks inside C: the pool kills the child after case_ms + grace without a
  -- NEW record; the cases that finished before are kept. A slow LOAD (before the first record) is
  -- not a stuck case.
  local rootb = S.new_root()
  local eb = S.project(rootb, {
    ["TESTS/stuck_spec.lua"] = [==[
describe("stuck", function()
  it("is fine", function()
    assert.is_true(true)
  end)
  it("blocks in C", function()
    vim.uv.sleep(600000)
  end)
  it("is never reached", function()
    assert.is_true(true)
  end)
end)
]==],
    ["TESTS/slowload_spec.lua"] = [==[
vim.uv.sleep(1500) -- loading the file takes longer than case_ms + grace
describe("slow load", function()
  it("still passes", function()
    assert.is_true(true)
  end)
end)
]==],
  }, { "TESTS/stuck_spec.lua", "TESTS/slowload_spec.lua" }, "busted")
  local repb = S.run(rootb, eb, { timeouts = { case_ms = 400, file_ms = 60000 }, grace_ms = 300 })
  local stuck, slow = {}, {}
  for _, bc in ipairs(repb.result.cases) do
    local bucket = bc.file == "TESTS/stuck_spec.lua" and stuck or slow
    bucket[#bucket + 1] = bc.status
  end
  eq(stuck, { "pass", "timeout" }, "a stuck case: the earlier case is kept, then one timeout")
  has(
    repb.result.cases[2].error.message,
    "a case exceeded 400 ms",
    "and the timeout names the case limit"
  )
  eq(slow, { "pass" }, "a file that is slow to load is not killed as a stuck case")

  -- ===================================================================
  -- 6. a prompt nobody answers (a raw :call input()) is stopped by the hard timeout, not hung
  local root6 = S.new_root()
  local e6 = S.project(root6, {
    ["TESTS/1_ask_spec.lua"] = [==[
return function(H)
  H.ok(true, "before the question")
  vim.cmd("call input('really? ')")
  H.ok(true, "after the question")
end
]==],
    ["TESTS/2_after_spec.lua"] = 'return function(H) H.ok(true, "ran after") end\n',
  }, { "TESTS/1_ask_spec.lua", "TESTS/2_after_spec.lua" })
  local t2 = vim.uv.hrtime()
  local rep6 = S.run(root6, e6, { timeouts = { file_ms = 1500 }, grace_ms = 500 })
  local ask = S.case_of(rep6, "TESTS/1_ask_spec.lua")
  eq(ask.status, "timeout", "an unanswerable prompt on host c is stopped by the hard timeout")
  local rep6l = S.run(root6, e6, { timeouts = { file_ms = 1500 }, options = { host = "l" } })
  eq(
    S.case_of(rep6l, "TESTS/1_ask_spec.lua").status,
    "crash",
    "on host l the editor ends at stdin EOF: a crash for that file, not a hang"
  )
  eq(S.case_of(rep6, "TESTS/2_after_spec.lua").status, "pass", "the next file runs")
  ok((vim.uv.hrtime() - t2) / 1e9 < 25, "and nothing hung")

  -- ===================================================================
  -- 7. self-running scripts: the exit code AND the printed [FAIL] lines are the verdict
  local root7 = S.new_root()
  local e7 = S.project(root7, {
    ["TESTS/1_green.lua"] = 'print("[ok] all good")\nos.exit(0)\n',
    ["TESTS/2_red_exit.lua"] = 'print("[FAIL] something broke")\nos.exit(1)\n',
    ["TESTS/3_red_text.lua"] = 'print("[FAIL] says it failed but exits 0")\nos.exit(0)\n',
    ["TESTS/4_exit_only.lua"] = "os.exit(7)\n",
    ["TESTS/5_raise.lua"] = 'error("boom from the script")\n',
    ["TESTS/6_segv.lua"] = "os.exit(139)\n",
  }, {
    "TESTS/1_green.lua",
    "TESTS/2_red_exit.lua",
    "TESTS/3_red_text.lua",
    "TESTS/4_exit_only.lua",
    "TESTS/5_raise.lua",
    "TESTS/6_segv.lua",
  }, "script")
  local rep7 = S.run(root7, e7, { timeouts = { file_ms = 20000 }, options = { jobs = 3 } })
  eq(S.statuses(rep7), {
    "TESTS/1_green.lua:pass",
    "TESTS/2_red_exit.lua:fail",
    "TESTS/3_red_text.lua:fail",
    "TESTS/4_exit_only.lua:fail",
    "TESTS/5_raise.lua:error",
    "TESTS/6_segv.lua:crash",
  }, "script verdicts: never greener than the script's own report")
  has(
    S.case_of(rep7, "TESTS/2_red_exit.lua").assertions[1].msg,
    "[FAIL] something broke",
    "the printed failure line is an assertion"
  )
  has(
    S.case_of(rep7, "TESTS/4_exit_only.lua").assertions[1].msg,
    "exit code 7",
    "a bare non-zero exit says so"
  )
  has(
    S.case_of(rep7, "TESTS/5_raise.lua").error.message,
    "boom from the script",
    "an uncaught error is the message"
  )

  S.cleanup()
end
