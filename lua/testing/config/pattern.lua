---@module 'testing.config.pattern'
---@brief Syntax check of a Lua pattern, independent of any subject string.
---@description
--- `pcall(string.find, "", pattern)` does NOT prove that a pattern is well formed: with an empty subject the matcher
--- reads only the first pattern item, so `a[`, `a(`, `a)`, `a%`, `%.log%` or `x%b` pass that probe and raise
--- "malformed pattern" / "unfinished capture" on the first file name that reaches the broken item. A configuration
--- check built on the probe lets a typo in `guards.fs.ignore_patterns` through, and the guard that reads the
--- pattern later dies for every file name that starts with the right letter.
---
--- `M.check` walks the pattern once with the same rules as the C matcher of LuaJIT/PUC Lua 5.1 (`lstrlib.c`):
---
---   * `%` is never the last byte; `%b` is followed by two bytes; `%f` is followed by a set;
---   * `%1`..`%9` names a capture that is already closed; `%0` is not a back reference;
---   * a set `[...]` ends at the first `]` that is not the first byte of the set and not escaped by `%`;
---   * every `(` is closed by a `)` and no `)` comes without an open `(`; at most 32 captures.
---
--- It answers "may `string.find` raise with this pattern for SOME subject" (every consumer of a configured pattern
--- uses `find`), so it is conservative: a pattern it refuses can still be harmless for the subjects at hand, a pattern
--- it accepts raises for none. `find` treats a pattern without any of the characters ^$*+?.([%- as plain text, so such
--- a pattern is accepted as it is (`a)` works there; `string.match` would raise). A spec compares the check with the real
--- matcher on a large set of generated patterns.

local M = {}

---Captures a pattern may open (`LUA_MAXCAPTURES`).
M.MAX_CAPTURES = 32

---Index of the first byte after the set that starts at `i` (`p:sub(i, i) == "["`), or nil when the set is not closed.
---Follows `classEnd` of the C matcher: the byte after `[` or `[^` belongs to the set even when it is a `]`, and `%`
---escapes the next byte.
---@param p string
---@param i integer
---@return integer|nil after
local function set_end(p, i)
  local n = #p
  local j = i + 1
  if p:sub(j, j) == "^" then
    j = j + 1
  end
  repeat
    if j > n then
      return nil
    end
    local c = p:sub(j, j)
    j = j + 1
    if c == "%" and j <= n then
      j = j + 1
    end
  until p:sub(j, j) == "]"
  return j + 1
end

---Is `p` a well formed Lua pattern?
---@param p any
---@return boolean ok
---@return string|nil err What is wrong, in the words of the matcher (nil when ok).
function M.check(p)
  if type(p) ~= "string" then
    return false, "not a string"
  end
  if not p:find("[%^%$%*%+%?%.%(%[%%%-]") then
    return true -- `string.find` takes this as plain text
  end
  local n = #p
  local i = 1
  if p:sub(1, 1) == "^" then
    i = 2
  end
  local opened = 0
  ---@type table<integer, boolean> capture number -> still open
  local is_open = {}
  ---@type integer[] open captures, innermost last
  local stack = {}
  while i <= n do
    local c = p:sub(i, i)
    if c == "%" then
      local d = p:sub(i + 1, i + 1)
      if d == "" then
        return false, "malformed pattern (ends with '%')"
      elseif d == "b" then
        if i + 3 > n then
          return false, "unbalanced pattern (missing arguments to '%b')"
        end
        i = i + 4
      elseif d == "f" then
        if p:sub(i + 2, i + 2) ~= "[" then
          return false, "missing '[' after '%f' in pattern"
        end
        local after = set_end(p, i + 2)
        if not after then
          return false, "malformed pattern (missing ']')"
        end
        i = after
      elseif d:match("%d") then
        local k = tonumber(d)
        if k < 1 or k > opened or is_open[k] then
          return false, ("invalid capture index %%%d"):format(k)
        end
        i = i + 2
      else
        i = i + 2
      end
    elseif c == "[" then
      local after = set_end(p, i)
      if not after then
        return false, "malformed pattern (missing ']')"
      end
      i = after
    elseif c == "(" then
      opened = opened + 1
      if opened > M.MAX_CAPTURES then
        return false, "too many captures"
      end
      is_open[opened] = true
      stack[#stack + 1] = opened
      i = i + 1
    elseif c == ")" then
      local k = table.remove(stack)
      if not k then
        return false, "invalid pattern capture"
      end
      is_open[k] = false
      i = i + 1
    else
      i = i + 1
    end
  end
  if #stack > 0 then
    return false, "unfinished capture"
  end
  return true
end

---`p` when it is a well formed pattern, else nil and the reason.
---@param p any
---@return string|nil pattern
---@return string|nil err
function M.checked(p)
  local ok, err = M.check(p)
  if ok then
    return p
  end
  return nil, err
end

return M
