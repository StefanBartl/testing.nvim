---@module 'testing.report.util'
---@brief Shared helpers of the reporters: strict UTF-8 cleaning, byte caps, status classes.
---@description
--- Reporters print text that came from the code under test (case names, assertion messages,
--- values). That text is hostile input (D.8): it can carry terminal escape sequences, bytes that are
--- not UTF-8, control characters that are illegal in XML 1.0, or bidirectional overrides that make
--- a line read differently from what it says. Everything a reporter emits goes through `clean`
--- first. Pure functions, no editor access.

local M = {}

---Every guard finding of a result, flattened, in IR order: the finding plus the case it sits on.
---@param result Testing.Result
---@return { case: Testing.Result.Case, guard: string, severity: "warn"|"error", message: string }[]
function M.guard_findings(result)
  local out = {}
  for _, c in ipairs(result.cases or {}) do
    for _, g in ipairs(c.guards or {}) do
      out[#out + 1] = { case = c, guard = g.guard, severity = g.severity, message = g.message }
    end
  end
  return out
end

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

---The multi-byte whitespace characters of .NET `char.IsWhiteSpace` (U+0085, U+00A0, U+1680, U+2000..U+200A,
---U+2028, U+2029, U+202F, U+205F, U+3000) as byte patterns. The runner of GitHub Actions trims a line with
---`TrimStart()` before it looks for `::`, and PowerShell 5.1 decides with `char.IsWhiteSpace` whether a word
---needs quotes, so ASCII whitespace alone is not whitespace here.
---@type string[]
local UNICODE_SPACE = {
  "\194[\133\160]",
  "\225\154\128",
  "\226\128[\128-\138]",
  "\226\128[\168\169\175]",
  "\226\129\159",
  "\227\128\128",
}

---Byte length of the whitespace character that starts at byte `i` of `s`: ASCII (space, `\t` to `\r`) or one of
---`UNICODE_SPACE`; nil when there is none. Independent of the locale.
---@param s string
---@param i integer
---@return integer|nil
function M.space_len(s, i)
  local b = s:byte(i)
  if not b then
    return nil
  end
  if b < 0x80 then
    return (b == 32 or (b >= 9 and b <= 13)) and 1 or nil
  end
  for _, pattern in ipairs(UNICODE_SPACE) do
    local _, last = s:find("^" .. pattern, i)
    if last then
      return last - i + 1
    end
  end
  return nil
end

---Does `s` hold a whitespace character anywhere (see `space_len`)?
---@param s string
---@return boolean
function M.has_space(s)
  if s:find("[ \9-\13]") then
    return true
  end
  for _, pattern in ipairs(UNICODE_SPACE) do
    if s:find(pattern) then
      return true
    end
  end
  return false
end

---Defuse a line that a CI runner would read as a workflow command: when the line starts with `::` after any
---amount of whitespace (ASCII or Unicode, see `UNICODE_SPACE`: the runner trims all of it), the `::` is written
---`\x3A:`. One physical line at a time; the whitespace in front stays, so the text keeps its indentation.
---@param line string
---@return string
function M.defuse_command(line)
  local i = 1
  while true do
    local n = M.space_len(line, i)
    if not n then
      break
    end
    i = i + n
  end
  if line:sub(i, i + 1) == "::" then
    return line:sub(1, i - 1) .. "\\x3A:" .. line:sub(i + 2)
  end
  return line
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

---Ids of the cases that passed without asserting anything (`assertions = "warn"` records a passed
---`no_assertions` assertion and lets the case pass).
---@param result Testing.Result
---@return string[]
function M.unasserted_ids(result)
  local ids = {}
  for _, c in ipairs(result.cases or {}) do
    for _, a in ipairs(c.assertions or {}) do
      if a.kind == "no_assertions" and a.ok then
        ids[#ids + 1] = c.id
        break
      end
    end
  end
  return ids
end

---Files of a busted spec that registered no case (`assertions = "warn"` skips them with a note).
---@param result Testing.Result
---@return string[]
function M.no_case_files(result)
  local files = {}
  local warning = require("testing.dialect.busted").NO_CASE_WARNING
  for _, c in ipairs(result.cases or {}) do
    for _, n in ipairs(c.notes or {}) do
      if n == warning then
        files[#files + 1] = c.file or c.id
        break
      end
    end
  end
  return files
end

---Cases a retry rescued (`--retry-failed`): they failed first and passed on a retry.
---@param result Testing.Result
---@return Testing.Result.Case[]
function M.flaky_cases(result)
  local out = {}
  for _, c in ipairs(result.cases or {}) do
    if c.flaky == true then
      out[#out + 1] = c
    end
  end
  return out
end

---Seconds with millisecond resolution, always with a `.` (never the locale's separator).
---@param ms number|nil
---@return string
function M.seconds(ms)
  local s = ("%.3f"):format((tonumber(ms) or 0) / 1000):gsub(",", ".")
  return s
end

return M
