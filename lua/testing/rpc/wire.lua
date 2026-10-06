---@module 'testing.rpc.wire'
---@brief The msgpack-rpc client side of `testing.rpc`: framing, request table, handle decoding.
---@description
--- Speaks the Neovim API protocol (msgpack-rpc: `[0, id, method, params]` requests,
--- `[1, id, error, result]` responses, `[2, method, params]` notifications) over a byte stream the
--- caller owns. It owns no process and no pipe, so it is testable with canned bytes.
---
--- Why not `jobstart({ rpc = true })`: `vim.rpcrequest` blocks WITHOUT a timeout (a child in an
--- endless loop would hang the run, which this driver must never do) and a `rpc = true` job lets the
--- child call the PARENT's API (`vim.rpcnotify(1, 'nvim_exec_lua', ...)` would run code in the
--- editor that runs the tests). Here the parent decides what a message from the child means: a
--- request FROM the child is answered with an error, a notification goes to `on_notify`.
---
--- `feed` runs in a libuv read callback (fast context): no `vim.api`, no `vim.fn`. Decoding uses
--- `vim.mpack.Unpacker`, which keeps the state of a half-received message between chunks.

local M = {}

---@class Testing.Rpc.Pending
---@field method string
---@field done boolean
---@field ok? boolean
---@field result? any
---@field err? { kind: integer, message: string }
---@field on_done? fun(slot: Testing.Rpc.Pending) Asynchronous caller (`request_async`): runs when the answer arrives.

---@class Testing.Rpc.Wire
---@field pending table<integer, Testing.Rpc.Pending>
---@field next_id integer
---@field write fun(bytes: string): boolean
---@field on_notify fun(method: string, args: table)
---@field unpack fun(data: string, pos: integer): any, integer
---@field broken? string Protocol error (garbage on the stream); the stream is unusable.
---@field bytes_in integer
---@field bytes_out integer
local Wire = {}
Wire.__index = Wire

---Handle objects (Buffer/Window/Tabpage) arrive as ext types 0/1/2 holding a msgpack integer: they
---become plain integers (a handle is only a number; it is validated by the child when it is used).
---@param _ integer
---@param data string
---@return integer
local function ext_handle(_, data)
  local ok, n = pcall(vim.mpack.decode, data)
  return ok and n or 0
end

---@class Testing.Rpc.WireOpts
---@field write fun(bytes: string): boolean Write bytes to the child (false: its stdin is closed).
---@field on_notify? fun(method: string, args: table) Called for every notification of the child (fast context).

---@param opts Testing.Rpc.WireOpts
---@return Testing.Rpc.Wire
function M.new(opts)
  return setmetatable({
    pending = {},
    next_id = 1,
    write = opts.write,
    on_notify = opts.on_notify or function() end,
    unpack = vim.mpack.Unpacker({ ext = { [0] = ext_handle, [1] = ext_handle, [2] = ext_handle } }),
    bytes_in = 0,
    bytes_out = 0,
  }, Wire)
end

---Largest request the driver sends (bytes). A bigger one is a programming error, not a payload.
M.MAX_REQUEST = 16 * 1024 * 1024

---Send a request.
---@param method string
---@param args any[]
---@param on_done? fun(slot: Testing.Rpc.Pending) Called when the answer arrived (fast context: schedule before touching the editor).
---@return integer|nil id
---@return string|nil err
function Wire:request(method, args, on_done)
  if self.broken then
    return nil, "the rpc stream is broken: " .. self.broken
  end
  local id = self.next_id
  self.next_id = (self.next_id % 0x7fffffff) + 1
  local ok, bytes = pcall(vim.mpack.encode, { 0, id, method, args })
  if not ok then
    return nil, ("cannot encode the arguments of %s: %s"):format(method, tostring(bytes))
  end
  if #bytes > M.MAX_REQUEST then
    return nil, ("the request %s is too large (%d bytes)"):format(method, #bytes)
  end
  self.pending[id] = { method = method, done = false, on_done = on_done }
  self.bytes_out = self.bytes_out + #bytes
  if not self.write(bytes) then
    self.pending[id] = nil
    return nil, "cannot write to the child (its stdin is closed)"
  end
  return id, nil
end

---Send a notification (no answer).
---@param method string
---@param args any[]
---@return boolean ok
function Wire:notify(method, args)
  local ok, bytes = pcall(vim.mpack.encode, { 2, method, args })
  if not ok then
    return false
  end
  return self.write(bytes)
end

---@param msg any[]
function Wire:_dispatch(msg)
  local kind = msg[1]
  if kind == 1 then
    local slot = self.pending[msg[2]]
    if not slot then
      return -- the answer of a call that timed out: nobody waits for it any more
    end
    slot.done = true
    local e = msg[3]
    if e ~= nil and e ~= vim.NIL then
      slot.ok = false
      slot.err = {
        kind = type(e) == "table" and tonumber(e[1]) or -1,
        message = type(e) == "table" and tostring(e[2]) or tostring(e),
      }
    else
      slot.ok = true
      slot.result = msg[4]
    end
    if slot.on_done then
      pcall(slot.on_done, slot)
    end
  elseif kind == 2 then
    local ok, args = true, msg[3]
    if type(args) ~= "table" then
      ok, args = false, nil
    end
    if ok then
      self.on_notify(tostring(msg[2]), args)
    end
  elseif kind == 0 then
    -- A request FROM the child: never served. The answer keeps the child from waiting for ever.
    local reply = vim.mpack.encode({
      1,
      msg[2],
      { 0, "testing.rpc: the host does not serve requests from the child" },
      vim.NIL,
    })
    self.write(reply)
  end
end

---Feed bytes that arrived on the child's stdout.
---@param data string
function Wire:feed(data)
  if self.broken then
    return
  end
  self.bytes_in = self.bytes_in + #data
  local pos = 1
  while pos <= #data do
    local ok, obj, next_pos = pcall(self.unpack, data, pos)
    if not ok then
      self.broken = tostring(obj)
      return
    end
    pos = next_pos
    if obj ~= nil then
      if type(obj) == "table" then
        self:_dispatch(obj)
      end
    end
  end
end

---Forget a call whose caller gave up (its answer, if it ever comes, is dropped).
---@param id integer
function Wire:forget(id)
  self.pending[id] = nil
end

---Take the finished slot of `id` out of the table.
---@param id integer
---@return Testing.Rpc.Pending|nil
function Wire:take(id)
  local slot = self.pending[id]
  if slot and slot.done then
    self.pending[id] = nil
    return slot
  end
  return nil
end

return M
