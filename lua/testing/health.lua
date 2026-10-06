---@module 'testing.health'
---@brief `:checkhealth testing` diagnostics.
---@description
--- Read-only and fast: reports the Neovim version, the lib.nvim modules the plugin calls (and two
--- behaviors it relies on, probed without writing anything), the kernel, the dialect and reporter
--- registries, the dependency resolution of the command-line runner and the project's
--- `.testing.lua`. Nothing is created or changed, no lazy-loaded plugin is loaded to probe it, and
--- no subprocess is started.
---
--- `.testing.lua` is a Lua file and loading it executes it. A health check must not execute the
--- file of whatever directory the editor happens to be in, so it is evaluated here in an EMPTY
--- environment with an instruction budget (no `vim`, no `io`, no `os`, no `require`): a file that
--- is a plain table passes through the real validator; a file that needs more than that is reported
--- as "not checked here" (info, never a false green), and `testing doctor` evaluates it for real.
---
--- A level never contradicts its text: `error` only for something that is broken, `warn` for what
--- will fail later in another entry (the command-line runner), `info` for what is merely not
--- checked or not applicable.

local M = {}

---Modules of lib.nvim the plugin calls, with the reason (shown on a failure).
---@type { [1]: string, [2]: string }[]
local REQUIRED_LIB = {
  { "lib.nvim.health", "health helpers" },
  { "lib.nvim.notify", "messages" },
  { "lib.nvim.bindings.usercmd.composer", "the :Testing command" },
  { "lib.nvim.bindings.keymap", "named keymap actions" },
  { "lib.nvim.json", "deterministic JSON for the Result-IR" },
  { "lib.lua.error", "safe_call around spec bodies" },
  { "lib.lua.diff", "line diff of the terminal reporter" },
  { "lib.lua.strings.width", "display width of the terminal reporter" },
  { "lib.nvim.fs.read", "reading specs and the config" },
  { "lib.nvim.fs.relpath", "project-relative spec paths" },
  { "lib.nvim.fs.is_subpath", "containment check of the config file" },
  { "lib.nvim.fs.collect_recursive", "spec discovery" },
  { "lib.nvim.fs.project_key", "stable project key of a run" },
  { "lib.nvim.fs.write.atomic", "atomic write of the JSON IR and the reports" },
  { "lib.nvim.system.job", "process execution (runner)" },
}

---Kernel modules the CLI and the in-process driver need; a failure here is a defect of the plugin
---itself, not of the environment.
---@type string[]
local KERNEL = {
  "testing.core.result",
  "testing.core.assert",
  "testing.deps",
  "testing.args",
  "testing.config.project",
  "testing.discover",
  "testing.dialect",
  "testing.report",
  "testing.run.inproc",
  "testing.cli",
}

---Directory whose `.testing.lua` is checked: the working directory of the editor. A function so that
---specs can point it at a fixture without changing the real working directory.
---@return string
function M.project_dir()
  return (vim.uv or vim.loop).cwd() or "."
end

---Instruction budget of the sandboxed `.testing.lua` evaluation.
local EVAL_BUDGET = 200000

local LIB_HINT =
  "testing.nvim needs lib.nvim >= 6304829 (fs.write.atomic) and >= 89cb912 (safe_call keeps non-string errors)"

---@param health table `vim.health`
---@return boolean lib_ok Every required module loaded.
local function check_lib(health)
  health.start("testing.nvim: lib.nvim")
  local all_ok = true
  for _, req in ipairs(REQUIRED_LIB) do
    if pcall(require, req[1]) then
      health.ok(("%s -- %s"):format(req[1], req[2]))
    else
      all_ok = false
      health.error(("%s missing -- %s"):format(req[1], req[2]), {
        'Install or update "StefanBartl/lib.nvim" and list it as a dependency',
        LIB_HINT,
      })
    end
  end
  if not all_ok then
    return false
  end

  -- Behavior the runner relies on, probed without side effects.
  local err_mod = require("lib.lua.error")
  local ran, caught = err_mod.safe_call(function()
    error({ code = 7 })
  end)
  if
    ran == false
    and type(caught) == "table"
    and type(caught.data) == "table"
    and caught.data.code == 7
  then
    health.ok("lib.lua.error.safe_call keeps non-string errors (commit 89cb912 or newer)")
  else
    health.error("lib.lua.error.safe_call loses non-string errors", {
      "A spec that raises a table would be reported without its payload, or crash the run",
      LIB_HINT,
    })
  end

  local atomic = require("lib.nvim.fs.write.atomic")
  if type(atomic) ~= "function" then
    health.error("lib.nvim.fs.write.atomic is not a function (" .. type(atomic) .. ")", {
      LIB_HINT,
    })
  else
    -- An invalid call must refuse without touching the disk; a writer that accepts it is not the
    -- one this plugin was written against.
    local wrote = atomic("", "x")
    if wrote == false then
      health.ok("lib.nvim.fs.write.atomic refuses an invalid call (commit 6304829 or newer)")
    else
      health.error("lib.nvim.fs.write.atomic accepted an empty path", { LIB_HINT })
    end
  end
  return true
