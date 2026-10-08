---@module 'testing.cache.keylog'
---@brief Key-flip detection: the same cache key that gave two different results proves a spec is not deterministic.
---@description
--- For every spec file that ran under a cache key, the run remembers `(key, class of the result)`. When the SAME
--- key shows up with a different class (`pass` once, `fail` another time), then either the spec is flaky or an input
--- the key cannot see changed between the runs. Both are a reason not to trust a cached result: the file is marked
--- `nondeterministic`, its entry is discarded and nothing is stored for it until the author declares
--- `-- @cache-allow nondeterministic` in its header (a new key, that is a changed input, starts a new record).
---
--- Layout: `stdpath('state')/testing/<project>/keys.json` (the directory of `testing.history`; the history itself
--- is not touched):
---
---   {"v":1,"files":{"<spec>":[{"key":"<64 hex>","class":"pass|fail|skip","run":"<run id>","ts":<unix>}, ...]}}
---
--- BOUNDED: at most `MAX_OBS` observations per file (the oldest go first; a repeated result of the same key only
--- refreshes its record), `MAX_FILES` files, `MAX_BYTES` in total. UNTRUSTED when read back (like `runs.jsonl`): size
--- cap before decoding, decode under `pcall`, every field validated, whatever fails is dropped and counted; nothing
--- from the file is used as a path, executed or interpolated into a pattern. A convenience, never part of a verdict:
--- a failing read or write is a note.
---
--- Two runs of one project at the same time (a CI matrix on one machine, `watch` next to a manual run) both load the
--- file when they start and save it when they end, so the window between the two is the length of a run. `save` does
--- not write what it loaded: under `testing.statelock` it reads the file again and replays the observations of THIS
--- run onto it (the same read-modify-write rule as for `runs.jsonl`, `order.json`, ...), so a key that gave `pass` in
--- one run and `fail` in the other shows up as a flip in the next one.

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_OBS = 12
---@type integer
M.MAX_FILES = 3000
---@type integer
M.MAX_BYTES = 2 * 1024 * 1024

---The classes a result can have; two different ones under one key are a flip.
---`flaky` is a file that passed only after a retry (`--retry-failed`): under `--allow-flaky` its cases read `pass`,
---so without this class a key that gave a plain pass and, another time, a pass after a retry would not look flipped.
---@type table<string, true>
M.CLASSES = { pass = true, fail = true, skip = true, flaky = true }

---@class Testing.KeyLog.Opts
---@field state_dir? string Replaces `stdpath('state')` (specs).

---@class Testing.KeyLog.Obs
---@field key string
---@field class "pass"|"fail"|"flaky"|"skip"
---@field run string
---@field ts integer

---@class Testing.KeyLog.Pending
---@field file string
---@field key string
---@field class "pass"|"fail"|"flaky"|"skip"
---@field run string
---@field ts integer

---@class Testing.KeyLog.Flip
---@field classes string[] The different results the key has given (sorted).
---@field runs string[] The run ids that gave them.

---@class Testing.KeyLog
---@field path string
---@field files table<string, Testing.KeyLog.Obs[]>
---@field notes string[] What was dropped or ignored while reading.
---@field dirty boolean
---@field pending Testing.KeyLog.Pending[] The observations of this run, in order (replayed onto the file by `save`).
---@field known? table<string, true> The set of the last `retain`.
local Log = {}
Log.__index = Log

---Class of the result of a file from its cases: any bad case makes it `fail`; a case that needed a retry
---(`flaky`, or `retries > 0`) makes it `flaky`; otherwise a skip makes it `skip`.
---@param cases Testing.Result.Case[]|nil
---@return "pass"|"fail"|"flaky"|"skip"|nil class nil: no cases, nothing to remember
function M.class_of(cases)
  if type(cases) ~= "table" or #cases == 0 then
    return nil
  end
  local bad = { fail = true, error = true, timeout = true, crash = true, xpass = true }
  local skip, flaky = false, false
  for _, c in ipairs(cases) do
    if bad[c.status] then
      return "fail"
    end
    if c.flaky == true or (tonumber(c.retries) or 0) > 0 then
      flaky = true
    end
    if c.status == "skip" then
      skip = true
    end
  end
  if flaky then
    return "flaky"
  end
  return skip and "skip" or "pass"
