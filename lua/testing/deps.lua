---@module 'testing.deps'
---@brief Dependency resolution (NEW-40): four places, in a fixed order, and ALL four named on failure.
---@description
--- A dependency `<name>` (e.g. `lib.nvim`, `testing.nvim`) is looked up in
---
---   1. `$<NAME>_DIR`                  (`lib.nvim` -> `$LIB_NVIM_DIR`; every character outside
---                                      A-Z0-9 becomes `_`, then `_DIR` is appended)
---   2. `<base>/.deps/<name>`          (what CI checks out)
---   3. `<base>/../<name>`             (a sibling checkout)
---   4. `stdpath('data')/lazy/<name>`  (what a plugin manager installed)
---
--- `<base>` is the project root of the caller (for the runner's own dependency `lib.nvim`: the
--- testing.nvim checkout). The first place that holds a valid checkout wins. An explicit override
--- (place 1) that is set but not valid is a FAILURE, not a reason to fall through to another
--- checkout: an override that is silently ignored is a lie about which code ran.
---
--- This module must work before `lib.nvim` is on the runtimepath (it is what puts it there), so it
--- uses plain `vim.*` only. The environment and the data directory can be injected for specs.
---
--- A caller that cannot continue without the dependency reports `format_failure` and exits 3.

local M = {}

---@class Testing.Deps.Opts
---@field getenv? fun(name: string): string|nil Environment lookup (default `vim.uv.os_getenv`).
---@field data_dir? string Replaces `stdpath('data')` (specs).
---@field marker? string Path below the checkout that must exist (default: `lua/lib/nvim` for lib.nvim, `lua/testing` for testing.nvim, else `lua`).

---@class Testing.Deps.Location
---@field label string e.g. `$LIB_NVIM_DIR`
---@field path? string Absolute path, nil when an environment variable is unset.
---@field status "ok"|"unset"|"missing"|"invalid" `invalid`: a directory without the marker.

---@class Testing.Deps.Resolved
---@field name string
---@field dir string Absolute directory of the checkout.
---@field source string Label of the place that matched.
---@field locations Testing.Deps.Location[] All four places with their state.

---@type table<string, string>
local MARKERS = {
  ["lib.nvim"] = "lua/lib/nvim",
  ["testing.nvim"] = "lua/testing",
}

---A dependency name is a directory name: no separators, no `..`, no shell or glob characters.
---@param name any
---@return boolean
function M.is_valid_name(name)
  return type(name) == "string"
    and #name <= 100
    and name:match("^[%w][%w._%-]*$") ~= nil
    and not name:find("..", 1, true)
end

---Environment variable that overrides `<name>`: `lib.nvim` -> `LIB_NVIM_DIR`.
---@param name string
---@return string
function M.env_name(name)
  return (name:upper():gsub("[^%w]", "_")) .. "_DIR"
end

---@param s string
---@return string
local function norm(s)
  return vim.fs.normalize(vim.fn.fnamemodify(s, ":p")):gsub("/+$", "")
end

---@param path string
---@return string|nil
local function dir_state(path, marker)
  if vim.fn.isdirectory(path) ~= 1 then
    return "missing"
  end
  if vim.fn.isdirectory(path .. "/" .. marker) ~= 1 then
    return "invalid"
  end
  return "ok"
end

