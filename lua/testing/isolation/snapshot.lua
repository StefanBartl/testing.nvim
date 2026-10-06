---@module 'testing.isolation.snapshot'
---@brief The internal state backend of the soft isolation: capture, diff, restore.
---@description
--- A backend is three functions with the shapes below; `testing.isolation` uses this one unless the
--- guard layer offers its own (see `testing.isolation` for the seam):
---
---   capture(opts)               -> snapshot   a plain table, nothing live (no handles to the editor)
---   diff(before, after, opts)   -> entries    what `after` has that `before` has not (or has differently)
---   verify is `diff` again: the caller captures once more after `restore` and diffs against `before`.
---
--- WHAT IS COVERED (and, deliberately, nothing else; the module list is the limit of the claim)
---   package      package.loaded entries (added / replaced / removed), except the keep list
---   preload      package.preload entries (added / replaced / removed)
---   global       `_G` entries, by identity (a table that is mutated in place is NOT detected)
---   vim.g        global variables (deep comparison; function values are ignored)
---   option       global-scoped options
---   env          the process environment
---   cwd          the working directory
---   buffer / window / tab    the ids that exist
---   command      global user commands
---   autocmd      autocommands (by id; a Vimscript autocmd without id is reported, not restorable)
---   keymap       global mappings of the modes n i x s o c t l
---
--- NOT covered: highlights, signs, extmark namespaces, registers, marks, quickfix and location lists,
--- jumplists, buffer- and window-local options, timers and other libuv handles, LSP clients,
--- `vim.diagnostic` state, tables mutated in place. A leak of those survives the restore silently:
--- soft isolation is a best effort, `--isolated=file` is the exact one.
---
--- Every diff entry knows how to undo itself (`restore`, nil when it cannot be undone). The caller
--- never trusts a restore: it captures again and reports whatever is still different.

local M = {}

local is_windows = vim.fn.has("win32") == 1

---Name prefixes that are never unloaded: the editor's own modules, the Lua runtime, this tool and its
---library. Everything else that was loaded DURING a file is the file's.
---@type string[]
M.KEEP_PREFIXES = { "vim", "jit", "testing", "lib", "ffi", "bit", "luv", "uv", "libluv", "string" }

---@type table<string, true>
local KEEP_EXACT = {
  _G = true,
  package = true,
  table = true,
  math = true,
  os = true,
  io = true,
  debug = true,
  coroutine = true,
  utf8 = true,
}

