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
--- **Soft coupling (LUA-05/91/92).** No `require("hover")` at module level, and no `require` of hover.nvim at
--- all outside `:checkhealth` (under a lazy loader a `require` is the trigger that loads the plugin): `setup()`
--- reads `package.loaded["hover.registry"]` and registers when it is there. When hover.nvim is not loaded yet it
--- arms one named autocmd group (`TestingHoverRegister`: `VimEnter`, `User LazyLoad`, `User VeryLazy`) that tries
--- again until it succeeds, and `show()` tries on first use. The `positions` entry is `on_request` (asked for
--- `:Hover show`, never on the automatic trigger). The `file` preview is asked for every local file target, so it
--- answers `nil` after one cheap name check (`_spec.lua`, the default `spec_pattern` of the discovery) for
--- anything that is not a spec path: hover.nvim's own preview of that file stays. Without hover.nvim
--- `:Testing hover` (and the optional `hover` keymap action) shows the same text in a float.
---
--- **Only saved text is current.** A buffer with unsaved changes is worded as outdated ("unsaved changes"): the
--- result belongs to the file as it was run.

local M = {}

---The group of the one-time retry of the registration (see `M.setup`).
local RETRY_GROUP = "TestingHoverRegister"

---The default `spec_pattern` of the discovery (`testing.discover.DEFAULT_SPEC_PATTERN`; a spec keeps the two in
---step). A literal here, because `testing.discover` is heavy and the hover must stay cheap for a path it declines.
local SPEC_PATTERN = "_spec%.lua$"

---Whether this plugin registered itself with hover.nvim (set by `try_register`).
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

---A describe path read from the text, spelled the way the store keeps it (control characters replaced, cut): a
---title with an escape or over 300 bytes is stored cleaned, so the raw one would never match.
---@param path string[]
---@return string[]
local function stored_path(path)
  local state = require("testing.state")
  local out = {}
  for i, name in ipairs(path) do
    out[i] = state.title(name) or name
  end
  return out
end

---The recorded case a discovered `it` position stands for: same file, describe path and name; the nearest
---recorded line when a title repeats.
---@param st Testing.State
---@param file string
---@param pos Testing.Position
---@return Testing.State.Case|nil
local function find_case(st, file, pos)
  local best, gap
  local name = require("testing.state").title(pos.name)
  local path = stored_path(pos.path)
  for _, c in ipairs(st.cases) do
    if c.file == file and c.name == name and same_path(c.describe, path) then
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
    if c.file == file and c.describe then
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
---@param view? { modified?: boolean }  `modified`: the buffer has unsaved changes, so its text is not the text that ran.
---@return Testing.Hover.Content
function M.content(st, file, line, now, scan, view)
  local state = require("testing.state")
  local format = require("testing.hover.format")
  now = now or os.time()
  local stale, why = state.is_stale(st, file)
  if not stale and view and view.modified then
    stale, why = true, "unsaved changes"
  end
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
    local cases = cases_under(st, file, stored_path(path))
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
  local sum = state.file_summary(st, file)
  if sum and stale and not sum.stale then
    sum.stale, sum.stale_reason = stale, why
  end
  return format.describe_file(file, sum, now, mine)
end

---Cheap check before anything is read: a path that cannot be a file of a project answers no. No URI (a
---`fugitive://` or `oil://` name is no file), no UNC path (a stat on a dead share blocks), no NUL, no huge name.
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

---Whether a path is named like a spec file (the default `spec_pattern` of the discovery). Looks at the name only.
---@param path string
---@return boolean
local function spec_name(path)
  return path:match(SPEC_PATTERN) ~= nil
end

---Whether a path is something this plugin has results for: a file the store recorded, or one named like a spec.
---Any other file under a spec root (`TESTS/harness.lua`, a helper) is no spec: the discovery does not run it.
---@param st Testing.State
---@param rel string
---@return boolean
local function relevant(st, rel)
  return st.files[rel] ~= nil or spec_name(rel)
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

---Indentation (bytes of leading blanks) of a line, or nil for a blank line.
---@param line string|nil
---@return integer|nil
local function indent_of(line)
  if not line or not line:find("%S") then
    return nil
  end
  return #line:match("^[ \t]*")
end

