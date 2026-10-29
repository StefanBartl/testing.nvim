---@module 'testing.ci.schema'
---@brief The `ci` section of `.testing.lua`: validation and resolution into a pipeline.
---@description
--- ```lua
--- ci = {
---   profiles = { fast = { "stylua", "luacheck" }, full = { "fast", "suite" } }, -- a profile may name a profile
---   default = "full",
---   steps = {
---     luacheck = { preset = "luacheck", args = { "lua", "TESTS" } },          -- a preset, adjusted
---     docs = { run = { "scripts/gen_docs.sh", "--check" }, timeout = "2m" },  -- a step of the repo
---   },
--- }
--- ```
---
--- A name in a profile is a profile, a step of `steps`, or a preset (`stylua`, `suite`, ...) used as it is. A step is
--- argv, never a shell line. The only placeholders are `${root}` and `${deps.<name>}` (in `run`, `args` and `env`
--- values). Unlike the rest of `.testing.lua`, where a bad key is a warning and the default stays, every problem
--- here is an error for `testing ci`: a pipeline with a typo must not run green.

local presets = require("testing.ci.presets")

local M = {}

---Default deadline of a process step (milliseconds).
M.DEFAULT_TIMEOUT_MS = 600000

---Options of a run that run no suite (or not to its end): in a suite step's `args` and after `--` they are an error,
---a suite step that runs nothing must not read as green.
M.NO_RUN_OPTIONS = {
  ["--help"] = true,
  ["-h"] = true,
  ["--cache-clear"] = true,
  ["--list"] = true,
  ["--dry-run"] = true,
  ["--watch"] = true,
}

local STEP_KEYS = {
  preset = true,
  run = true,
  args = true,
  needs = true,
  env = true,
  timeout = true,
  when = true,
  stamp = true,
  skip_exit = true,
}

local NAME = "^[%a_][%w_%-]*$"

---@class Testing.Ci.Step
---@field name string
---@field preset? string
---@field inprocess? string The in-process runner of a preset (`suite`, `conformance`, ...), nil for a process.
---@field argv? string[] Process steps: the command line, placeholders still in.
---@field needs string[] Tools that must be found before the first step runs.
---@field env table<string, string>
---@field timeout_ms integer
---@field os? table<string, boolean> Only on these systems (`windows`, `linux`, `macos`); nil = everywhere.
---@field stamp boolean `suite` only: write the stamp (`testing stamp`).
---@field skip_exit? integer A process step that exits with this code skipped itself (no proof, the run is partial).
---@field efm? string|string[] The preset's error format (quickfix, findings); alternatives as a list.
---@field version_argv? string[] How to ask the tool for its version.

---@class Testing.Ci.Pipeline
---@field profiles table<string, string[]> Each profile expanded into step names, in order, without duplicates.
---@field default string
---@field steps table<string, Testing.Ci.Step>
---@field digest_input table What the pipeline hash is taken over (the resolved definition).
---@field derived? table<string, string> Derived steps (`testing.ci.derive`) and why; nil for a written pipeline.

---@param v any
---@return string
local function show(v)
  local s = vim.inspect(v):gsub("%s+", " ")
  return #s > 60 and s:sub(1, 57) .. "..." or s
end

---@param v any
---@return boolean
local function is_str_list(v)
  if type(v) ~= "table" then
    return false
  end
  local n = 0
  for k, item in pairs(v) do
    n = n + 1
    if type(k) ~= "number" or type(item) ~= "string" or item == "" or item:find("\0", 1, true) then
      return false
    end
  end
  return n == #v
end

---Parse a duration: a number of milliseconds, or `"500ms"`, `"30s"`, `"2m"`, `"1h"`.
---@param v any
---@return integer|nil ms
function M.duration(v)
  if type(v) == "number" then
    return (v == v and v >= 1 and v == math.floor(v)) and v or nil
  end
  if type(v) ~= "string" then
    return nil
  end
  local n, unit = v:match("^(%d+)(%a*)$")
  local scale = ({ ms = 1, s = 1000, m = 60000, h = 3600000 })[unit or ""]
  if not n or not scale or tonumber(n) < 1 then
    return nil
  end
  return tonumber(n) * scale
