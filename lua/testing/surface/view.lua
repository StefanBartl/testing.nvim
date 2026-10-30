---@module 'testing.surface.view'
---@brief The matrix entries x spec files of `:Testing surface --matrix` as an interactive lib.nvim ui.kit view.
---@description
--- The child editor computes the report and prints it as JSON (`--matrix --json`); its `table` section holds the
--- cells of `render.matrix_rows` plus where a row and a file column point to. This module only shows them:
---
--- * `parse` reads the child's stdout into a model (nothing is recomputed, a cell is shown as the child wrote it);
--- * `filter`, `lines`, `cell_at`, `target` and `export_text` are pure (model in, data out), so specs need no window;
--- * `open` puts the model into a `lib.nvim.ui.kit.viewer` with keys (`<CR>` jump, `s` status filter,
---   `t` kind filter, `e` export). The keys come from `surface_view.keys` of `setup()`; the winbar legend, the
---   `?` cheatsheet and the keymaps are built from that one list by the viewer (UI-20).
---
--- Cells are cleaned by the renderer (control characters are `?`); the paths a jump opens are escaped with
--- `fnameescape`, never handed to a command line as text.

local M = {}

---The status filter, in the order the key walks through it (`nil` = all).
---@type string[]
M.STATUSES = { "hit", "missing", "untracked", "ignored" }

---The kind filter, in the order the key walks through it (`nil` = all).
---@type string[]
M.KINDS = { "binding", "command", "autocmd" }

---@class Testing.Surface.ViewModel
---@field plugin string
---@field header string[] KIND, STATUS, ID, one column per spec file, TOTAL.
---@field rows string[][] The cells, as the child wrote them.
---@field files string[] The spec file of each file column (column `3 + i`), as the IR named it.
---@field src string[] Per row, the `src` (`path:line`) of its entry; `""` when there is none.
---@field notes string[]

---@class Testing.Surface.ViewFilter
---@field status? string One of `STATUSES`, nil for all.
---@field kind? string One of `KINDS`, nil for all.

---@param v any
---@return boolean
local function strings(v)
  if type(v) ~= "table" then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= "string" then
      return false
    end
  end
  return true
end

