---@module 'testing.config'
---@brief Holds, validates and merges the active `Testing.Config`.
---@description
--- `setup(opts)` builds the configuration from `testing.config.DEFAULTS` plus the valid keys of
--- `opts`. A key with the wrong type, and any unknown key, is dropped and reported back to the caller
--- instead of silently replacing a good default. Nothing here touches the editor.

local DEFAULTS = require("testing.config.DEFAULTS")

local M = {}

--- `DEFAULTS` carries the project defaults (`project`) as well, which `setup()` does not take: the keys a
--- user may set are `CHECKS` below, so the problems are found there and only the valid part reaches the
--- config object, which keeps the merge, `get()` and `reset()` the same as in every other plugin.
local cfg = require("lib.lua.config").new(DEFAULTS, {
  name = "testing",
  schema = { keymaps = "table|false", ci = "table", hover = "table", surface_view = "table" },
})

---The actions of the matrix view whose key `surface_view.keys` sets (`testing.surface.view`).
---@type table<string, true>
local VIEW_ACTIONS = { jump = true, status = true, kind = true, export = true }

---Per-key type check; the single source of truth for which keys exist.
---@type table<string, fun(v: any): boolean>
local CHECKS = {
  notify_prefix = function(v)
    return type(v) == "string" and v ~= ""
  end,
  keymaps = function(v)
    return v == false or type(v) == "table"
  end,
  hover = function(v)
    if type(v) ~= "table" then
      return false
    end
    for _, key in ipairs({ "max_width", "max_height", "max_diff_lines" }) do
      local n = v[key]
      if n ~= nil and (type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > 1000) then
        return false
      end
    end
    return true
  end,
  surface_view = function(v)
    if type(v) ~= "table" then
      return false
    end
    for key in pairs(v) do
      if key ~= "keys" then
        return false
      end
    end
    if v.keys == nil then
      return true
    end
    if type(v.keys) ~= "table" then
      return false
    end
    for action, lhs in pairs(v.keys) do
      if not VIEW_ACTIONS[action] then
        return false
      end
      if lhs ~= false and (type(lhs) ~= "string" or lhs == "") then
        return false
      end
    end
    -- the keys as they will be bound (defaults plus these) must not collide with each other or with the
    -- viewer's own `?`, `q` and `<Esc>` (bound after the actions, so they would silently win)
    local seen = {}
    for _, reserved in ipairs({ "?", "q", "<Esc>" }) do
      seen[vim.api.nvim_replace_termcodes(reserved, true, true, true)] = true
    end
    for action in pairs(VIEW_ACTIONS) do
      local lhs = v.keys[action]
      if lhs == nil then
        lhs = DEFAULTS.surface_view.keys[action]
      end
      if type(lhs) == "string" then
        local code = vim.api.nvim_replace_termcodes(lhs, true, true, true)
        if seen[code] then
          return false
        end
        seen[code] = true
      end
    end
    return true
  end,
  ci = function(v)
    if type(v) ~= "table" then
      return false
    end
    local repos = v.repos
    if repos == nil then
      return true
    end
    if type(repos) ~= "table" then
      return false
    end
    for _, list in ipairs({ "roots", "include", "exclude" }) do
      local items = repos[list]
      if items ~= nil then
        if type(items) ~= "table" then
          return false
        end
        for _, item in ipairs(items) do
          if type(item) ~= "string" or item == "" then
            return false
          end
        end
      end
    end
    return true
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
  cfg.setup(valid)
  return problems
end

---The effective configuration.
---@return Testing.Config
function M.get()
  return cfg.get()
end

---Back to the plugin defaults.
---@return nil
function M.reset()
  cfg.reset()
end

return M
