---@module 'testing.run.events_reader'
---@brief The editor side of `--events -`: bytes from a pipe in, validated events out.
---@description
--- An editor that starts the driver as a child (`vim.system` with a stdout callback) gets the NDJSON stream of
--- `testing.run.events` in arbitrary chunks. This turns the chunks into events:
---
---   * a **line buffer** across chunk boundaries (a line can arrive in three pieces; `\r\n` is a line end too);
---   * a **size limit per line**: a line over `max_line` is dropped as a whole (even if its end arrives later) and
---     reported once, so a runaway line cannot fill memory;
---   * `pcall(json.decode)` and a **type check** per event kind: a line that fails is a `problem`, never an event,
---     never an error;
---   * **words of the project under test** (file names, case ids) lose control characters and bidi overrides and
---     are capped, whatever the emitter did: this module does not trust its input (SEC-32/33/45);
---   * unknown kinds and unknown fields are ignored (the format grows additively), unknown versions are refused;
---   * **the end**: `finish()` says how the stream ended. A stream that stops without `run_done` is an abort (the
---     driver was killed or crashed): the reader emits a `run_done` of its own with `aborted = true`,
---     `synthetic = true`, so a UI never waits for an end that will not come, and the cases announced before the
---     kill stay what they were.
---
--- No UI, no process handling: the caller owns the pipe.
---
---```lua
--- local reader = require("testing.run.events_reader").new({
---   on_event = function(ev) ... end,
---   on_problem = function(msg) ... end,   -- optional
--- })
--- vim.system(cmd, { stdout = function(_, data) if data then reader:feed(data) end end }, function(obj)
---   reader:finish(obj.code)
--- end)
---```

local events = require("testing.run.events")

local M = {}

---Longest line accepted (bytes).
---@type integer
M.MAX_LINE = 64 * 1024
---Most problems reported before they are only counted.
---@type integer
M.MAX_PROBLEMS = 20

local STATUS = {
  pass = true,
  fail = true,
  error = true,
  skip = true,
  xfail = true,
  xpass = true,
  timeout = true,
  crash = true,
}
local VERDICT = { green = true, ["green-partial"] = true, red = true }

---A word of the project under test: control characters and bidi overrides replaced, capped.
---@param s any
---@return string|nil
local function word(s)
  if type(s) ~= "string" then
    return nil
  end
  if #s > events.MAX_STRING then
    -- on a character boundary: a cut through a multi-byte character would hand the consumer invalid UTF-8
    s = require("testing.report.util").cap(s, events.MAX_STRING)
  end
  s = s:gsub("[%z\1-\31\127]", "?")
  -- C1 controls (U+0080..U+009F) and the bidi overrides/isolates (U+202A..U+202E, U+2066..U+2069)
  s = s:gsub("\194[\128-\159]", "?")
  s = s:gsub("\226\128[\170-\174]", "?")
  s = s:gsub("\226\129[\166-\169]", "?")
  return s
end

---@param n any
---@param max? number
---@return number|nil
local function count(n, max)
  if type(n) ~= "number" or n ~= n or n < 0 or n > (max or 1e12) then
    return nil
  end
  return n
end

---@param n any
---@return integer|nil
local function int(n)
  local c = count(n)
  return c and c == math.floor(c) and c or nil
end

