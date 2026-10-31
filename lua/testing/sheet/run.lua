---@module 'testing.sheet.run'
-- @cache-env NVIM_MACHINE_ROLE TESTING_ALLOW_WORKSTATION REPOS_DIR
---@brief `testing sheets run --task <id>`: run the test sheets of one task now and write the result into it.
---@description
--- The way from a live-check task to its result without running a whole suite: the sheets of the given roots
--- that name the task (`task = "<area/slug>"`, a sheet that does not load too) run here, one child editor each,
--- and with `--tasks <vault>` their state goes into the task's block as `testing sheets report --tasks` writes
--- it (`testing.sheet.tasks.sync`). tasks.nvim's `:Tasks sheet-run` calls this command; the two plugins meet
--- only on the command line and the block.
---
--- * The roots are `--root <dir>` (repeatable), else the task's area as a repository: `$REPOS_DIR/<area>`,
---   else `<vault>/../<area>`; with `--tasks` also the projects the task's block names (it is written whole).
--- * Each root passes the workspace trust gate (`testing.trust`) first: a sheet runs the project's minimal init.
--- * A missing snapshot is a failure, as on CI (`ci = true`): a run from a task never writes a reference image.
--- * On the workstation (`NVIM_MACHINE_ROLE=workstation`) it refuses, unless `TESTING_ALLOW_WORKSTATION=1`; another
---   value than `workstation` / `default` is refused as a typo.
--- * A red sheet carries its first failure line into the block (`red: <line>`).

local M = {}

M.USAGE =
  "usage: testing sheets run --task <area/slug> [--root <dir>]... [--tasks <vault> [--tasks-cli <tasks.lua>] [--dry-run]]"

---@class Testing.SheetRun.Deps
---@field call? Testing.SheetTasks.Call A stand-in for the engine of tasks.nvim (specs).
---@field getenv? fun(name: string): string|nil
---@field run? fun(s: Testing.Sheet, opts: table): Testing.Sheet.Result A stand-in for `testing.sheet.run` (specs).
---@field trust_check? fun(root: string): string|nil A stand-in for `testing.trust.check` (specs).
---@field on_ran? fun(entries: Testing.SheetReport.Entry[]) Called with the task's sheets after they ran (`e.result`).
---@field no_write? boolean Run only, never write the task (`testing sheets prompt explain`).

---The first line of the first failure: what the block shows of a red run.
---@param res Testing.Sheet.Result
---@return string
function M.first_failure(res)
  local first = res.failures and res.failures[1]
  if not first then
    return res.status or "fail"
  end
  return (tostring(first):match("^[^\r\n]*"))
end

