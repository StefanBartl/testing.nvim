---@module 'testing.surface'
---@brief The machine-readable surface of a plugin (keymaps, commands, autocmds, health, api, config) and how much of it the specs exercise.
---@description
--- ```lua
--- local surface = require("testing.surface")
---
--- -- 1. the surface of a plugin: read in a child editor after its setup()
--- local s = surface.collect(root, { plugin = "sessions" })       -- { entries = { { id = "binding:<leader>ss", ... } } }
---
--- -- 2. which entries a spec run exercised (the run is tracked, see testing.surface.track)
--- local hits = surface.hits({ from = { "out.json" } })            -- cases[].surface.hit of the Result-IR
--- local cov  = surface.coverage(s, hits)                          -- { total, hit, ratio, missing, ... }
---
--- -- 3. the report behind `testing surface` / `:Testing surface`
--- local code, text = surface.main({ ".", "--from", "out.json", "--threshold", "0.8" })
--- ```
---
--- Modules: `ids` (stable `kind:name` ids), `read` (the registries -> entries, in-process), `collect`
--- (the same in a child editor), `track` (the installable layer that counts executions),
--- `coverage` (pure: ratio, thresholds, baseline, IR), `render` (text / markdown / JSON). Full
--- documentation, limits and the integration contract: docs/SURFACE.md.
---
--- Exit codes of `main`: 0 done (below a threshold of 0 is a report), 1 a threshold or the baseline
--- failed, 2 usage or configuration error, 3 the surface could not be read.

local coverage = require("testing.surface.coverage")
local ids = require("testing.surface.ids")
local render = require("testing.surface.render")

local M = {}

M.EXIT_OK = 0
M.EXIT_FAILED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

M.ids = ids

M.USAGE = [[
usage: testing surface [<root>] [options]

Lists the keymaps, commands, autocmds, health, api and config keys of the plugin at <root> (read in a
child editor after setup()) and, when a tracked run is given, which of them the specs exercised.

  --from <ir.json>            hits from a Result-IR whose cases carry `surface.hit` (repeatable)
  --hits <file>               hits from a tracker sink, JSON lines (repeatable)
  --kind <k[,k...]>           kinds that make up the ratio (default binding,command,autocmd)
  --threshold <0..1>          fail (exit 1) when the overall ratio is below; 0 = only report
  --threshold <kind>=<0..1>   the same for one kind (repeatable)
  --ignore <lua-pattern>      leave the ids that match out of the ratio (repeatable)
  --baseline <file>           compare with a baseline: an entry that was exercised and is not now fails
  --fail-on-new               with --baseline: new entries that are not exercised fail as well
  --fail-on-removed           with --baseline: an entry that was exercised and is gone from the surface fails
  --require-signed-baseline   with --baseline: a baseline that is edited or has no digest fails (exit 1)
  --write-baseline <file>     write the baseline of this run (only when nothing failed)
  --json | --markdown         output format (default: a text table)
  --out <file>                also write the output to a file
  -h, --help                  this text

exit: 0 done, 1 a threshold or the baseline failed, 2 usage error, 3 the surface could not be read]]

-- ===========================================================
-- hits
-- ===========================================================

---@class Testing.Surface.HitSources
---@field from? string[] Result-IR files (JSON) with `cases[].surface.hit`.
---@field sinks? string[] Tracker sinks (JSON lines).
---@field ir? table[] Result-IRs already decoded.
---@field data? Testing.Surface.Hits Hits already in memory.

---Read a file whole.
---@param path string
---@return string|nil text
---@return string|nil err
local function read_file(path)
  return require("testing.surface.coverage").read_bounded(path)
end

---Collect the hits of every given source into one set. nil when no source was given.
---@param src Testing.Surface.HitSources
---@return Testing.Surface.Hits|nil hits
---@return string|nil err
function M.hits(src)
  local any = false
  local out = coverage.new_hits()
  if src.data then
    any = true
    coverage.merge(out, src.data)
  end
  for _, ir in ipairs(src.ir or {}) do
    any = true
    coverage.merge(out, coverage.from_ir(ir))
  end
  for _, path in ipairs(src.from or {}) do
    any = true
    local text, err = read_file(path)
    if not text then
      return nil, err
    end
    local ok, ir = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if not ok or type(ir) ~= "table" then
      return nil, ("%s is not a Result-IR (JSON)"):format(path)
    end
    coverage.merge(out, coverage.from_ir(ir))
  end
  for _, path in ipairs(src.sinks or {}) do
    any = true
    local h, err = coverage.from_sink(path)
    if not h then
      return nil, err
    end
    coverage.merge(out, h)
  end
  if not any then
    return nil
  end
  return out
