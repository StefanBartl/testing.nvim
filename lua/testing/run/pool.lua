---@module 'testing.run.pool'
---@brief The warm pool: child editors that stay alive from spec file to spec file.
---@description
--- Starting an editor costs about 0.3 s on Windows (0.05 s on Linux), and a 65-file suite pays it 65
--- times. The pool starts at most `size` embedded editors (`testing.rpc`, one `nvim --embed` each) and
--- lends them out one file at a time:
---
---   pool:acquire(cb)                 -> cb(member) | cb(nil, err)    (a free member, a new one, or wait)
---   ... run the file in member.child (see `testing.run.isolated`, `testing.child.pool_boot`)
---   pool:release(member, reason?)    the member goes back, or (a `reason`) is thrown away
---   pool:shutdown()                  every member is killed with its process tree
---
--- A member is reusable only when the file left nothing behind that the reset could not undo
--- (`pool_boot.run` answers with the lists); a member that crashed, timed out or leaks is DISCARDED, its
--- process tree is killed and the next file gets a new member. A crash or a timeout therefore kills
--- exactly the member that ran the file: the other members, and the files after it, are untouched.
---
--- `acquire` never blocks the main loop: a new member starts with `testing.rpc.spawn_async`, a caller
--- that finds all `size` members busy waits in a FIFO queue, so the order in which files get members is
--- the order in which they asked (the verdict order is the supervisor's business, not the pool's).
---
--- The pool decides nothing about verdicts and merges no results; it owns processes.

local M = {}

---@class Testing.Pool.Member
---@field id integer
---@field child Testing.Rpc.Child
---@field files integer Files this member has run.
---@field history? string[] Relative paths of those files, in order (`testing.run.isolated` names them on a red case).
---@field started_ms number

---@class Testing.Pool.Opts
---@field size integer Most members alive at once (>= 1).
---@field spawn_opts table `testing.rpc` options of every member (root, minit, rtp, env, ...).
---@field init_opts? table `testing.child.pool_boot.init` options.
---@field rpc? table Replaces `require("testing.rpc")` (specs).

---@class Testing.Pool.Stats
---@field spawned integer Members started.
---@field reused integer Files that ran in a member that had run a file before.
---@field discarded integer Members thrown away (`reason` given to `release`).
---@field files integer Files run.
---@field failed_starts integer Members that could not be started.
---@field boot_ms number Time spent starting members (start + setup), summed.
---@field finish_ms table<string, number> What the verification after a file cost, per step, summed (settle, soft, options, reset, sandbox).

---@class Testing.Pool
---@field opts Testing.Pool.Opts
---@field idle Testing.Pool.Member[]
---@field busy table<integer, Testing.Pool.Member>
---@field starting integer
---@field waiters fun(member: Testing.Pool.Member|nil, err: string|nil)[]
---@field stats Testing.Pool.Stats
---@field closed boolean
---@field seq integer
local Pool = {}
Pool.__index = Pool

---@param opts Testing.Pool.Opts
---@return Testing.Pool
function M.new(opts)
  return setmetatable({
    opts = opts,
    idle = {},
    busy = {},
    starting = 0,
    waiters = {},
    stats = {
      spawned = 0,
      reused = 0,
      discarded = 0,
      files = 0,
      failed_starts = 0,
      boot_ms = 0,
      finish_ms = {},
    },
    closed = false,
    seq = 0,
  }, Pool)
end

---Members alive or starting.
---@return integer
function Pool:count()
  return #self.idle + vim.tbl_count(self.busy) + self.starting
end

---Hand a member to the first waiter, or start one for it when there is room.
function Pool:dispatch()
  while #self.waiters > 0 do
    local cb = self.waiters[1]
    if self.closed then
      table.remove(self.waiters, 1)
      cb(nil, "the pool is closed")
    elseif #self.idle > 0 then
      table.remove(self.waiters, 1)
      local member = table.remove(self.idle, 1)
      self.busy[member.id] = member
      cb(member, nil)
    elseif self:count() < self.opts.size then
      table.remove(self.waiters, 1)
      self:start_member(cb)
    else
      return
    end
  end
