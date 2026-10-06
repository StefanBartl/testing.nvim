---@module 'testing.guard.state'
---@brief State-leak guard: snapshot before / after a case or file, named findings, soft isolation.
---@description
--- Shared state between spec files hid real bugs in the fleet for years (a spec that works only
--- because an earlier one left an autocmd, a cwd in a temp dir, a cache filled). This guard takes a
--- snapshot of the editor state before a case and names exactly what the case left behind:
---
---   "spec a_spec.lua::x leaves autocmd BufEnter in group MyGroup (pattern *.lua)"
---
--- Categories (`guards.state.categories`, each `error|warn|info|off`):
---   autocmds    every autocmd that was not there before (group, event, pattern)
---   usercmds    user commands, global and buffer-local (surviving buffers)
---   keymaps     global and buffer-local maps in n/i/x/s/o/c/t/l: added, replaced, removed
---   buffers / windows / tabs   created and still alive
---   cwd, rtp    current directory, runtimepath entries
---   options     global values of every option (named diff)
---   vars        `vim.g` (names only, never values)
---   env         environment variables (names only, never values)
---   highlights  highlight groups added or redefined
---   lua_globals new keys in `_G`
---   preload     new keys in `package.preload` (a stub that makes a later `require` fail or answer wrongly)
---   channels    jobs started and still running
---   modules     `package.loaded` keys added (default `info`: loading a module is normal)
---
--- Finding ids: `state.autocmd`, `state.usercmd`, `state.keymap`, `state.buffer`, `state.window`,
--- `state.tab`, `state.cwd`, `state.rtp`, `state.option`, `state.var`, `state.env`,
--- `state.highlight`, `state.lua_global`, `state.preload`, `state.channel`, `state.module`.
---
--- SOFT ISOLATION (`restore`, config `restore = true | {categories}` or `handle:restore()`):
--- close windows/tabs and delete buffers the case created, restore cwd, delete leaked autocmds and
--- user commands, delete or restore keymaps, put back options, `vim.g`, environment, runtimepath
--- and highlights. It is an aid for in-process runs, NOT an isolation: a leaked module-local cache,
--- a replaced Lua function, a started coroutine or a changed upvalue stay (`isolated = file` is
--- the real fix, and the guard names what a spec leaves so that it can be fixed).
---
--- Cost: roughly the editor's autocmd / keymap / option tables read twice per case (see
--- docs/GUARDS.md for the measured numbers); the heavier categories can be switched off.

local ledger = require("testing.core.ledger")

local M = {}

local uv = vim.uv or vim.loop
local IS_CI = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

local KEYMAP_MODES = { "n", "i", "x", "s", "o", "c", "t", "l" }

---Restorable categories `restore = true` stands for.
local DEFAULT_RESTORE = {
  "windows",
  "tabs",
  "buffers",
  "cwd",
  "autocmds",
  "usercmds",
  "keymaps",
  "options",
  "vars",
  "env",
  "rtp",
  "highlights",
}

---State the editor's OWN runtime changes as soon as a spec loads a filetype, a syntax or a lazily loaded
---module: never a leak of the spec, and reported they made 35 to 50 percent of all findings of the fleet
---runs. They are not captured at all (so they are neither reported nor restored).
---  * global variables of the runtime: `vim.g.markdown_*`, `java_*`, `typescript_*`, `pandoc#...`,
---    `lua_version`, `lua_subversion`, `did_load_*` (the ftplugin / syntax files set them on first use);
---  * the global value of the `syntax` option (every `setfiletype` changes it);
---  * `_G.re` (the runtime sets it the first time `vim.re` or `vim.lsp` is touched);
---  * highlight groups that are defined with `default = true` (`:highlight default link ...`, which is
---    what every `$VIMRUNTIME/syntax/*.vim` does; a default never replaces a definition);
---  * the jobs of the clipboard provider (`win32yank`, `xclip`, `pbcopy`, ...), started by the runtime
---    on the first register access.
M.RUNTIME_VAR_PREFIXES =
  { "markdown_", "java_", "typescript_", "pandoc#", "lua_version", "lua_subversion", "did_load_" }
