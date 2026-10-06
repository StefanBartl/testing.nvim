---@module 'testing.conformance.probe'
---@brief The code that runs INSIDE the child editor of a conformance run: loads the plugin and reports facts.
---@description
--- Every function returns plain data (strings, numbers, booleans, lists, tables of those): the parent
--- receives it over msgpack-rpc and the checks decide what it means. Nothing here judges. The child is a
--- throwaway editor (`testing.rpc`, its own XDG and temp directories, an allowlisted environment), and
--- the functions never raise: a failure is data (`ok = false, err = ...`).
---
--- `begin` takes the baseline of what the editor has before the plugin is touched (keymaps, user
--- commands, autocommands, `_G` keys); `facts` reports what exists NOW and is not in the baseline, plus a
--- signature list per kind (a multiset: two identical autocommands appear twice) that K2 compares after
--- the second `setup()`.
---
--- Keymaps and autocommands are read from the editor itself (`nvim_get_keymap`, `nvim_get_autocmds`), so
--- a mapping made with a raw `vim.keymap.set` counts as much as one made through lib.nvim; the lib.nvim
--- registries (`keymap.registered`, `usercmd.registered`, `autocmd.registered`, `composer.registry`) are
--- read in addition, when lib.nvim is there.

local M = {}

local uv = vim.uv or vim.loop

---Modes `nvim_get_keymap` is asked for.
local MODES = { "n", "v", "x", "s", "o", "i", "c", "t", "l" }

---Autocommand groups of the editor itself (created lazily at any time).
local function own_group(name)
  return type(name) == "string" and (name:sub(1, 5) == "nvim." or name:sub(1, 5) == "nvim_")
end

---@type { keymaps: table<string, table>, commands: table<string, table>, autocmds: table<string, integer>, globals: table<string, boolean>, plugin_files: table[] }|nil
local base

-- =========================================================
-- Reading the editor
-- =========================================================

---@param s any
---@return string
local function str(s)
  if s == nil then
    return ""
  end
  return tostring(s)
end

---Global keymaps (and those of the current buffer), keyed by a signature that includes the right-hand
---side, so a REPLACED mapping is a different key.
---@return table<string, table>
local function read_keymaps()
  local out = {}
  local function add(list, buf)
    for _, e in ipairs(list) do
      local item = {
        mode = str(e.mode),
        lhs = str(e.lhs),
        rhs = e.rhs ~= nil and str(e.rhs) or nil,
        callback = e.callback ~= nil or nil,
        desc = e.desc,
        buffer = buf or nil,
      }
      local key = table.concat({
        item.mode,
        item.lhs,
        tostring(buf or 0),
        str(item.rhs),
        item.callback and "cb" or "",
        str(item.desc),
      }, "\1")
      out[key] = item
    end
  end
  for _, mode in ipairs(MODES) do
    add(vim.api.nvim_get_keymap(mode), nil)
    local ok, list = pcall(vim.api.nvim_buf_get_keymap, 0, mode)
    if ok then
      add(list, vim.api.nvim_get_current_buf())
    end
  end
  return out
end

---@return table<string, table>
local function read_commands()
  local out = {}
  local ok, cmds = pcall(vim.api.nvim_get_commands, { builtin = false })
  if not ok then
    return out
  end
  for name, c in pairs(cmds) do
    out[name] = {
      name = name,
      nargs = str(c.nargs),
      complete = c.complete,
      complete_arg = c.complete_arg,
      bang = c.bang == true,
      range = c.range ~= nil,
      desc = nil,
      definition = c.definition,
    }
  end
  return out
end

