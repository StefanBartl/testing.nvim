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
--- (`suite`, `conformance`, `surface`, `budget`) run in this process through `testing.cli`; the suite counts as green
--- only when its Result-IR says so (an exit code 0 alone is no proof: `--help` exits 0 too).
---
--- Exit codes, the worst step wins: 0 every step green (or skipped for this system), 1 a step red, 2 a usage or
--- pipeline error (also a step that ended with 2), 3 infrastructure (a tool or dependency missing, a step that could
--- not start, a step that ended with 3, a report that could not be written). The document `testing-ci/1` is written to
--- the project's state directory after every run, also one that stopped before the first step (`ci.json` beside
--- `runs.jsonl`; a complete run also as `ci-<profile>.json`); `--step` is a partial selection and the document says so.
---
--- Every process this module starts itself (git facts, tool versions) is started together and waited for together:
--- on a machine whose endpoint protection inspects each start, one spawn costs a large part of a second.

local schema = require("testing.ci.schema")

local M = {}

M.EXIT_OK, M.EXIT_FAILED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci/1"

---The last line of a run that is green over a whole profile (a script may read it; a partial run never prints it).
M.SENTINEL = "TESTING_CI_OK"

M.USAGE = table.concat({
  "usage: testing ci [--profile=<name>] [--step=<a,b>] [--keep-going] [--reuse] [--agent|--no-agent] [--json=<file>]",
  "       testing ci verify [--profile=<name>] [--json] [--allow-dirty] [--max-age=<7d>] [--root=<dir>]",
  "       testing ci --repos=<a,b> | --repos-root=<dir> | --repos-file=<list> [--force] [--jobs=<n>] ...",
  "       testing ci list [--json] [--root=<dir>]",
  "       testing ci hook install|remove [--run=<profile>] [--verify=<profile>] [--root=<dir>]",
  "                  [--junit=<file>] [--state-dir=<dir>] [--root=<dir>] [-- <suite options>]",
  "  --profile=<name>  the profile to run (default: ci.default)",
  "  --step=<a,b>      only these steps (a partial run: no proof, no sentinel)",
  "  --keep-going      run every step even after a red one",
  "  --reuse           skip the suite when its stamp still verifies (a docs-only change reruns the other steps)",
  "  --agent           the agent report: the verdict first, then only the findings (default in an agent",
  "                    environment: TESTING_AGENT, CLAUDECODE, ...); --no-agent: the terminal report",
  "  --json=<file>     also write the testing-ci/1 document there",
  "  --junit=<file>    write a JUnit report there (one testsuite per step)",
  "  --state-dir=<dir> where the document (ci.json) and the suite's stamp go (default: stdpath('state'));",
  "                    a wrapper that isolates the suite's state passes the real one here",
  "  --root=<dir>      the project root (default: the current directory)",
  "  -- <options>      passed on to the suite step (testing run options, e.g. -- --jobs 4)",
}, "\n")

---@class Testing.Ci.Args
---@field profile? string
---@field steps? string[]
---@field keep_going boolean
---@field reuse boolean
---@field json? string
---@field junit? string
---@field state_dir? string
---@field agent? boolean nil: decided by the environment.
---@field root string
---@field suite_args string[]
---@field help boolean

local VALUED =
  { profile = true, step = true, json = true, junit = true, ["state-dir"] = true, root = true }

---@param argv string[] The arguments after `ci`.
---@return Testing.Ci.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Args
  local args = { keep_going = false, reuse = false, root = ".", suite_args = {}, help = false }
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
    elseif key == "reuse" and value == nil then
      args.reuse = true
    elseif (key == "agent" or key == "no-agent") and value == nil then
      args.agent = key == "agent"
    elseif key and VALUED[key] then
      if value == nil then
        i = i + 1
        value = argv[i]
        -- `--step --keep-going` is a missing value, not a step called "--keep-going"
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "step" then
        args.steps = vim.split(value, ",", { trimempty = true })
      elseif key == "state-dir" then
        args.state_dir = value
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

