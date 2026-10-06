---@module 'testing.core.ledger'
---@brief The effects ledger: what a case did to the outside world (spawned, network, fs, prompts).
---@description
--- A bounded, deduplicating, redacting list per kind. The guards of `testing.guard` write into it,
--- the runner merges the ledgers of several children and copies `to_effects()` into the IR field
--- `effects` of a case (`core/result.lua`, D.3.2: three string lists `spawned`, `network`,
--- `fs_outside_tmp`). Further kinds (`prompts`, ...) live in the ledger and in `serialize()`; the
--- IR does not carry them yet.
---
--- Rules:
---   * bounded (SEC-32): at most `max_entries` distinct entries per kind and `max_kinds` kinds, a
---     text is cut at `max_text` bytes; what does not fit is counted in `dropped`, never lost
---     silently;
---   * redacted (SEC-22): every text passes `opts.redact` on the way in (default: secrets only;
---     `Ledger.redactor(roots)` also maps paths to `<TMP>/<REPO>/<HOME>`);
---   * deterministic: `serialize()` / `encode()` sort kinds and entries, so the same effects give
---     the same bytes on every machine and in every merge order.
---
--- Pure Lua apart from `testing.core.result` (path placeholders); no editor state is touched.

local M = {}

---Kinds the IR knows today, in IR order.
---@type string[]
M.IR_KINDS = { "spawned", "network", "fs_outside_tmp" }

M.VERSION = 1

local DEFAULTS = { max_entries = 200, max_text = 300, max_kinds = 16 }

-- =========================================================
-- Redaction
-- =========================================================

local SECRET_WORDS = {
  "token",
  "secret",
  "passw",
  "apikey",
  "api_key",
  "api-key",
  "credential",
  "authoriz",
  "cookie",
  "bearer",
  "pwd",
}

---Does a variable / flag / query-key name look like it carries a secret?
---@param name string
---@return boolean
local function secret_name(name)
  local low = name:lower()
  -- whole-word forms of the short names (`pass`, `auth`), so `passed` and `--author` stay readable
  if low == "pass" or low == "auth" or low:find("^auth[_%-]") or low:find("[_%-]auth$") then
    return true
  end
  for _, w in ipairs(SECRET_WORDS) do
    if low:find(w, 1, true) then
      return true
    end
  end
  return low:find("key", 1, true) ~= nil
    and (low:find("private", 1, true) ~= nil or low:find("access", 1, true) ~= nil)
end

local MASK = "<REDACTED>"

---Remove secrets from free text: `Authorization` headers, `name=secret` pairs and flags, URL user
---info and secret query keys, well-known token shapes (GitHub, OpenAI-style, AWS access keys).
---@param s string
---@return string
function M.redact_secrets(s)
  if type(s) ~= "string" or s == "" then
    return s
  end
  -- `Bearer xyz` / `Basic xyz` (headers, curl -H)
  for _, scheme in ipairs({ "[Bb][Ee][Aa][Rr][Ee][Rr]", "[Bb][Aa][Ss][Ii][Cc]" }) do
    s = s:gsub("(" .. scheme .. "%s+)([%w%-%._~%+/=]+)", function(head, token)
      return #token >= 8 and head .. MASK or nil
    end)
  end
  -- URL user info: scheme://user:pass@host
  s = s:gsub("(%a[%w+.-]*://)[^/%s@]+@", "%1" .. MASK .. "@")
  -- name=value / name: value where the name looks secret (flag, env pair, query key)
  s = s:gsub("([%w_%-%.]+)(=)([^%s&\"']+)", function(name, eq, value)
    if value ~= MASK and secret_name(name) then
      return name .. eq .. MASK
    end
  end)
  s = s:gsub("([%w_%-]+)(:%s*)([^%s\"']+)", function(name, sep, value)
    if
      value ~= MASK
      and name:lower():find("^x?%-?api") == nil
      and secret_name(name)
      and not value:find("^//")
      and value:lower() ~= "bearer"
      and value:lower() ~= "basic"
    then
      return name .. sep .. MASK
    end
  end)
  -- `--password hunter2` as free text (an argv list is handled by `format_argv`)
  s = (" " .. s)
    :gsub("(%s%-%-?[%w_%-]+)(%s+)([^%s%-][^%s]*)", function(flag, sp, value)
      if value ~= MASK and secret_name(flag:match("[%w_%-]+$")) then
        return flag .. sp .. MASK
      end
    end)
    :sub(2)
  -- token shapes
  s = s:gsub("gh[pousr]_[%w]+", function(t)
    return #t >= 24 and MASK or t
  end)
  s = s:gsub("github_pat_[%w_]+", MASK)
  s = s:gsub("sk%-[%w_%-]+", function(t)
    return #t >= 19 and MASK or t
  end)
  s = s:gsub("AKIA[%u%d]+", function(t)
    return #t == 20 and MASK or t
  end)
  return s
