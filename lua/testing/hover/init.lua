---@module 'testing.hover'
---@brief The last result of a test, shown where the test is written: hover over a case, a describe block or a spec file.
---@description
--- Reads `testing.state` (the one shared result store, written by every run) and turns one position into a few
--- plain lines: the status, the duration, how long ago the case ran, and for a red case the first failing
--- assertion with a small diff. Runs nothing and writes nothing.
---
--- Layout: `testing.hover.format` is the pure text (no editor), `testing.hover.float` the plain float used
--- without hover.nvim, this module the editor side (which project, which file, which line) and the registration.
---
--- **What is under the cursor** is decided by the discovery positions of the buffer text, not by the line
--- numbers recorded at the run: an `it` line is matched to its recorded case by describe path and name, so a
--- file that grew above the case still finds it (worded as outdated). A `describe` line summarises the cases
--- below it. A line that is no test says the file's summary. A path of a spec file in any other buffer (a note,
--- a task, a report) answers with the same file summary through hover.nvim's `file` preview.
---
--- **Soft coupling (LUA-05/91/92).** No `require("hover")` at module level: `setup()` registers only when
--- `hover.registry` loads. The `positions` entry is `on_request` (asked for `:Hover show`, never on the
--- automatic trigger). The `file` preview is asked for every local file target, so it answers `nil` after one
--- cheap name check for anything that is not a spec path. Without hover.nvim `:Testing hover` (and the optional
--- `hover` keymap action) shows the same text in a float.

local M = {}

---@type boolean
local registered = false

---The pure formatters stay reachable under the module's own name.
---@param name string
---@return function
local function format_fn(name)
  return function(...)
    return require("testing.hover.format")[name](...)
  end
end
M.ago = format_fn("ago")
M.describe_case = format_fn("describe_case")
M.describe_file = format_fn("describe_file")

---@return Testing.Hover.Limits
local function limits()
  local ok, cfg = pcall(function()
    return require("testing.config").get().hover
  end)
  local format = require("testing.hover.format")
  if not ok or type(cfg) ~= "table" then
    return format.DEFAULT_LIMITS
  end
  return { width = cfg.max_width, height = cfg.max_height, diff = cfg.max_diff_lines }
end

---Whether two describe paths are the same.
---@param a string[]|nil
---@param b string[]
---@return boolean
local function same_path(a, b)
  a = a or {}
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

---The recorded case a discovered `it` position stands for: same file, describe path and name; the nearest
---recorded line when a title repeats.
---@param st Testing.State
---@param file string
---@param pos Testing.Position
---@return Testing.State.Case|nil
local function find_case(st, file, pos)
  local best, gap
  for _, c in ipairs(st.cases) do
    if c.file == file and c.name == pos.name and same_path(c.describe, pos.path) then
      local d = math.abs((c.line or pos.line) - pos.line)
      if not best or d < gap then
        best, gap = c, d
      end
    end
  end
  return best
end

