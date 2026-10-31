---@module 'testing.sheet.prompt'
-- @cache-env REPOS_DIR TASKS_VAULT NVIM_MACHINE_ROLE TESTING_ALLOW_WORKSTATION
---@brief Hand a test sheet over to an AI: a prompt to draft one from a task, a prompt to explain a red run, and the way back.
---@description
--- Stage 0 of the AI link (no model is called here; ai.nvim's headless entry comes later): the commands write a Markdown
--- document a person pastes into the AI of their choice, and take the answer back only through a check.
---
--- * `testing sheets prompt draft --from-task <id>`: the task (title, body), the rules of the sheet format and the
---   skeleton `testing sheets new` would write; the answer asked for is one ```lua block that returns the sheet.
--- * `testing sheets prompt explain --task <id>`: runs the task's sheets as `testing sheets run` does (trust gate,
---   workstation rule, as on CI, nothing written) and hands over each red sheet: its source, every failure line (a
---   snapshot failure shows the first differing rows) and its snapshot files; the answer asked for is an explanation and,
---   if it is a bug, one ```task block (title, summary) that tasks.nvim turns into a bug task after confirmation.
--- * `testing sheets accept --task <id> --from <file>`: the AI's answer (or just its ```lua block) becomes
---   `TESTS/sheets/<id>.sheet.lua` only when it loads (`sheet.load`), names the task and no sheet of that name exists.
---
--- What the model sees is exactly the document (docs/SHEETS.md, "Hand over to an AI"). A vault or root whose path names
--- `tricentis` is refused: its tasks may carry customer data.

local M = {}

M.USAGE = table.concat({
  "usage: testing sheets prompt draft --from-task <area/slug> [--repo <dir>] [--vault <dir>] [--tasks-cli <tasks.lua>] [--out <file>]",
  "       testing sheets prompt explain --task <area/slug> [--root <dir>]... [--tasks <vault>] [--out <file>]",
  "       testing sheets accept --task <area/slug> --from <file> [--repo <dir>] [--name <file-name>]",
}, "\n")
M.MAX_BODY = 32768
M.MAX_SOURCE = 32768

---@class Testing.SheetPrompt.Deps
---@field call? Testing.SheetTasks.Call
---@field getenv? fun(name: string): string|nil
---@field run? fun(s: Testing.Sheet, opts: table): Testing.Sheet.Result
---@field trust_check? fun(root: string): string|nil

---The rules of the sheet format the model needs (a short form of docs/SHEETS.md, "A sheet").
M.FORMAT = [[
A sheet is a Lua file that `return`s one table and is read as DATA (an empty environment: no require, os, io, vim).
Fields: id (letters, digits, _ - .), title, task ("<area/slug>"), engine ("rpc"), minit (default
"TESTS/minimal_init.lua"), sizes ({ { rows = 24, cols = 80 } }), steps, judge (criteria a person checks), manual
(steps only a person can do), notes. Each step has exactly one action and may carry a note:

| step | does | fails when |
|---|---|---|
| keys = "..." | typed like a user (mappings apply); ends insert mode | the keys left an error message (v:errmsg) |
| input = "..." | queued; the way into insert mode (input = "A", then a wait for the mode) | never |
| lua = "..." | Lua run in the child editor (the plugin's API, options) | it raises |
| settle = ms | waits until the child is idle | not idle in time |
| wait = "expr", timeout = ms | polls a Lua expression in the child | not truthy in time |
| expect = "expr" | evaluates a Lua expression now | not truthy |
| screen = "name" | compares the screen with a snapshot (masks = { { row = n } } hide rows) | it differs |

Milliseconds are whole numbers up to 600000. The first failed step ends the run of that size. Put what a machine can
check into steps (wait/expect/screen) and only the judgement into judge.]]

---@param vault string|nil
---@param roots string[]
---@return string|nil refusal
local function confidential(vault, roots)
  for _, p in ipairs(vim.list_extend({ vault }, roots)) do
    if p and p:lower():find("tricentis", 1, true) then
      return ("%s names tricentis: its tasks may carry customer data, nothing is handed to an AI"):format(
        p
      )
    end
  end
  return nil
end

---@param s string
---@param max integer
---@return string
local function cap(s, max)
  if #s <= max then
    return s
  end
  return s:sub(1, max) .. ("\n... (cut at %d bytes)"):format(max)
end

---A fence that cannot be closed by the text inside it.
---@param text string
---@return string
local function fence_for(text)
  local longest = 2
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return ("`"):rep(longest + 1)
end

---@param text string
---@param lang string
---@return string
local function fenced(text, lang)
  local f = fence_for(text)
  return f .. lang .. "\n" .. text:gsub("\n$", "") .. "\n" .. f
end

---Write `doc` to `--out` or stdout.
---@return integer
local function emit(doc, out, sv)
  if out then
    local ok, err = require("lib.nvim.fs.write.atomic")(out, doc, { mkdirp = true })
    if not ok then
      sv.err("testing sheets: cannot write " .. out .. ": " .. tostring(err))
      return 3
    end
    sv.err("testing sheets: wrote " .. out)
    return 0
  end
  sv.out(doc)
  return 0
end

---Options as `{ key = value }` plus the repeated `--root`.
---@return table|nil o, string[]|nil roots, string|nil err
local function parse(argv, keys)
  local o, roots, i = {}, {}, 1
  while i <= #argv do
    local key = keys[argv[i]]
    if not key or not argv[i + 1] then
      return nil,
        nil,
        (key and (argv[i] .. " needs a value") or ("unknown argument " .. tostring(argv[i])))
    end
    if key == "root" then
      roots[#roots + 1] = argv[i + 1]
    else
      o[key] = argv[i + 1]
    end
    i = i + 2
  end
  return o, roots
end

---`testing sheets prompt draft`: 0 written, 2 bad usage or refused, 3 the task could not be read.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetPrompt.Deps
---@return integer
function M.draft(argv, sv, deps)
  deps = deps or {}
  local o, _, perr = parse(argv, {
    ["--from-task"] = "id",
    ["--repo"] = "repo",
    ["--vault"] = "vault",
    ["--tasks-cli"] = "cli",
    ["--out"] = "out",
  })
  if not o then
    sv.err("testing sheets: " .. perr .. "\n" .. M.USAGE)
    return 2
  end
  if not o.id or not o.id:match("^[%w_.%-]+/[%w_.%-]+$") then
    sv.err("testing sheets: --from-task <area/slug> is required\n" .. M.USAGE)
    return 2
  end
  local new = require("testing.sheet.new")
  local repo = vim.fs.normalize(vim.fn.fnamemodify(o.repo or vim.fn.getcwd(), ":p")):gsub("/+$", "")
  local getenv = deps.getenv or vim.uv.os_getenv
  local vault
  local call = deps.call
  if not call then
    local verr
    vault, verr = new.find_vault(repo, o.vault, getenv)
    if not vault then
      sv.err("testing sheets: " .. tostring(verr))
      return 3
    end
  else
    vault = o.vault
  end
  local refusal = confidential(vault, { repo })
  if refusal then
    sv.err("testing sheets: refused: " .. refusal)
    return 2
  end
  if not call then
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
  local body = type(doc.body) == "string" and doc.body:gsub("\r\n?", "\n") or ""
  -- the generated block of the last report is the old state, not the task: left out
  local _, first, last = require("testing.sheet.tasks").extract(body)
  if first then
    local lines = vim.split(body, "\n", { plain = true })
    body = table.concat(vim.list_slice(lines, 1, first - 1), "\n")
      .. "\n"
      .. table.concat(vim.list_slice(lines, last + 1), "\n")
  end
  local title = type(t.title) == "string" and t.title ~= "" and t.title or o.id
  local slug = type(t.slug) == "string" and t.slug ~= "" and t.slug or o.id:match("/(.+)$")
  local skeleton =
    new.render({ id = o.id, title = title, sheet_id = new.id_of(slug) }, new.acceptance(body))
  local out = {
    "# Draft a test sheet for the live check " .. o.id,
    "",
    "You write a test sheet for testing.nvim: data that a machine runs in a child Neovim (an RPC client) to do",
    "the live check of the task below, so that only the judgement is left for a person. Use the plugin's real",
    "commands and API as the task names them; do not invent options. Keep id, title and task of the skeleton.",
    "",
    "## The task",
    "",
    "**" .. title .. "** (`" .. o.id .. "`)",
    "",
    fenced(cap(body, M.MAX_BODY), "markdown"),
    "",
    "## The sheet format",
    "",
    M.FORMAT,
    "",
    "## The skeleton (testing sheets new)",
    "",
    fenced(skeleton, "lua"),
    "",
    "## Answer with",
    "",
    "Exactly one ```lua block that returns the whole sheet table, then at most five lines on what a person still",
    "has to check by hand. Keep `notes` starting with DRAFT until a person reviewed the snapshots.",
  }
  return emit(table.concat(out, "\n") .. "\n", o.out, sv)
end

---`testing sheets prompt explain`: 0 written (or no red sheet), 2 bad usage, refused or no sheet, 3 the engine.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetPrompt.Deps
---@return integer
function M.explain(argv, sv, deps)
  deps = deps or {}
  local o, roots, perr = parse(argv, {
    ["--task"] = "id",
    ["--root"] = "root",
    ["--tasks"] = "vault",
    ["--tasks-cli"] = "cli",
    ["--out"] = "out",
  })
  if not o then
    sv.err("testing sheets: " .. perr .. "\n" .. M.USAGE)
    return 2
  end
  local refusal = confidential(o.vault, roots)
  if refusal then
    sv.err("testing sheets: refused: " .. refusal)
    return 2
  end
  local run_argv = { "--task", o.id or "" }
  for _, r in ipairs(roots) do
    vim.list_extend(run_argv, { "--root", r })
  end
  if o.vault then
    vim.list_extend(run_argv, { "--tasks", o.vault })
  end
  if o.cli then
    vim.list_extend(run_argv, { "--tasks-cli", o.cli })
  end
  local ran
  local quiet = {
    out = function() end,
    err = sv.err,
  }
  local code = require("testing.sheet.run").main(
    run_argv,
    quiet,
    vim.tbl_extend("force", deps, {
      no_write = true,
      on_ran = function(entries)
        ran = entries
      end,
    })
  )
  if not ran then
    return code
  end
  local red = {}
  for _, e in ipairs(ran) do
    if not e.sheet or (e.result and e.result.status == "fail") then
      red[#red + 1] = e
    end
  end
  if #red == 0 then
    sv.err("testing sheets: no sheet of " .. o.id .. " is red; nothing to explain")
    return 0
  end
  local refusal2 = confidential(
    nil,
    vim.tbl_map(function(e)
      return e.root
    end, red)
  )
  if refusal2 then
    sv.err("testing sheets: refused: " .. refusal2)
    return 2
  end
  local out = {
    "# Explain a red test sheet of " .. o.id,
    "",
    "A test sheet of testing.nvim (data run in a child Neovim over RPC) failed. Explain the most likely cause from",
    "the failure lines and the sheet: a bug in the plugin, a wrong step in the sheet, or a snapshot that is out of",
    "date. Say which, and what to change.",
    "",
    "## The sheet format",
    "",
    M.FORMAT,
  }
  for _, e in ipairs(red) do
    local name = vim.fs.basename(e.root) .. "/" .. e.rel
    out[#out + 1] = ""
    out[#out + 1] = "## " .. name
    out[#out + 1] = ""
    if not e.sheet then
      out[#out + 1] = "It does not load: " .. tostring(e.error)
    else
      out[#out + 1] = "Failures (size, step, what):"
      out[#out + 1] = ""
      out[#out + 1] = fenced(table.concat(e.result.failures, "\n"), "text")
      if #e.snapshots > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "Snapshot files: "
          .. table.concat(
            vim.tbl_map(function(p)
              return "`" .. p .. "`"
            end, e.snapshots),
            ", "
          )
      end
    end
    local f = io.open(e.root .. "/" .. e.rel, "rb")
    if f then
      local src = f:read(M.MAX_SOURCE + 1) or ""
      f:close()
      out[#out + 1] = ""
      out[#out + 1] = "The sheet:"
      out[#out + 1] = ""
      out[#out + 1] = fenced(cap(src, M.MAX_SOURCE), "lua")
    end
  end
  vim.list_extend(out, {
    "",
    "## Answer with",
    "",
    "The cause in a few sentences and what to change. If it is a bug of the plugin, add one block for a bug task:",
    "",
    "```task",
    "title: <one line>",
    "summary: <one or two sentences: what fails, where>",
    "```",
  })
  return emit(table.concat(out, "\n") .. "\n", o.out, sv)
end

---The sheet in an AI's answer: its ```lua block (the first), or the whole text when it has none.
---@param text string
---@return string
function M.lua_block(text)
  local f, body = text:match("\n?(```+)lua[ \t]*\r?\n(.-)\r?\n%1")
  if f then
    return body .. "\n"
  end
  return text
end

---`testing sheets accept`: 0 written, 2 bad usage, the draft does not load, names another task, or the sheet exists,
---3 the file could not be written.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetPrompt.Deps
---@return integer
function M.accept(argv, sv, deps)
  deps = deps or {}
  local o, _, perr = parse(argv, {
    ["--task"] = "id",
    ["--from"] = "from",
    ["--repo"] = "repo",
    ["--name"] = "name",
  })
  if not o then
    sv.err("testing sheets: " .. perr .. "\n" .. M.USAGE)
    return 2
  end
  if not o.id or not o.id:match("^[%w_.%-]+/[%w_.%-]+$") or not o.from then
    sv.err("testing sheets: --task <area/slug> and --from <file> are required\n" .. M.USAGE)
    return 2
  end
  if o.name and not o.name:match("^[%w][%w_.%-]*$") then
    sv.err("testing sheets: --name: letters, digits, '_', '-', '.'")
    return 2
  end
  local f = io.open(o.from, "rb")
  if not f then
    sv.err("testing sheets: cannot read " .. o.from)
    return 2
  end
  local text = M.lua_block(f:read(1048576) or "")
  f:close()
  local repo = o.repo
  if not repo then
    local r, tried = require("testing.sheet.run").area_root(
      o.id:match("^[^/]+"),
      nil,
      deps.getenv or vim.uv.os_getenv
    )
    if not r then
      sv.err(
        "testing sheets: no repository for the area (tried " .. tostring(tried) .. "); pass --repo"
      )
      return 2
    end
    repo = r
  end
  repo = vim.fs.normalize(vim.fn.fnamemodify(repo, ":p")):gsub("/+$", "")
  -- checked as a file of its own first: what is written is what loaded
  local tmp = vim.fn.tempname() .. ".sheet.lua"
  local tf = assert(io.open(tmp, "wb"))
  tf:write(text)
  tf:close()
  local sheet = require("testing.sheet")
  local s, lerr = sheet.load(tmp)
  os.remove(tmp)
  if not s then
    sv.err("testing sheets: the draft does not load: " .. tostring(lerr))
    return 2
  end
  if s.task ~= o.id then
    sv.err(("testing sheets: the draft names task %s, not %s"):format(tostring(s.task), o.id))
    return 2
  end
  local name = o.name and o.name:gsub("%.sheet%.lua$", "") or s.id
  local rel = "TESTS/sheets/" .. name .. ".sheet.lua"
  local path = repo .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd, oerr, ecode = vim.uv.fs_open(path, "wx", 420)
  if not fd then
    if ecode == "EEXIST" then
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
  local n = vim.uv.fs_write(fd, text)
  vim.uv.fs_close(fd)
  if n ~= #text then
    os.remove(path)
    sv.err("testing sheets: cannot write " .. rel)
    return 3
  end
  sv.out(("testing sheets: wrote %s (sheet %s, %d steps)"):format(rel, s.id, #s.steps))
  return 0
end

return M
