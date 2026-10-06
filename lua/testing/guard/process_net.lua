---@module 'testing.guard.process_net'
---@brief Process and network guard: blocked by default, logged always, released by tag or config.
---@description
--- Wrapped while a case is open (the runner and the helpers of lib.nvim spawn between cases and
--- are never seen):
---
---   process  `vim.system`, `vim.fn.jobstart` / `termopen` / `system` / `systemlist`,
---            `io.popen`, `os.execute`, `vim.uv.spawn`
---   network  `tcp:connect`, `udp:send` / `connect`, `vim.uv.getaddrinfo`, `vim.net.request`,
---            `vim.fn.sockconnect`
---
--- Every attempt goes into the ledger (`spawned` with the redacted argv, `network` with the host),
--- allowed or not. A call is LET THROUGH when
---   * the case has the tag `@spawn` (processes) / `@network` (network), or
---   * the executable (basename, `.exe`/`.cmd`/`.bat` ignored, case-insensitive) is in
---     `allow_exec`, the host in `allow_hosts` (config: nothing is hard-coded here; a harness that
---     needs `git` lists it), or
---   * the case called `handle:allow("spawn", "git")` / `handle:allow("network", "host")`.
--- Otherwise (mode `error`) the call raises an error naming the tag and the config key, the
--- ledger entry is marked `[blocked]` and the finding `process.spawn_blocked` / `network.blocked`
--- stays even if the spec catches the error. Mode `warn` lets everything through and only reports.
---
--- `vim.system` itself calls `uv.spawn` and `vim.net.request` calls `vim.system`: a wrapper silences
--- the guard (`busy`) while it runs the original, so one attempt is one ledger entry.
---
--- Limits: a command given as a SHELL STRING (`jobstart("a && b")`, `os.execute`) is judged by its
--- first word only; what a started program does afterwards is invisible; Vimscript (`:!cmd`,
--- `system()` called from `:call`) does not pass through the Lua wrappers.

local ledger = require("testing.core.ledger")

local M = {}

---@class Testing.Guard.ProcessNet
---@field h Testing.Guard.Handle
---@field cfg table
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.ProcessNet
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg }, G)
end

---`C:\Tools\Git.EXE` -> `git`.
---@param exe any
---@return string
local function exe_name(exe)
  if type(exe) ~= "string" then
    return ""
  end
  local base = exe:match("([^/\\]+)$") or exe
  base = base:lower():gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", ""):gsub("%.com$", "")
  return base
end

---@param list string[]|nil
---@param value string
---@return boolean
local function listed(list, value)
  for _, v in ipairs(list or {}) do
    if v:lower() == value then
      return true
    end
  end
  return false
end

---The host of `url` (scheme, user info, port and path stripped).
---@param url any
---@return string
local function url_host(url)
  if type(url) ~= "string" then
    return tostring(url)
  end
  local rest = url:gsub("^%a[%w+.-]*://", "")
  rest = rest:gsub("^[^/@]*@", "")
  return (rest:match("^%[?([^/:%]?#]+)") or rest):lower()
end

---Decide and record. Returns `true` when the call may proceed.
---@param self Testing.Guard.ProcessNet
---@param kind "spawn"|"network"
---@param text string display text (redacted by the ledger)
---@param key string executable name or host (lower case)
---@param api string
---@return boolean proceed
local function judge(self, kind, text, key, api)
  local h = self.h
  local ledger_kind = kind == "spawn" and "spawned" or "network"
  local tag_ok = h:has_tag(kind) or h.dyn_allow[kind][key] == true
  local cfg_ok = listed(kind == "spawn" and self.cfg.allow_exec or self.cfg.allow_hosts, key)
  local mode = self.cfg.mode
  if tag_ok or cfg_ok then
    h:log(ledger_kind, text, { allowed = tag_ok and "tag" or "config" })
    return true
  end
  local blocked = mode == "error" or (mode == "warn" and h.cfg.strict)
  h:log(ledger_kind, text, { blocked = blocked or nil })
  local id = kind == "spawn" and "process.spawn_blocked" or "network.blocked"
  local what = kind == "spawn" and "started a process" or "used the network"
  local how = kind == "spawn" and "@spawn" or "@network"
  local cfgkey = kind == "spawn" and "allow_exec" or "allow_hosts"
  local msg = ("%s %s: %s via %s%s"):format(
    h:label(),
    what,
    ledger.redact_secrets(text),
    api,
    blocked
        and (" (blocked: tag the case %s or list it in guards.process_net.%s)"):format(how, cfgkey)
      or " (not allowed)"
  )
  h:finding("process_net", id, msg, { mode = mode, stack = h:stack(4) })
  if blocked then
    error("testing.guard: " .. h.redact(msg), 0)
  end
  return true
end

---Run `orig` with the guard silenced (inner wrapped calls are part of this attempt).
---@param h Testing.Guard.Handle
---@param orig function
---@return any ...
local function inner(h, orig, ...)
  h.busy = h.busy + 1
  local res = vim.F.pack_len(pcall(orig, ...))
  h.busy = h.busy - 1
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

