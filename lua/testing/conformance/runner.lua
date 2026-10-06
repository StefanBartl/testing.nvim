---@module 'testing.conformance.runner'
---@brief `run(root, opts) -> report`: builds the context, runs the checks, applies waivers, summarizes.
---@description
--- The pipeline, each step a function that can be used alone:
---
---   settings  `.testing.lua` -> project configuration + the suite's own `conformance` settings
---   context   `Testing.Conformance.Ctx`: the root, the plugin, read-only file access, memoized sources and
---             module list, and `probe(name)` (the data of a child editor session, run once per name)
---   checks    every selected check runs under `xpcall`; a check that raises is `error`, never a crash
---   waivers   a finding that matches a waiver (which carries a reason) stays in the report as waived and
---             does not count; a waiver that matches nothing is reported as stale
---   summary   counts per status and level; the verdict
---
--- `run` never raises and never writes into the checked repository (SEC-47).

local catalog = require("testing.conformance.catalog")
local fsx = require("testing.conformance.fsx")
local settings_mod = require("testing.conformance.settings")
local util = require("testing.conformance.util")

local M = {}

---Report schema version.
M.SCHEMA_VERSION = 1

---Most source files a static scan reads (a repository with more is cut, and the report says so).
M.MAX_SOURCES = 4000

