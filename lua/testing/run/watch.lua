---@module 'testing.run.watch'
---@brief `--watch`: run, then re-run the affected spec files whenever something changes.
---@description
--- Two parts. The LOOP (`M.new`) is plain Lua over seams: a clock, a file-system source, a scanner, a
--- runner and a selection function. Specs drive it with fake events and a fake clock, no editor needed.
--- The GLUE (`M.run_cli`) builds the real seams from a project plan and runs the loop in this editor.
---
--- HOW A CHANGE BECOMES A RUN
---   1. The source (`fs_event` handles, or polling) only says "something changed": `W:event()` sets a flag
---      and a timestamp and bumps the generation counter (ERR-32: state versions, not timers, decide). It
---      runs in a luv callback and touches no editor API.
---   2. The main loop waits for quiet: when `debounce_ms` have passed since the LAST event (or, with
---      `max_wait_ms`, since the FIRST pending one: the cooldown that keeps a run coming while someone saves
---      all the time) and no run is active, a cycle starts. A cycle first takes a snapshot of the watched trees (path ->
---      `mtime:size`) and diffs it with the previous one, so a burst of events whose file names the
---      debounce kept only the last of still yields every changed path, and noise (an event with no
---      content change, a poll tick) yields no run at all.
---   3. What runs: changed spec files; for every other changed file (a module below `lua/`, a helper below
---      the spec root) the affected specs, from `testing.affected.select` when that module exists, else
---      ALL specs with a note (a lib change never silently runs nothing); plus the files that failed in
---      the last run. Failed files go FIRST. An empty result (only deleted files) runs nothing.
---   4. Events during a run are not lost: they set the flag again and start the next cycle when the run is
---      over; the status line says so.
---
--- STATUS LINES (to the out sink, one per fact): what is watched and how (`events` or `poll`), what
--- changed and what runs, how a run ended, and that it waits. The wait is silent.
---
--- EXIT. Ctrl-C (a luv `sigint` handle, plus `vim.wait` being interrupted) ends the loop cleanly: the
--- source is closed, the children that are still alive are killed with their process trees
--- (`testing.child.kill_all`, which covers pool members too), and the exit code is the one of the last
--- COMPLETED run (0 when none ran). A run that Ctrl-C cut short does not replace it.
---
--- PLATFORMS
---   * Windows and macOS: libuv watches a directory tree with one recursive handle. Linux: inotify is not
---     recursive, so one handle per directory is started and the set is refreshed after every cycle (a
---     directory created later is picked up then);
---   * a handle that cannot be started (`ENOENT`, `ENOSPC` = inotify watches exhausted, `EMFILE`) is NOT
---     a reason to run blind: the whole watcher falls back to POLLING (every `poll_ms`, default 1000) and
---     says so. `--watch-poll` asks for it up front (network drives, containers, exhausted watchers);
---   * closing an `fs_event` handle is asynchronous in libuv (ERR-40: Windows holds the directory until the
---     close callback ran), so `stop()` closes first and then lets the loop turn once (`vim.wait(20)`)
---     before the process goes on or exits;
---   * the quirks are in the source, the loop does not know them.
---
--- IN-PROCESS RUNS see a project whose modules were loaded by the previous run: `M.run_cli` forgets every
--- module that was not loaded before the first run (except `testing*`, `lib.nvim*`, `lib.lua*`) so an edit
--- to a plugin module is visible in the next in-process run. Child editors (`--isolated file`) start
--- fresh anyway.

local M = {}

---Quiet time before a run starts (ms) when nothing else is configured.
M.DEFAULT_DEBOUNCE_MS = 150
---Polling interval (ms) of the fallback source.
M.DEFAULT_POLL_MS = 1000
---Directory names the scanner and the watchers never enter.
M.IGNORE_DIRS = { ".git", ".deps", ".repro", "node_modules", ".cache" }
---Most changed paths named in a status line.
M.MAX_NAMED = 5

---A file that changes during this many runs in a row is taken to be written BY the run (a spec that writes a Lua
---file below a watched root) and is ignored from then on: otherwise every run would start the next one.
M.SELF_WRITE_LIMIT = 3

