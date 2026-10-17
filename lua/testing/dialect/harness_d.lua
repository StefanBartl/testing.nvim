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
---@field list table The plugin's failure list at the last sync (a spec may replace it).
---@field snapshot any[] Its entries at the last sync.
---@field known table<string, integer> The messages in the plugin's failure list at the last sync, with their counts.
---@field listed table[] The failed assertions recorded from the plugin's failure list, oldest first (taken back when the spec trims the list).
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

---Messages of the plugin's failure list with how often each occurs.
---@param failures table
---@return table<string, integer>
local function tally(failures)
  local counts = {}
  for i = 1, #failures do
    local msg = tostring(failures[i])
    counts[msg] = (counts[msg] or 0) + 1
  end
  return counts
end

---@param list table
---@return any[]
local function copy_list(list)
  local out = {}
  for i = 1, #list do
    out[i] = list[i]
  end
  return out
end

---A failed assertion for entry `i` of the plugin's failure list.
---@param run Testing.HarnessD.Run
---@param case Testing.Result.Case|nil
---@param msg string
---@param file string|nil
---@param line integer|nil
local function add_failure(run, case, msg, file, line)
  if not case then
    return
  end
  local entry = { ok = false, kind = "ok", msg = msg, file = file, line = line }
  case.assertions[#case.assertions + 1] = entry
  run.listed[#run.listed + 1] = entry
end

---Are the first `n` entries of `list` the ones of `snapshot`? (A list that lost an early entry and got a new one with the text
---of the last one it had looks unchanged by its last entry alone.)
---@param snapshot any[]
---@param list any[]
---@param n integer
---@return boolean
local function same_prefix(snapshot, list, n)
  for i = 1, n do
    if not rawequal(snapshot[i], list[i]) then
      return false
    end
  end
  return true
end

---Record what the counters gained since the last sync.
---@param run Testing.HarnessD.Run
---@param file string|nil
---@param line integer|nil
local function sync(run, file, line)
  local case = run.a.current()
  local t = run.t
  local passed, failures = t.passed, t.failures
  local n = #run.snapshot
  if failures == run.list and #failures >= n and same_prefix(run.snapshot, failures, n) then
    -- the common case: the list only grew at its end
    for i = n + 1, #failures do
      local msg = tostring(failures[i])
      add_failure(run, case, msg, file, line)
      run.snapshot[i] = failures[i]
      run.known[msg] = (run.known[msg] or 0) + 1
    end
  else
    local now = tally(failures)
    if failures ~= run.list then
      -- the spec replaced the list (`t.failures = {}`): the entries of the list it had are not in this one
      run.known = {}
      for _, entry in ipairs(run.listed) do
        run.known[entry.msg] = (run.known[entry.msg] or 0) + 1
      end
    end
    -- a spec that tests the harness takes an EXPECTED failure back out of the list (`table.remove(t.failures)`,
    -- `t.failures = {}`): what is gone from the list is judged by WHAT is gone, not by how many entries there are
    -- (it may be the oldest one, a failure of an earlier file, or go together with a new failure in the same step)
    local gone = {}
    for msg, count in pairs(run.known) do
      if count > (now[msg] or 0) then
        gone[msg] = count - (now[msg] or 0)
      end
    end
    for i = #run.listed, 1, -1 do
      local entry = run.listed[i]
      if (gone[entry.msg] or 0) > 0 then
        gone[entry.msg] = gone[entry.msg] - 1
        table.remove(run.listed, i)
        local assertions = case and case.assertions or {}
        for j = #assertions, 1, -1 do
          if assertions[j] == entry then
            table.remove(assertions, j)
            break
          end
        end
      end
    end
    local seen = {}
    for i = 1, #failures do
      local msg = tostring(failures[i])
      seen[msg] = (seen[msg] or 0) + 1
      -- the entries that were there before and still are (the file's own or earlier ones) are not new
      if seen[msg] > math.min(run.known[msg] or 0, now[msg]) then
        add_failure(run, case, msg, file, line)
      end
    end
    run.known, run.list = now, failures
    run.snapshot = copy_list(failures)
  end
  if case then
    for _ = run.passed + 1, passed do
      case.assertions[#case.assertions + 1] = { ok = true, kind = "ok", file = file, line = line }
    end
  end
  run.passed = passed
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

    -- The baseline is taken BEFORE the file is loaded: a check at the top level of the file (outside `M.run`) is a
    -- check of the file, as it is for the project's own runner, which loads the file and prints the shared list. What
    -- the harness itself recorded while it was required, and what earlier files left in the list, stays baseline.
    active = {
      a = a,
      t = t,
      passed = t.passed,
      list = t.failures,
      snapshot = copy_list(t.failures),
      known = tally(t.failures),
      listed = {},
      depth = 0,
    }
    local run = active
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
    -- no `spec_path`: the checks of dialect d are counted from the plugin's harness, never made through `a.eq` &
    -- co, so the pcall rule of `testing.core.protected` has nothing to decide here
    return a.run_case({ file = spec.rel, name = vim.fs.basename(spec.rel) }, function()
      M.run_body(a, spec)
    end)
  end)
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
