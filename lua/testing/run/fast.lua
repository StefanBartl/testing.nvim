---@module 'testing.run.fast'
---@brief `testing fast`, `--time-budget`: the likely specs first, an interim finding after them, a budget for the rest.
---@description
--- `testing fast` is `--cached --order priority` with a phase boundary. Phase 1 are the files the priority order has
--- a signal for (failed last time, changed, near a changed file); phase 2 is the rest, in the same run. When phase 1
--- is done one interim finding is printed (`fast: red for the 4 likely specs ... -- not final`) and written to the
--- event stream (`phase_done`); the verdict of the whole run replaces it. The interim finding never carries the
--- sentinel and never decides the exit code.
---
--- This module is the pure part: the duration of a budget, which files are phase 1, and the tracker that says when
--- phase 1 is over. The runner (`testing.run.project`) feeds it the cases it records.

local M = {}

---Stages of `testing.run.order` that count as "likely" (failed last time, changed, near a change).
M.LIKELY = { red = true, changed = true, near = true }

local BAD = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---A duration as seconds: `90`, `90s`, `1500ms`, `2m`, `1h`.
---@param text any
---@return number|nil seconds
---@return string|nil problem
function M.parse_duration(text)
  if type(text) ~= "string" then
    return nil, "a duration like 90s, 2m or 1h is needed"
  end
  local n, unit = text:match("^%s*(%d+%.?%d*)%s*(%a*)%s*$")
  if not n then
    return nil, ("'%s' is not a duration (90s, 2m, 1h)"):format(text)
  end
  local value = tonumber(n) --[[@as number]]
  local scale = ({ [""] = 1, s = 1, ms = 0.001, m = 60, h = 3600 })[unit]
  if not scale then
    return nil, ("'%s' is not a duration (90s, 2m, 1h)"):format(text)
  end
  local seconds = value * scale
  if seconds <= 0 then
    return nil, "a budget must be longer than zero"
  end
  return seconds
end

---Is a CI environment set (`CI` non-empty and not `false`/`0`)?
---@param given? string The value to judge instead of the process environment (a seam for specs).
---@return boolean
function M.in_ci(given)
  local v = given
  if v == nil then
    v = os.getenv("CI")
  end
  return v ~= nil and v ~= "" and v:lower() ~= "false" and v ~= "0"
end

---The files of phase 1, in run order: the ones the priority order had a signal for.
---@param ordered string[] The files in run order.
---@param info? table<string, { stage: string }> `testing.run.order.priority`'s info.
---@return string[] phase1
function M.phase1(ordered, info)
  local out = {}
  for _, rel in ipairs(ordered) do
    local i = info and info[rel]
    if i and M.LIKELY[i.stage] then
      out[#out + 1] = rel
    end
  end
  return out
end

---The interim line. `s` is what `Tracker:summary` returns.
---@param s { kind: string, specs: integer, cached: integer, ran: integer, failed: integer }
---@return string
function M.line(s)
  local head = ("fast: %s for the %d likely spec(s) (%d from cache, %d ran"):format(
    s.kind,
    s.specs,
    s.cached,
    s.ran
  )
  if s.kind == "red" then
    head = head .. (", %d failed"):format(s.failed)
  end
  return head .. ") -- not final, the run goes on"
end

---@class Testing.Fast.Tracker
---@field _pending table<string, boolean> Phase 1 files that still have to report a case.
---@field _all string[]
---@field _set table<string, boolean> The same files as a set.
---@field _cached integer
---@field _bad integer
---@field _skip integer
---@field _failed_files table<string, boolean>
---@field _fired boolean
---@field _emit fun(summary: table)
local Tracker = {}
Tracker.__index = Tracker

---@param o { phase1: string[], hits: table<string, any>|nil, emit: fun(summary: table) } `hits`: the files whose result comes from the cache (they report nothing during the run).
---@return Testing.Fast.Tracker
function M.tracker(o)
  local t = setmetatable({
    _pending = {},
    _all = o.phase1,
    _set = {},
    _cached = 0,
    _bad = 0,
    _skip = 0,
    _failed_files = {},
    _fired = false,
    _emit = o.emit,
  }, Tracker)
  for _, rel in ipairs(o.phase1) do
    t._set[rel] = true
    if o.hits and o.hits[rel] then
      t._cached = t._cached + 1
    else
      t._pending[rel] = true
    end
  end
  return t
end

---@return { kind: string, specs: integer, cached: integer, ran: integer, failed: integer }
function Tracker:summary()
  local kind = "green"
  if self._bad > 0 then
    kind = "red"
  elseif self._skip > 0 or next(self._pending) ~= nil then
    kind = "green-partial"
  end
  return {
    kind = kind,
    specs = #self._all,
    cached = self._cached,
    ran = #self._all - self._cached - vim.tbl_count(self._pending),
    failed = vim.tbl_count(self._failed_files),
  }
end

---Fire the interim finding once. Nothing happens for an empty phase 1.
function Tracker:_fire()
  if self._fired or #self._all == 0 then
    return
  end
  self._fired = true
  pcall(self._emit, self:summary())
end

---Phase 1 may already be over before anything runs (every likely file came from the cache).
function Tracker:begin()
  if next(self._pending) == nil then
    self:_fire()
  end
end

---A case was recorded. A bad case in a phase 1 file is a red interim finding at once. A passing case says nothing
---yet: the cases of a file arrive in batches, so only `file_done` knows that no bad case is still to come.
---@param case { file: string, status: string, na?: string }
function Tracker:case(case)
  if self._fired or not self._set[case.file] then
    return
  end
  if BAD[case.status] then
    self._bad = self._bad + 1
    self._failed_files[case.file] = true
    self._pending[case.file] = nil -- a file with a bad case has run
    self:_fire()
    return
  end
  -- an n/a case (`case.na`) does not keep a run from green
  if case.status == "skip" and type(case.na) ~= "string" then
    self._skip = self._skip + 1
  end
end

---All the cases of a file are recorded (the runner says so, also for a file with no case at all). The last pending
---file of phase 1 ends it.
---@param rel string
function Tracker:file_done(rel)
  if self._fired or not self._set[rel] then
    return
  end
  self._pending[rel] = nil
  if next(self._pending) == nil then
    self:_fire()
  end
end

---@return boolean
function Tracker:fired()
  return self._fired
end

return M
