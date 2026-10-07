---@module 'testing.affected.wrapped'
---@brief Calls of a `require` wrapper with a literal name (`lazy.require("lib.x")`): the call site is an edge.
---@description
--- A wrapper is a module that computes `require(<argument>)` for its callers (`lib.lua.lazy`). Seen from the
--- wrapper alone that is a dependency on EVERY module, and so is every module that requires the wrapper: that
--- is why one leaf module of lib.nvim selected 62 of 87 specs. Seen from the CALL SITE the wrapper loads
--- exactly the module that the call names, when the name is a literal.
---
--- This file reads the call sites. For every module `X` that a file requires by a literal it answers
--- whether the file uses `X` ONLY as
---
---   * `require("X").member("literal", ...)`, or
---   * `local a = require("X")` and then nothing but `a.member("literal", ...)`.
---
--- Anything else is a use the scanner cannot follow, and `X` is then left out of the answer: the value
--- is passed on (`f(a)`, `return a`, `t.x = a`), indexed (`a[k]`, `a:m()`), called with a computed or
--- concatenated first argument, taken apart (`local f = a.member`), required by `pcall(require, "X")`,
--- bound to the same name twice, or required in any form this reader does not recognise (the number of
--- occurrences it understood has to equal the number of occurrences `scan_requires` found). Every textual
--- occurrence of the alias counts, so a use cannot hide behind a nested function or a shadowing local.
---
--- The answer is data, not a decision: `testing.affected.heuristic` uses it only for a module that
--- declares itself with `-- @require-wrapper <members>` (the author vouches that the computed
--- `require` of the module is made for the first argument of those functions), and treats a file whose use
--- is not listed here as a dependent of everything, as before.
---
--- Pure Lua, no editor API.

local lua_text = require("testing.discover.lua_text")

local M = {}

---Most modules one file may use as a wrapper before the rest counts as unreadable (not listed).
---@type integer
M.MAX_MODULES = 40

---Most literal names kept per module and file.
---@type integer
M.MAX_NAMES = 300

---Most members kept per module and file.
---@type integer
M.MAX_MEMBERS = 8

---Longest name (module or member) kept.
---@type integer
M.MAX_NAME_BYTES = 200

---@param s string
---@return boolean
local function ident_char(s)
  return s ~= "" and s:match("[%w_%.]") ~= nil
end

