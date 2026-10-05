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
--- Keys: plugin, roots, dialect, minit, deps, setup, timeouts (used by M1) and the reserved typed
--- tables conformance, coverage, snapshots, backends (validated, not acted upon yet).

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
local DIALECTS =
  { auto = true, testing = true, a = true, b = true, c = true, d = true, busted = true }

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
  dialect = {
    check = function(v)
      if type(v) == "table" then
        -- per-file overrides: { ["TESTS/x_spec.lua"] = "c", ["*"] = "a" } (literal relative paths)
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
    expect = 'one of "auto", "testing", "a", "b", "c", "d", "busted", or a table { ["<relative spec path>" or "*"] = <one of those> }',
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
  },
  coverage = {
    bindings = { check = is_unit, expect = "a number between 0 and 1" },
    commands = { check = is_unit, expect = "a number between 0 and 1" },
  },
  timeouts = {
    case_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
    file_ms = { check = is_int_gt0, expect = "a positive integer (milliseconds)" },
  },
  snapshots = {
    dir = { check = is_safe_relpath, expect = "a relative path without '..'" },
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