end

---Display form of an argv: arguments with spaces are quoted, a secret value that follows a secret
---flag (`--token abc`) is masked, then `redact_secrets` runs over the whole line.
---@param argv string|string[]
---@return string
function M.format_argv(argv)
  if type(argv) == "string" then
    return M.redact_secrets(argv)
  end
  local parts, mask_next = {}, false
  for _, a in ipairs(argv) do
    a = tostring(a)
    if mask_next then
      a, mask_next = MASK, false
    elseif a:find("^%-%-?[%w_%-]+$") and secret_name(a) then
      mask_next = true
    end
    if a == "" or a:find("%s") then
      a = '"' .. a:gsub('"', '\\"') .. '"'
    end
    parts[#parts + 1] = a
  end
  return M.redact_secrets(table.concat(parts, " "))
end

---A redaction function for ledger texts: secrets first, then the path roots become placeholders
---(`<REPO>`, `<HOME>`, `<TMP>`, `<STATE>`, see `testing.core.result.normalize`).
---@param roots? Testing.Result.PathRoots
---@param opts? { case_insensitive?: boolean }
---@return fun(s: string): string
function M.redactor(roots, opts)
  local result = require("testing.core.result")
  local ci = opts ~= nil and opts.case_insensitive == true
  return function(s)
    s = M.redact_secrets(s)
    if roots then
      s = result.normalize(s, roots, { case_insensitive = ci }) --[[@as string]]
    end
    return s
  end
end

-- =========================================================
-- The ledger
-- =========================================================

---@class Testing.Ledger.Entry
---@field text string
---@field count integer
---@field blocked? boolean A guard refused the operation.
---@field allowed? string Why it was let through (`tag`, `config`).

---@class Testing.Ledger
---@field private data table<string, { map: table<string, Testing.Ledger.Entry>, n: integer, dropped: integer }>
---@field private opts table
local Ledger = {}
Ledger.__index = Ledger

---@param opts? { max_entries?: integer, max_text?: integer, max_kinds?: integer, redact?: fun(s: string): string }
---@return Testing.Ledger
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    data = {},
    nkinds = 0,
    opts = {
      max_entries = opts.max_entries or DEFAULTS.max_entries,
      max_text = opts.max_text or DEFAULTS.max_text,
      max_kinds = opts.max_kinds or DEFAULTS.max_kinds,
      redact = opts.redact or M.redact_secrets,
    },
  }, Ledger)
end

---@param text string
---@param blocked? boolean
---@return string
local function entry_key(text, blocked)
  return (blocked and "1" or "0") .. text
end

---@private
---@param kind string
---@return table|nil
function Ledger:bucket(kind)
  local b = self.data[kind]
  if not b then
    if self.nkinds >= self.opts.max_kinds then
      return nil
    end
    b = { map = {}, n = 0, dropped = 0 }
    self.data[kind] = b
    self.nkinds = self.nkinds + 1
  end
  return b
end