---@param area string
---@param vault string|nil
---@param getenv fun(name: string): string|nil
---@return string|nil root, string|nil tried
function M.area_root(area, vault, getenv)
  local tried, bases = {}, {}
  local repos = getenv("REPOS_DIR")
  if repos and repos ~= "" then
    bases[#bases + 1] = repos
  end
  if vault then
    bases[#bases + 1] = vim.fs.dirname(vault)
  end
  for _, base in ipairs(bases) do
    local dir = vim.fs.normalize(base .. "/" .. area)
    tried[#tried + 1] = dir
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil, table.concat(tried, ", ")
end

---`testing sheets run`: exit 0 every sheet green (or waiting for a person) and the task written, 1 a sheet is
---red or the task could not be written, 2 bad usage, refused (trust, workstation) or no sheet names the task, 3
---the engine of tasks.nvim could not be reached.
---@param argv string[] The arguments after `run`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@param deps? Testing.SheetRun.Deps
---@return integer
function M.main(argv, sv, deps)
  deps = deps or {}
  local getenv = deps.getenv or vim.uv.os_getenv
  local o, roots = { dry_run = false }, {}
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--dry-run" then
      o.dry_run = true
      i = i + 1
    else
      local key = ({
        ["--task"] = "id",
        ["--root"] = "root",
        ["--tasks"] = "vault",
        ["--tasks-cli"] = "cli",
      })[a]
      if not key or not argv[i + 1] then
        sv.err(
          (
            key and ("testing sheets: " .. a .. " needs a value")
            or ("testing sheets: unknown argument " .. tostring(a))
          )
            .. "\n"
            .. M.USAGE
        )
        return 2
      end
      if key == "root" then
        roots[#roots + 1] = argv[i + 1]
      else
        o[key] = argv[i + 1]
      end
      i = i + 2
    end
  end
  if not o.id or not o.id:match("^[%w_][%w_.%-]*/[%w_.%-]+$") then
    sv.err("testing sheets: --task <area/slug> is required\n" .. M.USAGE)
    return 2
  end
  if (o.cli or o.dry_run) and not o.vault then
    sv.err("testing sheets: --tasks-cli and --dry-run belong to --tasks <vault>\n" .. M.USAGE)
    return 2
  end
  -- trimmed: `set NVIM_MACHINE_ROLE=workstation ` in cmd keeps the blank (the nvim config's machine.lua trims too)
  local role = vim.trim(getenv("NVIM_MACHINE_ROLE") or ""):lower()
  if role ~= "" and role ~= "default" and role ~= "workstation" then
    sv.err(
      ("testing sheets: NVIM_MACHINE_ROLE=%q is neither workstation nor default (a typo?): refused until it is set right"):format(
        role
      )
    )
    return 2
  end
  if role == "workstation" and getenv("TESTING_ALLOW_WORKSTATION") ~= "1" then
    sv.err(
      "testing sheets: refused on the workstation (NVIM_MACHINE_ROLE=workstation): a sheet starts editors and runs "
        .. "the project's code; set TESTING_ALLOW_WORKSTATION=1 where that is allowed"
    )
    return 2
  end
  local vault = o.vault and vim.fs.normalize(vim.fn.fnamemodify(o.vault, ":p")):gsub("/+$", "")
    or nil
  local tasks = require("testing.sheet.tasks")
  -- the engine first: nothing runs when the result could not be written, and the task's block names the
  -- projects its sheets live in
  local call = deps.call
  if vault and not call then
    local cli, lerr = tasks.locate(vault, { cli = o.cli })
    if not cli then
      sv.err("testing sheets: " .. tostring(lerr))
      return 3
    end
    call = tasks.caller(cli, vault)
  end
  if #roots == 0 then
    local r, tried = M.area_root(o.id:match("^[^/]+"), vault, getenv)
    if not r then
      sv.err(
        "testing sheets: no repository for the area of "
          .. o.id
          .. " (tried "
          .. tostring(tried)
          .. "); pass --root"
      )
      return 2
    end
    roots = { r }
  end
  for k, r in ipairs(roots) do
    if vim.fn.isdirectory(r) ~= 1 then
      sv.err("testing sheets: --root " .. r .. " is not a directory")
      return 2
    end
    roots[k] = vim.fs.normalize(vim.fn.fnamemodify(r, ":p")):gsub("/+$", "")
  end
  -- the block is written whole: a sheet of the task in another project must run too, or it drops out of it
  if vault then
    local have = {}
    for _, r in ipairs(roots) do
      have[vim.fs.basename(r)] = true
    end
    local doc = call("bodies", { ids = { o.id } })
    local item = type(doc) == "table" and type(doc.items) == "table" and doc.items[1] or nil
    local block = item
      and type(item.body) == "string"
      and tasks.extract((item.body:gsub("\r\n?", "\n")))
    for project in (block or ""):gmatch("`([%w_.%-]+)/TESTS/sheets/[^`\n]-%.sheet%.lua`") do
      if not have[project] then
        local r = M.area_root(project, vault, getenv)
        if not r then
          sv.err(
            (
              "testing sheets: the block of %s names sheets of %s, which is not found: pass --root <dir> for it, "
              .. "or its sheets would drop out of the block"
            ):format(o.id, project)
          )
          return 2
        end
        have[project] = true
        roots[#roots + 1] = r
      end
    end
  end
  local trust_check = deps.trust_check or require("testing.trust").check
  for _, r in ipairs(roots) do
    local refusal = trust_check(r)
    if refusal then
      sv.err("testing sheets: " .. refusal)
      return 2
    end
  end

  local report = require("testing.sheet.report")
  local mine = {}
  for _, e in ipairs(report.collect(roots, { cases = {} })) do
    local id = e.sheet and e.sheet.task or (not e.sheet and tasks.task_of_unloadable(e))
    if id == o.id then
      mine[#mine + 1] = e
    end
  end
  if #mine == 0 then
    sv.err(
      ("testing sheets: no sheet in %s names the task %s"):format(table.concat(roots, ", "), o.id)
    )
    return 2
  end

  local run = deps.run or require("testing.sheet").run
  local sheet = require("testing.sheet")
  local red = false
  for _, e in ipairs(mine) do
    if not e.sheet then
      red = true
      sv.out(("sheet %s: does not load: %s"):format(e.rel, (tostring(e.error):match("^[^\r\n]*"))))
    else
      local started = vim.uv.hrtime()
      local res = run(e.sheet, { root = e.root, ci = true })
      e.result = res
      local status = res.status == "fail" and "fail" or "pass"
      e.case = {
        name = sheet.spec_name(e.sheet),
        status = status,
        file = "TESTS/sheets_spec.lua",
        message = status == "fail" and M.first_failure(res) or nil,
        duration_ms = math.floor((vim.uv.hrtime() - started) / 1e6),
      }
      red = red or status == "fail"
      sv.out(
        ("sheet %s: %s%s"):format(
          e.sheet.id,
          res.status,
          status == "fail" and (": " .. e.case.message) or ""
        )
      )
    end
  end

  if deps.on_ran then
    deps.on_ran(mine)
  end
  if not o.vault or deps.no_write then
    return red and 1 or 0
  end
  local results, serr = tasks.sync(mine, { call = call, dry_run = o.dry_run })
  if not results then
    sv.err("testing sheets: " .. tostring(serr))
    return 3
  end
  local failed = false
  for _, r in ipairs(results) do
    sv.out(
      ("testing sheets: task %s %s%s"):format(
        r.id,
        r.outcome,
        r.message and (": " .. r.message) or ""
      )
    )
    failed = failed
      or not (r.outcome == "changed" or r.outcome == "unchanged" or r.outcome == "would_change")
  end
  return (red or failed) and 1 or 0
end

return M
