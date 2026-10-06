---@module 'testing.rpc.trace'
---@brief The trace of an RPC child: a bounded ring of the last calls and events, written on timeout or crash.
---@description
--- When a child hangs or dies the question is always "what was it doing?". The driver keeps, in the
--- PARENT (the child cannot be asked any more):
---
---   * the last `MAX_CALLS` RPC calls: method, a short rendering of the arguments, start offset,
---     duration, outcome (`ok`, `error`, `timeout`, `died`) and the first line of an error;
---   * the last `MAX_EVENTS` events the child pushed on its own (`vim.notify` calls, prompts it
---     answered with "cancelled"; see `testing.child.rpc_boot`);
---   * the tail of the child's stderr.
---
--- `write` puts that in ONE small JSON file next to the IR and returns the artifact record
--- (`{ kind = "trace", path = ... }`) for `case.artifacts`. The file is:
---
---   * bounded: at most `MAX_BYTES` (SEC-32); the oldest calls/events go first and `truncated` says so;
---   * redacted like the IR: every string goes through the IR kernel (`testing.core.result.encode`:
---     paths to `<REPO>`/`<HOME>`/`<TMP>`/`<STATE>`, user and host name, environment pairs, e-mail
---     shapes), so a trace can travel with the IR as a CI artifact;
---   * written atomically (`lib.nvim.fs.write.atomic`).
---
--- The path in the artifact record is `<RUN>/<name>` when the file lies inside the run directory the
--- caller named (`run_dir`), otherwise the absolute path (the IR encoder then turns the temp
--- directory into `<TMP>`).

local M = {}

M.MAX_CALLS = 50
M.MAX_EVENTS = 100
M.MAX_STDERR = 16 * 1024
M.MAX_BYTES = 128 * 1024
M.MAX_ARG = 240
M.MAX_ERR = 400

---@class Testing.Rpc.TraceCall
---@field n integer Running number of the call in this child.
---@field method string
---@field args string
---@field at_ms number Milliseconds since the child started.
---@field ms? number Duration.
---@field status "pending"|"ok"|"error"|"timeout"|"died"
---@field err? string
---@field _t? number Internal: monotonic start (ms) of a pending call.

---@class Testing.Rpc.TraceEvent
---@field at_ms number
---@field kind string
---@field text string
---@field level? string

---@class Testing.Rpc.Trace
---@field calls Testing.Rpc.TraceCall[]
---@field events Testing.Rpc.TraceEvent[]
---@field count integer Calls made so far.
---@field t0 number Monotonic ms at the start.
local Trace = {}
Trace.__index = Trace

---@return Testing.Rpc.Trace
function M.new()
  return setmetatable({ calls = {}, events = {}, count = 0, t0 = vim.uv.hrtime() / 1e6 }, Trace)
end

---@param s any
---@param max integer
---@return string
local function clip(s, max)
  s = tostring(s):gsub("[%c]", " ")
  if #s > max then
    return s:sub(1, max) .. "..."
  end
  return s
end

---Short rendering of call arguments.
---@param args any
---@return string
local function render_args(args)
  local ok, text = pcall(vim.inspect, args, { newline = " ", indent = "", depth = 3 })
  return clip(ok and text or "<unprintable>", M.MAX_ARG)
end

---@return number
local function now()
  return vim.uv.hrtime() / 1e6
end