---Exit code of a watcher that was ended before any run completed (Ctrl-C in the first run): an aborted run is
---never a green exit.
M.EXIT_NO_RUN = 3

---@class Testing.Watch.RunResult
---@field exit_code integer The exit code of the run (0 green, 1 red, 2 nothing to run, 3 infrastructure).
---@field failed? table<string, true> Files that are red after the run (rel); nil = derive nothing.
---@field interrupted? boolean The run was cut short by Ctrl-C.

---@class Testing.Watch.Source
---@field stop fun()
---@field mode "events"|"poll"
---@field resync? fun() Re-read the directory set (non-recursive platforms).

---@class Testing.Watch.Opts
---@field root string Absolute project root (no trailing slash).
---@field clock? fun(): number Milliseconds (default `vim.uv.hrtime() / 1e6`).
---@field debounce_ms? integer
---@field max_wait_ms? integer Longest a pending change waits (0/nil = off): a run starts after this long even if files keep changing.
---@field event? fun(kind: string, fields: table) Machine-readable events (`--events`): `watch_change` with every changed file (the seam caps the list), only when a run follows. Errors are contained.
---@field say fun(line: string)
---@field scan fun(): table<string, string> Snapshot of the watched trees: absolute path -> `mtime:size`.
---@field source fun(on_event: fun(), opts: table): Testing.Watch.Source|nil, string|nil
---@field poll_source? fun(on_event: fun(), opts: table): Testing.Watch.Source
---@field poll? boolean Start with the polling source.
---@field poll_ms? integer
---@field is_spec fun(rel: string): boolean
---@field exists? fun(rel: string): boolean Default: the file exists below `root`.
---@field select? fun(changed: string[]): string[]|nil, string|nil Affected specs of the changed non-spec files; nil = unknown (all specs run).
---@field run fun(files: string[]|nil, ctx: Testing.Watch.RunCtx): Testing.Watch.RunResult Runs `files` (nil = every spec).
---@field wait? fun(ms: number, cond: fun(): boolean): boolean|nil, integer|nil `vim.wait` (default).
---@field kill_children? fun() Kills what is still running (default `testing.child.kill_all`).
---@field dirs? string[] Only for the status line.

---@class Testing.Watch.RunCtx
---@field first boolean The initial run.
---@field n integer Number of this run (1-based).
---@field failed_first string[] Files that failed before (they are first in `files`).

---@class Testing.Watch
---@field opts Testing.Watch.Opts
---@field gen integer Generation counter: bumped by every event.
---@field dirty boolean
---@field last_event number Clock reading of the last event.
---@field first_event? number Clock reading of the first event since the last cycle (nil = nothing pending).
---@field running boolean
---@field stopped boolean
---@field runs integer
---@field last_exit integer Exit code of the last completed run.
---@field completed integer Runs that completed (an interrupted run does not count).
---@field writes table<string, integer> Path -> runs in a row during which it changed.
---@field ignored table<string, true> Paths that changed during `SELF_WRITE_LIMIT` runs in a row.
---@field failed table<string, true>
---@field snapshot table<string, string>
---@field src? Testing.Watch.Source
local Watch = {}
Watch.__index = Watch

---@param opts Testing.Watch.Opts
---@return Testing.Watch
function M.new(opts)
  local clock = opts.clock or function()
    return vim.uv.hrtime() / 1e6
  end
  opts.clock = clock
  opts.debounce_ms = opts.debounce_ms or M.DEFAULT_DEBOUNCE_MS
  return setmetatable({
    opts = opts,
    gen = 0,
    dirty = false,
    last_event = 0,
    running = false,
    stopped = false,
    runs = 0,
    last_exit = 0,
    completed = 0,
    writes = {},
    ignored = {},
    failed = {},
    snapshot = {},
  }, Watch)
end

---A change was seen (called by the source). Safe in a luv callback: no editor API.
function Watch:event()
  self.gen = self.gen + 1
  local now = self.opts.clock()
  if not self.dirty then
    self.first_event = now
  end
  self.dirty = true
  self.last_event = now
end