---The four places for `name`, in order, with the state of each.
---@param name string
---@param base string Project root (see the module header).
---@param opts? Testing.Deps.Opts
---@return Testing.Deps.Location[]
function M.locations(name, base, opts)
  opts = opts or {}
  local getenv = opts.getenv or vim.uv.os_getenv
  local marker = opts.marker or MARKERS[name] or "lua"
  local data = opts.data_dir or vim.fn.stdpath("data")
  local base_abs = norm(base)

  local env_label = "$" .. M.env_name(name)
  local env_val = getenv(M.env_name(name))
  ---@type Testing.Deps.Location[]
  local locs = {}
  if env_val == nil or env_val == "" then
    locs[1] = { label = env_label, status = "unset" }
  else
    local p = norm(env_val)
    locs[1] = { label = env_label, path = p, status = dir_state(p, marker) }
  end
  local others = {
    { (".deps/%s"):format(name), base_abs .. "/.deps/" .. name },
    { ("../%s"):format(name), vim.fs.dirname(base_abs) .. "/" .. name },
    { ("stdpath('data')/lazy/%s"):format(name), norm(data) .. "/lazy/" .. name },
  }
  for _, o in ipairs(others) do
    locs[#locs + 1] = { label = o[1], path = o[2], status = dir_state(o[2], marker) }
  end
  return locs
end

---Message that names all four places and what was found at each.
---@param name string
---@param locations Testing.Deps.Location[]
---@return string
function M.format_failure(name, locations)
  local why = {
    unset = "unset",
    missing = "not a directory",
    invalid = "a directory, but not a %s checkout",
    ok = "ok",
  }
  local lines = { ("testing: dependency '%s' not found. Searched, in this order:"):format(name) }
  for i, loc in ipairs(locations) do
    local state = why[loc.status]:format(name)
    if loc.path then
      lines[#lines + 1] = ("  %d. %s  (%s: %s)"):format(i, loc.label, loc.path, state)
    else
      lines[#lines + 1] = ("  %d. %s  (%s)"):format(i, loc.label, state)
    end
  end
  lines[#lines + 1] = ("Set %s, or clone it to .deps/%s, or place it beside the project, or install it with your plugin manager."):format(
    locations[1].label,
    name
  )
  if locations[1].status == "missing" or locations[1].status == "invalid" then
    lines[#lines + 1] = ("%s is set but does not point to a valid checkout; an override is never skipped."):format(
      locations[1].label
    )
  end
  return table.concat(lines, "\n")
end

---Resolve one dependency.
---@param name string
---@param base string
---@param opts? Testing.Deps.Opts
---@return Testing.Deps.Resolved|nil resolved
---@return string|nil message Names all four places; set when `resolved` is nil.
function M.resolve(name, base, opts)
  if not M.is_valid_name(name) then
    return nil, ("testing: invalid dependency name %s"):format(vim.inspect(name))
  end
  local locs = M.locations(name, base, opts)
  -- An explicit override decides alone.
  if locs[1].status ~= "unset" then
    if locs[1].status == "ok" then
      return { name = name, dir = locs[1].path, source = locs[1].label, locations = locs }
    end
    return nil, M.format_failure(name, locs)
  end
  for i = 2, #locs do
    if locs[i].status == "ok" then
      return { name = name, dir = locs[i].path, source = locs[i].label, locations = locs }
    end
  end
  return nil, M.format_failure(name, locs)
end

---Resolve several dependencies; never stops at the first failure so that one run reports all.
---@param names string[]
---@param base string
---@param opts? Testing.Deps.Opts
---@return Testing.Deps.Resolved[] resolved
---@return string[] failures One `format_failure` message per dependency that was not found.
function M.resolve_all(names, base, opts)
  local resolved, failures = {}, {}
  for _, name in ipairs(names) do
    local r, msg = M.resolve(name, base, opts)
    if r then
      resolved[#resolved + 1] = r
    else
      failures[#failures + 1] = msg
    end
  end
  return resolved, failures
end

---Checkout of testing.nvim that this very file belongs to.
---@return string
function M.self_dir()
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))
end

---Add a resolved checkout to the runtimepath unless it is on it already.
---@param dir string
---@param prepend? boolean
function M.add_to_rtp(dir, prepend)
  local want = norm(dir):lower()
  for _, p in ipairs(vim.opt.rtp:get()) do
    if norm(p):lower() == want then
      return
    end
  end
  if prepend then
    vim.opt.rtp:prepend(dir)
  else
    vim.opt.rtp:append(dir)
  end
end

---Report for `testing doctor` and `:checkhealth`: one entry per name, found or not.
---@param names string[]
---@param base string
---@param opts? Testing.Deps.Opts
---@return { name: string, ok: boolean, dir?: string, source?: string, message?: string }[]
function M.report(names, base, opts)
  local rows = {}
  for _, name in ipairs(names) do
    local r, msg = M.resolve(name, base, opts)
    if r then
      rows[#rows + 1] = { name = name, ok = true, dir = r.dir, source = r.source }
    else
      rows[#rows + 1] = { name = name, ok = false, message = msg }
    end
  end
  return rows
end

return M
