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
-- The last line inside the block: `<!-- testing:sheets:states <id>=<state> ... -->`, the contract tasks.nvim reads.
M.STATES = "<!-- testing:sheets:states"
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

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---The lines of a body and, per line, whether it is inside (or opens/closes) a fenced code block.
---@param body string
---@return string[] lines, boolean[] fenced
local function lines_of(body)
  local lines, fenced, inside = {}, {}, false
  for line in (body .. "\n"):gmatch("(.-)\n") do
    local fence = line:match("^%s*```") or line:match("^%s*~~~")
    lines[#lines + 1] = line
    fenced[#lines] = inside or fence ~= nil
    if fence then
      inside = not inside
    end
  end
  return lines, fenced
end

---The generated block of a body. Only a marker on a line of its own and outside a fenced code block
---counts (a marker quoted in prose or in code is text); one begin and one end after it is a block.
---@param body string
---@return string|nil block, integer|nil first, integer|nil last, "ok"|"none"|"broken" state
function M.extract(body)
  local lines, fenced = lines_of(body)
  local begins, ends = {}, {}
  for i, line in ipairs(lines) do
    if not fenced[i] then
      local t = trim(line)
      if t == M.BEGIN then
        begins[#begins + 1] = i
      elseif t == M.END then
        ends[#ends + 1] = i
      end
    end
  end
  if #begins == 0 and #ends == 0 then
    return nil, nil, nil, "none"
  end
  if #begins == 1 and #ends == 1 and ends[1] > begins[1] then
    return table.concat(lines, "\n", begins[1], ends[1]), begins[1], ends[1], "ok"
  end
  return nil, nil, nil, "broken"
end

---The texts of the ticked checkboxes of a block (`- [x] text`), trimmed.
---@param block string|nil
---@return table<string, true>
function M.ticked(block)
  local out = {}
  for line in (block or ""):gmatch("[^\n]+") do
    local text = line:match("^%s*%- %[[xX]%] (.-)%s*$")
    if text and text ~= "" then
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

---The machine-readable state of a sheet, for the `states` line of the block (read by tasks.nvim): `red` (failed,
---or the sheet does not load), `stale`, `never`, `inbox`, `manual` or `green`.
---@param e Testing.SheetReport.Entry
---@return string
function M.state_word(e)
  local bucket = require("testing.sheet.report").bucket(e)
  if bucket == "red" then
    if e.sheet and not e.case then
      return "never"
    elseif e.sheet and e.stale then
      return "stale"
    end
    return "red"
  end
  return bucket == "automated" and "green" or bucket
end

---The `<id>=<state>` key of a sheet: its id, or the file name of one that does not load (letters, digits, `_`,
---`-`, `.` only, so the line splits on blanks and never ends the comment).
---@param e Testing.SheetReport.Entry
---@return string
local function state_key(e)
  local key = e.sheet and e.sheet.id or vim.fs.basename(e.rel):gsub("%.sheet%.lua$", "")
  return (key:gsub("[^%w_.%-]", "-"))
end

---The block for the sheets of one task. Paths always name their project (`ui.nvim/TESTS/...`): a task
---lives in a vault beside many projects, and the text must not depend on which roots a report was given.
---@param entries Testing.SheetReport.Entry[] The sheets that name this task.
---@param opts? { ticked?: table<string, true> }
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
    local prefix = vim.fs.basename(e.root) .. "/"
    local where = prefix .. e.rel
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
      out[#out + 1] = "  - Look at: "
        .. table.concat(
          vim.tbl_map(function(p)
            return code(prefix .. p)
          end, e.snapshots),
          ", "
        )
    end
  end
  local states = {}
  for _, e in ipairs(entries) do
    states[#states + 1] = state_key(e) .. "=" .. M.state_word(e)
  end
  out[#out + 1] = M.STATES .. " " .. table.concat(states, " ") .. " -->"
  out[#out + 1] = M.END
  return table.concat(out, "\n")
end

---The body with `block` in it: in place of the old block, else in front of the notes heading (outside a
---fenced code block), else at the end. A body whose markers are broken (a begin without an end, an end in
---front of the begin, two of them) is not touched: nil and why, so that no text between stray markers is
---ever replaced.
---@param body string Line feeds only (`sync` turns CRLF into LF).
---@param block string
---@return string|nil body, string|nil err
function M.apply(body, block)
  local lines, fenced = lines_of(body)
  local _, first, last, st = M.extract(body)
  if st == "broken" then
    return nil,
      "the block markers in the task are broken (a begin without its end, or more than one): fix them by hand"
  end
  local blines = vim.split(block, "\n", { plain = true })
  if st == "ok" then
    local out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, blines)
    vim.list_extend(out, lines, last + 1, #lines)
    return table.concat(out, "\n")
  end
  for i, line in ipairs(lines) do
    if not fenced[i] and (line:match("^## Notizen%s*$") or line:match("^## Notes%s*$")) then
      local out = vim.list_slice(lines, 1, i - 1)
      if #out > 0 and out[#out] ~= "" then
        out[#out + 1] = ""
      end
      vim.list_extend(out, blines)
      out[#out + 1] = ""
      vim.list_extend(out, lines, i, #lines)
      return table.concat(out, "\n")
    end
  end
  return (body:gsub("%s+$", "")) .. "\n\n" .. block .. "\n"
end

M.MAX_OPS = 100
M.MAX_REQUEST_BYTES = 200 * 1024 -- below the 256 KiB of a tasks-ops request, room for the envelope

---Split operations into requests the engine takes: at most `MAX_OPS` and about `MAX_REQUEST_BYTES` each (one
---operation that is larger alone goes in a request of its own and is refused alone).
---@param ops table[]
---@return integer[][] groups indexes into `ops`
local function batches(ops)
  local groups, cur, bytes = {}, {}, 0
  for i, op in ipairs(ops) do
    local size = #vim.json.encode(op)
    if #cur > 0 and (#cur >= M.MAX_OPS or bytes + size > M.MAX_REQUEST_BYTES) then
      groups[#groups + 1] = cur
      cur, bytes = {}, 0
    end
    cur[#cur + 1] = i
    bytes = bytes + size
  end
  if #cur > 0 then
    groups[#groups + 1] = cur
  end
  return groups
end
M._batches = batches -- for the spec

---The bodies of `ids`. `bodies` ends a page at 2 MiB of text (`next_offset`) also for a list of ids: the
---ids that did not come back are asked again until every one came back or a round brings nothing new.
---@param call Testing.SheetTasks.Call
---@param ids string[]
---@return table<string, table>|nil items, boolean|string cut_or_err  true when a page ended before some ids
local function read_bodies(call, ids)
  local items, pending = {}, ids
  for _ = 1, 64 do
    local doc, err = call("bodies", { ids = pending })
    if not doc then
      return nil, err or "bodies failed"
    end
    for _, item in ipairs(doc.items or {}) do
      if type(item) == "table" and type(item.id) == "string" then
        items[item.id] = item
      end
    end
    if doc.next_offset == nil then
      return items, false
    end
    local rest = {}
    for _, id in ipairs(pending) do
      if not items[id] then
        rest[#rest + 1] = id
      end
    end
    if #rest == 0 then
      return items, false
    end
    if #rest == #pending then
      return items, true -- a page that brings none of them: too large to read this way
    end
    pending = rest
  end
  return items, true
end

---Write the state of the sheets into their tasks.
---@param entries Testing.SheetReport.Entry[]
---@param opts { call: Testing.SheetTasks.Call, dry_run?: boolean }
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
  local items, cut = read_bodies(opts.call, ids)
  if not items then
    return nil, tostring(cut)
  end

  local results, ops, op_ids = {}, {}, {}
  for _, id in ipairs(ids) do
    local item = items[id]
    if not item and cut then
      results[#results + 1] =
        { id = id, outcome = "truncated", message = "not read: the bodies page ended before it" }
    elseif not item then
      results[#results + 1] =
        { id = id, outcome = "missing", message = "not an open task of the vault" }
      for _, e in ipairs(by_task[id]) do
        e.task_missing = true
      end
    elseif item.body_truncated then
      results[#results + 1] =
        { id = id, outcome = "truncated", message = "the body is too long to send back" }
    else
      -- set_body refuses a carriage return; the engine keeps the line ending of the file itself
      local body = tostring(item.body or ""):gsub("\r\n?", "\n")
      local block = M.render_block(by_task[id], { ticked = M.ticked((M.extract(body))) })
      local new, aerr = M.apply(body, block)
      if not new then
        results[#results + 1] = { id = id, outcome = "failed", message = aerr }
      elseif trim(new) == trim(body) then
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

  -- at most MAX_OPS operations and about MAX_REQUEST_BYTES per request: one oversized task fails alone
  local by_id, errs = {}, {}
  for _, group in ipairs(batches(ops)) do
    local chunk = {}
    for _, i in ipairs(group) do
      chunk[#chunk + 1] = ops[i]
    end
    local res, oerr = opts.call("ops", { schema = 1, client_op_id = "testing-sheets", ops = chunk })
    for k, i in ipairs(group) do
      if not res then
        errs[op_ids[i]] = oerr or "ops failed"
      end
      for _, r in ipairs(res and res.results or {}) do
        if type(r) == "table" and r.n == k then
          by_id[op_ids[i]] = r
        end
      end
    end
  end
  for _, r in ipairs(results) do
    if r.outcome == "changed" then
      local got = by_id[r.id]
      if errs[r.id] then
        r.outcome, r.message = "failed", errs[r.id]
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
  return results
end

return M
