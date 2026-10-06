---@module 'testing.cache.hash'
---@brief Content hashes of files with a stat pre-check and a persistent, bounded, untrusted index.
---@description
--- `vim.fn.sha256` over the bytes of a file is the truth. Reading and hashing a few hundred files per
--- run is the cost the cache wants to avoid, so a hash is remembered together with the `mtime` and
--- the size the file had when it was hashed (PERF-46: `getftime`/`getfsize` before hashing). An entry
--- is TRUSTED only when both still match AND the file was already at least `RACY_SECONDS` old when it
--- was hashed (git's "racy" rule: an edit inside the same timestamp tick with the same size would
--- otherwise go unnoticed); a younger file is hashed again every time until it ages.
---
--- The index lives in `<cache dir>/index.json`. It is UNTRUSTED input when read back (SEC-33): a size
--- cap before decoding, a version, and every entry is validated; a bad index is ignored (everything
--- is hashed again) and never trusted partially. A wrong index entry can only cost a re-hash if the
--- stat does not match; if it matches the hash was computed from this very content.
---
--- The hasher is an object: `clear` empties its tables IN PLACE (PERF-47), so a holder of the object
--- never keeps a stale reference.

local M = {}

---@type integer
M.VERSION = 2
---Seconds a file must be older than its hash for the stat pre-check to be trusted.
---@type integer
M.RACY_SECONDS = 2
---@type integer
M.MAX_INDEX_BYTES = 16 * 1024 * 1024
---@type integer
M.MAX_ENTRIES = 20000
---Largest file hashed at all; a bigger file has no hash (the caller treats the key as incomplete).
---@type integer
M.MAX_FILE_BYTES = 16 * 1024 * 1024
---@type integer
M.MAX_TREE_FILES = 5000

---@class Testing.Cache.IndexEntry
---@field m integer mtime seconds
---@field n integer mtime nanoseconds
---@field s integer size
---@field c integer ctime seconds (a content change with a restored mtime still moves it)
---@field cn integer ctime nanoseconds
---@field i integer inode (0 where the file system has none)
---@field h string sha256 hex
---@field t integer unix time the hash was computed
---@field x? Testing.Scan.Info Static analysis of a Lua file (valid as long as the hash is).

---@class Testing.Cache.Hasher
---@field entries table<string, Testing.Cache.IndexEntry>
---@field dirty boolean
---@field loaded boolean
---@field hashed integer Files read and hashed by this hasher.
---@field reused integer Files answered from the index.
---@field path? string Index file (nil: memory only).
---@field now fun(): integer
local Hasher = {}
Hasher.__index = Hasher

---@param s any
---@return boolean
local function is_hex64(s)
  return type(s) == "string" and #s == 64 and s:match("^%x+$") ~= nil
end

---@param raw any
---@param keep_analysis boolean The analysis was written by the scanner that is running.
---@return Testing.Cache.IndexEntry|nil
local function valid_entry(raw, keep_analysis)
  if type(raw) ~= "table" then
    return nil
  end
  local m, n, s, t = raw.m, raw.n, raw.s, raw.t
  local c, cn, ino = raw.c, raw.cn, raw.i
  for _, v in ipairs({ m, n, s, t, c, cn, ino }) do
    if type(v) ~= "number" or v ~= v or v < 0 or v ~= math.floor(v) or v > 9e15 then
      return nil
    end
  end
  if not is_hex64(raw.h) then
    return nil
  end
  local x = raw.x ~= nil and keep_analysis and require("testing.affected.scan").valid_info(raw.x)
    or nil
  return { m = m, n = n, s = s, c = c, cn = cn, i = ino, h = raw.h, t = t, x = x }
end

---@param path? string Index file; nil keeps the index in memory only.
---@param opts? { now?: fun(): integer }
---@return Testing.Cache.Hasher
function M.new(path, opts)
  local self = setmetatable({
    entries = {},
    dirty = false,
    hashed = 0,
    reused = 0,
    path = path,
    now = (opts and opts.now) or os.time,
    loaded = false,
  }, Hasher)
  return self
end

---Load the index file once (lazily); any problem leaves the index empty.
---@return string|nil note What was ignored.
function Hasher:load()
  if self.loaded then
    return nil
  end
  self.loaded = true
  if not self.path then
    return nil
  end
  local st = vim.uv.fs_stat(self.path)
  if not st then
    return nil
  end
  if st.type ~= "file" or st.size > M.MAX_INDEX_BYTES then
    return "hash index ignored (not a regular file or too large)"
  end
  local text = require("lib.nvim.fs.read")(self.path)
  if not text then
    return "hash index ignored (unreadable)"
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if
    not ok
    or type(decoded) ~= "table"
    or decoded.v ~= M.VERSION
    or type(decoded.files) ~= "table"
  then
    return "hash index ignored (corrupt)"
  end
  -- the hashes are facts about content; an analysis is only as good as the scanner that wrote it
  local keep_analysis = decoded.scan == require("testing.affected.scan").VERSION
  local count = 0
  for path, raw in pairs(decoded.files) do
    local e = type(path) == "string" and #path <= 1024 and valid_entry(raw, keep_analysis) or nil
    if e then
      count = count + 1
      if count > M.MAX_ENTRIES then
        break
      end
      self.entries[path] = e
    end
  end
  return nil
end