---Has the quiet time passed for a pending change?
---@param now? number
---@return boolean
function Watch:due(now)
  if self.stopped or self.running or not self.dirty then
    return false
  end
  now = now or self.opts.clock()
  if now - self.last_event >= self.opts.debounce_ms then
    return true
  end
  -- the cooldown: a debounce alone never fires while someone keeps saving
  local max_wait = self.opts.max_wait_ms
  if max_wait == nil or max_wait <= 0 or self.first_event == nil then
    return false
  end
  -- a cooldown shorter than the debounce would switch the debounce off: it is the longest wait, never the shortest
  return now - self.first_event >= math.max(max_wait, self.opts.debounce_ms)
end

---Paths whose signature differs between two snapshots (added, changed, removed), sorted.
---@param old table<string, string>
---@param new table<string, string>
---@return string[]
function M.diff(old, new)
  local out = {}
  for path, sig in pairs(new) do
    if old[path] ~= sig then
      out[#out + 1] = path
    end
  end
  for path in pairs(old) do
    if new[path] == nil then
      out[#out + 1] = path
    end
  end
  table.sort(out)
  return out
end

---Project-relative form of an absolute path (`/` separators, case-insensitive prefix on Windows).
---@param root string
---@param path string
---@return string
function M.rel_of(root, path)
  local r = root:gsub("\\", "/"):gsub("/+$", "")
  local p = path:gsub("\\", "/")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    return p:sub(#r + 2)
  end
  return p
end

---@param list string[]
---@return string
local function named(list)
  local shown = {}
  for i = 1, math.min(#list, M.MAX_NAMED) do
    shown[i] = list[i]
  end
  local text = table.concat(shown, ", ")
  if #list > #shown then
    text = text .. (", ... (%d more)"):format(#list - #shown)
  end
  return text
end

---@return string[]
function Watch:failed_list()
  local list = vim.tbl_keys(self.failed)
  table.sort(list)
  return list
end

---Order `files` so that the ones that failed last time come first (stable inside both groups).
---@param files string[]
---@param failed table<string, true>
---@return string[]
function M.failed_first(files, failed)
  local first, rest = {}, {}
  for _, f in ipairs(files) do
    if failed[f] then
      first[#first + 1] = f
    else
      rest[#rest + 1] = f
    end
  end
  return vim.list_extend(first, rest)
end

---Decide what a set of changed files runs.
---@param changed string[] Absolute paths.
---@return string[]|nil files nil = every spec
---@return string|nil note
function Watch:plan(changed)
  local o = self.opts
  local exists = o.exists
    or function(rel)
      return vim.uv.fs_stat(o.root .. "/" .. rel) ~= nil
    end
  local specs, others, seen = {}, {}, {}
  for _, path in ipairs(changed) do
    local rel = M.rel_of(o.root, path)
    if o.is_spec(rel) then
      if exists(rel) and not seen[rel] then
        seen[rel] = true
        specs[#specs + 1] = rel
      end
    elseif rel:sub(-4) == ".lua" then
      others[#others + 1] = rel
    end
  end

  local files, note = specs, nil
  if #others > 0 then
    local picked, why
    if o.select then
      local ok, a, b = pcall(o.select, others)
      if ok then
        picked, why = a, b
      else
        why = tostring(a)
      end
    else
      why = "no affected-module: every spec runs"
    end
    if picked == nil then
      return nil,
        ("%s changed: %s"):format(
          named(others),
          why or "the affected specs are unknown, every spec runs"
        )
    end
    for _, rel in ipairs(picked) do
      if not seen[rel] and exists(rel) then
        seen[rel] = true
        files[#files + 1] = rel
      end
    end
  end
  -- what failed last time runs again, first
  for rel in pairs(self.failed) do
    if not seen[rel] and exists(rel) then
      seen[rel] = true
      files[#files + 1] = rel
    end
  end
  table.sort(files)
  return M.failed_first(files, self.failed), note
end

---Run once with `files` (nil = everything) and fold the outcome into the state.
---@param files string[]|nil
---@param first boolean
---@return Testing.Watch.RunResult
function Watch:execute(files, first)
  local o = self.opts
  self.running = true
  self.runs = self.runs + 1
  local ctx = { first = first, n = self.runs, failed_first = self:failed_list() }
  local ok, res = pcall(o.run, files, ctx)
  self.running = false
  if not ok then
    o.say(("watch: the run raised: %s"):format(tostring(res)))
    res = { exit_code = 3 }
  end
  if not res.interrupted then
    self.last_exit = res.exit_code
    self.completed = self.completed + 1
    if files == nil then
      self.failed = {}
    else
      for _, f in ipairs(files) do
        self.failed[f] = nil
      end
    end
    for f in pairs(res.failed or {}) do
      self.failed[f] = true
    end
  end
  return res
end

---Find the files that changed while the run was going and ignore the ones that do so run after run: a spec that
---writes a Lua file below a watched root would otherwise re-trigger the watcher for ever. A person who saves the
---same file during three runs in a row is taken for such a writer too (the status line names the file; ending and
---restarting the watcher watches it again).
---@param before table<string, string> The snapshot the run started from.
function Watch:track_writes(before)
  local o = self.opts
  local ok, after = pcall(o.scan)
  if not ok or type(after) ~= "table" then
    return
  end
  local now = {}
  for _, path in ipairs(M.diff(before, after)) do
    now[path] = true
    local n = (self.writes[path] or 0) + 1
    self.writes[path] = n
    if n >= M.SELF_WRITE_LIMIT and not self.ignored[path] then
      self.ignored[path] = true
      o.say(
        ("watch: %s changed during %d runs in a row (written by a spec?); ignored from now on"):format(
          M.rel_of(o.root, path),
          n
        )
      )
    end
  end
  for path in pairs(self.writes) do
    if not now[path] then
      self.writes[path] = nil
    end
  end
end

---One cycle: diff the trees, decide, run. Returns true when something ran.
---@return boolean ran
function Watch:cycle()
  local o = self.opts
  self.dirty = false
  self.first_event = nil
  local gen_at_start = self.gen
  local new = o.scan()
  local changed = M.diff(self.snapshot, new)
  self.snapshot = new
  if next(self.ignored) ~= nil then
    changed = vim.tbl_filter(function(p)
      return not self.ignored[p]
    end, changed)
  end
  if self.src and self.src.resync then
    pcall(self.src.resync)
  end
  if #changed == 0 then
    return false
  end
  local rels = {}
  for i, p in ipairs(changed) do
    rels[i] = M.rel_of(o.root, p)
  end
  local files, note = self:plan(changed)
  if files ~= nil and #files == 0 then
    o.say(("watch: %s changed: nothing to run"):format(named(rels)))
    return false
  end
  -- only when a run follows: a consumer pairs every `watch_change` with the `run_start` that comes next
  if o.event then
    pcall(o.event, "watch_change", { files = rels, count = #rels })
  end
  o.say(
    ("watch: %d change(s) (%s) -> running %s%s"):format(
      #changed,
      named(rels),
      files and ("%d file(s)"):format(#files) or "every spec",
      note and (" [" .. note .. "]") or ""
    )
  )
  local res = self:execute(files, false)
  if not res.interrupted then
    self:track_writes(new)
  end
  local bad = self:failed_list()
  o.say(
    ("watch: run %d finished (exit %d%s). %s"):format(
      self.runs,
      res.exit_code,
      #bad > 0 and (", failing: " .. named(bad)) or "",
      self.gen ~= gen_at_start and "Files changed during the run; running again."
        or "Waiting for changes (Ctrl-C quits)."
    )
  )
  return true
end

---Start the source and the first full run.
function Watch:start()
  local o = self.opts
  self.snapshot = o.scan()
  local function on_event()
    self:event()
  end
  local src, err
  if not o.poll then
    src, err = o.source(on_event, { dirs = o.dirs })
  end
  if not src then
    local poll = o.poll_source or function(cb, popts)
      return M.poll_source(cb, popts)
    end
    src = poll(on_event, { interval_ms = o.poll_ms or M.DEFAULT_POLL_MS, scan = o.scan })
    if err then
      o.say(("watch: fs events are not available (%s); polling instead"):format(tostring(err)))
    end
  end
  self.src = src
  o.say(
    ("watching %s (%s, debounce %d ms). Ctrl-C quits."):format(
      o.dirs and #o.dirs > 0 and table.concat(o.dirs, ", ") or o.root,
      src.mode == "poll" and ("polling every %d ms"):format(o.poll_ms or M.DEFAULT_POLL_MS)
        or "fs events",
      o.debounce_ms
    )
  )
  local before = self.snapshot
  local res = self:execute(nil, true)
  if not res.interrupted then
    self:track_writes(before)
  end
  local bad = self:failed_list()
  o.say(
    ("watch: run 1 finished (exit %d%s). Waiting for changes (Ctrl-C quits)."):format(
      res.exit_code,
      #bad > 0 and (", failing: " .. named(bad)) or ""
    )
  )
end

---Ask the loop to end (Ctrl-C). Safe in a luv callback.
function Watch:interrupt()
  self.stopped = true
end

---Close the source, kill what still runs, let libuv finish closing handles (ERR-40).
---@return integer exit_code The exit code of the last completed run.
function Watch:stop()
  local o = self.opts
  self.stopped = true
  if self.src then
    pcall(self.src.stop)
    self.src = nil
  end
  local kill = o.kill_children
    or function()
      pcall(function()
        require("testing.child").kill_all()
      end)
    end
  pcall(kill)
  local wait = o.wait or vim.wait
  pcall(wait, 20)
  if self.completed == 0 then
    return M.EXIT_NO_RUN
  end
  return self.last_exit
end

---`stop` plus the closing status line; the exit code of the last completed run.
---@return integer exit_code
function Watch:stop_and_say()
  local code = self:stop()
  self.opts.say(
    self.completed == 0 and ("watch: stopped before a run completed; exit code %d"):format(code)
      or ("watch: stopped; exit code %d (the last completed run)"):format(code)
  )
  return code
end

---Run the loop until `interrupt`/Ctrl-C. Returns the exit code of the last completed run.
---@return integer exit_code
function Watch:loop()
  local o = self.opts
  local wait = o.wait or vim.wait
  self:start()
  local slice = math.max(10, math.min(50, math.floor(o.debounce_ms / 2)))
  while not self.stopped do
    local ok, _, status = pcall(wait, slice, function()
      return self.stopped or self:due()
    end)
    -- `vim.wait` answers `nil, -2` when the user interrupts it
    if ok and status == -2 then
      self.stopped = true
    end
    if not self.stopped and self:due() then
      self:cycle()
    end
  end
  return self:stop_and_say()
end

-- =========================================================
-- Sources
-- =========================================================

---Does libuv watch a tree recursively with ONE handle on this platform?
---@return boolean
function M.recursive_native()
  local sys = vim.uv.os_uname().sysname
  return sys == "Windows_NT" or sys == "Darwin"
end

---@param name string
---@return boolean
local function ignored_dir(name)
  for _, d in ipairs(M.IGNORE_DIRS) do
    if name == d then
      return true
    end
  end
  return false
end

---Directories below (and including) `dir` that are worth a handle (no VCS, no dependency checkouts).
---@param dir string
---@return string[]
function M.dirs_below(dir)
  local out = { dir }
  local collect = require("lib.nvim.fs.collect_recursive")
  local sub = collect.dirs(dir, {
    ignore = function(path, is_dir)
      return is_dir and ignored_dir(path:match("([^/\\]+)$") or "")
    end,
  })
  for _, d in ipairs(sub) do
    out[#out + 1] = d
  end
  return out
end

---The real source: `lib.nvim.fs.watch` handles on the given directories.
---@param on_event fun()
---@param opts { dirs: string[], flat_dirs?: string[], watch?: table, recursive?: boolean, resolve_dirs?: fun(dir: string): string[] } `flat_dirs` are watched without their subtrees (the project root: `.testing.lua`).
---@return Testing.Watch.Source|nil source
---@return string|nil err
function M.fs_source(on_event, opts)
  local fswatch = opts.watch or require("lib.nvim.fs.watch")
  local recursive = opts.recursive
  if recursive == nil then
    recursive = M.recursive_native()
  end
  ---@type table<string, { stop: fun() }>
  local handles = {}

  local function stop_all()
    for path, h in pairs(handles) do
      pcall(h.stop)
      handles[path] = nil
    end
  end

  ---@param path string
  ---@param flat? boolean Do not watch the subtree.
  ---@return string|nil err
  local function add(path, flat)
    if handles[path] then
      return nil
    end
    -- a short debounce of its own: the loop debounces for real; this only merges the burst of one save
    local h, err = fswatch.start(path, function()
      on_event()
    end, { recursive = recursive and not flat, debounce_ms = 10 })
    if not h then
      return err or "fs_event start failed"
    end
    handles[path] = h
    return nil
  end

  local function wanted()
    local list = {}
    for _, dir in ipairs(opts.dirs or {}) do
      if recursive then
        list[#list + 1] = dir
      else
        vim.list_extend(list, (opts.resolve_dirs or M.dirs_below)(dir))
      end
    end
    return list
  end

  for _, path in ipairs(wanted()) do
    local err = add(path)
    if err then
      stop_all()
      return nil, err
    end
  end
  for _, path in ipairs(opts.flat_dirs or {}) do
    local err = add(path, true)
    if err then
      stop_all()
      return nil, err
    end
  end

  return {
    mode = "events",
    stop = stop_all,
    resync = function()
      if recursive then
        return
      end
      local want = {}
      for _, path in ipairs(wanted()) do
        want[path] = true
        add(path) -- a directory that appeared; a failure here only costs events of that one directory
      end
      for _, path in ipairs(opts.flat_dirs or {}) do
        want[path] = true
      end
      for path, h in pairs(handles) do
        if not want[path] then
          pcall(h.stop)
          handles[path] = nil
        end
      end
    end,
  }
end

---The fallback source: a timer that looks at the trees every `interval_ms` and says "something changed" when
---a snapshot differs from the one before (`opts.scan`; without it every tick is an event and the loop's own
---diff sorts it out). It reads the file system with libuv calls only, which is allowed in a timer callback.
---@param on_event fun()
---@param opts { interval_ms: integer, scan?: fun(): table<string, string> }
---@return Testing.Watch.Source
function M.poll_source(on_event, opts)
  local timer = vim.uv.new_timer()
  local last = opts.scan and opts.scan() or nil
  if timer then
    timer:start(opts.interval_ms, opts.interval_ms, function()
      if opts.scan then
        -- only a real difference counts as an event: a poll interval shorter than the debounce must not
        -- keep moving the quiet time forever
        local now = opts.scan()
        if
          #M.diff(last --[[@as table]], now) == 0
        then
          return
        end
        last = now
      end
      on_event()
    end)
  end
  return {
    mode = "poll",
    stop = function()
      if timer then
        pcall(timer.stop, timer)
        if not timer:is_closing() then
          pcall(timer.close, timer)
        end
        timer = nil
      end
    end,
  }
end

---Most files one snapshot holds (a fixture tree that big is not what a watcher is for).
---@type integer
M.MAX_SNAPSHOT = 20000

---Snapshot of the files below `dirs`: absolute path -> `<mtime sec>.<nsec>:<size>`. By default only the
---`.lua` files; with `opts.all` every file (a fixture a spec reads, a data file) and with `opts.files` those
---single files as well (`.testing.lua`).
---@param dirs string[]
---@param opts? { all?: boolean, files?: string[] }
---@return table<string, string>
function M.scan_dirs(dirs, opts)
  opts = opts or {}
  local collect = require("lib.nvim.fs.collect_recursive")
  local snap = {}
  local count = 0
  for _, path in ipairs(opts.files or {}) do
    local st = vim.uv.fs_stat(path)
    if st then
      snap[path:gsub("\\", "/")] = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
    end
  end
  for _, dir in ipairs(dirs) do
    local files = collect.files(dir, {
      ignore = function(path, is_dir)
        return is_dir and ignored_dir(path:match("([^/\\]+)$") or "")
      end,
    })
    for _, path in ipairs(files) do
      if opts.all or path:sub(-4) == ".lua" then
        local st = vim.uv.fs_stat(path)
        if st then
          count = count + 1
          if count > M.MAX_SNAPSHOT then
            return snap
          end
          snap[path:gsub("\\", "/")] = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
        end
      end
    end
  end
  return snap
end

---Ctrl-C: a luv `sigint` handle that interrupts the watcher and ends what is running. Returns the
---function that removes the handle again (nil when libuv cannot make one: the interrupted `vim.wait`
---still ends the loop between runs).
---@param w Testing.Watch
---@return fun()|nil remove
function M.install_sigint(w)
  local sig = vim.uv.new_signal()
  if not sig then
    return nil
  end
  local ok = pcall(function()
    (sig --[[@as any]]):start("sigint", function()
      w:interrupt()
      -- a luv callback cannot start processes (taskkill) itself: the kill runs on the main loop
      vim.schedule(function()
        local kill = w.opts.kill_children
        if kill then
          pcall(kill)
        else
          pcall(function()
            require("testing.child").kill_all()
          end)
        end
      end)
    end)
  end)
  if not ok then
    pcall(sig.close, sig)
    return nil
  end
  return function()
    -- libuv ASSERTS (aborts the process, no Lua error) when a signal handle that is closing is stopped
    if sig:is_closing() then
      return
    end
    pcall(sig.stop, sig)
    pcall(sig.close, sig)
  end
end

-- =========================================================
-- Glue: the real seams of `testing --watch`
-- =========================================================

---Modules loaded before `baseline` stay; the rest is forgotten so that the next in-process run
---`require`s the edited files again. `testing*`, `lib.nvim*` and `lib.lua*` are the runner's own.
---@param baseline table<string, true>
---@return integer forgotten
function M.purge_modules(baseline)
  local n = 0
  for name in pairs(package.loaded) do
    if
      not baseline[name]
      and name ~= "testing"
      and not name:match("^testing%.")
      and not name:match("^lib%.nvim")
      and not name:match("^lib%.lua")
    then
      package.loaded[name] = nil
      n = n + 1
    end
  end
  return n
end

---The set of module names loaded right now.
---@return table<string, true>
function M.loaded_set()
  local set = {}
  for name in pairs(package.loaded) do
    set[name] = true
  end
  return set
end

---Files of a project that failed according to the history, grouped by file.
---@param root string
---@param state_dir? string
---@return table<string, true>
local function failed_files(root, state_dir)
  local hist = require("testing.history").load(root, { state_dir = state_dir })
  local out = {}
  for rel in pairs(require("testing.run.select").group_failed(hist.failed)) do
    out[rel] = true
  end
  return out
end

---Number of `run_cli` calls (the autocmd group of each is its own: a nested run cannot clear the one around it).
local leave_count = 0

---The specs `testing.affected` says a set of changed files can reach.
---@param root string
---@param cfg Testing.ProjectConfig
---@param changed string[] Changed files, relative to the root.
---@param over? { affected?: table, discover?: table, no_cache?: boolean } Replaces the modules (specs); `no_cache` keeps the analysis index off the disk.
---@return string[]|nil files nil = unknown: every spec runs
---@return string|nil note Why it is unknown.
function M.select_affected(root, cfg, changed, over)
  over = over or {}
  local affected = over.affected
  if affected == nil then
    local ok, mod = pcall(require, "testing.affected")
    affected = ok and mod or nil
  end
  if type(affected) ~= "table" or type(affected.select) ~= "function" then
    return nil, "no affected-module: every spec runs"
  end
  local discover = over.discover or require("testing.discover")
  local disc = discover.discover(
    root,
    { roots = cfg.roots, dialect = cfg.dialect, spec_pattern = cfg.spec_pattern }
  )
  local specs = {}
  for _, f in ipairs(discover.order(disc)) do
    specs[#specs + 1] = f.rel
  end
  -- an explicit use of the selection (the person asked for --watch): CI only gets a warning
  local res, err = affected.select({
    root = root,
    specs = specs,
    changed = changed,
    implicit = false,
    roots = cfg.roots,
    no_cache = over.no_cache == true,
  })
  if type(res) ~= "table" or type(res.files) ~= "table" then
    return nil, err and tostring(err) or "the affected-module gave no answer"
  end
  if res.all then
    return nil, res.all_reason or "the selection cannot be trusted: every spec runs"
  end
  return res.files, nil
end

---`testing run --watch`: the loop over the real project. Returns the exit code of the last completed run.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param seams? table Replaces single seams of `M.new` (specs): `run`, `source`, `scan`, `wait`, `clock`, `select`.
---@return integer exit_code
function M.run_cli(plan, sv, seams)
  local args, root, cfg = plan.args, plan.root, plan.project
  ---@type Testing.Watch|nil
  local w
  local project = require("testing.run.project")
  local dirs = {}
  for _, r in ipairs(cfg.roots) do
    local d = root .. "/" .. r
    if vim.uv.fs_stat(d) then
      dirs[#dirs + 1] = d
    end
  end
  if vim.uv.fs_stat(root .. "/lua") then
    dirs[#dirs + 1] = root .. "/lua"
  end

  local baseline = M.loaded_set()
  local function is_spec(rel)
    for _, p in ipairs(cfg.spec_pattern) do
      if rel:find(p) then
        return true
      end
    end
    return false
  end

  ---@type Testing.Watch.Opts
  local opts = {
    root = root,
    dirs = vim.tbl_map(function(d)
      return M.rel_of(root, d)
    end, dirs),
    debounce_ms = args.watch_debounce_ms
      or (cfg.watch and cfg.watch.debounce_ms)
      or M.DEFAULT_DEBOUNCE_MS,
    max_wait_ms = args.watch_max_wait_ms or (cfg.watch and cfg.watch.max_wait_ms) or 0,
    poll = args.watch_poll,
    poll_ms = cfg.watch and cfg.watch.poll_ms or M.DEFAULT_POLL_MS,
    say = function(line)
      sv.out(line)
    end,
    scan = function()
      -- every file below the roots and `lua/` (a fixture a spec reads counts) and the project's own `.testing.lua`
      return M.scan_dirs(dirs, { all = true, files = { root .. "/.testing.lua" } })
    end,
    source = function(on_event)
      return M.fs_source(on_event, { dirs = dirs, flat_dirs = { root } })
    end,
    event = args.events
        and function(kind, fields)
          local events = require("testing.run.events")
          if type(fields.files) == "table" and #fields.files > events.MAX_FILES then
            fields.files = vim.list_slice(fields.files, 1, events.MAX_FILES)
          end
          events.note(args.events, kind, fields, sv.events_out)
        end
      or nil,
    is_spec = is_spec,
    select = function(changed)
      return M.select_affected(root, cfg, changed, { no_cache = args.no_cache })
    end,
    run = function(files, ctx)
      if not ctx.first then
        M.purge_modules(baseline)
      end
      local cycle_args = vim.deepcopy(args)
      cycle_args.watch = false
      cycle_args.watch_debounce_ms = nil
      cycle_args.watch_max_wait_ms = nil
      cycle_args.watch_poll = false
      if files then
        cycle_args.paths = files
        cycle_args.ff = true
        cycle_args.lf = false
      end
      local cycle_plan = vim.tbl_extend("force", plan, { args = cycle_args })
      sv.out(("--- run %d ---"):format(ctx.n))
      local code = project.execute(cycle_plan, sv)
      -- Ctrl-C during the run killed its children: whatever the driver made of that is no verdict
      return {
        exit_code = code,
        failed = failed_files(root, sv.state_dir),
        interrupted = w ~= nil and w.stopped,
      }
    end,
  }
  for k, v in pairs(seams or {}) do
    opts[k] = v
  end

  w = M.new(opts)
  local remove = M.install_sigint(w)
  -- Ctrl-C while a run is going: nvim may treat SIGINT as a deadly signal there and leave through
  -- `VimLeavePre` (the run guard would answer "run did not complete", exit 3). This handler is created
  -- BEFORE the guard of the run, so it runs first: it ends the watcher (children killed, handles closed) and
  -- leaves with the exit code of the last COMPLETED run, the same as Ctrl-C between two runs.
  local real_exit = os.exit
  leave_count = leave_count + 1
  local group = vim.api.nvim_create_augroup("TestingWatchLeave" .. leave_count, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      if vim.v.exiting == vim.NIL or not w then
        return
      end
      pcall(function()
        require("testing.run.events").abort()
      end)
      real_exit(w:stop_and_say())
    end,
  })
  local ok, code = pcall(w.loop, w)
  pcall(vim.api.nvim_del_augroup_by_id, group)
  if remove then
    remove()
  end
  if not ok then
    pcall(w.stop, w)
    error(code, 0)
  end
  return code
end

return M
