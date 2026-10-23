---@module 'testing.state'
---@brief The last result of a project: one shared state for explorer, hover, quickfix, diagnostics and statusline.
---@description
--- `runs.jsonl` (`testing.history`) keeps only the ids of the red cases. A UI needs more: the counters, the
--- duration, which cases are green, the message of a red one, and whether the file has changed since the case
--- ran. This module is that state, a pure data module: no window, no buffer, no keymap.
---
---   stdpath('state')/testing/<project>/last.json   the last result per case, merged over partial runs
---   stdpath('state')/testing/<project>/prev.json   the one before it (the marker "newly red since the last run")
---
--- **Merged, not replaced.** `testing --file a_spec.lua` must not make the results of `b_spec.lua` disappear: a
--- run replaces the cases it produced (by id) and keeps the others. A file that ran COMPLETELY forgets the ids it
--- no longer produces; a file that no longer exists is dropped.
---
--- **Stale.** Per spec file the store keeps `{ mtime_ns, size }` of the file from when its result was recorded,
--- not in the IR. `is_stale` compares that with `uv.fs_stat`: a file changed since the run, or gone, has an
--- outdated result and must never be shown as a current green. `mtime_ns` is a DECIMAL STRING: nanoseconds since
--- the epoch do not fit a double, and a number that went through JSON would compare unequal to itself.
---
--- **Untrusted input (SEC-32/33/45).** `last.json` is read back like `runs.jsonl`: a size cap before decoding,
--- `pcall` around the decode, every field validated, a case that fails is dropped and counted in `notes`, a file
--- that is not usable at all is ignored with a note. The words of the project under test (titles, messages) lose
--- their control characters and are cut, so no terminal sequence in a test title reaches a window. Nothing from
--- the file is ever used as a path: files are compared with the ones the runner knows.
---
--- It is written atomically (`lib.nvim.fs.write.atomic`) under the lock of `testing.statelock`, bounded in
--- bytes, cases and string lengths. A store is a convenience, not part of the verdict: a failing read or write is
--- returned to the caller, which prints a note and carries on.

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_BYTES = 16 * 1024 * 1024
---@type integer
M.MAX_CASES = 100000
---@type integer
M.MAX_FILES = 20000
---@type integer
M.MAX_ID_BYTES = 500
---@type integer
M.MAX_TEXT = 2000
---@type integer
M.MAX_DESCRIBE = 20

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
-- what makes a run red
local BAD = { fail = true, error = true, timeout = true, crash = true, xpass = true }

local uv = vim.uv or vim.loop

---@class Testing.State.Case
---@field id string
---@field file string
---@field line? integer
---@field status Testing.Status
---@field duration_ms number
---@field flaky? boolean
---@field describe? string[]
---@field name? string
---@field message? string  First failing assertion (or the error, or the skip reason), first line.
---@field expected? string
---@field actual? string

---@class Testing.State.File
---@field mtime_ns string  Decimal string, nanoseconds since the epoch.
---@field size integer
---@field run string  Id of the run that recorded it.
---@field ts integer

---@class Testing.State
---@field root string
---@field run? string  Id of the run that wrote `last.json` last.
---@field ts? integer
---@field partial boolean  The last run did not cover every file or stopped early.
---@field summary table<string, integer>
---@field files table<string, Testing.State.File>
---@field cases Testing.State.Case[]
---@field notes string[]
---@field private _by_id table<string, Testing.State.Case>
---@field private _subs (fun(state: Testing.State, event: string))[]

-- =========================================================
-- Text
-- =========================================================

