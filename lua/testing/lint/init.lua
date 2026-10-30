---@module 'testing.lint'
---@brief `testing lint`: the linters of the pipeline on the changed files, named files or the whole repository.
---@description
--- ```
--- testing lint [<check>...] [--file=<a,b>|--changed|--all] [--fix] [--on-save] [--agent|--no-agent] [--json]
---              [--root=<dir>]
--- ```
---
--- The checks are the steps of the pipeline (`ci` section of `.testing.lua`, or the derived one) whose preset has a
--- `lint` descriptor (`testing.ci.presets`: stylua, luacheck, luals), so a linter is described once and runs the same
--- in `testing ci`, here and in the editor. A named check is such a step, or a lint preset the pipeline does not
--- have (its defaults: `testing lint luals`).
---
--- Scope: `--changed` (default) the files changed against HEAD plus the untracked ones git does not ignore,
--- `--file` the named ones, `--all` exactly what `testing ci` runs (the step's own args); a check only sees the files
--- with one of its extensions and below the paths of its args (a scope is never more than `--all`; the others are
--- "not checked by <check>"). A check that takes files gets them in place of the paths of its args (its options
--- stay); a check of the whole workspace (luals) runs as it is and keeps the findings of the files in scope. `--fix` checks first, runs the fix
--- of the check (stylua) on the files with findings and checks again: the exit code is what is still wrong.
---
--- The processes are those of `testing ci` (`testing.ci` internals: the `needs` lookup, the deadline that kills the
--- tree, the error format). A missing tool is a reported skip of that check and exit 3, never green (NEW-43); the
--- other checks still run. Exit codes, the worst wins: 0 green or nothing to check, 1 findings, 2 usage, 3 a tool is
--- missing or a check could not run.

local presets = require("testing.ci.presets")

local M = {}

M.EXIT_OK, M.EXIT_FAILED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-lint/1"

M.USAGE = table.concat({
  "usage: testing lint [<check>...] [--file=<f>...|--changed|--all] [--fix] [--on-save] [--agent|--no-agent] [--json]",
  "                    [--root=<dir>]",
  "  <check>       a step of the pipeline whose preset lints (stylua, luacheck, luals), or such a preset the",
  "                pipeline does not have (its defaults); default: every lint step of the pipeline",
  "  --changed     the files changed against HEAD and the untracked ones git does not ignore (default)",
  "  --file=<f>    this file (relative to the root, or absolute below it); repeatable, and a value that names no",
  "                file is split on commas (--file=a.lua,b.lua)",
  "  --all         what the step checks in `testing ci` (its own args)",
  "  --fix         rewrite what a check can fix (stylua) and check again; a check without a fix only checks",
  "  --on-save     only the checks that may run on save (never luals): the editor's check on save",
  "  --agent       the agent report: the verdict first, then only the findings (default in an agent",
  "                environment: TESTING_AGENT, CLAUDECODE, ...); --no-agent: the terminal report",
  "  --json        write the testing-lint/1 document to stdout instead of a report",
  "  --root=<dir>  the project root (default: the current directory)",
  "exit: 0 green or nothing to check, 1 findings, 2 usage, 3 a tool is missing or a check could not run",
}, "\n")

---@class Testing.Lint.Args
---@field checks string[]
---@field scope "changed"|"file"|"all"
---@field files? string[] The values of `--file`, as given (split on commas by `M.scope_files` when needed).
---@field fix boolean
---@field on_save boolean
---@field json boolean
---@field agent? boolean nil: decided by the environment.
---@field root string
---@field help boolean

---@param argv string[] The arguments after `lint`.
---@return Testing.Lint.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Lint.Args
  local args = {
    checks = {},
    scope = "changed",
    fix = false,
    on_save = false,
    json = false,
    root = ".",
    help = false,
  }
  local scope_flag
  ---@param flag string
  ---@return string|nil problem
  local function set_scope(flag)
    if scope_flag and scope_flag ~= flag then
      return ("--%s and --%s exclude each other"):format(scope_flag, flag)
    end
    scope_flag = flag
    args.scope = flag --[[@as "changed"|"file"|"all"]]
    return nil
  end
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    local problem
    if a == "-h" or key == "help" then
      args.help = true
    elseif a:sub(1, 1) ~= "-" then
      args.checks[#args.checks + 1] = a
    elseif (key == "changed" or key == "all") and value == nil then
      problem = set_scope(key)
    elseif (key == "fix" or key == "json") and value == nil then
      args[key] = true
    elseif key == "on-save" and value == nil then
      args.on_save = true
    elseif (key == "agent" or key == "no-agent") and value == nil then
      args.agent = key == "agent"
    elseif key == "file" or key == "root" then
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "root" then
        args.root = value
      else
        problem = set_scope("file")
        args.files = args.files or {}
        args.files[#args.files + 1] = value
      end
    else
      problem = ("unknown argument %s"):format(a)
    end
    if problem then
      return nil, problem
    end
    i = i + 1
  end
  if args.scope == "file" and #args.files == 0 then
    return nil, "--file names no file"
  end
  return args
end

---@param s string
---@return boolean
local function is_absolute(s)
  return s:find("^[/\\]") ~= nil or s:find("^%a:[/\\]") ~= nil
end

---The key two spellings of one relative path share (case-insensitive where the file system is).
---@param rel string
---@return string
local function path_key(rel)
  rel = require("testing.ci.report").normalize_file(rel)
  return require("testing.platform").is_case_insensitive() and rel:lower() or rel
end

---The real path of `path` (symlinks, junctions, macOS' `/var` that is `/private/var` resolved): of the file, else of
---the nearest folder above it that exists (a deleted file), else the path as written. Forward slashes.
---@param path string
---@return string
function M.real_path(path)
  local p = vim.fs.normalize(path)
  local rest = ""
  while p ~= "" do
    local r = vim.uv.fs_realpath(p)
    if r then
      return vim.fs.normalize(r) .. rest
    end
    local parent = vim.fs.dirname(p)
    if not parent or parent == p then
      break
    end
    rest = "/" .. vim.fs.basename(p) .. rest
    p = parent
  end
  return vim.fs.normalize(path)
end

---@param base string Normalised, no trailing slash.
---@param full string Normalised.
---@return string|nil
local function below(base, full)
  base = base .. "/"
  local a, b = full, base
  if require("testing.platform").is_case_insensitive() then
    a, b = a:lower(), b:lower()
  end
  if a:sub(1, #b) ~= b or #a == #b then
    return nil
  end
  return full:sub(#b + 1)
end

---A path relative to the root (forward slashes), nil when it does not lie below it. Two spellings of one folder (a
---link, `/var` and `/private/var`) are compared by their real paths.
---@param root string Absolute, normalised, no trailing slash.
---@param path string Relative to the root or absolute.
---@return string|nil
function M.relative(root, path)
  local full = vim.fs.normalize(is_absolute(path) and path or (root .. "/" .. path))
  local base = vim.fs.normalize(root):gsub("/+$", "")
  local rel = below(base, full)
  if rel or not is_absolute(path) then
    return rel
  end
  return below((M.real_path(base):gsub("/+$", "")), M.real_path(full))
end

---@param list string[]
---@param ext string[]
---@return string[]
local function with_ext(list, ext)
  local wanted = {}
  for _, e in ipairs(ext) do
    wanted[e:lower()] = true
  end
  local out = {}
  for _, f in ipairs(list) do
    local e = f:match("%.([^./]+)$")
    if e and wanted[e:lower()] then
      out[#out + 1] = f
    end
  end
  return out
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@class Testing.Lint.Check
---@field name string
---@field step Testing.Ci.Step
---@field preset Testing.Ci.Preset

---@class Testing.Lint.Result
---@field name string
---@field preset string
---@field state "green"|"red"|"skipped"|"error"|"infra"
---@field exit? integer
---@field ms integer
---@field ext string[]
---@field files? string[] The files in scope (nil: `--all`).
---@field findings Testing.Ci.Finding[]
---@field findings_total integer
---@field fixed string[] Files the fix changed.
---@field no_fix? boolean `--fix` and the check has none.
---@field missing? boolean Skipped because a tool it needs is missing (exit 3).
---@field nothing? boolean No file in scope for this check.
---@field not_checked? string[] Files of the scope outside the paths of the check's args.
---@field reason? string
---@field errors string[]

---The checks a call names, or every lint step of the pipeline.
---@param pipeline Testing.Ci.Pipeline|nil
---@param args Testing.Lint.Args
---@param load_problems string[]|nil Why the pipeline could not be loaded.
---@param absent? boolean The project has no pipeline at all (nothing written, nothing derivable): a named lint
---preset then runs with its defaults. A pipeline that could not be loaded (an untrusted root, a broken
---`.testing.lua`) is an error, never a fallback to defaults.
---@return Testing.Lint.Check[]|nil checks
---@return string|nil problem
function M.select(pipeline, args, load_problems, absent)
  if not pipeline and not (absent and #args.checks > 0) then
    return nil, table.concat(load_problems or { "no pipeline" }, "; ")
  end
  local steps = pipeline and pipeline.steps or {}
  local available = {}
  for name, step in pairs(steps) do
    local preset = step.preset and presets.get(step.preset)
    if preset and preset.lint then
      available[#available + 1] = name
    end
  end
  table.sort(available)
  local checks = {}
  if #args.checks == 0 then
    for _, name in ipairs(available) do
      local step = steps[name]
      checks[#checks + 1] = { name = name, step = step, preset = presets.get(step.preset) }
    end
  else
    local seen = {}
    for _, name in ipairs(args.checks) do
      if not seen[name] then
        seen[name] = true
        local step = steps[name]
        local preset = step and step.preset and presets.get(step.preset) or nil
        if step and not (preset and preset.lint) then
          return nil,
            ("%s is a step of the pipeline but no lint check (lint presets: %s)"):format(
              name,
              table.concat(presets.lint_names(), ", ")
            )
        elseif not step then
          preset = presets.get(name)
          if not (preset and preset.lint) then
            local known = vim.deepcopy(available)
            for _, p in ipairs(presets.lint_names()) do
              if not vim.tbl_contains(known, p) then
                known[#known + 1] = p
              end
            end
            return nil,
              ("unknown check %s (lint checks: %s)%s"):format(
                name,
                table.concat(known, ", "),
                pipeline and "" or ("; " .. table.concat(load_problems or {}, "; "))
              )
          end
          step = presets.step(
            name,
            preset,
            { timeout_ms = require("testing.ci.schema").DEFAULT_TIMEOUT_MS }
          )
        end
        ---@cast preset Testing.Ci.Preset
        checks[#checks + 1] = { name = name, step = step, preset = preset }
      end
    end
  end
  -- on save, the default set leaves out what is too expensive to run after every write (a named check runs)
  if args.on_save and #args.checks == 0 then
    checks = vim.tbl_filter(function(c)
      return c.preset.lint.on_save ~= false
    end, checks)
  end
  return checks
end

---The files of the scope, relative to the root; nil for `--all`.
---@param root string
---@param args Testing.Lint.Args
---@return string[]|nil files
---@return integer|nil code An exit code when the scope cannot be had.
---@return string|nil problem
function M.scope_files(root, args)
  if args.scope == "all" then
    return nil
  end
  local out, seen = {}, {}
  local function add(rel)
    local k = path_key(rel)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = rel
    end
  end
  if args.scope == "file" then
    local named = {}
    for _, value in ipairs(args.files or {}) do
      -- a value that is a file is one file (also with a comma in its name); else a list
      local whole = M.relative(root, value)
      if whole and vim.fn.filereadable(root .. "/" .. whole) == 1 then
        named[#named + 1] = value
      else
        vim.list_extend(named, vim.split(value, ",", { trimempty = true }))
      end
    end
    if #named == 0 then
      return nil, M.EXIT_USAGE, "--file names no file"
    end
    for _, f in ipairs(named) do
      local rel = M.relative(root, f)
      if not rel then
        return nil, M.EXIT_USAGE, ("--file %s does not lie below the root %s"):format(f, root)
      end
      if vim.fn.filereadable(root .. "/" .. rel) ~= 1 then
        return nil, M.EXIT_USAGE, ("--file %s is not a file"):format(f)
      end
      add(rel)
    end
    return out
  end
  if vim.fn.executable("git") ~= 1 then
    return nil, M.EXIT_INFRA, "--changed needs git, which was not found on PATH"
  end
  local files, why = require("testing.affected.git").changed(root, { mode = "changed" })
  if not files then
    return nil,
      M.EXIT_USAGE,
      ("--changed: %s (name the files with --file, or check everything with --all)"):format(
        tostring(why)
      )
  end
  for _, rel in ipairs(files) do
    -- a deleted file is a change, but nothing to check
    if vim.fn.filereadable(root .. "/" .. rel) == 1 then
      add(rel)
    end
  end
  return out
end

local function quiet() end

---The step's own args split into options (kept when files are named) and the paths they check.
---@param check Testing.Lint.Check
---@return string[] options
---@return string[] paths
function M.step_parts(check)
  local lint = check.preset.lint --[[@as Testing.Ci.PresetLint]]
  local own = vim.list_slice(check.step.argv or {}, 2 + #(check.preset.fixed or {}))
  local valued = {}
  for _, o in ipairs(lint.valued or {}) do
    valued[o] = true
  end
  local options, paths = {}, {}
  local i = 1
  while i <= #own do
    local a = own[i]
    if lint.path_option and a:sub(1, #lint.path_option) == lint.path_option then
      paths[#paths + 1] = a:sub(#lint.path_option + 1)
    elseif a:sub(1, 1) == "-" then
      options[#options + 1] = a
      if valued[a] and own[i + 1] then
        i = i + 1
        options[#options + 1] = own[i]
      end
    elseif lint.path_option then
      options[#options + 1] = a
    else
      paths[#paths + 1] = a
    end
    i = i + 1
  end
  return options, paths
end

---Whether a file (relative to the root) lies below one of the paths a step checks (`.` is everything; a path that is
---a file matches only itself).
---@param paths string[]
---@param rel string
---@return boolean
function M.within(paths, rel)
  if #paths == 0 then
    return true
  end
  local k = path_key(rel)
  for _, p in ipairs(paths) do
    local pk = path_key(p):gsub("/+$", "")
    if pk == "" or pk == "." or pk == k or k:sub(1, #pk + 1) == pk .. "/" then
      return true
    end
  end
  return false
end

---Run one check over `files` (nil: its own args) and read its findings.
---@param check Testing.Lint.Check
---@param files string[]|nil
---@param root string
---@param derived table|nil
---@return Testing.Ci.StepResult result
---@return boolean|nil missing A tool it needs is missing.
local function run_check(check, files, root, derived)
  local internal = require("testing.ci").internal
  local lint = check.preset.lint --[[@as Testing.Ci.PresetLint]]
  local step = vim.deepcopy(check.step)
  local keep
  if files then
    if lint.files then
      -- the tool and its fixed arguments, then the files instead of the step's args
      -- the tool, its fixed arguments, what goes before named files, the options of the step's args, the files
      local argv = { check.preset.tool }
      vim.list_extend(argv, check.preset.fixed or {})
      vim.list_extend(argv, lint.file_args or {})
      vim.list_extend(argv, (M.step_parts(check)))
      vim.list_extend(argv, files)
      step.argv = argv
    else
      -- the whole workspace: only the findings of the files in scope count
      local wanted = {}
      for _, f in ipairs(files) do
        wanted[path_key(f)] = true
      end
      keep = function(f)
        local rel = M.relative(root, f.file) or f.file
        return wanted[path_key(rel)] == true
      end
    end
  end
  local planned, code, problems = internal.plan(
    { steps = { [check.name] = step }, derived = derived } --[[@as Testing.Ci.Pipeline]],
    { check.name },
    root
  )
  if not planned then
    local why = table.concat(problems or {}, "; ")
    if code == M.EXIT_INFRA then
      return { name = check.name, state = "skipped", ms = 0, errors = {}, reason = why }, true
    end
    return { name = check.name, state = "error", ms = 0, errors = {}, reason = why }
  end
  local p = planned[1]
  if p.skip then
    return { name = check.name, state = "skipped", ms = 0, errors = {}, reason = p.skip }
  end
  local t0 = vim.uv.hrtime()
  local r = internal.run_process(p, root, { out = quiet, err = quiet }, { keep = keep })
  r.ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
  for _, f in ipairs(r.findings or {}) do
    f.file = M.relative(root, f.file) or f.file
    if (f.text or "") == "" and lint.message then
      f.text = lint.message
    end
  end
  -- a workspace check is red for a finding anywhere: in scope, only the findings that were kept count. Green only
  -- when the output did hold findings (all of them elsewhere): exit 1 without a single one is a crash or a
  -- configuration error, or output the error format cannot read, and stays red with its last lines
  if
    keep
    and r.state == "red"
    and r.exit == 1
    and (r.findings_total or 0) == 0
    and (r.matched or 0) > 0
  then
    r.state = "green"
  end
  return r
end

---Run the fix of a check on `targets` (or, for `--all`, the step's own args) and name the files it changed.
---@param check Testing.Lint.Check
---@param targets string[] Relative files to fix and compare.
---@param all boolean
---@param root string
---@return string[] changed
---@return string|nil problem
local function run_fix(check, targets, all, root)
  local internal = require("testing.ci").internal
  local lint = check.preset.lint --[[@as Testing.Ci.PresetLint]]
  local before = {}
  for _, t in ipairs(targets) do
    before[t] = read(root .. "/" .. t)
  end
  local step = vim.deepcopy(check.step)
  local argv = vim.deepcopy(lint.fix --[[@as string[] ]])
  if all then
    vim.list_extend(argv, vim.list_slice(check.step.argv, 2 + #(check.preset.fixed or {})))
  else
    vim.list_extend(argv, lint.file_args or {})
    vim.list_extend(argv, (M.step_parts(check)))
    vim.list_extend(argv, targets)
  end
  step.argv, step.efm, step.version_argv = argv, nil, nil
  local planned, _, problems = internal.plan(
    { steps = { [check.name] = step } } --[[@as Testing.Ci.Pipeline]],
    { check.name },
    root
  )
  local problem
  if not planned then
    problem = table.concat(problems or {}, "; ")
  else
    local r = internal.run_process(planned[1], root, { out = quiet, err = quiet })
    if r.state ~= "green" then
      problem = ("the fix (%s) ended with %s%s"):format(
        table.concat(argv, " "),
        r.exit and ("exit " .. r.exit) or r.state,
        r.errors[#r.errors] and (": " .. r.errors[#r.errors]) or ""
      )
    end
  end
  local changed = {}
  for _, t in ipairs(targets) do
    if read(root .. "/" .. t) ~= before[t] then
      changed[#changed + 1] = t
    end
  end
  return changed, problem
end

---@param results Testing.Lint.Result[]
---@return integer exit
---@return string|nil deciding
function M.exit_code(results)
  local worst, deciding = M.EXIT_OK, nil
  local rank = { [M.EXIT_OK] = 0, [M.EXIT_FAILED] = 1, [M.EXIT_USAGE] = 2, [M.EXIT_INFRA] = 3 }
  for _, r in ipairs(results) do
    local code = (r.missing or r.state == "infra") and M.EXIT_INFRA
      or r.state == "error" and M.EXIT_USAGE
      or r.state == "red" and M.EXIT_FAILED
      or M.EXIT_OK
    if rank[code] > rank[worst] then
      worst, deciding = code, r.name
    end
  end
  return worst, deciding
end

---@param v any
---@return any
local function null(v)
  if v == nil then
    return vim.NIL
  end
  return v
end

---The document `testing-lint/1`.
---@param o { root: string, args: Testing.Lint.Args, files: string[]|nil, results: Testing.Lint.Result[], exit: integer, deciding: string|nil, problems?: string[] }
---@return table
function M.document(o)
  local checks = {}
  for _, r in ipairs(o.results) do
    local findings = {}
    for _, f in ipairs(r.findings) do
      findings[#findings + 1] = {
        file = f.file,
        line = null(f.line),
        col = null(f.col),
        message = f.text or "",
        check = r.name,
      }
    end
    checks[#checks + 1] = {
      name = r.name,
      preset = r.preset,
      state = r.state,
      exit = null(r.exit),
      ms = r.ms,
      ext = r.ext,
      files = null(r.files),
      findings = findings,
      findings_total = r.findings_total,
      fixed = r.fixed,
      no_fix = r.no_fix == true,
      missing = r.missing == true,
      nothing = r.nothing == true,
      not_checked = r.not_checked or {},
      reason = null(r.reason),
      errors = r.errors,
    }
  end
  local x = o.exit
  return {
    schema = M.SCHEMA,
    root = o.root,
    scope = { mode = o.args.scope, files = null(o.files) },
    fix = o.args.fix,
    verdict = x == M.EXIT_OK and "green"
      or x == M.EXIT_FAILED and "red"
      or x == M.EXIT_USAGE and "error"
      or "infra",
    exit = x,
    deciding = null(o.deciding),
    problems = o.problems or {},
    checks = checks,
  }
end

---@param s any
---@return string
local function clean(s)
  return require("testing.report.util").clean(tostring(s))
end

---@param f table A finding of the document.
---@return string
local function finding_line(f)
  return require("testing.ci.report").finding_line({
    file = f.file,
    line = f.line,
    col = f.col,
    text = f.message,
  })
end

---@param doc table testing-lint/1
---@return integer green
---@return integer ran Checks that had something to check.
local function counts(doc)
  local green, ran = 0, 0
  for _, c in ipairs(doc.checks) do
    if not c.nothing then
      ran = ran + 1
      green = green + (c.state == "green" and 1 or 0)
    end
  end
  return green, ran
end

---@param doc table
---@return string
local function nothing_text(doc)
  if #doc.checks == 0 then
    return "no lint check: no step of the pipeline has a lint preset ("
      .. table.concat(presets.lint_names(), ", ")
      .. ")"
  end
  return doc.scope.mode == "changed" and "nothing changed" or "nothing to check"
end

---@param doc table
---@return integer
local function total_findings(doc)
  local n = 0
  for _, c in ipairs(doc.checks) do
    n = n + (c.findings_total or 0)
  end
  return n
end

---The first line of the agent report (also the verdict the editor shows).
---@param doc table testing-lint/1
---@return string
function M.verdict_line(doc)
  local green, ran = counts(doc)
  if doc.exit == M.EXIT_OK then
    return ("lint GREEN %d/%d%s"):format(
      green,
      ran,
      ran == 0 and (" (" .. nothing_text(doc) .. ")") or ""
    )
  end
  local word = doc.exit == M.EXIT_FAILED and "RED"
    or doc.exit == M.EXIT_USAGE and "ERROR"
    or "INFRA"
  local deciding = doc.deciding ~= vim.NIL and doc.deciding or nil
  if doc.exit == M.EXIT_FAILED then
    local n = total_findings(doc)
    return ("lint RED %s (%d finding%s)"):format(deciding or "?", n, n == 1 and "" or "s")
  end
  local why
  for _, c in ipairs(doc.checks) do
    if c.name == deciding and c.reason ~= vim.NIL then
      why = c.reason
    end
  end
  why = why or (doc.problems or {})[1]
  return ("lint %s %s%s"):format(word, deciding or "", why and (" (" .. clean(why) .. ")") or "")
end

---@param c table A check of the document.
---@param lines string[]
local function fix_lines(c, lines)
  for _, f in ipairs(c.fixed or {}) do
    lines[#lines + 1] = ("  fixed: %s"):format(clean(f))
  end
  if c.no_fix then
    lines[#lines + 1] = ("  %s: no --fix"):format(c.name)
  end
end

---The agent report: the verdict, then only what needs a look (and what `--fix` changed).
---@param doc table testing-lint/1
---@return string[]
function M.agent(doc)
  local lines = { M.verdict_line(doc) }
  for _, c in ipairs(doc.checks) do
    if c.state ~= "green" and not c.nothing then
      lines[#lines + 1] = ("[%s] %s%s"):format(
        c.name,
        c.state,
        c.reason ~= vim.NIL and (": " .. clean(c.reason)) or ""
      )
      for _, f in ipairs(c.findings) do
        lines[#lines + 1] = "  " .. finding_line(f)
      end
      if c.findings_total > #c.findings then
        lines[#lines + 1] = ("  ... %d more"):format(c.findings_total - #c.findings)
      end
      if #c.findings == 0 and c.state ~= "skipped" then
        for _, e in ipairs(c.errors or {}) do
          lines[#lines + 1] = "  " .. clean(e)
        end
      end
    end
    if #(c.fixed or {}) > 0 or c.no_fix then
      if c.state == "green" then
        lines[#lines + 1] = ("[%s] green"):format(c.name)
      end
      fix_lines(c, lines)
    end
  end
  return lines
end

---The terminal report: one section per check, then the verdict.
---@param doc table testing-lint/1
---@return string[]
function M.term(doc)
  local lines = {}
  local green, ran = counts(doc)
  if ran == 0 and doc.exit == M.EXIT_OK then
    local names = {}
    for _, c in ipairs(doc.checks) do
      names[#names + 1] = c.name
    end
    if #names == 0 then
      lines[1] = "lint: " .. nothing_text(doc)
      return lines
    end
    lines[1] = ("lint: %s (%s; checks: %s)"):format(
      nothing_text(doc),
      doc.scope.mode == "changed" and "no changed file a check reads"
        or "no named file a check reads",
      table.concat(names, ", ")
    )
    for _, c in ipairs(doc.checks) do
      if #(c.not_checked or {}) > 0 then
        lines[#lines + 1] = ("   not checked by %s (outside its args): %s"):format(
          c.name,
          clean(table.concat(c.not_checked, ", "))
        )
      end
    end
    return lines
  end
  for _, c in ipairs(doc.checks) do
    if #(c.not_checked or {}) > 0 then
      lines[#lines + 1] = ("   not checked by %s (outside its args): %s"):format(
        c.name,
        clean(table.concat(c.not_checked, ", "))
      )
    end
    if not c.nothing then
      local what
      if c.files == vim.NIL then
        what = "all"
      else
        what = ("%d file%s"):format(#c.files, #c.files == 1 and "" or "s")
      end
      lines[#lines + 1] = ("== %s (%s)"):format(c.name, what)
      for _, f in ipairs(c.findings) do
        lines[#lines + 1] = "  " .. finding_line(f)
      end
      if c.findings_total > #c.findings then
        lines[#lines + 1] = ("  ... %d more"):format(c.findings_total - #c.findings)
      end
      if #c.findings == 0 and c.state ~= "green" and c.state ~= "skipped" then
        for _, e in ipairs(c.errors or {}) do
          lines[#lines + 1] = "  " .. clean(e)
        end
      end
      fix_lines(c, lines)
      lines[#lines + 1] = ("-- %s: %s%s (%.1f s)%s"):format(
        c.name,
        c.state,
        c.findings_total > 0 and (", " .. c.findings_total .. " finding(s)") or "",
        (c.ms or 0) / 1000,
        c.reason ~= vim.NIL and (", " .. clean(c.reason)) or ""
      )
    end
  end
  if doc.exit == M.EXIT_OK then
    lines[#lines + 1] = ("lint: GREEN %d/%d"):format(green, ran)
  else
    local word = doc.exit == M.EXIT_FAILED and "RED"
      or doc.exit == M.EXIT_USAGE and "ERROR"
      or "INFRA"
    lines[#lines + 1] = ("lint: %s %s (exit %d)"):format(
      word,
      doc.deciding ~= vim.NIL and doc.deciding or "?",
      doc.exit
    )
  end
  return lines
end

---`testing lint ...`.
---@param argv string[] The arguments after `lint`.
---@param sv table `out`, `err` (sinks), `env`.
---@return integer exit_code
function M.main(argv, sv)
  local out, err = sv.out, sv.err
  local args, problem = M.parse(argv)
  if not args then
    err("testing lint: " .. tostring(problem))
    err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    out(M.USAGE)
    return M.EXIT_OK
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    err(("testing lint: root %s is not a directory"):format(args.root))
    return M.EXIT_USAGE
  end
  local agent = args.agent
  if agent == nil then
    agent = require("testing.report.agent").choose(nil, sv.env) == "agent"
  end

  ---@param code integer
  ---@param why string
  ---@return integer
  local function stop(code, why)
    err("testing lint: " .. why)
    if args.json then
      local doc =
        M.document({ root = root, args = args, results = {}, exit = code, problems = { why } })
      out(vim.json.encode(doc))
    elseif agent then
      out(("lint %s %s"):format(code == M.EXIT_USAGE and "ERROR" or "INFRA", clean(why)))
    end
    return code
  end

  local pipeline, load_problems, absent = require("testing.ci.schema").load(root)
  local checks, why = M.select(pipeline, args, load_problems, absent == "absent")
  if not checks then
    return stop(M.EXIT_USAGE, tostring(why))
  end
  local files, code, scope_problem = M.scope_files(root, args)
  if code then
    return stop(code, tostring(scope_problem))
  end

  ---@type Testing.Lint.Result[]
  local results = {}
  for _, check in ipairs(checks) do
    local lint = check.preset.lint --[[@as Testing.Ci.PresetLint]]
    local mine = files and with_ext(files, lint.ext) or nil
    -- a scope is never more than what `testing ci` checks: only the files below the paths of the step's args
    local outside = {}
    if mine then
      local _, paths = M.step_parts(check)
      local inside = {}
      for _, f in ipairs(mine) do
        if M.within(paths, f) then
          inside[#inside + 1] = f
        else
          outside[#outside + 1] = f
        end
      end
      mine = inside
    end
    ---@type Testing.Lint.Result
    local r
    if mine and #mine == 0 then
      r = {
        name = check.name,
        state = "skipped",
        ms = 0,
        reason = "no file in scope",
        nothing = true,
        errors = {},
      } --[[@as Testing.Lint.Result]]
    else
      local res, missing = run_check(check, mine, root, pipeline and pipeline.derived)
      r = res --[[@as Testing.Lint.Result]]
      r.missing = missing
      if args.fix and not missing then
        if not lint.fix then
          r.no_fix = true
        elseif r.state == "red" then
          local targets, seen = {}, {}
          for _, f in ipairs(r.findings or {}) do
            local k = path_key(f.file)
            if not seen[k] and vim.fn.filereadable(root .. "/" .. f.file) == 1 then
              seen[k] = true
              targets[#targets + 1] = f.file
            end
          end
          if #targets == 0 and mine then
            targets = mine
          end
          local changed, fix_problem = run_fix(check, targets, mine == nil, root)
          local ms = r.ms
          -- what is still wrong decides
          r = run_check(check, mine, root, pipeline and pipeline.derived) --[[@as Testing.Lint.Result]]
          r.ms = r.ms + ms
          r.fixed = changed
          if fix_problem and r.state ~= "green" then
            r.reason = fix_problem
          end
        end
      end
    end
    r.preset = check.preset.name
    r.not_checked = outside
    r.ext = lint.ext
    r.files = mine
    r.findings = r.findings or {}
    r.findings_total = r.findings_total or 0
    r.fixed = r.fixed or {}
    r.errors = r.errors or {}
    results[#results + 1] = r
  end

  local exit, deciding = M.exit_code(results)
  local doc = M.document({
    root = root,
    args = args,
    files = files,
    results = results,
    exit = exit,
    deciding = deciding,
  })
  if args.json then
    out(vim.json.encode(doc))
  else
    for _, line in ipairs(agent and M.agent(doc) or M.term(doc)) do
      out(line)
    end
  end
  return exit
end

return M
