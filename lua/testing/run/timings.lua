---@module 'testing.run.timings'
---@brief The last durations of every spec file, and the warning when a file takes three times its median.
---@description
--- `timings.json` lives beside `runs.jsonl` and `durations.json`:
---
---   { "v": 1, "files": { "<spec path>": [ms, ms, ...] } }
---
--- up to `M.SAMPLES` of the last COMPLETE runs per file (oldest first). `durations.json` (for `--shard`) keeps
--- ONE number per file; a regression needs a median, so this is the list. A file that came from the result cache
--- is never a sample (its duration is that of an older run), and a run that stopped or filtered cases is not
--- recorded at all (the caller decides: `testing.cli`).
---
--- A file is REGRESSED when it took more than `M.FACTOR` times the median of at least `M.MIN_RUNS` earlier runs
--- and at least `M.MIN_DELTA_MS` more than that median (a file that went from 2 ms to 9 ms is noise, not news).
--- A regression is a warning on stderr and a line for the agent report, never a failure: the machine can be busy.
---
--- UNTRUSTED when read back (like `runs.jsonl`): a size cap before decoding, a decode under `pcall`, every entry
--- validated (path length and characters, sample count and range), at most `M.MAX_FILES` files; whatever fails
--- is dropped and counted. Written atomically. A failing read or write is a note, never the verdict.

local M = {}

---@type integer
M.VERSION = 1
---Samples kept per file.
---@type integer
M.SAMPLES = 9
---Files kept.
---@type integer
M.MAX_FILES = 5000
---Largest accepted `timings.json` in bytes.
---@type integer
M.MAX_BYTES = 1048576
---Longest path kept.
---@type integer
M.MAX_PATH_BYTES = 500
---A file regressed when it took more than this many times its median ...
---@type number
M.FACTOR = 3
---... of at least this many earlier runs ...
---@type integer
M.MIN_RUNS = 3
---... and at least this many milliseconds more than the median.
---@type number
M.MIN_DELTA_MS = 100

---Path of `timings.json` of a project.
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/timings.json"
end

---@param ms any
---@return boolean
local function sample(ms)
  return type(ms) == "number" and ms == ms and ms >= 0 and ms < 86400000
end

---Validate a decoded `{ v, files }` object; never raises.
---@param raw any
---@return table<string, number[]> files
---@return integer dropped Entries that were not usable.
function M.validate(raw)
  local out, dropped, n = {}, 0, 0
  if type(raw) ~= "table" or raw.v ~= M.VERSION or type(raw.files) ~= "table" then
    return out, 1
  end
  for rel, list in pairs(raw.files) do
    local ok = type(rel) == "string"
      and rel ~= ""
      and #rel <= M.MAX_PATH_BYTES
      and not rel:find("%c")
      and type(list) == "table"
      and #list >= 1
      and #list <= M.SAMPLES
      and n < M.MAX_FILES
    local clean = {}
    if ok then
      local count = 0
      for _ in pairs(list) do
        count = count + 1
      end
      ok = count == #list
      for _, ms in ipairs(list) do
        ok = ok and sample(ms)
        clean[#clean + 1] = ms
      end
    end
    if ok then
      out[rel] = clean
      n = n + 1
    else
      dropped = dropped + 1
    end
  end
  return out, dropped
end

---Read `timings.json`.
---@param path string
---@return table<string, number[]> files Empty when there is none or it is unusable.
---@return string|nil note
function M.read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}, nil
  end
  if stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return {},
      ("timings file %s is not a regular file or larger than %d bytes: ignored"):format(
        path,
        M.MAX_BYTES
      )
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return {}, ("timings file %s cannot be read: %s"):format(path, tostring(err))
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok or decoded == nil then
    return {}, ("timings file %s is not valid JSON: ignored"):format(path)
  end
  local files, dropped = M.validate(decoded)
  if dropped > 0 then
    return files, ("timings file %s: %d unusable entr(y/ies) ignored"):format(path, dropped)
  end
  return files, nil
end

