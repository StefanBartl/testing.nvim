---@module 'testing.discover.lua_text'
---@brief Lua source text helpers for sniffing: comments and string contents removed, offsets kept.
---@description
--- A small scanner, not a parser. `code_only` returns the text with every comment and the CONTENT of
--- every string literal replaced by spaces (newlines are kept), so the result has the same length
--- and the same line structure as the input: a position found in it is a position in the original.
--- Sniffing on that text cannot be fooled by `-- describe("x", ...)` or by a string that mentions
--- `H.eq`. The delimiters of a string stay, so `describe("name"` is still recognisably a call with a
--- string argument.
---
--- Pure Lua, no editor API.

local M = {}

---@param s string
---@return string
local function blank(s)
  return (s:gsub("[^\n]", " "))
end

---Text without comments and string contents, same length and line structure as `text`.
---@param text string
---@return string
function M.code_only(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      local stop = math.min(j, n)
      local closed = text:sub(stop, stop) == c and stop > i
      if closed then
        out[#out + 1] = c .. blank(text:sub(i + 1, stop - 1)) .. c
      else
        out[#out + 1] = c .. blank(text:sub(i + 1, stop))
      end
      i = stop + 1
    elseif c == "-" and text:sub(i, i + 1) == "--" then
      local level = text:match("^%-%-%[(=*)%[", i)
      local stop
      if level then
        local _, e = text:find("]" .. level .. "]", i, true)
        stop = e or n
      else
        stop = (text:find("\n", i, true) or n + 1) - 1
      end
      out[#out + 1] = blank(text:sub(i, stop))
      i = stop + 1
    elseif c == "[" and text:match("^%[=*%[", i) then
      local level = text:match("^%[(=*)%[", i)
      local _, e = text:find("]" .. level .. "]", i, true)
      local stop = e or n
      -- keep the brackets, blank the inside: the literal still reads as one string argument
      local open_len = #level + 2
      local inner_end = e and (stop - open_len) or stop
      out[#out + 1] = text:sub(i, i + open_len - 1)
        .. blank(text:sub(i + open_len, inner_end))
        .. (e and text:sub(inner_end + 1, stop) or "")
      i = stop + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

---Comments only removed (string contents stay): what the spec-list scraper of a project runner needs.
---@param text string
---@return string
function M.strip_comments(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    elseif text:sub(i, i + 1) == "--" then
      local level = text:match("^%-%-%[(=*)%[", i)
      local stop
      if level then
        local _, e = text:find("]" .. level .. "]", i, true)
        stop = e or n
      else
        stop = (text:find("\n", i, true) or n + 1) - 1
      end
      out[#out + 1] = " "
      i = stop + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

return M
