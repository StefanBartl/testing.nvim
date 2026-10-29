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
---     The ids are separated by `,` or `;`; `@covers:` works too. The line may repeat.
---
--- Only a PASSING case claims (a failed or skipped case covers nothing). A tag is a claim, not a
--- measurement: an id that is not in the surface is reported as `extra` (a stale tag), and the entry
--- it hit is marked `tagged` in the report so a reader can tell it from a tracked execution.
--- Pure except `file_covers`, which reads the first bytes of a spec.

local ids = require("testing.surface.ids")

local M = {}

---Lines of a spec scanned for `@covers`.
M.HEADER_LINES = 30

---Largest number of bytes read from a spec for its header.
M.HEADER_BYTES = 8192

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
    for _, t in ipairs(tags) do
      if M.is_id(t) and not seen[t] then
        seen[t] = true
        out[#out + 1] = t
      end
    end
  end
  return out
end

---The ids of the `-- @covers` header lines of a spec text.
---@param text string
---@return string[]
function M.parse_covers(text)
  local out, seen = {}, {}
  local n = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    if n > M.HEADER_LINES then
      break
    end
    local rest = line:match("^%s*%-%-+%s*@covers:?%s+(.*)$")
    if rest then
      rest = rest:gsub("\r$", "")
      for piece in (rest .. ","):gmatch("([^,;]*)[,;]") do
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
  local function header(rel)
    if by_file[rel] == nil then
      by_file[rel] = M.file_covers(root .. "/" .. rel)
    end
    return by_file[rel]
  end
  local claims = {}
  for _, c in ipairs(hits.tag_cases or {}) do
    if c.status == nil or c.status == "pass" then
      local list = vim.list_extend({}, M.ids_of_tags(c.tags))
      if type(c.file) == "string" and c.file ~= "" and not c.file:find("..", 1, true) then
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
