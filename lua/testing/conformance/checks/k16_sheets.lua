---@module 'testing.conformance.checks.k16_sheets'
-- @cache-env TASKS_VAULT TASKS_NVIM_DIR
---@brief K16: every test sheet loads and names a task that exists in the vault (open or finished).
---@description
--- A test sheet (`TESTS/sheets/*.sheet.lua`, `testing.sheet`) names the live-check task it checks. A sheet whose
--- task was renamed or never existed keeps running and reporting, but nothing ever reads its state again:
--- `testing sheets report --tasks` lists it as missing, this check makes it a finding of the gate.
---
---   * a sheet that cannot be read or does not load                    -> `error`
---   * a sheet without `task`                                          -> `warn`
---   * a task that is neither open nor in its area's Backlog (or no id) -> `error`
---
--- The tasks are looked up through tasks.nvim's engine (`tasks-export/1`), never in the vault's files: ONE
--- `call order` for the ids of all open tasks, then every page of `call finished` of each area that still has a
--- task not found (an area the engine does not know, or an id it rejects, has none). The first answer that is not
--- a document stops the lookup: the check is `error`, and no task reads as missing. The vault is `$TASKS_VAULT`,
--- else `tasks-vault` beside the repository (`testing.sheet.new.find_vault`); without one, or without the engine,
--- the lookup is skipped and the check is `n/a` (a CI runner has no vault), never a failure. No reason names a
--- path of this machine. The sheets are the ones `testing.sheet.files` runs (up to 4 levels below
--- `TESTS/sheets`; a symbolic link is not followed here), read through `ctx.fs` and loaded as data
--- (`testing.sheet.load_text`, under its instruction limit).

local util = require("testing.conformance.util")

local M = {
  id = "K16",
  title = "test sheets name a task of the vault",
  rules = {},
  kind = "vault",
  level = "error",
}

M.DIR = "TESTS/sheets"
-- the depth `testing.sheet.files` looks into
M.MAX_DEPTH = 4

---The caller of the engine and the paths its messages must not show, or why there is none (no path in it).
---@param ctx Testing.Conformance.Ctx
---@return Testing.SheetTasks.Call|nil call, string[]|string hide_or_why
local function connect(ctx)
  local t = ctx.tasks or {}
  if t.call then
    return t.call, {}
  end
  local vault =
    require("testing.sheet.new").find_vault(ctx.root, t.vault, t.getenv or vim.uv.os_getenv)
  if not vault then
    return nil, "no vault (set TASKS_VAULT, or put tasks-vault beside the repository)"
  end
  local tasks = require("testing.sheet.tasks")
  local cli = tasks.locate(vault, { getenv = t.getenv })
  if not cli then
    return nil,
      "tasks.nvim not found (TASKS_NVIM_DIR, <vault>/.deps/tasks.nvim, <vault>/../tasks.nvim, lazy)"
  end
  return tasks.caller(cli, vault), { vault, vim.fs.dirname(vim.fs.dirname(cli)) }
end

---The first line of an engine message with the vault and the engine's checkout replaced.
---@param msg any
---@param hide string[]
---@return string
local function redact(msg, hide)
  local s = tostring(msg):match("^[^\r\n]*") or ""
  for i, p in ipairs(hide) do
    local name = i == 1 and "<VAULT>" or "<TASKS_NVIM>"
    for _, form in ipairs({ p, (p:gsub("/", "\\")) }) do
      s = s:gsub(vim.pesc(form), (name:gsub("%%", "%%%%")))
    end
  end
  return s
end

---Every page of a document's id list (`order`: `ids`; `finished`: `items[].id`).
---@param call Testing.SheetTasks.Call
---@param method "order"|"finished"
---@param params table
---@return table<string, boolean>|nil ids, string|nil err, string|nil code
local function ids_of(call, method, params)
  local ids, offset = {}, 0
  while true do
    local p = vim.deepcopy(params)
    if method == "finished" then
      p.offset = offset
    end
    local doc, err, code = call(method, p)
    if not doc then
      return nil, err, code
    end
    if method == "order" then
      for _, id in ipairs(type(doc.ids) == "table" and doc.ids or {}) do
        ids[tostring(id)] = true
      end
      return ids
    end
    local items = type(doc.items) == "table" and doc.items or {}
    for _, item in ipairs(items) do
      if type(item) == "table" and type(item.id) == "string" then
        ids[item.id] = true
      end
    end
    local next_offset = tonumber(doc.next_offset)
    if not next_offset or next_offset <= offset or #items == 0 then
      return ids
    end
    offset = next_offset
  end
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local rels = {}
  for _, rel in ipairs(ctx.fs:walk(M.DIR, { ext = "lua" })) do
    local _, depth = rel:sub(#M.DIR + 2):gsub("/", "")
    if rel:match("%.sheet%.lua$") and depth < M.MAX_DEPTH then
      rels[#rels + 1] = rel
    end
  end
  if #rels == 0 then
    return { na = "no test sheets (" .. M.DIR .. "/*.sheet.lua)" }
  end
  local sheet = require("testing.sheet")
  local findings = {}
  local wanted, order = {}, {}
  for _, rel in ipairs(rels) do
    local text, rerr = ctx.fs:read(rel)
    local s, lerr
    if text then
      s, lerr = sheet.load_text(text, rel)
    else
      lerr = ("%s cannot be read: %s"):format(rel, tostring(rerr))
    end
    if not s then
      findings[#findings + 1] = util.finding(
        "K16",
        "sheet",
        "error",
        "the sheet does not load: " .. (tostring(lerr):match("^[^\n]*") or "?"),
        rel
      )
    elseif not s.task then
      findings[#findings + 1] = util.finding(
        "K16",
        "sheet",
        "warn",
        'the sheet names no task (`task = "<area>/<slug>"`)',
        rel
      )
    else
      if not wanted[s.task] then
        wanted[s.task] = {}
        order[#order + 1] = s.task
      end
      table.insert(wanted[s.task], rel)
    end
  end
  local notes = { ("%d sheet(s), %d task(s) named"):format(#rels, #order) }
  if #order == 0 then
    return { findings = findings, notes = notes }
  end
  local call, hide = connect(ctx)
  if not call then
    local why = "the tasks were not looked up: " .. tostring(hide)
    if #findings == 0 then
      return { na = why }
    end
    notes[#notes + 1] = why
    return { findings = findings, notes = notes }
  end
  ---@cast hide string[]
  local function failed(err)
    return {
      findings = findings,
      notes = notes,
      error = "the vault could not be asked: " .. redact(err, hide),
    }
  end
  local open, oerr = ids_of(call, "order", {})
  if not open then
    return failed(oerr)
  end
  table.sort(order)
  local done_of = {}
  for _, id in ipairs(order) do
    local found = open[id] == true
    local area = id:match("^([^/]+)/[^/]+$")
    if not found and area then
      if not done_of[area] then
        local ids, ferr, code = ids_of(call, "finished", { area = area })
        if not ids then
          -- an area the engine does not know (or cannot take as one) has no finished task
          if code ~= "not_found" and code ~= "invalid_argument" then
            return failed(ferr)
          end
          ids = {}
        end
        done_of[area] = ids
      end
      found = done_of[area][id] == true
    end
    if not found then
      for _, rel in ipairs(wanted[id]) do
        findings[#findings + 1] = util.finding(
          "K16",
          "sheet",
          "error",
          ("task %s is neither an open task nor in the Backlog of the vault"):format(id),
          rel
        )
      end
    end
  end
  return { findings = findings, notes = notes }
end

return M
