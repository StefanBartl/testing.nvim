---@module 'testing.surface.ids'
---@brief Stable ids of surface entries: `kind:name`, built the same way by the reader, the tracker and the coverage.
---@description
--- An id is the identity of one thing a plugin offers to its user, stable across runs and machines:
---
---   binding:<lhs>[@<modes>]   a keymap; `@<modes>` is left out for normal mode (`binding:<leader>sa`),
---                             otherwise the sorted mode letters (`binding:<leader>sa@x`, `@nx`)
---   command:<Name>            a user command
---   command:<Verb> <path>     a route of a composer verb (`command:Session save`); the bare verb
---                             (`command:Session`) only when it has a `default` handler or a root route
---   autocmd:<group>:<events>[:<pattern>][#n]   an autocmd; group `-` when none, `buf` for a
---                             buffer-local one, `#n` (n >= 2) numbers autocmds that share the rest
---   api:<module>.<name>       a function of the public module
---   config:<dotted.key>      a key of the typed DEFAULTS
---   health:<plugin>           the plugin has a `health.lua`
---
--- Pure module: no editor state is read except `nvim_replace_termcodes` in `norm_lhs`.

local M = {}

---Kinds in the order a report lists them.
---@type string[]
M.KINDS = { "binding", "command", "autocmd", "api", "config", "health" }

---Kinds whose execution can be observed at runtime (the tracker wraps their handlers).
---@type table<string, true>
M.TRACKABLE = { binding = true, command = true, autocmd = true, api = true }

---Kinds that make up the coverage ratio unless a caller asks for others (API entries are listed and
---tracked, but a function can be exercised by another function, so they do not gate by default).
---@type string[]
M.COVERAGE_KINDS = { "binding", "command", "autocmd" }

---The sorted, de-duplicated mode letters of a keymap.
---@param modes string|string[]|nil `"n"`, `{ "n", "x" }`, `"nv"` (nvim_set_keymap style) or nil (normal)
---@return string[]
function M.mode_list(modes)
  local set = {}
  local function add(m)
    if type(m) ~= "string" then
      return
    end
    if m == "" then
      -- an empty mode string of nvim_set_keymap means "n", "v" and "o"
      set.n, set.v, set.o = true, true, true
      return
    end
    for ch in m:gmatch(".") do
      set[ch] = true
    end
  end
  if type(modes) == "table" then
    for _, m in ipairs(modes) do
      add(m)
    end
  else
    add(modes == nil and "n" or modes)
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  if #out == 0 then
    out[1] = "n"
  end
  return out
end

---`binding:<lhs>` (normal mode) or `binding:<lhs>@<modes>`.
---@param lhs string
---@param modes? string|string[]
---@return string
function M.binding(lhs, modes)
  local list = M.mode_list(modes)
  local suffix = (#list == 1 and list[1] == "n") and "" or ("@" .. table.concat(list))
  return "binding:" .. lhs .. suffix
end

---Split a binding id into its lhs and its modes.
---@param id string
---@return string|nil lhs
---@return string[]|nil modes
function M.parse_binding(id)
  local rest = id:match("^binding:(.*)$")
  if not rest then
    return nil, nil
  end
  local lhs, modes = rest:match("^(.-)@([a-zA-Z!]+)$")
  if lhs and lhs ~= "" then
    return lhs, M.mode_list(modes)
  end
  return rest, { "n" }
end

---Alias of a registered keymap action: `action:<plugin>.<name>`. The name of an action is the stable
---identity lib.nvim gives a keymap (the lhs is only its current default and a spec may choose its own
---keys); a hit is recorded under both the id of the lhs and this one.
---@param plugin string registry key of the plugin
---@param name string action name
---@return string
function M.action(plugin, name)
  return ("action:%s.%s"):format(plugin, name)
end

---`command:<Name>`.
---@param name string
---@return string
function M.command(name)
  return "command:" .. name
end

---`command:<Verb> <path...>`; an empty path is the verb itself.
---@param verb string
---@param path string[]|nil
---@return string
function M.route(verb, path)
  if type(path) == "table" and #path > 0 then
    return "command:" .. verb .. " " .. table.concat(path, " ")
  end
  return "command:" .. verb
end

---`api:<module>.<name>`.
---@param module string
---@param name string
---@return string
function M.api(module, name)
  return ("api:%s.%s"):format(module, name)
end

---@param key string
---@return string
function M.config(key)
  return "config:" .. key
end

---@param plugin string
---@return string
function M.health(plugin)
  return "health:" .. plugin
end

---Kind of an id (`binding`, `command`, ...), nil when it has none.
---@param id string
---@return string|nil
function M.kind_of(id)
  return type(id) == "string" and id:match("^(%a+):") or nil
end

---The part of an autocmd id before any `#n`.
---@param group string|nil augroup name
---@param events string|string[]
---@param pattern string|string[]|nil
---@param buffer any set (a number or true) for a buffer-local autocmd
---@return string
function M.autocmd_base(group, events, pattern, buffer)
  local evs = type(events) == "table" and table.concat(events, ",") or tostring(events)
  local where = ""
  if buffer ~= nil and buffer ~= false then
    where = ":buf"
  elseif type(pattern) == "table" then
    where = ":" .. table.concat(pattern, ",")
  elseif type(pattern) == "string" and pattern ~= "" and pattern ~= "*" then
    -- `*` is what the editor reports for an autocommand that was made without a pattern: the same autocommand
    where = ":" .. pattern
  end
  return ("autocmd:%s:%s%s"):format(group or "-", evs, where)
end

---Ids for a list of autocmd records in creation order: equal bases are numbered `#2`, `#3`, ...
---@param records { id?: integer, group?: string, events?: string[], pattern?: any, buffer?: any }[]
---@return string[] ids parallel to `records`
function M.autocmd_ids(records)
  local seen, out = {}, {}
  for i, r in ipairs(records) do
    local base = M.autocmd_base(r.group, r.events or {}, r.pattern, r.buffer)
    seen[base] = (seen[base] or 0) + 1
    out[i] = seen[base] == 1 and base or ("%s#%d"):format(base, seen[base])
  end
  return out
end

---`\ft` (the leader is a backslash) back to `<leader>ft`: the form a plugin writes, so the id of a
---keymap that only the editor knows reads like the ones the registry knows.
---@param lhs string
---@return string
function M.readable_lhs(lhs)
  for _, pair in ipairs({
    { vim.g.mapleader, "<leader>" },
    { vim.g.maplocalleader, "<localleader>" },
  }) do
    local leader = pair[1]
    if type(leader) == "string" and leader ~= "" then
      if leader == " " then
        leader = "<Space>"
      end
      if lhs:sub(1, #leader) == leader and #lhs > #leader then
        return pair[2] .. lhs:sub(#leader + 1)
      end
    end
  end
  if lhs:sub(1, 1) == "\\" and #lhs > 1 and vim.g.mapleader == nil then
    return "<leader>" .. lhs:sub(2)
  end
  return lhs
end

---A key written the way the editor stores it: `<leader>x` and `\x` (leader is a backslash) and
---`<C-X>`/`<c-x>` compare equal.
---@param lhs string
---@return string
function M.norm_lhs(lhs)
  local ok, out = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
  return ok and out or lhs
end

return M
