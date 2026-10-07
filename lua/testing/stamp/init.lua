---@module 'testing.stamp'
---@brief The green stamp: a small, checkable statement "this tree was fully green", and its untrusted-input rules.
---@description
--- After a COMPLETE green run (`verdict.kind == "green"`: nothing selected away, nothing skipped, nothing
--- stopped) `testing stamp` writes the keys the result cache would use for every spec file of the project
--- (`testing.cache.key`), or the reason a file has none, plus the facts the keys do not show on their own:
--- runner digest, Neovim version, OS and architecture, configuration digest. `testing verify` recomputes the keys
--- (no spec runs) and answers `verified` only when EVERY file is proven. A file without a key can never be proven:
--- the answer is then `partial` (and never green), and names what to run.
---
--- The stamp inherits every limit of the cache key (docs/CACHE.md, "Known limit"): it says "no input the key can
--- see has changed since a green run", nothing more. Age, the dirty-tree check and the trust rules of
--- `testing.stamp.verify` bound what that statement is worth.
---
--- File layout (`schema = "testing-stamp/1"`; JSON):
---
---   { schema, v = 1,
---     head   = { commit?, tree?, dirty?, run, ts, summary = { files, keyed, cases, cached, ran } },
---     origin = { kind = "local"|"ci", event?, ref?, trusted },
---     env    = { runner, nvim, os, config },
---     files  = [ { file, key } | { file, uncacheable } ]   -- strictly ascending by byte order, no duplicates
---     digest = sha256 hex of the canonical text (`M.payload`),
---     hmac?  = HMAC-SHA-256 hex of the canonical text under a secret from the environment }
---
--- Nothing secret is in it: no environment values, no tokens, no absolute path (a reason that names the project
--- root has it replaced by `<root>`). The summary is for display only, `verify` derives its counts from `files`.
---
--- UNTRUSTED when read back (like cache entries and `runs.jsonl`): a size cap before decoding, a decode under
--- `pcall`, every field type- and shape-checked, a closed set of schema versions, plain-text fields without control
--- characters, time values within sane bounds, a digest that must match the content (damage and edits show),
--- and an optional HMAC (authenticity: the digest alone can be recomputed by anyone who edits the file). A stamp
--- that fails any check is not used and `verify` says why. Nothing from a stamp becomes a path, a command, a pattern
--- or an argument to git.

local sha = require("testing.stamp.sha")

local M = {}

---@type string
M.SCHEMA = "testing-stamp/1"
---@type integer
M.VERSION = 1
---Largest stamp file read (bytes), checked before it is decoded.
---@type integer
M.MAX_BYTES = 8 * 1024 * 1024
---Most spec files a stamp lists.
---@type integer
M.MAX_FILES = 20000
---Longest stored reason (characters).
---@type integer
M.MAX_REASON = 300
---Default maximum age of a stamp (seconds): older is `expired`, the suite must run.
---@type integer
M.DEFAULT_MAX_AGE = 7 * 86400
---Longest `--max-age`: ten years.
---@type integer
M.MAX_AGE_LIMIT = 10 * 365 * 86400
---A stamp from the future by more than this (clock skew) is not believed.
---@type integer
M.FUTURE_SLACK = 300
---Environment variable that holds the HMAC secret.
---@type string
M.SECRET_ENV = "TESTING_STAMP_SECRET"
---Shortest secret accepted.
---@type integer
M.MIN_SECRET = 16
---Comma-separated refs a CI stamp counts as trusted for (default below).
---@type string
M.TRUSTED_REFS_ENV = "TESTING_STAMP_TRUSTED_REFS"
---@type string[]
M.DEFAULT_TRUSTED_REFS = { "refs/heads/main", "refs/heads/master" }
---CI events whose runs are not started by a pull request (a fork or a pull request never writes a trusted stamp).
---@type table<string, true>
M.TRUSTED_EVENTS = { push = true, schedule = true, workflow_dispatch = true }

---@class Testing.Stamp.Record
---@field file string Spec file, relative to the root.
---@field key? string The cache key (64 hex).
---@field uncacheable? string Why there is no key.

