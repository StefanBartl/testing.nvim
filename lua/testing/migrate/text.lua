---@module 'testing.migrate.text'
---@brief Text helpers of the migration: line splitting that round-trips, unified diffs, safe display.
---@description
--- Everything here is pure (no file system besides `M.read`) and never raises on bad input.
---
---   * `M.lines` / `M.join`: split a file into lines and join them again BYTE-EXACT, so editing one line
---     of a CRLF file with a missing final newline leaves every other byte alone (a migration diff must
---     show only what the migration changed).
---   * `M.unified`: a unified diff (headers `a/<path>` and `b/<path>`) of two texts through `vim.diff`.
---   * `M.show`: text that came out of a repository (file names, lines of a workflow, a module name) made
---     safe for a terminal, a notification or a Markdown report (SEC-42): control characters and escape
---     sequences become visible `\xNN`, they are never forwarded raw.

local M = {}

---Hard limit of a file the migration reads, in bytes (a workflow or a script is far smaller).
M.MAX_BYTES = 2 * 1024 * 1024

---Read a whole file; nil with a reason when it is missing, unreadable or larger than `M.MAX_BYTES`.
---@param path string
---@return string|nil text
---@return string|nil err
function M.read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, "not found"
  end
  if stat.type ~= "file" then
    return nil, "not a regular file"
  end
  if stat.size > M.MAX_BYTES then
    return nil, ("larger than %d bytes"):format(M.MAX_BYTES)
  end
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, tostring(err)
  end
  return text
end

---Split text into lines. The result remembers how to put the text back together.
---@param text string
---@return string[] lines Without line terminators.
---@return { eol: string, final: boolean } shape `eol` is "\r\n" when the first terminator is CRLF; `final`: the text ended with a terminator.
function M.lines(text)
  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local final = text:sub(-1) == "\n"
  local lines = {}
  local body = final and text:sub(1, -2) or text
  if text == "" then
    return {}, { eol = eol, final = false }
  end
  for line in (body .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  return lines, { eol = eol, final = final }
end

---Inverse of `M.lines`.
---@param lines string[]
---@param shape { eol: string, final: boolean }
---@return string
function M.join(lines, shape)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, shape.eol) .. (shape.final and shape.eol or "")
end

---The first `max` bytes of `s`, without the pieces of a multi-byte character that the cut went through.
---@param s string
---@param max integer
---@return string
local function utf8_head(s, max)
  local head = s:sub(1, max)
  local i = #head
  local back = 0
  while i > 0 and back < 3 and head:byte(i) >= 0x80 and head:byte(i) < 0xC0 do
    i = i - 1
    back = back + 1
  end
  local lead = head:byte(i)
  if lead and lead >= 0xC0 then
    local need = lead >= 0xF0 and 4 or lead >= 0xE0 and 3 or 2
    if #head - i + 1 < need then
      head = head:sub(1, i - 1)
    end
  end
  return head
end

---Make repository-controlled text safe to display: C0 controls (except TAB), DEL and the C1 range
---that terminals interpret become `\xNN`; bidirectional overrides and isolates (U+202A..202E, U+2066..2069: a file name
---that reads backwards, "Trojan Source") become `\uNNNN`; the result is cut at `max` bytes, on a character boundary,
---with an ellipsis.
---@param s any
---@param max? integer Default 200.
---@return string
function M.show(s, max)
  s = tostring(s)
  max = max or 200
  local cut = #s > max
  if cut then
    s = utf8_head(s, max)
  end
  s = s:gsub("[%c\127]", function(c)
    if c == "\t" then
      return c
    end
    return ("\\x%02X"):format(c:byte())
  end)
  -- CSI/OSC leave their introducer escaped above; the C1 controls (U+0080..U+009F) in UTF-8 are
  -- the two-byte forms below and are just as live in some terminals.
  s = s:gsub("\194([\128-\159])", function(c)
    return ("\\u%04X"):format(c:byte())
  end)
  -- U+202A..U+202E are E2 80 AA..AE, U+2066..U+2069 are E2 81 A6..A9 (the set of `report.util.clean { bidi = true }`)
  s = s:gsub("\226\128([\170-\174])", function(c)
    return ("\\u%04X"):format(0x2000 + c:byte() - 0x80)
  end)
  s = s:gsub("\226\129([\166-\169])", function(c)
    return ("\\u%04X"):format(0x2040 + c:byte() - 0x80)
  end)
  return cut and (s .. "...") or s