---The median of a list of numbers.
---@param list number[]
---@return number|nil
function M.median(list)
  if #list == 0 then
    return nil
  end
  local copy = vim.list_slice(list, 1)
  table.sort(copy)
  local mid = #copy / 2
  if #copy % 2 == 1 then
    return copy[math.ceil(mid)]
  end
  return (copy[mid] + copy[mid + 1]) / 2
end

---What each file of a run took: the sum of the durations of the cases it ran in this run. A cached case was
---not run, so a file that has one is left out (its duration would be that of an older run).
---@param res Testing.Result
---@return table<string, number>
function M.per_file(res)
  local sum, skip = {}, {}
  for _, c in ipairs(res.cases or {}) do
    if type(c.file) == "string" and type(c.duration_ms) == "number" then
      if c.cached then
        skip[c.file] = true
      end
      sum[c.file] = (sum[c.file] or 0) + c.duration_ms
    end
  end
  for rel in pairs(skip) do
    sum[rel] = nil
  end
  return sum
end

---@class Testing.Timings.Regression
---@field file string
---@field ms number
---@field median number
---@field runs integer Earlier runs the median is made of.

---The files of a run that took more than `FACTOR` times their median.
---@param history table<string, number[]> What `read` returned (the earlier runs).
---@param current table<string, number> What `per_file` returned.
---@return Testing.Timings.Regression[]
function M.regressions(history, current)
  local out = {}
  for rel, ms in pairs(current) do
    local past = history[rel]
    if past and #past >= M.MIN_RUNS then
      local median = M.median(past) --[[@as number]]
      if ms > M.FACTOR * median and ms - median >= M.MIN_DELTA_MS then
        out[#out + 1] = { file = rel, ms = ms, median = median, runs = #past }
      end
    end
  end
  table.sort(out, function(a, b)
    return a.ms - a.median > b.ms - b.median
  end)
  return out
end

---One warning line per regression (a file name comes from the project: the caller prints plain text).
---@param r Testing.Timings.Regression
---@return string
function M.line(r)
  return ("%s took %.1f s, %.1fx its median of %.1f s over %d run(s)"):format(
    r.file,
    r.ms / 1000,
    r.ms / r.median,
    r.median / 1000,
    r.runs
  )
end

---Add this run to the history of every file in `current` (bounded), and drop the files that no longer exist.
---The file is read AGAIN under the lock of `testing.statelock` and merged into: a second run that wrote since
---`history` was read keeps its samples (`history` is only the fallback when the file has none).
---@param root string
---@param history table<string, number[]> What `read` returned.
---@param current table<string, number>
---@param opts? { state_dir?: string, known_files?: table<string, true> }
---@return boolean ok
---@return string|nil err
function M.record(root, history, current, opts)
  opts = opts or {}
  local path = M.path(root, opts)
  local locked, ok, err = require("testing.statelock").with(path, function()
    return M.record_locked(path, history, current, opts)
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err
end

---The read-merge-write of `record`, to be called while the lock of `path` is held.
---@param path string
---@param history table<string, number[]>
---@param current table<string, number>
---@param opts { known_files?: table<string, true> }
---@return boolean ok
---@return string|nil err
function M.record_locked(path, history, current, opts)
  local merged = {}
  local fresh = M.read(path)
  if next(fresh) ~= nil then
    history = fresh
  end
  for rel, list in pairs(history) do
    merged[rel] = vim.list_slice(list, 1)
  end
  for rel, ms in pairs(current) do
    local list = merged[rel] or {}
    list[#list + 1] = math.floor(ms * 1000 + 0.5) / 1000
    while #list > M.SAMPLES do
      table.remove(list, 1)
    end
    merged[rel] = list
  end
  local keys = vim.tbl_keys(merged)
  table.sort(keys)
  local files, n = {}, 0
  for _, rel in ipairs(keys) do
    local known = opts.known_files == nil or opts.known_files[rel]
    if known and n < M.MAX_FILES and #rel <= M.MAX_PATH_BYTES and not rel:find("%c") then
      files[rel] = merged[rel]
      n = n + 1
    end
  end
  local text, err = require("lib.nvim.json").encode({ v = M.VERSION, files = files })
  if not text then
    return false, "cannot encode the timings: " .. tostring(err)
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

return M
