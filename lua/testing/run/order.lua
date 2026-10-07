---@module 'testing.run.order'
---@brief `--order priority`: the order in which the spec files run. It orders, it never filters.
---@description
--- A red result is only useful when it arrives early, so the files most likely to be red run first:
---
---   1. what failed last time (`runs.jsonl`),
---   2. what was changed itself (git: working tree against `HEAD`, untracked files),
---   3. the specs that reach a changed file through `require`, nearest first (distance 1 = the spec
---      requires the changed module itself),
---   4. what has not run for a long time (or never) according to `order.json`,
---   5. the rest.
---
--- Inside a stage the file that took the least time comes first (an unknown duration after the known
--- ones), then the discovery order. The SET of files is never touched: `priority` returns a permutation
--- of its input (a spec checks that over random inputs), and the Result-IR stays in discovery order
--- (`restore`), so the report does not depend on the order the files ran in. Heuristics order, only
--- proofs skip (the cache does the skipping).
---
--- Every input is optional. Without history, without git or without a usable graph the discovery order
--- is kept and `facts` says so in its notes: never an error.
---
--- `order.json` (beside `runs.jsonl`): `{ "v": 1, "files": { "<rel>": { "ts": <unix>, "ms": <ms> } } }`,
--- what the last execution of each file took and when it ran. Untrusted when read back, bounded, written
--- atomically; a failing read or write is a note.

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_FILES = 5000
---@type integer
M.MAX_BYTES = 1048576
---A file that has not run for this long (seconds) counts as stale: 7 days.
---@type integer
M.STALE_AFTER = 7 * 86400
---Distance given to a spec a change reaches in a way that has no module chain (a process it starts, a path it names).
---@type integer
M.UNKNOWN_DISTANCE = 50

---@class Testing.Order.History
---@field failed? table<string, any> Files with a remembered failure.
---@field last_run? table<string, integer> File -> unix time of the last execution.
---@field ms? table<string, number> File -> duration of the last execution.
---@field known? boolean `last_run` is a measurement (a state file exists): a file missing from it has never run.
---@field now? integer Unix time (default `os.time()`).
---@field stale_after? integer

---@class Testing.Order.Graph
---@field distance? table<string, integer> Spec -> require distance to a changed module (>= 1).

---@class Testing.Order.Info
---@field rank integer Position in the order (1 = first).
---@field stage "red"|"changed"|"near"|"stale"|"rest"
---@field distance? integer
---@field reason string

local STAGES = { "red", "changed", "near", "stale", "rest" }

