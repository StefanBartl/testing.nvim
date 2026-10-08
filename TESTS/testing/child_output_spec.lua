-- TESTS/testing/child_output_spec.lua -- the capture buffer of a child's output (`testing.child.keep`, `OUTPUT_CAP`):
-- the newest output is kept whole chunk by whole chunk, dropping the oldest never costs time per live chunk (a pipe
-- read can hand over a few bytes at a time), and a REAL process that floods its stderr through a pipe is drained, not
-- blocked, with the same cap. (An embedded editor is no subject for the last one: on Windows its stderr is a console of
-- its own, nothing reaches the pipe, see docs/CHILD.md.)

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
  local child = require("testing.child")

  ---Run `body` with `OUTPUT_CAP` set to `cap`, put the original back whatever happens.
  ---@param cap integer
  ---@param body fun()
  local function with_cap(cap, body)
    local saved = child.OUTPUT_CAP
    child.OUTPUT_CAP = cap
    local bok, err = pcall(body)
    child.OUTPUT_CAP = saved
    if not bok then
      error(err, 0)
    end
  end

  -- ===================================================================
  -- 1. the buffer is the reference model: the oldest whole chunks go while the cap is exceeded, a single chunk stays
  with_cap(1000, function()
    -- deterministic pseudo-random chunk sizes (no `math.random`: the run is reproducible)
    local state = 12345
    local function next_size()
      state = (state * 1103515245 + 12345) % 2147483648
      return 1 + state % 300
    end
    local buf = child.new_buffer()
    local model, model_bytes, model_truncated = {}, 0, false
    local mismatch
    for i = 1, 6000 do
      local chunk = (tostring(i % 10)):rep(next_size())
      child.keep(buf, chunk)
      model[#model + 1] = chunk
      model_bytes = model_bytes + #chunk
      while model_bytes > 1000 and #model > 1 do
        model_bytes = model_bytes - #table.remove(model, 1)
        model_truncated = true
      end
      if
        child.text(buf) ~= table.concat(model)
        or buf.bytes ~= model_bytes
        or buf.truncated ~= model_truncated
      then
        mismatch = ("after chunk %d: bytes %d vs %d, truncated %s vs %s"):format(
          i,
          buf.bytes,
          model_bytes,
          tostring(buf.truncated),
          tostring(model_truncated)
        )
        break
      end
    end
    ok(mismatch == nil, "a buffer behaves like the plain list it replaces: " .. tostring(mismatch))
    ok(buf.bytes <= 1000, "and stays within the cap")

    local lone = child.new_buffer()
    child.keep(lone, ("z"):rep(5000))
    eq(
      #child.text(lone),
      5000,
      "one chunk larger than the cap is kept whole (nothing older to drop)"
    )
    eq(lone.truncated, false, "and is not called truncated")
    child.keep(lone, "tail")
    eq(child.text(lone), "tail", "the next chunk pushes it out: the newest output wins")
    eq(lone.truncated, true, "which is a truncation")

    local crlf = child.new_buffer()
    child.keep(crlf, "a\r\nb")
    child.keep(crlf, "\r\nc")
    eq(child.text(crlf), "a\nb\nc", "CRLF is folded to LF")
    eq(
      child.text({ chunks = { "x", "y" }, bytes = 2, truncated = false }),
      "xy",
      "a buffer built by hand reads"
    )
  end)

  -- ===================================================================
  -- 2. dropping the oldest output costs the same however small the chunks are
  do
    local cap = child.OUTPUT_CAP
    local total = 6 * cap -- the buffer drops all but a sixth, one byte at a time
    local digits = {}
    for d = 0, 9 do
      digits[d] = tostring(d)
    end
    local buf = child.new_buffer()
    local limit_s = 20
    local t0 = vim.uv.hrtime()
    local fed = 0
    for i = 1, total do
      child.keep(buf, digits[(i - 1) % 10])
      fed = i
      -- a quadratic buffer is red after the limit, not after the minutes it needs for the whole loop
      if i % 4096 == 0 and (vim.uv.hrtime() - t0) / 1e9 > limit_s then
        break
      end
    end
    local took = (vim.uv.hrtime() - t0) / 1e9
    ok(fed == total, ("only %d of %d one-byte chunks were fed in %.1f s"):format(fed, total, took))
    local text = child.text(buf)
    eq(#text, cap, "one byte per chunk: exactly the cap is kept")
    local from = total - cap + 1
    eq(
      text:sub(1, 10),
      (("0123456789"):rep(2)):sub((from - 1) % 10 + 1, (from - 1) % 10 + 10),
      "starting where the newest output starts"
    )
    eq(text:sub(-1), digits[(total - 1) % 10], "and ending with the last byte written")
    eq(buf.truncated, true, "it says that older output was dropped")
    ok(
      #buf.chunks <= 2 * cap + 1,
      "the array does not keep the dead front for ever: " .. #buf.chunks
    )
    -- every drop used to move all the live chunks: about 0.2 ms per byte at this size, minutes for the run. The limit is
    -- far above what a loaded machine needs for a linear loop and far below the quadratic one.
    ok(took < limit_s, ("%d one-byte chunks took %.1f s"):format(total, took))
  end

  -- ===================================================================
  -- 3. a process that floods its stderr through a pipe is drained, not blocked, and the capture is capped
  do
    local root = S.new_root()
    local script = root .. "/flood.lua"
    S.write(
      script,
      [==[
for i = 1, 3000 do
  io.stderr:write(("e"):rep(499), "\n")
end
io.stderr:write("END-OF-FLOOD\n")
]==]
    )
    local plan = child.build({ entry = { rel = "x" }, root = root })
    plan.argv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }
    local pok, perr = child.prepare(plan)
    ok(pok, "the sandbox is prepared: " .. tostring(perr))
    local done = false
    local h, serr = child.spawn(plan, function()
      done = true
    end)
    ok(h ~= nil, "the flooding process starts: " .. tostring(serr))
    if h then
      -- no timing claim: a process that is blocked on a full pipe never ends, so this is only the point at which the
      -- spec gives up waiting
      vim.wait(120000, function()
        return done
      end, 20)
      ok(done, "the process ended: a full pipe did not block it")
      eq(h.exit and h.exit.code, 0, "with exit code 0")
      local text = child.text(h.err)
      ok(#text <= child.OUTPUT_CAP, "its stderr is capped: " .. #text)
      eq(h.err.truncated, true, "and says it is truncated (3000 lines of 500 bytes are 1.5 MB)")
      ok(
        text:sub(-13) == "END-OF-FLOOD\n",
        "the newest output is what is kept: " .. vim.inspect(text:sub(-30))
      )
      eq(h.stdout.bytes, 0, "nothing came through stdout")
    end
    child.cleanup(plan)
  end

  S.cleanup()
end
