---@module 'testing.run.events'
---@brief `--events <file>`: a machine-readable stream of what a run is doing, one JSON object per line.
---@description
--- The Result-IR (`--json`) exists only when a run is over. A supervisor (the hub app, a statusline, a CI
--- dashboard) that wants to SHOW a run needs the pieces while it goes. This is that channel: NDJSON, flushed
--- after every line, so a reader that tails the file sees a case the moment it is recorded.
---
--- EVENTS (every line has `v` (= `M.VERSION`), `event`, `ts` (unix seconds) and `run` (1-based, counts the runs
--- that wrote to this file in this process, so `--watch` produces run 1, 2, ...)):
---   * `run_start`   `project`, `files_total`, `files_selected`
---   * `case`        `file`, `id`, `status`, `duration_ms`, `cached` (true: not executed, from the result cache)
---   * `run_done`    (always preceded by a `run_start`, an empty one when the run ended before it began) `exit_code`, `verdict` (`green`|`green-partial`|`red`, absent when the run ended before one
---                   existed), `summary` (a counter per status, absent likewise)
---   * `watch_change` (only with `--watch`, only when a run follows) `files` (at most `M.MAX_FILES` project-relative paths), `count`
---
--- WHAT IT NEVER CARRIES: assertion text, error messages, notes, output of the code under test or absolute
--- paths. Case ids and file names come from the code under test and are treated as hostile: control characters,
--- bidi overrides and invalid UTF-8 are defused (`testing.report.util.clean`) and each string is capped. A
--- reader that wants the details reads the IR of the finished run.
---
--- FAILURE MODE. The stream is a convenience, never part of the verdict: a file that cannot be opened is a note
--- and the run goes on; a write that fails switches the stream off for the rest of the run, with one note. An
--- event that cannot be encoded is dropped. Nothing here raises into the runner.
---
--- STDOUT. `--events -` writes the stream to stdout, one line per event, flushed at once, so a supervisor that
--- spawns the run reads it from the pipe (no file to tail; end of file = the process is gone). Stdout then belongs
--- to the stream alone: what the run would print there (the reporter, the watch status lines) goes to stderr.
---
--- ABORT. When the editor is quit while a run is going (`:qa`, Ctrl-C that reaches the exit guard) every open stream
--- gets `run_done` with `exit_code = 3` and `aborted = true` before the process ends (`M.abort`). A process that is
--- killed hard (TerminateProcess, SIGKILL) cannot write anything: a stream that ends without `run_done` was
--- aborted, and the supervisor that killed the process must also kill its tree (child editors are not told).
---
--- ONE FILE, MANY RUNS. The first run of this process truncates the file, a later one (`--watch`) appends.
--- `M.reset()` forgets that (specs).

local util = require("testing.report.util")

local M = {}

---Version of the event format. Additive changes keep it; a reader ignores fields and kinds it does not know.
M.VERSION = 1
---Longest string an event carries (bytes).
M.MAX_STRING = 500
---Most paths in one `watch_change`.
M.MAX_FILES = 20

---Path that means "the stream goes to the standard output sink".
M.STDOUT = "-"

---Runs that wrote to a path in this process: path -> count.
---@type table<string, integer>
local runs_by_path = {}

---Streams that are open (a run is going): `M.abort` ends them.
---@type table<Testing.Events.Emitter, true>
local live = {}

---Forget which files this process already truncated and the streams that are open (specs).
function M.reset()
  runs_by_path = {}
  live = {}
end

---A line sink for `--events -` over the line writer of the process (`sv.out`): every line is flushed at once.
---@param out fun(s: string)
---@return fun(line: string): boolean
function M.stdout_sink(out)
  return function(line)
    out(line)
    pcall(io.stdout.flush, io.stdout)
    return true
  end
end

---@param s any
---@return string
local function text(s)
  local cleaned = util.clean(tostring(s), { c1 = true, bidi = true })
  local cut = util.cap(cleaned, M.MAX_STRING)
  return cut
end

---One NDJSON line (without the newline), or nil when the event cannot be encoded.
---@param kind string
---@param fields? table
---@param meta? { run?: integer, ts?: integer }
---@return string|nil line
function M.line(kind, fields, meta)
  meta = meta or {}
  local obj = { v = M.VERSION, event = kind, ts = meta.ts or os.time(), run = meta.run }
  for k, v in pairs(fields or {}) do
    if type(v) == "string" then
      obj[k] = text(v)
    elseif type(v) == "table" and type(v[1]) == "string" then
      local list = {}
      for i, item in ipairs(v) do
        list[i] = text(item)
      end
      obj[k] = list
    else
      obj[k] = v
    end
  end
  local ok, encoded = pcall(function()
    return (require("lib.nvim.json").encode(obj))
  end)
  if not ok or type(encoded) ~= "string" or encoded:find("[\r\n]") then
    return nil
  end
  return encoded
