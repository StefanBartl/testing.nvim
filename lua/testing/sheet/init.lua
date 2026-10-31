---@module 'testing.sheet'
---@brief Test sheets: a live check written down as data and run by the RPC klicker.
---@description
--- A live check used to be prose ("open :UI, look whether the rows read well"). A sheet keeps the
--- same check as data in `TESTS/sheets/<name>.sheet.lua`, so that the part a machine can do runs with
--- the suite and only the judgement is left for a person:
---
---   return {
---     id = "ui.option-float",                -- stable; the spec case is called `sheet:<id>`
---     title = ":UI option float",
---     task = "ui.nvim/try-the-ui-option-float-in-a-real-session",
---     engine = "rpc",                         -- "rpc" (testing.rpc) or "manual" (nothing to run)
---     sizes = { { rows = 24, cols = 80 } },   -- one run per size; default 24x80
---     steps = {
---       { keys = ":UI<CR>", note = "open the float" },
---       { wait = "vim.api.nvim_win_get_config(0).relative ~= ''" },
---       { screen = "float", masks = { { row = 24 } } },
---       { keys = "q" },
---       { expect = "vim.api.nvim_win_get_config(0).relative == ''", note = "the float is gone" },
---     },
---     judge = { "rows and texts read well" },  -- criteria for a person (or later an AI reviewer)
---     manual = { "press <M-h> in the real config" },  -- steps only a person can do
---   }
---
--- Steps (exactly one action each, `note` optional):
---
---   keys = s      typed through `child.feed` (mappings apply; returns when the typeahead is empty);
---                 an error message the keys cause (`v:errmsg`) fails the step, unless
---                 `ignore_errmsg = true` (a mapping that runs `silent! cmd` on purpose still sets it)
---   input = s     queued through `child.input` (returns at once)
---   lua = s       run in the child (`child.lua`)
---   settle = ms   wait until the child is idle (`child.settle`; not idle is a failure)
---   wait = expr   poll a Lua expression in the child until it is truthy (`timeout` ms, default 2000)
---   expect = expr a Lua expression in the child must be truthy now
---   screen = name compare the screen with a snapshot (`testing.screen`; `masks`, `cursor`, `mode`
---                 pass through); the name gets the size: `float.80x24`
---
--- The file is loaded as DATA: `load` with an empty environment, so a sheet cannot call anything
--- while it is read; what runs is the Lua of its steps, in the child editor. `load` checks the shape
--- and names the field of a mistake.

local M = {}

M.VERSION = 1
M.ENGINES = { rpc = true, manual = true }
M.ACTIONS = { "keys", "input", "lua", "settle", "wait", "expect", "screen" }
M.DEFAULT_MINIT = "TESTS/minimal_init.lua"
M.DEFAULT_WAIT_MS = 2000
M.MAX_BYTES = 256 * 1024

---@class Testing.Sheet.Step
---@field keys? string
---@field input? string
---@field lua? string
---@field settle? integer
---@field wait? string
---@field timeout? integer Milliseconds of a `wait`.
---@field expect? string
---@field screen? string
---@field masks? (string|table)[]
---@field cursor? boolean
---@field mode? boolean
---@field note? string

---@class Testing.Sheet
---@field id string
---@field title string
---@field task? string
---@field engine "rpc"|"manual"
---@field minit? string Relative to the root (default `TESTS/minimal_init.lua`).
---@field sizes { rows: integer, cols: integer }[]
---@field steps Testing.Sheet.Step[]
---@field judge string[]
---@field manual string[]
---@field notes? string
---@field path? string Where it was loaded from.

---@class Testing.Sheet.Result
---@field ok boolean
---@field status "pass"|"fail"|"manual"
---@field failures string[] One line per failed step (size, step number, what).
---@field snapshots string[] The messages of the screen steps (written, matched, updated).

local STEP_KEYS = {
  keys = "string",
  input = "string",
  lua = "string",
  settle = "number",
  wait = "string",
  timeout = "number",
  expect = "string",
  screen = "string",
  masks = "table",
  cursor = "boolean",
  mode = "boolean",
  note = "string",
  ignore_errmsg = "boolean",
}
local SHEET_KEYS = {
  id = "string",
  title = "string",
  task = "string",
  engine = "string",
  minit = "string",
  sizes = "table",
  steps = "table",
  judge = "table",
  manual = "table",
  notes = "string",
}

---@param v any
---@return boolean
local function is_list(v)
  if type(v) ~= "table" then
    return false
  end
  -- every key an integer 1..n and n keys: `{ nil, x, y = 1 }` has `#v == 2` and two keys, yet
  -- `ipairs` sees nothing of it
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if v[i] == nil then
      return false
    end
  end
  return true
