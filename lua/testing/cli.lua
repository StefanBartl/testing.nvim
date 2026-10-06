---@module 'testing.cli'
---@brief Command-line entry: `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|init|list|doctor] <root> [options]`.
---@description
--- Parses the arguments (`testing.args`), loads the project's `.testing.lua`
--- (`testing.config.project`), resolves its dependencies (`testing.deps`), and hands the run to
--- `testing.run.project`. Returns the process exit code (the caller, `scripts/testing.lua`, passes
--- it to `os.exit`):
---
---   0  every case passed (skips are reported and never green; `--strict` makes them red)
---   1  at least one case failed, errored or timed out
---   2  usage or configuration error (unknown option, no root, unusable `.testing.lua`, nothing to run)
---   3  infrastructure error (a dependency is missing, the IR cannot be written or validated, a
---      reporter failed, the editor was quit under the run, any internal error)
---
--- `testing migrate ...` is the migration tooling (`testing.migrate.main`), see docs/MIGRATING.md.
---
--- `main` never raises: everything that can raise runs under `xpcall`, and a raise is exit code 3
--- with a message on stderr (set `TESTING_DEBUG=1` for the traceback).
---
--- Honesty rule: an option that is parsed but not implemented is REFUSED with exit code 2 (see
--- `M.UNWIRED`, empty since M1 wired every option), never silently ignored; a run that dropped
--- `--filter` would be a green verdict about something else. Whoever adds an option that has no
--- behavior yet lists its canonical name there.
---
--- Everything after "arguments, config and dependencies are fine" lives in `testing.run.project`:
--- discovery, selection, the run, reporters, history, the sentinel.

local args_mod = require("testing.args")
local project = require("testing.run.project")

local M = {}

M.EXIT_OK = project.EXIT_OK
M.EXIT_FAILED = project.EXIT_FAILED
M.EXIT_USAGE = project.EXIT_USAGE
M.EXIT_INFRA = project.EXIT_INFRA

---Options (canonical names of `Testing.Args.given`) that parse and validate but have no behavior
---yet. Using one is exit code 2 with a message that says so. Empty: M1 wired them all.
---@type table<string, true>
M.UNWIRED = {}

---@class Testing.Cli.Services
--- Seams for specs; the defaults are the real process streams and modules.
---@field out? fun(s: string) stdout line sink
---@field err? fun(s: string) stderr line sink
---@field inproc? table `testing.run.inproc` (run, list, sanitize)
---@field discover? table `testing.discover` (discover, order)
---@field state_dir? string Replaces `stdpath('state')` for the history.
---@field color? boolean Forces the colour decision of the terminal reporter.

---Facts of one invocation after validation, before anything runs.
---@class Testing.Cli.RunPlan
---@field args Testing.Args
---@field root string Absolute, normalized, no trailing slash.
---@field project Testing.ProjectConfig
---@field rtp_dirs string[] Absolute `--rtp` directories.
---@field argv string[] The effective arguments (stored in the IR header).

---Parse; kept as a delegate for callers of the M0 API.
---@param argv string[]
---@return Testing.Args|nil
---@return string|nil problem
function M.parse(argv)
  return args_mod.parse(argv)
end

---The arguments as a plain list (`arg` also carries the interpreter at index <= 0).
---@param argv string[]
---@return string[]
local function clean_argv(argv)
  local list = {}
  for i = 1, #argv do
    list[i] = tostring(argv[i])
  end
  return list
end