---Is a module name protected from unloading?
---@param name any
---@param extra? string[] `soft_keep` of the project: exact names or `prefix*`.
---@param prefixes? string[] Replaces `M.KEEP_PREFIXES` (the warm pool unloads `lib.*` too).
---@return boolean
function M.is_kept(name, extra, prefixes)
  if type(name) ~= "string" then
    return true -- a non-string key is not a module name; never touch it
  end
  if KEEP_EXACT[name] then
    return true
  end
  for _, prefix in ipairs(prefixes or M.KEEP_PREFIXES) do
    if name == prefix or name:sub(1, #prefix + 1) == prefix .. "." then
      return true
    end
  end
  for _, pat in ipairs(extra or {}) do
    if pat:sub(-1) == "*" then
      if name:sub(1, #pat - 1) == pat:sub(1, -2) then
        return true
      end
    elseif name == pat then
      return true
    end
  end
  return false
end

---@class Testing.Isolation.Entry
---@field kind string package|preload|global|vim.g|option|env|cwd|buffer|window|tab|command|autocmd|keymap
---@field change "added"|"changed"|"removed"
---@field key string Stable identity (the same leak has the same key before and after a restore).
---@field name string What a human reads: "autocmd BufEnter in group `Leak`".
---@field restore? fun(): boolean, string|nil Undo it; nil = it cannot be undone.
---@field why? string Why it cannot be undone.

---@param p string
---@return string
local function norm_path(p)
  p = vim.fs.normalize(p):gsub("/+$", "")
  return is_windows and p:lower() or p
end

local MODES = { "n", "i", "x", "s", "o", "c", "t", "l" }

---@type string[]|nil
local option_names

---Names of the global-scoped options (looked up once).
---@return string[]
local function global_options()
  if option_names then
    return option_names
  end
  option_names = {}
  local ok, info = pcall(vim.api.nvim_get_all_options_info)
  if ok then
    for name, i in pairs(info) do
      if i.scope == "global" then
        option_names[#option_names + 1] = name
      end
    end
    table.sort(option_names)
  end
  return option_names
end

---@param v any
---@return boolean
local function is_fn(v)
  return type(v) == "function" or type(v) == "userdata"
end

---Capture the state. A snapshot holds plain values and ids only.
---@return table snapshot
function M.capture()
  local snap = {
    package = {},
    preload = {},
    globals = {},
    g = {},
    options = {},
    env = {},
    cwd = norm_path(vim.uv.cwd() or ""),
    cwd_raw = vim.uv.cwd(),
    bufs = {},
    wins = {},
    tabs = {},
    commands = {},
    autocmds = {},
    groups = {},
    keymaps = {},
    cur_win = nil,
    cur_tab = nil,
  }
  for k, v in next, package.loaded do
    snap.package[k] = v
  end
  for k, v in next, package.preload do
    snap.preload[k] = v
  end
  for k, v in next, _G do
    snap.globals[k] = v
  end
  local gok, gdict = pcall(vim.fn.eval, "g:")
  if gok and type(gdict) == "table" then
    for k, v in pairs(gdict) do
      -- `g:loaded_<name>_provider` is the editor's own flag that a provider ran its autoload once
      -- (`autoload/provider/clipboard.vim` raises "missing required variable" when it is gone)
      if not is_fn(v) and not (type(k) == "string" and k:find("^loaded_%w+_provider$")) then
        snap.g[k] = vim.deepcopy(v)
      end
    end
  end
  for _, name in ipairs(global_options()) do
    local ok, v = pcall(vim.api.nvim_get_option_value, name, { scope = "global" })
    if ok then
      snap.options[name] = vim.deepcopy(v)
    end
  end
  for k, v in pairs(vim.fn.environ()) do
    if k:sub(1, 1) ~= "=" then -- `=C:` style per-drive variables are an artefact of chdir on Windows
      snap.env[is_windows and k:upper() or k] = { name = k, value = v }
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    snap.bufs[b] = vim.api.nvim_buf_get_name(b)
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    snap.wins[w] = true
  end
  for _, t in ipairs(vim.api.nvim_list_tabpages()) do
    snap.tabs[t] = true
  end
  snap.cur_win = vim.api.nvim_get_current_win()
  snap.cur_tab = vim.api.nvim_get_current_tabpage()
  local cok, cmds = pcall(vim.api.nvim_get_commands, {})
  if cok then
    for name, def in pairs(cmds) do
      snap.commands[name] = def
    end
  end
  local aok, autocmds = pcall(vim.api.nvim_get_autocmds, {})
  if aok then
    for _, a in ipairs(autocmds) do
      local group = a.group_name
      if group then
        snap.groups[group] = true
      end
      -- a groupless `once` autocmd on `SafeState` is the editor's own idle hook (the runtime's
      -- matchparen registers one at every cursor move): it removes itself at the next idle moment,
      -- which a request that does not return to the main loop merely has not reached yet
      local transient = a.once == true and not group and a.event == "SafeState"
      -- the editor's own lazily created groups (`nvim.diagnostic.buf_wipeout`, ...): the runtime
      -- module that made one keeps its id in an upvalue, so deleting the group breaks that module
      -- for the rest of the process ("Invalid 'group': 47")
      if type(group) == "string" and group:sub(1, 5) == "nvim." then
        transient = true
      end
      local key = a.id and ("id:" .. a.id)
        or ("sig:%s|%s|%s|%s"):format(
          tostring(group),
          tostring(a.event),
          tostring(a.pattern),
          tostring(a.command or a.desc or "")
        )
      if not transient then
        snap.autocmds[key] = {
          id = a.id,
          group = group,
          event = a.event,
          pattern = a.pattern,
          desc = a.desc,
          command = a.command,
          buflocal = a.buflocal,
        }
      end
    end
  end
  for _, mode in ipairs(MODES) do
    local ok, maps = pcall(vim.api.nvim_get_keymap, mode)
    if ok then
      for _, m in ipairs(maps) do
        snap.keymaps[mode .. "\0" .. (m.lhsraw or m.lhs)] = {
          mode = mode,
          lhs = m.lhs,
          lhsraw = m.lhsraw,
          rhs = m.rhs,
          callback = m.callback,
          sig = tostring(m.rhs or "") .. "|" .. tostring(m.callback),
          opts = {
            noremap = m.noremap == 1,
            silent = m.silent == 1,
            expr = m.expr == 1,
            nowait = m.nowait == 1,
            script = m.script == 1,
            desc = m.desc,
          },
        }
      end
    end
  end
  return snap
end

---@param entries Testing.Isolation.Entry[]
---@param e Testing.Isolation.Entry
local function push(entries, e)
  entries[#entries + 1] = e
end

---Differences between two snapshots, in the order they are best undone (see `M.ORDER`).
---@param before table
---@param after table
---@param opts? { keep?: string[], keep_prefixes?: string[] }
---@return Testing.Isolation.Entry[]
function M.diff(before, after, opts)
  local keep = (opts or {}).keep or {}
  local prefixes = (opts or {}).keep_prefixes
  local entries = {}

  -- windows, tabs, buffers: ids that exist
  for w in pairs(after.wins) do
    if not before.wins[w] then
      push(entries, {
        kind = "window",
        change = "added",
        key = "window:" .. w,
        name = ("window %d"):format(w),
        restore = function()
          if not vim.api.nvim_win_is_valid(w) then
            return true
          end
          local ok, err = pcall(vim.api.nvim_win_close, w, true)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end
  for t in pairs(after.tabs) do
    if not before.tabs[t] then
      push(entries, {
        kind = "tab",
        change = "added",
        key = "tab:" .. t,
        name = ("tab page %d"):format(t),
        restore = function()
          if not vim.api.nvim_tabpage_is_valid(t) then
            return true
          end
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(t)) do
            pcall(vim.api.nvim_win_close, w, true)
          end
          return not vim.api.nvim_tabpage_is_valid(t), "the tab page is still open"
        end,
      })
    end
  end
  for b, name in pairs(after.bufs) do
    if not before.bufs[b] then
      push(entries, {
        kind = "buffer",
        change = "added",
        key = "buffer:" .. b,
        name = ("buffer %d%s"):format(
          b,
          name ~= "" and (" (" .. vim.fs.basename(name) .. ")") or ""
        ),
        restore = function()
          if not vim.api.nvim_buf_is_valid(b) then
            return true
          end
          local ok, err = pcall(vim.api.nvim_buf_delete, b, { force = true })
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end
  for b, name in pairs(before.bufs) do
    if not after.bufs[b] then
      push(entries, {
        kind = "buffer",
        change = "removed",
        key = "buffer:" .. b,
        name = ("buffer %d%s was wiped"):format(
          b,
          name ~= "" and (" (" .. vim.fs.basename(name) .. ")") or ""
        ),
        why = "a wiped buffer cannot be brought back",
      })
    end
  end

  -- autocommands and groups
  for key, a in pairs(after.autocmds) do
    if not before.autocmds[key] then
      local group = a.group
      local where = group and ("in group `%s`"):format(group) or "without a group"
      push(entries, {
        kind = "autocmd",
        change = "added",
        key = "autocmd:" .. key,
        name = ("autocmd %s (pattern %s) %s"):format(tostring(a.event), tostring(a.pattern), where),
        restore = (a.id or (group and not before.groups[group]))
            and function()
              if group and not before.groups[group] then
                -- the first autocmd of the group removes the whole group; the others find it gone
                if not pcall(vim.api.nvim_get_autocmds, { group = group }) then
                  return true
                end
                local ok, err = pcall(vim.api.nvim_del_augroup_by_name, group)
                return ok, not ok and tostring(err) or nil
              end
              local ok, err = pcall(vim.api.nvim_del_autocmd, a.id)
              return ok, not ok and tostring(err) or nil
            end
          or nil,
        why = "a Vimscript autocmd without an id cannot be removed one by one",
      })
    end
  end
  for key, a in pairs(before.autocmds) do
    if not after.autocmds[key] then
      push(entries, {
        kind = "autocmd",
        change = "removed",
        key = "autocmd:" .. key,
        name = ("autocmd %s (pattern %s) was removed%s"):format(
          tostring(a.event),
          tostring(a.pattern),
          a.group and (" from group `" .. a.group .. "`") or ""
        ),
        why = "a removed autocmd cannot be recreated",
      })
    end
  end

  -- user commands
  for name in pairs(after.commands) do
    if not before.commands[name] then
      push(entries, {
        kind = "command",
        change = "added",
        key = "command:" .. name,
        name = ("user command :%s"):format(name),
        restore = function()
          local ok, err = pcall(vim.api.nvim_del_user_command, name)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end
  for name in pairs(before.commands) do
    if not after.commands[name] then
      push(entries, {
        kind = "command",
        change = "removed",
        key = "command:" .. name,
        name = ("user command :%s was removed"):format(name),
        why = "a removed user command cannot be recreated",
      })
    end
  end

  -- keymaps
  local function set_back(m)
    return function()
      local o = vim.tbl_extend("force", {}, m.opts)
      if m.callback then
        o.callback = m.callback
        local ok, err = pcall(vim.api.nvim_set_keymap, m.mode, m.lhs, "", o)
        return ok, not ok and tostring(err) or nil
      end
      local ok, err = pcall(vim.api.nvim_set_keymap, m.mode, m.lhs, m.rhs or "", o)
      return ok, not ok and tostring(err) or nil
    end
  end
  for key, m in pairs(after.keymaps) do
    local old = before.keymaps[key]
    if not old then
      push(entries, {
        kind = "keymap",
        change = "added",
        key = "keymap:" .. key,
        name = ("keymap %s %s"):format(m.mode, m.lhs),
        restore = function()
          local ok, err = pcall(vim.api.nvim_del_keymap, m.mode, m.lhs)
          return ok, not ok and tostring(err) or nil
        end,
      })
    elseif old.sig ~= m.sig then
      push(entries, {
        kind = "keymap",
        change = "changed",
        key = "keymap:" .. key,
        name = ("keymap %s %s was redefined"):format(m.mode, m.lhs),
        restore = set_back(old),
      })
    end
  end
  for key, m in pairs(before.keymaps) do
    if not after.keymaps[key] then
      push(entries, {
        kind = "keymap",
        change = "removed",
        key = "keymap:" .. key,
        name = ("keymap %s %s was removed"):format(m.mode, m.lhs),
        restore = set_back(m),
      })
    end
  end

  -- vim.g
  local function gkey(name)
    return "vim.g:" .. name
  end
  for name, v in pairs(after.g) do
    local old = before.g[name]
    if old == nil then
      push(entries, {
        kind = "vim.g",
        change = "added",
        key = gkey(name),
        name = ("global variable g:%s"):format(name),
        restore = function()
          local ok, err = pcall(vim.api.nvim_del_var, name)
          return ok, not ok and tostring(err) or nil
        end,
      })
    elseif not vim.deep_equal(old, v) then
      push(entries, {
        kind = "vim.g",
        change = "changed",
        key = gkey(name),
        name = ("global variable g:%s changed"):format(name),
        restore = function()
          local ok, err = pcall(vim.api.nvim_set_var, name, old)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end
  for name, old in pairs(before.g) do
    if after.g[name] == nil then
      push(entries, {
        kind = "vim.g",
        change = "removed",
        key = gkey(name),
        name = ("global variable g:%s was removed"):format(name),
        restore = function()
          local ok, err = pcall(vim.api.nvim_set_var, name, old)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end

  -- options
  for name, v in pairs(after.options) do
    local old = before.options[name]
    if old ~= nil and not vim.deep_equal(old, v) then
      push(entries, {
        kind = "option",
        change = "changed",
        key = "option:" .. name,
        name = ("option '%s' changed (%s -> %s)"):format(name, vim.inspect(old), vim.inspect(v)),
        restore = function()
          local ok, err = pcall(vim.api.nvim_set_option_value, name, old, { scope = "global" })
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end

  -- environment
  for k, v in pairs(after.env) do
    local old = before.env[k]
    if old == nil then
      push(entries, {
        kind = "env",
        change = "added",
        key = "env:" .. k,
        name = ("environment variable %s"):format(v.name),
        restore = function()
          local ok, err = pcall(vim.fn.setenv, v.name, vim.NIL)
          return ok, not ok and tostring(err) or nil
        end,
      })
    elseif old.value ~= v.value then
      push(entries, {
        kind = "env",
        change = "changed",
        key = "env:" .. k,
        name = ("environment variable %s changed"):format(v.name),
        restore = function()
          local ok, err = pcall(vim.fn.setenv, old.name, old.value)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end
  for k, old in pairs(before.env) do
    if after.env[k] == nil then
      push(entries, {
        kind = "env",
        change = "removed",
        key = "env:" .. k,
        name = ("environment variable %s was removed"):format(old.name),
        restore = function()
          local ok, err = pcall(vim.fn.setenv, old.name, old.value)
          return ok, not ok and tostring(err) or nil
        end,
      })
    end
  end

  -- cwd
  if before.cwd ~= after.cwd then
    push(entries, {
      kind = "cwd",
      change = "changed",
      key = "cwd",
      name = ("working directory changed (%s -> %s)"):format(
        tostring(before.cwd_raw),
        tostring(after.cwd_raw)
      ),
      restore = function()
        local ok, err = pcall(vim.api.nvim_set_current_dir, before.cwd_raw)
        return ok, not ok and tostring(err) or nil
      end,
    })
  end

  -- globals
  for k, v in pairs(after.globals) do
    if before.globals[k] == nil then
      push(entries, {
        kind = "global",
        change = "added",
        key = "global:" .. tostring(k),
        name = ("global `%s`"):format(tostring(k)),
        restore = function()
          rawset(_G, k, nil)
          return true
        end,
      })
    elseif not rawequal(before.globals[k], v) then
      local old = before.globals[k]
      push(entries, {
        kind = "global",
        change = "changed",
        key = "global:" .. tostring(k),
        name = ("global `%s` was reassigned"):format(tostring(k)),
        restore = function()
          rawset(_G, k, old)
          return true
        end,
      })
    end
  end
  for k, old in pairs(before.globals) do
    if after.globals[k] == nil then
      push(entries, {
        kind = "global",
        change = "removed",
        key = "global:" .. tostring(k),
        name = ("global `%s` was removed"):format(tostring(k)),
        restore = function()
          rawset(_G, k, old)
          return true
        end,
      })
    end
  end

  -- modules (last: undoing them needs nothing else)
  for name, v in pairs(after.package) do
    if not M.is_kept(name, keep, prefixes) then
      local old = before.package[name]
      if old == nil then
        push(entries, {
          kind = "package",
          change = "added",
          key = "package:" .. tostring(name),
          name = ("module `%s` stays loaded"):format(tostring(name)),
          restore = function()
            package.loaded[name] = nil
            return true
          end,
        })
      elseif not rawequal(old, v) then
        push(entries, {
          kind = "package",
          change = "changed",
          key = "package:" .. tostring(name),
          name = ("module `%s` was replaced"):format(tostring(name)),
          restore = function()
            package.loaded[name] = old
            return true
          end,
        })
      end
    end
  end
  for name, old in pairs(before.package) do
    if after.package[name] == nil and not M.is_kept(name, keep, prefixes) then
      push(entries, {
        kind = "package",
        change = "removed",
        key = "package:" .. tostring(name),
        name = ("module `%s` was unloaded"):format(tostring(name)),
        restore = function()
          package.loaded[name] = old
          return true
        end,
      })
    end
  end

  -- package.preload: a stub left behind makes a later `require` of that name fail or answer wrongly
  -- (a spec that sets `package.preload[x]` and "restores" it from a table that skips nil values)
  for name, v in pairs(after.preload) do
    local old = before.preload[name]
    if old == nil then
      push(entries, {
        kind = "preload",
        change = "added",
        key = "preload:" .. tostring(name),
        name = ("package.preload entry `%s`"):format(tostring(name)),
        restore = function()
          package.preload[name] = nil
          return true
        end,
      })
    elseif not rawequal(old, v) then
      push(entries, {
        kind = "preload",
        change = "changed",
        key = "preload:" .. tostring(name),
        name = ("package.preload entry `%s` was replaced"):format(tostring(name)),
        restore = function()
          package.preload[name] = old
          return true
        end,
      })
    end
  end
  for name, old in pairs(before.preload) do
    if after.preload[name] == nil then
      push(entries, {
        kind = "preload",
        change = "removed",
        key = "preload:" .. tostring(name),
        name = ("package.preload entry `%s` was removed"):format(tostring(name)),
        restore = function()
          package.preload[name] = old
          return true
        end,
      })
    end
  end

  -- one stable order: kind order of `M.ORDER`, then the key
  local rank = {}
  for i, kind in ipairs(M.ORDER) do
    rank[kind] = i
  end
  table.sort(entries, function(a, b)
    local ra, rb = rank[a.kind] or 99, rank[b.kind] or 99
    if ra ~= rb then
      return ra < rb
    end
    return a.key < b.key
  end)
  return entries
end

---The order in which kinds are undone (and listed): what other state depends on goes first.
---@type string[]
M.ORDER = {
  "window",
  "tab",
  "buffer",
  "autocmd",
  "command",
  "keymap",
  "vim.g",
  "option",
  "env",
  "cwd",
  "global",
  "preload",
  "package",
}

---Undo the entries (best effort; one failure never stops the others). Returns what each reported.
---@param entries Testing.Isolation.Entry[]
---@return table<string, string> failures key -> reason (entries that could not or did not restore)
function M.restore(entries)
  local failures = {}
  for _, e in ipairs(entries) do
    if not e.restore then
      failures[e.key] = e.why or "no way to undo this"
    else
      local ok, ret, why = pcall(e.restore)
      if not ok then
        failures[e.key] = tostring(ret)
      elseif ret == false then
        failures[e.key] = why or "the restore reported failure"
      end
    end
  end
  return failures
end

---Put the focus back where it was when it still exists (closing windows may have moved it).
---@param before table
function M.refocus(before)
  if
    before.cur_tab
    and vim.api.nvim_tabpage_is_valid(before.cur_tab)
    and vim.api.nvim_get_current_tabpage() ~= before.cur_tab
  then
    pcall(vim.api.nvim_set_current_tabpage, before.cur_tab)
  end
  if
    before.cur_win
    and vim.api.nvim_win_is_valid(before.cur_win)
    and vim.api.nvim_get_current_win() ~= before.cur_win
  then
    pcall(vim.api.nvim_set_current_win, before.cur_win)
  end
end

return M