---@private
---@param kind string
---@param text string already redacted and cut
---@param count integer
---@param meta? { blocked?: boolean, allowed?: string }
function Ledger:put(kind, text, count, meta)
  local b = self:bucket(kind)
  if not b then
    return false
  end
  local blocked = meta ~= nil and meta.blocked == true
  local key = entry_key(text, blocked)
  local e = b.map[key]
  if e then
    e.count = e.count + count
    if meta and meta.allowed and not e.allowed then
      e.allowed = meta.allowed
    end
    return true
  end
  if b.n >= self.opts.max_entries then
    b.dropped = b.dropped + count
    return false
  end
  b.map[key] = {
    text = text,
    count = count,
    blocked = blocked or nil,
    allowed = meta and meta.allowed or nil,
  }
  b.n = b.n + 1
  return true
end

---Record one occurrence. The text is redacted and cut first; an identical entry only counts up.
---@param kind string e.g. `spawned`, `network`, `fs_outside_tmp`, `prompts`
---@param text string
---@param meta? { blocked?: boolean, allowed?: string }
---@return boolean stored false when the bounds dropped it
function Ledger:add(kind, text, meta)
  if type(kind) ~= "string" or kind == "" or type(text) ~= "string" then
    return false
  end
  local ok, red = pcall(self.opts.redact, text)
  text = ok and red or M.redact_secrets(text)
  if #text > self.opts.max_text then
    text = text:sub(1, self.opts.max_text) .. "..."
  end
  return self:put(kind, text, 1, meta)
end