---The line of the `it` whose body contains `row`, when the cursor is below the `it` line itself: the nearest
---position above is an `it` and every non-blank line from there down to `row` is indented deeper than the `it`
---(the closing `end)` is not). Needs formatted code, like the regex backend of the discovery. A one-line `it`,
---a line between two blocks and anything else answers nil.
---@param lines string[]  The buffer lines.
---@param scan Testing.Positions
---@param row integer
---@return integer|nil
local function enclosing_it(lines, scan, row)
  local above
  for _, p in ipairs(scan.positions) do
    if p.line >= row then
      break
    end
    above = p
  end
  if not above or above.kind ~= "it" or not above.name then
    return nil
  end
  local base = indent_of(lines[above.line])
  if not base or row - above.line > 5000 then
    return nil
  end
  for r = above.line + 1, row do
    local deeper = indent_of(lines[r])
    if deeper and deeper <= base then
      return nil
    end
  end
  return above.line
end

---The content for a buffer position, or nil when the buffer is not a test file of a project.
---@param bufnr integer
---@param row integer 1-based
---@param opts? { state_dir?: string }
---@return Testing.Hover.Content|nil  Already cut to the configured size.
function M.at(bufnr, row, opts)
  -- a buffer that is not a plain file (a `fugitive://` or `oil://` name, a terminal, a scratch) is no spec file
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not plausible(name) then
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
  local scan, lines
  if rel:match("%.lua$") then
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local ok, res = pcall(require("testing.discover.positions").scan, table.concat(lines, "\n"))
    scan = ok and res or nil
  end
  -- a line inside the body of an `it` answers with that case, not with the file
  local target = row
  if scan and lines then
    target = enclosing_it(lines, scan, row) or row
  end
  local content = M.content(st, rel, target, nil, scan, { modified = vim.bo[bufnr].modified })
  return require("testing.hover.format").fit(content, limits())
end

---The summary of a spec file named by a path (written in a note, a task, a report), or nil when the path is no
---spec file of a project that has results or specs. The path is only compared and statted, never opened. Only a
---path named like a spec (`_spec.lua`, the discovery's default) is looked at: the name is checked first, before
---a stat or the result file (up to 16 MB) is touched.
---@param path string  Absolute or relative to `base` (default: the working directory).
---@param opts? { base?: string, state_dir?: string }
---@return Testing.Hover.Content|nil
function M.for_path(path, opts)
  opts = opts or {}
  if not plausible(path) or not spec_name(path) then
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

---Define the highlight groups the hover colours its first line with (`default = true`: a colorscheme wins).
---@return nil
local function ensure_highlights()
  local float = require("testing.hover.float")
  local format = require("testing.hover.format")
  float.ensure_highlight(format.HL_ERROR)
  float.ensure_highlight(format.HL_WARN)
end

---The position preview hover.nvim asks for.
---@param bufnr integer
---@param row integer 1-based
---@param _col integer
---@return { lines: string[], title?: string, highlight?: string }|nil
function M.position(bufnr, row, _col)
  local ok, content = pcall(M.at, bufnr, row)
  if ok and content then
    pcall(ensure_highlights)
    return content
  end
  return nil
end

---The `file` preview hover.nvim asks for: the summary of a spec file written as a path anywhere. A path that is
---not named like a spec (`_spec.lua`) answers nil, so hover.nvim's own preview of that file stays.
---@param target { path?: string }
---@param _opts table
---@param _bufnr integer  The document the path is written in (unused: the path is absolute).
---@return { lines: string[], title?: string, highlight?: string }|nil
function M.file_preview(target, _opts, _bufnr)
  if type(target) ~= "table" or type(target.path) ~= "string" then
    return nil
  end
  local ok, content = pcall(M.for_path, target.path, { base = vim.fn.getcwd() })
  if ok and content then
    pcall(ensure_highlights)
    return content
  end
  return nil
end

---The registry of hover.nvim when it is loaded already. Reads `package.loaded`, never `require`s: under a lazy
---loader a `require` is what loads the plugin (LUA-92).
---@return { register: function, contributors?: function }|nil
local function loaded_registry()
  local reg = package.loaded["hover.registry"]
  if type(reg) == "table" and type(reg.register) == "function" then
    return reg
  end
  return nil
end

---Whether the contribution list of a hover.nvim registry names this plugin with something to answer.
---@param reg { contributors?: function }
---@return boolean|nil listed  nil: this hover.nvim cannot say.
local function listed_in(reg)
  if type(reg.contributors) ~= "function" then
    return nil
  end
  for _, c in ipairs(reg.contributors() or {}) do
    if c.name == "testing.nvim" and ((c.positions or 0) > 0 or (c.previews or 0) > 0) then
      return true
    end
  end
  return false
end

---Register with hover.nvim when its registry is loaded. Registering again replaces the earlier entry.
---@return boolean registered
local function try_register()
  local reg = loaded_registry()
  if not reg then
    return false
  end
  reg.register("testing.nvim", {
    positions = { { fn = M.position, on_request = true } },
    previews = { file = M.file_preview },
  })
  registered = true
  return true
end

---Try the registration again later: hover.nvim was not loaded when `setup()` ran (a lazy loader, or a plugin
---manager that loads it after this one). The autocmds of the named group go away as soon as one try succeeds.
---@return nil
local function arm_retry()
  local group = vim.api.nvim_create_augroup(RETRY_GROUP, { clear = true })
  local function retry()
    if try_register() then
      pcall(vim.api.nvim_del_augroup_by_name, RETRY_GROUP)
    end
  end
  vim.api.nvim_create_autocmd("VimEnter", { group = group, callback = retry })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "LazyLoad", "VeryLazy" },
    callback = retry,
  })
