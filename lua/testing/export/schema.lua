---@module 'testing.export.schema'
---@brief A small JSON Schema (draft 2020-12) validator for the schema files of `testing-export/1`.
---@description
--- It knows the keywords the schema files of this repository use, and refuses a schema that uses any other one (a
--- keyword it silently skipped would make every document "valid"): `$schema`, `$id`, `$ref` (to `#/$defs/<name>`),
--- `$defs`, `$comment`, `title`, `description`, `type` (one or a list), `const`, `enum`, `properties`, `required`,
--- `additionalProperties` (a boolean or a schema), `items`, `minItems`, `maxItems`, `minimum`, `maximum`, `minLength`,
--- `maxLength`, `pattern` (through `vim.regex` in very-magic mode: write patterns that read the same in both
--- dialects, `^[a-z0-9]{12}$`, no lookaround, no `\d`), `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`.
---
--- Why its own: the suite runs in Neovim without Node. The documents are validated here, in the suite, against the
--- same schema file a client of the contract reads; `contract/check.mjs` (Ajv, strict, its own CI job) checks the
--- same schema and golden files from the outside, so the two validators must agree.
---
--- A value is what `vim.json.decode` returns: `null` is `vim.NIL`, an empty `{}` carries the metatable of
--- `vim.empty_dict()`, an empty plain table is `[]`.

local M = {}

local EMPTY_DICT = getmetatable(vim.empty_dict())

---The keywords this validator understands; any other one in a schema is an error of the schema.
---@type table<string, true>
local KNOWN = {}
for _, k in ipairs({
  "$schema",
  "$id",
  "$ref",
  "$defs",
  "$comment",
  "title",
  "description",
  "type",
  "const",
  "enum",
  "properties",
  "required",
  "additionalProperties",
  "items",
  "minItems",
  "maxItems",
  "minimum",
  "maximum",
  "minLength",
  "maxLength",
  "pattern",
  "allOf",
  "anyOf",
  "oneOf",
  "not",
  "if",
  "then",
  "else",
}) do
  KNOWN[k] = true
end

---The JSON type of a decoded value.
---@param v any
---@return string
function M.type_of(v)
  if v == vim.NIL then
    return "null"
  end
  local t = type(v)
  if t == "boolean" or t == "string" then
    return t
  elseif t == "number" then
    return (v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge) and "integer"
      or "number"
  elseif t == "table" then
    if getmetatable(v) == EMPTY_DICT then
      return "object"
    end
    if next(v) == nil or vim.islist(v) then
      return "array"
    end
    return "object"
  end
  return t
end

---@param want string
---@param have string
---@return boolean
local function type_matches(want, have)
  return want == have or (want == "number" and have == "integer")
end

