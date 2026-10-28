---@module 'testing.ci'
-- @cache-allow env
-- (a step's own `env` is set for an in-process step and the outer values are put back: no hidden input of a spec)
---@brief `testing ci`: run the pipeline of a repository, described in the `ci` section of its `.testing.lua`.
---@description
--- ```
--- testing ci [--profile=<name>] [--step=<a,b>] [--keep-going] [--json=<file>] [--root=<dir>] [-- <suite options>]
--- ```
---
--- Steps run one after the other, fail-fast unless `--keep-going`. Before the first step every tool the selected steps
--- need is looked up: a missing one is exit 3 (infrastructure), never a green run, and the message names the step and
--- the places searched. Process steps are argv (`.sh` through Git Bash / bash, `.ps1` through pwsh), each with a
--- deadline that kills the whole process tree (`lib.nvim.system.job`, `kill_tree`). The presets of testing.nvim itself
--- (`suite`, `conformance`, `surface`, `budget`) run in this process through `testing.cli`.
---
--- Exit codes, the worst step wins: 0 every step green (or skipped for this system), 1 a step red, 2 a usage or
--- pipeline error (also a step that ended with 2), 3 infrastructure (a tool or dependency missing, a step that could
--- not start, a step that ended with 3). The document `testing-ci/1` is written to the project's state directory
--- (`ci.json` beside `runs.jsonl`); `--step` is a partial selection and the document says so.

local schema = require("testing.ci.schema")

local M = {}

M.EXIT_OK, M.EXIT_FAILED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci/1"

---The last line of a run that is green over a whole profile (a script may read it; a partial run never prints it).
M.SENTINEL = "TESTING_CI_OK"

M.USAGE = table.concat({
  "usage: testing ci [--profile=<name>] [--step=<a,b>] [--keep-going] [--agent|--no-agent] [--json=<file>]",
  "                  [--junit=<file>] [--root=<dir>] [-- <suite options>]",
  "  --profile=<name>  the profile to run (default: ci.default)",
  "  --step=<a,b>      only these steps (a partial run: no proof, no sentinel)",
  "  --keep-going      run every step even after a red one",
  "  --agent           the agent report: the verdict first, then only the findings (default in an agent",
  "                    environment: TESTING_AGENT, CLAUDECODE, ...); --no-agent: the terminal report",
  "  --json=<file>     also write the testing-ci/1 document there",
  "  --junit=<file>    write a JUnit report there (one testsuite per step)",
  "  --root=<dir>      the project root (default: the current directory)",
  "  -- <options>      passed on to the suite step (testing run options, e.g. -- --jobs 4)",
}, "\n")

---@class Testing.Ci.Args
---@field profile? string
---@field steps? string[]
---@field keep_going boolean
---@field json? string
---@field junit? string
---@field agent? boolean nil: decided by the environment.
---@field root string
---@field suite_args string[]
---@field help boolean

---@param argv string[] The arguments after `ci`.
---@return Testing.Ci.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Args
  local args = { keep_going = false, root = ".", suite_args = {}, help = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--" then
      args.suite_args = vim.list_slice(argv, i + 1)
      break
    end
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "keep-going" and value == nil then
      args.keep_going = true
    elseif (key == "agent" or key == "no-agent") and value == nil then
      args.agent = key == "agent"
    elseif
      key == "profile"
      or key == "step"
      or key == "json"
      or key == "junit"
      or key == "root"
    then
      if value == nil then
        i = i + 1
        value = argv[i]
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "step" then
        args.steps = vim.split(value, ",", { trimempty = true })
      elseif key == "profile" then
        args.profile = value
      else
        args[key] = value
      end
    else
      return nil, ("unknown argument %s"):format(a)
    end
    i = i + 1
  end
  return args
end

---The system name `when.os` speaks of.
---@return "windows"|"macos"|"linux"
local function this_os()
  local platform = require("testing.platform")
  if platform.is_windows() then
    return "windows"
  elseif platform.is_macos() then
    return "macos"
  end
  return "linux"
end

---Replace `${root}` and `${deps.<name>}` in `s`. A dependency is found the way `deps` of `.testing.lua` is (also
---beside the runner).
---@param s string
---@param root string
---@param deps_cache table<string, string|false>
---@return string|nil value
---@return string|nil problem A dependency that cannot be found.
local function expand(s, root, deps_cache)
  local problem
  local out = s:gsub("%${([^}]*)}", function(inner)
    if inner == "root" then
      return root
    end
    local name = inner:match("^deps%.(.+)$")
    if deps_cache[name] == nil then
      local found, failures = require("testing.deps").resolve_all({ name }, root)
      deps_cache[name] = found[1] and found[1].dir or false
      if not found[1] then
        problem = failures[1]
      end
    end
    if deps_cache[name] == false then
      problem = problem or ("dependency %s was not found"):format(name)
      return ""
    end
    return deps_cache[name]
  end)
  if problem then
    return nil, problem
  end
  return out
end

---@class Testing.Ci.Planned
---@field step Testing.Ci.Step
---@field argv? string[] The final command line; process steps: `argv[1]` is the path the needs check found.
---@field env table<string, string>
---@field skip? string Why the step does not run on this system.

---Look up a tool.
---@param name string
---@return string|nil path
---@return string where What was searched (for the message).
local function find_tool(name)
  -- the leaf modules, not the `lib.nvim.cross` aggregate: that loads `lib.nvim.fs.roots`, which exports
  -- $NVIM_CONFIG_DIR into the process environment
  local executable = require("lib.nvim.cross.executable")
  if name == "bash" then
    local ok, bash = pcall(require, "lib.nvim.cross.bash")
    if not ok then
      return nil, "lib.nvim is too old for `.sh` steps (cross.bash, lib.nvim >= 759db60)"
    end
    local path, why = bash.find()
    return path, why or "Git Bash / bash"
  end
  if name == "pwsh" then
    local p = executable.path("pwsh") or executable.path("powershell")
    return p, "pwsh, powershell on PATH"
  end
  return executable.path(name), name .. " on PATH"
end

---@param s string
---@return boolean
local function is_absolute(s)
  return s:find("^[/\\]") ~= nil or s:find("^%a:[/\\]") ~= nil
end

---Prepare the selected steps: placeholders, interpreters, the `needs` check. The path the check finds is the path
---that is started: a relative command with a separator is a file below the root, a bare name is looked up on PATH
---(`bash` and `pwsh` through their own lookup, so a `bash` step never starts the WSL launcher).
---@param pipeline Testing.Ci.Pipeline
---@param names string[]
---@param root string
---@return Testing.Ci.Planned[]|nil planned
---@return integer|nil code
---@return string[] problems
local function plan(pipeline, names, root)
  local os_name = this_os()
  local deps_cache = {}
  local planned, problems, infra = {}, {}, false
  ---@param name string
  ---@param list string[]
  ---@return string[]
  local function expand_all(name, list)
    local out = {}
    for _, a in ipairs(list) do
      local value, why = expand(a, root, deps_cache)
      if not value then
        problems[#problems + 1] = ("step %s: %s"):format(name, why)
        infra = true
        value = a
      end
      out[#out + 1] = value
    end
    return out
  end
  ---@param name string
  ---@param tool string
  ---@return string|nil path
  local function need(name, tool)
    local path, where = find_tool(tool)
    if not path then
      problems[#problems + 1] = ("step %s needs %s, which was not found (searched: %s)"):format(
        name,
        tool,
        where
      )
      infra = true
    end
    return path
  end

  for _, name in ipairs(names) do
    local step = pipeline.steps[name]
    ---@type Testing.Ci.Planned
    local p = { step = step, env = {} }
    planned[#planned + 1] = p
    if step.os and not step.os[os_name] then
      p.skip = "not on " .. os_name
    else
      for k, v in pairs(step.env) do
        local value, why = expand(v, root, deps_cache)
        if not value then
          problems[#problems + 1] = ("step %s: %s"):format(name, why)
          infra = true
        else
          p.env[k] = value
        end
      end
      local seen = {}
      if step.inprocess then
        p.argv = expand_all(name, step.argv)
      else
        local argv = expand_all(name, step.argv)
        local first = argv[1]
        local script = first:match("%.sh$") and "bash" or first:match("%.ps1$") and "pwsh" or nil
        local file = is_absolute(first) and first
          or (first:find("[/\\]") and (root .. "/" .. first))
          or nil
        if script then
          file = file or (root .. "/" .. first)
          if vim.fn.filereadable(file) ~= 1 then
            problems[#problems + 1] = ("step %s: the script %s does not exist"):format(name, first)
          end
          seen[script] = true
          local interpreter = need(name, script)
          argv[1] = file
          if interpreter then
            table.insert(argv, 1, interpreter)
            if script == "pwsh" then
              table.insert(argv, 2, "-NoProfile")
              table.insert(argv, 3, "-File")
            end
          end
        elseif file then
          if vim.fn.executable(file) ~= 1 and vim.fn.filereadable(file) ~= 1 then
            problems[#problems + 1] = ("step %s: %s does not exist below the root"):format(
              name,
              first
            )
            infra = true
          end
          argv[1] = file
        else
          seen[first] = true
          argv[1] = need(name, first) or first
        end
        p.argv = argv
      end
      for _, tool in ipairs(step.needs) do
        if not seen[tool] then
          seen[tool] = true
          need(name, tool)
        end
      end
    end
  end
  if #problems > 0 then
    return nil, infra and M.EXIT_INFRA or M.EXIT_USAGE, problems
  end
  return planned, nil, problems
end

---@class Testing.Ci.StepResult
---@field name string
---@field state "green"|"red"|"skipped"|"error"|"infra" `error`: an in-process step that ended with exit 2 (usage).
---@field exit integer|nil
---@field ms integer
---@field tool_version? string
---@field timed_out? boolean
---@field reason? string Why a step was skipped or is infra.
---@field errors string[] The last lines of the output (up to 20).
---@field findings? Testing.Ci.Finding[]
---@field findings_total? integer

local MAX_ERRORS = 20

---@param lines string[]
---@param line string
local function keep_error(lines, line)
  if #lines < MAX_ERRORS and line:match("%S") then
    lines[#lines + 1] = line
  end
end

---First line of `<tool> --version`, or nil.
---@param argv string[]|nil
---@return string|nil
local function tool_version(argv)
  if not argv then
    return nil
  end
  local ok, res = pcall(function()
    return vim.system(argv, { text = true }):wait(10000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim((res.stdout or ""):match("[^\r\n]+") or "")
end

---@param planned Testing.Ci.Planned
---@param root string
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return Testing.Ci.StepResult
local function run_process(planned, root, sv)
  local step = planned.step
  local errors, last = {}, {}
  local matcher = require("testing.ci.report").matcher(step.efm)
  local function remember(line)
    last[#last + 1] = line
    if #last > MAX_ERRORS then
      table.remove(last, 1)
    end
    matcher.feed(line)
  end
  local argv = planned.argv --[[@as string[] ]]
  local handle = require("lib.nvim.system.job").start({
    command = argv[1],
    args = vim.list_slice(argv, 2),
    cwd = root,
    env = planned.env,
    kill_tree = true,
    timeout_ms = step.timeout_ms,
    on_stdout = function(_, line)
      sv.out(line)
      remember(line)
    end,
    on_stderr = function(_, line)
      sv.err(line)
      remember(line)
    end,
  })
  if type(handle) ~= "table" or type(handle.is_done) ~= "function" then
    -- an old lib.nvim ignored `kill_tree` and started a plain `vim.system` (no cwd, env or deadline): end it
    pcall(function()
      handle:kill(9)
    end)
    return {
      name = step.name,
      state = "infra",
      ms = 0,
      errors = {},
      reason = "lib.nvim is too old: system.job has no kill_tree (update lib.nvim)",
    }
  end
  local r = (handle --[[@as Lib.System.Job.TreeHandle]]).wait()
  for _, line in ipairs(last) do
    keep_error(errors, line)
  end
  if not r then
    return {
      name = step.name,
      state = "infra",
      ms = 0,
      errors = errors,
      findings = matcher.list,
      findings_total = matcher.total(),
      reason = "the step did not end",
    }
  end
  ---@type Testing.Ci.StepResult
  local result = {
    name = step.name,
    exit = r.code,
    ms = 0,
    errors = errors,
    findings = matcher.list,
    findings_total = matcher.total(),
    timed_out = r.timed_out,
  }
  if r.code == -1 then
    result.state, result.reason = "infra", "could not start: " .. tostring(r.stderr)
  elseif r.timed_out then
    result.state, result.reason = "red", ("timed out after %d ms"):format(step.timeout_ms)
  elseif r.code == 0 then
    result.state = "green"
  else
    result.state = "red"
  end
  return result
end

---@param planned Testing.Ci.Planned
---@param root string
---@param suite_args string[]
---@param sv table The services of the outer run (`out`, `err`, `env`, `script`).
---@return Testing.Ci.StepResult
local function run_inprocess(planned, root, suite_args, sv)
  local step = planned.step
  local command = step.inprocess
  if command == "run" and step.stamp then
    command = "stamp"
  end
  local argv = { command, root }
  vim.list_extend(argv, planned.argv or {})
  if step.inprocess == "run" then
    vim.list_extend(argv, suite_args)
  end
  -- the suite's findings come from its Result-IR: a `--json` of the caller's, or one of ours
  local ir_path, own_ir = nil, false
  if step.inprocess == "run" then
    for i, a in ipairs(argv) do
      ir_path = ir_path or a:match("^%-%-json=(.+)$") or (a == "--json" and argv[i + 1]) or nil
    end
    if not ir_path then
      ir_path, own_ir = vim.fn.tempname() .. "-ci-ir.json", true
      vim.list_extend(argv, { "--json", ir_path })
    end
    -- the caller's path is read as the run writes it: relative to the current directory
    ir_path = vim.fn.fnamemodify(ir_path, ":p")
  end
  local errors, last = {}, {}
  local function sink(fn)
    return function(s)
      fn(s)
      for line in tostring(s):gmatch("[^\n]+") do
        last[#last + 1] = line
        if #last > MAX_ERRORS then
          table.remove(last, 1)
        end
      end
    end
  end
  -- the step's own environment, for the duration of the step
  local saved = {}
  for k, v in pairs(planned.env) do
    saved[k] = vim.uv.os_getenv(k) or false
    vim.uv.os_setenv(k, v)
  end
  -- every service of the outer run (state and cache directory, colour, the specs' fakes), only the sinks are ours
  local ok, code = pcall(
    require("testing.cli").main,
    argv,
    vim.tbl_extend("force", sv, { out = sink(sv.out), err = sink(sv.err) })
  )
  for k, v in pairs(saved) do
    if v == false then
      vim.uv.os_unsetenv(k)
    else
      vim.uv.os_setenv(k, v)
    end
  end
  for _, line in ipairs(last) do
    keep_error(errors, line)
  end
  ---@type Testing.Ci.StepResult
  local result = { name = step.name, ms = 0, errors = errors }
  if ir_path then
    local f = io.open(ir_path, "rb")
    if f then
      local okd, ir = pcall(vim.json.decode, f:read("*a"))
      f:close()
      if okd then
        result.findings, result.findings_total = require("testing.ci.report").ir_findings(ir)
      end
    end
    if own_ir then
      os.remove(ir_path)
    end
  end
  if not ok then
    result.state, result.exit, result.reason = "infra", M.EXIT_INFRA, tostring(code)
  else
    result.exit = code
    result.state = code == 0 and "green"
      or code == 1 and "red"
      or code == M.EXIT_USAGE and "error"
      or "infra"
  end
  return result
end

---@param results Testing.Ci.StepResult[]
---@return integer
local function exit_code(results)
  local worst = M.EXIT_OK
  for _, r in ipairs(results) do
    if r.state == "infra" then
      worst = M.EXIT_INFRA
    elseif r.state == "error" and worst ~= M.EXIT_INFRA then
      worst = M.EXIT_USAGE
    elseif r.state == "red" and worst == M.EXIT_OK then
      worst = M.EXIT_FAILED
    end
  end
  return worst
end

---@param root string
---@param ... string
---@return string|nil stdout (trimmed) when git exits 0
local function git_out(root, ...)
  local argv = { "git", ... }
  local ok, res = pcall(function()
    return vim.system(argv, { cwd = root, text = true }):wait(10000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
end

---Commit, tree and dirty state of the root, taken BEFORE the first step (the document is about what was tested).
---Unknown values stay nil (no git, not a repository): never `dirty = false` for a commit nobody knows.
---@param root string
---@return { commit?: string, tree?: string, dirty?: boolean, repo: string }
local function git_facts(root)
  local facts = { repo = vim.fs.basename(root) }
  facts.commit = git_out(root, "rev-parse", "HEAD")
  if facts.commit then
    facts.tree = git_out(root, "rev-parse", "HEAD^{tree}")
    local status = git_out(root, "status", "--porcelain")
    if status ~= nil then
      facts.dirty = status ~= ""
    end
  end
  return facts
end

---Write the document (state directory, and `--json`), and the transitional `.ci-last.json` when git ignores it.
---@param doc table
---@param root string
---@param json_path string|nil
---@param state_dir string|nil
---@return string[] notes
local function write_doc(doc, root, json_path, state_dir)
  local canonical = require("lib.nvim.json.canonical")
  local atomic = require("lib.nvim.fs.write.atomic")
  local text = canonical.encode(doc) .. "\n"
  local notes = {}
  local dir = require("testing.state").dir(root, { state_dir = state_dir })
  local path = dir .. "/ci.json"
  local locked, note = require("testing.statelock").with(path, function()
    local ok, err = atomic(path, text, { mkdirp = true })
    if not ok then
      notes[#notes + 1] = ("cannot write %s: %s"):format(path, tostring(err))
    end
  end)
  if not locked and note then
    notes[#notes + 1] = note
  end
  if json_path then
    local ok, err = atomic(vim.fn.fnamemodify(json_path, ":p"), text, { mkdirp = true })
    if not ok then
      notes[#notes + 1] = ("cannot write %s: %s"):format(json_path, tostring(err))
    end
  end
  -- transitional: the old `.ci-last.json` of `scripts/ci.sh`, only where git ignores it (never dirty the tree),
  -- and only for a complete run on the commit that was tested
  if
    not doc.partial
    and not doc.head_moved
    and git_out(root, "check-ignore", "-q", ".ci-last.json")
  then
    local legacy = vim.json.encode({
      repo = doc.repo,
      commit = type(doc.commit) == "string" and doc.commit or "unknown",
      dirty = doc.dirty == true,
      time = doc.time,
      state = doc.verdict == "green" and "green" or "red",
      note = doc.verdict == "green" and ""
        or tostring(doc.first_red ~= vim.NIL and doc.first_red or doc.verdict),
    })
    local ok, err = atomic(root .. "/.ci-last.json", legacy .. "\n", {})
    if not ok then
      notes[#notes + 1] = ("cannot write %s/.ci-last.json: %s"):format(root, tostring(err))
    end
  end
  return notes
end

---@param ms integer
---@return string
local function seconds(ms)
  return ("%.1f s"):format(ms / 1000)
end

---`testing ci ...`.
---@param argv string[] The arguments after `ci`.
---@param sv table `out`, `err` (sinks), `env`, `script`; `state_dir` (specs).
---@return integer exit_code
function M.main(argv, sv)
  local out, err = sv.out, sv.err
  local args, problem = M.parse(argv)
  if not args then
    err("testing ci: " .. tostring(problem))
    err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    out(M.USAGE)
    return M.EXIT_OK
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    err(("testing ci: root %s is not a directory"):format(args.root))
    return M.EXIT_USAGE
  end

  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    err("testing ci: " .. loaded.error)
    return M.EXIT_USAGE
  end
  local raw = loaded.config.ci
  if raw == nil then
    -- a `ci` that is not a table was dropped by the loader with a warning: say that, not "no section"
    for _, p in ipairs(loaded.problems or {}) do
      if p:find("'ci'", 1, true) then
        err("testing ci: " .. p)
        return M.EXIT_USAGE
      end
    end
    err(("testing ci: %s/.testing.lua has no `ci` section (docs/CI.md)"):format(root))
    return M.EXIT_USAGE
  end
  local pipeline, problems = schema.resolve(raw)
  if not pipeline then
    for _, p in ipairs(problems) do
      err("testing ci: " .. p)
    end
    return M.EXIT_USAGE
  end

  local profile = args.profile or pipeline.default
  if not pipeline.profiles[profile] then
    local names = vim.tbl_keys(pipeline.profiles)
    table.sort(names)
    err(
      ("testing ci: unknown profile %s (profiles: %s)"):format(profile, table.concat(names, ", "))
    )
    return M.EXIT_USAGE
  end
  local names = pipeline.profiles[profile]
  local partial, partial_why = false, nil
  if args.steps then
    if #args.steps == 0 then
      err("testing ci: --step names no step")
      return M.EXIT_USAGE
    end
    local chosen, seen = {}, {}
    for _, s in ipairs(args.steps) do
      if not pipeline.steps[s] then
        local known = vim.tbl_keys(pipeline.steps)
        table.sort(known)
        err(("testing ci: unknown step %s (steps: %s)"):format(s, table.concat(known, ", ")))
        return M.EXIT_USAGE
      end
      if not seen[s] then
        seen[s] = true
        chosen[#chosen + 1] = s
      end
    end
    names, partial, partial_why = chosen, true, "--step"
  end

  -- options after `--` reach the suite step: a selection there (`--file`, `--filter`, `--shard`, ...) is part of the
  -- suite only, so the run is partial (the same rule as a stamp, which refuses them)
  local has_suite = false
  for _, n in ipairs(names) do
    has_suite = has_suite or pipeline.steps[n].inprocess == "run"
  end
  if #args.suite_args > 0 then
    if not has_suite then
      err("testing ci: options after -- go to the suite step, and no suite step is selected")
      return M.EXIT_USAGE
    end
    local run_args, bad =
      require("testing.args").parse(vim.list_extend({ "run", root }, args.suite_args))
    if not run_args then
      err("testing ci: the options after --: " .. tostring(bad))
      return M.EXIT_USAGE
    end
    local refused = require("testing.stamp.write").refuse(run_args)
    if refused then
      partial = true
      partial_why = partial_why and (partial_why .. ", suite options") or "suite options"
    end
  end
  local facts = git_facts(root)

  local planned, code, why = plan(pipeline, names, root)
  if not planned then
    for _, p in ipairs(why) do
      err("testing ci: " .. p)
    end
    return code --[[@as integer]]
  end

  local report = require("testing.ci.report")
  -- the agent report replaces the streamed output: verdict first, then only the findings
  local agent = args.agent
  if agent == nil then
    agent = require("testing.report.agent").choose(nil, sv.env) == "agent"
  end
  local function quiet() end
  local say = agent and quiet or out
  local step_sv = agent and vim.tbl_extend("force", sv, { out = quiet, err = quiet }) or sv

  local started = os.time()
  local results, first_red = {}, nil
  local stop = false
  for _, p in ipairs(planned) do
    local step = p.step
    ---@type Testing.Ci.StepResult
    local r
    if p.skip then
      r = { name = step.name, state = "skipped", ms = 0, errors = {}, reason = p.skip }
      say(("== %s (skipped: %s)"):format(step.name, p.skip))
    elseif stop then
      r = {
        name = step.name,
        state = "skipped",
        ms = 0,
        errors = {},
        reason = "an earlier step failed",
      }
    else
      say(
        ("== %s%s"):format(
          step.name,
          p.argv and #p.argv > 0 and not step.inprocess and (": " .. table.concat(p.argv, " "))
            or ""
        )
      )
      local t0 = vim.uv.hrtime()
      if step.inprocess then
        r = run_inprocess(p, root, args.suite_args, step_sv)
      else
        r = run_process(p, root, step_sv)
        -- ask the tool that ran (the found path), not a bare name: libuv cannot start a `.cmd` by name
        local version_argv = step.version_argv and vim.deepcopy(step.version_argv)
        if version_argv and p.argv and version_argv[1] == step.argv[1] then
          version_argv[1] = p.argv[1]
        end
        r.tool_version = tool_version(version_argv)
      end
      r.ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
      say(
        ("-- %s: %s (%s)%s"):format(
          step.name,
          r.state,
          seconds(r.ms),
          r.reason and (", " .. r.reason) or ""
        )
      )
      if r.state ~= "green" then
        first_red = first_red or step.name
        if not args.keep_going then
          stop = true
        end
      end
    end
    results[#results + 1] = r
  end

  local exit = exit_code(results)
  local verdict = exit == M.EXIT_OK and (partial and "green-partial" or "green")
    or exit == M.EXIT_FAILED and "red"
    or exit == M.EXIT_USAGE and "error"
    or "infra"
  -- a commit or checkout during the run: the document must not claim the new tree was tested
  local head_moved = facts.commit ~= nil and git_out(root, "rev-parse", "HEAD") ~= facts.commit
  if head_moved then
    err("testing ci: HEAD moved during the run; the result is about " .. facts.commit)
  end
  local steps_doc = {}
  for _, r in ipairs(results) do
    local findings = {}
    for _, f in ipairs(r.findings or {}) do
      findings[#findings + 1] =
        { file = f.file, line = f.line or vim.NIL, col = f.col or vim.NIL, text = f.text }
    end
    steps_doc[#steps_doc + 1] = {
      name = r.name,
      state = r.state,
      exit = r.exit == nil and vim.NIL or r.exit,
      ms = r.ms,
      tool_version = r.tool_version or vim.NIL,
      reason = r.reason or vim.NIL,
      errors = r.errors,
      findings = findings,
      findings_total = r.findings_total or 0,
    }
  end
  local doc = {
    schema = M.SCHEMA,
    repo = facts.repo,
    commit = facts.commit or vim.NIL,
    tree = facts.tree or vim.NIL,
    dirty = facts.dirty == nil and vim.NIL or facts.dirty,
    head_moved = head_moved,
    os = this_os(),
    profile = profile,
    partial = partial,
    partial_why = partial_why or vim.NIL,
    suite_args = args.suite_args,
    verdict = verdict,
    exit = exit,
    first_red = first_red or vim.NIL,
    nvim = tostring(vim.version()),
    pipeline_sha = vim.fn.sha256(require("lib.nvim.json.canonical").encode(pipeline.digest_input)),
    time = os.date("!%Y-%m-%dT%H:%M:%SZ", started),
    steps = steps_doc,
  }
  for _, note in ipairs(write_doc(doc, root, args.json, sv.state_dir)) do
    err("testing ci: " .. note)
  end
  if args.junit then
    local ok_w, werr = require("lib.nvim.fs.write.atomic")(
      vim.fn.fnamemodify(args.junit, ":p"),
      report.junit(doc),
      { mkdirp = true }
    )
    if not ok_w then
      err(("testing ci: cannot write %s: %s"):format(args.junit, tostring(werr)))
    end
  end

  for _, line in ipairs(agent and report.agent(doc) or report.term(doc, M.SENTINEL)) do
    out(line)
  end
  return exit
end

return M
