---@module 'testing.cli'
-- @cache-env TESTING_DEBUG TESTING_STAMP_SECRET
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

---Names that `testing.args` ACCEPTS so that the parser does not reject them, but that nothing dispatches
---yet. Using one is exit code 2 with a message that says so: never silently ignored. Empty since the
---integration step wired the cache and affected options and the `conformance` and `surface` commands.
---@type { options: table<string, string>, commands: table<string, true> }
M.RESERVED = { options = {}, commands = {} }

---Subcommands that have their own arguments and exit codes: they are handed to their module before the
---run options are parsed (like `migrate`).
---@type table<string, true>
M.OWN_ARGS = { migrate = true, conformance = true, surface = true }

---@class Testing.Cli.Services
--- Seams for specs; the defaults are the real process streams and modules.
---@field out? fun(s: string) stdout line sink
---@field err? fun(s: string) stderr line sink
---@field inproc? table `testing.run.inproc` (run, list, sanitize)
---@field discover? table `testing.discover` (discover, order)
---@field state_dir? string Replaces `stdpath('state')` for the history.
---@field color? boolean Forces the colour decision of the terminal reporter.
---@field env? table<string, string|nil> Environment that chooses the reporter (`TESTING_REPORTER`, `TESTING_AGENT`, `AI_AGENT`, `CLAUDECODE`); only `scripts/testing.lua` sets it.
---@field script? string Path of the entry script (the `rerun:` line of the agent reporter).
---@field budget? table Replaces single seams of `testing budget` (`testing.budget.main`): `run`, `machine`.
---@field cache_dir? string Replaces `stdpath('cache')` for the result cache (specs).
---@field cache? table Replaces `testing.cache` (specs).
---@field affected? table Replaces single seams of the affected selection: `affected`, `getenv`, `run`, `provider` (specs).
---@field watch? table Replaces single seams of the `--watch` loop (`testing.run.watch.run_cli`): `wait`, `run`, `source`, `scan`, `clock`, ...

---Facts of one invocation after validation, before anything runs.
---@class Testing.Cli.RunPlan
---@field args Testing.Args
---@field root string Absolute, normalized, no trailing slash.
---@field project Testing.ProjectConfig
---@field rtp_dirs string[] Absolute `--rtp` directories.
---@field argv string[] The effective arguments (stored in the IR header).
---@field stamp? table The own flags of `testing stamp` (`--out`, `--note`): the run writes a stamp after a complete green verdict.

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

---@type fun(plan: Testing.Cli.RunPlan, sv: Testing.Run.Services): integer|nil
local apply_shard
---@type fun(plan: Testing.Cli.RunPlan, sv: Testing.Run.Services): integer
local run_measured

