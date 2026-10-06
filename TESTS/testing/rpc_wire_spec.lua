-- TESTS/testing/rpc_wire_spec.lua -- the msgpack-rpc client of testing.rpc, with canned bytes (no process):
-- framing of requests, responses split at every byte, several messages in one chunk, errors, handles
-- (ext types) as integers, notifications, a request FROM the child is refused, garbage breaks the stream.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local wire_mod = require("testing.rpc.wire")

  ---@param write_ok? boolean
  local function new(write_ok)
    local t = { written = {}, notes = {} }
    t.wire = wire_mod.new({
      write = function(bytes)
        t.written[#t.written + 1] = bytes
        return write_ok ~= false
      end,
      on_notify = function(method, args)
        t.notes[#t.notes + 1] = { method, args }
      end,
    })
    return t
  end

  -- a request is [0, id, method, params]
  do
    local t = new()
    local id, err = t.wire:request("nvim_eval", { "1+1" })
    ok(id and not err, "request is sent")
    eq(vim.mpack.decode(t.written[1]), { 0, id, "nvim_eval", { "1+1" } }, "request framing")
    local id2 = t.wire:request("nvim_eval", { "2" })
    ok(id2 ~= id, "request ids are unique")
    ok(t.wire.pending[id] and not t.wire.pending[id].done, "the request is pending")
  end

  -- a response split at EVERY byte still arrives (the stream has no message boundaries)
  do
    local t = new()
    local id = assert(t.wire:request("m", {}))
    local bytes = vim.mpack.encode({ 1, id, vim.NIL, { "hello", 42, { k = "v" } } })
    for i = 1, #bytes do
      t.wire:feed(bytes:sub(i, i))
    end
    local slot = t.wire.pending[id]
    ok(
      slot and slot.done and slot.ok,
      "the response of a one-byte-at-a-time stream completes the call"
    )
    eq(slot.result, { "hello", 42, { k = "v" } }, "result of the split response")
    ok(t.wire:take(id) == slot, "take returns the finished slot")
    ok(t.wire.pending[id] == nil, "take removes it")
  end

  -- two messages in one chunk, plus the first byte of a third
  do
    local t = new()
    local a, b = t.wire:request("a", {}), t.wire:request("b", {})
    local m1 = vim.mpack.encode({ 1, a, vim.NIL, "A" })
    local m2 = vim.mpack.encode({ 2, "note", { 1, 2 } })
    local m3 = vim.mpack.encode({ 1, b, vim.NIL, "B" })
    t.wire:feed(m1 .. m2 .. m3:sub(1, 1))
    ok(t.wire.pending[a].done, "first response of a batch")
    ok(not t.wire.pending[b].done, "the half-received one waits")
    eq(t.notes, { { "note", { 1, 2 } } }, "the notification in between is delivered")
    t.wire:feed(m3:sub(2))
    ok(t.wire.pending[b].done and t.wire.pending[b].result == "B", "the rest completes it")
  end

  -- an error response: [type, message]
  do
    local t = new()
    local id = t.wire:request("m", {})
    t.wire:feed(vim.mpack.encode({ 1, id, { 1, "Invalid buffer id: 999" }, vim.NIL }))
    local slot = t.wire.pending[id]
    ok(slot.done and slot.ok == false, "an error response fails the call")
    eq(slot.err, { kind = 1, message = "Invalid buffer id: 999" }, "error type and message")
  end

  -- Buffer/Window/Tabpage (ext types 0/1/2 holding an integer) become plain integers
  do
    local t = new()
    local id = assert(t.wire:request("nvim_get_current_buf", {}))
    -- [1, id, nil, <ext type 0: fixext1 holding the integer 7>]
    t.wire:feed("\x94\x01" .. string.char(id) .. "\xc0\xd4\x00\x07")
    eq(t.wire.pending[id].result, 7, "a buffer handle is an integer")
  end

  -- the answer of a call nobody waits for any more is dropped, not an error
  do
    local t = new()
    local id = assert(t.wire:request("m", {}))
    t.wire:forget(id)
    t.wire:feed(vim.mpack.encode({ 1, id, vim.NIL, 1 }))
    ok(t.wire.broken == nil, "an unknown id does not break the stream")
    ok(t.wire.pending[id] == nil, "and creates nothing")
  end

  -- a request FROM the child is refused with an error answer (it must not wait for ever, and the
  -- host never serves it)
  do
    local t = new()
    t.wire:feed(vim.mpack.encode({ 0, 77, "nvim_exec_lua", { "os.exit(1)", {} } }))
    local reply = vim.mpack.decode(t.written[1])
    eq(reply[1], 1, "the answer is a response")
    eq(reply[2], 77, "to that request id")
    ok(
      type(reply[3]) == "table" and tostring(reply[3][2]):find("does not serve", 1, true),
      "with an error"
    )
    eq(t.notes, {}, "and the request is not delivered anywhere")
  end

  -- garbage on the stream breaks it, loudly, and requests are refused afterwards
  do
    local t = new()
    t.wire:feed("\xc1\xc1\xc1")
    ok(t.wire.broken ~= nil, "garbage is a protocol error")
    local id, err = t.wire:request("m", {})
    ok(id == nil and err and err:find("broken", 1, true), "a broken stream refuses requests")
  end

  -- a failed write leaves no pending call behind
  do
    local t = new(false)
    local id, err = t.wire:request("m", {})
    ok(id == nil and err and err:find("stdin", 1, true), "write failure is reported")
    eq(next(t.wire.pending), nil, "nothing is left pending")
  end

  -- an argument that cannot be encoded is an error of the call, not a crash
  do
    local t = new()
    local id, err = t.wire:request("m", { function() end })
    ok(
      id == nil and err and err:find("cannot encode", 1, true),
      "a function argument is refused: " .. tostring(err)
    )
  end

  -- the size cap of one request
  do
    local t = new()
    local saved = wire_mod.MAX_REQUEST
    wire_mod.MAX_REQUEST = 100
    local id, err = t.wire:request("m", { ("x"):rep(500) })
    wire_mod.MAX_REQUEST = saved
    ok(id == nil and err and err:find("too large", 1, true), "an oversized request is refused")
    eq(#t.written, 0, "and not written")
  end
end
