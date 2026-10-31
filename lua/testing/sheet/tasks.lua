---@module 'testing.sheet.tasks'
---@brief The state of the test sheets, written into the tasks they check (tasks.nvim, `tasks-export/1`).
---@description
--- A sheet names its live-check task (`task = "ui.nvim/..."`). `testing sheets report --tasks <vault>` puts
--- the state of every sheet into that task as a generated block:
---
---   <!-- testing:sheets:begin -->
---   ## Test sheets
---   ...one entry per sheet: state, the judge criteria and manual steps as checkboxes, the snapshots...
---   <!-- testing:sheets:end -->
---
--- The block replaces the one a task already has, else it goes in front of `## Notizen` / `## Notes`, else at
--- the end. A criterion ticked in the task (by hand or by an app) stays ticked when the block is written
--- again. It carries no date, so a task changes only when the state of its sheets does.
---
--- Reading and writing go through the engine of tasks.nvim, never into the files: one `call bodies` for all
--- tasks (body and `etag`), one `call ops` with a `set_body` per changed task and `if_match` = that `etag`, so
--- a task edited in between is a `conflict`, not overwritten. A task that is not open (finished, or unknown)
--- does not come back from `bodies` and is reported as missing. The engine is found like a dependency:
--- `$TASKS_NVIM_DIR`, `<vault>/.deps/tasks.nvim`, `<vault>/../tasks.nvim`, `stdpath('data')/lazy/tasks.nvim`.

local M = {}

M.BEGIN = "<!-- testing:sheets:begin -->"
M.END = "<!-- testing:sheets:end -->"
M.TIMEOUT_MS = 60000
M.MAX_IDS = 1000

---@alias Testing.SheetTasks.Call fun(method: string, params: table): table|nil, string|nil

---@class Testing.SheetTasks.Result
---@field id string
---@field outcome "changed"|"unchanged"|"would_change"|"missing"|"truncated"|"failed"
---@field message? string

---The CLI of tasks.nvim for a vault.
---@param vault string
---@param opts? { cli?: string, getenv?: fun(name: string): string|nil }
---@return string|nil cli, string|nil err
function M.locate(vault, opts)
  opts = opts or {}
  if opts.cli then
    if vim.uv.fs_stat(opts.cli) then
      return opts.cli
    end
    return nil, "tasks.nvim CLI not found: " .. opts.cli
  end
  local r, err = require("testing.deps").resolve(
    "tasks.nvim",
    vault,
    { marker = "lua/tasks_nvim", fallback = false, getenv = opts.getenv }
  )
  if not r then
    return nil, err
  end
  return r.dir .. "/scripts/tasks.lua"
end