end

---Placeholders a value uses that are not `${root}` / `${deps.<name>}`.
---@param s string
---@return string|nil bad
local function bad_placeholder(s)
  for inner in s:gmatch("%${([^}]*)}") do
    local dep = inner:match("^deps%.(.+)$")
    if inner ~= "root" and not (dep and require("testing.deps").is_valid_name(dep)) then
      return "${" .. inner .. "}"
    end
  end
  if s:gsub("%${[^}]*}", ""):find("${", 1, true) then
    return "an unclosed ${"
  end
  return nil
end

---@param step_name string
---@param raw table
---@param problems string[]
---@return Testing.Ci.Step|nil
local function resolve_step(step_name, raw, problems)
  local where = "ci.steps." .. step_name
  local before = #problems
  for key in pairs(raw) do
    if type(key) ~= "string" or not STEP_KEYS[key] then
      problems[#problems + 1] = ("unknown key '%s.%s'"):format(where, tostring(key))
    end
  end
  local preset
  if raw.preset ~= nil then
    preset = presets.get(raw.preset)
    if not preset then
      problems[#problems + 1] = ("%s.preset: unknown preset %s (known: %s)"):format(
        where,
        show(raw.preset),
        table.concat(presets.names(), ", ")
      )
      return nil
    end
  end
  if raw.run ~= nil and preset then
    problems[#problems + 1] = ("%s: `run` and `preset` exclude each other"):format(where)
  elseif raw.run == nil and not preset then
    problems[#problems + 1] = ("%s: needs `run` (argv) or `preset`"):format(where)
  end
  if raw.run ~= nil and not is_str_list(raw.run) then
    problems[#problems + 1] = ("%s.run: expected a non-empty argv list of strings, got %s"):format(
      where,
      show(raw.run)
    )
  elseif raw.run ~= nil and #raw.run == 0 then
    problems[#problems + 1] = ("%s.run: the argv is empty"):format(where)
  end
  if raw.args ~= nil then
    if not is_str_list(raw.args) then
      problems[#problems + 1] = ("%s.args: expected a list of strings, got %s"):format(
        where,
        show(raw.args)
      )
    elseif not preset then
      problems[#problems + 1] = ("%s.args: only a preset takes `args`"):format(where)
    elseif preset.inprocess then
      for _, a in ipairs(raw.args) do
        local opt = a:match("^(%-%-?[%w%-]+)")
        if opt and M.NO_RUN_OPTIONS[opt] then
          problems[#problems + 1] = ("%s.args: %s runs no %s (the step would read as green)"):format(
            where,
            opt,
            preset.name
          )
        end
      end
    end
  end
  if raw.needs ~= nil and not is_str_list(raw.needs) then
    problems[#problems + 1] = ("%s.needs: expected a list of tool names, got %s"):format(
      where,
      show(raw.needs)
    )
  end
  if raw.env ~= nil then
    local ok_env = type(raw.env) == "table"
    for k, v in pairs(ok_env and raw.env or {}) do
      if type(k) ~= "string" or not k:match("^[%a_][%w_]*$") or type(v) ~= "string" then
        ok_env = false
      end
    end
    -- on Windows the environment ignores case: `Path` and `PATH` would set one variable twice
    local lower = {}
    for k in pairs(ok_env and raw.env or {}) do
      local l = tostring(k):lower()
      if lower[l] then
        problems[#problems + 1] = ("%s.env: %s and %s differ only in case"):format(
          where,
          lower[l],
          k
        )
      end
      lower[l] = k
    end
    if not ok_env then
      problems[#problems + 1] = ('%s.env: expected { NAME = "value" }, got %s'):format(
        where,
        show(raw.env)
      )
    end
  end
  local timeout_ms = M.DEFAULT_TIMEOUT_MS
  if raw.timeout ~= nil and preset and preset.inprocess then
    -- an in-process step cannot be killed; the suite has its own deadlines (`timeouts` of `.testing.lua`)
    problems[#problems + 1] = ("%s.timeout: the in-process preset %s takes no timeout (the suite: `timeouts`)"):format(
      where,
      preset.name
    )
  elseif raw.timeout ~= nil then
    timeout_ms = M.duration(raw.timeout)
    if not timeout_ms then
      problems[#problems + 1] = ('%s.timeout: expected milliseconds or "30s", "2m", got %s'):format(
        where,
        show(raw.timeout)
      )
    end
  end
  local os_set
  if raw.when ~= nil then
    local valid = type(raw.when) == "table" and is_str_list(raw.when.os)
    for k in pairs(type(raw.when) == "table" and raw.when or {}) do
      if k ~= "os" then
        valid = false
      end
    end
    if valid then
      os_set = {}
      for _, name in ipairs(raw.when.os) do
        if name ~= "windows" and name ~= "linux" and name ~= "macos" then
          valid = false
        end
        os_set[name] = true
      end
    end
    if not valid then
      problems[#problems + 1] = ('%s.when: expected { os = { "windows", "linux", "macos" } }, got %s'):format(
        where,
        show(raw.when)
      )
    end
  end
  if
    raw.skip_exit ~= nil
    and (
      type(raw.skip_exit) ~= "number"
      or raw.skip_exit % 1 ~= 0
      or raw.skip_exit < 1
      or raw.skip_exit > 255
      or (preset and preset.inprocess)
    )
  then
    problems[#problems + 1] = ('%s.skip_exit: the exit code 1..255 of a process step that means "skipped", got %s'):format(
      where,
      show(raw.skip_exit)
    )
  end
  if
    raw.stamp ~= nil and (type(raw.stamp) ~= "boolean" or not (preset and preset.name == "suite"))
  then
    problems[#problems + 1] = ("%s.stamp: only the `suite` preset takes stamp = true/false"):format(
      where
    )
  end
  for _, list in ipairs({ raw.run, raw.args }) do
    for _, s in ipairs(type(list) == "table" and list or {}) do
      local bad = type(s) == "string" and bad_placeholder(s)
      if bad then
        problems[#problems + 1] = ("%s: unknown placeholder %s (only ${root} and ${deps.<name>})"):format(
          where,
          bad
        )
      end
    end
  end
  for _, s in pairs(type(raw.env) == "table" and raw.env or {}) do
    local bad = type(s) == "string" and bad_placeholder(s)
    if bad then
      problems[#problems + 1] = ("%s.env: unknown placeholder %s (only ${root} and ${deps.<name>})"):format(
        where,
        bad
      )
    end
  end
  if #problems > before then
    return nil
  end
  return presets.step(step_name, preset, {
    run = raw.run,
    args = raw.args,
    needs = raw.needs,
    env = raw.env,
    timeout_ms = timeout_ms --[[@as integer]],
    os = os_set,
    stamp = raw.stamp,
    skip_exit = raw.skip_exit,
  })
end

---Validate a `ci` section and resolve it into a pipeline.
---@param raw any The value of `ci` in `.testing.lua`.
---@return Testing.Ci.Pipeline|nil pipeline
---@return string[] problems Empty when the pipeline is usable.
function M.resolve(raw)
  local problems = {}
  if type(raw) ~= "table" then
    return nil, { ("ci: expected a table, got %s"):format(show(raw)) }
  end
  for key in pairs(raw) do
    if key ~= "profiles" and key ~= "default" and key ~= "steps" then
      problems[#problems + 1] = ("unknown key 'ci.%s'"):format(tostring(key))
    end
  end
  local raw_steps = raw.steps == nil and {} or raw.steps
  if type(raw_steps) ~= "table" then
    problems[#problems + 1] = ("ci.steps: expected a table, got %s"):format(show(raw_steps))
    raw_steps = {}
  end
  if type(raw.profiles) ~= "table" or next(raw.profiles) == nil then
    problems[#problems + 1] = "ci.profiles: expected a table with at least one profile"
    return nil, problems
  end

  ---@type table<string, Testing.Ci.Step>
  local steps = {}
  local step_names = vim.tbl_keys(raw_steps)
  table.sort(step_names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, name in ipairs(step_names) do
    local def = raw_steps[name]
    if type(name) ~= "string" or not name:match(NAME) then
      problems[#problems + 1] = ("ci.steps: invalid step name %s"):format(show(name))
    elseif raw.profiles[name] ~= nil then
      problems[#problems + 1] = ("ci: %q is both a step and a profile"):format(name)
    elseif type(def) ~= "table" then
      problems[#problems + 1] = ("ci.steps.%s: expected a table, got %s"):format(name, show(def))
    else
      steps[name] = resolve_step(name, def, problems)
    end
  end

  for name, list in pairs(raw.profiles) do
    if type(name) ~= "string" or not name:match(NAME) then
      problems[#problems + 1] = ("ci.profiles: invalid profile name %s"):format(show(name))
    elseif not is_str_list(list) or #list == 0 then
      problems[#problems + 1] = ("ci.profiles.%s: expected a non-empty list of step or profile names, got %s"):format(
        name,
        show(list)
      )
    end
  end
  if #problems > 0 then
    return nil, problems
  end

  -- expand profiles (a profile may include another), with cycle detection
  local expanded = {}
  local function expand(name, stack)
    if expanded[name] then
      return expanded[name]
    end
    if stack[name] then
      problems[#problems + 1] = ("ci.profiles: %q includes itself (cycle)"):format(name)
      return {}
    end
    stack[name] = true
    local out, seen = {}, {}
    for _, item in ipairs(raw.profiles[name]) do
      local names
      if raw.profiles[item] ~= nil then
        names = expand(item, stack)
      elseif steps[item] then
        names = { item }
      elseif presets.get(item) then
        steps[item] = presets.step(item, presets.get(item), { timeout_ms = M.DEFAULT_TIMEOUT_MS })
        names = { item }
      else
        problems[#problems + 1] = ("ci.profiles.%s: %q is neither a profile, a step nor a preset"):format(
          name,
          item
        )
        names = {}
      end
      for _, n in ipairs(names) do
        if not seen[n] then
          seen[n] = true
          out[#out + 1] = n
        end
      end
    end
    stack[name] = nil
    expanded[name] = out
    return out
  end
  local profile_names = vim.tbl_keys(raw.profiles)
  table.sort(profile_names)
  for _, name in ipairs(profile_names) do
    expand(name, {})
  end

  local default = raw.default
  if default == nil then
    default = raw.profiles.full ~= nil and "full"
      or (#profile_names == 1 and profile_names[1] or nil)
    if default == nil then
      problems[#problems + 1] =
        "ci.default: several profiles and no `full`: name the default profile"
    end
  elseif type(default) ~= "string" or raw.profiles[default] == nil then
    problems[#problems + 1] = ("ci.default: %s is not a profile"):format(show(default))
  end
  if #problems > 0 then
    return nil, problems
  end

  local digest_input = { profiles = expanded, steps = {} }
  for name, step in pairs(steps) do
    digest_input.steps[name] = {
      argv = step.argv,
      inprocess = step.inprocess,
      needs = step.needs,
      env = step.env,
      timeout_ms = step.timeout_ms,
      os = step.os,
      stamp = step.stamp,
      skip_exit = step.skip_exit,
    }
  end
  ---@type Testing.Ci.Pipeline
  local pipeline = {
    profiles = expanded,
    default = default --[[@as string]],
    steps = steps,
    digest_input = digest_input,
  }
  return pipeline, problems
end

---Whether a `ci` value passes (the config loader's check; `testing ci` names the problems).
---@param v any
---@return boolean
function M.check(v)
  -- a section without profiles adjusts the derived pipeline: what it means is known only with the repository
  if type(v) == "table" and v.profiles == nil then
    return true
  end
  local pipeline = M.resolve(v)
  return pipeline ~= nil
end

---The keys of a section that adjusts the derived pipeline (no `profiles`).
local DERIVED_KEYS = { skip = true, steps = true, default = true }

---The pipeline of a project: its `ci` section, or the one derived from the repository (`testing.ci.derive`) when the
---section is absent or has no `profiles`. Such a section only adjusts what is derived: `skip` (names to leave out),
---`steps` (a derived step defined anew, or a step of its own, which joins `full`). The one function `testing ci`,
---`ci list`, `ci verify` and `ci hook` read the pipeline through.
---@param root string
---@return Testing.Ci.Pipeline|nil pipeline With `derived` (`step = why`) when it was derived.
---@return string[]|nil problems
function M.load(root)
  local loaded = require("testing.config.project").load(root)
  if loaded.error then
    return nil, { loaded.error }
  end
  local raw = loaded.config.ci
  if raw == nil then
    -- a `ci` that is not a table was dropped by the loader with a warning: say that
    for _, p in ipairs(loaded.problems or {}) do
      if p:find("'ci'", 1, true) then
        return nil, { p }
      end
    end
  end
  if type(raw) == "table" and raw.profiles ~= nil then
    if raw.skip ~= nil then
      return nil,
        { "ci.skip: only a section without `profiles` (a derived pipeline) can leave steps out" }
    end
    return M.resolve(raw)
  end
  raw = raw or {}
  local problems = {}
  for key in pairs(raw) do
    if not DERIVED_KEYS[key] then
      problems[#problems + 1] = ("unknown key 'ci.%s' (a section without `profiles` takes skip, steps, default)"):format(
        tostring(key)
      )
    end
  end
  local section, why = require("testing.ci.derive").section(root, loaded.config)
  if not section then
    problems[#problems + 1] = ("%s/.testing.lua has no `ci` section, and %s (docs/CI.md)"):format(
      root,
      tostring(why)
    )
    return nil, problems
  end
  ---@cast why table<string, string>
  local skip = raw.skip == nil and {} or raw.skip
  if type(skip) ~= "table" or (next(skip) ~= nil and not vim.islist(skip)) then
    problems[#problems + 1] = ("ci.skip: expected a list of step names, got %s"):format(show(skip))
    skip = {}
  end
  local skipped = {}
  for _, name in ipairs(skip) do
    if type(name) ~= "string" or not why[name] then
      problems[#problems + 1] = ("ci.skip: %s is not a derived step (derived: %s)"):format(
        show(name),
        table.concat(vim.tbl_keys(why), ", ")
      )
    else
      skipped[name] = true
    end
  end
  if #problems > 0 then
    return nil, problems
  end
  for name, profile in pairs(section.profiles) do
    section.profiles[name] = vim.tbl_filter(function(n)
      return not skipped[n]
    end, profile)
  end
  if section.profiles.fast and #section.profiles.fast == 0 then
    section.profiles.fast = nil
    section.profiles.full = vim.tbl_filter(function(n)
      return n ~= "fast"
    end, section.profiles.full)
  end
  -- the project's own steps: a derived one defined anew, or a new one that joins `full`
  local own = type(raw.steps) == "table" and raw.steps or {}
  section.steps = own
  local names = vim.tbl_keys(own)
  table.sort(names)
  for _, name in ipairs(names) do
    if not why[name] then
      table.insert(section.profiles.full, name)
    end
  end
  if raw.steps ~= nil and type(raw.steps) ~= "table" then
    section.steps = raw.steps -- resolve names the problem
  end
  if #section.profiles.full == 0 then
    return nil, { "ci.skip leaves nothing to run (write a `ci` section with profiles instead)" }
  end
  if raw.default ~= nil then
    section.default = raw.default
  end
  local pipeline, resolve_problems = M.resolve(section)
  if not pipeline then
    return nil, resolve_problems
  end
  local derived = {}
  for name, reason in pairs(why) do
    if not skipped[name] then
      derived[name] = reason
    end
  end
  pipeline.derived = derived
  return pipeline, resolve_problems
end

return M