end

---Start a member and give it to `cb`.
---@param cb fun(member: Testing.Pool.Member|nil, err: string|nil)
function Pool:start_member(cb)
  self.starting = self.starting + 1
  local started = vim.uv.hrtime()
  local rpc = self.opts.rpc or require("testing.rpc")
  rpc.spawn_async(self.opts.spawn_opts, function(child, err)
    if not child then
      self.starting = self.starting - 1
      self.stats.failed_starts = self.stats.failed_starts + 1
      cb(nil, err)
      self:dispatch()
      return
    end
    -- the member's own setup (filetype, soft isolation session, option and sandbox baselines)
    local init = vim.deepcopy(self.opts.init_opts or {})
    init.dirs = {}
    for _, name in ipairs({ "config", "data", "state", "cache" }) do
      init.dirs[name] = (child.dirs or {})[name]
    end
    child.exec_async(
      "return require('testing.child.pool_boot').init(...)",
      { init },
      function(ok, res)
        self.starting = self.starting - 1
        if not ok then
          self.stats.failed_starts = self.stats.failed_starts + 1
          pcall(child.kill)
          cb(nil, "the pool member could not be set up: " .. tostring(res))
          self:dispatch()
          return
        end
        self.seq = self.seq + 1
        self.stats.spawned = self.stats.spawned + 1
        self.stats.boot_ms = self.stats.boot_ms + (vim.uv.hrtime() - started) / 1e6
        ---@type Testing.Pool.Member
        local member =
          { id = self.seq, child = child, files = 0, started_ms = vim.uv.hrtime() / 1e6 }
        if self.closed then
          pcall(child.kill)
          cb(nil, "the pool is closed")
          return
        end
        self.busy[member.id] = member
        cb(member, nil)
      end
    )
  end)
end

---Ask for a member. `cb` runs once: with a member (this caller owns it until `release`), or with an
---error when no member could be started.
---@param cb fun(member: Testing.Pool.Member|nil, err: string|nil)
function Pool:acquire(cb)
  self.waiters[#self.waiters + 1] = cb
  self:dispatch()
end

---Add what a verification cost to the statistics.
---@param ms table<string, number>|nil
function Pool:account(ms)
  for step, v in pairs(type(ms) == "table" and ms or {}) do
    if type(v) == "number" then
      self.stats.finish_ms[step] = (self.stats.finish_ms[step] or 0) + v
    end
  end
end

---Give a member back. A `reason` throws it away (its process tree is killed); without one it is
---reused by the next file.
---@param member Testing.Pool.Member
---@param reason? string Why the member cannot be reused.
function Pool:release(member, reason)
  if self.busy[member.id] == nil then
    return
  end
  self.busy[member.id] = nil
  self.stats.files = self.stats.files + 1
  if member.files > 0 then
    self.stats.reused = self.stats.reused + 1
  end
  member.files = member.files + 1
  if not reason then
    local ok, up = pcall(member.child.alive)
    if not (ok and up == true) then
      reason = "the member ended"
    end
  end
  if reason or self.closed then
    self.stats.discarded = self.stats.discarded + 1
    pcall(member.child.kill)
  else
    self.idle[#self.idle + 1] = member
  end
  self:dispatch()
end

---Kill every member (the process trees first, then the waiting). Idempotent.
function Pool:shutdown()
  self.closed = true
  local all = {}
  for _, m in ipairs(self.idle) do
    all[#all + 1] = m
  end
  for _, m in pairs(self.busy) do
    all[#all + 1] = m
  end
  self.idle, self.busy = {}, {}
  local child_mod = require("testing.child")
  for _, m in ipairs(all) do
    local ok, proc = pcall(m.child.proc)
    if ok and proc and not proc.ended then
      pcall(child_mod.kill_tree, proc)
    end
  end
  for _, m in ipairs(all) do
    pcall(m.child.kill)
  end
  self:dispatch()
end

return M