end

---@param health table
local function check_kernel(health)
  health.start("testing.nvim: kernel")
  for _, name in ipairs(KERNEL) do
    local ok, err = pcall(require, name)
    if ok then
      health.ok(name)
    else
      health.error(("%s failed to load: %s"):format(name, tostring(err)), {
        "This is a defect of testing.nvim; report it with this message",
      })
    end
  end
  local ir_ok, result = pcall(require, "testing.core.result")
  if ir_ok and type(result.SCHEMA_VERSION) == "number" then
    health.info(("Result-IR schema_version %d"):format(result.SCHEMA_VERSION))
  end
  -- The CLI entry is a file on the runtimepath, not a module: probe it without loading anything.
  if #vim.api.nvim_get_runtime_file("scripts/testing.lua", false) > 0 then
    health.ok("scripts/testing.lua (command-line entry) is on the runtimepath")
  else
    health.info("scripts/testing.lua is not on the runtimepath; run it by path instead")
  end
end

---@param health table
local function check_registries(health)
  health.start("testing.nvim: dialects and reporters")
  local dok, dialect = pcall(require, "testing.dialect")
  if dok then
    local loaded, broken = {}, {}
    for _, name in ipairs(dialect.NAMES) do
      local ok, run = pcall(dialect.get, name)
      if ok and type(run) == "function" then
        loaded[#loaded + 1] = name
      else
        broken[#broken + 1] = ("%s (%s)"):format(name, tostring(run))
      end
    end
    if #loaded > 0 then
      health.ok("dialects: " .. table.concat(loaded, ", "))
    end
    for _, b in ipairs(broken) do
      health.error("dialect does not load: " .. b, { "This is a defect of testing.nvim" })
    end
  end
  local rok, report = pcall(require, "testing.report")
  if rok then
    local loaded = {}
    for _, name in ipairs(report.names()) do
      local mod, err = report.resolve(name)
      if mod and type(mod.render) == "function" then
        loaded[#loaded + 1] = name
      else
        health.error(
          ("reporter '%s' does not load: %s"):format(name, tostring(err or "no render function")),
          { "This is a defect of testing.nvim" }
        )
      end
    end
    if #loaded > 0 then
      health.ok("reporters: " .. table.concat(loaded, ", "))
    end
  end
end

---Evaluate `.testing.lua` in an empty environment under an instruction budget.
---@param path string
---@return boolean evaluated The file ran to a table in the sandbox.
---@return any result_or_reason The returned table, or the reason it could not be evaluated.
---@return boolean? syntax The text does not compile (the third value only comes with that reason).
local function sandbox_eval(path)
  local project = require("testing.config.project")
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat or stat.type ~= "file" then
    return false, "not a regular file"
  end
  if stat.size > project.MAX_BYTES then
    return false, ("larger than %d bytes"):format(project.MAX_BYTES)
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return false, "cannot be read"
  end
  -- Bytecode is never accepted (`loadstring` would load it).
  if text:byte(1) == 27 then
    return false, "precompiled chunk refused"
  end
  local loader = loadstring or load
  local chunk, lerr = loader(text, "@" .. path)
  if not chunk then
    return false, "syntax error: " .. tostring(lerr), true
  end
  if setfenv then
    setfenv(chunk, {})
  end
  -- LuaJIT only honors a count of 1 reliably (larger counts never fire inside a tight loop), so
  -- the hook runs per instruction and counts for itself; it is global and is switched off again.
  local steps, active = 0, true
  local co = coroutine.create(chunk)
  debug.sethook(co, function()
    steps = steps + 1
    if active and steps > EVAL_BUDGET then
      -- Once only: the hook also fires in the calling thread when `resume` returns.
      active = false
      error("instruction budget exceeded", 0)
    end
  end, "", 1)
  local ok, res = coroutine.resume(co)
  active = false
  debug.sethook(co)
  debug.sethook()
  if not ok then
    return false, tostring(res)
  end
  if type(res) ~= "table" then
    return false, "does not return a table"
  end
  return true, res
end

---@param health table
---@return table|nil project The project's configuration when `.testing.lua` evaluated to a table here.
local function check_project(health)
  health.start("testing.nvim: project (.testing.lua)")
  local cwd = vim.fs.normalize(M.project_dir())
  local path = cwd .. "/.testing.lua"
  if not (vim.uv or vim.loop).fs_stat(path) then
    health.info(
      ("no .testing.lua in %s: the defaults apply (that is fine; `testing doctor` prints them)"):format(
        cwd
      )
    )
    return nil
  end
  local ok, res, syntax = sandbox_eval(path)
  if ok then
    local _, problems = require("testing.config.project").validate(res)
    if #problems == 0 then
      health.ok(".testing.lua is valid: " .. path)
    else
      health.warn(
        (".testing.lua has %d problem(s); the defaults stay in place for them"):format(#problems),
        problems
      )
    end
    return res
  elseif syntax then
    health.error(".testing.lua cannot be loaded: " .. tostring(res), {
      "The runner refuses a project whose .testing.lua does not load (exit code 2)",
    })
  else
    health.info(
      (".testing.lua is present but was not evaluated here (%s); run `testing doctor` in %s to check it"):format(
        tostring(res),
        cwd
      )
    )
  end
  return nil
end

---Modules of the guard layer and of the isolation machinery (kernel of M2).
---@type string[]
local ISOLATION_MODULES = {
  "testing.guard",
  "testing.guard.config",
  "testing.run.guards",
  "testing.run.options",
  "testing.run.isolated",
  "testing.isolation",
  "testing.child",
  "testing.child.runner",
  "testing.child.pool_boot",
  "testing.rpc",
  "testing.run.pool",
}

---Guards and the warm pool as the project configures them (read-only: nothing is started).
---@param health table
---@param project table|nil The project's `.testing.lua` table when it could be evaluated here.
local function check_isolation(health, project)
  health.start("testing.nvim: guards and warm pool")
  local loaded = true
  for _, name in ipairs(ISOLATION_MODULES) do
    local ok, err = pcall(require, name)
    if not ok then
      loaded = false
      health.error(("%s failed to load: %s"):format(name, tostring(err)), {
        "This is a defect of testing.nvim; report it with this message",
      })
    end
  end
  if not loaded then
    return
  end
  health.ok("the guard layer, the child drivers and the pool load")

  local o = require("testing.run.options").of({ project = project or {}, args = {} })
  local order =
    { "fs", "state", "scheduled_error", "prompt", "deprecation", "process_net", "clock" }
  local parts, on = {}, 0
  for _, name in ipairs(order) do
    local mode = o.guards[name]
    if name == "clock" then
      mode = mode and "on" or "off"
    end
    parts[#parts + 1] = ("%s=%s"):format(name, tostring(mode))
    if mode ~= "off" then
      on = on + 1
    end
  end
  if on == 0 then
    health.warn("every guard is off: a spec that leaks state or spawns a process is not noticed", {
      "Guards are safety nets for accidents (not a sandbox); see docs/GUARDS.md",
      "Turn them on with `guards = { state = 'warn', ... }` in .testing.lua or `--guard name=mode`",
    })
  else
    health.ok(("guards: %s"):format(table.concat(parts, " ")))
  end
  local allowed = #o.guard_allow.fs + #o.guard_allow.spawn + #o.guard_allow.network
  if allowed > 0 then
    health.info(
      ("allowed on purpose: %d path(s) for writes, %d executable(s), %d host(s)"):format(
        #o.guard_allow.fs,
        #o.guard_allow.spawn,
        #o.guard_allow.network
      )
    )
  end
  health.info(
    ("isolation: %s; child environment: %s, trace artifact on a dead child: %s"):format(
      o.isolated,
      o.determinism and "LANG/TZ fixed" or "LANG/TZ of the parent",
      o.trace and "on" or "off"
    )
  )
  if o.pool.reuse then
    local size = o.pool.size > 0 and o.pool.size or math.min(o.jobs, 4)
    health.ok(
      ("warm pool: on (up to %d editor(s) at a time, each reset and verified clean between files)"):format(
        math.max(1, math.min(size, o.jobs))
      )
    )
    if o.jobs == 1 then
      health.info(
        "jobs = 1: the pool keeps ONE editor for all files; raise `jobs` to run files in parallel"
      )
    end
  else
    health.info(
      "warm pool: off (`pool = { reuse = true }` or --pool-reuse): a child editor per file"
    )
  end
end

---Can `dir` be created and written? Looks at the nearest ancestor that exists (nothing is written).
---@param dir string
---@return boolean writable
---@return string checked The directory that was tested.
local function writable_dir(dir)
  local uv = vim.uv or vim.loop
  local probe = dir
  while probe ~= "" and not uv.fs_stat(probe) do
    local parent = vim.fs.dirname(probe)
    if parent == probe then
      break
    end
    probe = parent
  end
  return uv.fs_access(probe, "W") == true, probe
end

---The result cache, the affected selection, the conformance suite and the surface report: are they
---available, and is what they read and write in order?
---@param health table
local function check_extensions(health)
  health.start("testing.nvim: cache, affected selection, conformance, surface")
  local root = vim.fs.normalize(M.project_dir())

  local okc, cache = pcall(require, "testing.cache")
  if not okc then
    health.error("testing.cache does not load: " .. tostring(cache), {
      "This is a defect of testing.nvim",
    })
  else
    local ok_stats, stats = pcall(cache.stats, { root = root })
    if ok_stats then
      local writable, checked = writable_dir(stats.dir)
      if writable then
        health.ok(
          ("result cache: %s is writable (%d entr%s, %.1f KB); `--cached` uses it, `--cache-clear` empties it"):format(
            stats.dir,
            stats.entries,
            stats.entries == 1 and "y" or "ies",
            stats.bytes / 1024
          )
        )
      else
        health.warn(
          ("result cache: %s cannot be written (%s is not writable); `--cached` runs everything and stores nothing"):format(
            stats.dir,
            checked
          ),
          { "Fix the permissions of stdpath('cache'), or do not use --cached" }
        )
      end
    else
      health.warn("result cache: cannot read its state: " .. tostring(stats))
    end
  end

  local oka, affected = pcall(require, "testing.affected")
  if not oka then
    health.error("testing.affected does not load: " .. tostring(affected), {
      "This is a defect of testing.nvim",
    })
  else
    local okd, doc = pcall(require, "documentation.testing")
    if okd and type(doc) == "table" and type(doc.affected_specs) == "function" then
      health.ok(
        ("documentation.nvim contract is available (version %s): --changed / --since / --affected use its module graph"):format(
          tostring(doc.CONTRACT_VERSION)
        )
      )
      local fresh = affected.graph_freshness(root)
      if fresh.status == "ok" then
        health.ok("module graph (docs/map/module_map.json) is current")
      elseif fresh.status == "stale" then
        health.warn(
          "module graph is stale: " .. fresh.message .. " (the selection runs every spec)",
          { "Regenerate it with documentation.nvim's map generator" }
        )
      elseif fresh.status == "missing" then
        health.info("module graph: " .. fresh.message .. " (the built-in heuristic is used)")
      else
        health.info("module graph: " .. tostring(fresh.message))
      end
    else
      health.info(
        "documentation.nvim contract is not on the runtimepath: --changed / --since / --affected use the built-in heuristic (conservative, project-local)"
      )
    end
  end

  local okf, conformance = pcall(require, "testing.conformance")
  if okf then
    health.ok(
      ("`testing conformance` is available (%d checks; report only unless --gate)"):format(
        #conformance.checks()
      )
    )
  else
    health.error("testing.conformance does not load: " .. tostring(conformance), {
      "This is a defect of testing.nvim",
    })
  end
  local oks, surface = pcall(require, "testing.surface")
  local okt = oks and pcall(require, "testing.surface.track")
  if oks and okt then
    health.ok("`testing surface` and the tracking layer (`surface.track = true`) are available")
  else
    health.error("testing.surface does not load: " .. tostring(surface), {
      "This is a defect of testing.nvim",
    })
  end
end

---@param health table
local function check_deps(health)
  health.start("testing.nvim: dependency resolution (command line)")
  local deps = require("testing.deps")
  local rows = deps.report({ "lib.nvim" }, deps.self_dir())
  for _, row in ipairs(rows) do
    if row.ok then
      health.ok(("%s -> %s (%s)"):format(row.name, row.dir, row.source))
    else
      -- The plugin works in the editor (the modules loaded above), but the runner looks in four
      -- fixed places and none holds lib.nvim: say exactly that, it is not an editor defect.
      local where = vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1]
      health.warn(
        ("%s is not in any of the places the command-line runner searches%s"):format(
          row.name,
          where and (" (it is on the runtimepath at " .. where .. ")") or ""
        ),
        vim.split(row.message, "\n", { plain = true })
      )
    end
  end
end

---@return nil
function M.check()
  local health = vim.health

  health.start("testing.nvim")
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("testing.nvim needs Neovim 0.10+", { "Upgrade Neovim to 0.10 or newer" })
  end

  -- lib.nvim is a hard dependency: without it nothing below can be probed.
  if not check_lib(health) then
    return
  end

  check_kernel(health)
  check_registries(health)
  check_deps(health)
  local project = check_project(health)
  check_isolation(health, project)
  check_extensions(health)

  health.start("testing.nvim: configuration")
  local config = require("testing.config")
  local cfg = config.get()
  health.ok(("notify prefix: %s"):format(cfg.notify_prefix))
  if cfg.keymaps == false or next(cfg.keymaps) == nil then
    health.info("no keymap is configured or bound by default")
  else
    health.info("keymap overrides are set, see docs/BINDINGS.md")
  end

  health.start("testing.nvim: bindings")
  if vim.fn.exists(":Testing") == 2 then
    health.ok(":Testing is registered")
  else
    -- The normal state before the plugin loaded (lazy `cmd =`), not a defect.
    health.info(":Testing is not registered yet; it is after the plugin loads or setup() runs")
  end
end

return M