---Start of a call. Returns the record; finish it with `finish`.
---@param method string
---@param args any
---@return Testing.Rpc.TraceCall
function Trace:start(method, args)
  self.count = self.count + 1
  local call = {
    n = self.count,
    method = method,
    args = render_args(args),
    at_ms = math.floor(now() - self.t0),
    status = "pending",
  }
  self.calls[#self.calls + 1] = call
  if #self.calls > M.MAX_CALLS then
    table.remove(self.calls, 1)
  end
  call._t = now()
  return call
end

---@param call Testing.Rpc.TraceCall
---@param status "ok"|"error"|"timeout"|"died"
---@param err? string
function Trace:finish(call, status, err)
  call.status = status
  call.ms = math.floor((now() - (call._t or now())) * 10) / 10
  call._t = nil
  if err then
    call.err = clip(err:match("^[^\n]*") or err, M.MAX_ERR)
  end
end

---An event the child pushed.
---@param kind string
---@param text any
---@param level? string
function Trace:event(kind, text, level)
  self.events[#self.events + 1] = {
    at_ms = math.floor(now() - self.t0),
    kind = kind,
    text = clip(text, M.MAX_ERR),
    level = level,
  }
  if #self.events > M.MAX_EVENTS then
    table.remove(self.events, 1)
  end
end

---The trace as a plain table.
---@param extra table `reason`, `child` (pid, exit, ...), `stderr`.
---@return table
function Trace:snapshot(extra)
  local calls = {}
  for i, c in ipairs(self.calls) do
    calls[i] = {
      n = c.n,
      method = c.method,
      args = c.args,
      at_ms = c.at_ms,
      ms = c.ms,
      status = c.status,
      err = c.err,
    }
  end
  local stderr = extra.stderr or ""
  local stderr_cut = false
  if #stderr > M.MAX_STDERR then
    stderr = stderr:sub(-M.MAX_STDERR)
    stderr_cut = true
  end
  return {
    version = 1,
    reason = extra.reason,
    child = extra.child,
    calls_total = self.count,
    calls = calls,
    events = vim.deepcopy(self.events),
    stderr_tail = stderr,
    truncated = stderr_cut or self.count > #calls,
  }
end

---Redaction words of the IR kernel: user and host name.
---@return Testing.Result.Redact
local function redaction()
  local words = {}
  for _, w in ipairs({
    { vim.env.USERNAME or vim.env.USER, "<USER>" },
    { vim.uv.os_gethostname(), "<HOST>" },
    { vim.env.COMPUTERNAME or vim.env.HOSTNAME, "<HOST>" },
  }) do
    if type(w[1]) == "string" and #w[1] >= 3 then
      words[#words + 1] = { text = w[1], ph = w[2] }
    end
  end
  return { env_names = vim.tbl_keys(vim.fn.environ()), words = words }
end

---Pass every string of `value` (in place) through the IR kernel's path normalization and
---redaction. The strings are carried as the notes of one pseudo case: `encode` redacts exactly the
---free text of cases, so the trace gets the same treatment as a case note.
---@param value table
---@param root string
---@return boolean ok
---@return string|nil err
local function redact_in_place(value, root)
  local result = require("testing.core.result")
  local slots, list = {}, {}
  local function walk(t, depth)
    if depth > 8 then
      return
    end
    for k, v in pairs(t) do
      if type(v) == "string" then
        slots[#slots + 1] = { t, k }
        list[#list + 1] = v
      elseif type(v) == "table" then
        walk(v, depth + 1)
      end
    end
  end
  walk(value, 0)
  if #list == 0 then
    return true, nil
  end
  local roots = require("testing.run.inproc").path_roots(root)
  ---@diagnostic disable-next-line: missing-fields
  local text, err = result.encode({ cases = { { notes = list } } }, {
    roots = roots,
    case_insensitive = vim.fn.has("win32") == 1,
    redact = redaction(),
  })
  if not text then
    return false, err
  end
  local decoded = vim.json.decode(text)
  local notes = decoded and decoded.cases and decoded.cases[1] and decoded.cases[1].notes
  if type(notes) ~= "table" or #notes ~= #list then
    return false, "the redaction changed the number of strings"
  end
  for i, slot in ipairs(slots) do
    slot[1][slot[2]] = notes[i]
  end
  return true, nil
end

---Encode a snapshot within `MAX_BYTES`: the oldest calls and events are dropped until it fits.
---@param snap table
---@return string|nil json
---@return string|nil err
local function encode_capped(snap)
  local json = require("lib.nvim.json")
  for _ = 1, 40 do
    local text, err = json.encode(snap, { indent = "  " })
    if not text then
      return nil, err
    end
    if #text <= M.MAX_BYTES then
      return text, nil
    end
    snap.truncated = true
    if #snap.calls > 5 then
      for _ = 1, math.max(1, math.floor(#snap.calls / 4)) do
        table.remove(snap.calls, 1)
      end
    elseif #snap.events > 5 then
      for _ = 1, math.max(1, math.floor(#snap.events / 4)) do
        table.remove(snap.events, 1)
      end
    else
      snap.stderr_tail = snap.stderr_tail:sub(math.floor(#snap.stderr_tail / 2))
    end
  end
  return nil, "the trace does not fit into the size cap"
end

---@class Testing.Rpc.TraceWriteOpts
---@field path string File to write (the directory is created).
---@field root string Project root (the base of the `<REPO>` placeholder).
---@field run_dir? string Run directory: a file below it is reported as `<RUN>/<relative>`.

---Write the (redacted, capped) trace file.
---@param snap table A `Trace:snapshot`.
---@param opts Testing.Rpc.TraceWriteOpts
---@return { kind: string, path: string }|nil artifact
---@return string|nil err
function M.write(snap, opts)
  local ok, err = redact_in_place(snap, opts.root)
  if not ok then
    return nil, "cannot redact the trace: " .. tostring(err)
  end
  local text, eerr = encode_capped(snap)
  if not text then
    return nil, "cannot encode the trace: " .. tostring(eerr)
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(opts.path, text, { mkdirp = true })
  if not wrote then
    return nil, "cannot write the trace: " .. tostring(werr)
  end
  return { kind = "trace", path = M.artifact_path(opts.path, opts.run_dir) }, nil
end

---The path a trace gets in `case.artifacts`: `<RUN>/<name>` below the run directory, otherwise the
---normalized absolute path.
---@param path string
---@param run_dir? string
---@return string
function M.artifact_path(path, run_dir)
  local p = vim.fs.normalize(path)
  if run_dir and run_dir ~= "" then
    local base = vim.fs.normalize(run_dir):gsub("/+$", "")
    local ci = vim.fn.has("win32") == 1
    local a, b = ci and p:lower() or p, ci and base:lower() or base
    if a:sub(1, #b + 1) == b .. "/" then
      return "<RUN>/" .. p:sub(#b + 2)
    end
  end
  return p
end

return M
