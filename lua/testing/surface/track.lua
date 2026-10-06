---@module 'testing.surface.track'
---@brief Runtime tracking of which keymaps, commands and autocmds a spec run EXERCISED: an installable layer in the style of `testing.guard`.
---@description
--- ```lua
--- local track = require("testing.surface.track")
--- local h = track.install({ api = { "myplugin" } })     -- patch the creation primitives, wrap what exists
--- h:begin_case({ id = "a_spec.lua::x::y", file = "a_spec.lua" })
--- -- ... the spec runs; every handler that fires is counted ...
--- local res = h:end_case()    -- { hit = { "binding:<leader>sa", ... }, counts = { [id] = n } }
--- local run = h:collect()     -- { hit, counts, wrapped, cases, notes } over everything so far
--- h:uninstall()               -- primitives and handlers put back; returns what could not be
--- ```
---
--- HOW. Handlers are wrapped when they are CREATED: `nvim_set_keymap` / `nvim_buf_set_keymap` (a Lua
--- `callback`), `nvim_create_user_command` / `nvim_buf_create_user_command` (a Lua function),
--- `nvim_create_autocmd` (a Lua `callback`) and the composer registry of lib.nvim (the `run` of every
--- route and the `default` of a verb). `vim.keymap.set`, `lib.nvim.bindings.*` and the plugin's own
--- wrappers all end in those primitives, so one layer sees them. Keymaps that exist at install time
--- are re-set with a wrapped callback (same options); commands and autocmds that exist at install time
--- cannot be wrapped without recreating them and are reported as untracked: install this layer
--- BEFORE the plugin's `setup()` runs (the project's minit comes after it in a child, see
--- `docs/SURFACE.md`). A wrapper is transparent: it counts, then returns what the original returns
--- (`expr` mappings, `true` from an autocmd callback that deletes itself). It does nothing once
--- uninstalled.
---
--- RESTORE. `uninstall()` puts the primitives back, restores the original callback of every keymap and
--- command whose live definition is still our wrapper, and restores the composer routes. An autocmd
--- callback cannot be swapped in place without changing the autocmd's id and order, so a wrapped
--- autocmd keeps its (then inert) wrapper; it is named in `notes`.
---
--- IDS. Hits are resolved to the ids of `testing.surface.ids` through the registries of lib.nvim
--- (so `binding:<leader>sa@nx` is the same entry the reader lists) with a raw fallback
--- (`binding:<lhs>`, `command:<name>`, `autocmd:<group>:<event>`).
---
--- HONEST LIMITS. A handler reached through a saved reference to the original (an alias captured
--- before the install) is counted when it is the wrapper, not when it is the original; keymaps with a
--- string rhs and commands given as a string are not tracked; a buffer-local keymap that a plugin
--- sets on `FileType` exists only when a spec opens such a buffer; nothing is attributed to the plugin
--- here (everything is counted, `testing.surface.coverage` keeps what is in the plugin's surface).

local ids = require("testing.surface.ids")
local patch = require("testing.guard.patch")

local M = {}

-- The sink is the runner's own bookkeeping, not an effect of the spec: it is written through the
-- `io.open` of the time this module loaded (before the guards of a run wrap it), so the fs guard never
-- sees it. Load this module from the minit, ahead of the guard layer.
local raw_open = io.open

---Most distinct handlers one handle keeps track of (a runaway spec must not grow without bound).
M.MAX_KEYS = 5000

---wrapper -> original, for every wrapper this module ever made (never wrapped twice).
---@type table<function, function>
local WRAPPERS = setmetatable({}, { __mode = "k" })

---The function behind a wrapper of this layer (the function itself when it is none). The reader uses
---it, so a surface read in an editor that is being tracked still names the plugin's own handlers.
---@param f any
---@return any
function M.unwrap(f)
  local seen = 0
  while type(f) == "function" and WRAPPERS[f] ~= nil and seen < 8 do
    f = WRAPPERS[f]
    seen = seen + 1
  end
  return f
end

---@class Testing.Surface.TrackCfg
---@field api? string[] Module names whose function fields are wrapped (when loaded) at every `begin_case`.
---@field rewrap? boolean Re-set the Lua keymaps that exist at install time with a wrapped callback (default true).
---@field sink? string File that receives one JSON line per case (and a `run` line on `flush`).

---@class Testing.Surface.TrackHandle
---@field cfg Testing.Surface.TrackCfg
---@field installed boolean
---@field patcher Testing.Guard.Patcher
---@field raw table<string, table> key -> what the handler is
---@field wrapped table<string, true> keys of handlers that carry a wrapper
---@field run_hits table<string, integer>
---@field case? { ctx: table, hits: table<string, integer> }
---@field cases { id?: string, file?: string, hit: string[], counts: table<string, integer> }[]
---@field made table[] what has to be restored
---@field notes string[]
---@field nkeys integer
---@field overflow? boolean
---@field last_buffer? integer
---@field existing? { commands: integer, autocmds: integer }
---@field orig_set_keymap? function
---@field orig_buf_set_keymap? function
---@field orig_create_command? function
---@field orig_buf_create_command? function
local Handle = {}
Handle.__index = Handle

---@param t table
---@return table
local function shallow(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

---@param h Testing.Surface.TrackHandle
---@param key string
---@param desc table
---@return boolean
local function register(h, key, desc)
  if h.raw[key] == nil then
    if h.nkeys >= M.MAX_KEYS then
      if not h.overflow then
        h.overflow = true
        h.notes[#h.notes + 1] = ("more than %d distinct handlers: the rest is not tracked"):format(
          M.MAX_KEYS
        )
      end
      return false
    end
    h.raw[key] = desc
    h.nkeys = h.nkeys + 1
  end
  h.wrapped[key] = true
  return true
end

---Count one execution of the handler `key`.
---@param key string
function Handle:hit(key)
  self.run_hits[key] = (self.run_hits[key] or 0) + 1
  local c = self.case
  if c then
    c.hits[key] = (c.hits[key] or 0) + 1
  end
end

---A counting wrapper around `orig`.
---@param h Testing.Surface.TrackHandle
---@param key string|fun(): string|nil
---@param orig function
---@return function
local function wrap_fn(h, key, orig)
  local wrapper
  wrapper = function(...)
    if h.installed then
      local k
      if type(key) == "function" then
        k = key()
      else
        k = key
      end
      if k then
        h:hit(k)
      end
    end
    return orig(...)
  end
  WRAPPERS[wrapper] = orig
  return wrapper
end

-- ===========================================================
-- creation primitives
-- ===========================================================

---Was this handler written by a spec (or any file of a test tree) rather than by the plugin? A spec that
---replaces `<leader>a` with its own function must not make the key look exercised: the plugin's handler never
---ran. The test is where the function was DEFINED: a `_spec.lua` file, or a `TESTS`/`tests`/`spec` directory.
---@param fn function
---@return boolean
local function foreign_handler(fn)
  local info = debug.getinfo(fn, "S")
  local src = info and info.source or ""
  if src:sub(1, 1) ~= "@" then
    return false
  end
  src = src:gsub("\\", "/")
  return src:find("_spec%.lua$") ~= nil
    or src:find("/TESTS/", 1, true) ~= nil
    or src:find("/tests/", 1, true) ~= nil
    or src:find("/spec/", 1, true) ~= nil
end

---Buffer handle 0 means "the current one": the real number is what a later restore needs.
---@param buffer any
---@return any
local function real_buf(buffer)
  if buffer == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return buffer
end

---@param h Testing.Surface.TrackHandle
---@param mode string
---@param lhs any
---@param buffer boolean
---@param opts any
---@param orig_cb function
---@return function|nil wrapper
local function wrap_keymap(h, mode, lhs, buffer, opts, orig_cb)
  if type(lhs) ~= "string" or WRAPPERS[orig_cb] or foreign_handler(orig_cb) then
    return nil
  end
  local key = ("k|%s|%s|%s"):format(mode, ids.norm_lhs(lhs), buffer and "b" or "g")
  if not register(h, key, { kind = "binding", mode = mode, lhs = lhs, buffer = buffer }) then
    return nil
  end
  local wrapper = wrap_fn(h, key, orig_cb)
  if #h.made < M.MAX_KEYS then
    h.made[#h.made + 1] = {
      kind = "keymap",
      mode = mode,
      lhs = lhs,
      buffer = buffer and h.last_buffer or nil,
      opts = opts,
      orig = orig_cb,
      wrapper = wrapper,
    }
  end
  return wrapper
end

---@param h Testing.Surface.TrackHandle
local function patch_keymaps(h)
  local p = h.patcher
  h.orig_set_keymap = p:wrap(vim.api, "nvim_set_keymap", function(orig)
    return function(mode, lhs, rhs, opts)
      if type(opts) == "table" and type(opts.callback) == "function" and h.installed then
        local wrapper = wrap_keymap(h, tostring(mode), lhs, false, shallow(opts), opts.callback)
        if wrapper then
          opts = shallow(opts)
          opts.callback = wrapper
        end
      end
      return orig(mode, lhs, rhs, opts)
    end
  end, "vim.api.nvim_set_keymap")
  h.orig_buf_set_keymap = p:wrap(vim.api, "nvim_buf_set_keymap", function(orig)
    return function(buffer, mode, lhs, rhs, opts)
      if type(opts) == "table" and type(opts.callback) == "function" and h.installed then
        h.last_buffer = real_buf(buffer)
        local wrapper = wrap_keymap(h, tostring(mode), lhs, true, shallow(opts), opts.callback)
        if wrapper then
          opts = shallow(opts)
          opts.callback = wrapper
        end
      end
      return orig(buffer, mode, lhs, rhs, opts)
    end
  end, "vim.api.nvim_buf_set_keymap")
end

---@param h Testing.Surface.TrackHandle
---@param name any
---@param command any
---@param opts any
---@param buffer? integer
---@return function|nil
local function wrap_command(h, name, command, opts, buffer)
  if
    type(name) ~= "string"
    or type(command) ~= "function"
    or WRAPPERS[command]
    or foreign_handler(command)
  then
    return nil
  end
  local key = "c|" .. name
  if not register(h, key, { kind = "command", id = ids.command(name), cmd = name }) then
    return nil
  end
  local wrapper = wrap_fn(h, key, command)
  if #h.made < M.MAX_KEYS then
    h.made[#h.made + 1] = {
      kind = "command",
      name = name,
      buffer = buffer,
      opts = type(opts) == "table" and shallow(opts) or {},
      orig = command,
      wrapper = wrapper,
    }
  end
  return wrapper
end

---@param h Testing.Surface.TrackHandle
local function patch_commands(h)
  local p = h.patcher
  h.orig_create_command = p:wrap(vim.api, "nvim_create_user_command", function(orig)
    return function(name, command, opts)
      if h.installed then
        command = wrap_command(h, name, command, opts) or command
      end
      return orig(name, command, opts)
    end
  end, "vim.api.nvim_create_user_command")
  h.orig_buf_create_command = p:wrap(vim.api, "nvim_buf_create_user_command", function(orig)
    return function(buffer, name, command, opts)
      if h.installed then
        command = wrap_command(h, name, command, opts, real_buf(buffer)) or command
      end
      return orig(buffer, name, command, opts)
    end
  end, "vim.api.nvim_buf_create_user_command")
end

---@param h Testing.Surface.TrackHandle
local function patch_autocmds(h)
  h.patcher:wrap(vim.api, "nvim_create_autocmd", function(orig)
    return function(event, opts)
      if
        not (h.installed and type(opts) == "table" and type(opts.callback) == "function")
        or WRAPPERS[opts.callback]
        or foreign_handler(opts.callback)
      then
        return orig(event, opts)
      end
      local cell = {}
      local user_cb = opts.callback
      local wrapper = wrap_fn(h, function()
        return cell.key
      end, user_cb)
      local o = shallow(opts)
      o.callback = wrapper
      local id = orig(event, o)
      if type(id) == "number" then
        cell.key = "a|" .. id
        -- the NAME of the group, now: `nvim_create_augroup(name, { clear = true })` later empties it, and a
        -- group that holds no autocommand any more has no name to ask for
        local gname = opts.group
        if type(gname) == "number" then
          local gok, got = pcall(vim.api.nvim_get_autocmds, { group = gname })
          gname = nil
          if gok then
            for _, a in ipairs(got) do
              if a.id == id then
                gname = a.group_name
                break
              end
            end
          end
        end
        local made_ok = register(h, cell.key, {
          kind = "autocmd",
          id = id,
          event = event,
          group = gname,
          pattern = opts.pattern,
          buffer = opts.buffer,
        })
        if not made_ok then
          cell.key = nil
        end
      end
      return id
    end
  end, "vim.api.nvim_create_autocmd")
end

-- ===========================================================
-- composer routes
-- ===========================================================

---Wrap the route handlers and the default of a composer verb.
---@param h Testing.Surface.TrackHandle
---@param name string
---@param handle any
local function wrap_verb(h, name, handle)
  local ok, spec = pcall(function()
    return handle:spec()
  end)
  if not ok or type(spec) ~= "table" then
    return
  end
  ---@param holder table
  ---@param field string
  ---@param path string[]
  ---@param resolve boolean the value may be a module path (route.run)
  local function wrap_slot(holder, field, path, resolve)
    local orig = holder[field]
    if orig == nil or WRAPPERS[orig] then
      return
    end
    local key = ("r|%s|%s"):format(name, table.concat(path, " "))
    if not register(h, key, { kind = "command", id = ids.route(name, path) }) then
      return
    end
    local inner = orig
    if resolve and type(orig) ~= "function" then
      inner = function(ctx)
        local parse = require("lib.nvim.bindings.usercmd.composer.parse")
        local f, err = parse.resolve_run(orig)
        if not f then
          error(err, 0)
        end
        return f(ctx)
      end
    elseif type(orig) ~= "function" then
      return
    end
    local wrapper = wrap_fn(h, key, inner)
    WRAPPERS[wrapper] = orig
    holder[field] = wrapper
    h.made[#h.made + 1] =
      { kind = "slot", holder = holder, field = field, orig = orig, wrapper = wrapper }
  end
  for _, route in ipairs(spec.routes or {}) do
    wrap_slot(route, "run", route.path or {}, true)
  end
  wrap_slot(spec, "default", {}, false)
end

---@param h Testing.Surface.TrackHandle
local function patch_composer(h)
  local ok, registry = pcall(require, "lib.nvim.bindings.usercmd.composer.registry")
  if not ok or type(registry) ~= "table" then
    return
  end
  h.patcher:wrap(registry, "add", function(orig)
    return function(name, handle)
      if h.installed then
        local wok, werr = pcall(wrap_verb, h, name, handle)
        if not wok then
          h.notes[#h.notes + 1] = ("composer verb %s could not be tracked: %s"):format(
            tostring(name),
            tostring(werr)
          )
        end
      end
      return orig(name, handle)
    end
  end, "composer.registry.add")
  for name, handle in pairs(registry.map()) do
    local wok, werr = pcall(wrap_verb, h, name, handle)
    if not wok then
      h.notes[#h.notes + 1] = ("composer verb %s could not be tracked: %s"):format(
        tostring(name),
        tostring(werr)
      )
    end
  end
end

-- ===========================================================
-- what exists at install time
-- ===========================================================

---The directory of testing.nvim's own Lua modules (what the runner defines is no business of the plugin).
local SELF_LUA = (function()
  local src = debug.getinfo(1, "S").source
  local dir = src:sub(1, 1) == "@"
    and src:sub(2):gsub("\\", "/"):match("^(.*/testing)/surface/[^/]*$")
  return dir and (dir:lower() .. "/") or nil
end)()

---Is `f` defined in Neovim's own runtime or in testing.nvim itself (their default mappings, autocmds and
---commands are none of our business)?
---@param f function
---@return boolean
local function in_runtime(f)
  local info = debug.getinfo(f, "S")
  local src = info and info.source or ""
  if src:sub(1, 1) ~= "@" then
    return false
  end
  local a = src:sub(2):gsub("\\", "/"):lower()
  if a:sub(1, 4) == "vim/" then
    -- the editor's own defaults (`@vim/_core/defaults.lua`): not a file on the disk
    return true
  end
  if SELF_LUA and a:sub(1, #SELF_LUA) == SELF_LUA then
    return true
  end
  local rt = vim.env.VIMRUNTIME
  if type(rt) ~= "string" or rt == "" then
    return false
  end
  local b = rt:gsub("\\", "/"):lower()
  return a:sub(1, #b) == b
end

---@param h Testing.Surface.TrackHandle
local function rewrap_keymaps(h)
  local skipped = 0
  local function each(maps, buffer)
    for _, m in ipairs(maps) do
      if
        type(m.callback) == "function"
        and not WRAPPERS[m.callback]
        and not in_runtime(m.callback)
      then
        local mode = m.mode
        if type(mode) == "string" and #mode == 1 and mode:match("[nvxsoilct!]") or mode == " " then
          local opts = {
            callback = m.callback,
            desc = m.desc,
            expr = m.expr == 1,
            noremap = m.noremap == 1,
            nowait = m.nowait == 1,
            silent = m.silent == 1,
            script = m.script == 1,
            replace_keycodes = (m.replace_keycodes == 1) or nil,
          }
          if mode == " " then
            mode = ""
          end
          local ok
          if buffer then
            h.last_buffer = buffer
            ok = pcall(vim.api.nvim_buf_set_keymap, buffer, mode, m.lhs, "", opts)
          else
            ok = pcall(vim.api.nvim_set_keymap, mode, m.lhs, "", opts)
          end
          if not ok then
            skipped = skipped + 1
          end
        else
          skipped = skipped + 1
        end
      end
    end
  end
  for _, mode in ipairs({ "n", "i", "v", "x", "s", "o", "c", "t", "l" }) do
    local ok, maps = pcall(vim.api.nvim_get_keymap, mode)
    if ok then
      each(maps, nil)
    end
    local cur = vim.api.nvim_get_current_buf()
    local okb, bmaps = pcall(vim.api.nvim_buf_get_keymap, cur, mode)
    if okb then
      each(bmaps, cur)
    end
  end
  if skipped > 0 then
    h.notes[#h.notes + 1] = ("%d keymap(s) that exist at install time could not be wrapped"):format(
      skipped
    )
  end
end

---Count what exists and cannot be wrapped (so the report can say "untracked", never "missing").
---@param h Testing.Surface.TrackHandle
local function note_existing(h)
  local ok, cmds = pcall(vim.api.nvim_get_commands, {})
  local n = 0
  if ok then
    for name, c in pairs(cmds) do
      if
        type(c) == "table"
        and type(c.callback) == "function"
        and not WRAPPERS[c.callback]
        and not in_runtime(c.callback)
        -- testing.nvim's own command (plugin/testing.lua goes through lib.nvim's wrapper)
        and name ~= "Testing"
      then
        n = n + 1
      end
    end
  end
  local oka, auts = pcall(vim.api.nvim_get_autocmds, {})
  local m = 0
  if oka then
    for _, a in ipairs(auts) do
      if
        type(a.callback) == "function"
        and not WRAPPERS[a.callback]
        and not in_runtime(a.callback)
      then
        m = m + 1
      end
    end
  end
  h.existing = { commands = n, autocmds = m }
end

-- ===========================================================
-- install / uninstall
-- ===========================================================

---Install the layer. Install it BEFORE the plugin's `setup()`.
---@param cfg? Testing.Surface.TrackCfg
---@return Testing.Surface.TrackHandle
function M.install(cfg)
  cfg = cfg or {}
  ---@type Testing.Surface.TrackHandle
  local h = setmetatable({
    cfg = cfg,
    installed = true,
    patcher = patch.new(),
    raw = {},
    wrapped = {},
    run_hits = {},
    cases = {},
    made = {},
    notes = {},
    nkeys = 0,
  }, Handle)
  local ok, err = pcall(function()
    note_existing(h)
    patch_keymaps(h)
    patch_commands(h)
    patch_autocmds(h)
    patch_composer(h)
    if cfg.rewrap ~= false then
      rewrap_keymaps(h)
    end
  end)
  if not ok then
    pcall(h.uninstall, h)
    error("testing.surface.track: install failed: " .. tostring(err), 0)
  end
  if h.existing and (h.existing.commands > 0 or h.existing.autocmds > 0) then
    h.notes[#h.notes + 1] = ("%d command(s) and %d autocmd(s) exist already and cannot be tracked (install before setup())"):format(
      h.existing.commands,
      h.existing.autocmds
    )
  end
  return h
end

---Wrap the function fields of the configured modules that are loaded (idempotent).
function Handle:wrap_api()
  for _, name in ipairs(self.cfg.api or {}) do
    local mod = package.loaded[name]
    if type(mod) == "table" then
      local keys = {}
      for k, v in pairs(mod) do
        if
          type(k) == "string"
          and type(v) == "function"
          and k:sub(1, 1) ~= "_"
          and not WRAPPERS[v]
        then
          keys[#keys + 1] = k
        end
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local orig = rawget(mod, k)
        local key = ("f|%s.%s"):format(name, k)
        if orig and register(self, key, { kind = "api", id = ids.api(name, k) }) then
          local wrapper = wrap_fn(self, key, orig)
          local ok = pcall(rawset, mod, k, wrapper)
          if ok then
            self.made[#self.made + 1] =
              { kind = "slot", holder = mod, field = k, orig = orig, wrapper = wrapper }
          end
        end
      end
    end
  end
end

---Open the window of a case.
---@param ctx? { id?: string, file?: string }
function Handle:begin_case(ctx)
  if not self.installed then
    return
  end
  self:wrap_api()
  self.case = { ctx = ctx or {}, hits = {} }
end

-- ===========================================================
-- resolving raw keys to ids
-- ===========================================================

---Index of the lib.nvim keymap registry by normalized lhs (one pass per resolve).
---@return table<string, table[]>
local function keymap_index()
  local index = {}
  local ok, km = pcall(require, "lib.nvim.bindings.keymap")
  if not ok or type(km) ~= "table" then
    return index
  end
  local okr, all = pcall(km.registered)
  if not okr or type(all) ~= "table" then
    return index
  end
  for _, list in pairs(all) do
    for _, e in ipairs(list) do
      if e.lhs then
        local k = ids.norm_lhs(e.lhs)
        index[k] = index[k] or {}
        index[k][#index[k] + 1] = e
      end
    end
  end
  return index
end

---@return table<integer, string>
local function autocmd_index()
  local out = {}
  local ok, ac = pcall(require, "lib.nvim.bindings.autocmd")
  if not ok or type(ac) ~= "table" then
    return out
  end
  local okr, records = pcall(ac.registered)
  if not okr then
    return out
  end
  local list = ids.autocmd_ids(records)
  for i, r in ipairs(records) do
    out[r.id] = list[i]
  end
  return out
end

---@param group any
---@return string|nil
local function group_name(group)
  if type(group) == "string" then
    return group
  end
  if type(group) == "number" then
    local ok, got = pcall(vim.api.nvim_get_autocmds, { group = group })
    if ok and got[1] then
      local name = got[1].group_name
      return type(name) == "string" and name or nil
    end
  end
  return nil
end

---The ids a raw handler stands for.
---@param desc table
---@param ctx table lazily built indexes
---@return string[]
local function resolve(desc, ctx)
  if desc.kind == "binding" then
    ctx.km = ctx.km or keymap_index()
    local modes = ids.mode_list(desc.mode)
    local out, seen = {}, {}
    for _, e in ipairs(ctx.km[ids.norm_lhs(desc.lhs)] or {}) do
      local emodes = ids.mode_list(e.mode)
      local hit = false
      for _, m in ipairs(modes) do
        if vim.tbl_contains(emodes, m) then
          hit = true
        end
      end
      if hit then
        local id = ids.binding(e.lhs, emodes)
        if not seen[id] then
          seen[id] = true
          out[#out + 1] = id
        end
        if not e.direct and e.name then
          local alias = ids.action(e.plugin or "?", e.name)
          if not seen[alias] then
            seen[alias] = true
            out[#out + 1] = alias
          end
        end
      end
    end
    if #out == 0 then
      out[1] = ids.binding(ids.readable_lhs(desc.lhs), modes)
    end
    return out
  elseif desc.kind == "autocmd" then
    ctx.ac = ctx.ac or autocmd_index()
    if ctx.ac[desc.id] then
      return { ctx.ac[desc.id] }
    end
    -- one id per event: the surface lists an autocommand per event (the editor does), not per call
    local ev = type(desc.event) == "table" and desc.event or { desc.event }
    local group = group_name(desc.group)
    local out = {}
    for _, e in ipairs(ev) do
      out[#out + 1] = ids.autocmd_base(group, { e }, desc.pattern, desc.buffer)
    end
    return out
  end
  if desc.cmd then
    -- a composer verb is tracked per route; the command behind it is not an entry of its own
    local ok, reg = pcall(require, "lib.nvim.bindings.usercmd.composer.registry")
    if ok and type(reg) == "table" and reg.get(desc.cmd) then
      return {}
    end
  end
  return { desc.id }
end

---@param self Testing.Surface.TrackHandle
---@param hits table<string, integer>
---@return table<string, integer> counts by id
local function to_counts(self, hits)
  local counts, ctx = {}, {}
  for key, n in pairs(hits) do
    local desc = self.raw[key]
    if desc then
      for _, id in ipairs(resolve(desc, ctx)) do
        counts[id] = (counts[id] or 0) + n
      end
    end
  end
  return counts
end

---@param counts table<string, integer>
---@return string[]
local function sorted_ids(counts)
  local list = vim.tbl_keys(counts)
  table.sort(list)
  return list
end

---@param path string|nil
---@param record table
---@return boolean
local function sink_write(path, record)
  if type(path) ~= "string" or path == "" then
    return false
  end
  local ok, line = pcall(vim.json.encode, record)
  if not ok then
    return false
  end
  local f = raw_open(path, "ab")
  if not f then
    return false
  end
  f:write(line, "\n")
  f:close()
  return true
end

---Close the window of the open case.
---@return { hit: string[], counts: table<string, integer> }
function Handle:end_case()
  local c = self.case
  self.case = nil
  if not c then
    return { hit = {}, counts = {} }
  end
  local counts = to_counts(self, c.hits)
  local rec = {
    id = c.ctx.id,
    file = c.ctx.file,
    hit = sorted_ids(counts),
    counts = counts,
  }
  if #self.cases < 20000 then
    self.cases[#self.cases + 1] = rec
  end
  sink_write(self.cfg.sink, {
    k = "case",
    id = rec.id,
    file = rec.file,
    hit = rec.hit,
    counts = rec.counts,
  })
  return { hit = rec.hit, counts = counts }
end

---Everything seen since install.
---@return { hit: string[], counts: table<string, integer>, wrapped: string[], cases: table[], notes: string[] }
function Handle:collect()
  local counts = to_counts(self, self.run_hits)
  local wrapped_set, ctx = {}, {}
  for key in pairs(self.wrapped) do
    for _, id in ipairs(resolve(self.raw[key], ctx)) do
      wrapped_set[id] = true
    end
  end
  local wrapped = vim.tbl_keys(wrapped_set)
  table.sort(wrapped)
  return {
    hit = sorted_ids(counts),
    counts = counts,
    wrapped = wrapped,
    cases = vim.list_slice(self.cases, 1, #self.cases),
    notes = vim.list_slice(self.notes, 1, #self.notes),
  }
end

---Append a `run` line (hits and wrapped handlers of the whole editor) to the sink.
---@param file? string The spec file (a script has no case windows: its hits belong to the file)
function Handle:flush(file)
  local run = self:collect()
  local total = 0
  for _, n in pairs(self.run_hits) do
    total = total + n
  end
  if self.flushed == total .. ":" .. self.nkeys then
    return
  end
  self.flushed = total .. ":" .. self.nkeys
  sink_write(self.cfg.sink, {
    k = "run",
    file = file,
    hit = run.hit,
    counts = run.counts,
    wrapped = run.wrapped,
    existing = self.existing,
    notes = run.notes,
  })
end

---Undo everything. Idempotent.
---@return string[] unrestored labels of what could not be put back
function Handle:uninstall()
  if not self.installed then
    return self.patcher.unrestored
  end
  local unrestored = self.patcher.unrestored
  local set = self.orig_set_keymap or vim.api.nvim_set_keymap
  local bset = self.orig_buf_set_keymap or vim.api.nvim_buf_set_keymap
  local create_cmd = self.orig_create_command or vim.api.nvim_create_user_command
  local bcreate = self.orig_buf_create_command or vim.api.nvim_buf_create_user_command
  for i = #self.made, 1, -1 do
    local m = self.made[i]
    local ok, err = pcall(function()
      if m.kind == "slot" then
        if rawget(m.holder, m.field) == m.wrapper then
          rawset(m.holder, m.field, m.orig)
        end
      elseif m.kind == "keymap" then
        local opts = shallow(m.opts)
        opts.callback = m.orig
        -- `unique = true` refuses to replace the mapping that is there: the wrapper IS that mapping
        opts.unique = nil
        if m.buffer then
          if vim.api.nvim_buf_is_valid(m.buffer) then
            local cur = vim.api.nvim_buf_call(m.buffer, function()
              return vim.fn.maparg(m.lhs, m.mode == "" and " " or m.mode, false, true)
            end)
            if type(cur) == "table" and cur.callback == m.wrapper then
              bset(m.buffer, m.mode, m.lhs, "", opts)
            end
          end
        else
          local cur = vim.fn.maparg(m.lhs, m.mode == "" and " " or m.mode, false, true)
          if type(cur) == "table" and cur.callback == m.wrapper then
            set(m.mode, m.lhs, "", opts)
          end
        end
      elseif m.kind == "command" then
        local live
        if m.buffer then
          if vim.api.nvim_buf_is_valid(m.buffer) then
            live = vim.api.nvim_buf_get_commands(m.buffer, {})[m.name]
          end
        else
          live = vim.api.nvim_get_commands({})[m.name]
        end
        if type(live) == "table" and live.callback == m.wrapper then
          local opts = m.opts
          opts.force = true
          if m.buffer then
            bcreate(m.buffer, m.name, m.orig, opts)
          else
            create_cmd(m.name, m.orig, opts)
          end
        end
      end
    end)
    if not ok then
      unrestored[#unrestored + 1] = ("%s %s could not be restored: %s"):format(
        m.kind,
        tostring(m.name or m.lhs or m.field),
        tostring(err)
      )
    end
    self.made[i] = nil
  end
  self.installed = false
  local rok, rerr = pcall(self.patcher.restore, self.patcher)
  if not rok then
    unrestored[#unrestored + 1] = "restoring the patches failed: " .. tostring(rerr)
  end
  return unrestored
end

-- ===========================================================
-- connection to the runner (until it calls the layer itself)
-- ===========================================================

---Install the layer in the editor of a spec file and connect it to the runner's case windows: every
---`testing.run.guards` window (`Session:open` / `Session:close`) opens and closes a tracked case, the
---records go to `opts.sink` (JSON lines) and a `run` line is written when the editor ends (also when a
---self-running script calls `os.exit`). For the minit of a child (the layer goes in BEFORE the plugin's
---`setup()`), until the runner owns this (docs/SURFACE.md).
---@param opts? Testing.Surface.TrackCfg
---@return Testing.Surface.TrackHandle
function M.hook_runner(opts)
  opts = opts or {}
  local holder = {}
  local function file_of_script()
    local a = rawget(_G, "arg")
    return type(a) == "table" and type(a[0]) == "string" and a[0] or nil
  end
  -- before the install, so the layer does not wrap its own exit hook
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if holder.h and holder.h.installed then
        holder.h:flush(file_of_script())
      end
    end,
  })
  local h = M.install(opts)
  holder.h = h
  local guards = require("testing.run.guards")
  local class = getmetatable(guards.install(nil)).__index
  h.patcher:wrap(class, "open", function(orig)
    return function(self, ctx, o)
      if h.installed and not h.case then
        h:begin_case(ctx)
      end
      return orig(self, ctx, o)
    end
  end, "testing.run.guards Session:open")
  h.patcher:wrap(class, "close", function(orig)
    return function(self, ...)
      if h.installed and h.case then
        -- the runner takes it with `guards.attach_surface` and puts it into the case
        self.surface_result = h:end_case()
      end
      return orig(self, ...)
    end
  end, "testing.run.guards Session:close")
  h.patcher:wrap(os, "exit", function(orig)
    return function(...)
      if h.installed then
        pcall(h.flush, h, file_of_script())
      end
      return orig(...)
    end
  end, "os.exit")
  return h
end

return M
