---@module 'testing.cache.store'
---@brief Disk side of the result cache: one JSON file per entry, bounded, validated when read back.
---@description
--- Layout (PERF-43): `stdpath('cache')/testing/<name>-<12 hex of sha256(project key)>/`
---
---   entries/<64 hex key>.json   one entry = the case list of ONE spec file
---   index.json                  hash index (`testing.cache.hash`)
---
--- The cache is regenerable: deleting the directory costs time, never correctness. It is per user
--- and per machine, never shared across a trust boundary (D.8), which is also why a hit is still
--- VALIDATED: an entry is untrusted input when read back (SEC-33). `read` applies a size cap before
--- decoding, decodes under `pcall`, and accepts an entry only when
---
---   * version, key (equal to the file name AND to the key asked for) and file are the expected ones,
---   * every case is a `pass` of that file with an empty effects ledger, no guard finding and no error,
---   * the case list is a valid Result-IR fragment (`testing.core.result.validate`).
---
--- Anything else is a MISS (with a reason), never a partial hit. Writes are atomic
--- (`lib.nvim.fs.write.atomic`); the store is bounded by bytes, entries and age (`prune`).

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_ENTRY_BYTES = 4 * 1024 * 1024
---@type integer
M.MAX_CASES = 5000
---@type integer
M.MAX_ASSERTIONS = 5000
---Defaults of `prune`.
---@type { max_bytes: integer, max_entries: integer, max_age_days: integer }
M.LIMITS = { max_bytes = 64 * 1024 * 1024, max_entries = 5000, max_age_days = 30 }

local uv = vim.uv

---@param s any
---@return boolean
local function is_key(s)
  return type(s) == "string" and #s == 64 and s:match("^%x+$") ~= nil
end
M.is_key = is_key

---Directory of the cache of a project.
---@param root string
---@param opts? { cache_dir?: string }
---@return string
function M.dir(root, opts)
  local base = (opts and opts.cache_dir) or vim.fn.stdpath("cache")
  local key = require("lib.nvim.fs.project_key")(root)
  local name = (key:match("([^/\\]+)[/\\]*$") or "project"):gsub("[^%w_.%-]", "_")
  return ("%s/testing/%s-%s"):format(base, name, vim.fn.sha256(key):sub(1, 12))
end

---@param dir string
---@param key string
---@return string
function M.entry_path(dir, key)
  return ("%s/entries/%s.json"):format(dir, key)
end

---@class Testing.Cache.Entry
---@field v integer
---@field key string
---@field file string Project-relative spec file.
---@field run string Run id that produced the entry.
---@field ts integer Unix time.
---@field nvim string
---@field cases Testing.Result.Case[]
---@field meta? table<string, any>

---Does a case carry a guard finding that makes it unfit for the cache? Findings of severity `info` (the state
---guard noting that a spec loaded a module) are observations, not problems: they are kept in the entry.
---@param case table
---@return boolean
function M.blocking_guards(case)
  local g = case.guards
  if type(g) ~= "table" then
    return false
  end
  for _, finding in ipairs(g) do
    if type(finding) ~= "table" or finding.severity ~= "info" then
      return true
    end
  end
  return next(g) ~= nil and #g == 0
end

