---@module 'testing.surface.read'
---@brief Reads the machine-readable surface of a plugin from the registries of the editor this runs in.
---@description
--- Call it AFTER the plugin's `setup()` (`testing.surface` does that in a child editor; see
--- `testing.surface.collect`). What is read, and where from:
---
---   binding   `lib.nvim.bindings.keymap.registered()` (registered actions and plain `keymap.set()`
---             calls), plus the live keymaps whose Lua callback is DEFINED in the plugin (a plain
---             `vim.keymap.set` the registry never saw)
---   command   `lib.nvim.bindings.usercmd.registered()`, plus the routes of the composer verbs
---             (`composer.registry()`), plus the live Lua commands defined in the plugin
---   autocmd   `lib.nvim.bindings.autocmd.registered()`, plus live Lua autocmds defined in the plugin
---   api       the function fields of `require(<plugin>)` (names that do not start with `_`)
---   config    the keys of the typed DEFAULTS (`<plugin>.config.DEFAULTS` and a few other spellings)
---   health    `lua/<plugin>/health.lua` exists
---
--- "Of the plugin" means: the registry key is the plugin (or `<plugin>/<surface>`, or the name of the
--- repository directory), or the call site / the handler function lies below the project root.
---
--- Entry: `{ id, kind, name, desc?, src?, detail? }`, `src` as `path:line` relative to the root when it
--- lies inside. `detail` per kind: binding `{ lhs, modes, action?, direct?, buffer? }`, command
--- `{ verb?, route?, buffer?, nargs? }`, autocmd `{ events, group?, pattern?, buffer?, once? }`,
--- config `{ type }`.
---
--- HONEST LIMITS: what a plugin creates through the raw API without a Lua callback (a command given as
--- a string, a keymap with a string rhs) is invisible to the native scan (the lib registries still
--- see it when it went through lib.nvim); keymaps and autocmds a plugin creates LATER (on `FileType`,
--- on first use) exist only once something triggered them; a handler that is a wrapper function from
--- another module is attributed to that module, not to the plugin.

local ids = require("testing.surface.ids")

local M = {}

local IS_CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---@class Testing.Surface.Entry
---@field id string
---@field aliases? string[] other ids a hit may be recorded under (`action:<plugin>.<name>` of a registered keymap)
---@field kind string
---@field name string
---@field desc? string
---@field src? string
---@field detail? table

---@class Testing.Surface.Surface
---@field version integer
---@field plugin string
---@field root string
---@field entries Testing.Surface.Entry[]
---@field counts table<string, integer>
---@field notes string[]

---@class Testing.Surface.ReadOpts
---@field plugin string Lua module root of the plugin.
---@field root string Project root (absolute).
---@field kinds? string[] Restrict to these kinds (default all).
---@field own_keys? string[] Keymap registry keys that belong to the plugin whatever they are called (the ones that appeared while it was set up).
---@field max_config? integer Most config keys listed (default 400).

---@param p string
---@return string
local function slash(p)
  return (p:gsub("\\", "/"))
end

---@param p string
---@return string
local function key_of(p)
  p = slash(p)
  return IS_CASE_INSENSITIVE and p:lower() or p
end

---The handler behind a wrapper of the tracker (`testing.surface.track`) when this editor is tracked.
---@param f any
---@return any
local function unwrap(f)
  local t = package.loaded["testing.surface.track"]
  if type(t) == "table" and type(t.unwrap) == "function" then
    return t.unwrap(f)
  end
  return f
end

