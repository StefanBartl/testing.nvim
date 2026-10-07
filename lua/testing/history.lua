---@module 'testing.history'
---@brief Run history for `--lf` / `--ff`: `stdpath('state')/testing/<project>/runs.jsonl`.
---@description
--- One JSON line per finished run:
---
---   {"v":1,"run":"<run id>","ts":<unix time>,"seed":<int|absent>,
---    "summary":{"pass":n,...},"failed":["<case id>", ...]}
---
--- `failed` is CUMULATIVE (the way pytest's `lastfailed` works): what failed before and did not run
--- again stays, a case that ran and passed leaves, a file that ran completely forgets the ids it no
--- longer produces (renamed/deleted cases), a file that no longer exists is dropped. So
--- `testing --file a_spec.lua` does not make the failures of `b_spec.lua` disappear from `--lf`.
---
--- The directory name is `<basename>-<12 hex of sha256(project key)>`: derived from the project key
--- of `lib.nvim.fs.project_key` (the git root), never taken from data.
---
--- SECURITY / ROBUSTNESS (SEC-32/33):
---   * the file is UNTRUSTED input when read back: a size cap is applied before decoding, every line is
---     decoded under `pcall` and validated (version, types, id length, no control characters, count
---     caps); a line that fails is dropped and counted in `notes`, a file that is not usable at all
---     is ignored with a note. Nothing from it is ever executed, used as a path or interpolated into a
---     pattern: ids are only compared to the ids of the discovered files and cases;
---   * the file is BOUNDED: at most `MAX_RUNS` lines, `MAX_FAILED` ids per line, `MAX_ID_BYTES` per id,
---     and `MAX_BYTES` in total (the oldest lines go first);
---   * it is rewritten atomically (`lib.nvim.fs.write.atomic`): a crash leaves the old file or the new
---     one, never half of it.
---
--- History is a convenience, not part of the verdict: a failing read or write is reported to the
--- caller, which prints a note and carries on.

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_RUNS = 20
---@type integer
M.MAX_FAILED = 5000
---@type integer
M.MAX_ID_BYTES = 500
---@type integer
M.MAX_BYTES = 1048576

---@class Testing.History.Record
---@field v integer
---@field run string
---@field ts integer
---@field seed? integer
---@field summary table<string, integer>
---@field failed string[]

---Directory of the history of a project.
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.dir(root, opts)
  local base = (opts and opts.state_dir) or vim.fn.stdpath("state")
  local key = require("lib.nvim.fs.project_key")(root)
  local name = (key:match("([^/\\]+)[/\\]*$") or "project"):gsub("[^%w_.%-]", "_")
  return ("%s/testing/%s-%s"):format(base, name, vim.fn.sha256(key):sub(1, 12))
end

---Path of `runs.jsonl`.
---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return M.dir(root, opts) .. "/runs.jsonl"
end

---Validate one decoded line. Returns a normalized record or nil and the reason.
---@param raw any
---@return Testing.History.Record|nil
---@return string|nil why
function M.validate(raw)
  if type(raw) ~= "table" then
    return nil, "not an object"
  end
  if raw.v ~= M.VERSION then
    return nil, "unknown version"
  end
  if type(raw.run) ~= "string" or #raw.run > 100 then
    return nil, "bad run id"
  end
  if type(raw.ts) ~= "number" or raw.ts ~= raw.ts or raw.ts < 0 or raw.ts > 4102444800 then
    return nil, "bad timestamp"
  end
  if type(raw.failed) ~= "table" or #raw.failed > M.MAX_FAILED then
    return nil, "bad failed list"
  end
  local failed, seen = {}, {}
  for i = 1, #raw.failed do
    local id = raw.failed[i]
    -- ids are only ever compared, never printed from here: a control character (a title with a
    -- tab) is legal. A line with anything that is no usable id is a corrupt line, not a run that
    -- failed nothing: `--lf` must not read "no failures" out of it.
    if type(id) ~= "string" or id == "" or #id > M.MAX_ID_BYTES then
      return nil, "bad case id"
    end
    if not seen[id] then
      seen[id] = true
      failed[#failed + 1] = id
    end
  end
  local seed = raw.seed
  if seed ~= nil and (type(seed) ~= "number" or seed ~= math.floor(seed) or seed < 0) then
    seed = nil
  end
  local summary = {}
  if type(raw.summary) == "table" then
    for k, v in pairs(raw.summary) do
      if type(k) == "string" and #k <= 20 and type(v) == "number" then
        summary[k] = v
      end
    end
  end
  return {
    v = M.VERSION,
    run = raw.run,
    ts = raw.ts,
    seed = seed,
    summary = summary,
    failed = failed,
  }
end

---Read the valid records of the file, oldest first.
---@param path string
---@return Testing.History.Record[] records
---@return string[] notes What was dropped or ignored, for the caller to print.
function M.read_records(path)
  local notes = {}
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}, notes
  end
  if stat.type ~= "file" then
    return {}, { ("history %s is not a regular file: ignored"):format(path) }
  end
  if stat.size > M.MAX_BYTES * 2 then
    return {}, { ("history %s is larger than %d bytes: ignored"):format(path, M.MAX_BYTES * 2) }
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return {}, { ("history %s cannot be read: %s"):format(path, tostring(err)) }
  end
  local json = require("lib.nvim.json")
  local records, dropped = {}, 0
  for line in text:gmatch("[^\r\n]+") do
    local ok, decoded = pcall(json.decode, line)
    local rec
    if ok and type(decoded) == "table" then
      rec = M.validate(decoded)
    end
    if rec then
      records[#records + 1] = rec
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    notes[#notes + 1] = ("history %s: %d unusable line(s) ignored"):format(path, dropped)
  end
  return records, notes
end

---@class Testing.History.Loaded
---@field failed string[] Cumulative failed case ids after the last valid run (empty when none).
---@field records integer Number of valid runs read.
---@field notes string[]
---@field path string

---What the last runs remember.
---@param root string
---@param opts? { state_dir?: string }
---@return Testing.History.Loaded
function M.load(root, opts)
  local path = M.path(root, opts)
  local ok, records, notes = pcall(M.read_records, path)
  if not ok then
    return {
      failed = {},
      records = 0,
      notes = { ("history %s cannot be read: %s"):format(path, tostring(records)) },
      path = path,
    }
  end
  local last = records[#records]
  return { failed = last and last.failed or {}, records = #records, notes = notes, path = path }
end

---@class Testing.History.RecordInfo
---@field ran_ids? table<string, true> Ids of the cases that ran (set; derived from the result when absent).
---@field ran_files? table<string, true> Files that ran WITHOUT a case restriction (they forget ids they no longer produce).
---@field known_files? table<string, true> Every discovered file (ids of other files are dropped); nil = keep all.
---@field time? integer Unix time (tests).

---Compute the cumulative failed list after a run.
---@param previous string[]
---@param res Testing.Result
---@param info Testing.History.RecordInfo
---@return string[] failed
---@return integer too_long Failing ids that cannot be remembered (longer than MAX_ID_BYTES).
function M.merge_failed(previous, res, info)
  local ran_ids, now_failed = {}, {}
  local bad = { fail = true, error = true, timeout = true, crash = true, xpass = true }
  for _, c in ipairs(res.cases) do
    ran_ids[c.id] = true
    if bad[c.status] then
      now_failed[#now_failed + 1] = c.id
    end
  end
  for id in pairs(info.ran_ids or {}) do
    ran_ids[id] = true
  end
  local ran_files = info.ran_files or {}
  local known = info.known_files
  local select_mod = require("testing.run.select")
  local out, seen = {}, {}
  local too_long = 0
  ---@param id string
  local function add(id)
    if #id > M.MAX_ID_BYTES then
      too_long = too_long + 1
    elseif not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  for _, id in ipairs(previous) do
    local file = select_mod.file_of_id(id)
    local gone = known ~= nil and not known[file]
    if not (ran_ids[id] or ran_files[file] or gone) then
      add(id)
    end
  end
  for _, id in ipairs(now_failed) do
    add(id)
  end
  while #out > M.MAX_FAILED do
    table.remove(out, 1)
  end
  return out, too_long
end

---Append this run to the history (bounded, atomic).
---@param root string
---@param res Testing.Result
---@param info? Testing.History.RecordInfo
---@param opts? { state_dir?: string }
---@return boolean ok
---@return string|nil err
---@return string|nil note Something that was not remembered (the run is recorded all the same).
function M.record(root, res, info, opts)
  local path = M.path(root, opts)
  local locked, ok, err, note = require("testing.statelock").with(path, function()
    return M.record_locked(path, res, info or {})
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err, note
end

---The read-append-write of `record`, to be called while the lock of `path` is held: the file is read here, so a
---run that finished since this one started keeps its line and its failures.
---@param path string
---@param res Testing.Result
---@param info Testing.History.RecordInfo
---@return boolean ok
---@return string|nil err
---@return string|nil note
function M.record_locked(path, res, info)
  local records = M.read_records(path)
  local last = records[#records]
  local failed, too_long = M.merge_failed(last and last.failed or {}, res, info)
  local summary = {}
  for k, v in pairs(res.summary or {}) do
    summary[k] = v
  end
  records[#records + 1] = {
    v = M.VERSION,
    run = res.run.id,
    ts = info.time or os.time(),
    seed = res.run.seed,
    summary = summary,
    failed = failed,
  }
  while #records > M.MAX_RUNS do
    table.remove(records, 1)
  end
  local json = require("lib.nvim.json")
  local lines = {}
  for _, r in ipairs(records) do
    local enc, err = json.encode(r)
    if not enc then
      return false, "cannot encode the history: " .. tostring(err)
    end
    lines[#lines + 1] = enc
  end
  -- bounded in bytes: the oldest lines go first, the newest always stays
  local text = table.concat(lines, "\n") .. "\n"
  while #text > M.MAX_BYTES and #lines > 1 do
    table.remove(lines, 1)
    text = table.concat(lines, "\n") .. "\n"
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  if too_long > 0 then
    return true,
      nil,
      ("%d failing case id(s) longer than %d bytes cannot be remembered for --lf"):format(
        too_long,
        M.MAX_ID_BYTES
      )
  end
  return true, nil
end

return M