end

---Upper bounds: an endless wait (`timeout = 1/0`) or a screen of a billion rows is a mistake, not a check.
M.MAX_MS = 10 * 60 * 1000
M.MAX_CELLS = 1000

---@param v any
---@param max number
---@return boolean
local function pos_int(v, max)
  return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= max
end

---@param list any
---@param what string
---@return string|nil err
local function check_strings(list, what)
  if list == nil then
    return nil
  end
  if not is_list(list) then
    return what .. " must be a list of strings"
  end
  for i, s in ipairs(list) do
    if type(s) ~= "string" or s == "" then
      return ("%s[%d] must be a non-empty string"):format(what, i)
    end
  end
  return nil
end

---@param step any
---@param i integer
---@return string|nil err
local function check_step(step, i)
  local at = ("steps[%d]"):format(i)
  if type(step) ~= "table" then
    return at .. " must be a table"
  end
  for k, v in pairs(step) do
    local want = STEP_KEYS[k]
    if not want then
      return ("%s: unknown field %s"):format(at, tostring(k))
    end
    if type(v) ~= want then
      return ("%s.%s must be a %s"):format(at, k, want)
    end
  end
  local action
  for _, a in ipairs(M.ACTIONS) do
    if step[a] ~= nil then
      if action then
        return ("%s has two actions (%s and %s): one per step"):format(at, action, a)
      end
      action = a
    end
  end
  if not action then
    return at .. " has no action (one of " .. table.concat(M.ACTIONS, ", ") .. ")"
  end
  if
    (action == "settle" and not pos_int(step.settle, M.MAX_MS))
    or (step.timeout and not pos_int(step.timeout, M.MAX_MS))
  then
    return at .. ": milliseconds must be a whole number from 1 to " .. M.MAX_MS
  end
  if step.ignore_errmsg ~= nil and action ~= "keys" then
    return at .. ": ignore_errmsg belongs to a keys step"
  end
  if step.timeout and action ~= "wait" then
    return at .. ": timeout belongs to a wait step"
  end
  if (step.masks or step.cursor ~= nil or step.mode ~= nil) and action ~= "screen" then
    return at .. ": masks, cursor and mode belong to a screen step"
  end
  if action == "screen" and not step.screen:match("^[%w][%w_%-]*$") then
    return at .. ".screen: letters, digits, '_' and '-'"
  end
  return nil
end

---Check the shape of a sheet; fills the defaults.
---@param s any
---@return Testing.Sheet|nil sheet, string|nil err
function M.validate(s)
  if type(s) ~= "table" then
    return nil, "a sheet returns a table"
  end
  for k, v in pairs(s) do
    local want = SHEET_KEYS[k]
    if not want then
      return nil, "unknown field " .. tostring(k)
    end
    if type(v) ~= want then
      return nil, ("%s must be a %s"):format(k, want)
    end
  end
  if not s.id or not s.id:match("^[%w][%w_.%-]*$") then
    return nil, "id: letters, digits, '_', '-', '.'"
  end
  if not s.title or s.title == "" then
    return nil, "title is required"
  end
  s.engine = s.engine or "rpc"
  if not M.ENGINES[s.engine] then
    return nil, "engine must be rpc or manual"
  end
  s.steps = s.steps or {}
  if not is_list(s.steps) then
    return nil, "steps must be a list"
  end
  for i, step in ipairs(s.steps) do
    local err = check_step(step, i)
    if err then
      return nil, err
    end
  end
  if s.engine == "rpc" and #s.steps == 0 then
    return nil, "an rpc sheet needs steps"
  end
  if s.engine == "manual" and #s.steps > 0 then
    return nil, "a manual sheet has no steps (manual = { ... } instead)"
  end
  s.sizes = s.sizes or { { rows = 24, cols = 80 } }
  if not is_list(s.sizes) or #s.sizes == 0 then
    return nil, "sizes must be a non-empty list"
  end
  for i, size in ipairs(s.sizes) do
    if
      type(size) ~= "table"
      or not pos_int(size.rows, M.MAX_CELLS)
      or not pos_int(size.cols, M.MAX_CELLS)
    then
      return nil,
        ("sizes[%d] must be { rows = n, cols = n } with 1 <= n <= %d"):format(i, M.MAX_CELLS)
    end
  end
  for _, f in ipairs({ "judge", "manual" }) do
    local err = check_strings(s[f], f)
    if err then
      return nil, err
    end
    s[f] = s[f] or {}
  end
  if s.engine == "manual" and #s.manual == 0 then
    return nil, "a manual sheet lists its manual steps"
  end
  return s, nil