---Validate a decoded entry against what the caller asked for.
---@param raw any
---@param expect { key: string, file: string }
---@return Testing.Cache.Entry|nil
---@return string|nil why
function M.validate(raw, expect)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  if raw.v ~= M.VERSION then
    return nil, "unknown version"
  end
  if raw.key ~= expect.key or not is_key(raw.key) then
    return nil, "key mismatch"
  end
  if raw.file ~= expect.file then
    return nil, "file mismatch"
  end
  if type(raw.run) ~= "string" or #raw.run > 100 or raw.run:find("[%c]") then
    return nil, "bad run id"
  end
  if type(raw.ts) ~= "number" or raw.ts ~= raw.ts or raw.ts < 0 or raw.ts > 4102444800 then
    return nil, "bad timestamp"
  end
  if type(raw.nvim) ~= "string" or #raw.nvim > 100 then
    return nil, "bad nvim version"
  end
  local cases = raw.cases
  if type(cases) ~= "table" or #cases == 0 or #cases > M.MAX_CASES then
    return nil, "bad case list"
  end
  local prefix = expect.file .. "::"
  for i, c in ipairs(cases) do
    if type(c) ~= "table" then
      return nil, ("case %d is not an object"):format(i)
    end
    if
      type(c.id) ~= "string"
      or #c.id > 500
      or c.id:sub(1, #prefix) ~= prefix
      or c.file ~= expect.file
    then
      return nil, ("case %d belongs to another file"):format(i)
    end
    if c.status ~= "pass" then
      return nil, ("case %d is not a pass"):format(i)
    end
    if c.error ~= nil or c.reason ~= nil then
      return nil, ("case %d carries an error"):format(i)
    end
    if M.blocking_guards(c) then
      return nil, ("case %d carries guard findings"):format(i)
    end
    local ef = c.effects
    if type(ef) ~= "table" then
      return nil, ("case %d has no effects ledger"):format(i)
    end
    for _, k in ipairs({ "spawned", "network", "fs_outside_tmp" }) do
      if type(ef[k]) ~= "table" or next(ef[k]) ~= nil then
        return nil, ("case %d has effects"):format(i)
      end
    end
    if type(c.assertions) ~= "table" or #c.assertions > M.MAX_ASSERTIONS then
      return nil, ("case %d has a bad assertion list"):format(i)
    end
    if type(c.retries) == "number" and c.retries > 0 then
      return nil, ("case %d was retried"):format(i)
    end
  end
  -- the case list must be a valid IR fragment (shape, verdict/assertion consistency); leaked paths are not
  -- a reason to distrust an entry (they are redacted when a report is written)
  local result = require("testing.core.result")
  local res = {
    schema_version = result.SCHEMA_VERSION,
    run = result.new_run({ id = raw.run }),
    cases = cases,
    summary = result.summarize(cases),
  }
  local sink = {}
  local ok, problems = result.validate(res, { leak_warnings = sink })
  if not ok then
    return nil, "invalid IR: " .. tostring(problems[1])
  end
  return raw
end

---Read an entry. A miss carries the reason.
---@param dir string
---@param key string
---@param expect { file: string }
---@return Testing.Cache.Entry|nil
---@return string|nil why
function M.read(dir, key, expect)
  if not is_key(key) then
    return nil, "bad key"
  end
  local path = M.entry_path(dir, key)
  local st = uv.fs_stat(path)
  if not st then
    return nil, "absent"
  end
  if st.type ~= "file" then
    return nil, "not a regular file"
  end
  if st.size > M.MAX_ENTRY_BYTES then
    return nil, "entry too large"
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, "unreadable"
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil, "corrupt"
  end
  local entry, why = M.validate(decoded, { key = key, file = expect.file })
  if not entry then
    return nil, "invalid: " .. tostring(why)
  end
  -- a hit refreshes the age: pruning by age drops what nobody asked for
  pcall(uv.fs_utime, path, os.time(), os.time())
  return entry
end

---Remove `path` when it is a directory (or a link to one): the cache owns this namespace, a directory named like
---an entry is debris that would block the key. A link is unlinked, never followed. Returns true when it removed one.
---@param path string
---@return boolean removed
local function remove_dir_in_place(path)
  local st = uv.fs_lstat(path)
  if not st or st.type ~= "directory" then
    return false
  end
  return vim.fn.delete(path, "rf") == 0
end

---Write an entry (atomic, bounded).
---@param dir string
---@param entry Testing.Cache.Entry
---@return boolean ok
---@return string|nil err
function M.write(dir, entry)
  if not is_key(entry.key) then
    return false, "bad key"
  end
  local enc, err = require("lib.nvim.json").encode(entry)
  if not enc then
    return false, "cannot encode: " .. tostring(err)
  end
  if #enc > M.MAX_ENTRY_BYTES then
    return false, ("entry larger than %d bytes"):format(M.MAX_ENTRY_BYTES)
  end
  local path = M.entry_path(dir, entry.key)
  local atomic = require("lib.nvim.fs.write.atomic")
  local ok, werr = atomic(path, enc, { mkdirp = true })
  if not ok and remove_dir_in_place(path) then
    -- a DIRECTORY where the entry file belongs would block this key for good (nothing else ever removes it)
    ok, werr = atomic(path, enc, { mkdirp = true })
  end
  return ok, werr
end

---@class Testing.Cache.Listed
---@field key string
---@field size integer
---@field mtime integer

---All entries of the directory (only files whose name is a key).
---@param dir string
---@return Testing.Cache.Listed[]
function M.list(dir)
  local out = {}
  local handle = uv.fs_scandir(dir .. "/entries")
  if not handle then
    return out
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local key = name:match("^(%x+)%.json$")
    if key and is_key(key) and (kind == "file" or kind == nil) then
      local st = uv.fs_stat(dir .. "/entries/" .. name)
      if st and st.type == "file" then
        out[#out + 1] = { key = key, size = st.size, mtime = st.mtime and st.mtime.sec or 0 }
      end
    end
  end
  return out
end

---Remove stray temp files of interrupted writes (older than an hour).
---@param dir string
---@param now integer
---@return integer removed
local function sweep_tmp(dir, now)
  local handle = uv.fs_scandir(dir .. "/entries")
  local n = 0
  if not handle then
    return 0
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("^%x+%.json%.atomic%-tmp%.") then
      local st = uv.fs_stat(dir .. "/entries/" .. name)
      if st and st.mtime and now - st.mtime.sec > 3600 then
        if uv.fs_unlink(dir .. "/entries/" .. name) then
          n = n + 1
        end
      end
    end
  end
  return n
end

---@class Testing.Cache.PruneOpts
---@field max_bytes? integer
---@field max_entries? integer
---@field max_age_days? number
---@field now? integer Unix time (specs).

---@class Testing.Cache.PruneResult
---@field removed_age integer
---@field removed_size integer Removed to meet the byte or entry cap (oldest first).
---@field kept integer
---@field bytes integer Bytes kept.

---Bound the store: entries older than `max_age_days` go, then the oldest until the byte and entry caps hold.
---@param dir string
---@param opts? Testing.Cache.PruneOpts
---@return Testing.Cache.PruneResult
function M.prune(dir, opts)
  opts = opts or {}
  local max_bytes = opts.max_bytes or M.LIMITS.max_bytes
  local max_entries = opts.max_entries or M.LIMITS.max_entries
  local max_age = (opts.max_age_days or M.LIMITS.max_age_days) * 86400
  local now = opts.now or os.time()
  sweep_tmp(dir, now)
  local items = M.list(dir)
  table.sort(items, function(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime < b.mtime -- oldest first
    end
    return a.key < b.key
  end)
  local res = { removed_age = 0, removed_size = 0, kept = 0, bytes = 0 }
  local keep = {}
  for _, it in ipairs(items) do
    if now - it.mtime > max_age then
      if uv.fs_unlink(M.entry_path(dir, it.key)) then
        res.removed_age = res.removed_age + 1
      end
    else
      keep[#keep + 1] = it
      res.bytes = res.bytes + it.size
    end
  end
  local first = 1
  while first <= #keep and (res.bytes > max_bytes or (#keep - first + 1) > max_entries) do
    local it = keep[first]
    if uv.fs_unlink(M.entry_path(dir, it.key)) then
      res.removed_size = res.removed_size + 1
      res.bytes = res.bytes - it.size
    end
    first = first + 1
  end
  res.kept = #keep - first + 1
  return res
end

---Delete every entry (and the hash index) of the directory; nothing else is touched.
---@param dir string
---@return integer removed Entries removed.
function M.clear(dir)
  local n = 0
  for _, it in ipairs(M.list(dir)) do
    if uv.fs_unlink(M.entry_path(dir, it.key)) then
      n = n + 1
    end
  end
  sweep_tmp(dir, math.huge)
  -- a directory named like an entry (`list` skips it) is debris of the same cache: it goes too
  local handle = uv.fs_scandir(dir .. "/entries")
  while handle do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local key = name:match("^(%x+)%.json$")
    if
      key
      and is_key(key)
      and kind == "directory"
      and remove_dir_in_place(dir .. "/entries/" .. name)
    then
      n = n + 1
    end
  end
  uv.fs_unlink(dir .. "/index.json")
  return n
end

---@class Testing.Cache.DiskStats
---@field dir string
---@field entries integer
---@field bytes integer
---@field oldest? integer Unix time of the oldest entry.
---@field newest? integer

---@param dir string
---@return Testing.Cache.DiskStats
function M.disk_stats(dir)
  local s = { dir = dir, entries = 0, bytes = 0 }
  for _, it in ipairs(M.list(dir)) do
    s.entries = s.entries + 1
    s.bytes = s.bytes + it.size
    s.oldest = (s.oldest == nil or it.mtime < s.oldest) and it.mtime or s.oldest
    s.newest = (s.newest == nil or it.mtime > s.newest) and it.mtime or s.newest
  end
  return s
end

return M