---The notes of a report document, as strings.
---@param doc table
---@return string[]
local function notes_of(doc)
  local out = {}
  for _, n in ipairs(type(doc.notes) == "table" and doc.notes or {}) do
    if type(n) == "string" then
      out[#out + 1] = n
    end
  end
  return out
end

---The model of the child's stdout (`testing surface --matrix --json`): the first line that is a JSON object.
---nil and why when there is no table to show (no tracked run, an error of the call, not JSON).
---@param text string|nil
---@return Testing.Surface.ViewModel|nil model
---@return string|nil err
function M.parse(text)
  if type(text) ~= "string" then
    return nil, "no output"
  end
  local doc
  for line in text:gmatch("[^\r\n]+") do
    if line:sub(1, 1) == "{" then
      local ok, decoded = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(decoded) == "table" then
        doc = decoded
        break
      end
    end
  end
  if not doc then
    return nil, "the output is not a surface report (JSON)"
  end
  local t = doc.table
  if type(t) ~= "table" then
    local notes = notes_of(doc)
    return nil, #notes > 0 and table.concat(notes, "\n") or "the report has no matrix"
  end
  if not (strings(t.header) and #t.header >= 4 and strings(t.files) and strings(t.src)) then
    return nil, "the matrix of the report is malformed"
  end
  if type(t.rows) ~= "table" or #t.files ~= #t.header - 4 or #t.src ~= #t.rows then
    return nil, "the matrix of the report is malformed"
  end
  for _, r in ipairs(t.rows) do
    if not strings(r) or #r ~= #t.header then
      return nil, "the matrix of the report is malformed"
    end
  end
  return {
    plugin = type(doc.plugin) == "string" and doc.plugin or "?",
    header = t.header,
    rows = t.rows,
    files = t.files,
    src = t.src,
    notes = notes_of(doc),
  }
end

---The indices of the rows the filter keeps, in table order. A status cell may carry ` (tag)`: it is still that status.
---@param model Testing.Surface.ViewModel
---@param f Testing.Surface.ViewFilter
---@return integer[]
function M.filter(model, f)
  local out = {}
  for i, r in ipairs(model.rows) do
    local status = r[2]:gsub(" %(tag%)$", "")
    if (f.status == nil or status == f.status) and (f.kind == nil or r[1] == f.kind) then
      out[#out + 1] = i
    end
  end
  return out
end

---@param s string
---@param w integer
---@return string
local function pad(s, w)
  local n = vim.fn.strdisplaywidth(s)
  if n >= w then
    return s
  end
  return s .. string.rep(" ", w - n)
end

---The aligned lines of the view (line 1 is the header, line `1 + k` is row `shown[k]`) and per line the byte span
---of every cell (`{ first, last }`, 0-based, `last` exclusive), which is how a cursor column finds its cell.
---@param model Testing.Surface.ViewModel
---@param shown integer[] Row indices (`filter`).
---@return string[] lines
---@return integer[][][] spans
function M.lines(model, shown)
  local widths = {}
  for i, h in ipairs(model.header) do
    widths[i] = vim.fn.strdisplaywidth(h)
  end
  for _, idx in ipairs(shown) do
    for i, v in ipairs(model.rows[idx]) do
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(v))
    end
  end
  local lines, spans = {}, {}
  local function put(cells)
    local parts, cols, at = {}, {}, 0
    for i, v in ipairs(cells) do
      local text = i < #cells and pad(v, widths[i]) or v
      cols[i] = { at, at + #text }
      parts[i] = text
      at = at + #text + 2
    end
    lines[#lines + 1] = table.concat(parts, "  ")
    spans[#spans + 1] = cols
  end
  put(model.header)
  for _, idx in ipairs(shown) do
    put(model.rows[idx])
  end
  if #shown == 0 then
    lines[#lines + 1] = "(no entry matches the filter)"
    spans[#spans + 1] = {}
  end
  return lines, spans
end

---The column under a 0-based byte column of one line's spans; the gap between two cells belongs to the left one.
---@param line_spans integer[][]|nil
---@param col integer
---@return integer|nil
function M.cell_at(line_spans, col)
  if type(line_spans) ~= "table" or #line_spans == 0 then
    return nil
  end
  for i, span in ipairs(line_spans) do
    local next_span = line_spans[i + 1]
    if col >= span[1] and (next_span == nil or col < next_span[1]) then
      return i
    end
  end
  return nil
end

---Where `<CR>` on row `idx`, column `col` goes: a spec file column to that spec file, every other column to the
---`src` of the entry. nil and why when there is nowhere to go (an entry without a source, `module x`).
---@param model Testing.Surface.ViewModel
---@param idx integer Row index into `model.rows`.
---@param col integer|nil Column index (`cell_at`).
---@param root string Project root the relative paths are below.
---@return { path: string, line: integer }|nil target
---@return string|nil err
function M.target(model, idx, col, root)
  local resolve = require("testing.bindings.child").resolve_path
  local nfiles = #model.files
  if col and col >= 4 and col <= 3 + nfiles then
    return { path = resolve(model.files[col - 3], root), line = 1 }
  end
  local src = model.src[idx]
  if type(src) ~= "string" or src == "" then
    return nil, "the entry has no source location"
  end
  local path, line = src:match("^(.-):(%d+)$")
  if not path then
    path, line = src, "1"
  end
  if path:match("^module ") then
    return nil, ("the source of the entry is %s, not a file"):format(src)
  end
  return { path = resolve(path, root), line = tonumber(line) or 1 }
end

---The filtered table as tab separated text (`render.tsv`: the same format as `--matrix --csv`).
---@param model Testing.Surface.ViewModel
---@param shown integer[]
---@return string
function M.export_text(model, shown)
  local data = {}
  for _, idx in ipairs(shown) do
    data[#data + 1] = model.rows[idx]
  end
  return require("testing.surface.render").tsv(model.header, data)
end

---@param list string[]
---@param current string|nil
---@return string|nil
local function next_of(list, current)
  if current == nil then
    return list[1]
  end
  for i, v in ipairs(list) do
    if v == current then
      return list[i + 1]
    end
  end
  return nil
end

---@param model Testing.Surface.ViewModel
---@param f Testing.Surface.ViewFilter
---@param n integer
---@return string
local function title(model, f, n)
  return (" surface matrix: %s  status=%s kind=%s  %d/%d "):format(
    model.plugin,
    f.status or "all",
    f.kind or "all",
    n,
    #model.rows
  )
end

---The path the user typed, as a file to write: `~` and `$VAR` expanded, a relative path below `root`
---(the default is there too), never against the editor's current directory.
---@param path string
---@param root string
---@return string
function M.export_path(path, root)
  local p = vim.fs.normalize(path, { expand_env = true })
  local absolute = p:sub(1, 1) == "/" or p:match("^%a:/") ~= nil
  if not absolute then
    p = vim.fs.normalize(root .. "/" .. p)
  end
  return p
end

---Where the export asks for a file name: the kit's input (a seam for specs is the kit's dialog hook).
---@param default string
---@param root string
---@param cb fun(path: string)
local function ask_path(default, root, cb)
  require("lib.nvim.ui.kit").input({
    prompt = "Export the shown rows (tab separated) to",
    default = default,
    completion = "file",
    on_submit = function(path)
      if type(path) == "string" and vim.trim(path) ~= "" then
        cb(M.export_path(vim.trim(path), root))
      end
    end,
  })
end

---@class Testing.Surface.ViewOpts
---@field root string The project root (relative `src` and spec paths are below it).
---@field keys? Testing.SurfaceViewKeys Default: `surface_view.keys` of the configuration.

---@class Testing.Surface.ViewHandle
---@field surface table The `lib.nvim.ui.kit` surface.
---@field filter Testing.Surface.ViewFilter The filter shown now (the keys change it).
---@field shown fun(): integer[] The row indices shown now.

---Open the view. nil and why when the viewer cannot open.
---@param model Testing.Surface.ViewModel
---@param opts Testing.Surface.ViewOpts
---@return Testing.Surface.ViewHandle|nil handle
---@return string|nil err
function M.open(model, opts)
  local notify = require("testing.notify").get()
  local root = opts.root
  local cfg_keys = opts.keys or require("testing.config").get().surface_view.keys
  local f = {}
  local shown = M.filter(model, f)
  local lines, spans = M.lines(model, shown)

  local function refresh(view)
    shown = M.filter(model, f)
    lines, spans = M.lines(model, shown)
    view.set_lines(lines)
    view.set_title(title(model, f, #shown))
    if vim.api.nvim_win_is_valid(view.winid) then
      pcall(vim.api.nvim_win_set_cursor, view.winid, { math.min(2, #lines), 0 })
    end
  end

  ---@type table<string, Lib.UI.Kit.ViewerKey>
  local actions = {
    jump = {
      lhs = "",
      desc = "Jump: a row to the source of its entry, a spec file column to the spec file",
      legend = "jump",
      run = function(view)
        if not vim.api.nvim_win_is_valid(view.winid) then
          return
        end
        local cursor = vim.api.nvim_win_get_cursor(view.winid)
        local idx = shown[cursor[1] - 1]
        if not idx then
          return
        end
        local where, err = M.target(model, idx, M.cell_at(spans[cursor[1]], cursor[2]), root)
        if not where then
          notify.warn(tostring(err))
          return
        end
        if not vim.uv.fs_stat(where.path) then
          notify.warn(("%s does not exist"):format(where.path))
          return
        end
        view.close()
        local ok, eerr = pcall(vim.cmd.edit, vim.fn.fnameescape(where.path))
        if not ok then
          notify.error(("cannot open %s: %s"):format(where.path, tostring(eerr)))
          return
        end
        pcall(vim.api.nvim_win_set_cursor, 0, { where.line, 0 })
      end,
    },
    status = {
      lhs = "",
      desc = "Filter by status: all, hit, missing, untracked, ignored",
      legend = "status",
      run = function(view)
        f.status = next_of(M.STATUSES, f.status)
        refresh(view)
      end,
    },
    kind = {
      lhs = "",
      desc = "Filter by kind: all, binding, command, autocmd",
      legend = "kind",
      run = function(view)
        f.kind = next_of(M.KINDS, f.kind)
        refresh(view)
      end,
    },
    export = {
      lhs = "",
      desc = "Export the shown rows as a tab separated file",
      legend = "export",
      run = function()
        local text = M.export_text(model, shown)
        local n = #shown
        ask_path(root .. "/surface-matrix.csv", root, function(path)
          local ok, written, werr = pcall(require("lib.nvim.fs.write.atomic"), path, text)
          if ok and written == true then
            notify.info(("surface matrix: %d row(s) written to %s"):format(n, path))
            return
          end
          -- not ok: `written` is the error the call raised
          local why = ok and (werr or "write failed") or tostring(written)
          notify.error(("cannot write %s: %s"):format(path, why))
        end)
      end,
    },
  }
  ---@type Lib.UI.Kit.ViewerKey[]
  local keys = {}
  for _, name in ipairs({ "jump", "status", "kind", "export" }) do
    local lhs = cfg_keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      local k = actions[name]
      k.lhs = lhs
      keys[#keys + 1] = k
    end
  end

  local surf = require("lib.nvim.ui.kit").viewer({
    title = title(model, f, #shown),
    lines = lines,
    keys = keys,
    table_view = true,
    close_on_focus_lost = false,
    desc_prefix = "testing surface matrix",
    filetype = "testing-surface-matrix",
    width = math.min(math.max(40, vim.fn.strdisplaywidth(lines[1]) + 2), vim.o.columns - 4),
  })
  if not surf then
    return nil, "the matrix view could not be opened"
  end
  return {
    surface = surf,
    filter = f,
    shown = function()
      return shown
    end,
  }
end

---Show what `:Testing surface --matrix` got back from the child: the view, or (no table) the reason.
---@param verdict Testing.Child.Verdict
---@param root string
---@return Testing.Surface.ViewHandle|nil
function M.show_verdict(verdict, root)
  local notify = require("testing.notify").get()
  local model, err = M.parse(table.concat(verdict.lines or {}, "\n"))
  if not model then
    local msg = ("testing surface --matrix: %s"):format(tostring(err))
    if verdict.level == "info" then
      notify.warn(msg)
    else
      notify.error(verdict.message .. "\n" .. msg)
    end
    return nil
  end
  if verdict.level == "warn" then
    notify.warn(verdict.message)
  elseif verdict.level == "error" then
    notify.error(verdict.message)
  end
  local handle, oerr = M.open(model, { root = root })
  if not handle then
    notify.error(tostring(oerr))
  end
  return handle
end

return M