end

M.coverage = coverage.compute

-- ===========================================================
-- surface
-- ===========================================================

---Read the surface in a child editor (`testing.surface.collect`).
---@param root string
---@param opts Testing.Surface.CollectOpts
---@return Testing.Surface.Surface|nil
---@return string|nil err
function M.collect(root, opts)
  return require("testing.surface.collect").collect(root, opts)
end

---Read the surface in THIS editor (the plugin must be set up already).
---@param opts Testing.Surface.ReadOpts
---@return Testing.Surface.Surface
function M.read(opts)
  return require("testing.surface.read").read(opts)
end

-- ===========================================================
-- report
-- ===========================================================

---@class Testing.Surface.CliThresholds
---@field overall? number
---@field kinds table<string, number>
---@field problems? string[] A threshold that was refused (not a number between 0 and 1).

---@class Testing.Surface.ReportOpts
---@field config? table The project configuration (`Testing.ProjectConfig`; default: load `<root>/.testing.lua`).
---@field plugin? string
---@field surface? Testing.Surface.Surface A surface already read (skips the child editor).
---@field collect? fun(root: string, opts: table): Testing.Surface.Surface|nil, string|nil Seam for specs.
---@field hits? Testing.Surface.HitSources
---@field kinds? string[]
---@field ignore? string[]
---@field thresholds? Testing.Surface.CliThresholds From the command line.
---@field baseline? string|table A baseline file or an already parsed baseline.
---@field fail_on_new? boolean
---@field fail_on_removed? boolean
---@field require_signed_baseline? boolean A baseline that is `edited` or `unsigned` fails the run.
---@field write_baseline? string

---Write a file the way lib.nvim does (temp file, flush, rename): never half a file.
---@param path string
---@param text string
---@return boolean ok
local function atomic_write(path, text)
  local ok, written = pcall(function()
    return (require("lib.nvim.fs.write.atomic")(path, text))
  end)
  return ok and written == true
end

