---@module 'testing.ci.derive'
---@brief The pipeline of a Lua project that has no `ci` profiles of its own: derived from what the repository has.
---@description
--- A Lua project (a `lua/` folder) gets the usual checks without writing them down:
---
---   * `stylua`      when there is a `stylua.toml` or `.stylua.toml`;
---   * `luacheck`    when there is a `.luacheckrc` (its own `files`/`exclude_files` decide what is read);
---   * `suite`       when a spec root of `.testing.lua` (`roots`, default `TESTS`) holds a spec file;
---   * `conformance` when `.testing.lua` makes the conformance suite a gate (`conformance.gate = true`).
---
--- Profiles: `fast` (stylua and luacheck, the pre-push check) and `full` (everything), `full` is the default. What
--- was derived and why is part of the pipeline (`derived`), so `testing ci list` and the document can say so.
--- Everything here reads the file system only: the same files give the same steps on every machine.

local M = {}

---@param root string
---@param rel string
---@return string|nil kind `file`, `directory`, nil when absent
local function kind(root, rel)
  local st = vim.uv.fs_stat(root .. "/" .. rel)
  return st and st.type or nil
end

---Is there a spec file below one of the spec roots?
---@param root string
---@param roots string[]
---@param patterns string[]
---@return string|nil found The spec root that has one.
local function spec_root(root, roots, patterns)
  for _, r in ipairs(roots) do
    if kind(root, r) == "directory" then
      local hit = vim.fs.find(function(name)
        for _, p in ipairs(patterns) do
          if name:match(p) then
            return true
          end
        end
        return false
      end, { path = root .. "/" .. r, type = "file", limit = 1 })
      if #hit > 0 then
        return r
      end
    end
  end
  return nil
end

---The derived `ci` section of a project, before the project's own `skip` and `steps` are applied.
---@param root string
---@param project table The configuration of `.testing.lua` (`roots`, `spec_pattern`, `conformance`).
---@return table|nil section `{ default, profiles }`, nil when nothing can be derived
---@return table<string, string>|string why The reason of each derived step, or why nothing was derived.
function M.section(root, project)
  if kind(root, "lua") ~= "directory" then
    return nil, "not a Lua project (no lua/ folder), so nothing is derived"
  end
  local why = {}
  local fast, rest = {}, {}
  if kind(root, "stylua.toml") == "file" or kind(root, ".stylua.toml") == "file" then
    fast[#fast + 1] = "stylua"
    why.stylua = kind(root, "stylua.toml") == "file" and "stylua.toml" or ".stylua.toml"
  end
  if kind(root, ".luacheckrc") == "file" then
    fast[#fast + 1] = "luacheck"
    why.luacheck = ".luacheckrc"
  end
  local roots = type(project.roots) == "table" and project.roots or { "TESTS" }
  local patterns = type(project.spec_pattern) == "table" and project.spec_pattern
    or { "_spec%.lua$" }
  local specs = spec_root(root, roots, patterns)
  if specs then
    rest[#rest + 1] = "suite"
    why.suite = ("spec files below %s/"):format(specs)
  end
  local conformance = type(project.conformance) == "table" and project.conformance or {}
  if conformance.gate == true then
    rest[#rest + 1] = "conformance"
    why.conformance = "conformance.gate = true"
  end
  if #fast == 0 and #rest == 0 then
    return nil,
      "a Lua project without stylua.toml, .luacheckrc or spec files: nothing to derive (write a `ci` section)"
  end
  local profiles = {}
  local full = {}
  if #fast > 0 then
    profiles.fast = fast
    full[1] = "fast"
  end
  vim.list_extend(full, rest)
  profiles.full = full
  return { default = "full", profiles = profiles }, why
end

return M