---Hash of the content of one file.
---@param abs string Absolute path.
---@return string|nil sha `nil` when the file is missing, not a regular file, or too large.
---@return string|nil why
function Hasher:file(abs)
  self:load()
  local key = vim.fs.normalize(abs)
  local st = vim.uv.fs_stat(key)
  if not st or st.type ~= "file" then
    self.entries[key] = nil
    return nil, "missing"
  end
  if st.size > M.MAX_FILE_BYTES then
    return nil, "too large"
  end
  local mt = st.mtime or { sec = 0, nsec = 0 }
  local ct = st.ctime or { sec = 0, nsec = 0 }
  local ino = (tonumber(st.ino) or 0) % 1e15
  local e = self.entries[key]
  if
    e
    and e.s == st.size
    and e.m == mt.sec
    and e.n == (mt.nsec or 0)
    and e.c == ct.sec
    and e.cn == (ct.nsec or 0)
    and e.i == ino
    and (e.t - e.m) >= M.RACY_SECONDS
  then
    self.reused = self.reused + 1
    return e.h
  end
  local text, err = require("lib.nvim.fs.read")(key)
  if not text then
    return nil, err or "unreadable"
  end
  local sha = vim.fn.sha256(text)
  self.hashed = self.hashed + 1
  self.entries[key] = {
    m = mt.sec,
    n = mt.nsec or 0,
    s = st.size,
    c = ct.sec,
    cn = ct.nsec or 0,
    i = ino,
    h = sha,
    t = self.now(),
  }
  self.dirty = true
  return sha
end

---Hash and static analysis (`testing.affected.scan`) of a Lua file; both come from the index while the
---stat still matches, so a dependency closure of thousands of files is not read again.
---@param abs string
---@return string|nil sha
---@return Testing.Scan.Info|string info The analysis; a reason string when there is no sha.
function Hasher:analyzed(abs)
  self:load()
  local key = vim.fs.normalize(abs)
  local sha, why = self:file(key)
  if not sha then
    return nil, why or "unreadable"
  end
  local e = self.entries[key]
  if e and e.x then
    return sha, e.x
  end
  local text = require("lib.nvim.fs.read")(key)
  if not text then
    return nil, "unreadable"
  end
  -- the file may have changed between the two reads: hash the bytes the analysis comes from
  local sha2 = vim.fn.sha256(text)
  local info = require("testing.affected.scan").analyze(text)
  if e then
    e.h = sha2
    e.x = info
    self.dirty = true
  end
  return sha2, info
end

---@class Testing.Cache.TreeOpts
---@field skip? fun(rel: string): boolean
---@field ignore_dirs? table<string, boolean> Directory NAMES that are not entered (`.git`).

---Digest of every file below a directory (relative names and content hashes, sorted).
---@param dir string Absolute directory.
---@param opts? Testing.Cache.TreeOpts
---@return string|nil digest `nil` when the tree is too big or a file cannot be hashed.
---@return string|nil why
function Hasher:tree(dir, opts)
  local skip = opts and opts.skip
  local ignore_dirs = opts and opts.ignore_dirs
  dir = vim.fs.normalize(dir):gsub("/+$", "")
  if vim.fn.isdirectory(dir) ~= 1 then
    return vim.fn.sha256("absent:" .. dir)
  end
  local files = require("lib.nvim.fs.collect_recursive").files(dir, {
    ignore = ignore_dirs and function(path, is_dir)
      return is_dir and ignore_dirs[path:match("([^/]+)$") or ""] == true
    end or nil,
  })
  local rels = {}
  for _, p in ipairs(files) do
    p = vim.fs.normalize(p)
    local rel = p:sub(#dir + 2)
    if not (skip and skip(rel)) then
      rels[#rels + 1] = rel
    end
  end
  if #rels > M.MAX_TREE_FILES then
    return nil, ("more than %d files below %s"):format(M.MAX_TREE_FILES, dir)
  end
  table.sort(rels)
  local parts = {}
  for _, rel in ipairs(rels) do
    local sha, why = self:file(dir .. "/" .. rel)
    if not sha then
      return nil, ("%s: %s"):format(rel, tostring(why))
    end
    parts[#parts + 1] = rel .. "\0" .. sha
  end
  return vim.fn.sha256(table.concat(parts, "\n"))
end

---Write the index back when something changed (bounded, atomic).
---@return boolean ok
---@return string|nil err
function Hasher:flush()
  if not self.path or not self.dirty then
    return true
  end
  -- bounded: the youngest hashes stay
  local keys = {}
  for k in pairs(self.entries) do
    keys[#keys + 1] = k
  end
  if #keys > M.MAX_ENTRIES then
    table.sort(keys, function(a, b)
      return self.entries[a].t > self.entries[b].t
    end)
    for i = M.MAX_ENTRIES + 1, #keys do
      self.entries[keys[i]] = nil
    end
  end
  local enc, err = require("lib.nvim.json").encode({
    v = M.VERSION,
    scan = require("testing.affected.scan").VERSION,
    files = self.entries,
  })
  if not enc then
    return false, tostring(err)
  end
  if #enc > M.MAX_INDEX_BYTES then
    -- too big to read back: write nothing rather than an index that is ignored
    return false, "hash index would exceed its size cap"
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(self.path, enc, { mkdirp = true })
  if ok then
    self.dirty = false
  end
  return ok, werr
end

---Forget everything, in place.
function Hasher:clear()
  for k in pairs(self.entries) do
    self.entries[k] = nil
  end
  self.dirty = false
  self.hashed = 0
  self.reused = 0
  self.loaded = true
end

return M
