---@module 'testing.conformance.runtime'
---@brief Runs the runtime checks' sessions: a throwaway child editor with the plugin loaded from the repository.
---@description
--- A runtime check never touches the editor that runs the suite. It asks `ctx.probe(name)` for the data of
--- one SESSION; a session is one child editor (`testing.rpc`: its own XDG and temp directories, an
--- allowlisted environment, guards installed) that the suite starts, drives with the functions of
--- `testing.conformance.probe`, and kills again. The data is memoized per run, so K2, K4, K5, K6, K8 .. K14
--- share the `main` session and the whole suite starts at most three editors:
---
---   main          sources `plugin/`, requires the plugin, `setup()` twice, facts after each, the lib.nvim
---                 audits, `:checkhealth`, timing; the guard window (K8, K9) covers sourcing, require and
---                 the first `setup()`
---   keymaps_off   the same with `setup(<setup> + conformance.keymaps_off)` (K3)
---   require       every module of the plugin alone (K1)
---
--- The plugin comes from the repository: its root is FIRST on the child's runtimepath, then this
--- checkout of testing.nvim (the guards), lib.nvim and the dependencies of `.testing.lua`. The child's
--- working directory is a temporary directory, never the repository: a plugin that writes to a relative
--- path during `setup()` writes there (and SEC-47 holds: the checked repository is never modified).
--- `.testing.lua`'s `minit` is NOT run: it belongs to the specs (it may stub half the editor), and the
--- point of the suite is the plugin in a plain editor; what the plugin needs must be listed in `deps`.

local M = {}

---Guard configuration of a conformance child: observe (`warn`), never block, no file-tree snapshot.
---@param root string
---@return table
function M.guard_config(root)
  return {
    repo = root,
    guards = {
      fs = { mode = "warn", snapshot = false },
      state = { mode = "off" },
      scheduled_error = { mode = "warn" },
      prompt = { mode = "warn" },
      deprecation = { mode = "warn" },
      process_net = { mode = "warn" },
      clock = { mode = "off" },
    },
  }
end