---The order of the spec files by priority. Pure.
---@param files string[] Spec files (relative), in discovery order.
---@param history? Testing.Order.History
---@param changed? table<string, any> Changed files (a set).
---@param graph? Testing.Order.Graph
---@return string[] ordered A permutation of `files`.
---@return table<string, Testing.Order.Info> info
---@return boolean signal False when nothing told one file from another (the discovery order is kept).
function M.priority(files, history, changed, graph)
  history = history or {}
  changed = changed or {}
  local failed = history.failed or {}
  local last_run = history.last_run or {}
  local ms = history.ms or {}
  local distance = graph and graph.distance or {}
  local now = history.now or os.time()
  local stale_after = history.stale_after or M.STALE_AFTER
  local known = history.known == true

  local rows = {}
  for i, rel in ipairs(files) do
    local stage, sub, reason = 5, 0, "no signal"
    local ran = last_run[rel]
    if failed[rel] then
      stage, reason = 1, "failed last time"
    elseif changed[rel] then
      stage, reason = 2, "changed"
    elseif distance[rel] then
      stage, sub = 3, distance[rel]
      reason = sub >= M.UNKNOWN_DISTANCE and "reached by a change"
        or ("requires a changed file at distance %d"):format(sub)
    elseif known and ran == nil then
      stage, reason = 4, "never run"
    elseif ran ~= nil and now - ran > stale_after then
      stage = 4
      reason = ("not run for %d day(s)"):format(math.floor((now - ran) / 86400))
    end
    local dur = ms[rel]
    rows[i] = {
      rel = rel,
      idx = i,
      stage = stage,
      sub = sub,
      reason = reason,
      known = type(dur) == "number" and 0 or 1,
      dur = type(dur) == "number" and dur or 0,
    }
  end
  table.sort(rows, function(a, b)
    if a.stage ~= b.stage then
      return a.stage < b.stage
    end
    if a.sub ~= b.sub then
      return a.sub < b.sub
    end
    if a.known ~= b.known then
      return a.known < b.known
    end
    if a.dur ~= b.dur then
      return a.dur < b.dur
    end
    return a.idx < b.idx
  end)
  local ordered, info, signal = {}, {}, false
  for rank, r in ipairs(rows) do
    ordered[rank] = r.rel
    info[r.rel] = {
      rank = rank,
      stage = STAGES[r.stage],
      distance = r.stage == 3 and r.sub or nil,
      reason = r.reason,
    }
    if r.stage < 5 then
      signal = true
    end
  end
  if not signal then
    -- nothing to tell the files apart: the durations alone must not shuffle the discovery order
    ordered = vim.list_slice(files, 1, #files)
    for rank, rel in ipairs(ordered) do
      info[rel].rank = rank
    end
  end
  return ordered, info, signal
end

---The require distance in the reason text of the affected heuristic (`reaches a.b <- c.d (x.lua changed)`
---is a chain of two modules: distance 2). nil when the reason names no chain.
---@param reason any
---@return integer|nil
function M.distance_of(reason)
  if type(reason) ~= "string" then
    return nil
  end
  local chain = reason:match("^reaches (.-) %(")
  if not chain then
    return nil
  end
  local n = 1
  for _ in chain:gmatch(" <%- ") do
    n = n + 1
  end
  return n
end

-- =========================================================
-- The state file
-- =========================================================

---@class Testing.Order.StateOpts
---@field state_dir? string Replaces `stdpath('state')` (specs).
---@field time? integer Unix time (specs).
---@field partial? boolean The run measured only part of the cases of a file: durations stay.
---@field known_files? table<string, true> Files that exist; the state forgets the others.

---@param root string
---@param opts? Testing.Order.StateOpts
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/order.json"
end

---@param s any
---@return boolean
local function plain_path(s)
  return type(s) == "string" and s ~= "" and #s <= 300 and not s:find("[%c\127]")
end

---@param root string
---@param opts? Testing.Order.StateOpts
---@return table<string, { ts: integer, ms: number }> files
---@return string|nil note
function M.load_state(root, opts)
  local path = M.path(root, opts)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return {}, nil
  end
  if stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return {}, ("order state %s is not a regular file or too large: ignored"):format(path)
  end
  local text = require("lib.nvim.fs.read")(path)
  local ok, decoded = false, nil
  if text then
    ok, decoded = pcall(require("lib.nvim.json").decode, text)
  end
  if
    not ok
    or type(decoded) ~= "table"
    or decoded.v ~= M.VERSION
    or type(decoded.files) ~= "table"
  then
    return {}, ("order state %s is not usable: ignored"):format(path)
  end
  local files, n = {}, 0
  for rel, e in pairs(decoded.files) do
    n = n + 1
    if n > M.MAX_FILES then
      break
    end
    if
      plain_path(rel)
      and type(e) == "table"
      and type(e.ts) == "number"
      and e.ts >= 0
      and e.ts <= 4102444800
    then
      local ms = type(e.ms) == "number" and e.ms >= 0 and e.ms < 1e10 and e.ms or 0
      files[rel] = { ts = e.ts, ms = ms }
    end
  end
  return files, nil
end

---Remember when each file that really ran was executed and how long it took (a case filter leaves the
---duration alone: it measured part of the file).
---@param root string
---@param res Testing.Result
---@param opts? Testing.Order.StateOpts
---@return boolean ok
---@return string|nil err
function M.record_state(root, res, opts)
  opts = opts or {}
  local path = M.path(root, opts)
  -- the state is read again INSIDE the lock: a second run that wrote since is merged into, not overwritten
  local locked, ok, err = require("testing.statelock").with(path, function()
    return M.record_state_locked(root, res, opts)
  end)
  if not locked then
    return false, tostring(ok)
  end
  return ok, err
end

---The read-merge-write of `record_state`, to be called while the lock of `M.path(root, opts)` is held.
---@param root string
---@param res Testing.Result
---@param opts Testing.Order.StateOpts
---@return boolean ok
---@return string|nil err
function M.record_state_locked(root, res, opts)
  local files = M.load_state(root, opts)
  local sums, ran, hits = {}, {}, {}
  for _, c in ipairs(res.cases or {}) do
    if type(c.file) == "string" then
      if c.cached then
        hits[c.file] = (hits[c.file] or 0) + (tonumber(c.duration_ms) or 0)
      else
        ran[c.file] = true
        sums[c.file] = (sums[c.file] or 0) + (tonumber(c.duration_ms) or 0)
      end
    end
  end
  local now = opts.time or os.time()
  for rel in pairs(ran) do
    local old = files[rel]
    files[rel] = { ts = now, ms = opts.partial and old and old.ms or sums[rel] }
  end
  -- a cache hit is a file whose last green result still holds: it was looked at now, so it must not age into
  -- "not run for 7 days" (stage 4) just because nothing had to execute; the measured duration stays
  for rel, stored_ms in pairs(hits) do
    if not ran[rel] then
      local old = files[rel]
      files[rel] = { ts = now, ms = old and old.ms or stored_ms }
    end
  end
  if opts.known_files then
    for rel in pairs(files) do
      if not opts.known_files[rel] then
        files[rel] = nil
      end
    end
  end
  -- bounded: the entries that ran longest ago go first
  local rels = vim.tbl_keys(files)
  if #rels > M.MAX_FILES then
    table.sort(rels, function(a, b)
      if files[a].ts ~= files[b].ts then
        return files[a].ts > files[b].ts
      end
      return a < b
    end)
    for i = M.MAX_FILES + 1, #rels do
      files[rels[i]] = nil
    end
  end
  local text, err = require("lib.nvim.json").encode({ v = M.VERSION, files = files })
  if not text then
    return false, "cannot encode the order state: " .. tostring(err)
  end
  local ok, werr =
    require("lib.nvim.fs.write.atomic")(M.path(root, opts), text .. "\n", { mkdirp = true })
  if not ok then
    return false, ("cannot write the order state: %s"):format(tostring(werr))
  end
  return true, nil
end

-- =========================================================
-- Facts and the report order
-- =========================================================

---@class Testing.Order.FactsOpts
---@field root string
---@field specs string[] Every spec file of the project (the graph is asked about all of them).
---@field roots? string[] Spec roots (`.testing.lua` `roots`).
---@field state_dir? string
---@field now? integer
---@field affected? table Replaces `testing.affected` (specs).
---@field select_over? table Seams of the affected selection (`getenv`, `run`, `provider`, `cache_dir`).
---@field no_cache? boolean

---Gather what `priority` needs. Never raises: whatever cannot be read becomes a note and an empty input.
---@param o Testing.Order.FactsOpts
---@return Testing.Order.History history
---@return table<string, true> changed
---@return Testing.Order.Graph graph
---@return string[] notes
function M.facts(o)
  local notes = {}
  local history = { failed = {}, last_run = {}, ms = {}, known = false, now = o.now }

  local hok, hist = pcall(require("testing.history").load, o.root, { state_dir = o.state_dir })
  if hok then
    for _, n in ipairs(hist.notes) do
      notes[#notes + 1] = n
    end
    for rel in pairs(require("testing.run.select").group_failed(hist.failed)) do
      history.failed[rel] = true
    end
  else
    notes[#notes + 1] = "history cannot be read: " .. tostring(hist)
  end
  local state, snote = M.load_state(o.root, { state_dir = o.state_dir })
  if snote then
    notes[#notes + 1] = snote
  end
  for rel, e in pairs(state) do
    history.last_run[rel] = e.ts
    history.ms[rel] = e.ms
  end
  history.known = next(state) ~= nil

  local changed, graph = {}, { distance = {} }
  local over = o.select_over or {}
  local sok, sel = pcall((o.affected or require("testing.affected")).select, {
    root = o.root,
    specs = o.specs,
    mode = "changed",
    roots = o.roots,
    implicit = false,
    getenv = over.getenv,
    run = over.run,
    provider = over.provider,
    no_cache = o.no_cache,
    cache_dir = over.cache_dir,
  })
  if not sok then
    notes[#notes + 1] = "the changes cannot be looked at: " .. tostring(sel)
  elseif sel.source == "none" and sel.all then
    notes[#notes + 1] = ("no diff proximity: %s"):format(tostring(sel.all_reason))
  else
    for _, rel in ipairs(sel.changed or {}) do
      changed[rel] = true
    end
    for rel, reason in pairs(sel.reason or {}) do
      if not sel.all then
        graph.distance[rel] = M.distance_of(reason) or M.UNKNOWN_DISTANCE
      end
    end
  end
  return history, changed, graph, notes
end

---Put the cases back in discovery order (stable inside a file), so the IR does not depend on the order the
---files ran in.
---@param res Testing.Result
---@param discovery string[] The files in discovery order.
function M.restore(res, discovery)
  local at = {}
  for i, rel in ipairs(discovery) do
    at[rel] = i
  end
  local rows = {}
  for i, c in ipairs(res.cases or {}) do
    rows[i] = { c = c, file = at[c.file] or (#discovery + 1), idx = i }
  end
  table.sort(rows, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.idx < b.idx
  end)
  for i, r in ipairs(rows) do
    res.cases[i] = r.c
  end
end

return M