M.RUNTIME_OPTIONS = { syntax = true }
M.RUNTIME_GLOBALS = { re = true }
M.CLIPBOARD_PROVIDERS = {
  ["win32yank"] = true,
  ["win32yank.exe"] = true,
  ["xclip"] = true,
  ["xsel"] = true,
  ["pbcopy"] = true,
  ["pbpaste"] = true,
  ["wl-copy"] = true,
  ["wl-paste"] = true,
  ["clip.exe"] = true,
  ["lemonade"] = true,
  ["doitclient"] = true,
  ["termux-clipboard-set"] = true,
  ["termux-clipboard-get"] = true,
}

---@class Testing.Guard.State
---@field h Testing.Guard.Handle
---@field cfg table
---@field opt_names? string[]
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.State
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg }, G)
end

---@param cat string
---@return string mode
function G:cat_mode(cat)
  return self.cfg.categories[cat] or "off"
end

---@param name any
---@param prefixes string[]
---@return boolean
local function has_prefix(name, prefixes)
  if type(name) ~= "string" then
    return false
  end
  for _, p in ipairs(prefixes) do
    if name:sub(1, #p) == p then
      return true
    end
  end
  return false
end

---@param list string[]
---@return table<string, boolean>
local function set_of(list)
  local s = {}
  for _, v in ipairs(list or {}) do
    s[v] = true
  end
  return s
end

---Compact display of a value for messages.
---@param v any
---@return string
local function show(v)
  local s = type(v) == "string" and v or vim.inspect(v)
  s = s:gsub("%s+", " ")
  if #s > 60 then
    s = s:sub(1, 57) .. "..."
  end
  return s
end

-- =========================================================
-- Capture
-- =========================================================

local CAPTURE = {}

function CAPTURE.autocmds(self)
  local res = {}
  local ok, list = pcall(vim.api.nvim_get_autocmds, {})
  if not ok then
    return res
  end
  for _, a in ipairs(list) do
    -- a groupless `once` autocmd on `SafeState` is the editor's own idle hook (the runtime's matchparen
    -- registers one at every cursor move); it removes itself at the next idle moment
    if not (a.once == true and not a.group_name and a.event == "SafeState") then
      local key = a.id and tostring(a.id)
        or table.concat(
          { a.event, a.group_name or "", a.pattern or "", a.command or "", a.desc or "" },
          "\0"
        )
      res[key] = {
        id = a.id,
        event = a.event,
        group = a.group_name,
        pattern = a.pattern,
        buffer = a["buffer"], -- only present for buffer-local autocmds (not in the type)
        desc = a.desc,
      }
    end
  end
  return res
end

function CAPTURE.usercmds(self)
  local res = { global = {}, buf = {} }
  for name, c in pairs(vim.api.nvim_get_commands({})) do
    res.global[name] = tostring(c.definition)
  end
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and n < self.cfg.max_buffers_scanned then
      n = n + 1
      local cmds = {}
      for name, c in pairs(vim.api.nvim_buf_get_commands(b, {})) do
        cmds[name] = tostring(c.definition)
      end
      res.buf[b] = cmds
    end
  end
  return res
end

function CAPTURE.keymaps(self)
  local res = { global = {}, buf = {} }
  for _, mode in ipairs(KEYMAP_MODES) do
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      res.global[mode .. "\0" .. m.lhs] = m
    end
  end
  local n = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and n < self.cfg.max_buffers_scanned then
      n = n + 1
      local maps = {}
      for _, mode in ipairs(KEYMAP_MODES) do
        for _, m in ipairs(vim.api.nvim_buf_get_keymap(b, mode)) do
          maps[mode .. "\0" .. m.lhs] = m
        end
      end
      res.buf[b] = maps
    end
  end
  return res
end

function CAPTURE.buffers()
  local res = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) then
      res[b] = {
        name = vim.api.nvim_buf_get_name(b),
        loaded = vim.api.nvim_buf_is_loaded(b),
        listed = vim.bo[b].buflisted,
      }
    end
  end
  return res
end

function CAPTURE.windows()
  local res = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    res[w] = vim.api.nvim_win_get_config(w).relative ~= ""
  end
  return res
