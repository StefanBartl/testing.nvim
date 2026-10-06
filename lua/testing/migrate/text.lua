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

---Make repository-controlled text safe to display: C0 controls (except TAB), DEL and the C1 range
---that terminals interpret become `\xNN`; the result is cut at `max` bytes with an ellipsis.
---@param s any
---@param max? integer Default 200.
---@return string
function M.show(s, max)
  s = tostring(s)
  max = max or 200
  local cut = #s > max
  if cut then
    s = s:sub(1, max)
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
  return cut and (s .. "...") or s
end

---Unified diff of two texts. An empty string when they are equal.
---@param before string|nil Nil: the file does not exist yet (header `/dev/null`).
---@param after string
---@param path string Project-relative path for the headers.
---@return string
function M.unified(before, after, path)
  if before == after then
    return ""
  end
  local a = before or ""
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
  local body = diff(nl(a), nl(after), { result_type = "unified", ctxlen = 3 })
  local shown = M.show(path, 300)
  local from = before == nil and "/dev/null" or ("a/" .. shown)
  local header = ("--- %s\n+++ b/%s\n"):format(from, shown)
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

return M
