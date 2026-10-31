---@module 'testing.conformance.checks.k16_sheets'
-- @cache-env TASKS_VAULT TASKS_NVIM_DIR
---@brief K16: every test sheet loads and names a task that exists in the vault (open or finished).
---@description
--- A test sheet (`TESTS/sheets/*.sheet.lua`, `testing.sheet`) names the live-check task it checks. A sheet whose
--- task was renamed or never existed keeps running and reporting, but nothing ever reads its state again:
--- `testing sheets report --tasks` lists it as missing, this check makes it a finding of the gate.
---
---   * a sheet that cannot be read or does not load            -> `error`
---   * a sheet without `task`                                  -> `warn`
---   * a task that is neither open nor in its area's Backlog   -> `error`
---
--- The tasks are looked up through tasks.nvim's engine (`tasks-export/1`: `call task`, then `call finished` of the
--- area), never in the vault's files. The vault is `$TASKS_VAULT`, else `tasks-vault` beside the repository
--- (`testing.sheet.new.find_vault`); without one, or without the engine, the lookup is skipped and the check is
--- `n/a` with the reason (a CI runner has no vault), never a failure. The sheets are read through `ctx.fs` and
--- loaded as data (`testing.sheet.load_text`), nothing of them runs.

local util = require("testing.conformance.util")

local M = {
  id = "K16",
  title = "test sheets name a task of the vault",
  rules = {},
  kind = "vault",
  level = "error",
}

M.DIR = "TESTS/sheets"

---The caller of the engine, or why there is none.
---@param ctx Testing.Conformance.Ctx
---@return Testing.SheetTasks.Call|nil call, string|nil why
local function connect(ctx)
  local t = ctx.tasks or {}
  if t.call then
    return t.call
  end
  local vault, verr =
    require("testing.sheet.new").find_vault(ctx.root, t.vault, t.getenv or vim.uv.os_getenv)
  if not vault then
    return nil, verr
  end
  local tasks = require("testing.sheet.tasks")
  local cli, lerr = tasks.locate(vault, { getenv = t.getenv })
  if not cli then
    return nil, "tasks.nvim not found: " .. tostring(lerr)
  end
  return tasks.caller(cli, vault)
end

---The ids of the finished tasks of `area` (every page of `call finished`); an unknown area has none.
---@param call Testing.SheetTasks.Call
---@param area string
---@return table<string, boolean>|nil ids, string|nil err
local function finished(call, area)
  local ids, offset = {}, 0
  while true do
    local doc, err, code = call("finished", { area = area, offset = offset })
    if not doc then
      if code == "not_found" then
        return ids
      end
      return nil, err
    end
    local items = type(doc.items) == "table" and doc.items or {}
    for _, item in ipairs(items) do
      if type(item) == "table" and type(item.id) == "string" then
        ids[item.id] = true
      end
    end
    offset = offset + #items
    if #items == 0 or offset >= (tonumber(doc.total) or 0) then
      return ids
    end
  end
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local rels = {}
  for _, rel in ipairs(ctx.fs:walk(M.DIR, { ext = "lua" })) do
    if rel:match("%.sheet%.lua$") then
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
  local call, why = connect(ctx)
  if not call then
    if #findings == 0 then
      return { na = "the tasks were not looked up: " .. tostring(why) }
    end
    notes[#notes + 1] = "the tasks were not looked up: " .. tostring(why)
    return { findings = findings, notes = notes }
  end
  table.sort(order)
  local done_of, failures = {}, {}
  for _, id in ipairs(order) do
    local area = id:match("^([^/]+)/[^/]+$")
    local found = false
    if area then
      local doc, err, code = call("task", { id = id })
      if doc then
        found = true
      elseif code ~= "not_found" then
        failures[#failures + 1] = tostring(err)
        found = true -- not known either way: reported as an error below, not as a missing task
      else
        if done_of[area] == nil then
          local ids, ferr = finished(call, area)
          if not ids then
            failures[#failures + 1] = tostring(ferr)
          end
          done_of[area] = ids or false
        end
        -- a Backlog that could not be read is reported as an error below, not as a missing task
        found = done_of[area] == false or done_of[area][id] == true
      end
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
  local outcome = { findings = findings, notes = notes }
  if #failures > 0 then
    outcome.error = "the vault could not be asked: " .. table.concat(failures, "; ")
  end
  return outcome
end

return M