---Build the report: surface, coverage (when hits are given), thresholds, baseline diff, exit code.
---@param root string
---@param opts? Testing.Surface.ReportOpts
---@return table report
function M.report(root, opts)
  opts = opts or {}
  local project = opts.config
  local notes = {}
  if not project then
    local loaded = require("testing.config.project").load(root)
    if loaded.error then
      return { error = loaded.error, exit_code = M.EXIT_USAGE, notes = {} }
    end
    project = loaded.config
    for _, p in ipairs(loaded.problems or {}) do
      -- the `surface` key of `.testing.lua` is not part of the validated schema yet
      if not tostring(p):find("surface", 1, true) then
        notes[#notes + 1] = "config: " .. p
      end
    end
  end
  local surf_cfg = type(project.surface) == "table" and project.surface or {}
  local plugin = opts.plugin or project.plugin

  local surface = opts.surface
  if not surface then
    local minit
    if type(project.minit) == "string" and project.minit ~= "" then
      local abs = vim.fs.normalize(root .. "/" .. project.minit)
      if vim.uv.fs_stat(abs) then
        minit = abs
      end
    end
    local collect = opts.collect or M.collect
    local got, err = collect(root, {
      plugin = plugin,
      minit = minit,
      deps = project.deps,
      setup = project.setup,
      setup_chunk = surf_cfg.setup_chunk,
    })
    if not got then
      return { plugin = plugin, error = err, exit_code = M.EXIT_INFRA, notes = notes }
    end
    surface = got
  end
  for _, n in ipairs(surface.notes or {}) do
    notes[#notes + 1] = n
  end

  local report = {
    plugin = plugin,
    root = root,
    surface = surface,
    failures = {},
    notes = notes,
    exit_code = M.EXIT_OK,
  }

  local hits, herr = M.hits(opts.hits or {})
  if herr then
    report.error = herr
    report.exit_code = M.EXIT_USAGE
    return report
  end
  local kinds = opts.kinds or surf_cfg.kinds
  local ignore = opts.ignore or surf_cfg.ignore
  report.thresholds =
    coverage.thresholds(project.coverage, surf_cfg, opts.thresholds or { kinds = {} })
  local wants_gate = report.thresholds.overall > 0
  for _, t in pairs(report.thresholds.kinds) do
    wants_gate = wants_gate or t > 0
  end
  if not hits then
    if wants_gate or opts.baseline or opts.write_baseline or opts.require_signed_baseline then
      report.error =
        "a threshold or a baseline needs a tracked run: give --from <ir.json> or --hits <file>"
      report.exit_code = M.EXIT_USAGE
    end
    return report
  end
  for _, n in ipairs(hits.notes) do
    notes[#notes + 1] = n
  end
  local cov = coverage.compute(surface, hits, { kinds = kinds, ignore = ignore })
  report.coverage = cov
  report.hits = hits
  report.files = coverage.by_file(cov, hits)
  report.failures = coverage.check(cov, report.thresholds)
  for _, problem in ipairs(report.thresholds.problems or {}) do
    notes[#notes + 1] = problem
  end
  if cov.total == 0 and #report.failures == 0 and #cov.entries == 0 then
    notes[#notes + 1] =
      "nothing to cover in the asked kinds: a threshold of a kind the plugin does not have passes"
  end

  local failed = #report.failures > 0
  if opts.require_signed_baseline and not opts.baseline then
    report.error = "--require-signed-baseline needs a baseline to check: give --baseline <file>"
    report.exit_code = M.EXIT_USAGE
    return report
  end
  if opts.baseline then
    local base = opts.baseline
    if type(base) == "string" then
      local text, rerr = read_file(base)
      if not text then
        report.error = rerr
        report.exit_code = M.EXIT_USAGE
        return report
      end
      local perr
      base, perr = coverage.parse_baseline(text)
      if not base then
        report.error = ("%s: %s"):format(opts.baseline, perr)
        report.exit_code = M.EXIT_USAGE
        return report
      end
    end
    report.diff = coverage.diff(base --[[@as table]], cov)
    if #report.diff.regressions > 0 or (opts.fail_on_new and #report.diff.new_missing > 0) then
      failed = true
    end
    if opts.fail_on_removed and #report.diff.removed > 0 then
      failed = true
      notes[#notes + 1] = ("baseline: %d entry(ies) that were exercised are gone from the surface (--fail-on-removed)"):format(
        #report.diff.removed
      )
    end
    -- a baseline is the bar the next run is measured against: say when the file is not what a run wrote
    local base_state = coverage.baseline_state(base --[[@as table]])
    if base_state == "edited" then
      notes[#notes + 1] =
        "baseline: its entries do not match its digest: edited by hand (or by another tool); the bar is what the file says now"
    elseif base_state == "unsigned" then
      notes[#notes + 1] =
        "baseline: no digest (written by an older version or by hand): it cannot be told whether it was edited"
    end
    if opts.require_signed_baseline and base_state ~= "signed" then
      failed = true
      notes[#notes + 1] = ("baseline: not signed (%s): --require-signed-baseline fails the run; rewrite it with --write-baseline from a green run"):format(
        base_state
      )
    end
  end
  report.exit_code = failed and M.EXIT_FAILED or M.EXIT_OK
  if opts.write_baseline then
    if failed then
      notes[#notes + 1] = "baseline not written: the run failed"
    else
      local ok, enc = pcall(vim.json.encode, coverage.baseline(cov), { sort_keys = true })
      if not ok then
        ok, enc = pcall(vim.json.encode, coverage.baseline(cov))
      end
      -- atomic: a baseline that is half written would lower the bar of every later run
      local wrote = ok and atomic_write(opts.write_baseline, enc .. "\n")
      if wrote then
        notes[#notes + 1] = "baseline written: " .. opts.write_baseline
      else
        report.error = "cannot write the baseline " .. tostring(opts.write_baseline)
        report.exit_code = M.EXIT_INFRA
      end
    end
  end
  return report
end

---Write the aggregate into a Result-IR (`ir.surface`).
---@param ir table
---@param report table
---@return table ir
function M.annotate_ir(ir, report)
  if report.coverage then
    coverage.annotate_ir(ir, report.coverage, report.files, report.hits)
  end
  return ir
end

-- ===========================================================
-- command line
-- ===========================================================

---@class Testing.Surface.Args
---@field root? string
---@field from string[]
---@field sinks string[]
---@field kinds? string[]
---@field ignore string[]
---@field thresholds Testing.Surface.CliThresholds
---@field baseline? string
---@field fail_on_new boolean
---@field fail_on_removed boolean
---@field require_signed_baseline boolean
---@field write_baseline? string
---@field format "text"|"markdown"|"json"
---@field out? string
---@field help boolean

---@param s string
---@return number|nil
local function unit(s)
  local n = tonumber(s)
  if n and n >= 0 and n <= 1 then
    return n
  end
  return nil
end

---Parse the arguments after `surface`.
---@param argv string[]
---@return Testing.Surface.Args|nil
---@return string|nil err
function M.parse_args(argv)
  ---@type Testing.Surface.Args
  local a = {
    from = {},
    sinks = {},
    ignore = {},
    thresholds = { kinds = {} },
    fail_on_new = false,
    fail_on_removed = false,
    require_signed_baseline = false,
    format = "text",
    help = false,
  }
  local i = 1
  ---@param name string
  ---@return string|nil value
  ---@return string|nil err
  local function value(name, inline)
    if inline then
      return inline
    end
    i = i + 1
    if argv[i] == nil then
      return nil, name .. " needs a value"
    end
    return argv[i]
  end
  while i <= #argv do
    local arg = argv[i]
    local name, inline = arg:match("^(%-%-[%w%-]+)=(.*)$")
    name = name or arg
    local v, err
    if name == "-h" or name == "--help" then
      a.help = true
    elseif name == "--json" then
      a.format = "json"
    elseif name == "--markdown" then
      a.format = "markdown"
    elseif name == "--fail-on-new" then
      a.fail_on_new = true
    elseif name == "--fail-on-removed" then
      a.fail_on_removed = true
    elseif name == "--require-signed-baseline" then
      a.require_signed_baseline = true
    elseif name == "--from" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.from[#a.from + 1] = v
    elseif name == "--hits" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.sinks[#a.sinks + 1] = v
    elseif name == "--kind" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.kinds = a.kinds or {}
      for k in v:gmatch("[^,]+") do
        if not vim.tbl_contains(ids.KINDS, k) then
          return nil, ("--kind: unknown kind %q (%s)"):format(k, table.concat(ids.KINDS, ", "))
        end
        a.kinds[#a.kinds + 1] = k
      end
    elseif name == "--ignore" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.ignore[#a.ignore + 1] = v
    elseif name == "--threshold" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      local kind, num = v:match("^(%a+)=(.+)$")
      if kind then
        if not vim.tbl_contains(ids.KINDS, kind) then
          return nil, ("--threshold: unknown kind %q"):format(kind)
        end
        local n = unit(num)
        if not n then
          return nil, ("--threshold %s: %q is not a number between 0 and 1"):format(kind, num)
        end
        a.thresholds.kinds[kind] = n
      else
        local n = unit(v)
        if not n then
          return nil, ("--threshold: %q is not a number between 0 and 1"):format(v)
        end
        a.thresholds.overall = n
      end
    elseif name == "--baseline" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.baseline = v
    elseif name == "--write-baseline" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.write_baseline = v
    elseif name == "--out" then
      v, err = value(name, inline)
      if not v then
        return nil, err
      end
      a.out = v
    elseif name == "list" and a.root == nil and i == 1 then
      -- `testing surface list`: the one view there is
      a.root = nil
    elseif arg:sub(1, 1) == "-" and #arg > 1 then
      return nil, ("unknown option %s"):format((arg:sub(1, 60):gsub("%c", "?")))
    elseif a.root == nil then
      a.root = arg
    else
      return nil, "only one path is accepted"
    end
    i = i + 1
  end
  return a
end

---@class Testing.Surface.Services
---@field cwd? string Default root.
---@field collect? fun(root: string, opts: table): Testing.Surface.Surface|nil, string|nil
---@field config? table Replaces the project configuration (specs).

---`testing surface` / `:Testing surface`.
---@param argv string[]
---@param services? Testing.Surface.Services
---@return integer code
---@return string text
function M.main(argv, services)
  services = services or {}
  local args, perr = M.parse_args(argv)
  if not args then
    return M.EXIT_USAGE, "testing surface: " .. tostring(perr) .. "\n" .. M.USAGE .. "\n"
  end
  if args.help then
    return M.EXIT_OK, M.USAGE .. "\n"
  end
  local root =
    vim.fs.normalize(vim.fn.fnamemodify(args.root or services.cwd or vim.fn.getcwd(), ":p"))
  root = root:gsub("/+$", "")
  local report = M.report(root, {
    config = services.config,
    collect = services.collect,
    hits = { from = args.from, sinks = args.sinks },
    kinds = args.kinds,
    ignore = #args.ignore > 0 and args.ignore or nil,
    thresholds = args.thresholds,
    baseline = args.baseline,
    fail_on_new = args.fail_on_new,
    fail_on_removed = args.fail_on_removed,
    require_signed_baseline = args.require_signed_baseline,
    write_baseline = args.write_baseline,
  })
  if report.error and not report.surface then
    local code = report.exit_code
    return code, "testing surface: " .. tostring(report.error) .. "\n"
  end
  local text = render.render(report, args.format)
  if report.error then
    text = text .. "testing surface: " .. tostring(report.error) .. "\n"
  end
  if args.out then
    if not atomic_write(args.out, text) then
      text = text .. "testing surface: cannot write " .. args.out .. "\n"
      if report.exit_code == M.EXIT_OK then
        report.exit_code = M.EXIT_INFRA
      end
    end
  end
  return report.exit_code, text
end

return M