---Normalize a root: absolute, forward slashes, no trailing slash.
---@param root string
---@return string
local function normalize_root(root)
  return (vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/+$", ""))
end

---Choose the plugin's Lua module root.
---@param fs Testing.Conformance.Fs
---@param wanted string
---@param notes string[]
---@return string|nil plugin
---@return string|nil problem
local function choose_plugin(fs, wanted, notes)
  if wanted ~= "" and (fs:is_dir("lua/" .. wanted) or fs:is_file("lua/" .. wanted .. ".lua")) then
    return wanted
  end
  local dirs = {}
  for _, e in ipairs(fs:list("lua")) do
    if e.type == "directory" then
      dirs[#dirs + 1] = e.name
    end
  end
  if #dirs == 1 then
    notes[#notes + 1] = ("plugin %q has no lua/%s; using the only module root lua/%s"):format(
      wanted,
      wanted,
      dirs[1]
    )
    return dirs[1]
  end
  if #dirs == 0 then
    return nil, ("no lua/ directory with a module root (plugin = %q)"):format(wanted)
  end
  return nil,
    ("lua/%s does not exist and lua/ has several module roots (%s): set `plugin` in .testing.lua"):format(
      wanted,
      table.concat(dirs, ", ")
    )
end

---Build the context of one run.
---@param root string
---@param loaded Testing.Conformance.Loaded
---@param opts table
---@return Testing.Conformance.Ctx
function M.context(root, loaded, opts)
  local fs = fsx.new(root)
  local notes = {}
  local plugin, problem = choose_plugin(fs, loaded.config.plugin or "", notes)

  -- `modules`, `sources`, `module_file` and `probe` close over this table and are assigned below
  ---@type Testing.Conformance.Ctx
  ---@diagnostic disable-next-line: missing-fields
  local ctx = {
    root = root,
    plugin = plugin,
    plugin_problem = problem,
    config = loaded.config,
    settings = loaded.settings,
    fs = fs,
    notes = notes,
  }

  -- memoized sources of a top-level directory: `{ rel, text, lines }`
  local sources_cache = {}
  local sources_bytes = 0
  function ctx.sources(dir)
    if sources_cache[dir] then
      return sources_cache[dir]
    end
    local out = {}
    if dir == "lua" and plugin == nil and not fs:is_dir("lua") then
      sources_cache[dir] = out
      return out
    end
    local skipped = 0
    for _, rel in ipairs(fs:walk(dir, { ext = "lua", limit = M.MAX_SOURCES })) do
      local st = fs:stat(rel)
      if st and st.size > fsx.MAX_SOURCE_BYTES then
        skipped = skipped + 1
      elseif st and sources_bytes + st.size > fsx.MAX_SOURCES_TOTAL then
        skipped = skipped + 1
      else
        local text = fs:read(rel)
        if text then
          -- the lines are the capped ones, and the text is made of them: a pattern that runs over `text` sees
          -- no line the cap did not allow
          local lines, cut = fsx.cap_lines(text)
          if cut > 0 then
            fs.cut = fs.cut + cut
            text = table.concat(lines, "\n")
          end
          sources_bytes = sources_bytes + #text
          out[#out + 1] = { rel = rel, text = text, lines = lines }
        end
      end
    end
    if skipped > 0 then
      notes[#notes + 1] = ("%d Lua file(s) below %s/ were not read (larger than %d KB, or more than %d MB of sources in all)"):format(
        skipped,
        dir,
        fsx.MAX_SOURCE_BYTES / 1024,
        fsx.MAX_SOURCES_TOTAL / 1024 / 1024
      )
    end
    sources_cache[dir] = out
    return out
  end

  -- the modules of the plugin: `{ module, rel }`
  local modules_cache
  local module_files = {}
  function ctx.modules()
    if modules_cache then
      return modules_cache
    end
    local out = {}
    if plugin then
      local function add(rel, module)
        out[#out + 1] = { module = module, rel = rel }
        module_files[module] = rel
      end
      if fs:is_file("lua/" .. plugin .. ".lua") then
        add("lua/" .. plugin .. ".lua", plugin)
      end
      for _, rel in ipairs(fs:walk("lua/" .. plugin, { ext = "lua", limit = M.MAX_SOURCES })) do
        local inner = rel:sub(#"lua/" + 1, -5)
        local skip = rel:find("/@types/", 1, true) ~= nil
          or rel:match("_spec%.lua$") ~= nil
          or rel:match("%.spec%.lua$") ~= nil
        if not skip then
          local module = inner:gsub("/init$", ""):gsub("/", ".")
          add(rel, module)
        end
      end
    end
    table.sort(out, function(a, b)
      return a.module < b.module
    end)
    modules_cache = out
    return out
  end
  function ctx.module_file(module)
    ctx.modules()
    return module_files[module]
  end

  -- runtime sessions, once per name
  local probes = {}
  function ctx.probe(name)
    if probes[name] == nil then
      local data, err
      if opts.probe then
        data, err = opts.probe(name, ctx)
      else
        local runtime = require("testing.conformance.runtime")
        if name == "main" then
          data, err = runtime.main(ctx)
        elseif name == "keymaps_off" then
          data, err = runtime.keymaps_off(ctx)
        elseif name == "require" then
          data, err = runtime.require_all(ctx)
        else
          err = "unknown session " .. tostring(name)
        end
      end
      probes[name] = { data = data, err = err }
    end
    local p = probes[name]
    return p.data, p.err
  end
  return ctx
end

---Does a waiver match a finding?
---@param w Testing.Conformance.Waiver
---@param f Testing.Conformance.Finding
---@return boolean
local function matches(w, f)
  if w.check ~= f.check then
    return false
  end
  if w.rule and w.rule ~= f.rule then
    return false
  end
  if w.file then
    local file = f.file or ""
    if w.file:sub(-1) == "/" then
      if file:sub(1, #w.file) ~= w.file then
        return false
      end
    elseif file ~= w.file then
      return false
    end
  end
  if w.text and not f.message:find(w.text, 1, true) then
    return false
  end
  return true
end

---Apply the waivers to the findings of the check results (in place).
---@param results Testing.Conformance.CheckResult[]
---@param waivers Testing.Conformance.Waiver[]
---@return string[] stale Waivers that matched nothing.
function M.apply_waivers(results, waivers)
  local used = {}
  for _, res in ipairs(results) do
    for _, f in ipairs(res.findings) do
      for i, w in ipairs(waivers) do
        if matches(w, f) then
          f.waived = true
          f.waiver_reason = w.reason
          used[i] = true
          break
        end
      end
    end
  end
  local stale = {}
  for i, w in ipairs(waivers) do
    if not used[i] then
      stale[#stale + 1] = ("waiver %d (check %s%s%s) matched no finding: remove it"):format(
        i,
        w.check,
        w.rule and (", rule " .. w.rule) or "",
        w.file and (", file " .. w.file) or ""
      )
    end
  end
  return stale
end

---Status of a check from its (non-waived) findings.
---@param findings Testing.Conformance.Finding[]
---@return "pass"|"warn"|"fail"
local function status_of(findings)
  local status = "pass"
  for _, f in ipairs(findings) do
    if not f.waived then
      if f.level == "error" then
        return "fail"
      elseif f.level == "warn" then
        status = "warn"
      end
    end
  end
  return status
end

---Run one check under `xpcall` and turn its outcome into a result.
---@param check Testing.Conformance.Check
---@param ctx Testing.Conformance.Ctx
---@param timings boolean
---@return Testing.Conformance.CheckResult
function M.run_check(check, ctx, timings)
  local t0 = vim.uv.hrtime()
  local ok, outcome = xpcall(check.run, debug.traceback, ctx)
  local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
  ---@type Testing.Conformance.CheckResult
  local res = {
    id = check.id,
    title = check.title,
    kind = check.kind,
    rules = vim.deepcopy(check.rules),
    status = "pass",
    findings = {},
    notes = {},
  }
  if timings then
    res.duration_ms = ms
  end
  if not ok then
    res.status = "error"
    res.reason = "the check raised: " .. util.show(tostring(outcome):match("^[^\n]*") or "?")
    return res
  end
  if type(outcome) ~= "table" then
    res.status = "error"
    res.reason = "the check returned no outcome"
    return res
  end
  for _, f in ipairs(outcome.findings or {}) do
    local copy = vim.deepcopy(f)
    if check.report_only and copy.level == "error" then
      copy.level = "warn"
    end
    res.findings[#res.findings + 1] = copy
  end
  table.sort(res.findings, function(a, b)
    if (a.file or "") ~= (b.file or "") then
      return (a.file or "") < (b.file or "")
    end
    if (a.line or 0) ~= (b.line or 0) then
      return (a.line or 0) < (b.line or 0)
    end
    if a.rule ~= b.rule then
      return a.rule < b.rule
    end
    return a.message < b.message
  end)
  for _, n in ipairs(outcome.notes or {}) do
    res.notes[#res.notes + 1] = util.show(n)
  end
  if timings then
    for _, n in ipairs(outcome.volatile or {}) do
      res.notes[#res.notes + 1] = util.show(n)
    end
  end
  res.rule_status = outcome.rules
  if outcome.error then
    res.status = "error"
    res.reason = util.show(util.relativize(outcome.error, ctx.root))
  elseif outcome.na then
    res.status = "n/a"
    res.reason = util.show(outcome.na)
  elseif outcome.blocked then
    res.status = "n/a"
    res.reason = "blocked: " .. util.show(outcome.blocked)
  else
    res.status = status_of(res.findings)
  end
  return res
end

---Summary counts of a report.
---@param results Testing.Conformance.CheckResult[]
---@param manual Testing.Conformance.ManualRule[]
---@return table summary
---@return "pass"|"warn"|"fail"|"error" verdict
local function summarize(results, manual)
  local summary = {
    checks = #results,
    pass = 0,
    fail = 0,
    warn = 0,
    ["n/a"] = 0,
    error = 0,
    manual = #manual,
    findings = { error = 0, warn = 0, info = 0 },
    waived = 0,
  }
  for _, r in ipairs(results) do
    summary[r.status] = (summary[r.status] or 0) + 1
    for _, f in ipairs(r.findings) do
      if f.waived then
        summary.waived = summary.waived + 1
      else
        summary.findings[f.level] = (summary.findings[f.level] or 0) + 1
      end
    end
  end
  local verdict = "pass"
  if summary.error > 0 then
    verdict = "error"
  elseif summary.fail > 0 then
    verdict = "fail"
  elseif summary.warn > 0 then
    verdict = "warn"
  end
  return summary, verdict
end

---Normalize the selection options.
---@param list any
---@return table<string, boolean>
local function as_set(list)
  local set = {}
  if type(list) == "table" then
    for _, id in ipairs(list) do
      set[tostring(id):upper()] = true
    end
  end
  return set
end

---@class Testing.Conformance.RunOpts
---@field only? string[] Check ids that run (default: all).
---@field skip? string[] Check ids that do not run (on top of `conformance.skip`).
---@field gate? boolean Mode of the report (`gate` or `report`); default: `conformance.gate`.
---@field timings? boolean Add durations and measured times (the report is then not deterministic).
---@field probe? fun(name: string, ctx: Testing.Conformance.Ctx): table|nil, string|nil Replaces the child sessions (specs).
---@field settings? table Overrides of the suite settings (specs).
---@field config? table Overrides of the project configuration (specs).
---@field bridge? boolean|table Run the rules.nvim bridge (`true` or its options).

---Run the suite on `root`.
---@param root string Repository root.
---@param opts? Testing.Conformance.RunOpts
---@return Testing.Conformance.Report
function M.run(root, opts)
  opts = opts or {}
  root = normalize_root(root)
  local ids = catalog.ids()
  ---@type Testing.Conformance.Report
  local report = {
    schema_version = M.SCHEMA_VERSION,
    tool = "testing.conformance",
    root = "<REPO>",
    name = vim.fs.basename(root),
    mode = "report",
    checks = {},
    manual = {},
    summary = {},
    problems = {},
    verdict = "error",
  }
  if vim.fn.isdirectory(root) ~= 1 then
    report.problems[1] = ("the root %s is not a directory"):format(util.show(root, 120))
    report.summary = select(1, summarize({}, {}))
    return report
  end

  local loaded = settings_mod.load(root, ids)
  if loaded.error then
    report.problems[#report.problems + 1] = loaded.error
    report.config_error = loaded.error
  end
  for _, p in ipairs(loaded.problems) do
    report.problems[#report.problems + 1] = util.show(p)
  end
  if opts.config then
    loaded.config = vim.tbl_deep_extend("force", loaded.config, opts.config)
  end
  if opts.settings then
    loaded.settings = vim.tbl_deep_extend("force", loaded.settings, opts.settings)
  end
  report.mode = (opts.gate == nil and loaded.settings.gate or opts.gate) and "gate" or "report"

  local ctx = M.context(root, loaded, opts)
  report.plugin = ctx.plugin

  local only = as_set(opts.only)
  local skipped = as_set(opts.skip)
  local config_skip = as_set(loaded.settings.skip)
  local results = {}
  for _, check in ipairs(catalog.checks()) do
    local selected = next(only) == nil or only[check.id]
    if selected then
      if skipped[check.id] or config_skip[check.id] then
        results[#results + 1] = {
          id = check.id,
          title = check.title,
          kind = check.kind,
          rules = vim.deepcopy(check.rules),
          status = "n/a",
          reason = skipped[check.id] and "skipped (--skip)"
            or "skipped (conformance.skip in .testing.lua)",
          findings = {},
          notes = {},
        }
      else
        results[#results + 1] = M.run_check(check, ctx, opts.timings == true)
      end
    end
  end

  for _, stale in ipairs(M.apply_waivers(results, loaded.settings.waivers)) do
    report.problems[#report.problems + 1] = stale
  end
  for _, r in ipairs(results) do
    if r.status ~= "error" and r.status ~= "n/a" then
      r.status = status_of(r.findings)
    end
  end
  report.checks = results
  report.manual = vim.deepcopy(catalog.MANUAL)
  if ctx.fs.cut and ctx.fs.cut > 0 then
    ctx.notes[#ctx.notes + 1] = ("%d line(s) longer than %d bytes were cut before the checks looked at them"):format(
      ctx.fs.cut,
      fsx.MAX_LINE
    )
  end
  for _, n in ipairs(ctx.notes) do
    report.problems[#report.problems + 1] = "note: " .. util.show(n)
  end
  table.sort(report.problems)

  if opts.bridge then
    local bridge_opts = type(opts.bridge) == "table" and opts.bridge or {}
    report.bridge = require("testing.conformance.rules_bridge").run(root, {
      rulesets = bridge_opts.rulesets or loaded.settings.rules_bridge.rulesets,
      families = bridge_opts.families or loaded.settings.rules_bridge.families,
      checks = results,
      loader = bridge_opts.loader,
    })
    for _, m in ipairs(report.bridge.manual or {}) do
      local known = false
      for _, have in ipairs(report.manual) do
        known = known or have.id == m.id
      end
      if not known then
        report.manual[#report.manual + 1] = m
      end
    end
    table.sort(report.manual, function(a, b)
      return a.id < b.id
    end)
  end

  report.summary, report.verdict = summarize(results, report.manual)
  return report
end

return M
