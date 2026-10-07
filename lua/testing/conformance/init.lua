---@module 'testing.conformance'
---@brief The conformance suite K1 .. K15: the rules of the gates that can run, as verdicts about a repository.
---@description
--- Guard rail L7 ("gates are specification"): a rule of `NEW_PROJECT`, `RELEASE` or `REVIEW` that can be
--- decided becomes a check, one that needs a reader stays `manual` and is listed in the report. Every plugin
--- with a `.testing.lua` gets the suite without a line of spec code.
---
---   local conformance = require("testing.conformance")
---   local report = conformance.run(root, { only = { "K3", "K7" } })   -- the report as data
---   print(table.concat(conformance.terminal(report), "\n"))           -- terminal lines
---   print(conformance.json(report))                                   -- JSON (sorted keys, deterministic)
---   local code = conformance.main({ "--gate", root }, services)       -- what `testing conformance` does
---
--- The checks (docs/CONFORMANCE.md has the full table):
---
---   K1  every module can be required on its own          K9   no write outside tmp, no process, no network
---   K2  setup() twice is idempotent                       K10  require + setup() within the load budget
---   K3  setup({ keymaps = false }) registers no keymaps   K11  no new global
---   K4  every keymap has a desc                           K12  keymap actions have a command counterpart
---   K5  every user command has completion                 K13  fragile keys, command-name prefix collisions
---   K6  :checkhealth <plugin> runs without an error       K14  BINDINGS.md / commands.md match the registry
---   K7  every soft dependency has a health check          K15  static gate rules (NEW-36/45/48/49, REL-16, ...)
---   K8  no vim.deprecate message and no scheduled error on load and setup
---
--- A check is `{ id, title, rules, kind = "static"|"runtime", level, run(ctx) }` and returns findings; the
--- runtime ones run in a child editor (`testing.rpc`) with the plugin loaded from the repository and the
--- guards on. The report is first and the gate comes later (the author's decision): the default
--- (`--report-only`) always exits 0, except for an infrastructure error (exit 3); `--gate` exits 1 when a
--- check failed. Nothing is ever written into the checked repository (SEC-47), nothing uses the network.

local M = {}

M.EXIT_OK = 0
M.EXIT_FAILED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

---The checks in order.
---@return Testing.Conformance.Check[]
function M.checks()
  return require("testing.conformance.catalog").checks()
end

---The manual rules.
---@return Testing.Conformance.ManualRule[]
function M.manual()
  return vim.deepcopy(require("testing.conformance.catalog").MANUAL)
end

---Run the suite on the repository at `root`. Never raises.
---@param root string
---@param opts? Testing.Conformance.RunOpts
---@return Testing.Conformance.Report
function M.run(root, opts)
  return require("testing.conformance.runner").run(root, opts)
end

---The report as JSON text.
---@param report Testing.Conformance.Report
---@return string|nil json
---@return string|nil err
function M.json(report)
  return require("testing.conformance.render").json(report)
end

---The report as terminal lines.
---@param report Testing.Conformance.Report
---@param opts? { verbose?: boolean, manual?: boolean }
---@return string[]
function M.terminal(report, opts)
  return require("testing.conformance.render").terminal(report, opts)
end

---The report as Markdown.
---@param report Testing.Conformance.Report
---@return string
function M.markdown(report)
  return require("testing.conformance.render").markdown(report)
end

---The report as a Result-IR (for `testing.report` reporters such as `junit` and `github`).
---@param report Testing.Conformance.Report
---@return Testing.Result
function M.to_result(report)
  return require("testing.conformance.render").to_result(report)
end

---The optional rules.nvim bridge for one root (soft: `available = false` without rules.nvim).
---@param root string
---@param opts? Testing.Conformance.BridgeOpts
---@return table
function M.rules_bridge(root, opts)
  return require("testing.conformance.rules_bridge").run(root, opts)
end

---Exit code of a report: 0, unless `--gate` and a check failed (1), `.testing.lua` was unusable (2) or
---something could not run (3).
---@param report Testing.Conformance.Report
---@return integer
function M.exit_code(report)
  if report.verdict == "error" then
    return M.EXIT_INFRA
  end
  if report.config_error then
    return M.EXIT_USAGE
  end
  if report.mode == "gate" and report.verdict == "fail" then
    return M.EXIT_FAILED
  end
  return M.EXIT_OK
end

M.USAGE = table.concat({
  "usage: testing conformance [<root>] [options]",
  "",
  "Runs the conformance checks K1 .. K15 on a repository (default: the current directory).",
  "",
  "  --only K3,K7        run only these checks (repeatable)",
  "  --skip K10          do not run these checks (repeatable)",
  "  --report-only       always exit 0 (default); exit 3 only when a check could not run",
  "  --gate              exit 1 when a check failed (`conformance.gate = true` makes it the default)",
  "  --json              print the report as JSON instead of terminal lines",
  "  --markdown          print the report as Markdown instead of terminal lines",
  "  --verbose           terminal: also waived findings and the notes of every check",
  "  --manual            terminal: also list the manual rules",
  "  --bridge            also run rules.nvim's own check of the same rule families (soft)",
  "  --timings           add durations and measured times (the report is then not deterministic)",
  "  --json-file=<path>      also write the JSON report (never inside the checked repository)",
  "  --markdown-file=<path>  also write the Markdown report",
  "  --junit-file=<path>     also write a JUnit report (one case per check)",
  "  --list              list the checks and exit",
  "  --help              this text",
  "",
  "Exit codes: 0 done, 1 --gate and a check failed, 2 usage error, 3 a check could not run.",
}, "\n")

---@class Testing.Conformance.Parsed
---@field root? string
---@field only string[]
---@field skip string[]
---@field gate? boolean
---@field format "text"|"json"|"markdown"
---@field verbose boolean
---@field manual boolean
---@field bridge boolean
---@field timings boolean
---@field list boolean
---@field help boolean
---@field json_file? string
---@field markdown_file? string
---@field junit_file? string

---Split a comma list into upper-cased ids and validate them.
---@param text string
---@param into string[]
---@return string|nil err
local function add_ids(text, into)
  local ids = require("testing.conformance.catalog").ids()
  for id in text:gmatch("[^,%s]+") do
    local up = id:upper()
    if not ids[up] then
      return ("unknown check id %q (known: K1 .. K%d)"):format(
        id:sub(1, 20),
        #require("testing.conformance.catalog").ORDER
      )
    end
    into[#into + 1] = up
  end
  return nil
end

---Parse the arguments of `conformance`.
---@param argv string[]
---@return Testing.Conformance.Parsed|nil parsed
---@return string|nil err
function M.parse_args(argv)
  ---@type Testing.Conformance.Parsed
  local p = {
    only = {},
    skip = {},
    format = "text",
    verbose = false,
    manual = false,
    bridge = false,
    timings = false,
    list = false,
    help = false,
  }
  local i = 1
  ---@param name string
  ---@return string|nil value
  ---@return string|nil err
  local function value_of(name, a)
    -- plain prefix test: the dashes of an option name are magic in a Lua pattern
    if a:sub(1, #name + 1) == name .. "=" then
      return a:sub(#name + 2)
    end
    i = i + 1
    if argv[i] == nil then
      return nil, name .. " needs a value"
    end
    return argv[i]
  end
  while i <= #argv do
    local a = argv[i]
    local value, err
    if a == "--only" or a:sub(1, 7) == "--only=" then
      value, err = value_of("--only", a)
      err = err or add_ids(value or "", p.only)
    elseif a == "--skip" or a:sub(1, 7) == "--skip=" then
      value, err = value_of("--skip", a)
      err = err or add_ids(value or "", p.skip)
    elseif a == "--report-only" then
      p.gate = false
    elseif a == "--gate" then
      p.gate = true
    elseif a == "--json" then
      p.format = "json"
    elseif a == "--markdown" then
      p.format = "markdown"
    elseif a == "--verbose" then
      p.verbose = true
    elseif a == "--manual" then
      p.manual = true
    elseif a == "--bridge" then
      p.bridge = true
    elseif a == "--timings" then
      p.timings = true
    elseif a == "--list" then
      p.list = true
    elseif a == "--help" or a == "-h" then
      p.help = true
    elseif a == "--json-file" or a:sub(1, 12) == "--json-file=" then
      p.json_file, err = value_of("--json-file", a)
    elseif a == "--markdown-file" or a:sub(1, 16) == "--markdown-file=" then
      p.markdown_file, err = value_of("--markdown-file", a)
    elseif a == "--junit-file" or a:sub(1, 13) == "--junit-file=" then
      p.junit_file, err = value_of("--junit-file", a)
    elseif a:sub(1, 1) == "-" and #a > 1 then
      err = ("unknown option %s"):format(require("testing.conformance.util").show(a, 40))
    elseif p.root == nil then
      p.root = a
    else
      err = "only one path is accepted"
    end
    if err then
      return nil, err
    end
    i = i + 1
  end
  return p
end

---Refuse a report path inside the checked repository (SEC-47).
---@param path string
---@param root string
---@return string|nil err
local function outside_root(path, root)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  local real_root = vim.uv.fs_realpath(root) or root
  local is_subpath = require("lib.nvim.fs.is_subpath")
  -- a link or a junction on the way (a directory outside that points INTO the repository) leads in as well: the
  -- file does not exist yet, so the deepest directory that does is resolved
  local resolved = abs
  local probe = vim.fs.dirname(abs)
  while probe and probe ~= "" do
    local real = vim.uv.fs_realpath(probe)
    if real then
      resolved = vim.fs.normalize(real) .. abs:sub(#probe + 1)
      break
    end
    local up = vim.fs.dirname(probe)
    if up == probe then
      break
    end
    probe = up
  end
  if
    is_subpath(abs, vim.fs.normalize(root), {})
    or is_subpath(abs, vim.fs.normalize(real_root), {})
    or is_subpath(resolved, vim.fs.normalize(real_root), {})
  then
    return ("%s is inside the checked repository: the suite never writes there"):format(
      require("testing.conformance.util").show(path, 100)
    )
  end
  return nil
end

---Run `testing conformance` the way the command line does.
---
---`services`: `out(text)` and `err(text)` sinks (default: stdout/stderr), `cwd` (default: the current
---directory), `run(root, opts)` replaces `conformance.run` (specs).
---@param argv string[]
---@param services? { out?: fun(s: string), err?: fun(s: string), cwd?: string, run?: fun(root: string, opts: table): table }
---@return integer exit_code
function M.main(argv, services)
  services = services or {}
  local out = services.out or function(s)
    io.stdout:write(s, "\n")
  end
  local err = services.err or function(s)
    io.stderr:write(s, "\n")
  end
  local parsed, perr = M.parse_args(argv or {})
  if not parsed then
    err("testing conformance: " .. tostring(perr))
    err(M.USAGE)
    return M.EXIT_USAGE
  end
  if parsed.help then
    out(M.USAGE)
    return M.EXIT_OK
  end
  if parsed.list then
    for _, check in ipairs(M.checks()) do
      out(
        ("%-4s %-8s %s  [%s]"):format(
          check.id,
          check.kind,
          check.title,
          table.concat(check.rules, ", ")
        )
      )
    end
    return M.EXIT_OK
  end

  local root = parsed.root or services.cwd or vim.fn.getcwd()
  -- (not `ipairs`: it stops at the first file that was not asked for)
  for _, path in pairs({
    json = parsed.json_file,
    md = parsed.markdown_file,
    junit = parsed.junit_file,
  }) do
    local problem = outside_root(path, root)
    if problem then
      err("testing conformance: " .. problem)
      return M.EXIT_USAGE
    end
  end

  -- not a sandbox: the checks that need the plugin's code start a child editor that runs it (`plugin/`, the module,
  -- `setup()`), and `.testing.lua` is a Lua file that runs in this process: with the rights of whoever calls this
  err(
    "testing conformance: note: this runs the repository's own code (plugin/, setup(), .testing.lua) with your rights: only point it at a repository you trust"
  )
  local run = services.run or M.run
  local ok, report = pcall(run, root, {
    only = parsed.only,
    skip = parsed.skip,
    gate = parsed.gate,
    timings = parsed.timings,
    bridge = parsed.bridge or nil,
  })
  if not ok then
    err("testing conformance: internal error: " .. tostring(report))
    return M.EXIT_INFRA
  end

  local render = require("testing.conformance.render")
  local atomic = require("lib.nvim.fs.write.atomic")
  local code = M.exit_code(report)
  local function write(path, text)
    local wok, werr = atomic(path, text, { mkdirp = true })
    if not wok then
      err(("testing conformance: cannot write %s: %s"):format(path, tostring(werr)))
      code = M.EXIT_INFRA
    end
  end
  if parsed.json_file or parsed.format == "json" then
    local text, jerr = render.json(report)
    if not text then
      err("testing conformance: cannot encode the report: " .. tostring(jerr))
      return M.EXIT_INFRA
    end
    if parsed.json_file then
      write(parsed.json_file, text)
    end
    if parsed.format == "json" then
      out((text:gsub("\n$", "")))
    end
  end
  if parsed.markdown_file or parsed.format == "markdown" then
    local text = render.markdown(report)
    if parsed.markdown_file then
      write(parsed.markdown_file, text)
    end
    if parsed.format == "markdown" then
      out((text:gsub("\n$", "")))
    end
  end
  if parsed.junit_file then
    local outputs, errors = require("testing.report").run_reporters(render.to_result(report), {
      reporters = { { name = "junit", path = parsed.junit_file } },
    })
    if #errors > 0 or (outputs[1] and outputs[1].err) then
      err("testing conformance: " .. tostring(errors[1] or outputs[1].err))
      code = M.EXIT_INFRA
    end
  end
  if parsed.format == "text" then
    out(
      table.concat(
        render.terminal(report, { verbose = parsed.verbose, manual = parsed.manual }),
        "\n"
      )
    )
  end
  return code
end

return M
