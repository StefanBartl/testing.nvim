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

---Read the sheets and last results of the projects.
---@param roots string[]
---@param opts? { states?: table<string, Testing.State>, state_dir?: string }
---@return Testing.SheetReport.Entry[]
function M.collect(roots, opts)
  opts = opts or {}
  local state = require("testing.state")
  local out = {}
  for _, r in ipairs(roots) do
    local root = norm(r)
    local st = (opts.states and opts.states[root])
      or state.load(root, { state_dir = opts.state_dir })
    local by_name = {}
    for _, c in ipairs(st.cases or {}) do
      if c.name then
        by_name[c.name] = c
      end
    end
    for _, path in ipairs(sheet_mod.files(root .. "/TESTS/sheets")) do
      local rel = path:sub(#root + 2)
      local s, err = sheet_mod.load(path)
      local e =
        { root = root, rel = rel, sheet = s, error = err, snapshots = snapshot_files(root, rel) }
      if s then
        e.case = by_name[sheet_mod.spec_name(s)]
        if e.case then
          local stale, why = state.is_stale(st, e.case.file)
          e.stale = stale and (why or "stale") or nil
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

---@param e Testing.SheetReport.Entry
---@param multi boolean Several projects: name the project.
---@return string
local function head(e, multi)
  local s = e.sheet
  local where = multi and (vim.fs.basename(e.root) .. "/" .. e.rel) or e.rel
  if not s then
    return ("- [ ] **%s**: does not load: %s"):format(where, e.error or "?")
  end
  local task = s.task and (", task `" .. s.task .. "`") or ""
  return ("- [ ] **%s** (`%s`%s) — `%s`"):format(s.title, s.id, task, where)
end

---Checkbox items below an entry (`depth` 1) or below one of its lines (`depth` 2).
---@param out string[]
---@param list string[]
---@param depth integer
local function sub_items(out, list, depth)
  local indent = ("  "):rep(depth)
  for _, item in ipairs(list) do
    out[#out + 1] = indent .. "- [ ] " .. item
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
      out[#out + 1] = ("  - last result `%s` is not current: %s"):format(e.case.status, e.stale)
    else
      out[#out + 1] = ("  - `%s`: %s"):format(e.case.status, e.case.message or "(no message)")
    end
  end)
  section("Review inbox", buckets.inbox, function(e)
    out[#out + 1] = "  - automated part green; judge:"
    sub_items(out, e.sheet.judge, 2)
    if #e.snapshots > 0 then
      out[#out + 1] = "  - look at: "
        .. table.concat(
          vim.tbl_map(function(p)
            return "`" .. p .. "`"
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

M.USAGE = "usage: testing sheets report [<root>...] [--out <file>]"

---`testing sheets report`: exit 0 written or printed, 2 bad usage, 3 the file could not be written.
---@param argv string[] The arguments after `sheets`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer
function M.main(argv, sv)
  if argv[1] ~= "report" then
    sv.err(M.USAGE)
    return 2
  end
  local roots, out_file = {}, nil
  local i = 2
  while i <= #argv do
    local a = argv[i]
    if a == "--out" then
      out_file = argv[i + 1]
      if not out_file then
        sv.err(M.USAGE)
        return 2
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
  local text = M.render(M.collect(roots), {
    date = os.date("!%Y-%m-%d") --[[@as string]],
  })
  if not out_file then
    sv.out((text:gsub("\n$", "")))
    return 0
  end
  local ok, werr = require("lib.nvim.fs.write.atomic")(out_file, text, { mkdirp = true })
  if not ok then
    sv.err("testing sheets: cannot write " .. out_file .. ": " .. tostring(werr))
    return 3
  end
  sv.out("testing sheets: wrote " .. out_file)
  return 0
end

return M
