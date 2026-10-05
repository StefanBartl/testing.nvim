---@module 'testing.config'
---@brief Holds, validates and merges the active `Testing.Config`.
---@description
--- `setup(opts)` builds the configuration from `testing.config.DEFAULTS` plus the valid keys of
--- `opts`. A key with the wrong type, and any unknown key, is dropped and reported back to the caller
--- instead of silently replacing a good default. Nothing here touches the editor.

local DEFAULTS = require("testing.config.DEFAULTS")

local M = {}

---@type Testing.Config
local cfg = vim.deepcopy(DEFAULTS)

---Per-key type check; the single source of truth for which keys exist.
---@type table<string, fun(v: any): boolean>
local CHECKS = {
  notify_prefix = function(v)
    return type(v) == "string" and v ~= ""
  end,
  keymaps = function(v)
    return v == false or type(v) == "table"
  end,
}

---Split user options into the valid part and a list of human-readable problems.
---@param opts any
---@return Testing.ConfigOptions valid
---@return string[] problems
function M.validate(opts)
  local valid, problems = {}, {}
  if opts == nil then
    return valid, problems
  end
  if type(opts) ~= "table" then
    problems[1] = ("options must be a table, got %s"):format(type(opts))
    return valid, problems
  end
  local names = vim.tbl_keys(opts)
  table.sort(names, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(names) do
    local check = CHECKS[key]
    if not check then
      problems[#problems + 1] = ("unknown option '%s'"):format(tostring(key))
    elseif check(opts[key]) then
      valid[key] = opts[key]
    else
      problems[#problems + 1] = ("option '%s' has an invalid value (%s)"):format(
        key,
        type(opts[key])
      )
    end
  end
  return valid, problems
end

---Rebuild the active configuration: defaults first, the valid user options on top.
---@param opts? Testing.ConfigOptions
---@return string[] problems Options that were dropped, empty when everything was accepted.
function M.setup(opts)
  local valid, problems = M.validate(opts)
  cfg = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), valid)
  return problems
end

---The effective configuration.
---@return Testing.Config
function M.get()
  return cfg
end

---Back to the plugin defaults.
---@return nil
function M.reset()
  cfg = vim.deepcopy(DEFAULTS)
end

return M
