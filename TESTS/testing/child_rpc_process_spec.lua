-- TESTS/testing/child_rpc_process_spec.lua -- REAL child editors (testing.rpc): the process side. Kill of the whole
-- tree (a grandchild does not survive), crash detection (exit code, `:qa`, `os.exit`), a hung child is a timeout
-- and not a hang, the trace file on timeout/crash (and in the IR), a dead child gives a precise error,
-- a closed stdin ends the child, restart, a broken minit, big payloads and a noisy stderr.

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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local rpc = require("testing.rpc")

  ---@param path string
  ---@return table
  local function read_trace(path)
    local text = S.slurp(path)
    ok(text and #text > 0, "the trace file exists: " .. tostring(path))
    local decoded = vim.json.decode(text --[[@as string]])
    ok(type(decoded) == "table", "the trace file is JSON")
    return decoded
  end

  S.run(function()
    -- ===================================================================
    -- 1. kill takes the whole process tree: a grandchild started by the child does not survive
    local c = S.spawn()
    local pid = c.pid
    ok(S.alive(pid), "the child runs")
    local sandbox = c.sandbox
    eq(vim.fn.isdirectory(sandbox), 1, "its sandbox exists")
    local gpid = c.lua([[
      local job = vim.fn.jobstart({ vim.v.progpath, '--headless', '-n', '-i', 'NONE', '-u', 'NONE', '+sleep 300' })
      return vim.fn.jobpid(job)
    ]])
    ok(type(gpid) == "number" and gpid > 0, "the child started a grandchild nvim")
    ok(S.alive(gpid), "the grandchild runs")
    c.kill()
    ok(
      S.wait(30000, function()
        return not S.alive(pid) and not S.alive(gpid)
      end),
      "after kill() neither the child nor its grandchild is alive"
    )
    ok(not c.alive(), "alive() is false")
    eq(c.status().state, "killed", "status: killed")
    eq(c.status().kill_reason, "kill", "by kill()")
    eq(vim.fn.isdirectory(sandbox), 0, "the sandbox is removed")
    c.kill() -- idempotent
    local dok, derr = pcall(c.lua, "return 1")
    ok(not dok, "a call to a killed child raises")
    has(derr, "child died", "naming it")
    has(derr, "killed by kill()", "and why")
    local aok, aerr = pcall(c.ensure_alive)
    ok(not aok, "ensure_alive raises for a dead child")
    has(aerr, "child died", "ensure_alive message")

    -- ===================================================================
    -- 2. crash detection: exit codes, :qa, os.exit. Never a hang, always the exit and the call that was running
    -- The yardstick of "promptly" is the call timeout: a death that was only noticed by the timeout would take all
    -- of it. It is set far above what noticing a death costs on a busy machine, so the claim does not depend on how
    -- busy that is.
    local crash = S.spawn({ call_timeout_ms = 60000 })
    crash.lua("vim.notify('about to die', vim.log.levels.WARN)")
    local t0 = vim.uv.hrtime() / 1e6
    local cok, cerr = pcall(crash.lua, "vim.cmd('cquit 139')")
    ok(not cok, "a child that exits during a call raises")
    local noticed_ms = vim.uv.hrtime() / 1e6 - t0
    ok(
      noticed_ms < 30000,
      ("and does so promptly, not after the call timeout of 60 s (took %d ms)"):format(noticed_ms)
    )
    has(cerr, "child died during nvim_exec_lua", "names the call")
    has(cerr, "exit code 139", "and the exit code")
    local st = crash.status()
    eq(st.state, "crashed", "status: crashed")
    eq(st.exit.code, 139, "exit code is kept")
    ok(not crash.alive(), "not alive")
    eq(
      crash.notifies()[1].msg,
      "about to die",
      "the notifications of a dead child are still available"
    )
    local trace_art = crash.trace_artifact()
    ok(trace_art and trace_art.kind == "trace", "a crash writes the trace and reports the artifact")
    has(cerr, "trace: ", "the error names the trace file")
    local tr = read_trace(trace_art.path)
    eq(tr.reason, "crash", "trace reason")
    eq(tr.child.pid, crash.pid, "trace: the pid")
    has(tr.child.exit_text, "exit code 139", "trace: the exit")
    local last = tr.calls[#tr.calls]
    eq({ last.method, last.status }, { "nvim_exec_lua", "died" }, "trace: the last call died")
    local about = false
    for _, e in ipairs(tr.events) do
      if e.text:find("about to die", 1, true) then
        about = true
      end
    end
    ok(about, "trace: the child's last notification is in it")

    local q = S.spawn()
    local qok, qerr = pcall(q.cmd, "qa!")
    ok(not qok, ":qa! during a call raises")
    has(qerr, "child died", ":qa! message")
    has(qerr, "exit code 0", "with its exit code")
    eq(q.status().state, "exited", "a clean exit is 'exited', not 'crashed'")

    local x = S.spawn()
    local xok, xerr = pcall(x.lua, "os.exit(7)")
    ok(not xok, "os.exit raises")
    has(xerr, "exit code 7", "os.exit code")

    -- ===================================================================
    -- 3. timeout: a hung child is killed and the call raises; the trace says what it was doing
    local hung = S.spawn({ call_timeout_ms = 500, run_dir = nil })
    hung.lua("vim.notify('before the hang')")
    local hpid = hung.pid
    local h0 = vim.uv.hrtime() / 1e6
    local hok, herr = pcall(hung.lua, "while true do end")
    local took = vim.uv.hrtime() / 1e6 - h0
    ok(not hok, "an endless loop in the child raises in the parent")
    -- Killing the tree of a child takes seconds on a busy Windows machine (the process table, `taskkill`), and the
    -- driver waits up to `REAP_MS` for the process to end before it gives up on it: the call returns within a few
    -- of those. A hang is a call that does not return.
    ok(took < 3 * rpc.REAP_MS, ("and does not hang (took %d ms)"):format(took))
    has(herr, "timed out after 500 ms", "the timeout is named")
    has(herr, "nvim_exec_lua", "with the call")
    has(herr, "was killed", "the child was killed")
    ok(
      S.wait(30000, function()
        return not S.alive(hpid)
      end),
      "the hung process is gone"
    )
    eq(hung.status().kill_reason, "timeout", "kill reason: timeout")
    local ht = read_trace(hung.trace_artifact().path)
    eq(ht.reason, "timeout", "trace reason")
    local hl = ht.calls[#ht.calls]
    eq({ hl.method, hl.status }, { "nvim_exec_lua", "timeout" }, "trace: the call that timed out")
    ok(hl.args:find("while true do end", 1, true), "trace: with its (short) arguments")
    local dead_ok, dead_err = pcall(hung.lua, "return 1")
    ok(not dead_ok, "afterwards the child is dead")
    has(dead_err, "killed after a call timed out", "and says why")

    -- opt out: the child is left alone (and killed by the test)
    local keep = S.spawn({ call_timeout_ms = 300, kill_on_timeout = false })
    local kok, kerr = pcall(keep.lua, "vim.wait(60000)")
    ok(not kok, "the call still times out")
    has(kerr, "is still running", "kill_on_timeout = false leaves the child running")
    ok(keep.alive(), "alive")
    keep.kill()
    ok(not keep.alive(), "killed by hand")

    -- a prompt that blocks (answers stay real) is a timeout, not a hang
    local prompt = S.spawn({ prompts = "real", call_timeout_ms = 500 })
    local pok, perr = pcall(prompt.lua, "return vim.fn.input('anyone there? ')")
    ok(not pok, "a real input() prompt blocks the request")
    has(perr, "timed out", "and surfaces as a timeout")

    -- ===================================================================
    -- 4. the trace is an IR artifact: relative placeholder in the case, bounded, redacted
    do
      local run_dir = S.new_dir()
      local cc =
        S.spawn({ trace_dir = run_dir .. "/traces", run_dir = run_dir, trace_name = "case1" })
      cc.lua("vim.notify(" .. vim.inspect(vim.uv.os_homedir() .. "/private/file.lua") .. ")")
      pcall(cc.lua, "vim.cmd('cquit 2')")
      local art = cc.trace_artifact()
      ok(art, "artifact")
      eq(
        art.path:match("^<RUN>/traces/case1%-%d+%-1%.trace%.json$") ~= nil,
        true,
        "the path is <RUN>-relative: " .. tostring(art.path)
      )
      local text = S.slurp(run_dir .. "/traces/" .. art.path:match("[^/]+$")) or ""
      ok(
        #text > 0 and #text <= require("testing.rpc.trace").MAX_BYTES,
        "the file exists and is bounded"
      )
      ok(
        not text:lower():find(vim.uv.os_homedir():gsub("\\", "/"):lower(), 1, true),
        "the home directory is redacted"
      )
      has(text, "<HOME>", "to a placeholder")

      -- through the IR: the artifact of a crash case survives the sanitizer, with <TMP>
      local result = require("testing.core.result")
      local inproc = require("testing.run.inproc")
      local tmp_child = S.spawn({ trace_name = "ir" })
      pcall(tmp_child.lua, "vim.cmd('cquit 5')")
      local tart = tmp_child.trace_artifact()
      local res = result.new({
        run = { root = S.repo, os = vim.fn.has("win32") == 1 and "windows" or "linux" },
      })
      local case = result.new_case({ file = "TESTS/x_spec.lua", name = "crashes" })
      case.status = "crash"
      case.notes = { tmp_child.status().exit_text or "" }
      case.artifacts = { tart }
      result.add_case(res, case)
      result.finalize(res)
      local ir, err = inproc.sanitize(res, S.repo)
      ok(ir, "the IR with the trace artifact validates: " .. tostring(err))
      local ap = ir and ir.cases[1].artifacts[1]
      ok(
        ap and ap.kind == "trace" and ap.path:match("^<TMP>/"),
        "the artifact path is <TMP>-relative in the IR: " .. vim.inspect(ap)
      )
    end

    -- ===================================================================
    -- 5. a closed stdin ends the child: no hang, no kill needed
    local sc = S.spawn()
    local spid = sc.pid
    sc.close_stdin()
    ok(
      S.wait(30000, function()
        return not S.alive(spid)
      end),
      "an editor whose client went away quits by itself"
    )
    -- the pid is gone before the exit callback of the handle ran: wait for the state to follow
    S.wait(10000, function()
      return sc.status().state ~= "running"
    end)
    eq(sc.status().state, "exited", "which is 'exited', not 'crashed'")
    ok(not pcall(sc.lua, "return 1"), "and calls to it raise")

    -- ===================================================================
    -- 6. restart: the same handle, a new process and sandbox, a clean state
    local r = S.spawn({ minit = S.minit })
    local old_pid, old_box = r.pid, r.sandbox
    r.g.state_before = "dirty"
    r.restart()
    ok(r.pid ~= old_pid, "a new process")
    ok(r.sandbox ~= old_box, "and a new sandbox")
    ok(r.alive() and r.lua("return 1") == 1, "the same handle works again")
    eq(r.g.state_before, nil, "with a fresh state")
    eq(r.g.rpc_minit_ran, true, "the minit ran again")
    ok(
      S.wait(30000, function()
        return not S.alive(old_pid)
      end),
      "the old process is gone"
    )
    eq(vim.fn.isdirectory(old_box), 0, "the old sandbox is removed")
    eq(r.notifies(), {}, "captures start empty")

    -- ===================================================================
    -- 7. a broken minit is a failed spawn with the reason, and leaves nothing behind
    local base = S.new_dir()
    local bad, berr = rpc.spawn({
      root = S.repo,
      minit = S.fixtures .. "/bad_minit.lua",
      guard = false,
      base = base,
      name = "testing-child-bad",
      trace_dir = S.new_dir(),
    })
    ok(bad == nil, "spawn fails")
    has(berr, "did not start", "says so")
    has(berr, "broken on purpose", "and why (the minit's own error)")
    eq(vim.fn.isdirectory(base .. "/testing-child-bad"), 0, "no sandbox is left")
    local nope, nerr =
      rpc.spawn({ root = S.repo, nvim = S.fixtures .. "/does-not-exist-nvim", guard = false })
    ok(
      nope == nil and nerr and nerr:find("cannot start", 1, true),
      "a missing executable is a failed spawn: " .. tostring(nerr)
    )

    -- ===================================================================
    -- 8. payloads and noise
    -- Bulk data is slow and erratic on a busy machine, and not because of the driver: the same 3 MB result took
    -- from 60 ms to 19 s on Windows while the 2 MB argument (parent to child) stayed at 0.2 s, and `wire.feed`
    -- decodes the 3 MB in under 10 ms. The limit of a call here is the point where the spec gives up on a stuck
    -- child (a child that never answers is a timeout whatever the limit), not a performance claim.
    local big = S.spawn({ call_timeout_ms = 120000 })
    local n = 3 * 1024 * 1024
    eq(#big.lua("return string.rep('x', ...)", n), n, "a 3 MB result arrives (many chunks)")
    local blob = ("y"):rep(2 * 1024 * 1024)
    eq(big.lua("return #...", blob), #blob, "a 2 MB argument is sent")
    -- Where the child's stderr goes decides what a flood measures. A pipe is drained by the parent as the data
    -- arrives: 1.5 MB must not block the child. On Windows Neovim gives an embedded editor a console of its own
    -- (stdio is a character device there and nothing reaches our pipe, docs/CHILD.md), so the write is paid to
    -- conhost.exe: 10 to 75 s for 1.5 MB on a machine that other work keeps busy, none of it the driver's. That
    -- case floods less; a blocked child is a timeout either way. The pipe itself (drain, cap, newest output) is
    -- covered with a real process on every system in child_output_spec.lua.
    local sink = big.lua("return vim.uv.guess_handle(2)")
    local lines = sink == "tty" and 100 or 3000
    eq(
      big.lua("for i = 1, ... do io.stderr:write(('e'):rep(500), '\\n') end return 'done'", lines),
      "done",
      ("a child that floods stderr (%d lines, into a %s) does not block"):format(lines, sink)
    )
    ok(#big.stderr() <= require("testing.child").OUTPUT_CAP + 1000, "and its stderr is capped")
    ok(big.alive(), "still alive")
    -- many small calls
    for i = 1, 200 do
      eq(big.lua("return ... + 1", i), i + 1, "call " .. i)
    end
  end)
end