---@param list string[]
---@return string[]
local function sorted_unique(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do
    if not seen[v] then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  table.sort(out)
  return out
end

---The first argument of a call `(<quote>literal<quote>` followed by `,` or `)` at `pos`.
---@param text string
---@param pos integer
---@return string|nil literal
local function literal_arg(text, pos)
  local q, lit = text:match("^%s*%(%s*([\"'])([^\"'\r\n]*)%1%s*[,%)]", pos)
  if q then
    return lit
  end
  return nil
end

---Every plain `require("X")` / `require "X"` of a text, with where it ends.
---@param text string Text without comments.
---@return { name: string, s: integer, stop: integer }[]
local function occurrences(text)
  local out = {}
  local pos = 1
  while true do
    local s, e = text:find("require", pos, true)
    if not s then
      break
    end
    pos = e + 1
    local before = s > 1 and text:sub(s - 1, s - 1) or ""
    if not ident_char(before) and not text:sub(e + 1, e + 1):match("[%w_]") then
      local name, stop = text:match('^%s*%(%s*"([^"\r\n]*)"%s*%)()', e + 1)
      if not name then
        name, stop = text:match("^%s*%(%s*'([^'\r\n]*)'%s*%)()", e + 1)
      end
      if not name then
        name, stop = text:match('^%s*"([^"\r\n]*)"()', e + 1)
      end
      if not name then
        name, stop = text:match("^%s*'([^'\r\n]*)'()", e + 1)
      end
      if name then
        out[#out + 1] = { name = name, s = s, stop = stop }
      end
    end
  end
  return out
end

---The members and literal names of the modules a file uses only as a wrapper.
---@param nocomment string Text without comments (string contents kept).
---@param raw_requires string[] Every literal module name `require` is called with in it, one entry per occurrence (not unique).
---@return table<string, Testing.Scan.Wrapped>
function M.scan(nocomment, raw_requires)
  local result = {}
  if #raw_requires == 0 then
    return result
  end
  local total = {}
  for _, name in ipairs(raw_requires) do
    total[name] = (total[name] or 0) + 1
  end
  local seen = {}
  ---@type table<string, { members: string[], names: string[] }>
  local mods = {}
  ---@type table<string, boolean>
  local loose = {}
  ---@type table<string, { name: string, mod: string, pos: integer }>
  local aliases = {}
  ---@type table<string, boolean>
  local alias_conflict = {}

  for _, o in ipairs(occurrences(nocomment)) do
    local x = o.name
    seen[x] = (seen[x] or 0) + 1
    mods[x] = mods[x] or { members = {}, names = {} }
    local nxt = nocomment:match("^%s*(.)", o.stop) or ""
    if nxt == "." then
      local member, q = nocomment:match("^%s*%.%s*([%a_][%w_]*)()", o.stop)
      local lit = member and literal_arg(nocomment, q)
      if lit and #lit <= M.MAX_NAME_BYTES and #member <= M.MAX_NAME_BYTES then
        table.insert(mods[x].members, member)
        table.insert(mods[x].names, lit)
      else
        loose[x] = true
      end
    elseif nxt == ":" or nxt == "[" or nxt == "(" or nxt == "{" or nxt == '"' or nxt == "'" then
      loose[x] = true
    else
      -- a value: it is only followed when it is the right side of `local a = require("X")`
      local from = math.max(1, o.s - 120)
      local head = nocomment:sub(from, o.s - 1)
      local at, alias = head:match("local%s+()([%a_][%w_]*)%s*=%s*$")
      if alias then
        local pos = from + at - 1
        if aliases[alias] and aliases[alias].mod ~= x then
          alias_conflict[alias] = true
        end
        if aliases[alias] and aliases[alias].mod == x then
          -- the same name bound twice to the same module: two declarations, two scopes
          alias_conflict[alias] = true
        end
        aliases[alias] = { name = alias, mod = x, pos = pos }
      else
        loose[x] = true
      end
    end
  end

  -- an occurrence this reader did not understand (`pcall(require, "X")`, `require("X", y)`) is a use
  for x, n in pairs(total) do
    if (seen[x] or 0) ~= n then
      loose[x] = true
    end
  end

  -- the uses of every alias: each textual occurrence has to be `alias.member("literal"`
  local code
  local owner = {}
  for alias, a in pairs(aliases) do
    if alias_conflict[alias] then
      loose[a.mod] = true
    else
      owner[alias] = a
    end
  end
  if next(owner) ~= nil then
    code = lua_text.code_only(nocomment)
  end
  for alias, a in pairs(owner) do
    if not loose[a.mod] then
      local pos = 1
      local plain = alias:gsub("%p", "%%%0")
      while true do
        local s, e = code:find("%f[%w_]" .. plain .. "%f[^%w_]", pos)
        if not s then
          break
        end
        pos = e + 1
        local prev = s > 1 and code:sub(s - 1, s - 1) or ""
        local prev2 = s > 2 and code:sub(s - 2, s - 1) or ""
        local field = (prev == "." and prev2 ~= "..") or prev == ":"
        if not field and s ~= a.pos then
          local member, q = nocomment:match("^%s*%.%s*([%a_][%w_]*)()", e + 1)
          local lit = member and literal_arg(nocomment, q)
          local m = mods[a.mod]
          if lit and #lit <= M.MAX_NAME_BYTES and #member <= M.MAX_NAME_BYTES then
            table.insert(m.members, member)
            table.insert(m.names, lit)
          else
            loose[a.mod] = true
            break
          end
        end
      end
    end
  end

  local n = 0
  for x, m in pairs(mods) do
    if not loose[x] then
      local members, names = sorted_unique(m.members), sorted_unique(m.names)
      if
        #members <= M.MAX_MEMBERS
        and #names <= M.MAX_NAMES
        and #x <= M.MAX_NAME_BYTES
        and n < M.MAX_MODULES
      then
        n = n + 1
        result[x] = { members = members, names = names }
      end
    end
  end
  return result
end

---The members a module declares with `-- @require-wrapper a b c` (first lines of the file).
---(The body is the rest of the line, never `(.-)%s*$`: that form is quadratic in the blanks of a hostile line, and
---the word scan below ignores blanks at the end.)
---@param line string One line of the header.
---@return string[]|nil members
function M.directive(line)
  local body = line:match("^%s*%-%-%s*@require%-wrapper%s+(.*)")
  if not body then
    return nil
  end
  local out = {}
  for word in body:gmatch("[%a_][%w_]*") do
    if #word <= 40 and #out < M.MAX_MEMBERS then
      out[#out + 1] = word
    end
  end
  return out
end

---Validate a decoded `wrapped` table (untrusted, from the index on disk); returns a clean copy.
---@param raw any
---@return table<string, Testing.Scan.Wrapped>|nil
function M.valid(raw)
  if type(raw) ~= "table" then
    return nil
  end
  local out, n = {}, 0
  for x, v in pairs(raw) do
    n = n + 1
    if
      n > M.MAX_MODULES
      or type(x) ~= "string"
      or #x > M.MAX_NAME_BYTES
      or type(v) ~= "table"
      or type(v.members) ~= "table"
      or type(v.names) ~= "table"
      or #v.members > M.MAX_MEMBERS
      or #v.names > M.MAX_NAMES
    then
      return nil
    end
    local members, names = {}, {}
    for _, s in ipairs(v.members) do
      if type(s) ~= "string" or #s > M.MAX_NAME_BYTES then
        return nil
      end
      members[#members + 1] = s
    end
    for _, s in ipairs(v.names) do
      if type(s) ~= "string" or #s > M.MAX_NAME_BYTES then
        return nil
      end
      names[#names + 1] = s
    end
    out[x] = { members = members, names = names }
  end
  return out
end

return M
