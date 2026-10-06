---@module 'testing.run.timeout'
---@brief Best-effort in-process timeouts for a spec file and for single cases.
---@description
--- A spec that hangs must not hang the run (guard rail L2). Lua in one Neovim cannot be preempted, so
--- this module injects an error into the running spec instead, with two mechanisms:
---
---   * a COUNT HOOK (`debug.sethook(fn, "", N)`): every `N` VM instructions the hook compares the clock
---     with the deadlines and raises `testing: timeout: ...` when one has passed. This stops a spec that
---     spins in Lua (`while true do end`, a retry loop without exit). LuaJIT does not call hooks from
---     JIT-compiled traces, so the compiler is switched off for as long as a guard is active (and
---     back on afterwards, if it was on);
---   * a `vim.wait` WRAPPER: `vim.wait(ms, cond)` is clamped to the time that is left and raises when the
---     clamped wait ran out. This stops the other common hang, waiting for a condition that never comes.
---
--- Known limits (not hidden, see `docs`/`run/README.md`): a spec that blocks inside C, e.g.
--- `vim.system(...):wait()` without a timeout, `io.read`, a blocking `vim.fn.system`, a stuck RPC call,
--- cannot be interrupted. Only a child process that can be killed (the isolated driver of M2) gives a
--- hard kill. A spec that catches the raised error with `pcall` keeps running; the FILE deadline is
--- persistent (it raises again at the next check), the CASE deadline is one-shot (it must not fire
--- again inside the runner's own bookkeeping) and is re-armed by `guard:arm_case()`.
---
--- Guards nest (a run of this project inside one of its own specs): the hook checks every active
--- guard, innermost first, and the machinery (hook, JIT state, `vim.wait`) is restored only when the
--- last guard stops.

local M = {}

-- Everything the count hook touches is bound HERE, at load time. A spec may stub `vim.uv.hrtime`,
-- `os.clock` or `error` (a spec of the code under test that fakes time is common); the guard must
-- never read such a stub, or a faked clock turns into a bogus timeout (and a verdict that depends on
-- the instruction count between two hook calls). The hook calls nothing through `vim.uv`.
local hrtime = vim.uv.hrtime
local sethook = debug.sethook
local gethook = debug.gethook
local error_ = error
local ipairs_ = ipairs
local fmt = string.format
local huge = math.huge

---Prefix of every error this module raises; the driver recognizes a timeout case by it.
---@type string
M.MARKER = "testing: timeout:"

---Instructions between two clock checks. Small enough to react within milliseconds, large enough
---that the check is cheap.
---@type integer
M.HOOK_COUNT = 10000

---@class Testing.Timeout.Guard
---@field label string What is guarded (for the message), e.g. a spec path.
---@field file_ms integer|nil
---@field case_ms integer|nil
---@field file_deadline number|nil Clock value (ms) after which the file is over; nil = none.
---@field case_deadline number|nil Clock value of the current case window; nil = none or already fired.
---@field fired_file boolean The file deadline passed.
---@field fired_case boolean A case deadline passed since the last `take_case`.
---@field stopped boolean
---@field clock fun(): number
local Guard = {}
Guard.__index = Guard

---@type Testing.Timeout.Guard[]
local active = {}

---@class Testing.Timeout.Saved
---@field hook function|nil
---@field mask string|nil
---@field count integer|nil
---@field jit_was_on boolean
---@field wait function

---@type Testing.Timeout.Saved|nil
local saved

local function hrtime_ms()
  return hrtime() / 1e6
end

---@param g Testing.Timeout.Guard
---@param what string
---@param ms integer
local function raise(g, what, ms)
  error_(fmt("%s %s exceeded %d ms (in-process best effort): %s", M.MARKER, what, ms, g.label), 0)
end

---Check every active guard; raises when a deadline has passed. Called by the hook and the wait wrapper.
local function check()
  for i = #active, 1, -1 do
    local g = active[i]
    local now = g.clock()
    if g.file_deadline and now >= g.file_deadline then
      g.fired_file = true
      raise(g, "file", g.file_ms --[[@as integer]])
    end
    if g.case_deadline and now >= g.case_deadline then
      g.case_deadline = nil
      g.fired_case = true
      raise(g, "case", g.case_ms --[[@as integer]])
    end
  end
end

---Smallest time (ms) left before any deadline; nil when no guard has one.
---@return number|nil
local function remaining()
  local best
  for _, g in ipairs_(active) do
    local now = g.clock()
    for _, d in ipairs_({ g.file_deadline or huge, g.case_deadline or huge }) do
      if d ~= huge then
        local left = d - now
        if best == nil or left < best then
          best = left
        end
      end
    end
  end
  return best
end

---@param real function The unwrapped `vim.wait`.
---@return function
local function wrap_wait(real)
  return function(timeout, cond, interval, fast_only)
    local left = remaining()
    if left == nil or type(timeout) ~= "number" then
      return real(timeout, cond, interval, fast_only)
    end
    if left <= 0 then
      check()
    end
    local clamped = timeout > left
    if clamped then
      timeout = math.ceil(left) + 1
    end
    local ok, code = real(timeout, cond, interval, fast_only)
    if clamped and not ok then
      -- the clamped wait ran out: the deadline has passed (or is a millisecond away)
      check()
    end
    return ok, code
  end
end

local function install()
  local hook, mask, count = gethook()
  saved = {
    hook = hook,
    mask = mask,
    count = count,
    jit_was_on = (jit ~= nil and jit.status() == true),
    wait = vim.wait,
  }
  if jit then
    jit.off()
  end
  sethook(check, "", M.HOOK_COUNT)
  vim.wait = wrap_wait(saved.wait)
end

local function uninstall()
  local s = saved
  saved = nil
  if not s then
    return
  end
  sethook()
  if s.hook then
    sethook(s.hook, s.mask or "", s.count or 0)
  end
  vim.wait = s.wait
  if s.jit_was_on and jit then
    jit.on()
  end
end

---@class Testing.Timeout.Opts
---@field label? string
---@field file_ms? integer Deadline of the whole file, from now.
---@field case_ms? integer Window of one case, from now (re-armed with `arm_case`).
---@field clock? fun(): number Monotonic milliseconds (default: `uv.hrtime`, bound at load time).

---Start guarding. The caller MUST `stop` the guard (also after an error).
---@param opts? Testing.Timeout.Opts
---@return Testing.Timeout.Guard
function M.start(opts)
  opts = opts or {}
  local clock = opts.clock or hrtime_ms
  local now = clock()
  ---@type Testing.Timeout.Guard
  local g = setmetatable({
    label = opts.label or "?",
    file_ms = opts.file_ms,
    case_ms = opts.case_ms,
    file_deadline = opts.file_ms and (now + opts.file_ms) or nil,
    case_deadline = opts.case_ms and (now + opts.case_ms) or nil,
    fired_file = false,
    fired_case = false,
    stopped = false,
    clock = clock,
  }, Guard)
  if #active == 0 then
    install()
  end
  active[#active + 1] = g
  return g
end

---A new case window starts now (the previous case ended).
function Guard:arm_case()
  self.fired_case = false
  if self.case_ms and not self.stopped then
    self.case_deadline = self.clock() + self.case_ms
  end
end

---True once (and clears the flag) when a case deadline fired since the last call.
---@return boolean
function Guard:take_case()
  local fired = self.fired_case
  self.fired_case = false
  return fired
end

---Run `fn` with this guard's deadlines out of the way and put them back afterwards: the runner's own
---bookkeeping (what the guard layer checks after a case, for instance) must not be cut off by the
---deadline the spec has just exceeded; the error would be blamed on the guard layer ("diff of env
---failed: testing: timeout"). The deadlines are persistent: the spec is stopped again as soon as `fn`
---is over.
---@param fn fun(): any, any
---@return any a The first result of `fn`.
---@return any b The second result of `fn`.
function Guard:suspend(fn)
  local file_deadline, case_deadline = self.file_deadline, self.case_deadline
  self.file_deadline, self.case_deadline = nil, nil
  local ok, a, b = pcall(fn)
  if not self.stopped then
    self.file_deadline = file_deadline
    self.case_deadline = case_deadline
  end
  if not ok then
    error(a, 0)
  end
  return a, b
end

---Stop guarding. Safe to call twice. Returns whether the FILE deadline fired.
---@return boolean fired_file
function Guard:stop()
  -- Every step is idempotent, so a caller whose `stop` was cut short by the hook of an OUTER guard
  -- can simply call it again.
  self.file_deadline, self.case_deadline = nil, nil
  self.stopped = true
  for i = #active, 1, -1 do
    if active[i] == self then
      table.remove(active, i)
      break
    end
  end
  if #active == 0 then
    uninstall()
  end
  return self.fired_file
end

---Number of active guards (specs and the cleanup of a crashed run).
---@return integer
function M.depth()
  return #active
end

---Is this error message one of ours?
---@param message any
---@return boolean
function M.is_timeout(message)
  return type(message) == "string" and message:find(M.MARKER, 1, true) ~= nil
end

return M