---A caller of `tasks call <method> --params=-` in a headless editor of its own.
---@param cli string
---@param vault string
---@param opts? { timeout_ms?: integer, nvim?: string }
---@return Testing.SheetTasks.Call
function M.caller(cli, vault, opts)
  opts = opts or {}
  local nvim = opts.nvim or vim.v.progpath
  return function(method, params)
    local argv = { nvim, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", cli }
    vim.list_extend(argv, { "call", method, "--params=-", "--vault=" .. vault })
    local ok, res = pcall(function()
      return vim
        .system(argv, { stdin = vim.json.encode(params), text = true })
        :wait(opts.timeout_ms or M.TIMEOUT_MS)
    end)
    if not ok then
      return nil, ("tasks.nvim call %s could not start: %s"):format(method, tostring(res))
    end
    local last
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
      last = line
    end
    local dok, doc =
      pcall(vim.json.decode, last or "", { luanil = { object = true, array = true } })
    if not dok or type(doc) ~= "table" then
      local why = ((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
        :gsub("%s+", " ")
        :sub(1, 300)
      return nil,
        ("tasks.nvim call %s gave no document (exit %s): %s"):format(
          method,
          tostring(res.code),
          why
        )
    end
    if doc.kind == "tasks.error" then
      return nil,
        ("tasks.nvim call %s: %s: %s"):format(method, tostring(doc.code), tostring(doc.message))
    end
    return doc
  end
end

---@param v any
---@return string
local function one_line(v)
  return (tostring(v):gsub("[\r\n]+", " "))
end

---@param v any
---@return string
local function code(v)
  return "`" .. (one_line(v):gsub("`", "'")) .. "`"
end

---The generated block of a body, markers included, or nil.
---@param body string
---@return string|nil block, integer|nil s, integer|nil e  byte range of the block
function M.extract(body)
  local s = body:find(M.BEGIN, 1, true)
  if not s then
    return nil
  end
  local _, e = body:find(M.END, s, true)
  if not e then
    return nil
  end
  return body:sub(s, e), s, e
end

---The texts of the ticked checkboxes of a block (`- [x] text`).
---@param block string|nil
---@return table<string, true>
function M.ticked(block)
  local out = {}
  for line in (block or ""):gmatch("[^\n]+") do
    local text = line:match("^%s*%- %[[xX]%] (.+)$")
    if text then
      out[text] = true
    end
  end
  return out
end

---One line: where the sheet stands.
---@param e Testing.SheetReport.Entry
---@return string
local function state(e)
  local bucket = require("testing.sheet.report").bucket(e)
  if bucket == "red" then
    if not e.sheet then
      return "does not load: " .. one_line(e.error or "?")
    elseif not e.case then
      return "never ran"
    elseif e.stale then
      return ("last result %s is not current: %s"):format(code(e.case.status), one_line(e.stale))
    end
    return ("red: %s"):format(one_line(e.case.message or e.case.status))
  elseif bucket == "inbox" then
    return "automated part green, waiting for your judgement"
  elseif bucket == "manual" then
    return e.sheet.engine == "manual" and "manual sheet"
      or "automated part green, steps by hand left"
  end
  return "green, nothing left for a person"
end

---The block for the sheets of one task.
---@param entries Testing.SheetReport.Entry[] The sheets that name this task.
---@param opts? { ticked?: table<string, true>, multi?: boolean }
---@return string
function M.render_block(entries, opts)
  opts = opts or {}
  local ticked = opts.ticked or {}
  local out = {
    M.BEGIN,
    "## Test sheets",
    "",
    "_Generated by `testing sheets report --tasks`; edit the sheet, not this block (ticked boxes are kept)._",
    "",
  }
  local function box(text, depth)
    local t = one_line(text)
    out[#out + 1] = ("  "):rep(depth) .. (ticked[t] and "- [x] " or "- [ ] ") .. t
  end
  for _, e in ipairs(entries) do
    local where = (opts.multi ~= false and (vim.fs.basename(e.root) .. "/") or "") .. e.rel
    local title = e.sheet and one_line(e.sheet.title) or where
    local id = e.sheet and (code(e.sheet.id) .. ", ") or ""
    out[#out + 1] = ("- **%s** (%s%s): %s"):format(title, id, code(where), state(e))
    if e.sheet and #e.sheet.judge > 0 then
      out[#out + 1] = "  - Judge:"
      for _, j in ipairs(e.sheet.judge) do
        box(j, 2)
      end
    end
    if e.sheet and #e.sheet.manual > 0 then
      out[#out + 1] = "  - By hand:"
      for _, m in ipairs(e.sheet.manual) do
        box(m, 2)
      end
    end
    if #e.snapshots > 0 then
      local prefix = opts.multi ~= false and (vim.fs.basename(e.root) .. "/") or ""
      out[#out + 1] = "  - Look at: "
        .. table.concat(
          vim.tbl_map(function(p)
            return code(prefix .. p)
          end, e.snapshots),
          ", "
        )
    end
  end
  out[#out + 1] = M.END
  return table.concat(out, "\n")
end

---The body with `block` in it: in place of the old block, else in front of the notes, else at the end.
---@param body string
---@param block string
---@return string
function M.apply(body, block)
  local _, s, e = M.extract(body)
  if s then
    return body:sub(1, s - 1) .. block .. body:sub(e + 1)
  end
  local text = "\n" .. body
  for _, heading in ipairs({ "\n## Notizen", "\n## Notes" }) do
    local at = text:find(heading .. "\n", 1, true)
      or (text:sub(-#heading) == heading and #text - #heading + 1)
    if at then
      return text:sub(2, at) .. block .. "\n\n" .. text:sub(at + 1)
    end
  end
  return (body:gsub("%s+$", "")) .. "\n\n" .. block .. "\n"
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Write the state of the sheets into their tasks.
---@param entries Testing.SheetReport.Entry[]
---@param opts { call: Testing.SheetTasks.Call, dry_run?: boolean, multi?: boolean }
---@return Testing.SheetTasks.Result[]|nil results, string|nil err
function M.sync(entries, opts)
  local by_task, ids = {}, {}
  for _, e in ipairs(entries) do
    local id = e.sheet and e.sheet.task
    if id then
      if not by_task[id] then
        by_task[id] = {}
        ids[#ids + 1] = id
      end
      table.insert(by_task[id], e)
    end
  end
  table.sort(ids)
  if #ids == 0 then
    return {}
  end
  if #ids > M.MAX_IDS then
    return nil, ("more than %d tasks named by sheets"):format(M.MAX_IDS)
  end
  local doc, err = opts.call("bodies", { ids = ids })
  if not doc then
    return nil, err
  end
  local items = {}
  for _, item in ipairs(doc.items or {}) do
    if type(item) == "table" and type(item.id) == "string" then
      items[item.id] = item
    end
  end

  local results, ops, op_ids = {}, {}, {}
  for _, id in ipairs(ids) do
    local item = items[id]
    if not item then
      results[#results + 1] =
        { id = id, outcome = "missing", message = "not an open task of the vault" }
      for _, e in ipairs(by_task[id]) do
        e.task_missing = true
      end
    elseif item.body_truncated then
      results[#results + 1] =
        { id = id, outcome = "truncated", message = "the body is too long to send back" }
    else
      local body = tostring(item.body or "")
      local block =
        M.render_block(by_task[id], { ticked = M.ticked(M.extract(body)), multi = opts.multi })
      local new = M.apply(body, block)
      if trim(new) == trim(body) then
        results[#results + 1] = { id = id, outcome = "unchanged" }
      elseif opts.dry_run then
        results[#results + 1] = { id = id, outcome = "would_change" }
      else
        ops[#ops + 1] = { op = "set_body", id = id, body = trim(new), if_match = item.etag }
        op_ids[#ops] = id
        results[#results + 1] = { id = id, outcome = "changed" }
      end
    end
  end
  if #ops > 0 then
    local res, oerr = opts.call("ops", { schema = 1, client_op_id = "testing-sheets", ops = ops })
    local by_id = {}
    for _, r in ipairs(res and res.results or {}) do
      if type(r) == "table" and type(r.n) == "number" and op_ids[r.n] then
        by_id[op_ids[r.n]] = r
      end
    end
    for _, r in ipairs(results) do
      if r.outcome == "changed" then
        local got = by_id[r.id]
        if not res then
          r.outcome, r.message = "failed", oerr
        elseif not got or got.ok == false then
          r.outcome = "failed"
          r.message = got
              and got.error
              and ("%s: %s"):format(tostring(got.error.code), tostring(got.error.message))
            or "no answer for this task"
        elseif got.outcome == "unchanged" then
          r.outcome = "unchanged"
        end
      end
    end
  end
  return results
end

return M