end

---Path of `keys.json` of a project.
---@param root string
---@param opts? Testing.KeyLog.Opts
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/keys.json"
end

---Forget the key log of a project (`--cache-clear`).
---@param root string
---@param opts? Testing.KeyLog.Opts
---@return boolean removed
function M.clear(root, opts)
  return vim.uv.fs_unlink(M.path(root, opts)) == true
end

---@param raw any
---@return Testing.KeyLog.Obs|nil
local function valid_obs(raw)
  if
    type(raw) ~= "table"
    or not require("testing.cache.store").is_key(raw.key)
    or not M.CLASSES[raw.class]
    or type(raw.run) ~= "string"
    or #raw.run > 100
    or raw.run:find("%c")
    or type(raw.ts) ~= "number"
    or raw.ts ~= raw.ts
    or raw.ts < 0
    or raw.ts > 4102444800
  then
    return nil
  end
  return { key = raw.key, class = raw.class, run = raw.run, ts = raw.ts }
end

---Remove stray temp files of interrupted writes of `keys.json` (`keys.json.atomic-tmp.*`, older than an hour).
---@param dir string
---@param now integer
---@return integer removed
function M.sweep_tmp(dir, now)
  local n = 0
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("^keys%.json%.atomic%-tmp%.") then
      local st = vim.uv.fs_stat(dir .. "/" .. name)
      if st and st.mtime and now - st.mtime.sec > 3600 and vim.uv.fs_unlink(dir .. "/" .. name) then
        n = n + 1
      end
    end
  end
  return n
end