---A reader bound to one root.
---@param root string
---@return { owned: fun(path: string|nil): boolean, rel: fun(path: string): string, fn_src: fun(f: any): string|nil }
local function paths(root)
  local base = key_of(root):gsub("/+$", "")
  local P = {}
  ---@param path string|nil
  ---@return boolean
  function P.owned(path)
    if type(path) ~= "string" or path == "" then
      return false
    end
    local k = key_of((path:gsub("^@", "")))
    return k == base or k:sub(1, #base + 1) == base .. "/"
  end
  ---@param path string
  ---@return string
  function P.rel(path)
    local s = slash((path:gsub("^@", "")))
    if P.owned(s) then
      return (s:sub(#base + 2))
    end
    return s
  end
  ---`path:line` of a Lua function, nil for a C function or a non-function.
  ---@param f any
  ---@return string|nil
  function P.fn_src(f)
    f = unwrap(f)
    if type(f) ~= "function" then
      return nil
    end
    local info = debug.getinfo(f, "S")
    if
      not info
      or info.what == "C"
      or type(info.source) ~= "string"
      or info.source:sub(1, 1) ~= "@"
    then
      return nil
    end
    return ("%s:%d"):format(P.rel(info.source), info.linedefined or 0)
  end
  ---Absolute path of the file a function is defined in (nil for C / strings).
  ---@param f any
  ---@return string|nil
  function P.fn_file(f)
    f = unwrap(f)
    if type(f) ~= "function" then
      return nil
    end
    local info = debug.getinfo(f, "S")
    if
      info
      and info.what ~= "C"
      and type(info.source) == "string"
      and info.source:sub(1, 1) == "@"
    then
      return info.source:sub(2)
    end
    return nil
  end
  ---`src` strings of lib.nvim ("file:line") back to a path.
  ---@param src string|nil
  ---@return string|nil
  function P.src_file(src)
    if type(src) ~= "string" then
      return nil
    end
    return (src:gsub("^@", ""):gsub(":%-?%d+$", ""))
  end
  return P
end

---@param name string
---@return table|nil
local function try_require(name)
  local ok, mod = pcall(require, name)
  if ok and type(mod) == "table" then
    return mod
  end
  return nil
end

---Does a registry key (`plugin name` passed to `keymap.register`) belong to the plugin?
---@param key string
---@param plugin string
---@param dirname string
---@return boolean
local function key_matches(key, plugin, dirname)
  local base = key:match("^([^/]+)/") or key
  return base == plugin or base == dirname or base == dirname:gsub("%.nvim$", "")
end

---@param list Testing.Surface.Entry[]
---@param index table<string, Testing.Surface.Entry>
---@param entry Testing.Surface.Entry
---@return Testing.Surface.Entry the entry that stands for the id (an earlier duplicate wins)
local function add(list, index, entry)
  local have = index[entry.id]
  if have then
    have.detail = have.detail or {}
    have.detail.count = (have.detail.count or 1) + 1
    return have
  end
  index[entry.id] = entry
  list[#list + 1] = entry
  return entry
end

-- ===========================================================
-- keymaps
-- ===========================================================

local readable = ids.readable_lhs

---@param ctx table
local function read_bindings(ctx)
  local P = ctx.paths
  local km = try_require("lib.nvim.bindings.keymap")
  local known = {}
  local unbound = 0
  if km then
    local all = km.registered()
    local keys = vim.tbl_keys(all)
    table.sort(keys)
    for _, key in ipairs(keys) do
      for _, e in ipairs(all[key]) do
        local mine = key_matches(key, ctx.plugin, ctx.dirname)
          or ctx.own_keys[key]
          or P.owned(P.src_file(e.src))
          or P.owned(P.fn_file(e.rhs))
        if mine then
          if e.lhs == nil or e.bound == false then
            unbound = unbound + 1
          else
            local modes = ids.mode_list(e.mode)
            local entry = add(ctx.entries, ctx.index, {
              id = ids.binding(e.lhs, modes),
              kind = "binding",
              name = e.lhs,
              desc = e.desc,
              src = e.src and P.rel(e.src) or P.fn_src(e.rhs),
              aliases = (not e.direct) and { ids.action(e.plugin or key, e.name) } or nil,
              detail = {
                lhs = e.lhs,
                modes = modes,
                action = (not e.direct) and e.name or nil,
                direct = e.direct or nil,
                buffer = e.buffer ~= nil or nil,
                -- a string rhs cannot be wrapped: nothing could ever observe it
                untrackable = type(e.rhs) ~= "function" or nil,
              },
            })
            known[ids.norm_lhs(e.lhs)] = known[ids.norm_lhs(e.lhs)] or {}
            for _, m in ipairs(modes) do
              known[ids.norm_lhs(e.lhs)][m] = entry
            end
          end
        end
      end
    end
  end
  if unbound > 0 then
    ctx.notes[#ctx.notes + 1] = ("%d registered binding(s) with no lhs or switched off are not listed"):format(
      unbound
    )
  end

  -- native scan: a keymap whose Lua callback is defined in the plugin and the registry never saw
  local groups, order = {}, {}
  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o", "c", "t" }) do
    local ok, maps = pcall(vim.api.nvim_get_keymap, mode)
    for _, m in ipairs(ok and maps or {}) do
      if type(m.callback) == "function" and P.owned(P.fn_file(m.callback)) then
        local lhs = m.lhsraw or m.lhs or ""
        local already = known[ids.norm_lhs(lhs)]
        if not (already and already[m.mode:sub(1, 1)]) then
          local gk = ids.norm_lhs(lhs) .. "\0" .. tostring(m.callback)
          if not groups[gk] then
            groups[gk] = { lhs = readable(m.lhs), modes = {}, desc = m.desc, cb = m.callback }
            order[#order + 1] = gk
          end
          for ch in m.mode:gmatch(".") do
            if ch ~= " " then
              groups[gk].modes[#groups[gk].modes + 1] = ch
            end
          end
        end
      end
    end
  end
  for _, gk in ipairs(order) do
    local g = groups[gk]
    local modes = ids.mode_list(g.modes)
    add(ctx.entries, ctx.index, {
      id = ids.binding(g.lhs, modes),
      kind = "binding",
      name = g.lhs,
      desc = (g.desc and g.desc ~= "") and g.desc or nil,
      src = P.fn_src(g.cb),
      detail = { lhs = g.lhs, modes = modes, native = true },
    })
  end
end

-- ===========================================================
-- commands
-- ===========================================================

---@param ctx table
local function read_commands(ctx)
  local P = ctx.paths
  local uc = try_require("lib.nvim.bindings.usercmd")
  local verbs = {}
  local ok_c, composer = pcall(function()
    return uc and uc.composer.registry() or nil
  end)
  if ok_c and type(composer) == "table" then
    verbs = composer
  end
  local names = {}
  if uc then
    for _, r in ipairs(uc.registered()) do
      if P.owned(P.src_file(r.src)) then
        names[r.name] = r
      end
    end
  end

  -- composer verbs: one entry per route (and `command:Verb` when it has a default or a root route)
  local verb_names = vim.tbl_keys(verbs)
  table.sort(verb_names)
  for _, vname in ipairs(verb_names) do
    local handle = verbs[vname]
    local ok_s, spec = pcall(function()
      return handle:spec()
    end)
    spec = ok_s and spec or nil
    local rec = names[vname]
    local mine = rec ~= nil
    if spec and not mine then
      for _, route in ipairs(spec.routes or {}) do
        if P.owned(P.fn_file(route.run)) then
          mine = true
        end
      end
      if P.owned(P.fn_file(spec.default)) then
        mine = true
      end
    end
    if mine and spec then
      names[vname] = nil
      local has_root = false
      for _, route in ipairs(spec.routes or {}) do
        local path = route.path or {}
        if #path == 0 then
          has_root = true
        end
        local run = unwrap(route.run)
        local src = P.fn_src(run)
        if not src and type(run) == "string" then
          local file = package.searchpath(run, package.path)
          src = file and P.rel(file) or ("module " .. run)
        end
        add(ctx.entries, ctx.index, {
          id = ids.route(vname, path),
          kind = "command",
          name = (#path > 0) and (vname .. " " .. table.concat(path, " ")) or vname,
          desc = route.desc,
          src = src,
          detail = {
            verb = vname,
            route = table.concat(path, " "),
            buffer = rec and rec.buffer or nil,
          },
        })
      end
      if spec.default ~= nil and not has_root then
        add(ctx.entries, ctx.index, {
          id = ids.route(vname, {}),
          kind = "command",
          name = vname,
          desc = spec.desc,
          src = P.fn_src(spec.default) or (rec and P.rel(rec.src)) or nil,
          detail = { verb = vname, route = "" },
        })
      end
    end
  end

  local plain = vim.tbl_keys(names)
  table.sort(plain)
  for _, name in ipairs(plain) do
    local r = names[name]
    local live_ok, live = pcall(vim.api.nvim_get_commands, {})
    local live_cmd = live_ok and live[name] or nil
    add(ctx.entries, ctx.index, {
      id = ids.command(name),
      kind = "command",
      name = name,
      desc = r.desc,
      src = P.rel(r.src),
      detail = {
        nargs = r.nargs,
        bang = r.bang or nil,
        range = r.range or nil,
        buffer = r.buffer ~= nil or nil,
        untrackable = (live_cmd ~= nil and live_cmd.callback == nil) or nil,
      },
    })
  end

  -- native scan: global Lua commands defined in the plugin that lib.nvim never recorded
  local ok_n, live = pcall(vim.api.nvim_get_commands, {})
  if ok_n then
    local live_names = vim.tbl_keys(live)
    table.sort(live_names)
    for _, name in ipairs(live_names) do
      local c = live[name]
      if
        type(c) == "table"
        and type(c.callback) == "function"
        and P.owned(P.fn_file(c.callback))
        and not ctx.index[ids.command(name)]
        and not verbs[name]
      then
        add(ctx.entries, ctx.index, {
          id = ids.command(name),
          kind = "command",
          name = name,
          desc = (c.definition and c.definition ~= "") and c.definition or nil,
          src = P.fn_src(c.callback),
          detail = { nargs = c.nargs, native = true },
        })
      end
    end
  end
end

-- ===========================================================
-- autocmds
-- ===========================================================

---@param ctx table
local function read_autocmds(ctx)
  local P = ctx.paths
  local ac = try_require("lib.nvim.bindings.autocmd")
  local lib_ids = {}
  if ac then
    local records = ac.registered()
    local all_ids = ids.autocmd_ids(records)
    for i, r in ipairs(records) do
      lib_ids[r.id] = true
      if P.owned(P.src_file(r.src)) then
        add(ctx.entries, ctx.index, {
          id = all_ids[i],
          kind = "autocmd",
          name = all_ids[i]:sub(#"autocmd:" + 1),
          desc = r.desc,
          src = P.rel(r.src),
          detail = {
            events = r.events,
            group = r.group,
            pattern = r.pattern,
            buffer = r.buffer ~= nil or nil,
            once = r.once or nil,
          },
        })
      end
    end
  end
  -- native scan: live Lua autocmds whose callback is defined in the plugin
  local ok, live = pcall(vim.api.nvim_get_autocmds, {})
  local native = {}
  if ok then
    for _, a in ipairs(live) do
      if
        not lib_ids[a.id]
        and type(a.callback) == "function"
        and P.owned(P.fn_file(a.callback))
      then
        native[#native + 1] = {
          id = a.id,
          group = a.group_name,
          events = { a.event },
          pattern = a.pattern,
          buffer = a.buflocal and (a --[[@as table]]).buffer or nil,
          once = a.once,
          desc = a.desc,
          cb = a.callback,
        }
      end
    end
  end
  table.sort(native, function(x, y)
    return x.id < y.id
  end)
  local nids = ids.autocmd_ids(native)
  for i, r in ipairs(native) do
    local id = nids[i]
    -- numbering restarts for native ones: keep clear of an id a registry entry already owns
    local n = 1
    local base = id:gsub("#%d+$", "")
    while ctx.index[id] do
      n = n + 1
      id = ("%s#%d"):format(base, n)
    end
    add(ctx.entries, ctx.index, {
      id = id,
      kind = "autocmd",
      name = id:sub(#"autocmd:" + 1),
      desc = (r.desc and r.desc ~= "") and r.desc or nil,
      src = P.fn_src(r.cb),
      detail = {
        events = r.events,
        group = r.group,
        pattern = r.pattern,
        buffer = r.buffer ~= nil or nil,
        once = r.once or nil,
        native = true,
      },
    })
  end
end

-- ===========================================================
-- api, config, health
-- ===========================================================

---@param ctx table
local function read_api(ctx)
  local P = ctx.paths
  local mod = try_require(ctx.plugin)
  if not mod then
    ctx.notes[#ctx.notes + 1] = ("require('%s') did not return a table: no api entries"):format(
      ctx.plugin
    )
    return
  end
  local names = {}
  for k, v in pairs(mod) do
    if type(k) == "string" and type(v) == "function" and k:sub(1, 1) ~= "_" then
      names[#names + 1] = k
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    add(ctx.entries, ctx.index, {
      id = ids.api(ctx.plugin, name),
      kind = "api",
      name = ctx.plugin .. "." .. name,
      src = P.fn_src(mod[name]),
    })
  end
end

---Where the typed DEFAULTS of a plugin may live.
---@param plugin string
---@return string[]
local function defaults_candidates(plugin)
  return {
    plugin .. ".config.DEFAULTS",
    plugin .. ".DEFAULTS",
    plugin .. ".config.defaults",
    plugin .. ".defaults",
    plugin .. ".config",
  }
end

---@param ctx table
local function read_config(ctx)
  local tbl, from
  for _, name in ipairs(defaults_candidates(ctx.plugin)) do
    local m = try_require(name)
    if m then
      local candidate = m
      if type(rawget(m, "DEFAULTS")) == "table" then
        candidate = rawget(m, "DEFAULTS")
      elseif type(rawget(m, "defaults")) == "table" then
        candidate = rawget(m, "defaults")
      end
      -- a module of functions (a config module with `setup`, `get`) is not a table of defaults
      local data = 0
      for _, v in pairs(candidate) do
        if type(v) ~= "function" then
          data = data + 1
        end
      end
      if data > 0 then
        tbl, from = candidate, name
        break
      end
    end
  end
  if not tbl then
    ctx.notes[#ctx.notes + 1] = "no typed DEFAULTS found (looked for "
      .. table.concat(defaults_candidates(ctx.plugin), ", ")
      .. ")"
    return
  end
  local max = ctx.max_config
  local n = 0
  ---@param t table
  ---@param prefix string
  ---@param depth integer
  local function walk(t, prefix, depth)
    local keys = {}
    for k in pairs(t) do
      if type(k) == "string" then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = t[k]
      if type(v) ~= "function" then
        local full = prefix == "" and k or (prefix .. "." .. k)
        local is_map = type(v) == "table"
          and next(v) ~= nil
          and vim.islist(v) == false
          and depth < 3
        if is_map then
          walk(v, full, depth + 1)
        else
          n = n + 1
          if n <= max then
            ---@type string
            local typ = type(v)
            if typ == "table" then
              typ = (next(v) ~= nil and vim.islist(v)) and "list" or "table"
            end
            add(ctx.entries, ctx.index, {
              id = ids.config(full),
              kind = "config",
              name = full,
              detail = { type = typ },
            })
          end
        end
      end
    end
  end
  walk(tbl, "", 0)
  if n > max then
    ctx.notes[#ctx.notes + 1] = ("%d config keys, the first %d are listed"):format(n, max)
  end
  ctx.notes[#ctx.notes + 1] = "config keys read from " .. from
end

---@param ctx table
local function read_health(ctx)
  local found = vim.api.nvim_get_runtime_file("lua/" .. ctx.plugin .. "/health.lua", false)
  local file = found and found[1]
  if file then
    add(ctx.entries, ctx.index, {
      id = ids.health(ctx.plugin),
      kind = "health",
      name = ctx.plugin .. ".health",
      src = ctx.paths.rel(file),
    })
  end
end

-- ===========================================================
-- entry point
-- ===========================================================

local READERS = {
  binding = read_bindings,
  command = read_commands,
  autocmd = read_autocmds,
  api = read_api,
  config = read_config,
  health = read_health,
}

---Read the surface of `opts.plugin` from this editor.
---@param opts Testing.Surface.ReadOpts
---@return Testing.Surface.Surface
function M.read(opts)
  assert(
    type(opts) == "table" and type(opts.plugin) == "string" and opts.plugin ~= "",
    "read: plugin is required"
  )
  assert(type(opts.root) == "string" and opts.root ~= "", "read: root is required")
  local root = slash(opts.root):gsub("/+$", "")
  local want = {}
  for _, k in ipairs(opts.kinds or ids.KINDS) do
    want[k] = true
  end
  local ctx = {
    plugin = opts.plugin,
    root = root,
    dirname = vim.fs.basename(root),
    paths = paths(root),
    entries = {},
    index = {},
    notes = {},
    max_config = opts.max_config or 400,
    own_keys = (function()
      local set = {}
      for _, k in ipairs(opts.own_keys or {}) do
        set[k] = true
      end
      return set
    end)(),
  }
  for _, kind in ipairs(ids.KINDS) do
    if want[kind] then
      local ok, err = pcall(READERS[kind], ctx)
      if not ok then
        ctx.notes[#ctx.notes + 1] = ("reading %s entries failed: %s"):format(kind, tostring(err))
      end
    end
  end
  local counts = {}
  for _, e in ipairs(ctx.entries) do
    counts[e.kind] = (counts[e.kind] or 0) + 1
  end
  return {
    version = 1,
    plugin = opts.plugin,
    root = root,
    entries = ctx.entries,
    counts = counts,
    notes = ctx.notes,
  }
end

return M
