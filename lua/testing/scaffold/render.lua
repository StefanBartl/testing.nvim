---@module 'testing.scaffold.render'
---@brief Escape-safe template substitution for the scaffold (SEC-46): plain data in, text out, no shell.
---@description
--- A template is a plain text file with placeholders `@@NAME@@` or `@@NAME|mode@@` (`NAME` is
--- `[A-Z_]+`). Each value is inserted ONCE and never scanned again, so a value that itself contains
--- `@@X@@` stays literal text. How a value is embedded depends on the target language and is stated
--- at the placeholder:
---
---   `@@NAME@@`       a bare word: the value must consist of `[%w._/-]` only (it can neither close a
---                    quote nor start a command, whatever language it lands in); anything else is an error.
---   `@@NAME|lua@@`   a Lua string literal (`"..."`), or for a list `{ "a", "b" }`; the backslash is
---                    escaped FIRST, then the quote and every control character.
---   `@@NAME|sh@@`    a POSIX single-quoted word, or for a list the words separated by a space.
---   `@@NAME|yaml@@`  a double-quoted YAML scalar (a JSON string is one).
---   `@@NAME|raw@@`   inserted as is. Only for blocks that this module's caller built from values it
---                    has already vetted; never for a caller-supplied string.
---
--- A placeholder without a value is an error, so a typo in a template cannot ship `@@FOO@@` to a user.
--- CRLF in a template (a checkout with `autocrlf`) is normalized to LF first: the output contains
--- shell scripts and must be byte-identical on every platform.

local M = {}

---Largest accepted value in bytes; the values are names and paths, never prose.
M.MAX_VALUE = 400

---@alias Testing.Scaffold.Value string|string[]

---Lua string literal of `s`. The escape character is escaped first (SEC-46), so a value ending in a
---backslash cannot swallow the closing quote.
---@param s string
---@return string
function M.lua_quote(s)
  local named = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  local body = s:gsub('[%c\\"]', function(c)
    return named[c] or ("\\%03d"):format(c:byte())
  end)
  return '"' .. body .. '"'
end

---POSIX single-quoted word of `s`. A NUL cannot be represented; the caller checks for it.
---@param s string
---@return string
function M.sh_quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

---Double-quoted YAML scalar of `s`.
---@param s string
---@return string
function M.yaml_quote(s)
  return vim.json.encode(s)
end

---@param v any
---@return boolean
local function is_safe_word(v)
  return type(v) == "string" and #v <= M.MAX_VALUE and v:match("^[%w%._/%-]*$") ~= nil
end

---@param v any
---@return boolean
local function is_string_list(v)
  if type(v) ~= "table" then
    return false
  end
  for i = 1, #v do
    if type(v[i]) ~= "string" then
      return false
    end
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  return n == #v
end

---Embed one value.
---@param value any
---@param mode string "" (bare word), lua, sh, yaml or raw
---@return string|nil text
---@return string|nil err
local function embed(value, mode)
  if mode == "raw" then
    if type(value) ~= "string" then
      return nil, "a raw value must be a string"
    end
    return value
  end
  local items = is_string_list(value) and value or { value }
  for _, s in ipairs(items) do
    if type(s) ~= "string" or #s > M.MAX_VALUE or s:find("\0", 1, true) then
      return nil, "the value is not a string of at most " .. M.MAX_VALUE .. " bytes without NUL"
    end
  end
  if mode == "" then
    if not is_safe_word(value) then
      return nil,
        "a bare value may only contain letters, digits and . _ / - (use |lua, |sh or |yaml)"
    end
    return value
  elseif mode == "lua" then
    if type(value) == "string" then
      return M.lua_quote(value)
    end
    local parts = {}
    for _, s in ipairs(items) do
      parts[#parts + 1] = M.lua_quote(s)
    end
    return #parts == 0 and "{}" or ("{ " .. table.concat(parts, ", ") .. " }")
  elseif mode == "sh" then
    local parts = {}
    for _, s in ipairs(items) do
      parts[#parts + 1] = M.sh_quote(s)
    end
    return table.concat(parts, " ")
  elseif mode == "yaml" then
    if type(value) ~= "string" then
      return nil, "a yaml value must be a string"
    end
    return M.yaml_quote(value)
  end
  return nil, ("unknown mode '%s'"):format(mode)
end

---Substitute every placeholder of `template`.
---@param template string
---@param vars table<string, Testing.Scaffold.Value>
---@return string|nil text
---@return string|nil err All problems at once; set when `text` is nil.
function M.render(template, vars)
  local problems = {}
  local text = template:gsub("\r\n", "\n"):gsub("@@([A-Z_]+)(|?%l*)@@", function(name, mode)
    mode = mode:gsub("^|", "")
    local value = vars[name]
    if value == nil then
      problems[#problems + 1] = ("no value for placeholder %s"):format(name)
      return ""
    end
    local out, err = embed(value, mode)
    if not out then
      problems[#problems + 1] = ("placeholder %s: %s"):format(name, err)
      return ""
    end
    return out
  end)
  if #problems > 0 then
    return nil, table.concat(problems, "; ")
  end
  return text
end

return M