---Fill `log.files` (and `log.notes`) from the file of `log.path`: an absent or unusable file is an empty log.
---@param log Testing.KeyLog
---@return Testing.KeyLog log
local function read(log)
  local path = log.path
  local st = vim.uv.fs_stat(path)
  if not st then
    return log
  end
  if st.type ~= "file" or st.size > M.MAX_BYTES * 2 then
    log.notes[#log.notes + 1] = ("key log %s is not usable (not a file, or larger than %d bytes): ignored"):format(
      path,
      M.MAX_BYTES * 2
    )
    return log
  end
  local text = require("lib.nvim.fs.read")(path)
  local ok, raw = pcall(require("lib.nvim.json").decode, text or "")
  if not (ok and type(raw) == "table" and raw.v == M.VERSION and type(raw.files) == "table") then
    log.notes[#log.notes + 1] = ("key log %s is not usable: ignored"):format(path)
    return log
  end
  local dropped, nfiles = 0, 0
  for file, list in pairs(raw.files) do
    if
      type(file) == "string"
      and #file <= 500
      and not file:find("%c")
      and type(list) == "table"
      and nfiles < M.MAX_FILES
    then
      local obs = {}
      for i = 1, math.min(#list, M.MAX_OBS) do
        local o = valid_obs(list[i])
        if o then
          obs[#obs + 1] = o
        else
          dropped = dropped + 1
        end
      end
      if #obs > 0 then
        log.files[file] = obs
        nfiles = nfiles + 1
      end
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    log.notes[#log.notes + 1] = ("key log %s: %d unusable record(s) ignored"):format(path, dropped)
  end
  return log
end

---@param path string
---@return Testing.KeyLog
local function new_log(path)
  return setmetatable({ path = path, files = {}, notes = {}, dirty = false, pending = {} }, Log)
end

---Read the key log of a project (an absent or unusable file is an empty log, with a note when it is unusable).
---@param root string
---@param opts? Testing.KeyLog.Opts
---@return Testing.KeyLog
function M.load(root, opts)
  local path = M.path(root, opts)
  M.sweep_tmp(vim.fs.dirname(path), os.time())
  return read(new_log(path))
end

---The results `key` has given for `file` when they differ.
---@param file string
---@param key string
---@return Testing.KeyLog.Flip|nil
function Log:flipped(file, key)
  local seen, classes, runs = {}, {}, {}
  for _, o in ipairs(self.files[file] or {}) do
    if o.key == key then
      if not seen[o.class] then
        seen[o.class] = true
        classes[#classes + 1] = o.class
      end
      runs[#runs + 1] = o.run
    end
  end
  if #classes < 2 then
    return nil
  end
  table.sort(classes)
  return { classes = classes, runs = runs }
end

---Remember the result of `file` under `key`; returns the flip this makes visible (or the one that was known).
---@param file string
---@param key string
---@param class "pass"|"fail"|"flaky"|"skip"
---@param run string
---@param ts? integer
---@return Testing.KeyLog.Flip|nil
function Log:observe(file, key, class, run, ts)
  local list = self.files[file]
  if not list then
    list = {}
    self.files[file] = list
  end
  ts = ts or os.time()
  local replaced = false
  for i, o in ipairs(list) do
    if o.key == key and o.class == class then
      o.run, o.ts = run, ts
      -- the record was used again: it moves to the end, so the one that goes when the list is full is the
      -- one that was used longest ago (not the one that was first written)
      table.remove(list, i)
      list[#list + 1] = o
      replaced = true
      break
    end
  end
  if not replaced then
    list[#list + 1] = { key = key, class = class, run = run, ts = ts }
    while #list > M.MAX_OBS do
      table.remove(list, 1)
    end
  end
  self.dirty = true
  self.pending = self.pending or {}
  self.pending[#self.pending + 1] = { file = file, key = key, class = class, run = run, ts = ts }
  return self:flipped(file, key)
end

---Drop the records of files that are not in `known` (a set); nil keeps all.
---@param known? table<string, true>
function Log:retain(known)
  if not known then
    return
  end
  self.known = known
  for file in pairs(self.files) do
    if not known[file] then
      self.files[file] = nil
      self.dirty = true
    end
  end
end

---The JSON text of `files`, cut to `MAX_FILES` files and `MAX_BYTES` (the files whose newest record is oldest go first).
---@param files table<string, Testing.KeyLog.Obs[]>
---@return string|nil text
---@return string|nil err
local function encode_bounded(files)
  local json = require("lib.nvim.json")
  local names = vim.tbl_keys(files)
  local function newest(file)
    local t = 0
    for _, o in ipairs(files[file]) do
      t = math.max(t, o.ts)
    end
    return t
  end
  table.sort(names, function(a, b)
    local ta, tb = newest(a), newest(b)
    if ta ~= tb then
      return ta > tb
    end
    return a < b
  end)
  local keep = {}
  for i = 1, math.min(#names, M.MAX_FILES) do
    keep[names[i]] = files[names[i]]
  end
  local enc, err = json.encode({ v = M.VERSION, files = keep })
  if not enc then
    return nil, "cannot encode the key log: " .. tostring(err)
  end
  while #enc > M.MAX_BYTES and #names > 1 do
    keep[table.remove(names)] = nil
    enc, err = json.encode({ v = M.VERSION, files = keep })
    if not enc then
      return nil, "cannot encode the key log: " .. tostring(err)
    end
  end
  return enc, nil
end

---Write the log (bounded, atomic) when it changed. Under the lock of `keys.json` the file is read again and the
---observations of this run are replayed onto what is there now, so a run that ended in between keeps its records.
---@return boolean ok
---@return string|nil err
function Log:save()
  if not self.dirty then
    return true
  end
  local locked, ok, err = require("testing.statelock").with(self.path, function()
    local fresh = read(new_log(self.path))
    for _, o in ipairs(self.pending or {}) do
      fresh:observe(o.file, o.key, o.class, o.run, o.ts)
    end
    fresh:retain(self.known)
    local enc, eerr = encode_bounded(fresh.files)
    if not enc then
      return false, eerr
    end
    local wok, werr = require("lib.nvim.fs.write.atomic")(self.path, enc, { mkdirp = true })
    if not wok then
      return false, ("cannot write %s: %s"):format(self.path, tostring(werr))
    end
    self.files = fresh.files
    return true, nil
  end)
  if not locked then
    return false, tostring(ok)
  end
  if not ok then
    return false, tostring(err)
  end
  self.dirty = false
  self.pending = {}
  return true
end

return M
