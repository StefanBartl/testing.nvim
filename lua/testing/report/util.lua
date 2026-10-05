---@module 'testing.report.util'
---@brief Shared helpers of the reporters: strict UTF-8 cleaning, byte caps, status classes.
---@description
--- Reporters print text that came from the code under test (case names, assertion messages,
--- values). That text is hostile input (D.8): it can carry terminal escape sequences, bytes that are
--- not UTF-8, control characters that are illegal in XML 1.0, or bidirectional overrides that make
--- a line read differently from what it says. Everything a reporter emits goes through `clean`
--- first. Pure functions, no editor access.

local M = {}

---@alias Testing.Report.Class "ok"|"bad"|"skip"

---Status to class: `bad` fails the run, `skip` is never green, `ok` is green. `xfail` (an expected
---failure) is ok; `xpass` (an expected failure that passed) is bad.
---@type table<string, Testing.Report.Class>
M.CLASS = {
  pass = "ok",
  xfail = "ok",
  skip = "skip",
  fail = "bad",
  error = "bad",
  xpass = "bad",
  timeout = "bad",
  crash = "bad",
}

---@param status string
---@return Testing.Report.Class
function M.class_of(status)
  return M.CLASS[status] or "bad" -- an unknown status must never read as green
end

local REPLACEMENT = "\239\191\189" -- U+FFFD

---Strictly decode one multi-byte UTF-8 sequence at `i` (no overlongs, no surrogates, max U+10FFFF).
---@param s string
---@param i integer
---@return integer|nil len
---@return integer|nil cp
local function decode(s, i)
  local b1 = s:byte(i)
  local len, cp, lo, hi
  if b1 >= 0xC2 and b1 <= 0xDF then
    len, cp = 2, b1 - 0xC0
  elseif b1 >= 0xE0 and b1 <= 0xEF then
    len, cp = 3, b1 - 0xE0
    lo = b1 == 0xE0 and 0xA0 or 0x80
    hi = b1 == 0xED and 0x9F or 0xBF
  elseif b1 >= 0xF0 and b1 <= 0xF4 then
    len, cp = 4, b1 - 0xF0
    lo = b1 == 0xF0 and 0x90 or 0x80
    hi = b1 == 0xF4 and 0x8F or 0xBF
  else
    return nil, nil
  end
  if i + len - 1 > #s then
    return nil, nil
  end
  for k = 1, len - 1 do
    local c = s:byte(i + k)
    local from, to = 0x80, 0xBF
    if k == 1 and lo then
      from, to = lo, hi
    end
    if c < from or c > to then
      return nil, nil
    end
    cp = cp * 64 + (c - 0x80)
  end
  return len, cp
end

---@class Testing.Report.CleanOpts
---@field keep? table<integer, boolean> ASCII control bytes passed through (e.g. `{ [9] = true }`).
---@field c1? boolean Escape U+0080..U+009F (an 8-bit CSI is a control sequence on some terminals).
---@field bidi? boolean Escape bidirectional overrides and isolates (U+202A..202E, U+2066..2069).

---@param cp integer
---@param o Testing.Report.CleanOpts
---@return boolean
local function unsafe_cp(cp, o)
  if cp == 0xFFFE or cp == 0xFFFF then
    return true -- not a character in XML 1.0, and noise everywhere else
  end
  if o.c1 and cp >= 0x80 and cp <= 0x9F then
    return true
  end
  if o.bidi and ((cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069)) then
    return true
  end
  return false
end

---Make a string safe to emit: control characters not in `opts.keep` become a visible `\xNN`
---(`\u{NNNN}` above U+007F), bytes that are not valid UTF-8 become U+FFFD. The result is valid
---UTF-8 and valid XML 1.0 text (apart from `keep`), so no reporter needs a second pass.
---@param s string
---@param opts? Testing.Report.CleanOpts
---@return string
function M.clean(s, opts)
  s = tostring(s)
  if not s:find("[^\32-\126]") then
    return s
  end
  local o = opts or {}
  local keep = o.keep or {}
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      if (b < 0x20 or b == 0x7F) and not keep[b] then
        out[#out + 1] = ("\\x%02X"):format(b)
      else
        out[#out + 1] = string.char(b)
      end
      i = i + 1
    else
      local len, cp = decode(s, i)
      if not len or not cp then
        out[#out + 1] = REPLACEMENT
        i = i + 1
      else
        if unsafe_cp(cp, o) then
          out[#out + 1] = ("\\u{%04X}"):format(cp)
        else
          out[#out + 1] = s:sub(i, i + len - 1)
        end
        i = i + len
      end
    end
  end
  return table.concat(out)
end

---Cut `s` to at most `max_bytes` bytes without splitting a UTF-8 character.
---@param s string
---@param max_bytes integer
---@return string cut
---@return boolean truncated
function M.cap(s, max_bytes)
  if #s <= max_bytes then
    return s, false
  end
  local cut = max_bytes
  -- back off over continuation bytes so the cut lands on a character boundary
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b and b >= 0x80 and b <= 0xBF then
      cut = cut - 1
    else
      break
    end
  end
  return s:sub(1, cut), true
end

---Split a string into lines (`\n`, `\r\n` and lone `\r` all end a line; a trailing newline does not
---start an empty line).
---@param s string
---@return string[]
function M.split_lines(s)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 1 and lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---Group the cases by file, in order of first appearance.
---@param result Testing.Result
---@return { file: string, cases: Testing.Result.Case[] }[]
function M.group_by_file(result)
  local groups, index = {}, {}
  for _, c in ipairs(result.cases or {}) do
    local file = c.file or "?"
    local g = index[file]
    if not g then
      g = { file = file, cases = {} }
      index[file] = g
      groups[#groups + 1] = g
    end
    g.cases[#g.cases + 1] = c
  end
  return groups
end

---Case id without its `<file>::` prefix: the name a human reads inside a file group.
---@param c Testing.Result.Case
---@return string
function M.short_name(c)
  local id, file = c.id or "", c.file or ""
  if file ~= "" and id:sub(1, #file + 2) == file .. "::" then
    return id:sub(#file + 3)
  end
  return id
end

---Seconds with millisecond resolution, always with a `.` (never the locale's separator).
---@param ms number|nil
---@return string
function M.seconds(ms)
  local s = ("%.3f"):format((tonumber(ms) or 0) / 1000):gsub(",", ".")
  return s
end

return M