---A word of the project under test, safe to show: control characters replaced, cut to `max` bytes.
---@param s any
---@param max? integer
---@param keep_newlines? boolean
---@return string|nil
local function clean(s, max, keep_newlines)
  if type(s) ~= "string" then
    return nil
  end
  max = max or M.MAX_TEXT
  if #s > max then
    s = s:sub(1, max)
    -- do not leave half a UTF-8 sequence at the cut
    local cut = #s
    while cut > 0 and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do
      cut = cut - 1
    end
    if cut > 0 and s:byte(cut) >= 0xC0 then
      s = s:sub(1, cut - 1)
    end
  end
  if keep_newlines then
    return (s:gsub("[%z\1-\8\11\12\14-\31\127]", "?"))
  end
  return (s:gsub("[%z\1-\31\127]", "?"))
end

---@param s any
---@return string|nil
local function first_line(s)
  if type(s) ~= "string" then
    return nil
  end
  return (s:match("^[^\r\n]*"))
end

-- =========================================================
-- Paths and files
-- =========================================================

---Spec file names as the IR spells them: forward slashes.
---@param file string
---@return string
local function norm_file(file)
  return (file:gsub("\\", "/"))
end

---Whether a file name from a result file stays inside the project: relative, no drive, no `..` segment. The
---name is stat'ed (`is_stale`, `snapshot`), so a hostile `last.json` must not be able to point it elsewhere.
---@param file string  Already normalised.
---@return boolean
local function inside(file)
  if file:sub(1, 1) == "/" or file:match("^%a:") then
    return false
  end
  -- a `..` segment, written as a pattern (a literal would read as a path outside the project to the cache key)
  return not (file == ".." or file:find("^%.%./") or file:find("/%.%./") or file:find("/%.%.$"))
end

---The state directory of a project (the one `runs.jsonl` is in).
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.dir(root, opts)
  return require("testing.history").dir(root, opts)
end

---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return M.dir(root, opts) .. "/last.json"
end

---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.prev_path(root, opts)
  return M.dir(root, opts) .. "/prev.json"
end

---`{ mtime_ns, size }` of a file now, or nil when it is gone.
---@param root string
---@param file string
---@return { mtime_ns: string, size: integer }|nil
function M.stat(root, file)
  local st = uv.fs_stat(root .. "/" .. file)
  if not st or st.type ~= "file" then
    return nil
  end
  local mt = st.mtime or { sec = 0, nsec = 0 }
  return { mtime_ns = ("%d%09d"):format(mt.sec or 0, mt.nsec or 0), size = st.size or 0 }
end

-- =========================================================
-- The state object
-- =========================================================

---An empty state.
---@param root string
---@return Testing.State
function M.new(root)
  return {
    root = root,
    partial = false,
    summary = {},
    files = {},
    cases = {},
    notes = {},
    _by_id = {},
    _subs = {},
  }
end

---@param st Testing.State
local function reindex(st)
  st._by_id = {}
  for _, c in ipairs(st.cases) do
    st._by_id[c.id] = c
  end
end

---@param st Testing.State
local function recount(st)
  local summary = {}
  for status in pairs(STATUS) do
    summary[status] = 0
  end
  for _, c in ipairs(st.cases) do
    summary[c.status] = summary[c.status] + 1
  end
  st.summary = summary
end

-- =========================================================
-- Validation (the file is untrusted)
-- =========================================================

