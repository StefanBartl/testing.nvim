---@module 'testing.surface.tags'
---@brief Cases that claim a surface entry by a tag: `binding:<lhs>`, `command:<route>` (the second source of hits).
---@description
--- Besides the tracker (which sees a handler run), a case can state which entry it is the test of:
---
---   * Result-IR: a string in `cases[].tags` that is a surface id (`binding:<leader>ssa`,
---     `command:Session save`), i.e. starts with a kind of `testing.surface.ids`;
---   * Dialect A (busted-style specs, whose `#tag` words cannot hold `<`, `>` or a space): a header
---     comment within the first 30 lines of the spec file, which claims for every case of the file
---     ```lua
---     -- @covers binding:<leader>ssa, command:Session save
---     ```
---     A `,` or `;` separates two ids only when a kind (`binding:`, `command:`, ...) follows, so a name may
---     hold them (`binding:;`, `binding:<leader>,`); a `,` or `;` at the very end of the list therefore belongs
---     to the last id. `@covers:` and `@Covers` work too. The line may repeat.
---
--- Only a PASSING case claims (a failed, skipped or status-less case covers nothing). A tag is a claim,
--- not a measurement: an id that is not in the surface is reported as `extra` (a stale tag), and the entry
--- it hit is marked `tagged` in the report so a reader can tell it from a tracked execution.
--- Pure except `file_covers`, which reads the first bytes of a spec (`apply` resolves the path first).

local ids = require("testing.surface.ids")

local M = {}

---Lines of a spec scanned for `@covers`.
M.HEADER_LINES = 30

---Largest number of bytes read from a spec for its header.
M.HEADER_BYTES = 8192

---Largest number of tags of one case that are looked at (an IR cannot make the scan unbounded).
M.MAX_TAGS = 256

---Is `s` a surface id (a known kind, a non-empty name)?
---@param s any
---@return boolean
function M.is_id(s)
  if type(s) ~= "string" or #s > 512 then
    return false
  end
  local kind, name = s:match("^(%a+):(.+)$")
  return kind ~= nil and vim.tbl_contains(ids.KINDS, kind) and vim.trim(name) ~= ""
end

---The ids a tag list claims (everything that is no id, such as `slow`, is left out).
---@param tags any
---@return string[]
function M.ids_of_tags(tags)
  local out, seen = {}, {}
  if type(tags) == "table" then
    for i, t in ipairs(tags) do
      if i > M.MAX_TAGS then
        break
      end
      if M.is_id(t) and not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  return out
end

---Split the list after `@covers` into pieces: a `,` or `;` ends a piece only when a kind and its colon
---follow (`, command:Open`), so `binding:;` and `binding:<leader>,` stay whole.
---@param rest string
---@return string[]
local function split_pieces(rest)
  local pieces, start, pos = {}, 1, 1
  while true do
    local s, e, kind = rest:find("[,;]%s*(%a+):", pos)
    if not s then
      break
    end
    if vim.tbl_contains(ids.KINDS, kind) then
      pieces[#pieces + 1] = rest:sub(start, s - 1)
      start = e - #kind
    end
    pos = s + 1
  end
  pieces[#pieces + 1] = rest:sub(start)
  return pieces
end

---The ids of the `-- @covers` header lines of a spec text.
---@param text string
---@return string[]
function M.parse_covers(text)
  local out, seen = {}, {}
  -- a UTF-8 byte order mark in front of line 1 would hide a `--` that starts it
  text = text:gsub("^\239\187\191", "")
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > M.HEADER_LINES then
      break
    end
    -- `lower` keeps every byte count, so the offset found in it is valid in `line`
    local _, tail = line:lower():find("^%s*%-%-+%s*@covers:?%s+")
    if tail then
      local rest = line:sub(tail + 1):gsub("\r$", "")
      for _, piece in ipairs(split_pieces(rest)) do
        local id = vim.trim(piece)
        if M.is_id(id) and not seen[id] then
          seen[id] = true
          out[#out + 1] = id
        end
      end
    end
  end
  return out
end

---The ids claimed by the header of a spec file; empty when it cannot be read.
---@param path string
---@return string[]
function M.file_covers(path)
  local f = io.open(path, "rb")
  if not f then
    return {}
  end
  local text = f:read(M.HEADER_BYTES) or ""
  f:close()
  return M.parse_covers(text)
end

---Add the claims of the passing cases to `hits`: `hits.hit`, `hits.tagged`, and `case.tagged`.
---@param hits Testing.Surface.Hits
---@param root string Project root the spec files are relative to.
---@return integer claims Number of distinct ids claimed by tags.
function M.apply(hits, root)
  hits.tagged = hits.tagged or {}
  local by_file = {}
  local real_root
  ---The header ids of the spec `rel` below the root: nothing for a path that leaves it (`..`, absolute, a
  ---drive) or that resolves out of it through a symbolic link or a junction.
  ---@param rel any
  ---@return string[]
  local function header(rel)
    if by_file[rel] == nil then
      by_file[rel] = {}
      if require("testing.config.project").is_safe_relpath(rel) then
        real_root = real_root or vim.uv.fs_realpath(root) or root
        local real = vim.uv.fs_realpath(root .. "/" .. rel)
        local is_subpath = require("lib.nvim.fs.is_subpath")
        if real and is_subpath(vim.fs.normalize(real), vim.fs.normalize(real_root), {}) then
          by_file[rel] = M.file_covers(real)
        end
      end
    end
    return by_file[rel]
  end
  local claims = {}
  for _, c in ipairs(hits.tag_cases or {}) do
    -- fail closed: a case without a status (a hand-made IR) has not been seen to pass
    if c.status == "pass" then
      local list = vim.list_extend({}, M.ids_of_tags(c.tags))
      if type(c.file) == "string" then
        for _, id in ipairs(header(c.file)) do
          list[#list + 1] = id
        end
      end
      c.tagged = {}
      for _, id in ipairs(list) do
        if not claims[id] then
          claims[id] = true
          hits.tagged[id] = true
        end
        hits.hit[id] = true
        c.tagged[#c.tagged + 1] = id
      end
    end
  end
  return vim.tbl_count(claims)
end

return M