---Cores minus one, at least 1: what `--jobs auto` and `jobs = "auto"` mean.
---@param cpus? integer Number of cores (default: what libuv reports).
---@return integer
function M.auto_jobs(cpus)
  cpus = cpus or #(vim.uv.cpu_info() or {})
  return math.max(1, cpus - 1)
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

  say(
    ("shard: balance=%s durations=%s; watch: debounce=%d ms poll=%d ms; budget: factor=%g baseline=%s"):format(
      plan.project.shard.balance,
      plan.project.shard.durations or "-",
      plan.project.watch.debounce_ms,
      plan.project.watch.poll_ms,
      plan.project.budget.factor,
      plan.project.budget.baseline
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

---`testing conformance ...` and `testing surface ...`: the suite and the surface report have their own
---arguments (`--gate`, `--from`, ...) and exit codes. `conformance` prints through the sinks and returns the
---code; `surface` returns the code and the text (stderr for a usage error).
---@param command "conformance"|"surface"
---@param rest string[]
---@param sv Testing.Run.Services
---@return integer exit_code
local function run_own(command, rest, sv)
  local cwd = vim.fn.getcwd()
  if command == "conformance" then
    return require("testing.conformance").main(rest, { out = sv.out, err = sv.err, cwd = cwd })
  end
  local code, text = require("testing.surface").main(rest, { cwd = cwd })
  text = (tostring(text or ""):gsub("\n+$", ""))
  if text ~= "" then
    ((code == 2 or code == 3) and sv.err or sv.out)(text)
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

---@param rel string
---@param p string A path the user typed (relative to the root, or absolute inside it).
---@param root string
---@return boolean
local function under_path(rel, p, root)
  p = p:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
  local r = root:gsub("/+$", "")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    p = p:sub(#r + 2)
  end
  return rel == p or rel:sub(1, #p + 1) == p .. "/"
end

---`--shard i/n`: partition the discovered files (`testing.run.shard`) and hand this shard's files to the
---run as its path arguments, so `--list`, `--lf`, the partial-run sentinel and the history all treat a
---shard like any other selection. A path argument of the user narrows the shard further.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@return integer|nil exit_code Set when there is nothing to run for this shard.
apply_shard = function(plan, sv)
  local args, root, cfg = plan.args, plan.root, plan.project
  local shard = require("testing.run.shard")
  local discover = sv.discover or require("testing.discover")
  local disc = discover.discover(
    root,
    { roots = cfg.roots, dialect = cfg.dialect, spec_pattern = cfg.spec_pattern }
  )
  local ordered = discover.order(disc)
  local rels = {}
  for _, f in ipairs(ordered) do
    rels[#rels + 1] = f.rel
  end
  local weights, notes = shard.weights(root, rels, {
    balance = cfg.shard.balance,
    durations_file = cfg.shard.durations and (root .. "/" .. cfg.shard.durations) or nil,
    state_dir = sv.state_dir,
  })
  for _, note in ipairs(notes) do
    sv.err("testing: note: " .. note)
  end
  local mine, info = shard.apply(ordered, args.shard --[[@as table]], {
    balance = cfg.shard.balance,
    weights = weights,
  })
  sv.err(
    ("testing: note: shard %d/%d: %d of %d spec file(s) (balance %s)"):format(
      info.index,
      info.count,
      info.selected,
      info.total,
      info.balance
    )
  )
  local paths = {}
  for _, f in ipairs(mine) do
    local keep = #args.paths == 0
    for _, p in ipairs(args.paths) do
      keep = keep or under_path(f.rel, p, root)
    end
    if keep then
      paths[#paths + 1] = f.rel
    end
  end
  if #paths == 0 then
    sv.err(
      ("testing: note: shard %d/%d has no spec file (%d shard(s), %d file(s)); nothing to run"):format(
        info.index,
        info.count,
        info.count,
        info.total
      )
    )
    return M.EXIT_OK
  end
  args.paths = paths
  return nil
end

---A service table whose `inproc`, `isolated` and `discover` keep behaving as they were but report to
---`hook`: the run report (after the driver, before the reporters), and the time discovery took.
---@param sv Testing.Run.Services
---@param hook { on_report: fun(report: table), on_discovery: fun(ms: number) }
---@return Testing.Run.Services
local function observing(sv, hook)
  local out = vim.tbl_extend("force", {}, sv)
  ---@param real table
  ---@return table
  local function proxy_run(real)
    return setmetatable({
      run = function(...)
        local report = real.run(...)
        hook.on_report(report)
        return report
      end,
    }, { __index = real })
  end
  out.inproc = proxy_run(sv.inproc or require("testing.run.inproc"))
  out.isolated = proxy_run(sv.isolated or require("testing.run.isolated"))
  local real_discover = sv.discover or require("testing.discover")
  out.discover = setmetatable({
    discover = function(...)
      local t0 = vim.uv.hrtime()
      local disc = real_discover.discover(...)
      hook.on_discovery((vim.uv.hrtime() - t0) / 1e6)
      return disc
    end,
  }, { __index = real_discover })
  return out
end

---Can the durations of this run be remembered for `--shard`? Only a COMPLETE run of every selected file
---gives the true duration of a file: a case filter or a `--maxfail` stop leaves it short.
---@param args Testing.Args
---@param report table
---@return boolean
local function complete_enough(args, report)
  return #args.filter == 0
    and #args.tags == 0
    and #args.exclude_tags == 0
    and not args.lf
    and not report.stopped
end

---Run the project, with `--profile` measuring it and the durations of the files remembered for `--shard`.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@return integer exit_code
run_measured = function(plan, sv)
  local args = plan.args
  local profile_mod = args.profile and require("testing.run.profile") or nil
  local prof = profile_mod and profile_mod.new() or nil
  local last
  local discovery_ms
  local run_started
  local built

  local observed = observing(sv, {
    on_report = function(report)
      last = report
      if profile_mod then
        local run_ms = (vim.uv.hrtime() / 1e6) - (run_started or (vim.uv.hrtime() / 1e6))
        built = profile_mod.build(report.result, {
          phases = { discovery = discovery_ms, run = run_ms },
          jobs = report.result.run.jobs,
          file_timings = report.file_timings,
          pool = report.pool,
          run_ms = run_ms,
        })
        profile_mod.attach(report.result, built)
      end
    end,
    on_discovery = function(ms)
      discovery_ms = ms
      run_started = vim.uv.hrtime() / 1e6
    end,
  })
  if prof then
    prof:begin("total")
  end
  local code = project.execute(plan, observed)
  if prof and profile_mod then
    prof:finish("total")
    if built then
      built.phases.total = math.floor((prof:ms("total") or 0) * 1000 + 0.5) / 1000
      local rest = built.phases.total - (built.phases.discovery or 0) - (built.phases.run or 0)
      built.phases.report = math.max(0, math.floor(rest * 1000 + 0.5) / 1000)
      for _, line in ipairs(profile_mod.lines(built)) do
        -- case ids and file names come from the project: nothing in them may become a control sequence or a
        -- workflow command of the CI log
        sv.err(project.safe_line(line))
      end
    else
      sv.err("testing: note: --profile: no run happened, nothing to profile")
    end
  end
  if last and (code == M.EXIT_OK or code == M.EXIT_FAILED) and complete_enough(args, last) then
    local shard = require("testing.run.shard")
    local ok, err =
      pcall(shard.record_durations, plan.root, last.result, nil, { state_dir = sv.state_dir })
    if not ok then
      sv.err("testing: note: durations not updated: " .. tostring(err))
    end
    -- a file that took three times its median is a warning (the machine may be busy), never a failure
    local timings = require("testing.run.timings")
    local topts = { state_dir = sv.state_dir }
    local history, tnote = timings.read(timings.path(plan.root, topts))
    if tnote then
      sv.err("testing: note: " .. tnote)
    end
    local current = timings.per_file(last.result)
    last.time_regressions = timings.regressions(history, current)
    for _, r in ipairs(last.time_regressions) do
      sv.err(project.safe_line("testing: warning: slower than usual: " .. timings.line(r)))
    end
    local tok, wrote, werr = pcall(timings.record, plan.root, history, current, topts)
    if not tok or wrote == false then
      sv.err("testing: note: timings not updated: " .. tostring(tok and werr or wrote))
    end
  end
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
  if argv[1] == "conformance" or argv[1] == "surface" then
    return run_own(argv[1], vim.list_slice(argv, 2), sv)
  end
  -- `testing explain`: its own flags (--all, --json, --parts) are taken out, the rest is a run's arguments
  local explain_own
  if argv[1] == "explain" then
    argv, explain_own = require("testing.explain").split_argv(argv)
  end
  -- `testing verify` and `testing stamp`: their own flags (--stamp, --out, --json, ...) are taken out as well
  local stamp_own
  if argv[1] == "verify" or argv[1] == "stamp" then
    local bad
    argv, stamp_own, bad = require("testing.stamp.cli").split_argv(argv)
    if bad then
      err("testing: " .. bad)
      return M.EXIT_USAGE
    end
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
    if M.RESERVED.options[name] then
      err(
        ("testing: option %s is reserved (M5-A: cache and affected selection); the integration step dispatches it, it is not wired yet"):format(
          M.RESERVED.options[name]
        )
      )
      return M.EXIT_USAGE
    end
  end
  if M.RESERVED.commands[args.command] then
    err(
      ("testing: `%s` is reserved (M4); the integration step dispatches it, it is not wired yet"):format(
        args.command
      )
    )
    return M.EXIT_USAGE
  end
  if args.command == "init" then
    err("testing: `init` is not implemented yet")
    return M.EXIT_USAGE
  end
  if stamp_own and stamp_own.command == "stamp" then
    local write = require("testing.stamp.write")
    local refused = write.refuse(args)
    if refused then
      err("testing: " .. refused)
      return M.EXIT_USAGE
    end
    local _, secret_problem = write.secret(
      (sv --[[@as table]]).stamp and (sv --[[@as table]]).stamp.getenv or vim.uv.os_getenv
    )
    if secret_problem then
      err("testing: stamp: " .. secret_problem)
      return M.EXIT_USAGE
    end
  end
  if
    (args.command == "budget" or args.command == "explain" or args.command == "verify")
    and not args.root
  then
    args.root = "."
  end
  if args.command == "explain" and args.root ~= "." and vim.fn.isdirectory(abs(args.root)) ~= 1 then
    -- `testing explain TESTS/a_spec.lua`: no root, a spec
    table.insert(args.paths, 1, args.root)
    args.root = "."
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
  -- `jobs = "auto"` / `--jobs auto`: cores minus one. Everything below sees an integer.
  if loaded.config.jobs == "auto" then
    loaded.config.jobs = M.auto_jobs()
  end
  if args.jobs_auto then
    args.jobs = M.auto_jobs()
  end
  ---@type Testing.Cli.RunPlan
  local plan = {
    args = args,
    root = root,
    project = loaded.config,
    rtp_dirs = rtp_dirs,
    argv = clean_argv(argv),
  }

  -- where the result cache lives: `--cache-dir`, else `TESTING_CACHE_HOME` (read by the entry script and handed
  -- down in `env`), else `stdpath('cache')`; and the folder name, `cache.project_key` or the checkout path
  if args.cache_dir then
    sv.cache_dir = abs(args.cache_dir)
  elseif not sv.cache_dir then
    local home = sv.env and sv.env.TESTING_CACHE_HOME
    if home and home ~= "" then
      sv.cache_dir = abs(home)
    end
  end
  require("testing.cache.store").project_key = plan.project.cache and plan.project.cache.project_key
    or nil
  -- the runner itself stores into the directory it was told to use, also while a spec of an in-process
  -- window is running next to it (jobs > 1): the fs guard must not count that as a write of the spec
  if sv.cache_dir then
    args.allow_fs = vim.list_extend(vim.deepcopy(args.allow_fs or {}), { sv.cache_dir })
  end

  if args.cache_clear then
    local cache = require("testing.cache")
    local dir = cache.stats({ root = root, cache_dir = sv.cache_dir }).dir
    local n = cache.clear({ root = root, cache_dir = sv.cache_dir })
    -- a start from nothing also forgets which keys gave different results (`testing.cache.keylog`)
    pcall(require("testing.cache.keylog").clear, root, { state_dir = sv.state_dir })
    out(("cache cleared: %d entr%s removed (%s)"):format(n, n == 1 and "y" or "ies", dir))
    return M.EXIT_OK
  end
  if args.command == "doctor" then
    return doctor(plan, loaded, out)
  end
  if args.command == "budget" then
    return require("testing.budget").main(plan, sv, (sv --[[@as table]]).budget)
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

  if args.command == "explain" then
    return require("testing.explain").main(plan, sv, explain_own)
  end
  if args.command == "verify" then
    return require("testing.stamp.verify").main(plan, sv, stamp_own)
  end
  if stamp_own and stamp_own.command == "stamp" then
    plan.stamp = stamp_own
  end
  if args.watch then
    return require("testing.run.watch").run_cli(plan, sv, (sv --[[@as table]]).watch)
  end
  if args.shard then
    local code = apply_shard(plan, sv)
    if code ~= nil then
      return code
    end
  end
  return run_measured(plan, sv)
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