---@param s any
---@return string
local function clean(s)
  return require("testing.report.util").clean(tostring(s))
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

---Whether a path written relative to the root stays below it (`../x` does not).
---@param root string
---@param rel string
---@return boolean
local function below_root(root, rel)
  local full = vim.fs.normalize(root .. "/" .. rel)
  local base = vim.fs.normalize(root)
  local a, b = full, base .. "/"
  if require("testing.platform").is_windows() then
    a, b = a:lower(), b:lower()
  end
  return a:sub(1, #b) == b
end

---Characters cmd.exe interprets inside the arguments of a batch file (libuv does not quote for cmd.exe).
local CMD_META = '[&|<>%^%%!"]'

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
        local first_raw = step.argv[1]
        local argv = expand_all(name, step.argv)
        local first = argv[1]
        local script = first:match("%.sh$") and "bash" or first:match("%.ps1$") and "pwsh" or nil
        local relative = not is_absolute(first)
        if relative and first:find("[/\\]") and not below_root(root, first) then
          problems[#problems + 1] = ("step %s: %s lies outside the root (a file below it, an absolute path or ${deps.<name>})"):format(
            name,
            first_raw
          )
        end
        local file = not relative and first
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
        -- a batch file runs through cmd.exe, which reads `&`, `|`, `%`, ... in its arguments: no such argument
        if argv[1]:lower():match("%.bat$") or argv[1]:lower():match("%.cmd$") then
          for k = 2, #argv do
            if argv[k]:find(CMD_META) then
              problems[#problems + 1] = ("step %s: argument %q runs through cmd.exe (%s is a batch file) and contains a character cmd.exe interprets"):format(
                name,
                argv[k],
                vim.fs.basename(argv[1])
              )
            end
          end
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
---@field partial? boolean The suite's own verdict was `green-partial`.

local MAX_ERRORS = 20

---@param lines string[]
---@param line string
local function keep_error(lines, line)
  if #lines < MAX_ERRORS and line:match("%S") then
    lines[#lines + 1] = line
  end
end

---Start a process without waiting (several are started together and then collected).
---@param argv string[]
---@param cwd? string
---@return table|nil obj The `vim.SystemObj`, nil when it could not be started.
local function start(argv, cwd)
  local ok, obj = pcall(vim.system, argv, { cwd = cwd, text = true })
  return ok and obj or nil
end

---Collect a process from `start`: its trimmed stdout when it exited 0.
---@param obj table|nil
---@return string|nil
local function collect(obj)
  if not obj then
    return nil
  end
  local ok, res = pcall(obj.wait, obj, 10000)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout or "")
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

---@param path string
---@return integer|nil ns The modification time, nil when the file does not exist.
local function mtime_ns(path)
  local st = vim.uv.fs_stat(path)
  return st and (st.mtime.sec * 1e9 + (st.mtime.nsec or 0)) or nil
end

---The value of the last `--<name> x` / `--<name>=x` in `argv`, and whether the option is there at all.
---@param argv string[]
---@param name string
---@return string|nil value
---@return boolean present
local function last_option(argv, name)
  local value, present = nil, false
  for i, a in ipairs(argv) do
    if a == "--" then
      break
    end
    local v = a:match("^%-%-" .. name .. "=(.*)$")
    if v then
      value, present = v, true
    elseif a == "--" .. name then
      value, present = argv[i + 1], true
    end
  end
  return value, present
end

---@param planned Testing.Ci.Planned
---@param root string
---@param suite_args string[]
---@param sv table The services of the outer run (`out`, `err`, `env`, `script`).
---@param o { selects: boolean, stamp_out?: string } `selects`: the suite options select part of the suite (a run
---that cannot earn a stamp); `stamp_out`: where the stamp goes (`--state-dir`).
---@return Testing.Ci.StepResult
local function run_inprocess(planned, root, suite_args, sv, o)
  local step = planned.step
  local command = step.inprocess
  local is_suite = command == "run"
  -- a stamp needs a full run (`testing stamp` refuses a selection with exit 2): a selected run is a plain run
  if is_suite and step.stamp and not o.selects then
    command = "stamp"
  end
  local rest = vim.deepcopy(planned.argv or {})
  if is_suite then
    vim.list_extend(rest, suite_args)
  end
  -- our own options go right after the root: an argument `--` of the caller's later on cannot turn them into paths
  local ours = {}
  local ir_path, own_ir, ir_before = nil, false, nil
  if is_suite then
    -- the suite's findings and verdict come from its Result-IR: the caller's `--json` (the run takes the last
    -- one), or one of ours
    ir_path = last_option(rest, "json")
    if not ir_path then
      ir_path, own_ir = vim.fn.tempname() .. "-ci-ir.json", true
      vim.list_extend(ours, { "--json", ir_path })
    end
    -- the caller's path is read as the run writes it: relative to the current directory
    ir_path = vim.fn.fnamemodify(ir_path, ":p")
    -- a file left from an earlier run is not this run's result
    ir_before = mtime_ns(ir_path)
  end
  if command == "stamp" and o.stamp_out then
    local _, has_out = last_option(rest, "out")
    if not has_out then
      vim.list_extend(ours, { "--out", o.stamp_out })
    end
  end
  local argv = { command, root }
  vim.list_extend(argv, ours)
  vim.list_extend(argv, rest)

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
  -- the step's own environment, for the duration of the step: every outer value is saved before any is set
  -- The suite runs in a throwaway state and cache directory, whoever started `testing ci` (a terminal, the hook, the
  -- editor, CI): the same environment `scripts/test.sh` sets up, so a spec never writes into the user's real
  -- `stdpath("state")`. The step's own `env` wins.
  local env, scratch = planned.env, nil ---@type table<string, string>, string|nil
  if is_suite then
    scratch = vim.fn.tempname() .. "-ci-scratch"
    env = vim.tbl_extend("keep", planned.env, {
      XDG_STATE_HOME = scratch .. "/state",
      XDG_CACHE_HOME = scratch .. "/cache",
    })
  end
  local saved = {}
  for k in pairs(env) do
    saved[k] = vim.uv.os_getenv(k) or false
  end
  for k, v in pairs(env) do
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
  if scratch then
    vim.fn.delete(scratch, "rf")
  end
  for _, line in ipairs(last) do
    keep_error(errors, line)
  end
  ---@type Testing.Ci.StepResult
  local result = { name = step.name, ms = 0, errors = errors }
  local verdict
  if ir_path then
    local now = mtime_ns(ir_path)
    local fresh = now ~= nil and (ir_before == nil or now ~= ir_before)
    local f = fresh and io.open(ir_path, "rb") or nil
    if f then
      local okd, ir = pcall(vim.json.decode, f:read("*a"))
      f:close()
      if okd then
        result.findings, result.findings_total = require("testing.ci.report").ir_findings(ir)
        local v = type(ir) == "table" and type(ir.run) == "table" and ir.run.verdict
        verdict = type(v) == "table" and v.kind or nil
      end
    end
    if own_ir then
      os.remove(ir_path)
    end
  end
  if not ok then
    result.state, result.exit, result.reason = "infra", M.EXIT_INFRA, tostring(code)
    return result
  end
  result.exit = code
  if is_suite then
    -- the suite is green only when its own result says so: an exit code 0 without a result (`--help`,
    -- `--cache-clear`, a run that wrote nothing) proves nothing
    if code == 0 and (verdict == "green" or verdict == "green-partial") then
      result.state, result.partial = "green", verdict == "green-partial"
    elseif code == 0 then
      result.state, result.reason = "infra", "the suite wrote no result (Result-IR)"
    elseif code == 1 and command == "stamp" and verdict == "green-partial" then
      -- `testing stamp` exits 1 when it cannot write a stamp: a green-partial suite is partial, not red
      result.state, result.partial = "green", true
      result.reason = "no stamp: the suite is green-partial"
    elseif code == 1 then
      result.state = "red"
    else
      result.state = code == M.EXIT_USAGE and "error" or "infra"
    end
  else
    result.state = code == 0 and "green"
      or code == 1 and "red"
      or code == M.EXIT_USAGE and "error"
      or "infra"
  end
  return result
end

---@param results Testing.Ci.StepResult[]
---@return integer exit
---@return string|nil deciding The first step whose state decided the exit code.
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
  local want = ({ [M.EXIT_FAILED] = "red", [M.EXIT_USAGE] = "error", [M.EXIT_INFRA] = "infra" })[worst]
  for _, r in ipairs(results) do
    if r.state == want then
      return worst, r.name
    end
  end
  return worst, nil
end

---@class Testing.Ci.Facts
---@field repo string
---@field commit? string
---@field tree? string
---@field dirty? boolean
---@field status? string The porcelain status (compared at the end: a step that changed the tree).
---@field legacy_ignored boolean git ignores `.ci-last.json`.

---Commit, tree, dirty state and whether `.ci-last.json` is ignored, taken BEFORE the first step (the document is
---about what was tested), with the processes started together. Unknown values stay nil (no git, not a
---repository): never `dirty = false` for a commit nobody knows.
---@param root string
---@return Testing.Ci.Facts
local function git_facts(root)
  local revs = start({ "git", "rev-parse", "HEAD", "HEAD^{tree}" }, root)
  local status = start({ "git", "--no-optional-locks", "status", "--porcelain" }, root)
  local ignore = start({ "git", "check-ignore", "-q", ".ci-last.json" }, root)
  local facts = { repo = vim.fs.basename(root), legacy_ignored = false }
  local out = collect(revs)
  if out then
    local lines = vim.split(out, "\n", { trimempty = true })
    facts.commit, facts.tree = lines[1], lines[2]
  end
  local st = collect(status)
  if facts.commit and st ~= nil then
    facts.status, facts.dirty = st, st ~= ""
  end
  facts.legacy_ignored = collect(ignore) ~= nil
  return facts
end

---Start `--version` of every tool a plan will run (together; collect each with `collect`).
---@param planned Testing.Ci.Planned[]
---@return table<string, table> started By step name.
local function start_versions(planned)
  local versions = {}
  for _, p in ipairs(planned) do
    local step = p.step
    if not p.skip and not step.inprocess and step.version_argv then
      -- ask the tool that will run (the found path), not a bare name: libuv cannot start a `.cmd` by name
      local version_argv = vim.deepcopy(step.version_argv)
      if p.argv and version_argv[1] == step.argv[1] then
        version_argv[1] = p.argv[1]
      end
      versions[step.name] = start(version_argv)
    end
  end
  return versions
end

---After the steps: did HEAD move, did the tree change? (Started together.)
---@param root string
---@param facts Testing.Ci.Facts
---@return boolean head_moved
---@return boolean tree_changed
local function after_facts(root, facts)
  if not facts.commit then
    return false, false
  end
  local head = start({ "git", "rev-parse", "HEAD" }, root)
  local status = facts.status
    and start({ "git", "--no-optional-locks", "status", "--porcelain" }, root)
  local now = collect(head)
  local st = status and collect(status)
  return now ~= facts.commit, facts.status ~= nil and st ~= nil and st ~= facts.status
end

---Write the document (state directory, `--json`) and the transitional `.ci-last.json` where git ignores it.
---@param doc table
---@param root string
---@param json_path string|nil
---@param state_dir string|nil
---@param legacy_ignored boolean
---@return string[] notes One per write that failed (a failed write is exit 3).
local function write_doc(doc, root, json_path, state_dir, legacy_ignored)
  local canonical = require("lib.nvim.json.canonical")
  local atomic = require("lib.nvim.fs.write.atomic")
  local text = canonical.encode(doc) .. "\n"
  local notes = {}
  local dir = require("testing.state").dir(root, { state_dir = state_dir })
  -- (a run that stopped before its first step proves nothing and never replaces a profile's document)
  local complete = #doc.steps > 0
    and not doc.partial
    and not doc.head_moved
    and not doc.tree_changed
  -- `ci.json` is the last run; a complete run is also `ci-<profile>.json`, which a later `--step` or another
  -- profile never replaces (the proof `testing ci verify` reads)
  local paths = { dir .. "/ci.json" }
  if complete and type(doc.profile) == "string" then
    paths[#paths + 1] = dir .. "/ci-" .. doc.profile .. ".json"
  end
  for _, path in ipairs(paths) do
    local locked, note = require("testing.statelock").with(path, function()
      local ok, err = atomic(path, text, { mkdirp = true })
      if not ok then
        notes[#notes + 1] = ("cannot write %s: %s"):format(path, tostring(err))
      end
    end)
    if not locked then
      notes[#notes + 1] = note or ("cannot lock %s"):format(path)
    end
  end
  if json_path then
    local ok, err = atomic(vim.fn.fnamemodify(json_path, ":p"), text, { mkdirp = true })
    if not ok then
      notes[#notes + 1] = ("cannot write %s: %s"):format(json_path, tostring(err))
    end
  end
  -- transitional: the old `.ci-last.json` of `scripts/ci.sh`, only where git ignores it (never dirty the tree),
  -- and only for a complete run on the commit that was tested
  if complete and legacy_ignored then
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

---Helpers `testing.ci.verify` shares with a run (not an API).
M.internal = {
  plan = plan,
  git_facts = git_facts,
  start_versions = start_versions,
  collect = collect,
  this_os = this_os,
}

---`testing ci ...`.
---@param argv string[] The arguments after `ci`.
---@param sv table `out`, `err` (sinks), `env`, `script`; `state_dir` (specs).
---@return integer exit_code
function M.main(argv, sv)
  if argv[1] == "verify" then
    return require("testing.ci.verify").main(vim.list_slice(argv, 2), sv)
  end
  if require("testing.ci.repos").wanted(argv) then
    return require("testing.ci.repos").main(argv, sv)
  end
  if argv[1] == "list" then
    return require("testing.ci.list").main(vim.list_slice(argv, 2), sv)
  end
  if argv[1] == "hook" then
    return require("testing.ci.hook").main(vim.list_slice(argv, 2), sv)
  end
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
  local report = require("testing.ci.report")
  local agent = args.agent
  if agent == nil then
    agent = require("testing.report.agent").choose(nil, sv.env) == "agent"
  end
  local state_dir = args.state_dir and vim.fn.fnamemodify(args.state_dir, ":p") or sv.state_dir

  ---A run that stops before its first step still leaves its document (never yesterday's green one) and its
  ---reports; the problems go to stderr, the agent report's first line is the verdict.
  ---@param code integer
  ---@param problems string[]
  ---@param profile_name? string
  ---@param with_usage? boolean
  ---@return integer
  local function stop_early(code, problems, profile_name, with_usage)
    for _, p in ipairs(problems) do
      err("testing ci: " .. p)
    end
    if with_usage then
      err(M.USAGE)
    end
    local doc = {
      schema = M.SCHEMA,
      repo = vim.fs.basename(root),
      os = this_os(),
      profile = profile_name or vim.NIL,
      partial = false,
      verdict = code == M.EXIT_USAGE and "error" or "infra",
      exit = code,
      first_red = vim.NIL,
      problems = problems,
      time = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      steps = {},
    }
    for _, note in ipairs(write_doc(doc, root, args.json, state_dir, false)) do
      err("testing ci: " .. note)
    end
    if args.junit then
      pcall(
        require("lib.nvim.fs.write.atomic"),
        vim.fn.fnamemodify(args.junit, ":p"),
        report.junit(doc),
        {
          mkdirp = true,
        }
      )
    end
    if agent then
      for _, line in ipairs(report.agent(doc)) do
        out(line)
      end
    end
    return code
  end

  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    return stop_early(M.EXIT_USAGE, { loaded.error })
  end
  local raw = loaded.config.ci
  if raw == nil then
    -- a `ci` that is not a table was dropped by the loader with a warning: say that, not "no section"
    for _, p in ipairs(loaded.problems or {}) do
      if p:find("'ci'", 1, true) then
        return stop_early(M.EXIT_USAGE, { p })
      end
    end
    return stop_early(
      M.EXIT_USAGE,
      { ("%s/.testing.lua has no `ci` section (docs/CI.md)"):format(root) }
    )
  end
  local pipeline, problems = schema.resolve(raw)
  if not pipeline then
    return stop_early(M.EXIT_USAGE, problems)
  end

  local profile = args.profile or pipeline.default
  if not pipeline.profiles[profile] then
    local names = vim.tbl_keys(pipeline.profiles)
    table.sort(names)
    return stop_early(
      M.EXIT_USAGE,
      { ("unknown profile %s (profiles: %s)"):format(profile, table.concat(names, ", ")) }
    )
  end
  local names = pipeline.profiles[profile]
  local partial_why = {}
  if args.steps then
    if #args.steps == 0 then
      return stop_early(M.EXIT_USAGE, { "--step names no step" }, profile)
    end
    local chosen, seen = {}, {}
    for _, s in ipairs(args.steps) do
      if not pipeline.steps[s] then
        local known = vim.tbl_keys(pipeline.steps)
        table.sort(known)
        return stop_early(
          M.EXIT_USAGE,
          { ("unknown step %s (steps: %s)"):format(s, table.concat(known, ", ")) },
          profile
        )
      end
      if not seen[s] then
        seen[s] = true
        chosen[#chosen + 1] = s
      end
    end
    names = chosen
    partial_why[#partial_why + 1] = "--step"
  end

  local suite_selects = false
  -- options after `--` reach the suite step: a selection there (`--file`, `--filter`, `--shard`, ...) is part of the
  -- suite only, so the run is partial (the same rule as a stamp, which refuses them)
  local has_suite = false
  for _, n in ipairs(names) do
    has_suite = has_suite or pipeline.steps[n].inprocess == "run"
  end
  for _, a in ipairs(args.suite_args) do
    if schema.NO_RUN_OPTIONS[a] then
      return stop_early(M.EXIT_USAGE, {
        ("%s after -- runs no suite; call `testing %s` itself"):format(
          a,
          a == "-h" and "--help" or a
        ),
      }, profile)
    end
  end
  if #args.suite_args > 0 then
    if not has_suite then
      return stop_early(
        M.EXIT_USAGE,
        { "options after -- go to the suite step, and no suite step is selected" },
        profile
      )
    end
    local run_args, bad =
      require("testing.args").parse(vim.list_extend({ "run", root }, args.suite_args))
    if not run_args then
      return stop_early(M.EXIT_USAGE, { "the options after --: " .. tostring(bad) }, profile)
    end
    if require("testing.stamp.write").refuse(run_args) then
      suite_selects = true
      partial_why[#partial_why + 1] = "suite options"
    end
  end

  local planned, code, why = plan(pipeline, names, root)
  if not planned then
    return stop_early(code --[[@as integer]], why, profile)
  end

  -- every process of our own is started now and collected later: git facts and the tool versions
  local facts = git_facts(root)
  local versions = start_versions(planned)

  -- the agent report replaces the streamed output: verdict first, then only the findings
  local function quiet() end
  local say = agent and quiet or out
  local step_sv = agent and vim.tbl_extend("force", sv, { out = quiet, err = quiet }) or sv
  -- asked for now, before the suite step points the state directory at a scratch directory: the stamp must outlive it
  local stamp_out = require("testing.stamp").path(root, { state_dir = state_dir })

  local started = os.time()
  local results, first_red = {}, nil
  local stop, ran = false, 0
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
      ran = ran + 1
      say(
        ("== %s%s"):format(
          step.name,
          p.argv and #p.argv > 0 and not step.inprocess and (": " .. table.concat(p.argv, " "))
            or ""
        )
      )
      local t0 = vim.uv.hrtime()
      local reused = args.reuse
        and step.inprocess == "run"
        and step.stamp
        and not suite_selects
        and #args.suite_args == 0
        and require("testing.ci.verify").suite_status(
            root,
            state_dir,
            step_sv,
            { allow_dirty = true }
          )
          == "verified"
      if reused then
        r = {
          name = step.name,
          state = "green",
          exit = 0,
          errors = {},
          reason = "reused: its stamp verifies",
        }
      elseif step.inprocess then
        r = run_inprocess(
          p,
          root,
          args.suite_args,
          step_sv,
          { selects = suite_selects, stamp_out = stamp_out }
        )
        if r.partial and r.state == "green" and not suite_selects then
          partial_why[#partial_why + 1] = "suite green-partial"
        end
      else
        r = run_process(p, root, step_sv)
      end
      r.ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
      say(
        ("-- %s: %s (%s)%s"):format(
          step.name,
          r.state,
          seconds(r.ms),
          r.reason and (", " .. clean(r.reason)) or ""
        )
      )
      if r.state ~= "green" then
        first_red = first_red or step.name
        if not args.keep_going then
          stop = true
        end
      end
    end
    local v = versions[step.name]
    if v then
      local line = collect(v)
      r.tool_version = line and vim.trim(line:match("[^\r\n]+") or "") or nil
    end
    results[#results + 1] = r
  end
  if ran == 0 then
    partial_why[#partial_why + 1] = "no step ran on " .. this_os()
  end

  local exit, deciding = exit_code(results)
  -- a commit, a checkout or a step that changed files: the document must not claim the new tree was tested
  local head_moved, tree_changed = after_facts(root, facts)
  if head_moved then
    err("testing ci: HEAD moved during the run; the result is about " .. facts.commit)
  end
  if tree_changed then
    partial_why[#partial_why + 1] = "the tree changed during the run"
    err("testing ci: the working tree changed during the run (a step wrote files)")
  end
  local partial = #partial_why > 0
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
  local function verdict_of(x)
    return x == M.EXIT_OK and (partial and "green-partial" or "green")
      or x == M.EXIT_FAILED and "red"
      or x == M.EXIT_USAGE and "error"
      or "infra"
  end
  local doc = {
    schema = M.SCHEMA,
    repo = facts.repo,
    commit = facts.commit or vim.NIL,
    tree = facts.tree or vim.NIL,
    dirty = facts.dirty == nil and vim.NIL or facts.dirty,
    head_moved = head_moved,
    tree_changed = tree_changed,
    os = this_os(),
    profile = profile,
    partial = partial,
    partial_why = partial and table.concat(partial_why, ", ") or vim.NIL,
    suite_args = args.suite_args,
    verdict = verdict_of(exit),
    exit = exit,
    first_red = first_red or vim.NIL,
    deciding = deciding or vim.NIL,
    nvim = tostring(vim.version()),
    pipeline_sha = vim.fn.sha256(require("lib.nvim.json.canonical").encode(pipeline.digest_input)),
    time = os.date("!%Y-%m-%dT%H:%M:%SZ", started),
    steps = steps_doc,
  }

  -- the reports: a report that could not be written is exit 3 (as for a run), and the document says so
  local notes = {}
  if args.junit then
    local ok_w, werr = require("lib.nvim.fs.write.atomic")(
      vim.fn.fnamemodify(args.junit, ":p"),
      report.junit(doc),
      { mkdirp = true }
    )
    if not ok_w then
      notes[#notes + 1] = ("cannot write %s: %s"):format(args.junit, tostring(werr))
    end
  end
  vim.list_extend(notes, write_doc(doc, root, args.json, state_dir, facts.legacy_ignored))
  if #notes > 0 then
    doc.exit, doc.verdict, doc.write_errors = M.EXIT_INFRA, "infra", notes
    exit = M.EXIT_INFRA
    for _, note in ipairs(notes) do
      err("testing ci: " .. note)
    end
    -- best effort: the document on disk must not keep the green it had before the failure
    write_doc(doc, root, nil, state_dir, false)
  end

  for _, line in ipairs(agent and report.agent(doc) or report.term(doc, M.SENTINEL)) do
    out(line)
  end
  return exit
end

return M
