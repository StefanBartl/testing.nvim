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
--- LINE ENDINGS. A text file is hashed with `\r\n` read as `\n` (`M.normalize`): git's `core.autocrlf` writes the same
--- commit with CRLF on one machine and with LF on another, and the content hash (so every key) must not depend on that.
--- A file with a NUL byte in its first `M.BINARY_PROBE` bytes is binary and is hashed as it is. The entry keeps the hash
--- of the raw bytes as well (`r`, only when it differs) and whether the text had CRLF (`k`): a key that has to stay
--- conservative (a spec that looks at line endings itself, see `docs/CACHE.md`) asks for the raw hash.
---
--- The hasher is an object: `clear` empties its tables IN PLACE (PERF-47), so a holder of the object
--- never keeps a stale reference.

local M = {}

---(3: the hash of a text file reads CRLF as LF; the entry keeps the raw hash `r` and the flag `k`.)
---@type integer
M.VERSION = 3
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
---A file with a NUL byte within this many bytes is binary: it is hashed as it is.
---@type integer
M.BINARY_PROBE = 8192

---Most symlinked directories one tree digest follows (more: no digest, so no key).
M.MAX_LINKS = 64

---@class Testing.Cache.IndexEntry
---@field m integer mtime seconds
---@field n integer mtime nanoseconds
---@field s integer size
---@field c integer ctime seconds (a content change with a restored mtime still moves it)
---@field cn integer ctime nanoseconds
---@field i integer inode (0 where the file system has none)
---@field h string sha256 hex of the text with CRLF read as LF (of the bytes for a binary file)
---@field r? string sha256 hex of the raw bytes; only when the text had CRLF
---@field k? boolean The text had CRLF line endings (and is not binary)
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
  if raw.k ~= nil and type(raw.k) ~= "boolean" then
    return nil
  end
  local crlf = raw.k == true
  if (crlf and not is_hex64(raw.r)) or (not crlf and raw.r ~= nil) then
    return nil
  end
  local x = raw.x ~= nil and keep_analysis and require("testing.affected.scan").valid_info(raw.x)
    or nil
  return {
    m = m,
    n = n,
    s = s,
    c = c,
    cn = cn,
    i = ino,
    h = raw.h,
    r = crlf and raw.r or nil,
    k = crlf or nil,
    t = t,
    x = x,
  }
end

---The text as it is hashed: `\r\n` read as `\n`, unless the file is binary (a NUL byte in the first
---`M.BINARY_PROBE` bytes). A lone `\r` stays.
---@param text string
---@return string normalized
---@return boolean crlf The text had CRLF line endings and was changed.
function M.normalize(text)
  if not text:find("\r\n", 1, true) then
    return text, false
  end
  if text:sub(1, M.BINARY_PROBE):find("\0", 1, true) then
    return text, false
  end
  return (text:gsub("\r\n", "\n")), true
end

---Both hashes of a text: of the normalized text, and of the raw bytes when they differ.
---@param text string
---@return string h
---@return string|nil r
---@return boolean|nil k
local function hashes_of(text)
  local norm, crlf = M.normalize(text)
  if not crlf then
    return vim.fn.sha256(text), nil, nil
  end
  return vim.fn.sha256(norm), vim.fn.sha256(text), true
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

---Hash of the content of one file (CRLF read as LF, see the header).
---@param abs string Absolute path.
---@param raw? boolean The hash of the bytes as they are.
---@return string|nil sha `nil` when the file is missing, not a regular file, or too large.
---@return string|nil why
---@return boolean|nil crlf The text has CRLF line endings (so the normalized hash differs from the raw one).
function Hasher:file(abs, raw)
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
    return (raw and e.r) or e.h, nil, e.k == true
  end
  local text, err = require("lib.nvim.fs.read")(key)
  if not text then
    return nil, err or "unreadable"
  end
  local entry = {
    m = mt.sec,
    n = mt.nsec or 0,
    s = st.size,
    c = ct.sec,
    cn = ct.nsec or 0,
    i = ino,
    t = self.now(),
  }
  entry.h, entry.r, entry.k = hashes_of(text)
  self.hashed = self.hashed + 1
  self.entries[key] = entry
  self.dirty = true
  return (raw and entry.r) or entry.h, nil, entry.k == true
end

---Hash and static analysis (`testing.affected.scan`) of a Lua file; both come from the index while the
---stat still matches, so a dependency closure of thousands of files is not read again.
---@param abs string
---@param raw? boolean The hash of the bytes as they are.
---@return string|nil sha
---@return Testing.Scan.Info|string info The analysis; a reason string when there is no sha.
---@return boolean|nil crlf The text has CRLF line endings.
function Hasher:analyzed(abs, raw)
  self:load()
  local key = vim.fs.normalize(abs)
  local sha, why, crlf = self:file(key, raw)
  if not sha then
    return nil, why or "unreadable"
  end
  local e = self.entries[key]
  if e and e.x then
    return sha, e.x, crlf
  end
  local text = require("lib.nvim.fs.read")(key)
  if not text then
    return nil, "unreadable"
  end
  -- the file may have changed between the two reads: hash the bytes the analysis comes from
  local h, r, k = hashes_of(text)
  local info = require("testing.affected.scan").analyze(text)
  if e then
    e.h, e.r, e.k = h, r, k
    e.x = info
    self.dirty = true
  end
  return (raw and r) or h, info, k == true
end