---@param raw table
---@return table[]|nil
local function word_list(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local out = {}
  for i = 1, math.min(#raw, events.MAX_PLAN_FILES) do
    local w = word(raw[i])
    if not w then
      return nil
    end
    out[i] = w
  end
  return out
end

-- One validator per event kind: returns the event with the fields it trusts, or nil + why.
---@type table<string, fun(raw: table): table|nil, string|nil>
local KINDS = {
  run_start = function(raw)
    local files = raw.files ~= nil and word_list(raw.files) or nil
    if raw.files ~= nil and not files then
      return nil, "files: not a list of strings"
    end
    return {
      project = word(raw.project),
      files_total = int(raw.files_total),
      files_selected = int(raw.files_selected),
      files = files,
      plan_truncated = raw.plan_truncated == true or nil,
      cases_estimate = int(raw.cases_estimate),
      cases_estimated = raw.cases_estimated == true or nil,
    }
  end,
  file_start = function(raw)
    local file = word(raw.file)
    if not file or file == "" then
      return nil, "file_start: no file"
    end
    return {
      file = file,
      cases_estimate = int(raw.cases_estimate),
      cases_estimated = raw.cases_estimated == true or nil,
    }
  end,
  case = function(raw)
    local file, id = word(raw.file), word(raw.id)
    if not file or not id or id == "" then
      return nil, "case: no file or id"
    end
    if not STATUS[raw.status] then
      return nil, "case: unknown status"
    end
    local ms = count(raw.duration_ms)
    if ms == nil then
      return nil, "case: bad duration"
    end
    return {
      file = file,
      id = id,
      status = raw.status,
      duration_ms = ms,
      cached = raw.cached == true or nil,
    }
  end,
  file_end = function(raw)
    local file = word(raw.file)
    if not file or file == "" then
      return nil, "file_end: no file"
    end
    return {
      file = file,
      cases = int(raw.cases) or 0,
      failed = int(raw.failed) or 0,
      duration_ms = count(raw.duration_ms) or 0,
    }
  end,
  run_done = function(raw)
    local summary
    if type(raw.summary) == "table" then
      summary = {}
      for status in pairs(STATUS) do
        summary[status] = int(raw.summary[status]) or 0
      end
    end
    return {
      exit_code = int(raw.exit_code),
      verdict = VERDICT[raw.verdict] and raw.verdict or nil,
      summary = summary,
      aborted = raw.aborted == true or nil,
    }
  end,
  watch_change = function(raw)
    return { files = word_list(raw.files) or {}, count = int(raw.count) }
  end,
}

---Validate one decoded line into an event.
---@param raw any
---@return table|nil event
---@return string|nil why
function M.event(raw)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  if raw.v ~= events.VERSION then
    return nil, "unknown version"
  end
  if type(raw.event) ~= "string" then
    return nil, "no event kind"
  end
  local check = KINDS[raw.event]
  if not check then
    return nil, nil -- a kind this reader does not know: ignored, not a problem
  end
  local ev, why = check(raw)
  if not ev then
    return nil, why
  end
  ev.event = raw.event
  ev.v = raw.v
  ev.run = int(raw.run)
  ev.ts = count(raw.ts)
  return ev
end

---@class Testing.EventsReader
---@field problems integer How many lines were refused.
---@field ignored integer How many lines were of a kind this reader does not know.
---@field events integer How many events were delivered.
---@field ended boolean `run_done` was delivered (by the stream or by `finish`).
---@field private _buf string
---@field private _skipping boolean
---@field private _opts table
local Reader = {}
Reader.__index = Reader

---@class Testing.EventsReader.Opts
---@field on_event fun(ev: table)
---@field on_problem? fun(msg: string)
---@field max_line? integer

---@param opts Testing.EventsReader.Opts
---@return Testing.EventsReader
function M.new(opts)
  assert(
    type(opts) == "table" and type(opts.on_event) == "function",
    "events_reader.new: on_event is required"
  )
  return setmetatable({
    problems = 0,
    ignored = 0,
    events = 0,
    ended = false,
    _buf = "",
    _skipping = false,
    _opts = opts,
  }, Reader)
end

---@param msg string
function Reader:_problem(msg)
  self.problems = self.problems + 1
  if self._opts.on_problem and self.problems <= M.MAX_PROBLEMS then
    pcall(self._opts.on_problem, msg)
  end
end

---@param ev table
function Reader:_deliver(ev)
  self.events = self.events + 1
  if ev.event == "run_done" then
    self.ended = true
  end
  -- a consumer that raises must not break the stream
  pcall(self._opts.on_event, ev)
end

---@param line string
function Reader:_line(line)
  if line == "" then
    return
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, line)
  if not ok or type(decoded) ~= "table" then
    self:_problem("a line is not JSON")
    return
  end
  local ev, why = M.event(decoded)
  if ev then
    self:_deliver(ev)
  elseif why then
    self:_problem(why)
  else
    self.ignored = self.ignored + 1
  end
end

---Bytes from the pipe, in any piece.
---@param chunk string
function Reader:feed(chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return
  end
  local max = self._opts.max_line or M.MAX_LINE
  local from = 1
  while from <= #chunk do
    local nl = chunk:find("\n", from, true)
    local piece = chunk:sub(from, (nl or #chunk + 1) - 1)
    if self._skipping then
      -- the rest of a line that was too long
      if nl then
        self._skipping = false
      end
    else
      self._buf = self._buf .. piece
      if #self._buf > max then
        self._buf = ""
        self._skipping = not nl
        self:_problem("a line is longer than " .. max .. " bytes: dropped")
      elseif nl then
        local line = self._buf:gsub("\r$", "")
        self._buf = ""
        self:_line(line)
      end
    end
    if not nl then
      break
    end
    from = nl + 1
  end
end

---The pipe is closed. A last line without a newline is read; a stream that has no `run_done` was aborted: the
---reader says so with a `run_done` of its own.
---@param exit_code? integer The exit code of the process, when the caller knows it.
function Reader:finish(exit_code)
  if self._buf ~= "" and not self._skipping then
    local line = self._buf:gsub("\r$", "")
    self._buf = ""
    -- a half line at the end is what a killed writer leaves: it may not parse, and that is not worth a problem
    local ok, decoded = pcall(require("lib.nvim.json").decode, line)
    if ok and type(decoded) == "table" then
      local ev = M.event(decoded)
      if ev then
        self:_deliver(ev)
      end
    end
  end
  self._buf, self._skipping = "", false
  if not self.ended then
    self:_deliver({
      event = "run_done",
      v = events.VERSION,
      exit_code = exit_code,
      aborted = true,
      synthetic = true,
    })
  end
end

return M