end

---Read a sheet file as data (empty environment) and validate it.
---@param path string
---@return Testing.Sheet|nil sheet, string|nil err
function M.load(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local text = f:read(M.MAX_BYTES + 1) or ""
  f:close()
  if #text > M.MAX_BYTES then
    return nil, ("%s is larger than %d bytes"):format(path, M.MAX_BYTES)
  end
  local chunk, perr = load(text, "@" .. path, "t", {})
  if not chunk then
    return nil, tostring(perr)
  end
  local ok, value = pcall(chunk)
  if not ok then
    return nil, tostring(value) -- already starts with `<path>:<line>:` (the chunk name)
  end
  local s, err = M.validate(value)
  if not s then
    return nil, ("%s: %s"):format(path, err)
  end
  s.path = path
  return s, nil
end

---The sheet files below `dir`, sorted (`*.sheet.lua`).
---@param dir string
---@return string[]
function M.files(dir)
  local out = {}
  dir = vim.fs.normalize(dir)
  if vim.fn.isdirectory(dir) == 0 then
    return out
  end
  for name, kind in vim.fs.dir(dir, { depth = 4 }) do
    if (kind == "file" or kind == "link") and name:match("%.sheet%.lua$") then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  table.sort(out)
  return out
end

---The name of the spec case that runs a sheet; the report finds the last result by it.
---@param s Testing.Sheet|string
---@return string
function M.spec_name(s)
  return "sheet:" .. (type(s) == "table" and s.id or s)
end

---@param step Testing.Sheet.Step
---@return string
local function describe(step)
  for _, a in ipairs(M.ACTIONS) do
    if step[a] ~= nil then
      -- one short line: a multi-line `wait`/`lua` would push the reason off the first line
      local value = tostring(step[a]):gsub("%s+", " ")
      if #value > 60 then
        value = value:sub(1, 57) .. "..."
      end
      local what = ("%s %s"):format(a, value)
      return step.note and (step.note .. " (" .. what .. ")") or what
    end
  end
  return "?"
end

---@param v any
---@return string
local function shown(v)
  local s = vim.inspect(v)
  return #s > 200 and (s:sub(1, 200) .. "...") or s
end

---Run one step; returns nil or the reason it failed.
---@param child table testing.rpc handle
---@param step Testing.Sheet.Step
---@param ctx { sheet: Testing.Sheet, size: table, root: string, opts: table, snapshots: string[] }
---@return string|nil
local function run_step(child, step, ctx)
  if step.keys then
    -- an error the keys caused (`E492: Not an editor command`) fails the step; feed itself never raises
    child.lua("vim.v.errmsg = ''")
    child.feed(step.keys)
    local msg = child.lua_get("vim.v.errmsg")
    if msg ~= nil and msg ~= "" and not step.ignore_errmsg then
      return "the keys caused an error: " .. msg
    end
  elseif step.input then
    child.input(step.input)
  elseif step.lua then
    child.lua(step.lua)
  elseif step.settle then
    local idle, why = child.settle(step.settle)
    if not idle then
      return why or "not idle"
    end
  elseif step.wait then
    -- a loop of its own: every poll is an RPC call that waits with `vim.wait` itself, and a
    -- `vim.wait` inside the condition of another one does not keep the outer deadline
    local timeout = step.timeout or M.DEFAULT_WAIT_MS
    local deadline = vim.uv.hrtime() + timeout * 1e6
    local last
    while true do
      last = child.lua_get(step.wait)
      if last then
        break
      end
      if vim.uv.hrtime() >= deadline then
        return ("still %s after %d ms"):format(shown(last), timeout)
      end
      vim.wait(20)
    end
  elseif step.expect then
    local v = child.lua_get(step.expect)
    if not v then
      return "got " .. shown(v)
    end
  elseif step.screen then
    local name = ("%s.%dx%d"):format(step.screen, ctx.size.cols, ctx.size.rows)
    local res = require("testing.screen").compare(name, child.screen(), {
      root = ctx.root,
      file = ctx.sheet.path,
      masks = step.masks,
      cursor = step.cursor,
      mode = step.mode,
      update = ctx.opts.update,
      ci = ctx.opts.ci,
    })
    ctx.snapshots[#ctx.snapshots + 1] = res.message
    if not res.ok then
      return res.message
    end
  end
  return nil
end

---Run a sheet: one child editor per size, the steps in order; the first failed step ends that size.
---@param s Testing.Sheet
---@param opts? { root?: string, update?: boolean, ci?: boolean, spawn?: table }
---@return Testing.Sheet.Result
function M.run(s, opts)
  opts = opts or {}
  local result = { ok = true, status = "pass", failures = {}, snapshots = {} }
  if s.engine == "manual" then
    result.status = "manual"
    return result
  end
  local root =
    vim.fs.normalize(vim.fn.fnamemodify(opts.root or vim.fn.getcwd(), ":p")):gsub("/+$", "")
  local minit = s.minit or M.DEFAULT_MINIT
  -- absolute: a drive (`C:/`, `C:\`), a POSIX root or a UNC path in either slash style
  if not minit:match("^%a:[/\\]") and not minit:match("^[/\\]") then
    minit = root .. "/" .. minit
  end
  for _, size in ipairs(s.sizes) do
    local tag = ("%dx%d"):format(size.cols, size.rows)
    local spawn = vim.tbl_extend(
      "force",
      { root = root, minit = minit, size = size, guard = false },
      opts.spawn or {}
    )
    -- a spawn that raises is a failure of this size, not an error out of `run` (expect hands the
    -- verdict to the harness, it must not throw past it)
    local spawned, child, err = pcall(require("testing.rpc").spawn, spawn)
    if not spawned then
      child, err = nil, child
    end
    if not child then
      result.failures[#result.failures + 1] = ("%s: the child did not start: %s"):format(
        tag,
        tostring(err)
      )
    else
      local ctx = { sheet = s, size = size, root = root, opts = opts, snapshots = result.snapshots }
      local ok, perr = pcall(function()
        -- attach the UI first: the editor lays out windows (floats too) for the size of its UI
        child.screen()
        for i, step in ipairs(s.steps) do
          local why = run_step(child, step, ctx)
          if why then
            result.failures[#result.failures + 1] = ("%s step %d, %s: %s"):format(
              tag,
              i,
              describe(step),
              why
            )
            return
          end
        end
      end)
      if not ok then
        result.failures[#result.failures + 1] = ("%s: %s"):format(tag, tostring(perr))
      end
      pcall(child.kill)
    end
  end
  if #result.failures > 0 then
    result.ok, result.status = false, "fail"
  end
  return result
end

---@param target string|Testing.Sheet
---@param opts? table
---@return Testing.Sheet|nil sheet, Testing.Sheet.Result|string result_or_err
local function load_and_run(target, opts)
  if type(target) ~= "string" then
    return target, M.run(target, opts)
  end
  local s, err = M.load(target)
  if not s then
    return nil, tostring(err)
  end
  return s, M.run(s, opts)
end

---Every failed step on the FIRST line: the state and the report keep only that line of a message.
---@param s Testing.Sheet
---@param res Testing.Sheet.Result
---@return string
local function failed_text(s, res)
  -- the first line of each failure (size, step, reason) on the first line; details such as a
  -- snapshot diff follow on the lines below
  local firsts, details = {}, {}
  for _, f in ipairs(res.failures) do
    local first, more = f:match("^([^\n]*)\n?(.*)$")
    firsts[#firsts + 1] = first
    if more and more ~= "" then
      details[#details + 1] = more
    end
  end
  local text = ("test sheet %s failed: %s"):format(s.id, table.concat(firsts, "; "))
  if #details > 0 then
    text = text .. "\n" .. table.concat(details, "\n")
  end
  return text
end
M._failed_text = failed_text -- for the spec

---Run a sheet and raise on a failure (busted style specs): `it(sheet.spec_name(s), function() sheet.check(path) end)`.
---@param target string|Testing.Sheet A path or a loaded sheet.
---@param opts? table As `run`.
---@return Testing.Sheet.Result
function M.check(target, opts)
  local s, res = load_and_run(target, opts)
  if not s then
    error("test sheet: " .. tostring(res), 2)
  end
  ---@cast res Testing.Sheet.Result
  if not res.ok then
    error(failed_text(s, res), 2)
  end
  return res
end

---Run a sheet and hand the verdict to the harness: `ok_fn(ok, message)`.
---@param ok_fn fun(ok: boolean, msg?: string): any
---@param target string|Testing.Sheet
---@param opts? table As `run`.
---@return boolean ok, Testing.Sheet.Result|string result
function M.expect(ok_fn, target, opts)
  local s, res = load_and_run(target, opts)
  if not s then
    ok_fn(false, "test sheet: " .. tostring(res))
    return false, res
  end
  ---@cast res Testing.Sheet.Result
  local msg = res.ok and ("test sheet %s: %s"):format(s.id, res.status) or failed_text(s, res)
  ok_fn(res.ok, msg)
  return res.ok, res
end

return M