---The runtimepath entries and environment of a conformance child.
---@param ctx Testing.Conformance.Ctx
---@return string[] prepend
---@return table<string, string> extra_env
---@return string[] missing Dependencies of `.testing.lua` that were not found.
function M.environment(ctx)
  local deps = require("testing.deps")
  local self_dir = deps.self_dir()
  local prepend, seen = {}, {}
  local function add(dir)
    local key = vim.fs.normalize(dir):lower()
    if not seen[key] then
      seen[key] = true
      prepend[#prepend + 1] = vim.fs.normalize(dir)
    end
  end
  local extra_env = { [deps.env_name("testing.nvim")] = self_dir }
  add(ctx.root)
  add(self_dir)
  local lib = deps.resolve("lib.nvim", ctx.root) or deps.resolve("lib.nvim", self_dir)
  if lib then
    add(lib.dir)
    extra_env[deps.env_name("lib.nvim")] = lib.dir
  end
  local missing = {}
  local resolved, failures = deps.resolve_all(ctx.config.deps or {}, ctx.root)
  for _, r in ipairs(resolved) do
    add(r.dir)
    extra_env[deps.env_name(r.name)] = r.dir
  end
  for _, name in ipairs(ctx.config.deps or {}) do
    local found = false
    for _, r in ipairs(resolved) do
      found = found or r.name == name
    end
    if not found then
      missing[#missing + 1] = name
    end
  end
  if #failures > 0 and #missing == 0 then
    missing[1] = "?"
  end
  return prepend, extra_env, missing
end

---Can this table travel over msgpack-rpc (no function, userdata, thread or cycle)?
---@param value any
---@param depth? integer
---@return boolean
function M.serializable(value, depth)
  depth = depth or 0
  local t = type(value)
  if t == "function" or t == "userdata" or t == "thread" then
    return false
  end
  if t ~= "table" then
    return true
  end
  if depth > 16 then
    return false
  end
  for k, v in pairs(value) do
    if (type(k) ~= "string" and type(k) ~= "number") or not M.serializable(v, depth + 1) then
      return false
    end
  end
  return true
end

---Run `fn(child, P)` in a fresh child editor and clean up whatever happened.
---`P(name, ...)` calls `testing.conformance.probe.<name>(...)` in the child.
---@param ctx Testing.Conformance.Ctx
---@param name string Session name (trace file stem).
---@param fn fun(child: table, P: fun(name: string, ...: any): any): table
---@return table|nil data
---@return string|nil err
function M.session(ctx, name, fn)
  local prepend, extra_env, missing = M.environment(ctx)
  ctx.missing_deps = missing -- K6 reads it: a health error about a dependency that is not installed here is the environment's
  if #missing > 0 and not ctx.missing_noted then
    ctx.missing_noted = true
    ctx.notes[#ctx.notes + 1] = ("dependenc(ies) of .testing.lua not found: %s; a require of them fails in the child editor"):format(
      table.concat(missing, ", ")
    )
  end
  local work = vim.fs.normalize(vim.fn.tempname()) .. "-conformance"
  local made, merr = require("lib.nvim.fs.mkdirp")(work)
  if not made then
    return nil, ("cannot create a working directory: %s"):format(tostring(merr))
  end
  local child
  local function finish()
    if child then
      -- Let the editor quit by itself (closing its stdin ends an embedded session: ~40 ms); killing
      -- the process tree costs seconds on Windows. `kill` afterwards only cleans up (and is the
      -- fallback for an editor that does not leave within 3 s).
      pcall(child.close_stdin)
      pcall(vim.wait, 3000, function()
        return not child.alive()
      end, 5)
      pcall(child.kill)
    end
    -- own temporary directory only
    pcall(vim.fn.delete, work, "rf")
  end
  local rpc = require("testing.rpc")
  local spawned, err = rpc.spawn({
    root = work,
    rtp_prepend = prepend,
    extra_env = extra_env,
    env_allow = ctx.config.env_allow,
    defer_plugins = true,
    guard = M.guard_config(ctx.root),
    call_timeout_ms = ctx.settings.timeout_ms,
    boot_timeout_ms = 30000,
    trace_dir = work .. "/trace",
    trace_name = "conformance-" .. name,
    deterministic = ctx.config.determinism ~= false,
  })
  if not spawned then
    finish()
    return nil, "the child editor did not start: " .. tostring(err)
  end
  child = spawned
  local function P(fn_name, ...)
    return child.lua("return require('testing.conformance.probe')." .. fn_name .. "(...)", ...)
  end
  local ok, data = xpcall(fn, debug.traceback, child, P)
  finish()
  if not ok then
    local msg = tostring(data):match("^[^\n]*") or tostring(data)
    return nil, msg
  end
  return data
end

---`pcall` that returns `value` or a table `{ err = ... }`.
---@param f fun(): any
---@return any
local function try(f)
  local ok, res = pcall(f)
  if ok then
    return res
  end
  return { err = (tostring(res):match("^[^\n]*") or tostring(res)):sub(1, 600) }
end

---Plain `{ spawned, network, fs_outside_tmp }` and findings out of a guard `end_case` result. `available`
---says whether the guards ran at all: "nothing was observed" is not "nothing happened" (K8, K9 answer `n/a`).
---@param res any
---@param ran boolean A guard was installed in the child.
---@return table
local function guard_data(res, ran)
  local out = {
    findings = {},
    effects = { spawned = {}, network = {}, fs_outside_tmp = {} },
    available = ran and type(res) == "table" and res.err == nil,
    err = type(res) == "table" and res.err or nil,
  }
  if type(res) ~= "table" then
    return out
  end
  for _, f in ipairs(res.findings or {}) do
    if type(f) == "table" then
      out.findings[#out.findings + 1] = {
        id = f.id,
        guard = f.guard,
        severity = f.severity,
        message = f.message,
      }
    end
  end
  local effects = res.effects
  if type(effects) == "table" then
    for _, key in ipairs({ "spawned", "network", "fs_outside_tmp" }) do
      for _, v in ipairs(type(effects[key]) == "table" and effects[key] or {}) do
        if type(v) == "string" then
          out.effects[key][#out.effects[key] + 1] = v
        end
      end
    end
  end
  return out
end

---Where the generated binding pages of lib.nvim would live, when the repository has them.
---@param ctx Testing.Conformance.Ctx
---@return { root: string, usercmd_dir?: string, autocmd_dir?: string }|nil
function M.docs_spec(ctx)
  local plugin = ctx.plugin
  if not plugin then
    return nil
  end
  local spec = { root = ctx.root }
  for _, rel in ipairs({
    "lua/" .. plugin .. "/bindings/usercmd",
    "lua/" .. plugin .. "/bindings/usrcmds",
    "lua/" .. plugin .. "/bindings/usercmds",
    "docs",
  }) do
    local text = ctx.fs:read(rel .. "/commands.md")
    if text and text:find("GENERATED by lib.nvim.bindings.usercmd.docs", 1, true) then
      spec.usercmd_dir = ctx.root .. "/" .. rel
      break
    end
  end
  for _, rel in ipairs({ "lua/" .. plugin .. "/bindings/autocmd", "docs" }) do
    for _, e in ipairs(ctx.fs:list(rel)) do
      if e.type == "file" and e.name:match("%.md$") then
        local text = ctx.fs:read(rel .. "/" .. e.name)
        if text and text:find("GENERATED by lib.nvim.bindings.autocmd.docs", 1, true) then
          spec.autocmd_dir = ctx.root .. "/" .. rel
          break
        end
      end
    end
    if spec.autocmd_dir then
      break
    end
  end
  if spec.usercmd_dir or spec.autocmd_dir then
    return spec
  end
  return nil
end

---The `main` session.
---@param ctx Testing.Conformance.Ctx
---@return table|nil data
---@return string|nil err
function M.main(ctx)
  local plugin = ctx.plugin
  if not plugin then
    return nil, ctx.plugin_problem or "no plugin module"
  end
  local opts = vim.deepcopy(ctx.config.setup or {})
  if not M.serializable(opts) then
    return nil,
      "`setup` of .testing.lua holds a function or another value that cannot be sent to a child editor"
  end
  return M.session(ctx, "main", function(child, P)
    local data = { plugin = plugin }
    data.base = try(function()
      return P("begin")
    end)
    local has_guard = child.guard ~= nil
    if has_guard then
      try(function()
        return child.guard.begin_case({ id = "conformance::main", file = "conformance" })
      end)
    end
    data.plugin_files = try(function()
      return P("source_plugin", ctx.root)
    end)
    data.load = try(function()
      return P("load", plugin)
    end)
    if data.load.ok and data.load.has_setup then
      data.setup1 = try(function()
        return P("setup", plugin, opts)
      end)
    end
    data.facts1 = try(function()
      return P("facts")
    end)
    if has_guard then
      data.guard = guard_data(
        try(function()
          return child.guard.end_case()
        end),
        true
      )
    else
      data.guard = guard_data(nil, false)
    end
    if data.setup1 and data.setup1.ok then
      data.setup2 = try(function()
        return P("setup", plugin, opts)
      end)
      data.facts2 = try(function()
        return P("facts")
      end)
      local again = try(function()
        return P("remeasure", plugin, opts, 2)
      end)
      local timings = { (data.load.ms or 0) + (data.setup1.ms or 0) }
      if type(again) == "table" and again.err == nil then
        for _, ms in ipairs(again) do
          timings[#timings + 1] = ms
        end
      end
      data.timings = timings
    elseif data.load.ok then
      data.timings = { data.load.ms or 0 }
    end
    data.audit = try(function()
      return P("audit")
    end)
    if ctx.fs:is_file("lua/" .. plugin .. "/health.lua") then
      data.health = try(function()
        return P("health", plugin)
      end)
    end
    local docs = M.docs_spec(ctx)
    if docs then
      data.docs = try(function()
        return P("docs", docs)
      end)
    end
    return data
  end)
end

---The `keymaps_off` session (K3).
---@param ctx Testing.Conformance.Ctx
---@return table|nil data
---@return string|nil err
function M.keymaps_off(ctx)
  local plugin = ctx.plugin
  if not plugin then
    return nil, ctx.plugin_problem or "no plugin module"
  end
  local opts =
    vim.tbl_deep_extend("force", vim.deepcopy(ctx.config.setup or {}), ctx.settings.keymaps_off)
  if not M.serializable(opts) then
    return nil, "the setup options cannot be sent to a child editor"
  end
  return M.session(ctx, "keymaps_off", function(_, P)
    local data = { plugin = plugin, opts = opts }
    data.base = try(function()
      return P("begin")
    end)
    data.plugin_files = try(function()
      return P("source_plugin", ctx.root)
    end)
    data.load = try(function()
      return P("load", plugin)
    end)
    if data.load.ok and data.load.has_setup then
      data.setup = try(function()
        return P("setup", plugin, opts)
      end)
    end
    data.facts = try(function()
      return P("facts")
    end)
    return data
  end)
end

---Most modules one call into the child requires (a call has a timeout).
M.BATCH = 60

---The `require` session (K1): every module of the plugin alone.
---
---A module that ENDS the editor when it is required (`os.exit`, `:quit` at its top level: a module meant
---to run as an init script) kills the batch it is in. The batch is then split and run again in fresh
---editors until the killer is alone; it is reported as a module that cannot be required.
---@param ctx Testing.Conformance.Ctx
---@return table|nil data
---@return string|nil err
function M.require_all(ctx)
  local modules = {}
  for _, m in ipairs(ctx.modules()) do
    modules[#modules + 1] = m.module
  end
  local results = {}

  ---@param batch string[]
  ---@return string|nil err An infrastructure error (not a dead editor).
  local function run_batch(batch)
    local data, err = M.session(ctx, "require", function(_, P)
      return { results = P("require_each", batch) }
    end)
    if data then
      for _, r in ipairs(data.results) do
        results[#results + 1] = r
      end
      return nil
    end
    if err and err:find("child died", 1, true) then
      if #batch == 1 then
        results[#results + 1] = {
          module = batch[1],
          ok = false,
          killed = true,
          err = "the editor ended while it was required (" .. err .. ")",
        }
        return nil
      end
      local mid = math.floor(#batch / 2)
      return run_batch(vim.list_slice(batch, 1, mid))
        or run_batch(vim.list_slice(batch, mid + 1, #batch))
    end
    return err or "the child editor did not answer"
  end

  for i = 1, #modules, M.BATCH do
    local err = run_batch(vim.list_slice(modules, i, math.min(i + M.BATCH - 1, #modules)))
    if err then
      return nil, err
    end
  end
  table.sort(results, function(x, y)
    return x.module < y.module
  end)
  return { results = results }
end

return M
