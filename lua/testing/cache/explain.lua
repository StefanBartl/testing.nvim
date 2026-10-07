---@module 'testing.cache.explain'
---@brief The decision of the cache for one spec file, as data and as text: `testing explain`.
---@description
--- DISPLAY ONLY: nothing here decides a verdict or changes a cache entry. What it shows comes from ONE call of
--- `testing.cache.key` (the key, the reason there is none, the lines the key is the hash of, the structured
--- reason): the explanation is never computed a second time, so it cannot describe another key than the run's.
---
--- `explain(info, ctx, deps)` -> a record
---
---   { file, key?, status = "hit"|"miss"|"uncacheable", reason?, kind?, location?, way_out?, parts?,
---     previous? = { run, ts, key }, changes? = { { kind, name, old?, new?, change } ... },
---     compare? = "ok"|"none", compare_why? }
---
--- On a `miss` the key lines are compared with the lines stored in the most recent entry of the file
--- (`changes`): which dependency or input file changed (name, old and new hash, never content), the Neovim
--- version, an environment variable (name, never value), the configuration. An entry of an older version carries
--- no lines: the comparison says so (`compare = "none"`), it never fails.

local M = {}

---Longest line shown from a source file.
---@type integer
M.MAX_SOURCE_LINE = 120

---Short form of a hash for display.
---@param v string|nil
---@return string|nil
local function short(v)
  if v and v:match("^%x+$") and #v > 16 then
    return v:sub(1, 12)
  end
  return v
end

---Kinds of key lines that name something with `<id>=<value>`.
---@type table<string, true>
local NAMED = { dep = true, input = true, data = true, extra = true, env = true }

---One key line as `kind`, `name` (what it is about) and `value` (what changes).
---@param line string
---@return string kind
---@return string name
---@return string value
local function split_line(line)
  local word, rest = line:match("^(%S+)%s?(.*)$")
  word, rest = word or "", rest or ""
  if NAMED[word] then
    local name, value = rest:match("^(.*)=([^=]*)$")
    if name then
      return word, name, value
    end
    return word, rest, ""
  end
  if word == "absent" or word == "outside-absent" then
    return word, rest, "absent"
  end
  return word, word, rest
end