end

---`:Testing hover`: the result under the cursor (else the spec path under it) in a plain float.
---@param opts? { state_dir?: string }
function M.show(opts)
  opts = type(opts) == "table" and opts or {}
  if not registered then
    try_register()
  end
  local buf = vim.api.nvim_get_current_buf()
  local content = M.at(buf, vim.api.nvim_win_get_cursor(0)[1], opts)
  if not content then
    local name = vim.api.nvim_buf_get_name(buf)
    local base = name ~= "" and plausible(name) and vim.fs.dirname(name) or nil
    local ok, res =
      pcall(M.for_path, vim.fn.expand("<cfile>"), { base = base, state_dir = opts.state_dir })
    content = ok and res or nil
  end
  local notify = require("testing.notify").get()
  if not content then
    notify.info(
      "nothing to show here: this is no test file of a project, and no spec path is under the cursor"
    )
    return
  end
  if not require("testing.hover.float").open(content, limits()) then
    notify.warn("could not open the hover float")
  end
end

---Whether the contribution is registered with hover.nvim right now (read back from its loaded registry).
---@return boolean
function M.registered()
  local reg = loaded_registry()
  if not reg then
    return false
  end
  local listed = listed_in(reg)
  if listed == nil then
    return registered
  end
  return listed
end

---Whether hover.nvim's registry is loaded, without loading or registering anything.
---@return boolean
function M.available()
  return loaded_registry() ~= nil
end

---Where the optional half stands, for `:checkhealth testing` (the one reader that may `require` hover.nvim's
---registry, LUA-92): `registered`, `not registered` (hover.nvim is there, this plugin is not in its list: `setup()`
---has not run, or hover.nvim was loaded after it and no retry fired) or `absent`; and the lhs bound to the `hover`
---keymap action, if any.
---@return { state: "registered"|"not registered"|"absent", keymap?: string }
function M.status()
  local reg = loaded_registry()
  if not reg then
    local ok, found = pcall(require, "hover.registry")
    if ok and type(found) == "table" and type(found.register) == "function" then
      reg = found
    end
  end
  local state = "absent"
  if reg then
    local listed = listed_in(reg)
    if listed == nil then
      listed = registered
    end
    state = listed and "registered" or "not registered"
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

---Register with hover.nvim when it is loaded; otherwise try again when it may have been (`VimEnter`,
---`User LazyLoad`, `User VeryLazy`) and on the first `show()`. Never loads hover.nvim itself. Safe to call twice.
---@return boolean registered  Registered right now.
function M.setup()
  registered = false
  if try_register() then
    pcall(vim.api.nvim_del_augroup_by_name, RETRY_GROUP)
    return true
  end
  arm_retry()
  return false
end

return M