end

function CAPTURE.tabs()
  local res = {}
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    res[t] = true
  end
  return res
end

function CAPTURE.cwd()
  return uv.cwd() or ""
end

function CAPTURE.rtp()
  return vim.split(vim.o.runtimepath, ",", { plain = true })
end

function CAPTURE.options(self)
  if not self.opt_names then
    local names = {}
    local skip = set_of(self.cfg.ignore_options)
    skip.runtimepath, skip.packpath = true, true
    for name in pairs(M.RUNTIME_OPTIONS) do
      skip[name] = true
    end
    for name in pairs(vim.api.nvim_get_all_options_info()) do
      if not skip[name] then
        names[#names + 1] = name
      end
    end
    table.sort(names)
    self.opt_names = names
  end
  local res = {}
  for _, name in ipairs(self.opt_names) do
    local ok, v = pcall(vim.api.nvim_get_option_value, name, { scope = "global" })
    if ok then
      res[name] = v
    end
  end
  return res
end

function CAPTURE.vars(self)
  local ok, g = pcall(vim.api.nvim_eval, "g:")
  local res = {}
  if ok and type(g) == "table" then
    for k, v in pairs(g) do
      if not has_prefix(k, self.cfg.ignore_vars) and not has_prefix(k, M.RUNTIME_VAR_PREFIXES) then
        res[k] = v
      end
    end
  end
  return res
end

function CAPTURE.env(self)
  local res = {}
  for k, v in pairs(vim.fn.environ()) do
    -- `=C:` and friends: Windows keeps the per-drive cwd in hidden variables
    if k:sub(1, 1) ~= "=" and not has_prefix(k, self.cfg.ignore_env) then
      res[k] = v
    end
  end
  return res
end

function CAPTURE.highlights(self)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, {})
  local res = {}
  if ok then
    for k, v in pairs(hl) do
      if
        not has_prefix(k, self.cfg.ignore_highlights)
        and not (type(v) == "table" and v.default == true)
      then
        res[k] = v
      end
    end
  end
  return res
end

function CAPTURE.lua_globals(self)
  local res = {}
  for k in pairs(_G) do
    if
      type(k) == "string"
      and not M.RUNTIME_GLOBALS[k]
      and not has_prefix(k, self.cfg.ignore_globals)
    then
      res[k] = true
    end
  end
  return res
end

function CAPTURE.preload()
  local res = {}
  for k in pairs(package.preload) do
    res[tostring(k)] = true
  end
  return res
end

function CAPTURE.channels()
  local res = {}
  for _, c in ipairs(vim.api.nvim_list_chans()) do
    if c.stream == "job" then
      local exe = type(c.argv) == "table" and c.argv[1] or nil
      local base = type(exe) == "string" and (exe:match("([^/\\]+)$") or exe):lower() or nil
      if not (base and M.CLIPBOARD_PROVIDERS[base]) then
        res[c.id] = c.argv or {}
      end
    end
  end
  return res
end

function CAPTURE.modules()
  local res = {}
  for k in pairs(package.loaded) do
    res[k] = true
  end
  return res
end

---@return table
function G:capture()
  local snap = {
    cur_win = vim.api.nvim_get_current_win(),
    cur_tab = vim.api.nvim_get_current_tabpage(),
    cur_buf = vim.api.nvim_get_current_buf(),
  }
  for cat, fn in pairs(CAPTURE) do
    if self:cat_mode(cat) ~= "off" then
      local ok, v = pcall(fn, self)
      if ok then
        snap[cat] = v
      else
        self.h.notes[#self.h.notes + 1] = ("state guard: capture of %s failed: %s"):format(
          cat,
          tostring(v)
        )
      end
    end
  end
  return snap
end

-- =========================================================
-- Diff: items { op = added|changed|removed, key, before?, after?, ... }
-- =========================================================

