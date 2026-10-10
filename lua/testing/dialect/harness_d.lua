---@module 'testing.dialect.harness_d'
---@brief Dialect D adapter: spotlight.nvim's `M.run()` specs with their own `harness` module.
---@description
--- Dialect D is a module spec: `local t = require("harness")`, `function M.run() ... t.ok(name, cond, msg) ... end`,
--- `return M`. The plugin's harness collects already (`t.failures`, `t.passed`) and carries helpers of
--- its own (`with_modules`, `fixture`, `cursor_on`, ...). Re-implementing those would fork them, so
--- this adapter keeps the plugin's own `harness` module and listens to it:
---
---   * the module is loaded the way the plugin's runner does (`require("harness")`, with the spec's
---     directory on `package.path` for the time of the run);
---   * every function of the module is wrapped once: after the call, whatever the plugin's counters
---     gained (`t.passed`, `t.failures`) is recorded as assertions of the open case, with the call
---     site of the spec (the outermost wrapped call decides; helpers that call `t.ok` inside are one
---     step);
---   * the file is ONE case, `<file>::<file name>` (dialect D has no case structure), whose
---     assertions are the `t.*` checks of `M.run`.
---
--- A harness without the two counters is not dialect D: the adapter raises a clear error instead of
--- guessing. `package.loaded.harness` is restored (removed) after the run when it was not loaded
--- before, so a later file loads its own copy and counters do not leak between files.
---
--- The adapter outside a run (the wrapped module used after the case ended) behaves exactly like the
--- original.

local M = {}

---@class Testing.HarnessD.Run
---@field a Testing.Assert.Context
---@field t table The plugin's harness module.
---@field passed integer Passes already recorded.
---@field failed integer Failures already recorded.
---@field depth integer Nesting of wrapped calls.

---@type Testing.HarnessD.Run|nil
local active

---@type table<table, boolean>
local instrumented = setmetatable({}, { __mode = "k" })

local unpack_fn = table.unpack or unpack

---@param ... any
---@return table packed `{ n = count, ... }`: embedded nils survive.
local function pack(...)
  return { n = select("#", ...), ... }
end

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---File and line of the first frame above the wrapper that is neither this file nor C.
---@param skip table<string, boolean> Sources (forward slashes) to step over.
---@return string|nil file
---@return integer|nil line
local function call_site(skip)
  local level = 3
  while level < 20 do
    local info = debug.getinfo(level, "Sl")
    if not info then
      return nil, nil
    end
    local src = info.source
    local file = slashes(src:sub(1, 1) == "@" and src:sub(2) or info.short_src)
    if
      info.what ~= "C"
      and not skip[file]
      and not file:find("lua/testing/dialect/harness_d.lua", 1, true)
    then
      return file, info.currentline > 0 and info.currentline or nil
    end
    level = level + 1
  end
  return nil, nil
end

---Record what the counters gained since the last sync.
---@param run Testing.HarnessD.Run
---@param file string|nil
---@param line integer|nil
local function sync(run, file, line)
  local case = run.a.current()
  local t = run.t
  local passed, failures = t.passed, t.failures
  if case then
    for _ = run.passed + 1, passed do
      case.assertions[#case.assertions + 1] = { ok = true, kind = "ok", file = file, line = line }
    end
    for i = run.failed + 1, #failures do
      case.assertions[#case.assertions + 1] = {
        ok = false,
        kind = "ok",
        msg = tostring(failures[i]),
        file = file,
        line = line,
      }
    end
  end
  run.passed, run.failed = passed, #failures
end

---@param e any
---@return any
local function with_traceback(e)
  if type(e) == "string" then
    return debug.traceback(e, 2)
  end
  return e
end

---Wrap every function of the plugin's harness once.
---@param t table
---@param harness_file string|nil Source of the harness (frames in it are not the spec's call site).
local function instrument(t, harness_file)
  if instrumented[t] then
    return
  end
  instrumented[t] = true
  local skip = {}
  if harness_file then
    skip[harness_file] = true
  end
  local names = {}
  for name, value in pairs(t) do
    if type(value) == "function" then
      names[#names + 1] = name
    end
  end
  for _, name in ipairs(names) do
    local original = t[name]
    t[name] = function(...)
      local run = active
      if not run or run.t ~= t then
        return original(...)
      end
      local args = { n = select("#", ...), ... }
      run.depth = run.depth + 1
      local res = pack(xpcall(function()
        return original(unpack_fn(args, 1, args.n))
      end, with_traceback))
      run.depth = run.depth - 1
      local file, line = call_site(skip)
      sync(run, file, line)
      if not res[1] then
        error(res[2], 0)
      end
      return unpack_fn(res, 2, res.n)
    end
  end
end

---Run one dialect-D spec file inside the open case of `a`.
---@param a Testing.Assert.Context
---@param spec { path: string, rel: string, tests_dir?: string }
function M.run_body(a, spec)
  local dir = slashes(spec.tests_dir or vim.fs.dirname(spec.path))
  local old_path = package.path
  local had = package.loaded["harness"]
  package.path = dir .. "/?.lua;" .. dir .. "/?/init.lua;" .. old_path

  local function finish()
    active = nil
    package.path = old_path
    if had == nil then
      package.loaded["harness"] = nil
    end
  end

  local ok, err = xpcall(function()
    local loaded, t = pcall(require, "harness")
    if not loaded then
      error(
        ("dialect d: cannot load the plugin's harness (require 'harness' from %s): %s"):format(
          dir,
          tostring(t)
        ),
        0
      )
    end
    if type(t) ~= "table" or type(t.passed) ~= "number" or type(t.failures) ~= "table" then
      error(
        "dialect d: the module 'harness' has no numeric `passed` and table `failures`; this is not a dialect-D harness",
        0
      )
    end
    local harness_file
    local found = package.searchpath("harness", package.path)
    if found then
      harness_file = slashes(found)
    end
    instrument(t, harness_file)

    local mod = dofile(spec.path)
    if type(mod) ~= "table" or type(mod.run) ~= "function" then
      error(
        ("dialect d: %s must return a table with a run() function, got %s"):format(
          spec.rel,
          type(mod) == "table" and "a table without run" or type(mod)
        ),
        0
      )
    end

    active = { a = a, t = t, passed = t.passed, failed = #t.failures, depth = 0 }
    local run = active
    local ran, run_err = xpcall(mod.run, with_traceback)
    -- whatever was counted without passing through a wrapper (direct writes) is recorded with the spec's file
    sync(run, slashes(spec.path), nil)
    if not ran then
      error(run_err, 0)
    end
  end, with_traceback)
  finish()
  if not ok then
    error(err, 0)
  end
end

---Run a dialect-D spec file as one case.
---@param a Testing.Assert.Context
---@param spec { path: string, rel: string, tests_dir?: string }
---@param opts? { on_case?: fun(case: Testing.Result.Case), assertions?: "error"|"warn" }
---@return Testing.Result.Case[] cases
function M.run_file(a, spec, opts)
  local case = require("testing.policy").guard(opts, function()
    return a.run_case(
      { file = spec.rel, name = vim.fs.basename(spec.rel), spec_path = spec.path },
      function()
        M.run_body(a, spec)
      end
    )
  end)
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
