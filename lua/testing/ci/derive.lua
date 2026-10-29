---@module 'testing.ci.derive'
---@brief The pipeline of a Lua project that has no `ci` profiles of its own: derived from what the repository has.
---@description
--- A Lua project (a `lua/` folder) gets the usual checks without writing them down:
---
---   * `stylua`      when there is a `stylua.toml` or `.stylua.toml`;
---   * `luacheck`    when there is a `.luacheckrc` (its own `include_files`/`exclude_files` decide what is read);
---   * `suite`       when discovery finds a spec file (`roots` and `spec_pattern` of `.testing.lua`, default `TESTS`);
---   * `conformance` when `.testing.lua` makes the conformance suite a gate (`conformance.gate = true`).
---
--- Profiles: `fast` (stylua and luacheck, the pre-push check) and `full` (everything), `full` is the default. What
--- was derived and why is part of the pipeline (`derived`), so `testing ci list` and the document can say so.
--- Everything here reads the file system only (discovery for the specs): the same files give the same steps on every
--- machine.

local M = {}

---@param root string
---@param rel string
---@return string|nil kind `file`, `directory`, nil when absent
local function kind(root, rel)
  local st = vim.uv.fs_stat(root .. "/" .. rel)
  return st and st.type or nil
end

---Does the project have specs? Asked of discovery itself, so the suite step exists exactly when `testing run` would
---find something to run (patterns match the relative path, `TESTS/` and `tests/` agree on every system).
---@param root string
---@param project table
---@return string|nil first The relative path of a spec; a note when discovery failed (the suite then fails loudly).
local function first_spec(root, project)
  local ok, found = pcall(require("testing.discover").discover, root, {
    roots = project.roots,
    spec_pattern = project.spec_pattern,
  })
  if not ok then
    return "(spec discovery failed: " .. tostring(found) .. ")"
  end
  return found.files[1] and found.files[1].rel or nil
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
  local spec = first_spec(root, project)
  if spec then
    rest[#rest + 1] = "suite"
    why.suite = ("spec files, e.g. %s"):format(spec)
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
