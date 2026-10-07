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
---@type table<string, true>
M.CLASSES = { pass = true, fail = true, skip = true }

---@class Testing.KeyLog.Opts
---@field state_dir? string Replaces `stdpath('state')` (specs).

---@class Testing.KeyLog.Obs
---@field key string
---@field class "pass"|"fail"|"skip"
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
local Log = {}
Log.__index = Log

---Class of the result of a file from its cases: any bad case makes it `fail`, otherwise a skip makes it `skip`.
---@param cases Testing.Result.Case[]|nil
---@return "pass"|"fail"|"skip"|nil class nil: no cases, nothing to remember
function M.class_of(cases)
  if type(cases) ~= "table" or #cases == 0 then
    return nil
  end
  local bad = { fail = true, error = true, timeout = true, crash = true, xpass = true }
  local skip = false
  for _, c in ipairs(cases) do
    if bad[c.status] then
      return "fail"
    end
    if c.status == "skip" then
      skip = true
    end
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

---Read the key log of a project (an absent or unusable file is an empty log, with a note when it is unusable).
---@param root string
---@param opts? Testing.KeyLog.Opts
---@return Testing.KeyLog
function M.load(root, opts)
  local path = M.path(root, opts)
  local log = setmetatable({ path = path, files = {}, notes = {}, dirty = false }, Log)
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
---@param class "pass"|"fail"|"skip"
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
  for _, o in ipairs(list) do
    if o.key == key and o.class == class then
      o.run, o.ts = run, ts
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
  return self:flipped(file, key)
end

---Drop the records of files that are not in `known` (a set); nil keeps all.
---@param known? table<string, true>
function Log:retain(known)
  if not known then
    return
  end
  for file in pairs(self.files) do
    if not known[file] then
      self.files[file] = nil
      self.dirty = true
    end
  end
end

---Write the log (bounded, atomic) when it changed.
---@return boolean ok
---@return string|nil err
function Log:save()
  if not self.dirty then
    return true
  end
  local json = require("lib.nvim.json")
  local names = vim.tbl_keys(self.files)
  -- bounded in files: the ones whose newest record is oldest go first
  local function newest(file)
    local t = 0
    for _, o in ipairs(self.files[file]) do
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
    keep[names[i]] = self.files[names[i]]
  end
  local enc, err = json.encode({ v = M.VERSION, files = keep })
  if not enc then
    return false, "cannot encode the key log: " .. tostring(err)
  end
  while #enc > M.MAX_BYTES and #names > 1 do
    keep[table.remove(names)] = nil
    enc, err = json.encode({ v = M.VERSION, files = keep })
    if not enc then
      return false, "cannot encode the key log: " .. tostring(err)
    end
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(self.path, enc, { mkdirp = true })
  if not ok then
    return false, ("cannot write %s: %s"):format(self.path, tostring(werr))
  end
  self.dirty = false
  return true
end

return M