end

---@class Testing.Events.Emitter
---@field run integer
---@field alive boolean
---@field started? boolean A `run_start` was written.
---@field finished? boolean A `run_done` was written.
---@field emit fun(self: Testing.Events.Emitter, kind: string, fields?: table)
---@field case fun(self: Testing.Events.Emitter, case: Testing.Result.Case, cached?: boolean)
---@field done fun(self: Testing.Events.Emitter, exit_code: integer, res?: Testing.Result)
---@field close fun(self: Testing.Events.Emitter)
---@field result? Testing.Result Set by the runner once the verdict exists; `done` reads it.

local Emitter = {}
Emitter.__index = Emitter

---A stream over a writer. `write(line)` returns true or false + an error; `close()` is optional.
---@param write fun(line: string): boolean|nil, string|nil
---@param opts? { run?: integer, close?: fun(), on_error?: fun(msg: string) }
---@return Testing.Events.Emitter
function M.new(write, opts)
  opts = opts or {}
  return setmetatable({
    run = opts.run or 1,
    alive = true,
    _write = write,
    _close = opts.close,
    _on_error = opts.on_error,
  }, Emitter)
end

---@param kind string
---@param fields? table
function Emitter:emit(kind, fields)
  if not self.alive then
    return
  end
  if kind == "run_start" then
    self.started = true
  end
  local line = M.line(kind, fields, { run = self.run })
  if not line then
    return
  end
  local ok, wrote, werr = pcall(self._write, line)
  if not ok or wrote == false then
    self.alive = false
    if self._on_error then
      pcall(self._on_error, tostring(ok and werr or wrote))
    end
  end
end

---@param case Testing.Result.Case
---@param cached? boolean
function Emitter:case(case, cached)
  self:emit("case", {
    file = case.file,
    id = case.id,
    status = case.status,
    duration_ms = case.duration_ms,
    cached = (cached or case.cached) and true or nil,
  })
end

---`run_done` from the exit code and, when the run got that far, its result. Once per stream.
---@param exit_code integer
---@param res? Testing.Result
---@param extra? table Further fields (`aborted`).
function Emitter:done(exit_code, res, extra)
  if self.finished then
    return
  end
  self.finished = true
  if not self.started then
    -- the run ended before it began (a usage error): a consumer still sees a pair
    self:emit("run_start", {})
  end
  local verdict = res and res.run and res.run.verdict
  self:emit("run_done", {
    exit_code = exit_code,
    verdict = verdict and verdict.kind or nil,
    summary = res and res.summary or nil,
    aborted = extra and extra.aborted or nil,
  })
end

function Emitter:close()
  live[self] = nil
  self.alive = false
  if self._close then
    pcall(self._close)
  end
end

---One event that belongs to no run in progress (`watch_change`, written between two runs): appended to a stream
---an earlier run of this process opened, tagged with the number of the run it leads to. Does not count as a run;
---nothing happens when the file cannot be opened.
---@param path string
---@param kind string
---@param fields? table
---@param sink? fun(line: string) The writer of `M.STDOUT` (`M.stdout_sink`).
function M.note(path, kind, fields, sink)
  if not runs_by_path[path] then
    return
  end
  local line = M.line(kind, fields, { run = runs_by_path[path] + 1 })
  if not line then
    return
  end
  if path == M.STDOUT then
    if sink then
      pcall(sink, line)
    end
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  pcall(f.write, f, line, "\n")
  f:close()
end

---Open the stream `path` for one run: the first run of this process truncates, a later one appends.
---@param path string A file, or `M.STDOUT`.
---@param on_error? fun(msg: string)
---@param sink? fun(line: string): boolean|nil The writer of `M.STDOUT` (`M.stdout_sink`).
---@return Testing.Events.Emitter|nil emitter
---@return string|nil err
function M.open(path, on_error, sink)
  local previous = runs_by_path[path]
  local write, close
  if path == M.STDOUT then
    if not sink then
      return nil, "--events -: there is no standard output to write to"
    end
    write = sink
  else
    local f, err = io.open(path, previous and "a" or "w")
    if not f then
      return nil, ("--events: cannot open %s: %s"):format(path, tostring(err))
    end
    write = function(line)
      local ok, werr = f:write(line, "\n")
      if not ok then
        return false, werr
      end
      f:flush()
      return true
    end
    close = function()
      f:close()
    end
  end
  runs_by_path[path] = (previous or 0) + 1
  local emitter = M.new(write, { run = runs_by_path[path], on_error = on_error, close = close })
  live[emitter] = true
  return emitter, nil
end

---The editor is being quit while streams are open: every stream that has no `run_done` yet gets one that says
---`aborted`. Never raises (it runs in an exit handler).
function M.abort()
  for em in pairs(live) do
    pcall(em.done, em, 3, nil, { aborted = true })
  end
end

return M