---@class Testing.Stamp.Head
---@field commit? string
---@field tree? string
---@field dirty? boolean The working tree had uncommitted changes when the stamp was written.
---@field run string
---@field ts integer
---@field summary? { files: integer, keyed: integer, cases: integer, cached: integer, ran: integer } Display only.

---@class Testing.Stamp.Origin
---@field kind "local"|"ci"
---@field event? string
---@field ref? string
---@field trusted boolean

---@class Testing.Stamp.Env
---@field runner string
---@field nvim string
---@field os string
---@field config string

---@class Testing.Stamp
---@field schema string
---@field v integer
---@field head Testing.Stamp.Head
---@field origin Testing.Stamp.Origin
---@field env Testing.Stamp.Env
---@field files Testing.Stamp.Record[]
---@field digest string
---@field hmac? string

---Byte-order comparison: the same on every machine (the `<` of strings follows the locale).
---@param a string
---@param b string
---@return integer -1, 0 or 1
function M.bytecmp(a, b)
  if a == b then
    return 0
  end
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y and -1 or 1
    end
  end
  return #a < #b and -1 or 1
end

---@param records Testing.Stamp.Record[]
function M.sort_records(records)
  table.sort(records, function(a, b)
    return M.bytecmp(a.file, b.file) < 0
  end)
end

---Where a stamp is kept by default (beside the history of the project, outside the checkout).
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/stamp.json"
end

