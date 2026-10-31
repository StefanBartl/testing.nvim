---@module 'testing.sheet.report'
---@brief The list of live checks, made from the sheets and their last result.
---@description
--- `testing sheets report [<root>...] [--out <file>]` reads the sheets of each project
--- (`TESTS/sheets/*.sheet.lua`) and the last result of their spec cases (`testing.state`, the case
--- named `sheet:<id>`) and writes one Markdown list:
---
---   * Red, stale or not run: the sheet's case failed, its spec file changed since, or it never ran;
---   * Review inbox: the automated part is green and the sheet has `judge` criteria; the snapshot files
---     to look at are listed;
---   * Manual: the steps only a person can do (`manual`, or a `manual` sheet);
---   * Automated: green, nothing left for a person.
---
--- A sheet that does not load is listed under red with the reason. Nothing is run here.

local M = {}

local sheet_mod = require("testing.sheet")

---@class Testing.SheetReport.Entry
---@field root string
---@field rel string The sheet file relative to the root.
---@field sheet? Testing.Sheet
---@field error? string Why the sheet did not load.
---@field case? Testing.State.Case The last result of its spec case.
---@field stale? string Why that result is not current (the spec file changed, gone, ...).
---@field snapshots string[] Snapshot files of the sheet, relative to the root.

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(vim.fn.fnamemodify(p, ":p")):gsub("/+$", ""))
end