---Distinct entries of a kind, sorted (text, then allowed before blocked).
---@param kind string
---@return Testing.Ledger.Entry[]
function Ledger:entries(kind)
  local b = self.data[kind]
  local out = {}
  if b then
    for _, e in pairs(b.map) do
      out[#out + 1] = vim.deepcopy(e)
    end
  end
  table.sort(out, function(a, c)
    if a.text ~= c.text then
      return a.text < c.text
    end
    return (a.blocked and 1 or 0) < (c.blocked and 1 or 0)
  end)
  return out
end

---Occurrences of a kind (sum of the counts), without what the bounds dropped.
---@param kind string
---@return integer
function Ledger:total(kind)
  local n = 0
  local b = self.data[kind]
  if b then
    for _, e in pairs(b.map) do
      n = n + e.count
    end
  end
  return n
end

---What the bounds dropped for a kind.
---@param kind string
---@return integer
function Ledger:dropped(kind)
  local b = self.data[kind]
  return b and b.dropped or 0
end

---@return boolean
function Ledger:is_empty()
  for _, b in pairs(self.data) do
    if b.n > 0 or b.dropped > 0 then
      return false
    end
  end
  return true
end

function Ledger:clear()
  self.data = {}
  self.nkinds = 0
end

---Sorted kind names.
---@return string[]
function Ledger:kinds()
  local ks = vim.tbl_keys(self.data)
  table.sort(ks)
  return ks
end

---Plain, sorted, JSON-safe table (arrays only, so any encoder gives one order).
---@return table
function Ledger:serialize()
  local kinds = {}
  for _, kind in ipairs(self:kinds()) do
    local entries = {}
    for _, e in ipairs(self:entries(kind)) do
      entries[#entries + 1] =
        { text = e.text, count = e.count, blocked = e.blocked, allowed = e.allowed }
    end
    kinds[#kinds + 1] = { kind = kind, dropped = self.data[kind].dropped, entries = entries }
  end
  return { version = M.VERSION, kinds = kinds }
end

---Deterministic JSON: fixed key order, sorted kinds and entries. Same effects, same bytes.
---@return string
function Ledger:encode()
  local function str(s)
    return vim.json.encode(s)
  end
  local kinds = {}
  for _, k in ipairs(self:serialize().kinds) do
    local entries = {}
    for _, e in ipairs(k.entries) do
      local f = { '"text":' .. str(e.text), '"count":' .. tostring(e.count) }
      if e.blocked then
        f[#f + 1] = '"blocked":true'
      end
      if e.allowed then
        f[#f + 1] = '"allowed":' .. str(e.allowed)
      end
      entries[#entries + 1] = "{" .. table.concat(f, ",") .. "}"
    end
    kinds[#kinds + 1] = ('{"kind":%s,"dropped":%d,"entries":[%s]}'):format(
      str(k.kind),
      k.dropped,
      table.concat(entries, ",")
    )
  end
  return ('{"version":%d,"kinds":[%s]}'):format(M.VERSION, table.concat(kinds, ","))
end

---Merge another ledger (or its `serialize()` / decoded `encode()` form) into this one: counts add
---up, the bounds of THIS ledger apply. Malformed input is refused as a whole.
---@param other Testing.Ledger|table
---@return boolean ok
---@return string? err
function Ledger:merge(other)
  ---@type table
  local ser = other
  if getmetatable(other) == Ledger then
    ser = other:serialize()
  end
  if type(ser) ~= "table" or ser.version ~= M.VERSION or type(ser.kinds) ~= "table" then
    return false, "not a ledger (version mismatch or no kinds)"
  end
  -- validate first: a half-merged ledger is worse than a refused one
  for i, k in ipairs(ser.kinds) do
    if type(k) ~= "table" or type(k.kind) ~= "string" or type(k.entries) ~= "table" then
      return false, ("kinds[%d]: malformed"):format(i)
    end
    for j, e in ipairs(k.entries) do
      if
        type(e) ~= "table"
        or type(e.text) ~= "string"
        or type(e.count) ~= "number"
        or e.count < 1
      then
        return false, ("kinds[%d].entries[%d]: malformed"):format(i, j)
      end
    end
  end
  for _, k in ipairs(ser.kinds) do
    local b = self:bucket(k.kind)
    if b then
      if type(k.dropped) == "number" and k.dropped > 0 then
        b.dropped = b.dropped + k.dropped
      end
      for _, e in ipairs(k.entries) do
        local text = e.text
        if #text > self.opts.max_text then
          text = text:sub(1, self.opts.max_text) .. "..."
        end
        self:put(
          k.kind,
          text,
          math.floor(e.count),
          { blocked = e.blocked == true, allowed = e.allowed }
        )
      end
    end
  end
  return true
end

---Rebuild a ledger from `serialize()` output (e.g. a child's result file).
---@param ser table
---@param opts? table options of `M.new`
---@return Testing.Ledger|nil
---@return string? err
function M.deserialize(ser, opts)
  local l = M.new(opts)
  local ok, err = l:merge(ser)
  if not ok then
    return nil, err
  end
  return l
end

---Text of an entry in the IR string lists: `text`, `[blocked]`, `(xN)`.
---@param e Testing.Ledger.Entry
---@return string
local function entry_string(e)
  local s = e.text
  if e.blocked then
    s = s .. " [blocked]"
  end
  if e.count > 1 then
    s = s .. (" (x%d)"):format(e.count)
  end
  return s
end

---The IR `effects` table of a case: always the three lists, sorted, as strings. With
---`opts.extra` the other kinds follow as additional string lists (not part of the IR schema yet).
---@param opts? { extra?: boolean }
---@return Testing.Result.Effects|table
function Ledger:to_effects(opts)
  local out = {}
  for _, kind in ipairs(M.IR_KINDS) do
    local list = {}
    for _, e in ipairs(self:entries(kind)) do
      list[#list + 1] = entry_string(e)
    end
    local dropped = self:dropped(kind)
    if dropped > 0 then
      list[#list + 1] = ("... %d more not recorded (ledger bound)"):format(dropped)
    end
    out[kind] = list
  end
  if opts and opts.extra then
    for _, kind in ipairs(self:kinds()) do
      if out[kind] == nil then
        local list = {}
        for _, e in ipairs(self:entries(kind)) do
          list[#list + 1] = entry_string(e)
        end
        out[kind] = list
      end
    end
  end
  return out
end

return M