---@class Testing.Cache.TreeOpts
---@field raw? boolean The hashes of the bytes as they are (no CRLF read as LF).
---@field skip? fun(rel: string): boolean
---@field ignore_dirs? table<string, boolean> Directory NAMES that are not entered (`.git`).

---Every file below a directory, symlinked directories FOLLOWED: the ONE list of files that a digest of a tree
---(`Hasher:tree`) and a reader of the same tree (the members of the cache key) agree on, so that a file that is part
---of the digest is also a file the key analyses.
---
---ERR-34 says a recursive walk never enters a symlinked directory (an endless loop through a link to an ancestor).
---This walk deviates on purpose, and keeps what the rule is for: a fixture directory that is a link is an INPUT of the
---spec, so a file below it must change the digest. The walker itself still does not enter links; they are collected
---here (the callback sees every directory, so no per-file stat) and followed one by one, EACH REAL DIRECTORY ONCE
---(`seen`) and at most `M.MAX_LINKS` of them, so a loop ends after one round and nothing is read twice. The walk only
---reads: nothing is written or deleted through a link. The files below a link are named by the path of the link (not
---by its target), so they stay below `dir`.
---@param dir string Absolute directory (normalized, no trailing slash).
---@param ignore_dirs? table<string, boolean> Directory NAMES that are not entered (`.git`).
---@return string[]|nil files `nil` when a directory cannot be listed or there are too many links.
---@return string[]|string links The links met (every one, also those whose target was already followed), or why there are no files.
---@return string|nil real_dir The real path of `dir`.
function M.list_files(dir, ignore_dirs)
  local collect = require("lib.nvim.fs.collect_recursive")
  local uv = vim.uv
  local links, all_links = {}, {}
  local function ignore(path, is_dir)
    if not is_dir then
      return false
    end
    if ignore_dirs and ignore_dirs[path:match("([^/]+)$") or ""] == true then
      return true
    end
    local lst = uv.fs_lstat(path)
    if lst and lst.type == "link" then
      links[#links + 1] = path
      all_links[#all_links + 1] = path
    end
    return false
  end
  -- a directory the walk cannot list is NOT an empty one: the files below it would be left out of the digest, and
  -- an edit of one of them (a spec may open it by name) would be served a stale green. No digest, no key.
  local files, unreadable = collect.files(dir, { ignore = ignore })
  if unreadable then
    return nil, ("unreadable directory: %s"):format(tostring(unreadable[1]))
  end
  local real_dir = uv.fs_realpath(dir) or dir
  local seen = { [real_dir] = true }
  local followed = 0
  while #links > 0 do
    local link = table.remove(links, 1)
    local real = uv.fs_realpath(link)
    if real and not seen[real] then
      seen[real] = true
      followed = followed + 1
      if followed > M.MAX_LINKS then
        return nil, ("more than %d symlinked directories below %s"):format(M.MAX_LINKS, dir)
      end
      local more, link_unreadable = collect.files(link, { ignore = ignore })
      if link_unreadable then
        return nil, ("unreadable directory: %s"):format(tostring(link_unreadable[1]))
      end
      vim.list_extend(files, more)
    end
  end
  return files, all_links, real_dir
end

---Digest of every file below a directory (relative names and content hashes, sorted).
---@param dir string Absolute directory.
---@param opts? Testing.Cache.TreeOpts
---@return string|nil digest `nil` when the tree is too big or a file cannot be hashed.
---@return string|nil why
---@return boolean|nil crlf Some file of the tree has CRLF line endings.
function Hasher:tree(dir, opts)
  local skip = opts and opts.skip
  local ignore_dirs = opts and opts.ignore_dirs
  dir = vim.fs.normalize(dir):gsub("/+$", "")
  if vim.fn.isdirectory(dir) ~= 1 then
    return vim.fn.sha256("absent:" .. dir)
  end
  -- The traversal is deduplicated (`M.list_files`), the digest is not: every link is a line of its own
  -- (`link <rel> -> <target>`), so two links to one directory are two lines, and removing one of them changes the
  -- digest.
  local files, all_links, real_dir = M.list_files(dir, ignore_dirs)
  if not files then
    return nil, all_links
  end
  local uv = vim.uv
  local link_lines = {}
  for _, link in ipairs(all_links) do
    local rel = vim.fs.normalize(link):sub(#dir + 2)
    if not (skip and skip(rel)) then
      local real = uv.fs_realpath(link)
      -- a target below the directory is named relative to it (the digest must not change when the checkout moves)
      local target = real and vim.fs.normalize(real) or "<unresolved>"
      if real and target:sub(1, #real_dir + 1) == vim.fs.normalize(real_dir) .. "/" then
        target = "./" .. target:sub(#real_dir + 2)
      end
      link_lines[#link_lines + 1] = "link " .. rel .. " -> " .. target
    end
  end
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
  table.sort(link_lines)
  local parts = {}
  for _, line in ipairs(link_lines) do
    parts[#parts + 1] = line
  end
  local any_crlf = false
  for _, rel in ipairs(rels) do
    local sha, why, crlf = self:file(dir .. "/" .. rel, opts and opts.raw)
    if not sha then
      return nil, ("%s: %s"):format(rel, tostring(why))
    end
    any_crlf = any_crlf or crlf == true
    parts[#parts + 1] = rel .. "\0" .. sha
  end
  return vim.fn.sha256(table.concat(parts, "\n")), nil, any_crlf
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
