-- TESTS/testing/rpc_trace_spec.lua -- the trace of an RPC child: bounded rings, the file (size cap,
-- redaction through the IR kernel, atomic write), the artifact record (`<RUN>/...` or the absolute path).

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local trace_mod = require("testing.rpc.trace")
  local dir = vim.fs.normalize(vim.fn.tempname()) .. "-trace"
  vim.fn.mkdir(dir, "p")

  local function slurp(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local s = f:read("*a")
    f:close()
    return s
  end

  local body_ok, body_err = xpcall(function()
    -- the call ring keeps the last MAX_CALLS, counts all of them
    do
      local t = trace_mod.new()
      for i = 1, trace_mod.MAX_CALLS + 10 do
        local c = t:start("nvim_eval", { "expr" .. i })
        t:finish(c, "ok")
      end
      local snap = t:snapshot({ reason = "test", stderr = "" })
      eq(#snap.calls, trace_mod.MAX_CALLS, "the ring is bounded")
      eq(snap.calls_total, trace_mod.MAX_CALLS + 10, "all calls are counted")
      eq(snap.calls[1].n, 11, "the OLDEST calls are dropped")
      eq(snap.calls[#snap.calls].n, trace_mod.MAX_CALLS + 10, "the newest is kept")
      ok(snap.truncated, "a snapshot that lost calls says so")
      ok(snap.calls[1].args:find("expr11", 1, true), "arguments are rendered")
    end

    -- call outcome and error line
    do
      local t = trace_mod.new()
      local c = t:start("nvim_exec_lua", { "error('x')" })
      t:finish(c, "error", "first line\nsecond line")
      local snap = t:snapshot({ reason = "test", stderr = "" })
      eq(snap.calls[1].status, "error", "status")
      eq(snap.calls[1].err, "first line", "only the first line of an error is kept")
      ok(type(snap.calls[1].ms) == "number", "duration")
      local pending = t:start("slow", {})
      eq(t:snapshot({ stderr = "" }).calls[2].status, "pending", "an unfinished call is pending")
      t:finish(pending, "timeout")
      eq(t:snapshot({ stderr = "" }).calls[2].status, "timeout", "timeout status")
    end

    -- long arguments and events are clipped
    do
      local t = trace_mod.new()
      t:start("m", { ("x"):rep(5000) })
      t:event("notify", ("y"):rep(5000), "WARN")
      local snap = t:snapshot({ stderr = "" })
      ok(#snap.calls[1].args <= trace_mod.MAX_ARG + 3, "long arguments are clipped")
      ok(#snap.events[1].text <= trace_mod.MAX_ERR + 3, "long events are clipped")
      eq(snap.events[1].level, "WARN", "event level")
    end

    -- the event ring is bounded
    do
      local t = trace_mod.new()
      for i = 1, trace_mod.MAX_EVENTS + 5 do
        t:event("notify", "n" .. i)
      end
      local snap = t:snapshot({ stderr = "" })
      eq(#snap.events, trace_mod.MAX_EVENTS, "the event ring is bounded")
      eq(snap.events[1].text, "n6", "the oldest events are dropped")
    end

    -- stderr is cut to its tail
    do
      local t = trace_mod.new()
      local snap = t:snapshot({ stderr = ("a"):rep(trace_mod.MAX_STDERR) .. "TAIL" })
      eq(#snap.stderr_tail, trace_mod.MAX_STDERR, "stderr tail is capped")
      ok(snap.stderr_tail:sub(-4) == "TAIL", "the END of stderr is kept")
      ok(snap.truncated, "and marked")
    end

    -- the file: written, valid JSON, redacted (home and user name) like the IR
    do
      local home = assert(vim.uv.os_homedir())
      local user = vim.env.USERNAME or vim.env.USER
      local t = trace_mod.new()
      local c = t:start("nvim_exec_lua", { "return 1" })
      t:finish(c, "error", "failed in " .. home .. "/secret/file.lua")
      t:event("notify", "opened " .. home .. "/x as " .. tostring(user))
      local snap = t:snapshot({
        reason = "crash",
        child = { pid = 123 },
        stderr = "E5113 at " .. home .. "/y.lua\n",
      })
      local path = dir .. "/sub/case.trace.json"
      local artifact, err = trace_mod.write(snap, { path = path, root = dir })
      artifact = assert(artifact, "the trace is written: " .. tostring(err))
      eq(artifact.kind, "trace", "artifact kind")
      eq(artifact.path, vim.fs.normalize(path), "outside a run directory the path is absolute")
      local text = slurp(path) or ""
      ok(#text > 0, "the file exists")
      local decoded = vim.json.decode(text)
      eq(decoded.reason, "crash", "reason")
      eq(decoded.child.pid, 123, "child info")
      eq(#decoded.calls, 1, "calls are in the file")
      ok(
        not text:lower():find(home:gsub("\\", "/"):lower(), 1, true),
        "the home directory is not in the file"
      )
      ok(
        not text:lower():find(home:gsub("/", "\\\\"):lower(), 1, true),
        "nor in its escaped Windows form"
      )
      ok(text:find("<HOME>", 1, true), "it is a placeholder instead")
      if user and #user >= 3 then
        ok(not text:lower():find(user:lower(), 1, true), "the user name is redacted")
      end
    end

    -- a path below the run directory is `<RUN>/...`
    do
      local rel = trace_mod.artifact_path(dir .. "/run1/a.trace.json", dir .. "/run1")
      eq(rel, "<RUN>/a.trace.json", "<RUN> placeholder")
      local upper = trace_mod.artifact_path(dir .. "/RUN1/a.trace.json", dir .. "/run1")
      if vim.fn.has("win32") == 1 then
        eq(upper, "<RUN>/a.trace.json", "Windows paths compare case-insensitively")
      end
      eq(
        trace_mod.artifact_path(dir .. "/other/a.json", dir .. "/run1"),
        vim.fs.normalize(dir .. "/other/a.json"),
        "outside the run directory"
      )
      eq(
        trace_mod.artifact_path(dir .. "/run10/a.json", dir .. "/run1"),
        vim.fs.normalize(dir .. "/run10/a.json"),
        "a sibling with the same prefix is not inside"
      )
    end

    -- size cap: a flood of large events never makes a file over MAX_BYTES (SEC-32)
    do
      local t = trace_mod.new()
      for i = 1, trace_mod.MAX_EVENTS + 20 do
        t:event("notify", ("%d:"):format(i) .. ("z"):rep(3000))
      end
      for i = 1, trace_mod.MAX_CALLS do
        local c = t:start("m" .. i, { ("a"):rep(1000) })
        t:finish(c, "error", ("e"):rep(1000))
      end
      local snap = t:snapshot({ reason = "timeout", stderr = ("s"):rep(trace_mod.MAX_STDERR) })
      -- clipping keeps events at MAX_ERR; shrink the cap so the loop that sheds history is exercised
      local saved = trace_mod.MAX_BYTES
      trace_mod.MAX_BYTES = 8 * 1024
      local path = dir .. "/big.trace.json"
      local artifact, err = trace_mod.write(snap, { path = path, root = dir })
      trace_mod.MAX_BYTES = saved
      ok(artifact, "a big trace is still written: " .. tostring(err))
      local text = slurp(path) or ""
      ok(#text <= 8 * 1024, ("the file respects the cap (%d bytes)"):format(#text))
      local decoded = vim.json.decode(text)
      eq(decoded.truncated, true, "and says it is truncated")
      ok(
        #decoded.calls < trace_mod.MAX_CALLS or #decoded.events < trace_mod.MAX_EVENTS,
        "history was shed"
      )
    end

    -- no temp file is left next to the trace (atomic write)
    do
      local leftovers = vim.fn.glob(dir .. "/*.atomic-tmp*", false, true)
      eq(#leftovers, 0, "no temp file left behind")
    end
  end, debug.traceback)
  pcall(vim.fn.delete, dir, "rf")
  if not body_ok then
    error(body_err, 0)
  end
end
