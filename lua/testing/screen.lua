---@module 'testing.screen'
-- @cache-env CI TESTING_UPDATE_SNAPSHOTS
---@brief Screen snapshots: compare what an RPC child shows with a reviewed text file.
---@description
--- `testing.rpc` drives a real editor (`input`, `feed`, `mouse`, `settle`) and reads its screen
--- (`child.screen()`). This module turns such a screen into an assertion:
---
---   local screen = require("testing.screen")
---   screen.expect(H.ok, "dialog", child.screen(), { masks = { "%d%d:%d%d", { row = 24 } } })
---
--- * `normalize(shot, opts)` masks what changes between runs: Lua patterns (`"%d%d:%d%d"`), plain
---   text (`{ text = "..." }`) and rectangles by screen cell (`{ row = 24 }`, `{ row = 1, col = 70,
---   cols = 11 }`; 1-based, `rows`/`cols` default to one row / the rest of the row). A masked cell
---   shows `#` and its attribute `#`; a wide character is masked as a whole. `replace` /
---   `roots` put placeholders (`<REPO>`, `<HOME>`, `<TMP>`) in place of paths (this changes the
---   width of the text row, not of the attribute row). Attribute letters are given again in order
---   of first appearance AFTER masking, so a masked clock with its own highlight does not shift the
---   letters of everything behind it.
--- * `render(norm)` is the file format: a header (size, cursor, mode), the text rows, the attribute
---   rows, each row numbered, trailing blanks cut, LF line endings. It is meant to be read in a diff.
--- * `compare(name, shot, opts)` reads `<dir>/<spec>/<name>.snap` (`dir` default
---   `TESTS/__snapshots__`, `<spec>` the spec file without `TESTS/` and `.lua`) and decides:
---
---     match     the file has the same bytes                                    ok
---     written   no file yet, not on CI: the file is written                    ok (the message says so)
---     updated   it differs and updating is on: the file is rewritten          ok (the message says so)
---     missing   no file on CI (`CI` set): never written there                 fail
---     differ    it differs: the message shows the first differing rows        fail
---     error     the file could not be read or written                        fail
---
---   Updating is on with `opts.update = true` or `TESTING_UPDATE_SNAPSHOTS=1` (what
---   `testing run --update-snapshots` sets; the variable reaches child editors).
--- * `expect(ok_fn, name, shot, opts)` hands the verdict to the harness (`H.ok`, a collecting
---   `a.ok`, ...); `check(name, shot, opts)` raises instead (busted style specs).
---
--- Cache: the files are read by this module, not by the spec, so the cache key does not see them.
--- A spec file that uses snapshots declares them: `-- @cache-inputs TESTS/__snapshots__/`.

local M = {}

M.VERSION = 1
M.DEFAULT_DIR = "TESTS/__snapshots__"
M.FILL = "#"

local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local MAX_DIFF_ROWS = 12

---@class Testing.Screen.Shot
---@field size { rows: integer, cols: integer }
---@field cursor? { row: integer, col: integer }
---@field mode? string
---@field lines string[]
---@field attrs string[]
---@field cells? string[][] One entry per screen column, `""` for the second cell of a wide character.
---@field cell_attrs? string[] One attribute letter per screen column.

---@class Testing.Screen.Opts
---@field masks? (string|table)[] Lua patterns, `{ text = s }`, `{ pattern = p }` or `{ row, col?, rows?, cols? }`.
---@field replace? { from: string, to: string }[] Plain replacements in the text rows.
---@field roots? { repo?: string, home?: string, tmp?: string } Paths shown as `<REPO>`, `<HOME>`, `<TMP>`.
---@field cursor? boolean Keep the cursor in the snapshot (default true).
---@field mode? boolean Keep the mode in the snapshot (default true).
---@field dir? string Snapshot directory relative to `root` (default `TESTS/__snapshots__`).
---@field root? string Project root (default the current directory).
---@field file? string The spec file (default: found on the call stack, the nearest `*_spec.lua`).
---@field update? boolean Rewrite a differing file (default: `TESTING_UPDATE_SNAPSHOTS`).
---@field ci? boolean Missing files fail instead of being written (default: `CI`).

---@class Testing.Screen.Norm
---@field size { rows: integer, cols: integer }
---@field cursor? { row: integer, col: integer }
---@field mode? string
---@field text string[]
---@field attrs string[]

---@class Testing.Screen.Result
---@field ok boolean
---@field status "match"|"written"|"updated"|"missing"|"differ"|"error"
---@field path? string Absolute path of the snapshot file.
---@field rel? string The same relative to the root, `/` separated.
---@field message string
---@field actual? string The rendered screen.