---`C:\Tools\git.exe` -> `git` (the ledger reads the same on every machine).
---@param exe any
---@return string
local function shown_exe(exe)
  local base = tostring(exe):match("([^/\\]+)$") or tostring(exe)
  return (base:gsub("%.[Ee][Xx][Ee]$", ""))
end

---@param cmd any string or list
---@return string text, string exe
local function describe_cmd(cmd)
  if type(cmd) == "table" then
    -- the program is shown by its file name: the ledger is the same on every machine
    local shown = vim.list_extend({}, cmd)
    shown[1] = shown_exe(cmd[1])
    return ledger.format_argv(shown), exe_name(cmd[1])
  end
  local s = tostring(cmd)
  local first, rest = s:match('^%s*"([^"]+)"(.*)$')
  if not first then
    first, rest = s:match("^%s*(%S+)(.*)$")
  end
  if not first then
    return ledger.format_argv(s), ""
  end
  return ledger.format_argv(shown_exe(first) .. rest), exe_name(first)
end

function G:install()
  local h, g = self.h, self
  local p = h.patcher
  local uv = vim.uv or vim.loop

  local function wrap_cmd(tbl, key, label, argn)
    p:wrap(tbl, key, function(orig)
      return function(...)
        if not h:is_active() then
          return orig(...)
        end
        local text, exe = describe_cmd((select(argn or 1, ...)))
        judge(g, "spawn", text, exe, label)
        return inner(h, orig, ...)
      end
    end, label)
  end
  wrap_cmd(vim, "system", "vim.system")
  wrap_cmd(vim.fn, "jobstart", "vim.fn.jobstart")
  wrap_cmd(vim.fn, "termopen", "vim.fn.termopen")
  wrap_cmd(vim.fn, "system", "vim.fn.system")
  wrap_cmd(vim.fn, "systemlist", "vim.fn.systemlist")
  wrap_cmd(io, "popen", "io.popen")
  p:wrap(os, "execute", function(orig)
    return function(cmd, ...)
      if cmd == nil or not h:is_active() then
        return orig(cmd, ...)
      end
      local text, exe = describe_cmd(cmd)
      judge(g, "spawn", text, exe, "os.execute")
      return inner(h, orig, cmd, ...)
    end
  end, "os.execute")
  p:wrap(uv, "spawn", function(orig)
    return function(path, opts, ...)
      if not h:is_active() then
        return orig(path, opts, ...)
      end
      local argv = { tostring(path) }
      for _, a in ipairs(type(opts) == "table" and opts.args or {}) do
        argv[#argv + 1] = tostring(a)
      end
      argv[1] = shown_exe(argv[1])
      judge(g, "spawn", ledger.format_argv(argv), exe_name(path), "uv.spawn")
      return inner(h, orig, path, opts, ...)
    end
  end, "uv.spawn")

  -- network
  p:wrap(uv, "getaddrinfo", function(orig)
    return function(host, ...)
      if not h:is_active() then
        return orig(host, ...)
      end
      local name = tostring(host or ""):lower()
      judge(g, "network", "dns " .. name, name, "uv.getaddrinfo")
      return inner(h, orig, host, ...)
    end
  end, "uv.getaddrinfo")
  local function wrap_method(handle, method, label, host_idx, port_idx)
    local mt = getmetatable(handle)
    local methods = mt and mt.__index
    if type(methods) ~= "table" then
      return
    end
    p:wrap(methods, method, function(orig)
      return function(self_, ...)
        if not h:is_active() then
          return orig(self_, ...)
        end
        local a = { ... }
        local host = tostring(a[host_idx] or ""):lower()
        local text = ("%s %s%s"):format(
          label,
          host,
          a[port_idx] and (":" .. tostring(a[port_idx])) or ""
        )
        judge(g, "network", text, host, label)
        return inner(h, orig, self_, ...)
      end
    end, label)
  end
  local tcp = uv.new_tcp()
  if tcp then
    wrap_method(tcp, "connect", "tcp.connect", 1, 2)
    tcp:close()
  end
  local udp = uv.new_udp()
  if udp then
    wrap_method(udp, "send", "udp.send", 2, 3)
    wrap_method(udp, "try_send", "udp.try_send", 2, 3)
    wrap_method(udp, "connect", "udp.connect", 1, 2)
    udp:close()
  end
  if vim.net and type(vim.net.request) == "function" then
    p:wrap(vim.net, "request", function(orig)
      return function(url, ...)
        if not h:is_active() then
          return orig(url, ...)
        end
        local host = url_host(url)
        judge(g, "network", "request " .. host, host, "vim.net.request")
        return inner(h, orig, url, ...)
      end
    end, "vim.net.request")
  end
  p:wrap(vim.fn, "sockconnect", function(orig)
    return function(mode, address, ...)
      if not h:is_active() then
        return orig(mode, address, ...)
      end
      local addr = tostring(address or "")
      local host = mode == "tcp" and (addr:match("^(.*):%d+$") or addr):lower() or addr:lower()
      judge(
        g,
        "network",
        ("sockconnect %s %s"):format(tostring(mode), addr),
        host,
        "vim.fn.sockconnect"
      )
      return inner(h, orig, mode, address, ...)
    end
  end, "vim.fn.sockconnect")
end

return M
