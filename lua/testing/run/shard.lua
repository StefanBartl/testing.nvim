---@module 'testing.run.shard'
---@brief `--shard i/n`: a deterministic partition of the spec files for CI matrices.
---@description
--- A matrix job `i` of `n` runs the files of bucket `i` and nothing else. The partition is a pure
--- function of the file list, the balance mode and the weights, so every job of the matrix computes the
--- SAME `n` buckets and takes its own: the union of all buckets is the whole list and no file is in two
--- of them (`M.partition` is specified against a fixture list).
---
--- BALANCE (`.testing.lua` `shard.balance`)
---   * `"size"` (default): the weight of a file is its size in bytes. It needs nothing but the checkout, so
---     every job of a matrix sees the same weights whatever its history looks like;
---   * `"count"`: every file weighs 1 (equal file counts, +-1);
---   * `"hash"`: bucket = stable hash of the relative path modulo `n`. Adding a file moves no other file,
---     but small suites are unbalanced;
---   * `"history"`: the weight is the duration of the file in the last run that recorded one. DANGER: the
---     buckets are only equal on all jobs when all jobs read the SAME durations. A job with a different
---     local history computes a different partition, and then some file runs twice and some never. The
---     durations therefore come from `shard.durations` (a JSON file `{ "<rel>": <ms>, ... }` that belongs
---     to the repository or to a restored CI cache) when that key is set; without it the local history
---     (`durations.json` beside `runs.jsonl`) is used and the caller says so. A file without a known
---     duration weighs the median of the known ones.
---
--- ALGORITHM. `hash`: modulo. The others: longest-processing-time-first, i.e. the files are sorted by weight
--- (heaviest first; ties by the stable hash of the path, then the path) and each goes to the bucket with
--- the smallest load so far (ties: the lowest bucket). Inside a bucket the files keep the order of the
--- input list, so a shard runs its files in the order a full run would.
---
--- The hash is the first 32 bits of `vim.fn.sha256(rel)`: stable across platforms and versions (paths are
--- compared with `/` separators).
---
--- DURATIONS. `M.record_durations` stores, after a run, the wall time of every file (the sum of its case
--- durations) in `durations.json` beside the history. Bounded and validated like the history (the file is
--- untrusted input when read back); a failure is a note, never a verdict.

local M = {}

---@type string[]
M.BALANCES = { "size", "history", "count", "hash" }

---Most files `durations.json` remembers.
M.MAX_FILES = 5000
---Largest accepted `durations.json` in bytes.
M.MAX_BYTES = 1048576
---Longest path kept in `durations.json`.
M.MAX_PATH_BYTES = 500

---@class Testing.Shard.Item
---@field rel string Project-relative path with `/` separators.
---@field weight? number Positive weight (`size`/`history`); absent = unknown.

---@class Testing.Shard.Opts
---@field balance? "size"|"history"|"count"|"hash" Default `size`.
---@field weights? table<string, number> rel -> weight (what `M.weights` returns).
---@field hash? fun(rel: string): integer Replaces the sha256 based hash (specs).

---@class Testing.Shard.Info
---@field index integer
---@field count integer
---@field balance string
---@field total integer Files in the whole list.
---@field selected integer Files of this shard.
---@field loads number[] Summed weight of every bucket (1 per file for `count` and `hash`).

---Stable 32-bit hash of a relative path.
---@param rel string
---@return integer
function M.hash(rel)
  return tonumber(vim.fn.sha256((rel:gsub("\\", "/"))):sub(1, 8), 16) --[[@as integer]]
end