---Autocommands as a multiset: signature -> count (and one item per signature).
---@return table<string, integer> counts
---@return table<string, table> items
local function read_autocmds()
  local counts, items = {}, {}
  local ok, list = pcall(vim.api.nvim_get_autocmds, {})
  if not ok then
    return counts, items
  end
  for _, a in ipairs(list) do
    if not own_group(a.group_name) then
      local sig = table.concat({
        str(a.group_name),
        str(a.event),
        str(a.pattern),
        a.buflocal and "buf" or "",
        str(a.command),
        a.callback ~= nil and "cb" or "",
        str(a.desc),
      }, "\1")
      counts[sig] = (counts[sig] or 0) + 1
      items[sig] = {
        group = a.group_name,
        event = a.event,
        pattern = a.pattern,
        desc = a.desc,
        buflocal = a.buflocal or nil,
        callback = a.callback ~= nil or nil,
        command = a.command ~= "" and a.command or nil,
      }
    end
  end
  return counts, items
end

---@return table<string, boolean>
local function read_globals()
  local out = {}
  for k in pairs(_G) do
    out[tostring(k)] = true
  end
  return out
end

-- =========================================================
-- Baseline and facts
-- =========================================================

---A copy that can travel over msgpack: a function or userdata becomes `true` (it is there, the suite
---does not need it), a table is copied, `vim.NIL` becomes nil.
---@param value any
---@param depth? integer
---@return any
local function plain(value, depth)
  depth = depth or 0
  local t = type(value)
  if t == "function" or t == "userdata" or t == "thread" then
    return value == vim.NIL and nil or true
  end
  if t ~= "table" then
    return value
  end
  if depth > 6 then
    return nil
  end
  local out = {}
  for k, v in pairs(value) do
    if type(k) == "string" or type(k) == "number" then
      out[k] = plain(v, depth + 1)
    end
  end
  return out
end

---Take the baseline: what the editor has before the plugin is loaded.
---@return { keymaps: integer, commands: integer, autocmds: integer, globals: integer }
function M.begin()
  local counts = read_autocmds()
  local n = 0
  for _ in pairs(counts) do
    n = n + 1
  end
  base = {
    keymaps = read_keymaps(),
    commands = read_commands(),
    autocmds = counts,
    globals = read_globals(),
    plugin_files = {},
  }
  return {
    keymaps = vim.tbl_count(base.keymaps),
    commands = vim.tbl_count(base.commands),
    autocmds = n,
    globals = vim.tbl_count(base.globals),
  }
end