---Deep equality of two decoded values (`const`, `enum`).
---@param a any
---@param b any
---@return boolean
local function equal(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  if M.type_of(a) ~= M.type_of(b) then
    return false
  end
  for k, v in pairs(a) do
    if not equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---@type table<string, any>
local regex_cache = {}

---@param pattern string
---@return any regex
local function regex(pattern)
  local r = regex_cache[pattern]
  if not r then
    local ok, compiled = pcall(vim.regex, "\\v" .. pattern)
    if not ok then
      error(("schema: pattern %q does not compile: %s"):format(pattern, tostring(compiled)), 0)
    end
    r = compiled
    regex_cache[pattern] = r
  end
  return r
end

---Check that a schema uses only known keywords (recursively). Raises on the first unknown one.
---@param schema any
---@param where string
local function check_keywords(schema, where)
  if type(schema) == "boolean" then
    return
  end
  if type(schema) ~= "table" then
    error(("schema: %s is not a schema"):format(where), 0)
  end
  for k, v in pairs(schema) do
    if not KNOWN[k] then
      error(("schema: unknown keyword %q at %s"):format(tostring(k), where), 0)
    end
    if k == "properties" or k == "$defs" then
      for name, sub in pairs(v) do
        check_keywords(sub, where .. "/" .. k .. "/" .. name)
      end
    elseif k == "allOf" or k == "anyOf" or k == "oneOf" then
      for i, sub in ipairs(v) do
        check_keywords(sub, ("%s/%s/%d"):format(where, k, i - 1))
      end
    elseif
      k == "items"
      or k == "not"
      or k == "if"
      or k == "then"
      or k == "else"
      or (k == "additionalProperties" and type(v) == "table")
    then
      check_keywords(v, where .. "/" .. k)
    end
  end
end

---@class Testing.Export.Schema.Ctx
---@field root table The whole schema (for `$ref`).
---@field problems string[]

local validate

---@param ctx Testing.Export.Schema.Ctx
---@param ref string
---@return table
local function resolve(ctx, ref)
  local name = ref:match("^#/%$defs/([%w_%-]+)$")
  local target = name and ctx.root["$defs"] and ctx.root["$defs"][name]
  if not target then
    error(("schema: unresolvable $ref %q"):format(ref), 0)
  end
  return target
end

---Validate without recording: does `value` match `schema`?
---@param ctx Testing.Export.Schema.Ctx
---@param schema any
---@param value any
---@return boolean
local function matches(ctx, schema, value)
  local probe = { root = ctx.root, problems = {} }
  validate(probe, schema, value, "")
  return #probe.problems == 0
end

---@param ctx Testing.Export.Schema.Ctx
---@param schema any
---@param value any
---@param path string
validate = function(ctx, schema, value, path)
  local function fail(msg)
    ctx.problems[#ctx.problems + 1] = ("%s: %s"):format(path == "" and "$" or path, msg)
  end
  if schema == true then
    return
  elseif schema == false then
    return fail("no value is allowed here")
  end
  if schema["$ref"] then
    validate(ctx, resolve(ctx, schema["$ref"]), value, path)
  end
  local have = M.type_of(value)
  if schema.type then
    local wants = type(schema.type) == "table" and schema.type or { schema.type }
    local ok = false
    for _, w in ipairs(wants) do
      if type_matches(w, have) then
        ok = true
        break
      end
    end
    if not ok then
      return fail(("type %s, expected %s"):format(have, table.concat(wants, "|")))
    end
  end
  if schema.const ~= nil and not equal(schema.const, value) then
    fail(("not the constant %s"):format(vim.inspect(schema.const)))
  end
  if schema.enum then
    local found = false
    for _, e in ipairs(schema.enum) do
      if equal(e, value) then
        found = true
        break
      end
    end
    if not found then
      fail(("%s is not one of the enum"):format(vim.inspect(value)))
    end
  end
  if have == "string" then
    if schema.minLength and vim.fn.strchars(value) < schema.minLength then
      fail("shorter than " .. schema.minLength)
    end
    if schema.maxLength and vim.fn.strchars(value) > schema.maxLength then
      fail("longer than " .. schema.maxLength)
    end
    if schema.pattern and not regex(schema.pattern):match_str(value) then
      fail(("%q does not match %s"):format(value, schema.pattern))
    end
  elseif have == "integer" or have == "number" then
    if schema.minimum and value < schema.minimum then
      fail(("%s is below %s"):format(tostring(value), tostring(schema.minimum)))
    end
    if schema.maximum and value > schema.maximum then
      fail(("%s is above %s"):format(tostring(value), tostring(schema.maximum)))
    end
  elseif have == "array" then
    if schema.minItems and #value < schema.minItems then
      fail("fewer than " .. schema.minItems .. " items")
    end
    if schema.maxItems and #value > schema.maxItems then
      fail("more than " .. schema.maxItems .. " items")
    end
    if schema.items ~= nil then
      for i, item in ipairs(value) do
        validate(ctx, schema.items, item, ("%s[%d]"):format(path, i - 1))
      end
    end
  elseif have == "object" then
    for _, name in ipairs(schema.required or {}) do
      if value[name] == nil then
        fail(("the field %q is missing"):format(name))
      end
    end
    local props = schema.properties or {}
    for k, v in pairs(value) do
      local sub = props[k]
      local where = ("%s.%s"):format(path, tostring(k))
      if sub ~= nil then
        validate(ctx, sub, v, where)
      elseif schema.additionalProperties ~= nil then
        if schema.additionalProperties == false then
          ctx.problems[#ctx.problems + 1] = ("%s: a field nobody listed"):format(where)
        else
          validate(ctx, schema.additionalProperties, v, where)
        end
      end
    end
  end
  for _, sub in ipairs(schema.allOf or {}) do
    validate(ctx, sub, value, path)
  end
  if schema.anyOf then
    local any = false
    for _, sub in ipairs(schema.anyOf) do
      if matches(ctx, sub, value) then
        any = true
        break
      end
    end
    if not any then
      fail("matches none of anyOf")
    end
  end
  if schema.oneOf then
    local n, best = 0, nil
    for _, sub in ipairs(schema.oneOf) do
      local probe = { root = ctx.root, problems = {} }
      validate(probe, sub, value, path)
      if #probe.problems == 0 then
        n = n + 1
      elseif not best or #probe.problems < #best then
        best = probe.problems
      end
    end
    if n ~= 1 then
      if n == 0 and best then
        -- the branch that came closest says best what is wrong
        vim.list_extend(ctx.problems, best)
      else
        fail(("matches %d of oneOf, not exactly one"):format(n))
      end
    end
  end
  if schema["not"] ~= nil and matches(ctx, schema["not"], value) then
    fail("matches what `not` excludes")
  end
  if schema["if"] ~= nil then
    if matches(ctx, schema["if"], value) then
      if schema["then"] ~= nil then
        validate(ctx, schema["then"], value, path)
      end
    elseif schema["else"] ~= nil then
      validate(ctx, schema["else"], value, path)
    end
  end
end

---Validate a decoded value against a schema.
---@param schema table The decoded schema.
---@param value any
---@return boolean ok
---@return string[] problems Empty when ok.
function M.validate(schema, value)
  check_keywords(schema, "#")
  local ctx = { root = schema, problems = {} }
  validate(ctx, schema, value, "")
  return #ctx.problems == 0, ctx.problems
end

---Read and decode a schema file. Raises when it cannot be read or decoded.
---@param path string
---@return table
function M.load(path)
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    error(("schema: cannot read %s"):format(path), 0)
  end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    error(("schema: %s is not JSON: %s"):format(path, tostring(decoded)), 0)
  end
  return decoded
end

return M
