---@module 'testing.config.project'
---@brief Loads and validates a project's `.testing.lua`.
---@description
--- SECURITY: `.testing.lua` is a Lua file and loading it EXECUTES it, with the privileges of the
--- editor process. That is the same trust as running the project's own specs (which this tool does
--- anyway), and nothing more: so the file is loaded only
---
---   * from the project root the caller chose (`<root>/.testing.lua`), or from a file given with
---     `--config`, which must lie inside that root once symlinks are resolved (SEC-40);
---   * as text (never as precompiled bytecode) and below a size limit;
---   * never from a path that came out of data (a config file, a spec, a report): `load` takes the
---     root from its caller, and the caller takes it from its own command line.
---
--- The file returns a table. Its keys are validated BEFORE they are merged over the defaults
--- (`DEFAULTS.project`): a key with an invalid value, an unknown key and a malformed group each
--- produce one warning that names the key and the expectation, and the default stays in place
--- (ERR-50, ERR-22). Only a file that cannot be used at all (syntax error, raises, does not return
--- a table, lies outside the root) is an `error`, which the CLI maps to exit code 2.
---
--- Keys: plugin, roots, spec_pattern, dialect, minit, deps, setup, timeouts, shard, watch, budget, assertions (used by the
--- in-process driver), isolated, jobs, host, filetype, env_allow, disable_first_run (used by the child driver and the in-process driver) and the reserved
--- typed tables conformance, coverage, snapshots, backends (validated, not acted upon yet).
---
--- Which key means what (defaults in `testing.config.DEFAULTS`, documented in docs/CONFIG.md):
---   spec_pattern  Lua patterns (against the relative path) that make a file a spec; `{"_spec%.lua$"}`
---   dialect       a name or a table `{ [<path or glob>] = <name>, ["*"] = <name> }`; the names are
---                 "auto", "testing", "a", "b", "c", "d", "h" (the project's own harness), "busted",
---                 "script" (a self-running script, run in its own process)
---   assertions    "error" (a case without assertions fails) or "warn" (it passes with a warning)
---   isolated      "none" (everything in one process), "file" (one child process per spec file),
---                 "case" (one child process per case: busted files; the other dialects run one case
---                 per file and degrade to "file"), "soft" (one process, what a file changed is
---                 restored before the next file, see `testing.isolation`) or "auto" (default):
---                 "file" for busted files, "none" for the others;
---                 `M.isolated_for(config, dialect)` resolves it
---   soft_keep     modules ("name" or "prefix*") that "soft" never unloads
---   guards        { fs, state, scheduled_error, prompt, deprecation, process_net = "off"|"warn"|"error"
---                 or a table { mode = ..., <tuning> } (see docs/GUARDS.md), clock = bool }: the guards
---                 (`testing.guard`; safety nets, not a sandbox)
---   guard_allow   { fs, spawn, network = string[] }: what the guards let through
---   pool          { size = 0..256 (0 = jobs), reuse = bool }: the warm child pool
---   determinism   true (default): children start with a fixed LANG/LC_ALL and TZ
---   trace         true (default): a child that times out or crashes leaves a trace artifact
---   jobs          integer >= 1 or "auto" (cores minus one), parallel child processes of an isolated run
---   shard         { balance = "size"|"count"|"hash"|"history", durations = <relative json path> }: `--shard i/n`
---   affected      { consumers = <directory> }: the checkouts of the projects that use this one (`--consumers`)
---   watch         { debounce_ms, poll_ms }: `--watch`
---   budget        { factor = number >= 1, baseline = <relative json path> }: `testing budget`
---   host          "c" (default: the child starts like plenary's host, `--cmd`/`-c` based, so
---                 `vim.v.vim_did_enter` is 0 while the specs run) or "l" (`nvim -l`)
---   filetype      true (default): the host runs `filetype plugin indent on` like plenary's minimal init
---   disable_first_run  true (default): every editor the runner starts (child or this one) gets
---                 `vim.g.lib_nvim_deps_disable_first_run = true` BEFORE the project's `minit` runs, so
---                 lib.nvim's one-time "missing tools" float never opens in a spec; false = untouched
---   env_allow     environment names (or `PREFIX*`) a child may inherit on top of the built-in
---                 allowlist; `--env-allow` adds to them

local M = {}

---Name of the file in the project root.
M.FILE_NAME = ".testing.lua"

---Largest accepted config file in bytes.
M.MAX_BYTES = 262144

---@alias Testing.Config.Check fun(v: any): boolean

---@class Testing.Config.Leaf
---@field check Testing.Config.Check
---@field expect string What a valid value looks like, for the warning.

---@param v any
---@return boolean
local function is_safe_relpath(v)
  if type(v) ~= "string" or v == "" or #v > 400 or v:find("\0", 1, true) then
    return false
  end
  if v:sub(1, 1) == "/" or v:sub(1, 1) == "\\" or v:match("^%a:") then
    return false
  end
  for seg in v:gsub("\\", "/"):gmatch("[^/]+") do
    if seg == ".." then
      return false
    end
  end
  return true
end

---@param item_check Testing.Config.Check
---@param min_len integer
---@return Testing.Config.Check
local function list_of(item_check, min_len)
  return function(v)
    if type(v) ~= "table" or #v < min_len or #v > 256 then
      return false
    end
    -- a pure sequence: no holes, no extra keys
    local count = 0
    for _ in pairs(v) do
      count = count + 1
    end
    if count ~= #v then
      return false
    end
    for _, item in ipairs(v) do
      if not item_check(item) then
        return false
      end
    end
    return true
  end
end

---@param v any
---@return boolean
local function is_int_gt0(v)
  return type(v) == "number" and v == math.floor(v) and v > 0 and v <= 86400000
end

---@param v any
---@return boolean
local function is_unit(v)
  return type(v) == "number" and v >= 0 and v <= 1
end

---@param v any
---@return boolean
local function is_bool(v)
  return type(v) == "boolean"
end

---@type table<string, true>
local DIALECTS = {
  auto = true,
  testing = true,
  a = true,
  b = true,
  c = true,
  d = true,
  h = true,
  busted = true,
  script = true,
}

---@param v any
---@return boolean
local function is_lua_pattern(v)
  return type(v) == "string" and v ~= "" and #v <= 200 and pcall(string.find, "", v)
end

---@param v any
---@return boolean
local function is_jobs(v)
  return v == "auto" or (type(v) == "number" and v == math.floor(v) and v >= 1 and v <= 256)
end

---@param v any
---@return boolean
local function is_guard_mode(v)
  return v == "off" or v == "warn" or v == "error"
end

---A path, executable or host the guards let through: plain text, no control characters.
---@param v any
---@return boolean
local function is_allow_entry(v)
  return type(v) == "string" and v ~= "" and #v <= 400 and not v:find("%c")
end

---A module name the soft isolation keeps: letters, digits and `_ . -`, optionally ending in `*`.
---@param v any
---@return boolean
local function is_module_pattern(v)
  return type(v) == "string" and #v <= 100 and v:match("^[%w_.%-]+%*?$") ~= nil
end

---A check id of the conformance suite: `K1` .. `K15` (the suite itself reports an id it does not know).
---@param v any
---@return boolean
local function is_check_id(v)
  return type(v) == "string" and v:match("^K%d%d?$") ~= nil
end

---One waiver of `conformance.waivers`: a table naming a check and a reason (the suite validates the rest).
---@param v any
---@return boolean
local function is_waiver(v)
  return type(v) == "table"
    and type(v.check) == "string"
    and is_check_id(v.check)
    and type(v.reason) == "string"
    and #vim.trim(v.reason) >= 8
    and (v.rule == nil or type(v.rule) == "string")
    and (v.file == nil or is_safe_relpath(v.file))
    and (v.text == nil or type(v.text) == "string")
end

---Guard names that take a table (everything but `clock`) and the keys each accepts besides `mode`.
---Every list is checked entry by entry (`is_allow_entry` or a Lua pattern).
---@type table<string, table<string, "list"|"patterns"|"state_modes"|"notify"|"count">>
local GUARD_KEYS = {
  fs = {
    allow = "list",
    allow_patterns = "patterns",
    ignore = "list",
    ignore_patterns = "patterns",
  },
  state = {
    categories = "state_modes",
    keep = "list",
    ignore_groups = "list",
    ignore_vars = "list",
    ignore_options = "list",
    ignore_env = "list",
    ignore_globals = "list",
    ignore_highlights = "list",
    ignore_usercmds = "list",
    ignore_keymaps = "list",
    max_per_category = "count",
  },
  scheduled_error = { allow_patterns = "patterns", notify = "notify" },
  prompt = { getchar_wait_ms = "count" },
  deprecation = {},
  process_net = { allow_exec = "list", allow_hosts = "list" },
}

---Categories of the state guard (the guard layer's own list is the source of truth).
---@return table<string, boolean>
local function state_category_names()
  local ok, gcfg = pcall(require, "testing.guard.config")
  local out = {}
  if ok and type(gcfg) == "table" and gcfg.DEFAULTS then
    for cat in pairs(gcfg.DEFAULTS.guards.state.categories) do
      out[cat] = true
    end
  end
  return out
end

---@param kind string
---@param v any
---@return boolean
local function guard_value_ok(kind, v)
  if kind == "list" then
    return list_of(is_allow_entry, 0)(v)
  elseif kind == "patterns" then
    return list_of(is_lua_pattern, 0)(v)
  elseif kind == "notify" then
    return v == "error" or v == "warn" or v == "info" or v == "off"
  elseif kind == "count" then
    return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 100000
  elseif kind == "state_modes" then
    if type(v) ~= "table" then
      return false
    end
    local known = state_category_names()
    for cat, mode in pairs(v) do
      if
        known[cat] ~= true
        or not (mode == "error" or mode == "warn" or mode == "info" or mode == "off")
      then
        return false
      end
    end
    return true
  end
  return false
end

---A guard section of `.testing.lua`: a bare mode (`state = "warn"`) or a table
---`{ mode = "warn", <keys of GUARD_KEYS[name]> }`; no key may be unknown.
---@param name string
---@return Testing.Config.Leaf
local function guard_section(name)
  local keys = GUARD_KEYS[name]
  local names = vim.tbl_keys(keys)
  table.sort(names)
  return {
    check = function(v)
      if is_guard_mode(v) then
        return true
      end
      if type(v) ~= "table" then
        return false
      end
      for k, val in pairs(v) do
        if k == "mode" then
          if not is_guard_mode(val) then
            return false
          end
        elseif type(k) ~= "string" or keys[k] == nil or not guard_value_ok(keys[k], val) then
          return false
        end
      end
      return true
    end,
    expect = ('"off", "warn" or "error", or a table { mode = ..., %s }'):format(
      #names > 0 and table.concat(names, ", ") .. " = ..." or "(no further keys)"
    ),
  }
end

---Schema: a leaf (`check` + `expect`) or a group of named nodes. Keys of the file that the
---schema does not name are reported as unknown.
---@type table<string, table>
local SCHEMA = {
  plugin = {
    check = function(v)
      return type(v) == "string" and #v <= 100 and v:match("^[%w_.%-]*$") ~= nil
    end,
    expect = 'a module name ("" = derive it from the directory name)',
  },
  roots = {
    check = list_of(is_safe_relpath, 1),
    expect = "a non-empty list of relative paths without '..'",
  },
  spec_pattern = {
    check = list_of(is_lua_pattern, 1),
    expect = 'a non-empty list of Lua patterns, e.g. { "_spec%.lua$" }',
  },
  assertions = {
    check = function(v)
      return v == "error" or v == "warn"
    end,
    expect = '"error" (a case without assertions fails) or "warn" (it passes with a warning)',
  },
  isolated = {
    check = function(v)
      return v == "auto" or v == "none" or v == "file" or v == "case" or v == "soft"
    end,
    expect = '"auto", "none" (one process), "file" (a child process per spec file), "case" (a child process per case, busted files) or "soft" (one process, state restored between files)',
  },
  soft_keep = {
    check = list_of(is_module_pattern, 0),
    expect = 'a list of module names, each optionally ending in "*" (e.g. { "my.plugin.cache", "my.shared*" })',
  },
  guards = {
    fs = guard_section("fs"),
    state = guard_section("state"),
    scheduled_error = guard_section("scheduled_error"),
    prompt = guard_section("prompt"),
    deprecation = guard_section("deprecation"),
    process_net = guard_section("process_net"),
    clock = { check = is_bool, expect = "true or false" },
  },
  guard_allow = {
    fs = {
      check = list_of(is_allow_entry, 0),
      expect = "a list of paths (text without control characters)",
    },
    spawn = {
      check = list_of(is_allow_entry, 0),
      expect = "a list of executable names (text without control characters)",
    },
    network = {
      check = list_of(is_allow_entry, 0),
      expect = "a list of host names (text without control characters)",
    },
  },
  pool = {
    size = {
      check = function(v)
        return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 256
      end,
      expect = "an integer between 0 (= jobs) and 256",
    },
    reuse = { check = is_bool, expect = "true or false" },
  },
  determinism = { check = is_bool, expect = "true or false" },
  trace = { check = is_bool, expect = "true or false" },
  jobs = { check = is_jobs, expect = 'an integer between 1 and 256, or "auto" (cores minus one)' },
  host = {
    check = function(v)
      return v == "c" or v == "l"
    end,
    expect = '"c" (started like plenary: --cmd/-c) or "l" (nvim -l)',
  },
  filetype = { check = is_bool, expect = "true or false" },
  disable_first_run = { check = is_bool, expect = "true or false" },
  env_allow = {
    check = list_of(function(v)
      return (require("testing.child.env").check_entry(v))
    end, 0),
    expect = 'a list of environment names, each optionally ending in "*" (e.g. { "REPOS_DIR", "MAGICK_*" }); names starting with NVIM are refused',
  },
  dialect = {
    check = function(v)
      if type(v) == "table" then
        -- per-file overrides: { ["TESTS/x_spec.lua"] = "c", ["TESTS/hover/**"] = "busted", ["*"] = "a" }
        -- (a literal relative path or a glob: `*` within a segment, `**` across, `?` one character)
        local n = 0
        for k, name in pairs(v) do
          n = n + 1
          if
            type(k) ~= "string"
            or not (k == "*" or is_safe_relpath(k))
            or type(name) ~= "string"
            or DIALECTS[name] ~= true
          then
            return false
          end
        end
        return n > 0
      end
      return type(v) == "string" and DIALECTS[v] == true
    end,
    expect = 'one of "auto", "testing", "a", "b", "c", "d", "h", "busted", "script", or a table { ["<relative spec path or glob>" or "*"] = <one of those> }',
  },
  minit = {
    check = function(v)
      return v == false or is_safe_relpath(v)
    end,
    expect = "false or a relative path without '..'",
  },
  deps = {
    check = list_of(function(v)
      return require("testing.deps").is_valid_name(v)
    end, 0),
    expect = "a list of dependency directory names (letters, digits, . _ -)",
  },
  setup = {
    check = function(v)
      return type(v) == "table"
    end,
    expect = "a table",
  },
  conformance = {
    load_budget_ms = {
      check = function(v)
        return type(v) == "number" and v >= 0
      end,
      expect = "a number >= 0",
    },
    gate = {
      check = is_bool,
      expect = "true or false (true: `testing conformance` exits 1 on a failed check)",
    },
    skip = {
      check = list_of(is_check_id, 0),
      expect = 'a list of check ids ("K1" .. "K15")',
    },
    waivers = {
      check = list_of(is_waiver, 0),
      expect = 'a list of tables { check = "K4", reason = "why" (>= 8 characters), rule?, file?, text? }',
    },
    keymaps_off = {
      check = function(v)
        return type(v) == "table"
      end,
      expect = "a table (what `setup()` is called with on top of `setup` to switch the keymaps off)",
    },
    timeout_ms = {
      check = function(v)
        return type(v) == "number" and v == math.floor(v) and v >= 1000 and v <= 600000
      end,
      expect = "an integer between 1000 and 600000 (milliseconds)",
    },
    rules_bridge = {
      rulesets = { check = list_of(is_allow_entry, 0), expect = "a list of paths" },
      families = {
        check = list_of(is_allow_entry, 1),
        expect = 'a non-empty list of rule family prefixes, e.g. { "NEW", "REL" }',
      },
    },
  },
  surface = {
    track = {
      check = is_bool,
      expect = "true or false (true: the runner counts the handlers the specs exercise)",
    },
    threshold = { check = is_unit, expect = "a number between 0 and 1 (0 = only report)" },
    kinds = {
      check = list_of(function(v)
        return v == "binding" or v == "command" or v == "autocmd" or v == "api"
      end, 1),
      expect = 'a non-empty list of "binding", "command", "autocmd", "api"',
    },
    ignore = {
      check = list_of(is_lua_pattern, 0),
      expect = "a list of Lua patterns that match entry ids",
    },
    setup_chunk = {
      check = function(v)
        return type(v) == "string" and v ~= "" and #v <= 4000
      end,
      expect = "a non-empty string (Lua code the surface is read after)",
    },
  },
  cache = {
    enabled = {
      check = is_bool,
      expect = "true or false (true: reuse results without --cached; ignored in CI)",
    },
  },
  coverage = {
    bindings = { check = is_unit, expect = "a number between 0 and 1" },
    commands = { check = is_unit, expect = "a number between 0 and 1" },
    autocmds = { check = is_unit, expect = "a number between 0 and 1" },
  },
  timeouts = {
    case_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
    file_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
  },
  snapshots = {
    dir = { check = is_safe_relpath, expect = "a relative path without '..'" },
  },
  shard = {
    balance = {
      check = function(v)
        return v == "size" or v == "count" or v == "hash" or v == "history"
      end,
      expect = '"size" (file bytes), "count", "hash" or "history" (measured durations)',
    },
    durations = {
      check = is_safe_relpath,
      expect = 'a relative path without \'..\' to a JSON file { "<spec path>": <ms> } (used by balance = "history")',
    },
  },
  affected = {
    consumers = {
      check = function(v)
        return type(v) == "string" and v ~= "" and #v <= 400 and not v:find("%c")
      end,
      expect = "a directory (absolute, or relative to the project root) with the checkouts of the projects that use this one",
    },
  },
  watch = {
    debounce_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
    poll_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
  },
  budget = {
    factor = {
      check = function(v)
        return type(v) == "number" and v == v and v >= 1 and v <= 1000
      end,
      expect = "a number between 1 and 1000 (a measurement may be this many times its baseline)",
    },
    baseline = { check = is_safe_relpath, expect = "a relative path without '..'" },
  },
  backends = {
    luals = { check = is_bool, expect = "true or false" },
    pty = { check = is_bool, expect = "true or false" },
    playwright = { check = is_bool, expect = "true or false" },
    webdriver = { check = is_bool, expect = "true or false" },
  },
}

---@param node table
---@return boolean
local function is_leaf(node)
  return type(node.check) == "function"
end

---@param v any
---@return string
local function describe(v)
  local t = type(v)
  if t == "string" then
    return ("string %q"):format(#v > 40 and v:sub(1, 40) .. "..." or v)
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return t
end

---@param v any
---@return string
local function short(v)
  local s = vim.inspect(v):gsub("%s+", " ")
  return #s > 60 and s:sub(1, 57) .. "..." or s
end

---Merge `raw` into `out` along `schema`, collecting problems.
---@param raw table
---@param schema table<string, table>
---@param out table Already holds the defaults.
---@param path string Dotted prefix of the keys, "" at the top.
---@param problems string[]
local function apply(raw, schema, out, path, problems)
  local keys = vim.tbl_keys(raw)
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    local full = path .. tostring(key)
    local node = type(key) == "string" and schema[key] or nil
    local value = raw[key]
    if node == nil then
      problems[#problems + 1] = ("unknown key '%s' (ignored)"):format(full)
    elseif is_leaf(node) then
      if node.check(value) then
        out[key] = vim.deepcopy(value)
      else
        problems[#problems + 1] = ("key '%s' is invalid (%s), expected %s; using the default %s"):format(
          full,
          describe(value),
          node.expect,
          short(out[key])
        )
      end
    elseif type(value) == "table" then
      apply(value, node, out[key], full .. ".", problems)
    else
      problems[#problems + 1] = ("key '%s' must be a table, got %s; using the defaults"):format(
        full,
        describe(value)
      )
    end
  end
end

---Validate the table a `.testing.lua` returned and merge its valid keys over the defaults.
---Never raises on bad input.
---@param raw any
---@return Testing.ProjectConfig config Defaults plus the valid keys.
---@return string[] problems
function M.validate(raw)
  local config = vim.deepcopy(require("testing.config.DEFAULTS").project)
  local problems = {}
  if raw == nil then
    return config, problems
  end
  if type(raw) ~= "table" then
    problems[1] = ("the configuration must be a table, got %s; using the defaults"):format(
      describe(raw)
    )
    return config, problems
  end
  apply(raw, SCHEMA, config, "", problems)
  return config, problems
end

---The isolation that applies to a spec file of `dialect`: the explicit `isolated` of the project, and
---for `"auto"` one child process per file for busted specs (plenary ran one nvim per file and busted
---specs were written against that) and the shared process for every other dialect. A `script` is
---always its own process: it ends the process it runs in.
---`"case"` (a child per case) is possible for busted files only, where a case is something the
---runner can pick out (`it`); the other dialects run ONE case per file, so for them `"case"` is
---`"file"` (see `M.degraded_case`). `"soft"` runs in this process like `"none"`; the restore between
---the files is a separate layer (`testing.isolation`), not a process mode.
---@param config Testing.ProjectConfig
---@param dialect string
---@return "none"|"file"|"case" mode
function M.isolated_for(config, dialect)
  if dialect == "script" then
    return "file"
  end
  local mode = config.isolated
  if mode == "file" then
    return "file"
  elseif mode == "case" then
    return dialect == "busted" and "case" or "file"
  elseif mode == "none" or mode == "soft" then
    return "none"
  end
  return dialect == "busted" and "file" or "none"
end

---Does `isolated = "case"` degrade to one child per FILE for this dialect? (Every dialect but busted;
---a `script` is a file in a child anyway and is not reported.)
---@param config Testing.ProjectConfig
---@param dialect string
---@return boolean
function M.degraded_case(config, dialect)
  return config.isolated == "case" and dialect ~= "busted" and dialect ~= "script"
end

---Default `plugin` when the file does not name it.
---@param root string
---@return string
local function derive_plugin(root)
  local base = vim.fs.basename(root)
  return (base:gsub("%.nvim$", ""))
end

---@param file string
---@param root string
---@return boolean
local function inside_root(file, root)
  return require("lib.nvim.fs.is_subpath")(file, root, { realpath = true })
end

---@class Testing.Config.LoadOpts
---@field file? string Explicit config file (`--config`); must lie inside the root.

---Load `<root>/.testing.lua` (or `opts.file`), validate it and return the effective configuration.
---Never raises: every failure ends in `Loaded.error` (file unusable) or `Loaded.problems`.
---@param root string Project root (absolute), from the caller's own command line.
---@param opts? Testing.Config.LoadOpts
---@return Testing.ProjectConfig.Loaded
function M.load(root, opts)
  opts = opts or {}
  ---@type Testing.ProjectConfig.Loaded
  local loaded =
    { config = vim.deepcopy(require("testing.config.DEFAULTS").project), problems = {} }
  loaded.config.plugin = derive_plugin(root)

  local path
  if opts.file then
    path = vim.fs.normalize(vim.fn.fnamemodify(opts.file, ":p"))
  else
    path = vim.fs.normalize(root .. "/" .. M.FILE_NAME)
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    if opts.file then
      loaded.error = ("config file not found: %s"):format(path)
    end
    return loaded
  end
  if stat.type ~= "file" then
    loaded.error = ("config path is not a regular file: %s"):format(path)
    return loaded
  end
  if not inside_root(path, root) then
    loaded.error = ("config file %s resolves outside the project root %s; refusing to execute it"):format(
      path,
      root
    )
    return loaded
  end
  if stat.size > M.MAX_BYTES then
    loaded.error = ("config file %s is larger than %d bytes"):format(path, M.MAX_BYTES)
    return loaded
  end

  local chunk, lerr = loadfile(path, "t")
  if not chunk then
    loaded.error = ("cannot load %s: %s"):format(path, tostring(lerr))
    return loaded
  end
  local ok, raw = pcall(chunk)
  if not ok then
    loaded.error = ("%s raised: %s"):format(path, tostring(raw))
    return loaded
  end
  if type(raw) ~= "table" then
    loaded.error = ("%s must return a table, got %s"):format(path, describe(raw))
    return loaded
  end

  loaded.path = path
  local config, problems = M.validate(raw)
  loaded.problems = problems
  loaded.config = config
  if config.plugin == "" then
    config.plugin = derive_plugin(root)
  end
  return loaded
end

return M