---Source the `plugin/` files of the repository, in the order the editor would (sorted, literal listing).
---@param root string
---@return { file: string, ok: boolean, err?: string }[]
function M.source_plugin(root)
  local out = {}
  local files = {}
  local function collect(dir, rel)
    local ok, iter = pcall(vim.fs.dir, dir)
    if not ok then
      return
    end
    local entries = {}
    for name, kind in iter do
      entries[#entries + 1] = { name = name, kind = kind }
    end
    table.sort(entries, function(a, b)
      return a.name < b.name
    end)
    for _, e in ipairs(entries) do
      if e.kind == "file" and (e.name:match("%.lua$") or e.name:match("%.vim$")) then
        files[#files + 1] = { abs = dir .. "/" .. e.name, rel = rel .. e.name }
      elseif e.kind == "directory" then
        collect(dir .. "/" .. e.name, rel .. e.name .. "/")
      end
    end
  end
  collect(root .. "/plugin", "plugin/")
  for _, f in ipairs(files) do
    local ok, err = pcall(vim.cmd.source, vim.fn.fnameescape(f.abs))
    out[#out + 1] = { file = f.rel, ok = ok, err = (not ok) and str(err):sub(1, 600) or nil }
  end
  return out
end

---`require(plugin)`, timed.
---@param plugin string
---@return table
function M.load(plugin)
  local t0 = uv.hrtime()
  local ok, mod = pcall(require, plugin)
  local ms = (uv.hrtime() - t0) / 1e6
  local res = { ok = ok, ms = ms }
  if ok then
    -- an aggregate module (`require("lib")`) can raise on an unknown key: reading `setup` is guarded
    local rok, setup = pcall(function()
      return type(mod) == "table" and mod.setup or nil
    end)
    res.has_setup = rok and type(setup) == "function"
  else
    res.err = str(mod):sub(1, 1500)
    res.missing = str(mod):find("module '" .. plugin .. "' not found", 1, true) ~= nil
  end
  return res
end

---`require(plugin).setup(opts)`, timed.
---@param plugin string
---@param opts table|nil
---@return table
function M.setup(plugin, opts)
  local mod = package.loaded[plugin]
  local rok, setup = pcall(function()
    return type(mod) == "table" and mod.setup or nil
  end)
  if not rok or type(setup) ~= "function" then
    return { ok = false, err = "the plugin module has no setup() function", no_setup = true, ms = 0 }
  end
  local t0 = uv.hrtime()
  local ok, err = pcall(setup, opts)
  local ms = (uv.hrtime() - t0) / 1e6
  if ok then
    return { ok = true, ms = ms }
  end
  return { ok = false, err = str(err):sub(1, 1500), ms = ms }
end

---Sorted list of the keys of a set.
---@param set table<string, any>
---@return string[]
local function sorted_keys(set)
  local keys = {}
  for k in pairs(set) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

---What the lib.nvim registries hold, as signature strings (a multiset: repeated entries repeat).
---@return table<string, string[]>|nil
local function registry_sigs()
  local out = { keymaps = {}, usercmds = {}, autocmds = {}, composer = {} }
  local seen_any = false
  local okk, keymap = pcall(require, "lib.nvim.bindings.keymap")
  if okk and type(keymap.registered) == "function" then
    seen_any = true
    local ok, all = pcall(keymap.registered)
    if ok and type(all) == "table" then
      for surface, entries in pairs(all) do
        for _, e in ipairs(entries) do
          local mode = e.mode
          out.keymaps[#out.keymaps + 1] = table.concat({
            surface,
            str(e.name),
            str(e.lhs),
            type(mode) == "table" and table.concat(mode, "") or str(mode),
            e.bound and "bound" or "unbound",
            str(e.desc),
          }, "\1")
        end
      end
    end
  end
  local oku, usercmd = pcall(require, "lib.nvim.bindings.usercmd")
  if oku and type(usercmd.registered) == "function" then
    seen_any = true
    local ok, list = pcall(usercmd.registered)
    if ok and type(list) == "table" then
      for _, r in ipairs(list) do
        out.usercmds[#out.usercmds + 1] = str(r.name) .. "\1" .. str(r.buffer)
      end
    end
  end
  local oka, autocmd = pcall(require, "lib.nvim.bindings.autocmd")
  if oka and type(autocmd.registered) == "function" then
    seen_any = true
    local ok, list = pcall(autocmd.registered)
    if ok and type(list) == "table" then
      for _, r in ipairs(list) do
        local events, pattern = r.events, r.pattern
        out.autocmds[#out.autocmds + 1] = table.concat({
          str(r.group),
          type(events) == "table" and table.concat(events, ",") or str(events),
          type(pattern) == "table" and table.concat(pattern, ",") or str(pattern),
          str(r.desc),
        }, "\1")
      end
    end
  end
  local okc, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  if okc and type(composer.registry) == "function" then
    seen_any = true
    local ok, reg = pcall(composer.registry)
    if ok and type(reg) == "table" then
      for name in pairs(reg) do
        out.composer[#out.composer + 1] = name
      end
    end
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return seen_any and out or nil
end

---What exists now and was not there at `begin`.
---@return table
function M.facts()
  local b = base
  if not b then
    return { err = "begin() was not called" }
  end
  local keymaps, commands = {}, {}
  local cur_k = read_keymaps()
  for _, key in ipairs(sorted_keys(cur_k)) do
    if not b.keymaps[key] then
      keymaps[#keymaps + 1] = cur_k[key]
    end
  end
  local cur_c = read_commands()
  for _, name in ipairs(sorted_keys(cur_c)) do
    if not b.commands[name] or b.commands[name].definition ~= cur_c[name].definition then
      commands[#commands + 1] = cur_c[name]
    end
  end
  local counts, items = read_autocmds()
  local autocmds = {}
  for _, sig in ipairs(sorted_keys(counts)) do
    local extra = counts[sig] - (b.autocmds[sig] or 0)
    if extra > 0 then
      local item = vim.deepcopy(items[sig])
      item.count = extra
      item.sig = sig
      autocmds[#autocmds + 1] = item
    end
  end
  local cur_g = read_globals()
  local globals = {}
  for _, name in ipairs(sorted_keys(cur_g)) do
    if not b.globals[name] then
      globals[#globals + 1] = name
    end
  end

  -- signature lists for the idempotence comparison (K2)
  local sigs = { keymaps = {}, commands = {}, autocmds = {} }
  for _, key in ipairs(sorted_keys(cur_k)) do
    if not b.keymaps[key] then
      sigs.keymaps[#sigs.keymaps + 1] = key
    end
  end
  for _, c in ipairs(commands) do
    sigs.commands[#sigs.commands + 1] = c.name .. "\1" .. str(c.definition)
  end
  for _, a in ipairs(autocmds) do
    for _ = 1, a.count do
      sigs.autocmds[#sigs.autocmds + 1] = a.sig
    end
  end
  return plain({
    keymaps = keymaps,
    commands = commands,
    autocmds = autocmds,
    globals = globals,
    sigs = sigs,
    leader = vim.g.mapleader or "\\",
    registry = registry_sigs(),
  })
end

-- =========================================================
-- Timing, audit, health, docs
-- =========================================================

---Unload the modules of the plugin (the plugin itself and everything below it).
---@param plugin string
local function purge(plugin)
  local prefix = plugin .. "."
  for name in pairs(package.loaded) do
    if name == plugin or name:sub(1, #prefix) == prefix then
      package.loaded[name] = nil
    end
  end
end

---`n` more measurements of `require` + `setup()` after the plugin's modules were unloaded.
---@param plugin string
---@param opts table|nil
---@param n integer
---@return number[] ms
function M.remeasure(plugin, opts, n)
  local out = {}
  for _ = 1, n do
    purge(plugin)
    local t0 = uv.hrtime()
    local ok, mod = pcall(require, plugin)
    local rok, setup = pcall(function()
      return ok and type(mod) == "table" and mod.setup or nil
    end)
    if rok and type(setup) == "function" then
      pcall(setup, opts)
    end
    out[#out + 1] = (uv.hrtime() - t0) / 1e6
  end
  return out
end

---The lib.nvim audits (K5, K12, K13) over what is registered. Unscoped: the child is a clean editor
---that holds this plugin and nothing else (the audits scope by directory name, which is not always
---the name the plugin registers under).
---@return table
function M.audit()
  local res = { lib = false }
  local ok, audit = pcall(require, "lib.nvim.bindings.audit")
  if not ok then
    res.err = str(audit):sub(1, 400)
    return res
  end
  res.lib = true
  local function try(name, fn)
    local fok, value = pcall(fn)
    if fok then
      res[name] = value
    else
      res[name .. "_err"] = str(value):sub(1, 400)
    end
  end
  try("actions", function()
    return audit.keymap_actions()
  end)
  try("routes", function()
    return audit.command_routes()
  end)
  try("gaps", function()
    return audit.gaps()
  end)
  try("key_risks", function()
    local out = {}
    for _, r in ipairs(audit.key_risks()) do
      local keys = {}
      for _, k in ipairs(r.keys) do
        keys[#keys + 1] = { lhs = k.lhs, tier = k.tier, reason = k.reason }
      end
      out[#out + 1] = { surface = r.surface, name = r.name, best = r.best, keys = keys }
    end
    return out
  end)
  try("prefix", function()
    return audit.prefix_ambiguities()
  end)
  try("composer", function()
    local out = {}
    local composer = require("lib.nvim.bindings.usercmd.composer")
    local all = composer.check_all()
    local names = {}
    for name in pairs(all) do
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      for _, r in ipairs(all[name]) do
        out[#out + 1] = {
          verb = name,
          path = table.concat(r.path or {}, " "),
          ok = r.ok == true,
          err = r.err ~= nil and str(r.err):sub(1, 300) or nil,
        }
      end
    end
    return out
  end)
  return res
end

---`:checkhealth <plugin>`: the lines of the report.
---@param plugin string
---@return { ok: boolean, err?: string, lines: string[] }
function M.health(plugin)
  if not plugin:match("^[%w_%.%-]+$") then
    return { ok = false, err = "invalid plugin name", lines = {} }
  end
  local ok, err = pcall(function()
    vim.cmd("checkhealth " .. plugin)
  end)
  local lines = {}
  if ok then
    local gok, got = pcall(vim.api.nvim_buf_get_lines, 0, 0, 500, false)
    if gok then
      lines = got
    end
  end
  return { ok = ok, err = (not ok) and str(err):sub(1, 600) or nil, lines = lines }
end

---Re-render the generated binding pages and compare them with the files (K14). Reads only.
---@param spec { root: string, usercmd_dir?: string, autocmd_dir?: string }
---@return table
function M.docs(spec)
  local res = {}
  if spec.usercmd_dir then
    local ok, mod = pcall(require, "lib.nvim.bindings.usercmd.docs")
    if ok then
      local cok, up, stale = pcall(mod.check, { dir = spec.usercmd_dir, root = spec.root })
      res.usercmd = cok and { up_to_date = up, stale = stale } or { err = str(up):sub(1, 400) }
    else
      res.usercmd = { err = str(mod):sub(1, 400) }
    end
  end
  if spec.autocmd_dir then
    local ok, mod = pcall(require, "lib.nvim.bindings.autocmd.docs")
    if ok then
      local cok, up, stale = pcall(mod.check, { dir = spec.autocmd_dir, root = spec.root })
      res.autocmd = cok and { up_to_date = up, stale = stale } or { err = str(up):sub(1, 400) }
    else
      res.autocmd = { err = str(mod):sub(1, 400) }
    end
  end
  return res
end

-- =========================================================
-- K1: every module on its own
-- =========================================================

---Require every module alone: the cache entries a module added are removed again, so the next one
---starts from the same cache (a module that only works because a sibling was loaded first fails).
---@param modules string[]
---@return table[] results
function M.require_each(modules)
  local out = {}
  for _, m in ipairs(modules) do
    local loaded_before = {}
    for k in pairs(package.loaded) do
      loaded_before[k] = true
    end
    local k0, c0, a0, g0 = read_keymaps(), read_commands(), read_autocmds(), read_globals()
    local ok, err = pcall(require, m)
    local res = { module = m, ok = ok }
    if not ok then
      res.err = str(err):sub(1, 1200)
      local missing = str(err):match("module '([^']+)' not found")
      if missing then
        res.missing = missing
      end
    end
    local k1, c1, a1, g1 = read_keymaps(), read_commands(), read_autocmds(), read_globals()
    local fx = { globals = {}, keymaps = 0, commands = {}, autocmds = 0, autocmd_groups = {} }
    for name in pairs(g1) do
      if not g0[name] then
        fx.globals[#fx.globals + 1] = name
      end
    end
    table.sort(fx.globals)
    for key in pairs(k1) do
      if not k0[key] then
        fx.keymaps = fx.keymaps + 1
      end
    end
    for name in pairs(c1) do
      if not c0[name] then
        fx.commands[#fx.commands + 1] = name
      end
    end
    table.sort(fx.commands)
    for sig, n in pairs(a1) do
      if n > (a0[sig] or 0) then
        fx.autocmds = fx.autocmds + (n - (a0[sig] or 0))
        local group = sig:match("^([^\1]*)") or ""
        fx.autocmd_groups[group] = (fx.autocmd_groups[group] or 0) + (n - (a0[sig] or 0))
      end
    end
    if #fx.globals > 0 or fx.keymaps > 0 or #fx.commands > 0 or fx.autocmds > 0 then
      res.effects = fx
    end
    -- only the modules of the plugin's own tree are forgotten: a dependency stays cached (speed)
    local root_name = m:match("^[^.]+")
    for k in pairs(package.loaded) do
      if
        not loaded_before[k] and (k == root_name or k:sub(1, #root_name + 1) == root_name .. ".")
      then
        package.loaded[k] = nil
      end
    end
    out[#out + 1] = res
  end
  return out
end

return M