end

---Unified diff of two texts. An empty string when they are equal.
---@param before string|nil Nil: the file does not exist yet (header `/dev/null`).
---@param after string|nil Nil: the file is deleted (header `/dev/null`).
---@param path string Project-relative path for the headers.
---@return string
function M.unified(before, after, path)
  if before == after then
    return ""
  end
  local a = before or ""
  local b = after or ""
  -- vim.diff works on lines; make both end in a newline so the last line is compared as a line.
  local function nl(t)
    if t ~= "" and t:sub(-1) ~= "\n" then
      return t .. "\n"
    end
    return t
  end
  -- `vim.diff` is the name before 0.12, `vim.text.diff` after it
  ---@diagnostic disable-next-line: deprecated
  local diff = (vim.text and vim.text.diff) or vim.diff
  local body = diff(nl(a), nl(b), { result_type = "unified", ctxlen = 3 })
  local shown = M.show(path, 300)
  local from = before == nil and "/dev/null" or ("a/" .. shown)
  local to = after == nil and "/dev/null" or ("b/" .. shown)
  local header = ("--- %s\n+++ %s\n"):format(from, to)
  return header .. tostring(body)
end

---Lines present in `before` that are gone in `after` (multiset difference, order of `before`).
---@param before string
---@param after string
---@return string[] removed
function M.removed_lines(before, after)
  local bl = M.lines(before)
  local al = M.lines(after)
  local left = {}
  for _, l in ipairs(al) do
    left[l] = (left[l] or 0) + 1
  end
  local removed = {}
  for _, l in ipairs(bl) do
    if (left[l] or 0) > 0 then
      left[l] = left[l] - 1
    else
      removed[#removed + 1] = l
    end
  end
  return removed
end

---Is `p` a relative path that stays below its base: not empty, not absolute, no `..`, no NUL?
---@param p any
---@return boolean
function M.is_safe_rel(p)
  if type(p) ~= "string" or p == "" or #p > 400 or p:find("\0", 1, true) then
    return false
  end
  if p:sub(1, 1) == "/" or p:sub(1, 1) == "\\" or p:match("^%a:") then
    return false
  end
  for seg in p:gsub("\\", "/"):gmatch("[^/]+") do
    if seg == ".." then
      return false
    end
  end
  return true
end

---A name with no byte that could end a quote or start a command: for values that land in a Lua
---pattern or a bare word.
---@param s any
---@return boolean
function M.is_plain_name(s)
  return type(s) == "string" and #s <= 100 and s:match("^[%w_%-%.]+$") ~= nil
end

---Files of a repository (text files of a few kinds, three directory levels deep, at most 400 files looked at,
---no dot directories) that mention the environment variable `name` as a word of its own. Workflows are not looked
---at (the caller has their text). Read-only, never raises.
---@param root string
---@param name string
---@return string[] rels Sorted, at most 10.
function M.readers_of(root, name)
  local found, seen = {}, 0
  local exts = {
    lua = true,
    sh = true,
    bash = true,
    ps1 = true,
    py = true,
    json = true,
    toml = true,
    mk = true,
  }
  local function wanted(file)
    local ext = file:match("%.(%w+)$")
    return (ext and exts[ext:lower()]) or file == "Makefile" or file == "justfile"
  end
  local function scan(dir, rel, depth)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    while seen < 400 do
      local entry, kind = vim.uv.fs_scandir_next(handle)
      if not entry then
        break
      end
      local path, r = dir .. "/" .. entry, (rel ~= "" and (rel .. "/") or "") .. entry
      if kind == "directory" and depth < 3 and not entry:match("^%.") then
        if entry ~= "node_modules" then
          scan(path, r, depth + 1)
        end
      elseif kind == "file" and wanted(entry) then
        seen = seen + 1
        local stat = vim.uv.fs_stat(path)
        if stat and stat.size <= 200000 then
          local src = M.read(path)
          if src then
            local from = 1
            while true do
              local i, j = src:find(name, from, true)
              if not i then
                break
              end
              local before = i > 1 and src:sub(i - 1, i - 1) or ""
              if not before:match("[%w_]") and not src:sub(j + 1, j + 1):match("[%w_]") then
                found[#found + 1] = r
                break
              end
              from = j + 1
            end
          end
        end
      end
    end
  end
  scan(root, "", 1)
  table.sort(found)
  return vim.list_slice(found, 1, 10)
end

return M
