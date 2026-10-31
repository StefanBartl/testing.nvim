---@module 'testing.sheet.new'
-- @cache-env TASKS_VAULT
---@brief `testing sheets new --from-task <id>`: a draft test sheet made from a live-check task.
---@description
--- Reads the task through tasks.nvim (`call task`) and writes `TESTS/sheets/<slug>.sheet.lua` in the repository:
--- `id` (the task's slug), `title`, `task`, a skeleton that runs as it is (no intro screen, a setup step to
--- fill in, `settle`, one `screen`) and one `judge` entry per acceptance checkbox of the task (`## Akzeptanz` /
--- `## Acceptance`). The sheet is marked as a draft in `notes` and in its header comment: the steps are a
--- start, a person writes the real ones (docs/SHEETS.md). An existing sheet is never overwritten.
---
--- The vault is `--vault <dir>`, else `$TASKS_VAULT`, else `<repo>/../tasks-vault`; the engine is found as
--- for `--tasks` (`testing.sheet.tasks.locate`).

---@class Testing.SheetNew.Deps
---@field call? Testing.SheetTasks.Call A stand-in for the engine (specs).
---@field getenv? fun(name: string): string|nil

local M = {}

M.USAGE =
  "usage: testing sheets new --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--tasks-cli <tasks.lua>] [--name <file-name>]"
M.MAX_JUDGE = 30
M.MAX_TEXT = 300 -- characters of a title or a judge entry (a sheet loads up to 256 KiB)

---A text cut to `M.MAX_TEXT` characters (not bytes, so UTF-8 stays whole).
---@param s string
---@return string
local function cut(s)
  if vim.fn.strchars(s) <= M.MAX_TEXT then
    return s
  end
  return vim.fn.strcharpart(s, 0, M.MAX_TEXT - 1) .. "…"
end

---The fence a line opens (CommonMark: up to 3 spaces, 3+ backticks without a backtick in the info string, or
---3+ tildes).
---@param line string
---@return string|nil
local function opens(line)
  local ticks, info = line:match("^ ? ? ?(```+)(.*)$")
  if ticks and not info:find("`", 1, true) then
    return ticks
  end
  return line:match("^ ? ? ?(~~~+)")
end