---@param before table<string, any>
---@param after table<string, any>
---@param equal fun(a: any, b: any): boolean
---@param extra? table fields copied into every item
---@return table[]
local function diff_map(before, after, equal, extra)
  local items = {}
  for k, v in pairs(after) do
    local b = before[k]
    local it
    if b == nil then
      it = { op = "added", key = k, after = v }
    elseif not equal(b, v) then
      it = { op = "changed", key = k, before = b, after = v }
    end
    if it then
      for ek, ev in pairs(extra or {}) do
        it[ek] = ev
      end
      items[#items + 1] = it
    end
  end
  for k, v in pairs(before) do
    if after[k] == nil then
      local it = { op = "removed", key = k, before = v }
      for ek, ev in pairs(extra or {}) do
        it[ek] = ev
      end
      items[#items + 1] = it
    end
  end
  table.sort(items, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)
  return items
end

local function eq_deep(a, b)
  return vim.deep_equal(a, b)
end

local function eq_always(a, b)
  return a == b
end

local function same_map(a, b)
  return a.rhs == b.rhs and a.callback == b.callback and a.desc == b.desc and a.expr == b.expr
end

local DIFF = {}

function DIFF.autocmds(self, b, a, ctx)
  local items = {}
  local ignore = self.cfg.ignore_groups
  local new_bufs = ctx.new_bufs
  for _, it in ipairs(diff_map(b, a, eq_always)) do
    local info = it.after or it.before
    if
      it.op == "added"
      and not has_prefix(info.group, ignore)
      and not (info.buffer and new_bufs[info.buffer])
    then
      it.info = info
      items[#items + 1] = it
    end
  end
  return items
end

function DIFF.usercmds(self, b, a, ctx)
  local items = {}
  for _, it in ipairs(diff_map(b.global, a.global, eq_always)) do
    it.scope = "global"
    items[#items + 1] = it
  end
  for buf, cmds in pairs(a.buf) do
    if b.buf[buf] and not ctx.new_bufs[buf] then
      for _, it in ipairs(diff_map(b.buf[buf], cmds, eq_always)) do
        it.scope = "buffer"
        it.buf = buf
        items[#items + 1] = it
      end
    end
  end
  return items
end

function DIFF.keymaps(self, b, a, ctx)
  local items = {}
  for _, it in ipairs(diff_map(b.global, a.global, same_map)) do
    it.scope = "global"
    items[#items + 1] = it
  end
  for buf, maps in pairs(a.buf) do
    if b.buf[buf] and not ctx.new_bufs[buf] then
      for _, it in ipairs(diff_map(b.buf[buf], maps, same_map)) do
        it.scope = "buffer"
        it.buf = buf
        items[#items + 1] = it
      end
    end
  end
  return items
end

function DIFF.buffers(self, b, a)
  local items = {}
  for nr, info in pairs(a) do
    if b[nr] == nil and (info.loaded or info.listed) then
      items[#items + 1] = { op = "added", key = nr, after = info }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.windows(self, b, a)
  local items = {}
  for id, floating in pairs(a) do
    if b[id] == nil then
      items[#items + 1] = { op = "added", key = id, floating = floating }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.tabs(self, b, a)
  local items = {}
  for id in pairs(a) do
    if b[id] == nil then
      items[#items + 1] = { op = "added", key = id }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.cwd(self, b, a)
  local function fold(p)
    p = vim.fs.normalize(p)
    return IS_CI and p:lower() or p
  end
  if fold(b) ~= fold(a) then
    return { { op = "changed", key = "cwd", before = b, after = a } }
  end
  return {}
end

function DIFF.rtp(self, b, a)
  local items = {}
  local before, after = set_of(b), set_of(a)
  for _, p in ipairs(a) do
    if not before[p] then
      items[#items + 1] = { op = "added", key = p }
    end
  end
  for _, p in ipairs(b) do
    if not after[p] then
      items[#items + 1] = { op = "removed", key = p }
    end
  end
  return items
end

function DIFF.options(self, b, a)
  return diff_map(b, a, eq_deep)
end

function DIFF.vars(self, b, a)
  return diff_map(b, a, eq_deep)
end

function DIFF.env(self, b, a)
  return diff_map(b, a, eq_always)
end

function DIFF.highlights(self, b, a)
  return diff_map(b, a, eq_deep)
end

function DIFF.lua_globals(self, b, a)
  local items = {}
  for k in pairs(a) do
    if not b[k] then
      items[#items + 1] = { op = "added", key = k }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.preload(self, b, a)
  local items = {}
  for k in pairs(a) do
    if not b[k] then
      items[#items + 1] = { op = "added", key = k }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.channels(self, b, a)
  local items = {}
  for id, argv in pairs(a) do
    if b[id] == nil then
      items[#items + 1] = { op = "added", key = id, argv = argv }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

function DIFF.modules(self, b, a)
  local items = {}
  for k in pairs(a) do
    if not b[k] then
      items[#items + 1] = { op = "added", key = k }
    end
  end
  table.sort(items, function(x, y)
    return x.key < y.key
  end)
  return items
end

-- =========================================================
-- Messages
-- =========================================================

local IDS = {
  autocmds = "state.autocmd",
  usercmds = "state.usercmd",
  keymaps = "state.keymap",
  buffers = "state.buffer",
  windows = "state.window",
  tabs = "state.tab",
  cwd = "state.cwd",
  rtp = "state.rtp",
  options = "state.option",
  vars = "state.var",
  env = "state.env",
  highlights = "state.highlight",
  lua_globals = "state.lua_global",
  preload = "state.preload",
  channels = "state.channel",
  modules = "state.module",
}

local VERB = { added = "leaves", changed = "changes", removed = "removes" }

---@param cat string
---@param it table
---@param label string
---@return string
local function describe(cat, it, label)
  local verb = VERB[it.op]
  if cat == "autocmds" then
    local a = it.info
    local pat = (a.pattern and a.pattern ~= "") and (" (pattern %s)"):format(a.pattern) or ""
    local grp = a.group and ("group " .. a.group) or "no group"
    return ("%s leaves autocmd %s in %s%s"):format(label, a.event, grp, pat)
  elseif cat == "usercmds" then
    local where = it.scope == "buffer" and (" in buffer %d"):format(it.buf) or ""
    return ("%s %s user command :%s%s"):format(label, verb, it.key, where)
  elseif cat == "keymaps" then
    local m = it.after or it.before
    local where = it.scope == "buffer" and (" of buffer %d"):format(it.buf) or ""
    local what = it.op == "changed" and "replaces" or verb
    return ("%s %s %skeymap %s (mode %s)%s"):format(
      label,
      what,
      it.scope == "buffer" and "buffer-local " or "",
      m.lhs,
      it.key:match("^[^%z]+"),
      where
    )
  elseif cat == "buffers" then
    local name = it.after.name ~= "" and it.after.name or "[No Name]"
    return ("%s leaves buffer %d (%s)"):format(label, it.key, name)
  elseif cat == "windows" then
    return ("%s leaves %s %d"):format(label, it.floating and "floating window" or "window", it.key)
  elseif cat == "tabs" then
    return ("%s leaves tab page %d"):format(label, vim.api.nvim_tabpage_get_number(it.key))
  elseif cat == "cwd" then
    return ("%s changes the working directory: %s -> %s"):format(label, it.before, it.after)
  elseif cat == "rtp" then
    return ("%s %s runtimepath entry %s"):format(
      label,
      it.op == "added" and "adds" or "removes",
      it.key
    )
  elseif cat == "options" then
    return ("%s changes option '%s' (%s -> %s)"):format(
      label,
      it.key,
      show(it.before),
      show(it.after)
    )
  elseif cat == "vars" then
    return ("%s %s vim.g.%s"):format(label, verb, it.key)
  elseif cat == "env" then
    return ("%s %s environment variable %s"):format(label, verb, it.key)
  elseif cat == "highlights" then
    return ("%s %s highlight group %s"):format(
      label,
      it.op == "added" and "adds" or "redefines",
      it.key
    )
  elseif cat == "lua_globals" then
    return ("%s leaves global _G.%s"):format(label, it.key)
  elseif cat == "preload" then
    return ("%s leaves package.preload[%q]"):format(label, it.key)
  elseif cat == "channels" then
    return ("%s leaves running job %s"):format(label, ledger.format_argv(it.argv))
  elseif cat == "modules" then
    return ("%s loads module %s"):format(label, it.key)
  end
  return label .. " leaves " .. cat .. " " .. tostring(it.key)
end

---@param before table
---@param after table
---@return table<string, table[]> items per category
function G:diff(before, after)
  local ctx = { new_bufs = {} }
  for nr in pairs(after.buffers or {}) do
    if before.buffers and before.buffers[nr] == nil then
      ctx.new_bufs[nr] = true
    end
  end
  if not before.buffers then
    -- without the buffer category new buffers cannot be told apart: use the buffer list itself
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      ctx.new_bufs[b] = nil
    end
  end
  local out = {}
  for cat, fn in pairs(DIFF) do
    if before[cat] ~= nil and after[cat] ~= nil then
      local ok, items = pcall(fn, self, before[cat], after[cat], ctx)
      if ok then
        out[cat] = items
      else
        self.h.notes[#self.h.notes + 1] = ("state guard: diff of %s failed: %s"):format(
          cat,
          tostring(items)
        )
      end
    end
  end
  return out
end

---@param snap? table
---@param ctx Testing.Guard.CaseCtx
function G:check(snap, ctx)
  if not snap then
    return
  end
  local h = self.h
  local label = h:label(ctx)
  local after = self:capture()
  local diffs = self:diff(snap, after)
  local cap = self.cfg.max_per_category
  for _, cat in ipairs({
    "autocmds",
    "usercmds",
    "keymaps",
    "buffers",
    "windows",
    "tabs",
    "cwd",
    "rtp",
    "options",
    "vars",
    "env",
    "highlights",
    "lua_globals",
    "preload",
    "channels",
    "modules",
  }) do
    local items = diffs[cat]
    if items and #items > 0 then
      local mode = self:cat_mode(cat)
      for i, it in ipairs(items) do
        if i > cap then
          h:finding(
            "state",
            IDS[cat],
            ("%s leaves %d more %s (not listed)"):format(label, #items - cap, cat),
            { mode = mode }
          )
          break
        end
        h:finding("state", IDS[cat], describe(cat, it, label), { mode = mode })
      end
    end
  end
end

-- =========================================================
-- Soft isolation
-- =========================================================

local RESTORE = {}

function RESTORE.windows(self, snap, items, after)
  local n = 0
  local new_tabs = {}
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    if snap.tabs and snap.tabs[t] == nil then
      new_tabs[t] = true
    end
  end
  for _, it in ipairs(items) do
    if vim.api.nvim_win_is_valid(it.key) then
      local tab = vim.api.nvim_win_get_tabpage(it.key)
      if not new_tabs[tab] and pcall(vim.api.nvim_win_close, it.key, true) then
        n = n + 1
      end
    end
  end
  return n
end

function RESTORE.tabs(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if vim.api.nvim_tabpage_is_valid(it.key) then
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(it.key)) do
        pcall(vim.api.nvim_win_close, w, true)
      end
      n = n + 1
    end
  end
  return n
end

function RESTORE.buffers(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if
      vim.api.nvim_buf_is_valid(it.key) and pcall(vim.api.nvim_buf_delete, it.key, { force = true })
    then
      n = n + 1
    end
  end
  return n
end

function RESTORE.cwd(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if pcall(vim.api.nvim_set_current_dir, it.before) then
      n = n + 1
    end
  end
  return n
end

function RESTORE.autocmds(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if it.info.id and pcall(vim.api.nvim_del_autocmd, it.info.id) then
      n = n + 1
    end
  end
  return n
end

function RESTORE.usercmds(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if it.op == "added" then
      local ok
      if it.scope == "buffer" then
        ok = vim.api.nvim_buf_is_valid(it.buf)
          and pcall(vim.api.nvim_buf_del_user_command, it.buf, it.key)
      else
        ok = pcall(vim.api.nvim_del_user_command, it.key)
      end
      if ok then
        n = n + 1
      end
    end
  end
  return n
end

---@param buf integer|nil
---@param mode string
---@param lhs string
---@return boolean
local function del_map(buf, mode, lhs)
  if buf then
    return (pcall(vim.api.nvim_buf_del_keymap, buf, mode, lhs))
  end
  return (pcall(vim.api.nvim_del_keymap, mode, lhs))
end

---@param buf integer|nil
---@param mode string
---@param lhs string
---@param m table a map as `nvim_get_keymap` returns it
---@return boolean
local function set_map(buf, mode, lhs, m)
  local opts = {
    noremap = m.noremap == 1,
    silent = m.silent == 1,
    expr = m.expr == 1,
    nowait = m.nowait == 1,
    desc = m.desc,
    callback = m.callback,
  }
  if buf then
    return (pcall(vim.api.nvim_buf_set_keymap, buf, mode, lhs, m.rhs or "", opts))
  end
  return (pcall(vim.api.nvim_set_keymap, mode, lhs, m.rhs or "", opts))
end

function RESTORE.keymaps(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    local mode = it.key:match("^[^%z]+")
    local lhs = (it.after or it.before).lhs
    local buf = it.scope == "buffer" and it.buf or nil
    local ok = false
    if not buf or vim.api.nvim_buf_is_valid(buf) then
      if it.op == "added" then
        ok = del_map(buf, mode, lhs)
      else
        if it.op == "changed" then
          del_map(buf, mode, lhs)
        end
        ok = set_map(buf, mode, lhs, it.before)
      end
    end
    if ok then
      n = n + 1
    end
  end
  return n
end

function RESTORE.options(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    if
      it.op == "changed"
      and pcall(vim.api.nvim_set_option_value, it.key, it.before, { scope = "global" })
    then
      n = n + 1
    end
  end
  return n
end

function RESTORE.vars(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    local v = it.op ~= "added" and it.before or nil
    if pcall(function()
      vim.g[it.key] = v
    end) then
      n = n + 1
    end
  end
  return n
end

function RESTORE.env(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    local v = it.op ~= "added" and it.before or nil
    if pcall(function()
      vim.env[it.key] = v
    end) then
      n = n + 1
    end
  end
  return n
end

function RESTORE.rtp(self, snap)
  if pcall(function()
    vim.o.runtimepath = table.concat(snap.rtp, ",")
  end) then
    return 1
  end
  return 0
end

function RESTORE.highlights(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    local def = it.op == "added" and {} or it.before
    if pcall(vim.api.nvim_set_hl, 0, it.key, def) then
      n = n + 1
    end
  end
  return n
end

function RESTORE.lua_globals(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    rawset(_G, it.key, nil)
    n = n + 1
  end
  return n
end

function RESTORE.preload(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    package.preload[it.key] = nil
    n = n + 1
  end
  return n
end

function RESTORE.modules(self, snap, items)
  local n = 0
  for _, it in ipairs(items) do
    package.loaded[it.key] = nil
    n = n + 1
  end
  return n
end

---Put back what the case left behind (see the module header for what that does and does not mean).
---@param snap? table the before-snapshot
---@param which boolean|string[] `true` = the default set, or a list of categories
---@return table<string, integer> restored counts per category
function G:restore(snap, which)
  local restored = {}
  if not snap or not which then
    return restored
  end
  local cats = (which == true and DEFAULT_RESTORE or which) --[[@as string[] ]]
  local after = self:capture()
  local diffs = self:diff(snap, after)
  -- windows and tabs first, then buffers: a buffer shown in a window cannot be wiped before
  local order = { "tabs", "windows", "buffers" }
  local want = set_of(cats)
  for _, cat in ipairs(cats) do
    if cat ~= "tabs" and cat ~= "windows" and cat ~= "buffers" then
      order[#order + 1] = cat
    end
  end
  for _, cat in ipairs(order) do
    local items = diffs[cat]
    local fn = RESTORE[cat]
    if want[cat] and fn and items and #items > 0 then
      local n = fn(self, snap, items, after)
      if n > 0 then
        restored[cat] = n
      end
    end
  end
  if snap.cur_win and vim.api.nvim_win_is_valid(snap.cur_win) then
    pcall(vim.api.nvim_set_current_win, snap.cur_win)
  end
  return restored
end

function G:snapshot()
  return self:capture()
end

return M