---@param list number[]
---@return number
local function median(list)
  if #list == 0 then
    return 1
  end
  local sorted = vim.list_slice(list, 1, #list)
  table.sort(sorted)
  local mid = math.floor((#sorted + 1) / 2)
  if #sorted % 2 == 1 then
    return sorted[mid]
  end
  return (sorted[mid] + sorted[mid + 1]) / 2
end

---Partition `items` into `count` buckets.
---@param items Testing.Shard.Item[]
---@param count integer >= 1
---@param opts? Testing.Shard.Opts
---@return string[][] buckets `count` lists of rel, each in input order.
---@return number[] loads Summed weight per bucket.
function M.partition(items, count, opts)
  opts = opts or {}
  local balance = opts.balance or "size"
  local hash = opts.hash or M.hash
  local buckets, loads = {}, {}
  for b = 1, count do
    buckets[b], loads[b] = {}, 0
  end

  -- one entry per distinct path: a duplicate in the input is the caller's problem, never run twice
  local seen, list = {}, {}
  for _, it in ipairs(items) do
    if not seen[it.rel] then
      seen[it.rel] = true
      list[#list + 1] = it
    end
  end

  local assigned = {}
  if balance == "hash" then
    for _, it in ipairs(list) do
      local b = hash(it.rel) % count + 1
      assigned[it.rel] = b
      loads[b] = loads[b] + 1
    end
  else
    local known = {}
    for _, it in ipairs(list) do
      local w = it.weight
      if balance ~= "count" and type(w) == "number" and w > 0 then
        known[#known + 1] = w
      end
    end
    local fallback = median(known)
    local rows = {}
    for _, it in ipairs(list) do
      local w = 1
      if balance ~= "count" then
        w = (type(it.weight) == "number" and it.weight > 0) and it.weight or fallback
      end
      rows[#rows + 1] = { rel = it.rel, w = w, h = hash(it.rel) }
    end
    table.sort(rows, function(a, b)
      if a.w ~= b.w then
        return a.w > b.w
      end
      if a.h ~= b.h then
        return a.h < b.h
      end
      return a.rel < b.rel
    end)
    for _, row in ipairs(rows) do
      local best = 1
      for b = 2, count do
        if loads[b] < loads[best] then
          best = b
        end
      end
      assigned[row.rel] = best
      loads[best] = loads[best] + row.w
    end
  end

  for _, it in ipairs(list) do
    local b = assigned[it.rel]
    buckets[b][#buckets[b] + 1] = it.rel
  end
  return buckets, loads
end

---Keep the files of shard `spec.index` of `spec.count`.
---@generic T: { rel: string }
---@param entries T[] Discovered files (anything with a `rel`), in run order.
---@param spec { index: integer, count: integer }
---@param opts? Testing.Shard.Opts
---@return T[] selected In the order of `entries`.
---@return Testing.Shard.Info info
function M.apply(entries, spec, opts)
  opts = opts or {}
  local weights = opts.weights or {}
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = { rel = e.rel, weight = weights[e.rel] }
  end
  local buckets, loads = M.partition(items, spec.count, opts)
  local mine = {}
  for _, rel in ipairs(buckets[spec.index]) do
    mine[rel] = true
  end
  local selected, taken = {}, {}
  for _, e in ipairs(entries) do
    if mine[e.rel] and not taken[e.rel] then
      taken[e.rel] = true
      selected[#selected + 1] = e
    end
  end
  return selected,
    {
      index = spec.index,
      count = spec.count,
      balance = opts.balance or "size",
      total = #entries,
      selected = #selected,
      loads = loads,
    }
end

-- =========================================================
-- Weights and durations
-- =========================================================

---Path of the durations file of a project.
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.durations_path(root, opts)
  return require("testing.history").dir(root, opts) .. "/durations.json"
end

---Validate a decoded `{ rel = ms }` object; never raises.
---@param raw any
---@return table<string, number> durations
---@return integer dropped Entries that were no usable pair.
function M.validate_durations(raw)
  local out, dropped, n = {}, 0, 0
  if type(raw) ~= "table" then
    return out, 1
  end
  for rel, ms in pairs(raw) do
    if
      type(rel) == "string"
      and rel ~= ""
      and #rel <= M.MAX_PATH_BYTES
      and not rel:find("%c")
      and type(ms) == "number"
      and ms == ms
      and ms >= 0
      and ms < 86400000
      and n < M.MAX_FILES
    then
      out[rel] = ms
      n = n + 1
    else
      dropped = dropped + 1
    end
  end
  return out, dropped
end

---Read a durations JSON file (size cap, decode under pcall, validation).
---@param path string
---@return table<string, number> durations Empty when there is none or it is unusable.
---@return string|nil note Why it is empty or what was dropped.
function M.read_durations(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}, nil
  end
  if stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return {},
      ("durations file %s is not a regular file or larger than %d bytes: ignored"):format(
        path,
        M.MAX_BYTES
      )
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return {}, ("durations file %s cannot be read: %s"):format(path, tostring(err))
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok or decoded == nil then
    return {}, ("durations file %s is not valid JSON: ignored"):format(path)
  end
  local durations, dropped = M.validate_durations(decoded)
  if dropped > 0 then
    return durations, ("durations file %s: %d unusable entr(y/ies) ignored"):format(path, dropped)
  end
  return durations, nil
end

---The weights of the files for a balance mode.
---@param root string
---@param rels string[]
---@param opts? { balance?: string, durations_file?: string, state_dir?: string, stat?: fun(path: string): { size: integer }|nil }
---@return table<string, number> weights Missing = unknown.
---@return string[] notes
function M.weights(root, rels, opts)
  opts = opts or {}
  local balance = opts.balance or "size"
  local weights, notes = {}, {}
  if balance == "size" then
    local stat = opts.stat or vim.uv.fs_stat
    for _, rel in ipairs(rels) do
      local st = stat(root .. "/" .. rel)
      if st and type(st.size) == "number" then
        -- an empty file still costs a process start: weight at least 1
        weights[rel] = math.max(st.size, 1)
      end
    end
  elseif balance == "history" then
    local path = opts.durations_file
    if not path then
      path = M.durations_path(root, opts)
      notes[#notes + 1] =
        'shard.balance = "history" reads the LOCAL history: every job of the matrix must see the same durations (set shard.durations to a file of the repository)'
    end
    local durations, note = M.read_durations(path)
    if note then
      notes[#notes + 1] = note
    end
    for _, rel in ipairs(rels) do
      weights[rel] = durations[rel]
    end
  end
  return weights, notes
end

---After a run: remember the duration of every file that produced cases (the sum of its cases).
---@param root string
---@param res Testing.Result
---@param info? { known_files?: table<string, true>, previous?: table<string, number> }
---@param opts? { state_dir?: string }
---@return boolean ok
---@return string|nil err
function M.record_durations(root, res, info, opts)
  info = info or {}
  local path = M.durations_path(root, opts)
  local merged = info.previous or M.read_durations(path)
  local per_file = {}
  for _, c in ipairs(res.cases or {}) do
    if type(c.file) == "string" and type(c.duration_ms) == "number" then
      per_file[c.file] = (per_file[c.file] or 0) + c.duration_ms
    end
  end
  for rel, ms in pairs(per_file) do
    merged[rel] = ms
  end
  local out, n = {}, 0
  local keys = vim.tbl_keys(merged)
  table.sort(keys)
  for _, rel in ipairs(keys) do
    local known = info.known_files == nil or info.known_files[rel]
    if known and n < M.MAX_FILES and #rel <= M.MAX_PATH_BYTES then
      out[rel] = math.floor(merged[rel] * 1000 + 0.5) / 1000
      n = n + 1
    end
  end
  local text, err = require("lib.nvim.json").encode(out)
  if not text then
    return false, "cannot encode the durations: " .. tostring(err)
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

return M