---@param raw any
---@return Testing.State.Case|nil
---@return string|nil why
local function validate_case(raw)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  if type(raw.id) ~= "string" or raw.id == "" or #raw.id > M.MAX_ID_BYTES then
    return nil, "bad id"
  end
  if type(raw.file) ~= "string" or raw.file == "" or #raw.file > M.MAX_ID_BYTES then
    return nil, "bad file"
  end
  if not STATUS[raw.status] then
    return nil, "bad status"
  end
  if
    type(raw.duration_ms) ~= "number"
    or raw.duration_ms ~= raw.duration_ms
    or raw.duration_ms < 0
    or raw.duration_ms > 1e12
  then
    return nil, "bad duration"
  end
  local line = raw.line
  if
    line ~= nil and (type(line) ~= "number" or line ~= math.floor(line) or line < 1 or line > 1e7)
  then
    line = nil
  end
  local describe
  if type(raw.describe) == "table" and #raw.describe <= M.MAX_DESCRIBE then
    describe = {}
    for _, d in ipairs(raw.describe) do
      local t = clean(d, 300)
      if t then
        describe[#describe + 1] = t
      end
    end
  end
  if not inside(norm_file(raw.file)) then
    return nil, "file outside the project"
  end
  return {
    id = raw.id,
    file = norm_file(raw.file),
    line = line,
    status = raw.status,
    duration_ms = raw.duration_ms,
    flaky = raw.flaky == true or nil,
    describe = describe,
    name = clean(raw.name, 300),
    message = clean(first_line(raw.message), M.MAX_TEXT),
    expected = clean(raw.expected, M.MAX_TEXT, true),
    actual = clean(raw.actual, M.MAX_TEXT, true),
  }
end

---@param raw any
---@return Testing.State.File|nil
local function validate_file(raw)
  if type(raw) ~= "table" then
    return nil
  end
  if type(raw.mtime_ns) ~= "string" or not raw.mtime_ns:match("^%d+$") or #raw.mtime_ns > 25 then
    return nil
  end
  if type(raw.size) ~= "number" or raw.size ~= math.floor(raw.size) or raw.size < 0 then
    return nil
  end
  if type(raw.run) ~= "string" or #raw.run > 100 then
    return nil
  end
  local ts = raw.ts
  if type(ts) ~= "number" or ts ~= ts or ts < 0 or ts > 4102444800 then
    ts = 0
  end
  return { mtime_ns = raw.mtime_ns, size = raw.size, run = raw.run, ts = ts }
end

---Validate a decoded `last.json` into a state. Never raises.
---@param root string
---@param raw any
---@return Testing.State|nil
---@return string[] notes
function M.validate(root, raw)
  local notes = {}
  if type(raw) ~= "table" then
    return nil, { "not an object" }
  end
  if raw.v ~= M.VERSION then
    return nil, { "unknown version" }
  end
  if type(raw.cases) ~= "table" or #raw.cases > M.MAX_CASES then
    return nil, { "bad case list" }
  end
  local st = M.new(root)
  if type(raw.run) == "string" and #raw.run <= 100 then
    st.run = raw.run
  end
  if type(raw.ts) == "number" and raw.ts == raw.ts and raw.ts >= 0 and raw.ts <= 4102444800 then
    st.ts = raw.ts
  end
  st.partial = raw.partial == true
  local dropped, seen = 0, {}
  for _, rc in ipairs(raw.cases) do
    local c = validate_case(rc)
    if c and not seen[c.id] then
      seen[c.id] = true
      st.cases[#st.cases + 1] = c
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    notes[#notes + 1] = ("%d unusable case(s) ignored"):format(dropped)
  end
  if type(raw.files) == "table" then
    local n, bad = 0, 0
    for file, rf in pairs(raw.files) do
      n = n + 1
      local f = type(file) == "string"
        and #file <= M.MAX_ID_BYTES
        and n <= M.MAX_FILES
        and inside(norm_file(file))
        and validate_file(rf)
      if f then
        st.files[norm_file(file)] = f
      else
        bad = bad + 1
      end
    end
    if bad > 0 then
      notes[#notes + 1] = ("%d unusable file record(s) ignored"):format(bad)
    end
  end
  reindex(st)
  recount(st)
  return st, notes
end

-- =========================================================
-- Load
-- =========================================================

---Read a state file.
---@param root string
---@param path string
---@return Testing.State|nil state  nil: no file, or not usable (then `notes` says why)
---@return string[] notes
local function read_file(root, path)
  local stat = uv.fs_stat(path)
  if not stat then
    return nil, {}
  end
  if stat.type ~= "file" then
    return nil, { ("%s is not a regular file: ignored"):format(path) }
  end
  if stat.size > M.MAX_BYTES then
    return nil, { ("%s is larger than %d bytes: ignored"):format(path, M.MAX_BYTES) }
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, { ("%s cannot be read: %s"):format(path, tostring(err)) }
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil, { ("%s is not valid JSON: ignored"):format(path) }
  end
  local st, notes = M.validate(root, decoded)
  if not st then
    return nil, { ("%s is not a result file (%s): ignored"):format(path, notes[1] or "?") }
  end
  for i, n in ipairs(notes) do
    notes[i] = ("%s: %s"):format(path, n)
  end
  return st, notes
end

---Load the last result of a project. Always returns a state: an empty one when there is no file or it is not
---usable, with the reason in `notes`.
---@param root string
---@param opts? { state_dir?: string }
---@return Testing.State
function M.load(root, opts)
  local ok, st, notes = pcall(read_file, root, M.path(root, opts))
  if not ok then
    local empty = M.new(root)
    empty.notes = { ("%s cannot be read: %s"):format(M.path(root, opts), tostring(st)) }
    return empty
  end
  st = st or M.new(root)
  st.notes = notes
  return st
end

---The result before the last one, or nil.
---@param root string
---@param opts? { state_dir?: string }
---@return Testing.State|nil
function M.load_prev(root, opts)
  local ok, st = pcall(read_file, root, M.prev_path(root, opts))
  return ok and st or nil
end

-- =========================================================
-- Queries
-- =========================================================

---Counters of the state, a copy.
---@param st Testing.State
---@return { run?: string, ts?: integer, partial: boolean, summary: table<string, integer>, cases: integer, files: integer, failed: integer, stale: integer }
function M.snapshot(st)
  local failed, stale = 0, 0
  for _, c in ipairs(st.cases) do
    if BAD[c.status] then
      failed = failed + 1
    end
  end
  for file in pairs(st.files) do
    if M.is_stale(st, file) then
      stale = stale + 1
    end
  end
  local files = 0
  for _ in pairs(st.files) do
    files = files + 1
  end
  return {
    run = st.run,
    ts = st.ts,
    partial = st.partial,
    summary = vim.deepcopy(st.summary),
    cases = #st.cases,
    files = files,
    failed = failed,
    stale = stale,
  }
end

---The case with this id.
---@param st Testing.State
---@param id string
---@return Testing.State.Case|nil
function M.case(st, id)
  return st._by_id[id]
end

---The case a line belongs to: the case of `file` with the largest definition line at or before `line`. With
---`opts.exact` only a case defined on that very line.
---@param st Testing.State
---@param file string
---@param line integer
---@param opts? { exact?: boolean }
---@return Testing.State.Case|nil
function M.case_at(st, file, line, opts)
  file = norm_file(file)
  local best
  for _, c in ipairs(st.cases) do
    if c.file == file and c.line and c.line <= line then
      if not best or c.line > best.line then
        best = c
      end
    end
  end
  if best and opts and opts.exact and best.line ~= line then
    return nil
  end
  return best
end

---Whether the result of a spec file is outdated: the file changed since the result was recorded, is gone, or has
---no record at all. Never a current green for an old result.
---@param st Testing.State
---@param file string
---@return boolean stale
---@return string|nil reason  `changed`, `gone` or `no result`
function M.is_stale(st, file)
  file = norm_file(file)
  local rec = st.files[file]
  if not rec then
    return true, "no result"
  end
  local now = M.stat(st.root, file)
  if not now then
    return true, "gone"
  end
  if now.mtime_ns ~= rec.mtime_ns or now.size ~= rec.size then
    return true, "changed"
  end
  return false
end

---@class Testing.State.FileSummary
---@field file string
---@field total integer
---@field counts table<string, integer>
---@field failed string[]  ids of the red cases
---@field duration_ms number
---@field ts? integer
---@field stale boolean
---@field stale_reason? string

---Summary of one spec file, or nil when the store knows no case of it.
---@param st Testing.State
---@param file string
---@return Testing.State.FileSummary|nil
function M.file_summary(st, file)
  file = norm_file(file)
  local out = { file = file, total = 0, counts = {}, failed = {}, duration_ms = 0 }
  for _, c in ipairs(st.cases) do
    if c.file == file then
      out.total = out.total + 1
      out.counts[c.status] = (out.counts[c.status] or 0) + 1
      out.duration_ms = out.duration_ms + c.duration_ms
      if BAD[c.status] then
        out.failed[#out.failed + 1] = c.id
      end
    end
  end
  if out.total == 0 then
    return nil
  end
  local rec = st.files[file]
  out.ts = rec and rec.ts or nil
  out.stale, out.stale_reason = M.is_stale(st, file)
  return out
end

---The red cases, by file and line.
---@param st Testing.State
---@return Testing.State.Case[]
function M.failures(st)
  local out = {}
  for _, c in ipairs(st.cases) do
    if BAD[c.status] then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    return a.id < b.id
  end)
  return out
end

---Ids that are red now and were not red in `prev` (the marker "newly red since the last run").
---@param st Testing.State
---@param prev? Testing.State
---@return table<string, true>
function M.newly_failed(st, prev)
  local was = {}
  if prev then
    for _, c in ipairs(prev.cases) do
      if BAD[c.status] then
        was[c.id] = true
      end
    end
  end
  local out = {}
  for _, c in ipairs(st.cases) do
    if BAD[c.status] and not was[c.id] then
      out[c.id] = true
    end
  end
  return out
end

-- =========================================================
-- Subscribe
-- =========================================================

---Call `fn(state, event)` whenever the state changes (`apply`, `reload`). A callback that raises is dropped from
---the call, not from the list, and cannot hurt the others.
---@param st Testing.State
---@param fn fun(state: Testing.State, event: string)
---@return fun() unsubscribe
function M.subscribe(st, fn)
  st._subs[#st._subs + 1] = fn
  return function()
    for i, f in ipairs(st._subs) do
      if f == fn then
        table.remove(st._subs, i)
        return
      end
    end
  end
end

---@param st Testing.State
---@param event string
local function emit(st, event)
  for _, fn in ipairs(vim.list_slice(st._subs)) do
    pcall(fn, st, event)
  end
end

-- =========================================================
-- Apply a run
-- =========================================================

---The state entry of one IR case.
---@param c Testing.Result.Case
---@return Testing.State.Case
local function from_ir(c)
  local message, expected, actual
  for _, a in ipairs(c.assertions or {}) do
    if a.ok == false then
      message = first_line(a.msg)
      expected, actual = a.expected, a.actual
      break
    end
  end
  if not message and c.error then
    message = first_line(c.error.message)
  end
  if not message and c.reason then
    message = first_line(c.reason)
  end
  local describe
  if type(c.describe) == "table" then
    describe = {}
    for i = 1, math.min(#c.describe, M.MAX_DESCRIBE) do
      describe[#describe + 1] = clean(c.describe[i], 300)
    end
  end
  return {
    id = c.id,
    file = norm_file(c.file),
    line = c.line,
    status = c.status,
    duration_ms = c.duration_ms,
    flaky = c.flaky == true or nil,
    describe = describe,
    name = clean(c.name, 300),
    message = clean(message, M.MAX_TEXT),
    expected = clean(expected, M.MAX_TEXT, true),
    actual = clean(actual, M.MAX_TEXT, true),
  }
end

---@class Testing.State.ApplyInfo
---@field ran_files? table<string, true>  Files that ran WITHOUT a case restriction: they forget ids they no longer produce and their file record is renewed.
---@field known_files? table<string, true>  Every discovered file; records and cases of other files are dropped. nil = keep all.
---@field partial? boolean  The run covered a selection or stopped early.
---@field time? integer  Unix time (tests).
---@field stat? fun(root: string, file: string): { mtime_ns: string, size: integer }|nil  Replaces `M.stat` (tests).

---Merge a finished run into the state: the cases it produced replace the ones with the same id, the others stay.
---Emits `apply`.
---@param st Testing.State
---@param res Testing.Result
---@param info? Testing.State.ApplyInfo
---@return Testing.State
function M.apply(st, res, info)
  info = info or {}
  local ran_files = info.ran_files or {}
  local known = info.known_files
  local produced, now = {}, {}
  for _, c in ipairs(res.cases) do
    produced[c.id] = from_ir(c)
    now[#now + 1] = produced[c.id]
  end
  local kept = {}
  for _, c in ipairs(st.cases) do
    local gone = known ~= nil and not known[c.file]
    if not (produced[c.id] or ran_files[c.file] or gone) then
      kept[#kept + 1] = c
    end
  end
  vim.list_extend(kept, now)
  -- bounded: the newest results stay
  while #kept > M.MAX_CASES do
    table.remove(kept, 1)
  end
  st.cases = kept
  reindex(st)
  recount(st)

  local stat = info.stat or M.stat
  local ts = info.time or os.time()
  for file in pairs(ran_files) do
    local rec = stat(st.root, file)
    if rec then
      st.files[norm_file(file)] =
        { mtime_ns = rec.mtime_ns, size = rec.size, run = res.run.id, ts = ts }
    end
  end
  if known then
    for file in pairs(st.files) do
      if not known[file] then
        st.files[file] = nil
      end
    end
  end
  st.run, st.ts, st.partial = res.run.id, ts, info.partial == true
  emit(st, "apply")
  return st
end

-- =========================================================
-- Save
-- =========================================================

---@param st Testing.State
---@return table
local function to_json(st)
  local cases = {}
  for _, c in ipairs(st.cases) do
    cases[#cases + 1] = {
      id = c.id,
      file = c.file,
      line = c.line,
      status = c.status,
      duration_ms = c.duration_ms,
      flaky = c.flaky,
      describe = c.describe,
      name = c.name,
      message = c.message,
      expected = c.expected,
      actual = c.actual,
    }
  end
  return {
    v = M.VERSION,
    run = st.run,
    ts = st.ts,
    partial = st.partial,
    files = st.files,
    cases = cases,
  }
end

---Write the state (and keep the previous one as `prev.json`). Call it while the lock of `last.json` is held.
---@param st Testing.State
---@param opts? { state_dir?: string }
---@return boolean ok
---@return string|nil err
function M.write_locked(st, opts)
  local path = M.path(st.root, opts)
  local text, err = require("lib.nvim.json").encode(to_json(st))
  if not text then
    return false, "cannot encode the result: " .. tostring(err)
  end
  if #text > M.MAX_BYTES then
    return false, ("the result is larger than %d bytes: not stored"):format(M.MAX_BYTES)
  end
  local atomic = require("lib.nvim.fs.write.atomic")
  local old = uv.fs_stat(path)
  if old and old.type == "file" and old.size <= M.MAX_BYTES then
    local prev_text = require("lib.nvim.fs.read")(path)
    if prev_text then
      -- losing the previous copy only loses the "newly red" marker
      atomic(M.prev_path(st.root, opts), prev_text, { mkdirp = true })
    end
  end
  local wrote, werr = atomic(path, text, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true
end

---Merge a finished run into `last.json`: read it again under the lock (a run that finished meanwhile keeps its
---cases), apply, write. This is what the run driver calls.
---@param root string
---@param res Testing.Result
---@param info? Testing.State.ApplyInfo
---@param opts? { state_dir?: string }
---@return boolean ok
---@return string|nil err
---@return Testing.State|nil state
function M.record(root, res, info, opts)
  local path = M.path(root, opts)
  local result_state
  local locked, ok, err = require("testing.statelock").with(path, function()
    local st = M.load(root, opts)
    M.apply(st, res, info)
    result_state = st
    return M.write_locked(st, opts)
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err, result_state
end

return M
