---@module 'testing.migrate'
---@brief Migration tooling: turns a repository that runs plenary / busted / a hand-written runner into one
---that runs on testing.nvim, with its specs unchanged.
---@description
--- Four steps, each a function that can be used alone:
---
---   local migrate = require("testing.migrate")
---   local report = migrate.analyze(root)         -- read-only facts about the repository
---   local plan   = migrate.plan(report)          -- file operations as DATA (nothing is written)
---   print(migrate.render(plan))                  -- Markdown / terminal text (`{ format = "text" }`)
---   print(migrate.to_json(plan))                 -- the same plan as JSON, sorted keys
---   migrate.apply(plan, { apply = true })        -- the only function that writes; refuses a dirty repository
---
--- `migrate.main(argv)` is what the command line and `:Testing migrate` call:
---
---   testing migrate [dry-run|apply] [<path>] [--json] [--markdown] [--check] [--fleet-root=<dir>]
---
--- Dry run is the default. `apply` writes the plan, and only into a repository whose working tree is
--- clean. `--check` exits 1 when the plan is not empty (a CI gate: "is this repository migrated?").
--- Exit codes of `main`: 0 done / nothing to do, 1 `--check` found work, 2 refused or bad usage,
--- 3 the root cannot be analysed.
---
--- Contract for the CLI (`testing.cli` dispatches the subcommand `migrate` here):
---
---   local code, out = require("testing.migrate").main(rest_of_argv)
---   io.stdout:write(out); return code

local M = {}

M.MODES = { "dry-run", "apply" }

---@param root string
---@param opts? Testing.Migrate.AnalyzeOpts
---@return Testing.Migrate.Report
function M.analyze(root, opts)
  return require("testing.migrate.analyze").analyze(root, opts)
end

---@param report Testing.Migrate.Report
---@param opts? Testing.Migrate.PlanOpts
---@return Testing.Migrate.Plan
function M.plan(report, opts)
  return require("testing.migrate.plan").plan(report, opts)
end

---@param plan Testing.Migrate.Plan
---@param opts? Testing.Migrate.RenderOpts
---@return string
function M.render(plan, opts)
  return require("testing.migrate.render").render(plan, opts)
end

---@param plan Testing.Migrate.Plan
---@return string|nil json
---@return string|nil err
function M.to_json(plan)
  return require("testing.migrate.render").to_json(plan)
end

---@param plan Testing.Migrate.Plan
---@param opts? Testing.Migrate.ApplyOpts
---@return Testing.Migrate.ApplyResult
function M.apply(plan, opts)
  return require("testing.migrate.apply").apply(plan, opts)
end

---Analyse and plan in one call.
---@param root string
---@param opts? Testing.Migrate.AnalyzeOpts
---@return Testing.Migrate.Plan plan
---@return Testing.Migrate.Report report
function M.run(root, opts)
  -- the editor outlives a run: a timeout of the last one (no network then) must not silence this one
  require("testing.migrate.branches").begin_run()
  local report = M.analyze(root, opts)
  return M.plan(report, {
    owner = opts and opts.owner,
    format = opts and opts.format,
    branch_exists = opts and opts.branch_exists,
  }),
    report
end

---@class Testing.Migrate.Parsed
---@field mode "dry-run"|"apply"
---@field root? string
---@field format "text"|"markdown"|"json"
---@field check boolean
---@field fleet_root? string

---Parse the arguments of `migrate`.
---@param argv string[]
---@return Testing.Migrate.Parsed|nil parsed
---@return string|nil err
function M.parse_args(argv)
  ---@type Testing.Migrate.Parsed
  local parsed = { mode = "dry-run", format = "text", check = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "dry-run" or a == "apply" then
      parsed.mode = a
    elseif a == "--json" then
      parsed.format = "json"
    elseif a == "--markdown" then
      parsed.format = "markdown"
    elseif a == "--check" then
      parsed.check = true
    elseif a == "--fleet-root" then
      i = i + 1
      if not argv[i] then
        return nil, "--fleet-root needs a directory"
      end
      parsed.fleet_root = argv[i]
    elseif a:sub(1, 13) == "--fleet-root=" then
      parsed.fleet_root = a:sub(14)
    elseif a:sub(1, 1) == "-" and #a > 1 then
      return nil, ("unknown option %s"):format(require("testing.migrate.text").show(a, 60))
    elseif parsed.root == nil then
      parsed.root = a
    else
      return nil, "only one path is accepted"
    end
    i = i + 1
  end
  if parsed.mode == "apply" and parsed.check then
    return nil, "--check and apply exclude each other"
  end
  return parsed
end

---Run `migrate` the way the command line does.
---@param argv string[]
---@param opts? Testing.Migrate.MainOpts
---@return integer code
---@return string output
function M.main(argv, opts)
  opts = opts or {}
  local parsed, perr = M.parse_args(argv)
  if not parsed then
    return 2,
      "testing migrate: "
        .. tostring(perr)
        .. "\nusage: testing migrate [dry-run|apply] [<path>] [--json] [--markdown] [--check] [--fleet-root=<dir>]\n"
  end
  local root = parsed.root or opts.cwd or vim.fn.getcwd()
  local plan = M.run(root, {
    fleet_root = parsed.fleet_root,
    branch_exists = opts.branch_exists or require("testing.migrate.branches").exists,
  })
  local code = 0
  local tail = ""
  if plan.error then
    code = 3
  elseif parsed.mode == "apply" then
    local res = M.apply(plan, { apply = true, is_dirty = opts.is_dirty })
    local lines = {}
    for _, p in ipairs(res.applied) do
      lines[#lines + 1] = "written: " .. require("testing.migrate.text").show(p, 200)
    end
    for _, p in ipairs(res.deleted or {}) do
      lines[#lines + 1] = "deleted: " .. require("testing.migrate.text").show(p, 200)
    end
    for _, e in ipairs(res.errors) do
      lines[#lines + 1] = "refused: " .. e
    end
    if #res.errors > 0 then
      code = 2
    end
    tail = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  elseif parsed.check and not plan.empty and not plan.skipped then
    code = 1
  end
  local out
  if parsed.format == "json" then
    out = (M.to_json(plan) or "{}") .. "\n"
  else
    out = M.render(plan, {
      format = parsed.format --[[@as "markdown"|"text"]],
    })
  end
  return code, out .. tail
end

return M