---The canonical text a digest and an HMAC are made over: one line per fact, the files sorted by byte order.
---The same stamp always gives the same bytes.
---@param st { head: Testing.Stamp.Head, origin: Testing.Stamp.Origin, env: Testing.Stamp.Env, files: Testing.Stamp.Record[] }
---@return string
function M.payload(st)
  local h, o, e = st.head, st.origin, st.env
  local lines = {
    "testing-stamp " .. M.VERSION,
    "commit " .. (h.commit or "-"),
    "tree " .. (h.tree or "-"),
    "dirty " .. (h.dirty and "1" or "0"),
    "run " .. h.run,
    "ts " .. string.format("%d", h.ts),
    ("origin %s %s %s %s"):format(o.kind, o.event or "-", o.ref or "-", o.trusted and "1" or "0"),
    "runner " .. e.runner,
    "nvim " .. e.nvim,
    "os " .. e.os,
    "config " .. e.config,
    "files " .. #st.files,
  }
  for _, f in ipairs(st.files) do
    if f.key then
      lines[#lines + 1] = "K\t" .. f.file .. "\t" .. f.key
    else
      lines[#lines + 1] = "U\t" .. f.file .. "\t" .. tostring(f.uncacheable)
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

---Make a stamp. `records` need not be sorted; the stamp is built from copies.
---@param o { head: Testing.Stamp.Head, origin: Testing.Stamp.Origin, env: Testing.Stamp.Env, records: Testing.Stamp.Record[], secret?: string }
---@return Testing.Stamp
function M.build(o)
  local files = {}
  for _, r in ipairs(o.records) do
    files[#files + 1] =
      { file = r.file, key = r.key, uncacheable = (not r.key) and r.uncacheable or nil }
  end
  M.sort_records(files)
  local st = {
    schema = M.SCHEMA,
    v = M.VERSION,
    head = vim.deepcopy(o.head),
    origin = vim.deepcopy(o.origin),
    env = vim.deepcopy(o.env),
    files = files,
  }
  local keyed = 0
  for _, f in ipairs(files) do
    keyed = keyed + (f.key and 1 or 0)
  end
  st.head.summary = st.head.summary
    or { files = #files, keyed = keyed, cases = 0, cached = 0, ran = 0 }
  local text = M.payload(st)
  st.digest = vim.fn.sha256(text)
  if o.secret and o.secret ~= "" then
    st.hmac = sha.hmac(o.secret, text)
  end
  return st
end

---@param st Testing.Stamp
---@return string|nil json
---@return string|nil err
function M.encode(st)
  return require("lib.nvim.json").encode(st, { indent = 2 })
end

---@param s any
---@param max integer
---@return boolean
local function plain(s, max)
  return type(s) == "string" and s ~= "" and #s <= max and not s:find("[%c\127]")
end

---@param s any
---@param lens integer[]
---@return boolean
local function hex(s, lens)
  if type(s) ~= "string" or not s:match("^[0-9a-f]+$") then
    return false
  end
  for _, n in ipairs(lens) do
    if #s == n then
      return true
    end
  end
  return false
end

---@param n any
---@return boolean
local function unix_time(n)
  return type(n) == "number" and n == n and n >= 0 and n <= 4102444800 and n == math.floor(n)
end

---A spec file path as the stamp lists it: relative, forward slashes, no `..`, no control characters.
---@param p any
---@return boolean
local function safe_path(p)
  if not plain(p, 1024) or p:find("\\", 1, true) or p:sub(1, 1) == "/" or p:match("^%a:") then
    return false
  end
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      return false
    end
  end
  return true
end

---Is a decoded value an array (keys 1..n, nothing else)?
---@param t any
---@return integer|nil n
local function array_len(t)
  if type(t) ~= "table" then
    return nil
  end
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  if n ~= #t then
    return nil
  end
  return n
end

---Validate a decoded stamp. Returns a stamp rebuilt from the validated fields only (unknown fields are dropped).
---@param raw any
---@return Testing.Stamp|nil
---@return string|nil why
function M.validate(raw)
  if type(raw) ~= "table" then
    return nil, "not a JSON object"
  end
  if raw.schema ~= M.SCHEMA or raw.v ~= M.VERSION then
    return nil,
      ("unknown schema or version (this runner reads %s, v%d)"):format(M.SCHEMA, M.VERSION)
  end
  local h = raw.head
  if type(h) ~= "table" then
    return nil, "no head"
  end
  if h.commit ~= nil and not hex(h.commit, { 40, 64 }) then
    return nil, "bad commit"
  end
  if h.tree ~= nil and not hex(h.tree, { 40, 64 }) then
    return nil, "bad tree"
  end
  if h.dirty ~= nil and type(h.dirty) ~= "boolean" then
    return nil, "bad dirty flag"
  end
  if not plain(h.run, 100) then
    return nil, "bad run id"
  end
  if not unix_time(h.ts) then
    return nil, "bad timestamp"
  end
  local o = raw.origin
  if
    type(o) ~= "table"
    or (o.kind ~= "local" and o.kind ~= "ci")
    or type(o.trusted) ~= "boolean"
  then
    return nil, "bad origin"
  end
  if o.event ~= nil and not (plain(o.event, 50) and o.event:match("^[%w_%-]+$")) then
    return nil, "bad origin event"
  end
  if o.ref ~= nil and not (plain(o.ref, 200) and o.ref:match("^[%w_%./%-]+$")) then
    return nil, "bad origin ref"
  end
  local e = raw.env
  if
    type(e) ~= "table"
    or not plain(e.runner, 200)
    or not plain(e.nvim, 200)
    or not plain(e.os, 100)
    or not plain(e.config, 200)
  then
    return nil, "bad environment facts"
  end
  local n = array_len(raw.files)
  if not n or n < 1 then
    return nil, "no files"
  end
  if n > M.MAX_FILES then
    return nil, ("more than %d files"):format(M.MAX_FILES)
  end
  local files, prev = {}, nil
  for i = 1, n do
    local f = raw.files[i]
    if type(f) ~= "table" or not safe_path(f.file) then
      return nil, ("bad file entry %d"):format(i)
    end
    if prev and M.bytecmp(prev, f.file) >= 0 then
      return nil, "files are not strictly ascending (duplicate or unsorted)"
    end
    prev = f.file
    if f.key ~= nil then
      if f.uncacheable ~= nil or not hex(f.key, { 64 }) then
        return nil, ("bad key for %s"):format(f.file)
      end
      files[i] = { file = f.file, key = f.key }
    else
      if not plain(f.uncacheable, M.MAX_REASON) then
        return nil, ("bad reason for %s"):format(f.file)
      end
      files[i] = { file = f.file, uncacheable = f.uncacheable }
    end
  end
  if not hex(raw.digest, { 64 }) then
    return nil, "bad digest"
  end
  if raw.hmac ~= nil and not hex(raw.hmac, { 64 }) then
    return nil, "bad hmac"
  end
  local st = {
    schema = M.SCHEMA,
    v = M.VERSION,
    head = {
      commit = h.commit,
      tree = h.tree,
      dirty = h.dirty,
      run = h.run,
      ts = h.ts,
    },
    origin = { kind = o.kind, event = o.event, ref = o.ref, trusted = o.trusted },
    env = { runner = e.runner, nvim = e.nvim, os = e.os, config = e.config },
    files = files,
    digest = raw.digest,
    hmac = raw.hmac,
  }
  if type(h.summary) == "table" then
    local s = h.summary
    local function count(v)
      return (type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 10000000) and v or 0
    end
    st.head.summary = {
      files = count(s.files),
      keyed = count(s.keyed),
      cases = count(s.cases),
      cached = count(s.cached),
      ran = count(s.ran),
    }
  end
  if vim.fn.sha256(M.payload(st)) ~= raw.digest then
    return nil, "the digest does not match the content (the file was edited or damaged)"
  end
  return st, nil
end

---Decode and validate the text of a stamp file.
---@param text any
---@return Testing.Stamp|nil
---@return string|nil why
function M.decode(text)
  if type(text) ~= "string" then
    return nil, "nothing to read"
  end
  if #text > M.MAX_BYTES then
    return nil, ("larger than %d bytes"):format(M.MAX_BYTES)
  end
  local ok, raw = pcall(require("lib.nvim.json").decode, text)
  if not ok or raw == nil then
    return nil, "not valid JSON"
  end
  return M.validate(raw)
end

---Does the HMAC of a stamp match under `secret`?
---@param st Testing.Stamp
---@param secret string
---@return boolean
function M.hmac_ok(st, secret)
  return st.hmac ~= nil and sha.equal(st.hmac, sha.hmac(secret, M.payload(st)))
end

---`7d`, `12h`, `30m`, `90s` or a plain number of seconds.
---@param text any
---@return integer|nil seconds
---@return string|nil why
function M.parse_age(text)
  if type(text) ~= "string" then
    return nil, "no value"
  end
  local n, unit = text:match("^(%d+)([smhd]?)$")
  if not n then
    return nil,
      ("'%s' is not a duration (use 7d, 12h, 30m, 90s or a number of seconds)"):format(text)
  end
  local mult = ({ s = 1, m = 60, h = 3600, d = 86400, [""] = 1 })[unit]
  local secs = tonumber(n) * mult
  if secs < 1 or secs > M.MAX_AGE_LIMIT then
    return nil, ("'%s' is outside 1 second .. 10 years"):format(text)
  end
  return math.floor(secs), nil
end

---Where the stamp is being written from, as far as the environment says: `local`, or `ci` with the event and ref.
---`trusted` is true only for a CI run that was not started by a pull request (event in `TRUSTED_EVENTS`) on one of
---the trusted refs. This is what the WRITER believes of itself; whoever reads a stamp believes it only as far as the
---stamp's transport and its HMAC allow (docs/CACHE.md, "Stamp").
---@param getenv fun(name: string): string|nil
---@return Testing.Stamp.Origin
function M.origin(getenv)
  if not require("testing.affected").in_ci(getenv) then
    return { kind = "local", trusted = false }
  end
  local event, ref = getenv("GITHUB_EVENT_NAME"), getenv("GITHUB_REF")
  if not (event and event:match("^[%w_%-]+$") and #event <= 50) then
    event = nil
  end
  if not (ref and ref:match("^[%w_%./%-]+$") and #ref <= 200) then
    ref = nil
  end
  local refs = M.DEFAULT_TRUSTED_REFS
  local configured = getenv(M.TRUSTED_REFS_ENV)
  if configured and configured ~= "" then
    refs = {}
    for r in configured:gmatch("[^,]+") do
      refs[#refs + 1] = vim.trim(r)
    end
  end
  local trusted = false
  if event and ref and M.TRUSTED_EVENTS[event] then
    for _, r in ipairs(refs) do
      trusted = trusted or r == ref
    end
  end
  return { kind = "ci", event = event, ref = ref, trusted = trusted }
end

return M