---Split a row into cells by screen column, from `cells`/`cell_attrs` when the shot has them, else from
---`lines`/`attrs` (one cell per character; older children, hand-made shots).
---@param shot Testing.Screen.Shot
---@param r integer
---@return string[] cells, string[] marks
local function row_cells(shot, r)
  local cells, marks = {}, {}
  if shot.cells and shot.cells[r] then
    local ca = shot.cell_attrs and shot.cell_attrs[r] or ""
    for c, s in ipairs(shot.cells[r]) do
      cells[c] = s
      local m = ca:sub(c, c)
      marks[c] = m ~= "" and m or " "
    end
    return cells, marks
  end
  local line, attr = shot.lines[r] or "", shot.attrs and shot.attrs[r] or ""
  local i = 0
  for ch in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    i = i + 1
    cells[i] = ch
    local m = attr:sub(i, i)
    marks[i] = m ~= "" and m or " "
  end
  return cells, marks
end

---Mask the cell in column `c` and, for a wide character, its other half.
---@param cells string[]
---@param marks string[]
---@param c integer
local function mask_cell(cells, marks, c)
  if cells[c] == nil then
    return
  end
  local head = c
  while head > 1 and cells[head] == "" do
    head = head - 1
  end
  cells[head], marks[head] = M.FILL, M.FILL
  local k = head + 1
  while cells[k] == "" do
    cells[k], marks[k] = M.FILL, M.FILL
    k = k + 1
  end
end

---@param v any
---@param name string
---@return integer|nil
local function int_field(v, name)
  if v == nil then
    return nil
  end
  if type(v) ~= "number" or v ~= math.floor(v) or v < 1 then
    error(
      ("testing.screen: mask field %s must be a positive integer, got %s"):format(name, tostring(v)),
      3
    )
  end
  return v
end

