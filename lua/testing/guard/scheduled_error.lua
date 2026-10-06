---@module 'testing.guard.scheduled_error'
---@brief Errors in `vim.schedule` / luv callbacks / timers, which otherwise only reach `:messages` (NEW-47).
---@description
--- A spec whose scheduled callback throws is green by default: Neovim prints the error and goes on.
--- Three sources feed this guard:
---
---   1. `vim.schedule` is wrapped while a case is open: the callback runs under `xpcall`, the error
---      and its traceback are remembered (and re-raised, so the editor reacts as before);
---   2. `:messages` is scanned after the case (`snapshot` remembers where it was): the text of an
---      error in a luv callback / timer (`Error executing luv callback`, `Lua callback:`), of
---      `vim.schedule` (`Error executing vim.schedule lua callback`, `vim.schedule callback:`) and
---      the numbered Lua errors `E5105` / `E5107` / `E5108` that nobody caught;
---   3. `vim.notify(msg, vim.log.levels.ERROR)` calls are recorded (severity `notify`, default
---      `info`: plugins use it for expected user errors).
---
--- Finding ids: `scheduled.schedule_callback`, `scheduled.luv_callback`, `scheduled.error_message`,
--- `scheduled.notify_error`. A deliberate error is allowed with `allow_patterns`.
---
--- Limit: Neovim keeps a bounded message history; a case that prints more than the history holds can
--- push an error out of `:messages` before the scan (the `vim.schedule` wrapper still has it).

local M = {}

local PATTERNS = {
  { "Error executing vim.schedule lua callback", "scheduled.schedule_callback" },
  { "vim.schedule callback:", "scheduled.schedule_callback" },
  { "Error executing luv callback", "scheduled.luv_callback" },
  { "Lua callback:", "scheduled.luv_callback" },
  { "E5108:", "scheduled.error_message" },
  { "E5107:", "scheduled.error_message" },
  { "E5105:", "scheduled.error_message" },
  { "Error detected while processing", "scheduled.error_message" },
}

local MAX_DETAIL_LINES = 14

---@class Testing.Guard.ScheduledError
---@field h Testing.Guard.Handle
---@field cfg table
---@field pending table[]
---@field notifications table[]
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.ScheduledError
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg, pending = {}, notifications = {} }, G)
end

---@return string[]
local function messages()
  local ok, res = pcall(vim.api.nvim_exec2, "messages", { output = true })
  if not ok or not res.output or res.output == "" then
    return {}
  end
  return vim.split(res.output, "\n", { plain = true })
end

function G:install()
  local h, g = self.h, self
  h.patcher:wrap(vim, "schedule", function(orig)
    return function(fn, ...)
      if not h.active or type(fn) ~= "function" then
        return orig(fn, ...)
      end
      local case_id = h.ctx.id
      return orig(function(...)
        local res = vim.F.pack_len(xpcall(fn, function(e)
          return { err = e, tb = debug.traceback("", 2) }
        end, ...))
        if not res[1] then
          local e = res[2]
          local msg = type(e.err) == "string" and e.err or vim.inspect(e.err)
          g.pending[#g.pending + 1] = { case = case_id, message = msg, stack = e.tb }
          error(e.err, 0)
        end
        return unpack(res, 2, res.n)
      end)
    end
  end, "vim.schedule")
  if g.cfg.notify ~= "off" then
    h.patcher:wrap(vim, "notify", function(orig)
      return function(msg, level, ...)
        if h:is_active() and level == vim.log.levels.ERROR then
          g.notifications[#g.notifications + 1] = { case = h.ctx.id, message = tostring(msg) }
        end
        return orig(msg, level, ...)
      end
    end, "vim.notify")
  end
end

---@return table
function G:snapshot()
  local lines = messages()
  return { n = #lines, tail = lines[#lines], lines = nil }
end

---The lines printed since `snap`.
---@param snap? table
---@return string[]
local function new_lines(snap)
  local lines = messages()
  if not snap then
    return lines
  end
  if #lines >= snap.n and (snap.n == 0 or lines[snap.n] == snap.tail) then
    return vim.list_slice(lines, snap.n + 1, #lines)
  end
  -- history was trimmed: look for the last remembered line from the end
  if snap.tail then
    for i = #lines, 1, -1 do
      if lines[i] == snap.tail then
        return vim.list_slice(lines, i + 1, #lines)
      end
    end
  end
  return lines
end

---@param patterns string[]
---@param text string
---@return boolean
local function allowed(patterns, text)
  for _, p in ipairs(patterns or {}) do
    local ok, hit = pcall(string.find, text, p)
    if (ok and hit) or text:find(p, 1, true) then
      return true
    end
  end
  return false
end

---@param snap? table
---@param ctx Testing.Guard.CaseCtx
function G:check(snap, ctx)
  local h, label = self.h, self.h:label(ctx)
  local mode = self.cfg.mode
  local allow = self.cfg.allow_patterns
  -- 1. errors the wrapper saw
  local keep = {}
  local consumed = {}
  for _, p in ipairs(self.pending) do
    if p.case == ctx.id then
      if not allowed(allow, p.message) then
        local first = p.message:match("^[^\n]*") or p.message
        h:finding(
          "scheduled_error",
          "scheduled.schedule_callback",
          ("%s: a vim.schedule callback threw: %s"):format(label, first),
          { mode = mode, stack = p.message .. "\n" .. p.stack }
        )
        consumed[#consumed + 1] = first
      end
    else
      keep[#keep + 1] = p
    end
  end
  self.pending = keep
  -- 2. :messages
  local lines = new_lines(snap)
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local hit
    for _, pat in ipairs(PATTERNS) do
      if line:find(pat[1], 1, true) then
        hit = pat
        break
      end
    end
    if hit then
      local block = { line }
      local j = i + 1
      while j <= #lines and #block < MAX_DETAIL_LINES do
        local nxt = lines[j]
        local starts_new = false
        for _, pat in ipairs(PATTERNS) do
          if nxt:find(pat[1], 1, true) then
            starts_new = true
          end
        end
        if starts_new or nxt == "" then
          break
        end
        block[#block + 1] = nxt
        j = j + 1
      end
      local text = table.concat(block, "\n")
      local dup = false
      for _, first in ipairs(consumed) do
        if first ~= "" and text:find(first, 1, true) then
          dup = true
        end
      end
      if not dup and not allowed(allow, text) then
        local summary = vim.trim(block[1])
        if summary:sub(-1) == ":" and vim.trim(block[2] or "") ~= "" then
          summary = vim.trim(block[2])
        end
        h:finding(
          "scheduled_error",
          hit[2],
          ("%s: error outside the test body (:messages): %s"):format(label, summary),
          { mode = mode, stack = text }
        )
      end
      i = j
    else
      i = i + 1
    end
  end
  -- 3. notifications
  local rest = {}
  for _, n in ipairs(self.notifications) do
    if n.case == ctx.id then
      if not allowed(allow, n.message) then
        local first = n.message:match("^[^\n]*") or n.message
        h:finding(
          "scheduled_error",
          "scheduled.notify_error",
          ("%s: vim.notify(ERROR): %s"):format(label, first),
          { mode = self.cfg.notify }
        )
      end
    else
      rest[#rest + 1] = n
    end
  end
  self.notifications = rest
end

function G:begin()
  self.pending = {}
  self.notifications = {}
end

return M