---@param path string
---@return string
local function abs(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

---Print the effective configuration and the dependency report (`testing doctor`).
---@param plan Testing.Cli.RunPlan
---@param loaded Testing.ProjectConfig.Loaded
---@param say fun(s: string)
---@return integer exit_code 0, or 3 when a dependency the run needs is missing
local function doctor(plan, loaded, say)
  local deps = require("testing.deps")
  say("testing doctor")
  say("root:    " .. plan.root)
  say("running: " .. deps.self_dir())
  say("config:  " .. (loaded.path or "none (.testing.lua not found, defaults)"))
  for _, p in ipairs(loaded.problems) do
    say("  warning: " .. p)
  end
  say("resolved configuration:")
  for line in vim.inspect(plan.project):gmatch("[^\n]+") do
    say("  " .. line)
  end

  local run_opts = require("testing.run.options").of(plan)
  say(
    ("child editors: isolated=%s jobs=%d host=%s filetype=%s disable_first_run=%s env_allow=%s"):format(
      run_opts.isolated,
      run_opts.jobs,
      run_opts.host,
      tostring(run_opts.filetype),
      tostring(run_opts.disable_first_run),
      #run_opts.env_allow > 0 and table.concat(run_opts.env_allow, ",") or "-"
    )
  )

  local guard_modes = {}
  for _, name in ipairs(require("testing.run.options").GUARD_NAMES) do
    guard_modes[#guard_modes + 1] = ("%s=%s"):format(name, tostring(run_opts.guards[name]))
  end
  say(("guards: %s"):format(table.concat(guard_modes, " ")))
  say(
    ("guard_allow: fs=%d spawn=%d network=%d; pool: size=%d reuse=%s; determinism=%s trace=%s; soft_keep=%s"):format(
      #run_opts.guard_allow.fs,
      #run_opts.guard_allow.spawn,
      #run_opts.guard_allow.network,
      run_opts.pool.size,
      tostring(run_opts.pool.reuse),
      tostring(run_opts.determinism),
      tostring(run_opts.trace),
      #run_opts.soft_keep > 0 and table.concat(run_opts.soft_keep, ",") or "-"
    )
  )

  say("dependencies:")
  local code = M.EXIT_OK
  ---@param row table
  local function show(row, required)
    if row.ok then
      say(("  ok       %s -> %s (%s)"):format(row.name, row.dir, row.source))
    else
      say(("  %s %s"):format(required and "MISSING " or "absent  ", row.name))
      for line in row.message:gmatch("[^\n]+") do
        say("      " .. line)
      end
      if required then
        code = M.EXIT_INFRA
      end
    end
  end
  show(deps.report({ "lib.nvim" }, deps.self_dir())[1], true)
  -- testing.nvim as seen from the project: only informative, the running copy is the one that counts.
  show(deps.report({ "testing.nvim" }, plan.root)[1], false)
  for _, row in ipairs(deps.report(plan.project.deps, plan.root)) do
    show(row, true)
  end
  return code
end

---`testing migrate [dry-run|apply] [<path>] [--json] [--markdown] [--check] [--fleet-root=<dir>]`: the
---migration tooling (`testing.migrate`) has its own arguments and exit codes (0 done or nothing to do,
---1 `--check` found work, 2 refused or bad usage, 3 the root cannot be analysed), so it is dispatched
---before the run options are parsed.
---@param rest string[] The arguments after `migrate`.
---@param sv Testing.Run.Services
---@return integer exit_code
local function run_migrate(rest, sv)
  local code, text = require("testing.migrate").main(rest, { cwd = vim.fn.getcwd() })
  text = tostring(text or "")
  -- the sinks add the newline themselves; usage and refusals belong on stderr
  local sink = code == 2 and sv.err or sv.out
  sink((text:gsub("\n+$", "")))
  return code
end

---Everything after argument parsing. May raise; `M.main` turns that into exit code 3.
---@param argv string[]
---@param sv Testing.Run.Services
---@return integer exit_code
local function execute(argv, sv)
  local out, err = sv.out, sv.err
  local usage = args_mod.usage()

  if argv[1] == "migrate" then
    return run_migrate(vim.list_slice(argv, 2), sv)
  end

  local args, problem = args_mod.parse(argv)
  if not args then
    err("testing: " .. tostring(problem))
    err(usage)
    return M.EXIT_USAGE
  end
  if args.help then
    out(usage)
    return M.EXIT_OK
  end

  for name in pairs(args.given) do
    if M.UNWIRED[name] then
      err(("testing: option --%s is not implemented yet"):format((name:gsub("_", "-"))))
      return M.EXIT_USAGE
    end
  end
  if args.command == "init" then
    err("testing: `init` is not implemented yet")
    return M.EXIT_USAGE
  end
  if not args.root then
    err("testing: no <root> given")
    err(usage)
    return M.EXIT_USAGE
  end

  local root = abs(args.root):gsub("/+$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    err(("testing: root is not a directory: %s"):format(root))
    return M.EXIT_USAGE
  end

  -- Paths are resolved against the caller's cwd (the specs run in the cwd the caller chose).
  local rtp_dirs = {}
  for _, dir in ipairs(args.rtp) do
    local dir_abs = abs(dir)
    if vim.fn.isdirectory(dir_abs) ~= 1 then
      err(("testing: --rtp is not a directory: %s"):format(dir))
      return M.EXIT_USAGE
    end
    rtp_dirs[#rtp_dirs + 1] = dir_abs
  end

  local loaded = require("testing.config.project").load(root, { file = args.config })
  if loaded.error then
    err("testing: " .. loaded.error)
    return M.EXIT_USAGE
  end
  for _, p in ipairs(loaded.problems) do
    err("testing: config: " .. p)
  end
  ---@type Testing.Cli.RunPlan
  local plan = {
    args = args,
    root = root,
    project = loaded.config,
    rtp_dirs = rtp_dirs,
    argv = clean_argv(argv),
  }

  if args.command == "doctor" then
    return doctor(plan, loaded, out)
  end

  -- Dependencies of the project: every one resolved, ALL failures reported at once.
  local deps = require("testing.deps")
  local resolved, failures = deps.resolve_all(plan.project.deps, root)
  if #failures > 0 then
    err(table.concat(failures, "\n"))
    return M.EXIT_INFRA
  end
  for _, r in ipairs(resolved) do
    deps.add_to_rtp(r.dir, false)
  end

  -- Specs are cwd-dependent (lib.nvim's git specs look at "this repo"), and the old runner is
  -- documented as "run from the repo root". There is deliberately NO chdir here: on Windows
  -- libuv's chdir exports the `=E:` per-drive variable into the environment, which a spec that
  -- audits the environment (spawn_env_spec) then fails on. Say so instead of changing the verdict.
  local here = vim.fs.normalize(vim.fn.getcwd()):gsub("/+$", "")
  if here:lower() ~= root:lower() then
    err(
      ("testing: note: cwd is %s, not the root; specs that look at the repo expect cwd = root"):format(
        here
      )
    )
  end
  deps.add_to_rtp(root, false)
  for _, dir in ipairs(rtp_dirs) do
    deps.add_to_rtp(dir, false)
  end

  return project.execute(plan, sv)
end

---Run the CLI. Never raises: an internal error becomes exit code 3 with a message on stderr.
---@param argv string[] The arguments after the script (`_G.arg`).
---@param services? Testing.Cli.Services
---@return integer exit_code
function M.main(argv, services)
  ---@type Testing.Run.Services
  local sv = vim.tbl_extend("force", {
    out = function(s)
      io.stdout:write(s, "\n")
    end,
    err = function(s)
      io.stderr:write(s, "\n")
    end,
  }, services or {})

  -- a run adds the project, its dependencies and `--rtp` to the runtimepath; an editor that hosts the
  -- run (a spec of this project calls `main`) is left as it was found
  local rtp_before = vim.o.rtp
  local ok, code = xpcall(execute, function(e)
    if vim.env.TESTING_DEBUG and vim.env.TESTING_DEBUG ~= "" then
      return debug.traceback(tostring(e), 2)
    end
    return tostring(e)
  end, clean_argv(argv or {}), sv)
  if vim.o.rtp ~= rtp_before then
    pcall(function()
      vim.o.rtp = rtp_before
    end)
  end
  if not ok then
    pcall(sv.err, "testing: internal error: " .. tostring(code))
    return M.EXIT_INFRA
  end
  if type(code) ~= "number" then
    pcall(sv.err, "testing: internal error: no exit code was produced")
    return M.EXIT_INFRA
  end
  return code
end

return M