---Mask a rectangle `{ row, col?, rows?, cols? }` (1-based screen cells).
---@param grid { cells: string[], marks: string[] }[]
---@param m table
---@param ncols integer
local function mask_rect(grid, m, ncols)
  local row = int_field(m.row, "row") --[[@as integer]]
  local col = int_field(m.col, "col") or 1
  local rows = int_field(m.rows, "rows") or 1
  local cols = int_field(m.cols, "cols") or (ncols - col + 1)
  for r = row, row + rows - 1 do
    local g = grid[r]
    if g then
      for c = col, math.min(col + cols - 1, #g.cells) do
        mask_cell(g.cells, g.marks, c)
      end
    end
  end
end

---Mask every match of `pat` (`plain`: a literal) in each row.
---@param grid { cells: string[], marks: string[] }[]
---@param pat string
---@param plain boolean
local function mask_text(grid, pat, plain)
  if pat == "" then
    error("testing.screen: an empty mask pattern masks nothing", 3)
  end
  for _, g in ipairs(grid) do
    -- byte offset of each column's first byte in the joined row
    local starts, parts, pos = {}, {}, 1
    for c, s in ipairs(g.cells) do
      starts[c] = pos
      parts[c] = s
      pos = pos + #s
    end
    local text = table.concat(parts)
    local init = 1
    while init <= #text do
      local s, e = text:find(pat, init, plain)
      if not s then
        break
      end
      if e >= s then
        for c = 1, #g.cells do
          local cs, len = starts[c], #g.cells[c]
          if len > 0 and cs <= e and cs + len - 1 >= s then
            mask_cell(g.cells, g.marks, c)
          end
        end
        init = e + 1
      else
        init = s + 1
      end
    end
  end
end

---@param text string
---@param from string
---@param to string
---@return string
local function replace_plain(text, from, to)
  if from == "" then
    return text
  end
  local out, init = {}, 1
  while true do
    local s, e = text:find(from, init, true)
    if not s then
      out[#out + 1] = text:sub(init)
      break
    end
    out[#out + 1] = text:sub(init, s - 1)
    out[#out + 1] = to
    init = e + 1
  end
  return table.concat(out)
end

---The replacements of `opts.replace` and `opts.roots`, longest first, both slash styles.
---@param opts Testing.Screen.Opts
---@return { from: string, to: string }[]
local function replacements(opts)
  local list = {}
  for _, r in ipairs(opts.replace or {}) do
    list[#list + 1] = { from = r.from, to = r.to }
  end
  local names = { repo = "<REPO>", home = "<HOME>", tmp = "<TMP>" }
  for key, token in pairs(names) do
    local p = opts.roots and opts.roots[key]
    if type(p) == "string" and p ~= "" then
      local fwd = (p:gsub("\\", "/")):gsub("/+$", "")
      list[#list + 1] = { from = fwd, to = token }
      list[#list + 1] = { from = (fwd:gsub("/", "\\")), to = token }
    end
  end
  table.sort(list, function(a, b)
    if #a.from ~= #b.from then
      return #a.from > #b.from
    end
    return a.from < b.from
  end)
  return list
end

---Mask, replace and re-letter a screen.
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Norm
function M.normalize(shot, opts)
  opts = opts or {}
  local nrows = shot.size and shot.size.rows or #shot.lines
  local ncols = shot.size and shot.size.cols or 0
  local grid = {}
  for r = 1, nrows do
    local cells, marks = row_cells(shot, r)
    grid[r] = { cells = cells, marks = marks }
  end
  for _, m in ipairs(opts.masks or {}) do
    if type(m) == "string" then
      mask_text(grid, m, false)
    elseif type(m) == "table" and m.text then
      mask_text(grid, m.text, true)
    elseif type(m) == "table" and m.pattern then
      mask_text(grid, m.pattern, false)
    elseif type(m) == "table" and m.row then
      mask_rect(grid, m, ncols)
    else
      error(
        "testing.screen: a mask is a Lua pattern, { text = s }, { pattern = p } or { row = n, ... }",
        2
      )
    end
  end
  local reps = replacements(opts)
  local letters, n = {}, 0
  local text, attrs = {}, {}
  for r = 1, nrows do
    local g = grid[r]
    local t, a = {}, {}
    for c, s in ipairs(g.cells) do
      if s ~= "" then
        t[#t + 1] = s
        local m = g.marks[c]
        if m ~= " " and m ~= M.FILL then
          if not letters[m] then
            n = n + 1
            letters[m] = n <= #LETTERS and LETTERS:sub(n, n) or "?"
          end
          m = letters[m]
        end
        a[#a + 1] = m
      end
    end
    local row = table.concat(t)
    for _, rep in ipairs(reps) do
      row = replace_plain(row, rep.from, rep.to)
    end
    text[r] = (row:gsub("%s+$", ""))
    attrs[r] = (table.concat(a):gsub("%s+$", ""))
  end
  return {
    size = { rows = nrows, cols = ncols },
    cursor = opts.cursor ~= false and shot.cursor or nil,
    mode = opts.mode ~= false and shot.mode or nil,
    text = text,
    attrs = attrs,
  }
end

---The snapshot file of a normalized screen.
---@param norm Testing.Screen.Norm
---@return string
function M.render(norm)
  local out = {
    ("testing.nvim screen v%d"):format(M.VERSION),
    ("size: %dx%d"):format(norm.size.cols, norm.size.rows),
  }
  if norm.cursor then
    out[#out + 1] = ("cursor: %d,%d"):format(norm.cursor.row, norm.cursor.col)
  end
  if norm.mode then
    out[#out + 1] = "mode: " .. norm.mode
  end
  local width = #tostring(#norm.text)
  local fmt = "%0" .. width .. "d|%s"
  out[#out + 1] = "--- text"
  for r, row in ipairs(norm.text) do
    out[#out + 1] = fmt:format(r, row)
  end
  out[#out + 1] = "--- attrs"
  for r, row in ipairs(norm.attrs) do
    out[#out + 1] = fmt:format(r, row)
  end
  return table.concat(out, "\n") .. "\n"
end

---@param p string
---@return string
local function norm_path(p)
  return (vim.fs.normalize(p):gsub("/+$", ""))
end

---The nearest `*_spec.lua` on the call stack.
---@return string|nil
local function spec_on_stack()
  for level = 3, 60 do
    local info = debug.getinfo(level, "S")
    if not info then
      return nil
    end
    local src = info.source or ""
    if src:sub(1, 1) == "@" and src:match("_spec%.lua$") then
      return vim.fn.fnamemodify(src:sub(2), ":p")
    end
  end
  return nil
end

---Path of the snapshot `name` for the spec file.
---@param name string
---@param opts? Testing.Screen.Opts
---@return string|nil path, string rel_or_err
function M.path(name, opts)
  opts = opts or {}
  if
    type(name) ~= "string"
    or not name:match("^[%w][%w_.%-]*$")
    or name:find("..", 1, true)
    or #name > 100
  then
    return nil,
      ("snapshot name %q: letters, digits, '_', '-', '.' (no '..'), at most 100 characters"):format(
        tostring(name)
      )
  end
  local root = norm_path(opts.root or vim.fn.getcwd())
  local spec = opts.file or spec_on_stack()
  if not spec then
    return nil, "no *_spec.lua on the call stack: pass opts.file"
  end
  spec = norm_path(vim.fn.fnamemodify(spec, ":p"))
  local windows = require("testing.platform").is_windows()
  local prefix = root .. "/"
  local head = spec:sub(1, #prefix)
  local inside = windows and head:lower() == prefix:lower() or head == prefix
  local rel = inside and spec:sub(#prefix + 1) or vim.fs.basename(spec)
  rel = rel:gsub("^TESTS/", ""):gsub("%.lua$", "")
  local dir = (opts.dir or M.DEFAULT_DIR):gsub("\\", "/"):gsub("/+$", "")
  local rel_path = dir .. "/" .. rel .. "/" .. name .. ".snap"
  return root .. "/" .. rel_path, rel_path
end

---@param v string|nil
---@return boolean
local function truthy(v)
  return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false"
end

---The first differing rows of two renderings.
---@param expected string
---@param actual string
---@return string diff, integer count
local function diff_rows(expected, actual)
  local e = vim.split(expected, "\n", { plain = true })
  local a = vim.split(actual, "\n", { plain = true })
  local lines, count = {}, 0
  for i = 1, math.max(#e, #a) do
    if e[i] ~= a[i] then
      count = count + 1
      if count <= MAX_DIFF_ROWS then
        lines[#lines + 1] = "  - " .. (e[i] or "<no line>")
        lines[#lines + 1] = "  + " .. (a[i] or "<no line>")
      end
    end
  end
  if count > MAX_DIFF_ROWS then
    lines[#lines + 1] = ("  ... %d more differing lines"):format(count - MAX_DIFF_ROWS)
  end
  return table.concat(lines, "\n"), count
end

---@param path string
---@param text string
---@return boolean ok, string|nil err
local function write(path, text)
  local atomic = require("lib.nvim.fs.write.atomic")
  local function go()
    return atomic(path, text, { mkdirp = true })
  end
  -- the snapshot is testing.nvim's own file, not a write of the spec: a guarded case may write it
  local guard = package.loaded["testing.guard"]
  if type(guard) == "table" and guard.suspended then
    local inner = go
    go = function()
      return guard.suspended(inner)
    end
  end
  local ok, res, err = pcall(go)
  if not ok then
    return false, tostring(res)
  end
  if not res then
    return false, tostring(err)
  end
  return true
end

---Compare a screen with its snapshot file (see the module header for the outcomes).
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Result
function M.compare(name, shot, opts)
  opts = opts or {}
  local path, rel = M.path(name, opts)
  if not path then
    return { ok = false, status = "error", message = "screen snapshot: " .. rel }
  end
  local actual = M.render(M.normalize(shot, opts))
  local update = opts.update
  if update == nil then
    update = truthy(os.getenv("TESTING_UPDATE_SNAPSHOTS"))
  end
  local ci = opts.ci
  if ci == nil then
    ci = truthy(os.getenv("CI"))
  end
  local res = { path = path, rel = rel, actual = actual }

  local f = io.open(path, "rb")
  if not f then
    if ci and not update then
      res.ok, res.status = false, "missing"
      res.message = ("screen snapshot %s is missing (CI writes none): run the spec locally and commit the file"):format(
        rel
      )
      return res
    end
    local wrote, err = write(path, actual)
    res.ok = wrote
    res.status = wrote and "written" or "error"
    res.message = wrote and ("screen snapshot %s written (new): review and commit it"):format(rel)
      or ("screen snapshot %s could not be written: %s"):format(rel, err)
    return res
  end
  local expected = (f:read("*a") or ""):gsub("\r\n", "\n")
  f:close()
  if expected == actual then
    res.ok, res.status = true, "match"
    res.message = ("screen snapshot %s matches"):format(rel)
    return res
  end
  local diff, count = diff_rows(expected, actual)
  if update then
    local wrote, err = write(path, actual)
    res.ok = wrote
    res.status = wrote and "updated" or "error"
    res.message = wrote and ("screen snapshot %s updated (%d lines changed)"):format(rel, count)
      or ("screen snapshot %s could not be written: %s"):format(rel, err)
    return res
  end
  res.ok, res.status = false, "differ"
  res.message = ("screen snapshot %s differs (%d lines; - snapshot, + screen; accept with --update-snapshots or TESTING_UPDATE_SNAPSHOTS=1):\n%s"):format(
    rel,
    count,
    diff
  )
  return res
end

---Compare and hand the verdict to the harness: `ok_fn(ok, message)`.
---@param ok_fn fun(ok: boolean, msg?: string): any
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return boolean ok, Testing.Screen.Result result
function M.expect(ok_fn, name, shot, opts)
  local res = M.compare(name, shot, opts)
  ok_fn(res.ok, res.message)
  return res.ok, res
end

---Compare and raise on a failure (busted style specs).
---@param name string
---@param shot Testing.Screen.Shot
---@param opts? Testing.Screen.Opts
---@return Testing.Screen.Result
function M.check(name, shot, opts)
  local res = M.compare(name, shot, opts)
  if not res.ok then
    error(res.message, 2)
  end
  return res
end

return M