---Snapshot files written for a sheet (`testing.screen` puts them below `<dir>/sheets/<name>.sheet/`).
---@param root string
---@param rel string
---@return string[]
local function snapshot_files(root, rel)
  local dir = root .. "/TESTS/__snapshots__/" .. rel:gsub("^TESTS/", ""):gsub("%.lua$", "")
  local out = {}
  if vim.fn.isdirectory(dir) == 1 then
    for name, kind in vim.fs.dir(dir) do
      if kind == "file" and name:match("%.snap$") then
        out[#out + 1] = (dir .. "/" .. name):sub(#root + 2)
      end
    end
  end
  table.sort(out)
  return out
end

M.MAX_IR_BYTES = 64 * 1024 * 1024

---The cases of a Result-IR file (`testing run --json <file>`) by name: the result of a run that did not
---write the editor's state (`scripts/test.sh` runs with a throwaway app name and stdpath).
---@param path string
---@return table<string, Testing.State.Case>|nil cases, string|nil err
function M.cases_from_ir(path)
  local f = io.open(path, "rb")
  if not f then
    return nil, "cannot read " .. path
  end
  local text = f:read(M.MAX_IR_BYTES + 1) or ""
  f:close()
  if #text > M.MAX_IR_BYTES then
    return nil, path .. " is too large for a Result-IR"
  end
  local ok, ir = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(ir) ~= "table" or type(ir.cases) ~= "table" then
    return nil, path .. " is not a Result-IR (no cases)"
  end
  local out = {}
  for _, c in ipairs(ir.cases) do
    if type(c) == "table" and type(c.name) == "string" and type(c.status) == "string" then
      local msg
      for _, a in ipairs(type(c.assertions) == "table" and c.assertions or {}) do
        if type(a) == "table" and a.ok == false then
          msg = type(a.msg) == "string" and a.msg or nil
          break
        end
      end
      if not msg and type(c.error) == "table" and type(c.error.message) == "string" then
        msg = c.error.message
      end
      out[c.name] = {
        id = tostring(c.id),
        file = tostring(c.file),
        name = c.name,
        status = c.status,
        duration_ms = type(c.duration_ms) == "number" and c.duration_ms or 0,
        message = msg and (msg:match("^[^\n]*")) or nil,
      }
    end
  end
  return out, nil
end

---Was the sheet or one of its snapshots written after the spec file's result was recorded? The state
---only watches the spec file (`TESTS/sheets_spec.lua`), a sheet is data that file reads.
---@param root string
---@param rel string
---@param snapshots string[]
---@param st Testing.State
---@param spec_file string
---@return string|nil reason
local function changed_since(root, rel, snapshots, st, spec_file)
  local rec = st.files and st.files[(spec_file:gsub("\\", "/"))]
  if not rec or type(rec.ts) ~= "number" or rec.ts <= 0 then
    return nil
  end
  local files = { rel }
  vim.list_extend(files, snapshots)
  for _, f in ipairs(files) do
    local stat = vim.uv.fs_stat(root .. "/" .. f)
    if stat and stat.mtime.sec > rec.ts then
      return ("%s changed since the run"):format(f)
    end
  end
  return nil
end

---Read the sheets and last results of the projects. `opts.cases` (from `cases_from_ir`) replaces the
---editor's state; it says nothing about staleness (an IR is one run).
---@param roots string[]
---@param opts? { states?: table<string, Testing.State>, state_dir?: string, cases?: table<string, Testing.State.Case> }
---@return Testing.SheetReport.Entry[]
function M.collect(roots, opts)
  opts = opts or {}
  local state = require("testing.state")
  local out = {}
  for _, r in ipairs(roots) do
    local root = norm(r)
    local st, by_name
    if opts.cases then
      by_name = opts.cases
    else
      st = (opts.states and opts.states[root]) or state.load(root, { state_dir = opts.state_dir })
      by_name = {}
      for _, c in ipairs(st.cases or {}) do
        if c.name then
          by_name[c.name] = c
        end
      end
    end
    for _, path in ipairs(sheet_mod.files(root .. "/TESTS/sheets")) do
      local rel = path:sub(#root + 2)
      local s, err = sheet_mod.load(path)
      local e =
        { root = root, rel = rel, sheet = s, error = err, snapshots = snapshot_files(root, rel) }
      if s then
        e.case = by_name[sheet_mod.spec_name(s)]
        if e.case and st then
          local stale, why = state.is_stale(st, e.case.file)
          e.stale = stale and (why or "stale")
            or changed_since(root, rel, e.snapshots, st, e.case.file)
        end
      end
      out[#out + 1] = e
    end
  end
  return out
end

---Where an entry belongs: "red", "inbox", "manual", "automated".
---@param e Testing.SheetReport.Entry
---@return string
function M.bucket(e)
  local s = e.sheet
  if not s then
    return "red"
  end
  if s.engine == "manual" then
    return "manual"
  end
  if not e.case or e.case.status ~= "pass" or e.stale then
    return "red"
  end
  if #s.judge > 0 then
    return "inbox"
  end
  if #s.manual > 0 then
    return "manual"
  end
  return "automated"
end

---Text from a sheet or a result on ONE line: a newline in a title or a criterion would start a heading
---or a checkbox of its own in the list.
---@param v any
---@return string
local function one_line(v)
  return (tostring(v):gsub("[\r\n]+", " "))
end

---An inline code span that a backtick in the text cannot end.
---@param v any
---@return string
local function code(v)
  return "`" .. (one_line(v):gsub("`", "'")) .. "`"
end

---@param e Testing.SheetReport.Entry
---@param multi boolean Several projects: name the project.
---@return string
local function head(e, multi)
  local s = e.sheet
  local where = multi and (vim.fs.basename(e.root) .. "/" .. e.rel) or e.rel
  if not s then
    return ("- [ ] **%s**: does not load: %s"):format(one_line(where), one_line(e.error or "?"))
  end
  local task = s.task and (", task " .. code(s.task)) or ""
  return ("- [ ] **%s** (%s%s) — %s"):format(one_line(s.title), code(s.id), task, code(where))
end

---Checkbox items below an entry (`depth` 1) or below one of its lines (`depth` 2).
---@param out string[]
---@param list string[]
---@param depth integer
local function sub_items(out, list, depth)
  local indent = ("  "):rep(depth)
  for _, item in ipairs(list) do
    out[#out + 1] = indent .. "- [ ] " .. one_line(item)
  end
end

---The Markdown list.
---@param entries Testing.SheetReport.Entry[]
---@param opts? { title?: string, date?: string }
---@return string
function M.render(entries, opts)
  opts = opts or {}
  local roots = {}
  for _, e in ipairs(entries) do
    roots[e.root] = true
  end
  local multi = vim.tbl_count(roots) > 1
  local buckets = { red = {}, inbox = {}, manual = {}, automated = {} }
  for _, e in ipairs(entries) do
    table.insert(buckets[M.bucket(e)], e)
  end
  local out = {
    "# " .. (opts.title or "Live checks from test sheets"),
    "",
    ("Generated by `testing sheets report`%s from %d sheet(s): %d red or not run, %d to review, %d manual, %d automated."):format(
      opts.date and (" on " .. opts.date) or "",
      #entries,
      #buckets.red,
      #buckets.inbox,
      #buckets.manual,
      #buckets.automated
    ),
    "Do not edit by hand: change the sheets and run the report again.",
  }
  local function section(title, list, body)
    out[#out + 1] = ""
    out[#out + 1] = ("## %s (%d)"):format(title, #list)
    out[#out + 1] = ""
    if #list == 0 then
      out[#out + 1] = "(none)"
    end
    for _, e in ipairs(list) do
      out[#out + 1] = head(e, multi)
      body(e)
      if e.task_missing then
        out[#out + 1] = ("  - task %s is not an open task of the vault"):format(code(e.sheet.task))
      end
    end
  end
  section("Red, stale or not run", buckets.red, function(e)
    if not e.sheet then
      return
    end
    if not e.case then
      out[#out + 1] = "  - never ran (spec case `"
        .. sheet_mod.spec_name(e.sheet)
        .. "` has no result)"
    elseif e.stale then
      out[#out + 1] = ("  - last result %s is not current: %s"):format(
        code(e.case.status),
        one_line(e.stale)
      )
    else
      out[#out + 1] = ("  - %s: %s"):format(
        code(e.case.status),
        one_line(e.case.message or "(no message)")
      )
    end
  end)
  section("Review inbox", buckets.inbox, function(e)
    out[#out + 1] = "  - automated part green; judge:"
    sub_items(out, e.sheet.judge, 2)
    if #e.snapshots > 0 then
      -- several projects: the snapshot paths name theirs, like the entry's own path does
      local prefix = multi and (vim.fs.basename(e.root) .. "/") or ""
      out[#out + 1] = "  - look at: "
        .. table.concat(
          vim.tbl_map(function(p)
            return code(prefix .. p)
          end, e.snapshots),
          ", "
        )
    end
    if #e.sheet.manual > 0 then
      out[#out + 1] = "  - and by hand:"
      sub_items(out, e.sheet.manual, 2)
    end
  end)
  section("Manual", buckets.manual, function(e)
    sub_items(out, e.sheet.manual, 1)
  end)
  section("Automated", buckets.automated, function(e)
    out[#out + 1] = "  - green"
      .. (e.case and e.case.duration_ms and (" (" .. e.case.duration_ms .. " ms)") or "")
  end)
  return table.concat(out, "\n") .. "\n"
end

M.USAGE =
  "usage: testing sheets report [<root>...] [--from <ir.json>]... [--out <file>] [--tasks <vault> [--tasks-cli <tasks.lua>] [--dry-run]]"

---`testing sheets report`: exit 0 written or printed, 1 a task could not be written (conflict, refused), 2 bad
---usage, 3 the file could not be written or the engine of tasks.nvim not reached.
---@param argv string[] The arguments after `sheets`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? { call?: Testing.SheetTasks.Call } A stand-in for the engine (specs).
---@return integer
function M.main(argv, sv, deps)
  if argv[1] ~= "report" then
    sv.err(M.USAGE)
    return 2
  end
  local roots, out_file, cases = {}, nil, nil
  local vault, tasks_cli, dry_run = nil, nil, false
  local i = 2
  while i <= #argv do
    local a = argv[i]
    if a == "--dry-run" then
      dry_run = true
    elseif a == "--out" or a == "--from" or a == "--tasks" or a == "--tasks-cli" then
      local v = argv[i + 1]
      if not v then
        sv.err(M.USAGE)
        return 2
      end
      if a == "--out" then
        out_file = v
      elseif a == "--tasks" then
        vault = v
      elseif a == "--tasks-cli" then
        tasks_cli = v
      else
        local got, ferr = M.cases_from_ir(v)
        if not got then
          sv.err("testing sheets: " .. tostring(ferr))
          return 2
        end
        cases = cases or {}
        for name, c in pairs(got) do
          cases[name] = c
        end
      end
      i = i + 1
    elseif a:match("^%-") then
      sv.err("testing sheets: unknown option " .. a .. "\n" .. M.USAGE)
      return 2
    else
      roots[#roots + 1] = a
    end
    i = i + 1
  end
  if #roots == 0 then
    roots = { vim.fn.getcwd() }
  end
  if (tasks_cli or dry_run) and not vault then
    sv.err("testing sheets: --tasks-cli and --dry-run belong to --tasks <vault>\n" .. M.USAGE)
    return 2
  end
  local entries = M.collect(roots, { cases = cases })
  local code_out = 0
  if vault then
    local tasks = require("testing.sheet.tasks")
    local call = deps and deps.call
    if not call then
      local cli, lerr = tasks.locate(vault, { cli = tasks_cli })
      if not cli then
        sv.err("testing sheets: " .. tostring(lerr))
        return 3
      end
      call = tasks.caller(cli, vault)
    end
    local results, serr = tasks.sync(entries, { call = call, dry_run = dry_run })
    if not results then
      sv.err("testing sheets: " .. tostring(serr))
      return 3
    end
    for _, r in ipairs(results) do
      sv.out(
        ("testing sheets: task %s %s%s"):format(
          r.id,
          r.outcome,
          r.message and (": " .. r.message) or ""
        )
      )
      if r.outcome == "failed" or r.outcome == "truncated" then
        code_out = 1
      end
    end
  end
  local text = M.render(entries, {
    date = os.date("!%Y-%m-%d") --[[@as string]],
  })
  if not out_file then
    sv.out((text:gsub("\n$", "")))
    return code_out
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(out_file, text, { mkdirp = true })
  if not ok then
    sv.err("testing sheets: cannot write " .. out_file .. ": " .. tostring(werr))
    return 3
  end
  sv.out("testing sheets: wrote " .. out_file)
  return code_out
end

return M