---The checkbox texts of the acceptance section of a body (ticked ones too), one line each; headings and
---boxes inside a fenced code block do not count. The section ends at the next heading of level 1 or 2.
---@param body string
---@return string[]
function M.acceptance(body)
  local out, inside, fence = {}, false, nil
  for line in (body .. "\n"):gmatch("(.-)\r?\n") do
    if fence then
      -- a closing fence: the same character, at least as long, nothing but blanks after it
      local close = line:match("^ ? ? ?(" .. fence:sub(1, 1):rep(3) .. "+)%s*$")
      if close and #close >= #fence then
        fence = nil
      end
    else
      local hashes, title = line:match("^ ? ? ?(#+)%s+(.-)%s*$")
      if not hashes then
        hashes = line:match("^ ? ? ?(#+)%s*$")
        title = ""
      end
      if opens(line) then
        fence = opens(line)
      elseif hashes and #hashes <= 6 then
        title = title:gsub("%s+#+$", ""):gsub("^#+$", "")
        if #hashes <= 2 then
          inside = title == "Akzeptanz" or title == "Acceptance"
        end
      elseif inside then
        local text = line:match("^%s*[-*+] %[[ xX]%] (.-)%s*$")
          or line:match("^%s*%d+[.)] %[[ xX]%] (.-)%s*$")
        if text and text ~= "" and #out < M.MAX_JUDGE then
          out[#out + 1] = cut(text)
        end
      end
    end
  end
  return out
end

---A sheet id from a task slug: the letters, digits, `_`, `-`, `.` the id allows.
---@param slug string
---@return string
function M.id_of(slug)
  local id = slug:gsub("[^%w_.%-]", "-"):gsub("^[^%w]+", "")
  return id ~= "" and id or "sheet"
end

---The text of the draft sheet.
---@param task { id: string, title: string, sheet_id: string }
---@param judge string[]
---@return string
function M.render(task, judge)
  local q = function(s)
    return ("%q"):format(s)
  end
  local out = {
    "-- Live check as a test sheet, drafted by `testing sheets new --from-task " .. task.id .. "`.",
    "-- DRAFT: the steps are a skeleton. Write what a person would do (docs/SHEETS.md of testing.nvim),",
    "-- run the spec once to write the snapshot, review it, then drop the DRAFT note below.",
    "return {",
    "  id = " .. q(task.sheet_id) .. ",",
    "  title = " .. q(task.title) .. ",",
    "  task = " .. q(task.id) .. ",",
    '  engine = "rpc",',
    '  notes = "DRAFT: generated from the task; the steps are a skeleton",',
    "  steps = {",
    '    { lua = \'vim.opt.shortmess:append("I")\', note = "no intro screen (it names the Neovim version)" },',
    '    { lua = "-- set up the plugin here", note = "setup" },',
    "    { settle = 2000 },",
    '    { screen = "start" },',
    "  },",
  }
  if #judge > 0 then
    out[#out + 1] = "  judge = {"
    for _, j in ipairs(judge) do
      out[#out + 1] = "    " .. q(j) .. ","
    end
    out[#out + 1] = "  },"
  else
    out[#out + 1] = "  judge = { "
      .. q("The live check of the task passes: " .. task.title)
      .. " },"
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

---@param repo string
---@param given? string
---@param getenv fun(name: string): string|nil
---@return string|nil vault, string|nil err
local function find_vault(repo, given, getenv)
  local v = given or getenv("TASKS_VAULT")
  if not v or v == "" then
    v = vim.fs.dirname(repo) .. "/tasks-vault"
  end
  if vim.fn.isdirectory(v) ~= 1 then
    return nil, "no vault: pass --vault <dir> or set TASKS_VAULT (" .. v .. " is not a directory)"
  end
  return vim.fs.normalize(v)
end

---`testing sheets new`: exit 0 written, 2 bad usage or the sheet exists, 3 the task could not be read or the
---file not written.
---@param argv string[] The arguments after `new`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetNew.Deps
---@return integer
function M.main(argv, sv, deps)
  deps = deps or {}
  local o = {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key = ({
      ["--from-task"] = "id",
      ["--repo"] = "repo",
      ["--vault"] = "vault",
      ["--tasks-cli"] = "cli",
      ["--name"] = "name",
    })[a]
    if not key or not argv[i + 1] then
      sv.err(
        (
          key and "testing sheets: " .. a .. " needs a value\n"
          or "testing sheets: unknown argument " .. tostring(a) .. "\n"
        ) .. M.USAGE
      )
      return 2
    end
    o[key] = argv[i + 1]
    i = i + 2
  end
  -- only the characters of a task id: it is written into a comment line of the sheet
  if not o.id or not o.id:match("^[%w_.%-]+/[%w_.%-]+$") then
    sv.err("testing sheets: --from-task <area/slug> is required\n" .. M.USAGE)
    return 2
  end
  if o.name and not o.name:match("^[%w][%w_.%-]*$") then
    sv.err("testing sheets: --name: letters, digits, '_', '-', '.'")
    return 2
  end
  local repo = vim.fs.normalize(vim.fn.fnamemodify(o.repo or vim.fn.getcwd(), ":p")):gsub("/+$", "")
  local call = deps.call
  if not call then
    local vault, verr = find_vault(repo, o.vault, deps.getenv or vim.uv.os_getenv)
    if not vault then
      sv.err("testing sheets: " .. verr)
      return 3
    end
    local tasks = require("testing.sheet.tasks")
    local cli, lerr = tasks.locate(vault, { cli = o.cli })
    if not cli then
      sv.err("testing sheets: " .. tostring(lerr))
      return 3
    end
    call = tasks.caller(cli, vault)
  end
  local doc, err = call("task", { id = o.id })
  if not doc then
    sv.err("testing sheets: " .. tostring(err))
    return 3
  end
  local t = type(doc.task) == "table" and doc.task or {}
  local title = type(t.title) == "string" and vim.trim(t.title) or ""
  local slug = type(t.slug) == "string" and t.slug ~= "" and t.slug or o.id:match("/(.+)$")
  -- the file name and the id go together: a second sheet of the same task (--name) is a case of its own
  local name = o.name and o.name:gsub("%.sheet%.lua$", "") or M.id_of(slug)
  local task = { id = o.id, title = cut(title ~= "" and title or o.id), sheet_id = M.id_of(name) }
  local rel = "TESTS/sheets/" .. name .. ".sheet.lua"
  local path = repo .. "/" .. rel
  local judge = M.acceptance(type(doc.body) == "string" and doc.body or "")
  local text = M.render(task, judge)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  -- created exclusively: a sheet that exists (or appears meanwhile, or is a symlink) is never written over
  local fd, oerr, code = vim.uv.fs_open(path, "wx", 420)
  if not fd then
    if code == "EEXIST" then
      sv.err(
        "testing sheets: "
          .. rel
          .. " exists; a sheet is never overwritten (--name for another file)"
      )
      return 2
    end
    sv.err("testing sheets: cannot write " .. rel .. ": " .. tostring(oerr))
    return 3
  end
  local n, werr = vim.uv.fs_write(fd, text)
  vim.uv.fs_close(fd)
  if n ~= #text then
    os.remove(path)
    sv.err("testing sheets: cannot write " .. rel .. ": " .. tostring(werr))
    return 3
  end
  local ok, lerr = require("testing.sheet").load(path)
  if not ok then
    os.remove(path)
    sv.err("testing sheets: the draft does not load (" .. tostring(lerr) .. "), nothing kept")
    return 3
  end
  sv.out(
    ("testing sheets: wrote %s (DRAFT, %d judge entr%s from the acceptance of %s)"):format(
      rel,
      #judge,
      #judge == 1 and "y" or "ies",
      o.id
    )
  )
  return 0
end

return M