---What changed between two lists of key lines.
---@param old string[]
---@param new string[]
---@return { kind: string, name: string, old?: string, new?: string, change: "changed"|"added"|"removed" }[]
function M.diff(old, new)
  local function index(lines)
    local out, order = {}, {}
    for _, line in ipairs(lines) do
      local kind, name, value = split_line(line)
      local id = kind .. "\0" .. name
      if out[id] == nil then
        order[#order + 1] = id
      end
      out[id] = { kind = kind, name = name, value = value }
    end
    return out, order
  end
  local a = index(old)
  local b, border = index(new)
  local changes = {}
  for _, id in ipairs(border) do
    local x, y = a[id], b[id]
    if not x then
      changes[#changes + 1] = {
        kind = y.kind,
        name = y.name,
        new = short(y.value),
        change = "added",
      }
    elseif x.value ~= y.value then
      changes[#changes + 1] = {
        kind = y.kind,
        name = y.name,
        old = short(x.value),
        new = short(y.value),
        change = "changed",
      }
    end
  end
  for id, x in pairs(a) do
    if not b[id] then
      changes[#changes + 1] = {
        kind = x.kind,
        name = x.name,
        old = short(x.value),
        change = "removed",
      }
    end
  end
  table.sort(changes, function(p, q)
    if p.kind ~= q.kind then
      return p.kind < q.kind
    end
    if p.name ~= q.name then
      return p.name < q.name
    end
    return p.change < q.change
  end)
  return changes
end

---Way out of an uncacheable file, by the kind of the reason (`Testing.Cache.Detail.kind`).
---@param detail Testing.Cache.Detail|nil
---@return string|nil
function M.way_out(detail)
  if not detail then
    return nil
  end
  local k = detail.kind
  if k == "clock" then
    return "if the clock does not decide what the spec asserts: `-- @cache-allow time` in the first 30 lines of the spec (the author vouches); otherwise give the spec a fixed time, or `-- @cache off` to say it is never cached"
  elseif k == "random" then
    return "if the random numbers do not decide what the spec asserts: `-- @cache-allow random` in the first 30 lines of the spec; otherwise seed them, or `-- @cache off`"
  elseif k == "process" then
    return "if the process does not decide what the spec asserts: `-- @cache-allow spawn` in the first 30 lines of the spec; otherwise `-- @cache off`"
  elseif k == "network" then
    return "if the network does not decide what the spec asserts: `-- @cache-allow net` in the first 30 lines of the spec; otherwise `-- @cache off`"
  elseif k == "env" then
    return ("list '%s' in `env_allow` of .testing.lua: its value (hashed) then joins the key"):format(
      tostring(detail.name)
    )
  elseif k == "env_dynamic" then
    return "read the variables by a literal name (`os.getenv('X')`) and list them in `env_allow` of .testing.lua, or `-- @cache off`"
  elseif k == "off" then
    return "remove `-- @cache off` from the header: it is the author's decision that this file is never cached"
  elseif k == "unresolved" then
    return ("make '%s' resolvable (`deps` in .testing.lua, `--rtp`), or load it with `pcall(require, ...)` where it is optional"):format(
      tostring(detail.name)
    )
  elseif k == "outside" then
    return "a file outside the project cannot be part of the key: read a copy below the project (name it with `-- @cache-inputs <path>`), or `-- @cache off`"
  elseif k == "inputs" or k == "dependency" or k == "spec" or k == "closure" then
    return "name what the spec reads with `-- @cache-inputs <path> ...`, split the spec, or `-- @cache off`"
  elseif k == "nondeterministic" then
    return "the same key gave different results: fix the flaky spec or the hidden input it reads; `-- @cache-allow nondeterministic` in the header caches it anyway"
  elseif k == "discovery" then
    return "fix the finding the discovery reports for this file"
  end
  return nil
end

---A source line for display: one line, no control characters, shortened.
---@param root string
---@param rel string
---@param line integer
---@return string|nil
local function source_line(root, rel, line)
  local text = require("lib.nvim.fs.read")(root .. "/" .. rel)
  if not text then
    return nil
  end
  local n = 0
  for l in (text .. "\n"):gmatch("(.-)\r?\n") do
    n = n + 1
    if n == line then
      l = vim.trim((l:gsub("%c", " ")))
      if #l > M.MAX_SOURCE_LINE then
        l = l:sub(1, M.MAX_SOURCE_LINE - 3) .. "..."
      end
      return l
    end
  end
  return nil
end

---@class Testing.Explain.Deps
---@field cache table `testing.cache` (key, peek).
---@field latest? table<string, Testing.Cache.Latest> Most recent stored entry per file (loaded on demand).
---@field root string
---@field cache_dir? string

---@class Testing.Explain.Record
---@field file string
---@field status "hit"|"miss"|"uncacheable"
---@field key? string
---@field reason? string
---@field kind? string Kind of the reason (`clock`, `process`, `env`, `nondeterministic`, ...).
---@field location? { file: string, line?: integer, source?: string } Where the scanner found it.
---@field way_out? string
---@field parts? string[] The lines the key is the hash of.
---@field stored_run? string On a hit: the run that stored the entry.
---@field previous? { run: string, ts: integer, key: string } The most recent stored entry of the file.
---@field changes? table[] On a miss: what differs from `previous`.
---@field compare? "ok"|"none"
---@field compare_why? string
---@field flipped? string[] The key has given these different results (and the spec is cached anyway).

---Explain one spec file. ONE call of `cache.key` makes the key, the reason and the lines.
---@param info Testing.Cache.FileInfo
---@param ctx Testing.Cache.Ctx
---@param deps Testing.Explain.Deps
---@return Testing.Explain.Record
function M.explain(info, ctx, deps)
  local cache = deps.cache
  local key, why, parts, detail = cache.key(info, ctx)
  ---@type Testing.Explain.Record
  local rec = { file = info.file, parts = parts, status = "miss" }
  if not key then
    rec.status = "uncacheable"
    rec.reason = why or "no key"
    rec.kind = detail and detail.kind or nil
    rec.way_out = M.way_out(detail)
    if detail and detail.kind ~= "nondeterministic" then
      local file = detail.file or info.file
      local loc = { file = file }
      if detail.line then
        loc.line = detail.line
        if not detail.file then
          loc.source = source_line(deps.root, info.file, detail.line)
        end
      end
      rec.location = loc
    end
    if detail and detail.key then
      rec.key = detail.key
    end
    if detail and detail.kind == "nondeterministic" then
      rec.location = nil
    end
    return rec
  end
  rec.key = key
  rec.flipped = detail and detail.flipped or nil
  local entry, miss = cache.peek(key, {
    root = deps.root,
    cache_dir = deps.cache_dir,
    file = info.file,
  })
  if entry then
    rec.status = "hit"
    rec.stored_run = entry.run
    return rec
  end
  rec.status = "miss"
  rec.reason = miss == "absent" and "no entry under this key"
    or ("entry unusable: " .. tostring(miss))
  deps.latest = deps.latest or cache.latest({ root = deps.root, cache_dir = deps.cache_dir })
  local prev = deps.latest[info.file]
  if not prev then
    rec.compare = "none"
    rec.compare_why =
      "no earlier entry of this file is stored (never ran with the cache, or pruned)"
    return rec
  end
  rec.previous = { run = prev.run, ts = prev.ts, key = prev.key }
  if not prev.parts then
    rec.compare = "none"
    rec.compare_why =
      "comparison not possible: the stored entry has no key lines (stored by an older version)"
    return rec
  end
  rec.compare = "ok"
  rec.changes = M.diff(prev.parts, parts or {})
  return rec
end

---Rank the reasons of the files that have no key (`--all`): the same wording folded together
---(names in quotes and numbers become `*`/`N`).
---@param records Testing.Explain.Record[]
---@return { reason: string, count: integer, files: string[] }[]
function M.rank_uncacheable(records)
  local by, order = {}, {}
  for _, r in ipairs(records) do
    if r.status == "uncacheable" then
      local folded = (r.reason or "no key"):gsub("'[^']*'", "'*'"):gsub("%d+", "N")
      local item = by[folded]
      if not item then
        item = { reason = folded, count = 0, files = {} }
        by[folded] = item
        order[#order + 1] = item
      end
      item.count = item.count + 1
      if #item.files < 3 then
        item.files[#item.files + 1] = r.file
      end
    end
  end
  table.sort(order, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.reason < b.reason
  end)
  return order
end

---@class Testing.Explain.Summary
---@field specs integer
---@field hit integer
---@field miss integer
---@field uncacheable integer
---@field off integer A case selection made the cache unusable.
---@field hit_rate number Hits over all the specs (0..1).
---@field reasons { reason: string, count: integer, files: string[] }[]

---@param records Testing.Explain.Record[]
---@return Testing.Explain.Summary
function M.summarize(records)
  local s = { specs = #records, hit = 0, miss = 0, uncacheable = 0, off = 0 }
  for _, r in ipairs(records) do
    s[r.status] = s[r.status] + 1
  end
  s.hit_rate = s.specs > 0 and (s.hit / s.specs) or 0
  s.reasons = M.rank_uncacheable(records)
  return s
end

return M
