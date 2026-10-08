---@module 'testing.statelock'
---@brief A short exclusive lock around the read-modify-write of a state file.
---@description
--- The state files beside `runs.jsonl` (`order.json`, `timings.json`, `durations.json`, `last_green.json`, `keys.json` and
--- `runs.jsonl` itself) are read, changed in memory and written back whole. Each write is atomic (a reader never
--- sees half a file), but two runs of the same project at the same time (a CI matrix on one machine, `watch`
--- next to a manual run) both read the old content and the second write drops what the first one added.
---
--- `with(path, fn)` runs `fn` while it holds `<path>.lock`, created with `O_CREAT|O_EXCL` (`"wx"`: the
--- check and the creation are one step). `fn` has to READ the file again inside the lock and merge into what it
--- finds, never into something it read before: that is what keeps both writers' entries.
---
--- * A holder that waits longer than `timeout_ms` (default 3000) gives up: `with` returns `false` and a note, and
---   the caller prints it. State is a hint, never part of the verdict, so a write that did not happen is better
---   than a write that overwrites somebody else's.
--- * A lock file that cannot be created for a reason other than "it exists" (a directory that is not writable:
---   EACCES / EPERM) is waited for only `grace_ms` (default 300) and then reported as it is, `cannot lock <path>:
---   <error>`: nobody holds it, and waiting the full timeout once per state file would only delay the end of a run
---   and put a wrong cause in the note.
--- * A lock older than `stale_ms` (default 10000; the critical section takes milliseconds) was left by a crashed
---   run and is taken over. The takeover renames the old file to a name of its own before it deletes it, so two
---   waiters do not delete each other's fresh lock more than once in a blue moon.
--- * The lock file holds `<pid> <unix time>` for whoever has to look at a stuck one.

local M = {}

---Longest wait for a lock held by a live run (milliseconds).
---@type integer
M.TIMEOUT_MS = 3000
---A lock older than this is a crashed run's (milliseconds).
---@type integer
M.STALE_MS = 10000
---Pause between two attempts (milliseconds).
---@type integer
M.POLL_MS = 15
---How long a refusal without a lock file in sight (EPERM / EACCES / EBUSY) may last before it is reported as an
---error: on Windows a lock whose delete is still pending refuses the next create for a few milliseconds.
---@type integer
M.GRACE_MS = 300

local uv = vim.uv or vim.loop

---@param lock string
---@return boolean created
---@return string|nil err
local function try_create(lock)
  local fd, err = uv.fs_open(lock, "wx", 420)
  if not fd then
    return false, err
  end
  pcall(uv.fs_write, fd, ("%d %d\n"):format(uv.os_getpid(), os.time()), 0)
  uv.fs_close(fd)
  return true, nil
end

---Take over a lock that is older than `stale_ms`. Returns true when this call removed it.
---@param lock string
---@param stale_ms integer
---@return boolean
local function steal_if_stale(lock, stale_ms)
  local st = uv.fs_stat(lock)
  if not st then
    return false
  end
  local age_ms = (os.time() - st.mtime.sec) * 1000
  if age_ms < stale_ms then
    return false
  end
  local mine = ("%s.stale.%d.%d"):format(lock, uv.os_getpid(), uv.hrtime())
  if not uv.fs_rename(lock, mine) then
    return false
  end
  pcall(uv.fs_unlink, mine)
  return true
end

---Run `fn` under the lock of `path`.
---@generic T
---@param path string The state file (its directory is created when missing).
---@param fn fun(): T
---@param opts? { timeout_ms?: integer, stale_ms?: integer, poll_ms?: integer, grace_ms?: integer }
---@return boolean locked False when the lock could not be taken: `fn` did not run.
---@return any ... What `fn` returned, or the note why it did not run.
function M.with(path, fn, opts)
  opts = opts or {}
  local lock = path .. ".lock"
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local timeout = opts.timeout_ms or M.TIMEOUT_MS
  local stale = opts.stale_ms or M.STALE_MS
  local poll = opts.poll_ms or M.POLL_MS
  local grace = opts.grace_ms or M.GRACE_MS
  local started = uv.hrtime()
  while true do
    local created, err = try_create(lock)
    if created then
      break
    end
    -- EEXIST: held. EBUSY/EPERM/EACCES: a lock file that is there (held), Windows while the holder's delete is
    -- still pending (gone in milliseconds), or a directory that cannot be written (it never gets better)
    local text = tostring(err)
    local exists = text:find("EEXIST", 1, true) ~= nil
    local denied = text:find("EBUSY", 1, true) ~= nil
      or text:find("EPERM", 1, true) ~= nil
      or text:find("EACCES", 1, true) ~= nil
    local waited = (uv.hrtime() - started) / 1e6
    if
      not (exists or denied) or (denied and not exists and waited >= grace and not uv.fs_stat(lock))
    then
      -- not "somebody holds it" (a read-only or missing directory): nothing to wait for
      return false, ("cannot lock %s: %s"):format(path, text)
    end
    if not steal_if_stale(lock, stale) then
      if waited >= timeout then
        return false,
          ("%s is locked by another run (%s): not updated"):format(
            vim.fn.fnamemodify(path, ":t"),
            vim.fn.fnamemodify(lock, ":t")
          )
      end
      uv.sleep(poll)
    end
  end
  -- (LuaJIT has no `table.pack`; the callers return at most three values)
  local res = { pcall(fn) }
  pcall(uv.fs_unlink, lock)
  if not res[1] then
    error(res[2], 0)
  end
  return true, res[2], res[3], res[4]
end

return M