---The recorded cases below a describe path.
---@param st Testing.State
---@param file string
---@param path string[]
---@return Testing.State.Case[]
local function cases_under(st, file, path)
  local out = {}
  for _, c in ipairs(st.cases) do
    if c.file == file and c.describe and #c.describe >= #path then
      local ok = true
      for i = 1, #path do
        if c.describe[i] ~= path[i] then
          ok = false
          break
        end
      end
      if ok then
        out[#out + 1] = c
      end
    end
  end
  return out
end

---Content for a file and a line of a project, from a loaded state.
---@param st Testing.State
---@param file string Project-relative.
---@param line integer 1-based
---@param now? number
---@param scan? Testing.Positions  Discovery positions of the current text of the file; without them only the recorded line is compared.
---@return Testing.Hover.Content
function M.content(st, file, line, now, scan)
  local state = require("testing.state")
  local format = require("testing.hover.format")
  now = now or os.time()
  local stale, why = state.is_stale(st, file)
  local rec = st.files[file]
  local ts = rec and rec.ts or st.ts

  local pos
  for _, p in ipairs(scan and scan.positions or {}) do
    if p.line == line and p.name then
      pos = p
      break
    end
  end
  if pos and pos.kind ~= "describe" then
    local c = find_case(st, file, pos)
    if c then
      return format.describe_case(c, ts, stale, why, now, limits())
    end
    return format.not_run(pos.name, "this case has no recorded result; run :Testing file")
  elseif pos then
    local path = vim.list_extend(vim.list_slice(pos.path), { pos.name })
    local cases = cases_under(st, file, path)
    local title = table.concat(path, " > ")
    if #cases == 0 then
      return format.not_run(title, "no case below it has a recorded result; run :Testing file")
    end
    return format.describe_group(title, cases, ts, stale, why, now)
  end

  local c = state.case_at(st, file, line, { exact = true })
  if c and not (scan and #scan.positions > 0) then
    return format.describe_case(c, ts, stale, why, now, limits())
  end
  -- A file that is one case (dialect A and the like): its result and each failing assertion.
  local mine = {}
  for _, k in ipairs(st.cases) do
    if k.file == file then
      mine[#mine + 1] = k
    end
  end
  if #mine == 1 and mine[1].line == nil then
    return format.describe_case(mine[1], ts, stale, why, now, limits())
  end
  return format.describe_file(file, state.file_summary(st, file), now, mine)
end

---Whether a path looks like something this plugin has results for.
---@param st Testing.State
---@param rel string
---@return boolean
local function relevant(st, rel)
  if st.files[rel] then
    return true
  end
  return rel:match("_spec%.lua$") ~= nil or rel:match("^TESTS/") ~= nil
end

---The project-relative spelling of an absolute path, or nil when it lies outside its project.
---@param name string
---@return string|nil root
---@return string|nil rel
local function project_rel(name)
  local root = require("testing.bindings.usrcmds").resolve_root(nil, name)
  local rel = require("lib.nvim.fs.relpath")(vim.fs.normalize(name), root)
  if rel:sub(1, 3) == "../" or rel:match("^%a:") or rel:sub(1, 1) == "/" then
    return nil
  end
  return root, rel
end

---The content for a buffer position, or nil when the buffer is not a test file of a project.
---@param bufnr integer
---@param row integer 1-based
---@param opts? { state_dir?: string }
---@return Testing.Hover.Content|nil  Already cut to the configured size.
function M.at(bufnr, row, opts)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local root, rel = project_rel(name)
  if not root or not rel then
    return nil
  end
  local st = require("testing.state").load(root, opts)
  if not relevant(st, rel) then
    return nil
  end
  local scan
  if rel:match("%.lua$") then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    local ok, res = pcall(require("testing.discover.positions").scan, text)
    scan = ok and res or nil
  end
  return require("testing.hover.format").fit(M.content(st, rel, row, nil, scan), limits())
end

---Cheap check before anything is read: a path that cannot be a spec file of a project answers no.
---@param path any
---@return boolean
local function plausible(path)
  return type(path) == "string"
    and path ~= ""
    and #path <= 500
    and not path:find("%z")
    and not path:find("^[%a][%w+.-]*://")
    and not path:find("^[\\/][\\/]")
end

---The summary of a spec file named by a path (written in a note, a task, a report), or nil when the path is no
---spec file of a project that has results or specs. The path is only compared and statted, never opened.
---@param path string  Absolute or relative to `base` (default: the working directory).
---@param opts? { base?: string, state_dir?: string }
---@return Testing.Hover.Content|nil
function M.for_path(path, opts)
  opts = opts or {}
  if not plausible(path) then
    return nil
  end
  local p = vim.fs.normalize(path)
  if not p:match("^%a:") and p:sub(1, 1) ~= "/" then
    p = vim.fs.normalize((opts.base or vim.fn.getcwd()) .. "/" .. p)
  end
  if vim.fn.filereadable(p) ~= 1 then
    return nil
  end
  local root, rel = project_rel(p)
  if not root or not rel then
    return nil
  end
  local st = require("testing.state").load(root, opts)
  if not relevant(st, rel) then
    return nil
  end
  return require("testing.hover.format").fit(M.content(st, rel, 0, nil, nil), limits())
end

---The position preview hover.nvim asks for.
---@param bufnr integer
---@param row integer 1-based
---@param _col integer
---@return { lines: string[], title?: string, highlight?: string }|nil
function M.position(bufnr, row, _col)
  local ok, content = pcall(M.at, bufnr, row)
  return ok and content or nil
end

---The `file` preview hover.nvim asks for: the summary of a spec file written as a path anywhere.
---@param target { path?: string }
---@param _opts table
---@param _bufnr integer  The document the path is written in (unused: the path is absolute).
---@return { lines: string[], title?: string, highlight?: string }|nil
function M.file_preview(target, _opts, _bufnr)
  if type(target) ~= "table" or type(target.path) ~= "string" then
    return nil
  end
  if not target.path:match("%.lua$") then
    return nil
  end
  local ok, content = pcall(M.for_path, target.path, { base = vim.fn.getcwd() })
  return ok and content or nil
end

---`:Testing hover`: the result under the cursor (else the spec path under it) in a plain float.
function M.show()
  local buf = vim.api.nvim_get_current_buf()
  local content = M.at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if not content then
    local name = vim.api.nvim_buf_get_name(buf)
    local base = name ~= "" and vim.fs.dirname(name) or nil
    local ok, res = pcall(M.for_path, vim.fn.expand("<cfile>"), { base = base })
    content = ok and res or nil
  end
  local notify = require("testing.notify").get()
  if not content then
    notify.info(
      "nothing to show here: this is no test file of a project, and no spec path is under the cursor"
    )
    return
  end
  if not require("testing.hover.float").open(content) then
    notify.warn("could not open the hover float")
  end
end

---Whether the contribution is registered with hover.nvim right now (read back from its registry).
---@return boolean
function M.registered()
  local ok, reg = pcall(require, "hover.registry")
  if not ok or type(reg.contributors) ~= "function" then
    return registered
  end
  for _, c in ipairs(reg.contributors() or {}) do
    if c.name == "testing.nvim" and ((c.positions or 0) > 0 or (c.previews or 0) > 0) then
      return true
    end
  end
  return false
end

---Whether hover.nvim is installed (its registry loads), without registering anything.
---@return boolean
function M.available()
  local ok, reg = pcall(require, "hover.registry")
  return ok and type(reg) == "table" and type(reg.register) == "function"
end

---Where the optional half stands, for `:checkhealth testing`: `registered`, `not registered` (hover.nvim is there,
---`setup()` has not run) or `absent`; and the lhs bound to the `hover` keymap action, if any.
---@return { state: "registered"|"not registered"|"absent", keymap?: string }
function M.status()
  local state = "absent"
  if M.registered() then
    state = "registered"
  elseif M.available() then
    state = "not registered"
  end
  local keymap
  local ok, cfg = pcall(function()
    return require("testing.config").get().keymaps
  end)
  if ok and type(cfg) == "table" and cfg.hover then
    local lhs = cfg.hover
    keymap = type(lhs) == "table" and table.concat(lhs, ", ") or tostring(lhs)
  end
  return { state = state, keymap = keymap }
end

---Register with hover.nvim when it is installed; silent otherwise.
---@return boolean
function M.setup()
  local ok, reg = pcall(require, "hover.registry")
  if not ok or type(reg) ~= "table" or type(reg.register) ~= "function" then
    registered = false
    return false
  end
  reg.register("testing.nvim", {
    positions = { { fn = M.position, on_request = true } },
    previews = { file = M.file_preview },
  })
  registered = true
  return true
end

return M
