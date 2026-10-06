---@module 'testing.conformance.settings'
---@brief Loads the project configuration for the conformance suite and validates the `conformance` table.
---@description
--- `.testing.lua` is loaded exactly like `testing.config.project.load` does it (same trust: loading
--- executes the file; only from the root the caller chose, as text, below a size limit, never from
--- outside the root), but the raw table is kept: the keys of `conformance` that this suite owns
--- (`gate`, `skip`, `waivers`, `keymaps_off`, `rules_bridge`, `timeout_ms`) are validated HERE, so the
--- suite works whether or not `testing.config.project` knows them yet. A key that is invalid is a
--- problem that names the key, and the default stays (ERR-50, ERR-22); a typo in a check id must not
--- silently skip a check, so an unknown id is a problem too.
---
--- The schema (documented in docs/CONFORMANCE.md):
---
---   conformance = {
---     load_budget_ms = 40,                         -- K10 budget (validated by testing.config.project)
---     gate = false,                                -- true: `testing conformance` exits 1 on a failed check
---     skip = { "K10" },                            -- check ids that do not run
---     waivers = {                                  -- a waiver MUST carry a reason
---       { check = "K4", file = "lua/x/maps.lua", rule = "REL-21", text = "plain text", reason = "why" },
---     },
---     keymaps_off = { keymaps = false },           -- what K3 passes to setup() on top of `setup`
---     timeout_ms = 20000,                          -- timeout of one call into the child editor
---     rules_bridge = { rulesets = { "<path>" }, families = { "NEW", "REL" } },
---   }

local M = {}

---Defaults of the suite's own keys.
---@type Testing.Conformance.Settings
M.DEFAULTS = {
  gate = false,
  skip = {},
  waivers = {},
  load_budget_ms = 40,
  keymaps_off = { keymaps = false },
  timeout_ms = 20000,
  rules_bridge = { families = { "NEW", "REL" } },
}

---Largest accepted `.testing.lua` (same limit as the project loader).
M.MAX_BYTES = 262144

---Shortest accepted waiver reason (characters, trimmed): "ok" is not a reason.
M.MIN_REASON = 8

---Keys of `conformance` this module owns (the project loader's "unknown key" warnings for them are dropped).
---@type table<string, boolean>
local OWN = {
  gate = true,
  skip = true,
  waivers = true,
  keymaps_off = true,
  timeout_ms = true,
  rules_bridge = true,
}

---@param v any
---@return boolean
local function is_string_list(v)
  if type(v) ~= "table" then
    return false
  end
  local n = 0
  for _ in pairs(v) do
    n = n + 1
  end
  if n ~= #v or n > 256 then
    return false
  end
  for _, s in ipairs(v) do
    if type(s) ~= "string" or s == "" or #s > 400 or s:find("\0", 1, true) then
      return false
    end
  end
  return true
end

---Validate the (raw) `conformance` table.
---@param raw any
---@param ids table<string, boolean> Known check ids.
---@param budget? number The validated `load_budget_ms`.
---@return Testing.Conformance.Settings settings
---@return string[] problems
function M.parse(raw, ids, budget)
  local s = vim.deepcopy(M.DEFAULTS)
  local problems = {}
  if budget ~= nil then
    s.load_budget_ms = budget
  end
  if raw == nil then
    return s, problems
  end
  if type(raw) ~= "table" then
    problems[1] = "conformance must be a table; using the defaults"
    return s, problems
  end

  if raw.gate ~= nil then
    if type(raw.gate) == "boolean" then
      s.gate = raw.gate
    else
      problems[#problems + 1] = "conformance.gate must be true or false; using false"
    end
  end

  if raw.skip ~= nil then
    if not is_string_list(raw.skip) then
      problems[#problems + 1] = "conformance.skip must be a list of check ids; skipping nothing"
    else
      for _, id in ipairs(raw.skip) do
        if ids[id] then
          s.skip[#s.skip + 1] = id
        else
          problems[#problems + 1] = ("conformance.skip: unknown check id %q (ignored)"):format(id)
        end
      end
    end
  end

  if raw.waivers ~= nil then
    if type(raw.waivers) ~= "table" then
      problems[#problems + 1] = "conformance.waivers must be a list of tables; no waiver is applied"
    else
      for i, w in ipairs(raw.waivers) do
        local where = ("conformance.waivers[%d]"):format(i)
        local ok, why = true, nil
        if type(w) ~= "table" then
          ok, why = false, "must be a table"
        elseif type(w.check) ~= "string" or not ids[w.check] then
          ok, why =
            false, ("check must be one of the check ids, got %s"):format(vim.inspect(w.check))
        elseif type(w.reason) ~= "string" or #vim.trim(w.reason) < M.MIN_REASON then
          ok, why =
            false,
            ("a waiver needs a reason of at least %d characters (why is this finding accepted?)"):format(
              M.MIN_REASON
            )
        else
          for _, key in ipairs({ "rule", "file", "text" }) do
            if w[key] ~= nil and (type(w[key]) ~= "string" or w[key] == "") then
              ok, why = false, key .. " must be a non-empty string"
              break
            end
          end
        end
        if ok then
          s.waivers[#s.waivers + 1] = {
            check = w.check,
            reason = vim.trim(w.reason),
            rule = w.rule,
            file = w.file and (w.file:gsub("\\", "/")) or nil,
            text = w.text,
          }
        else
          problems[#problems + 1] = ("%s is ignored: %s"):format(where, why)
        end
      end
    end
  end

  if raw.keymaps_off ~= nil then
    if type(raw.keymaps_off) == "table" then
      s.keymaps_off = vim.deepcopy(raw.keymaps_off)
    else
      problems[#problems + 1] = "conformance.keymaps_off must be a table; using { keymaps = false }"
    end
  end

  if raw.timeout_ms ~= nil then
    local t = raw.timeout_ms
    if type(t) == "number" and t == math.floor(t) and t >= 1000 and t <= 600000 then
      s.timeout_ms = t
    else
      problems[#problems + 1] =
        "conformance.timeout_ms must be an integer between 1000 and 600000; using 20000"
    end
  end

  if raw.rules_bridge ~= nil then
    local rb = raw.rules_bridge
    if type(rb) ~= "table" then
      problems[#problems + 1] = "conformance.rules_bridge must be a table; using the defaults"
    else
      if rb.rulesets ~= nil then
        if is_string_list(rb.rulesets) then
          s.rules_bridge.rulesets = vim.deepcopy(rb.rulesets)
        else
          problems[#problems + 1] =
            "conformance.rules_bridge.rulesets must be a list of paths; using none"
        end
      end
      if rb.families ~= nil then
        if is_string_list(rb.families) and #rb.families > 0 then
          s.rules_bridge.families = vim.deepcopy(rb.families)
        else
          problems[#problems + 1] =
            "conformance.rules_bridge.families must be a non-empty list of rule family prefixes; using NEW, REL"
        end
      end
    end
  end

  if (raw.load_budget_ms ~= nil) and budget == nil then
    local b = raw.load_budget_ms
    if type(b) == "number" and b >= 0 then
      s.load_budget_ms = b
    else
      problems[#problems + 1] = "conformance.load_budget_ms must be a number >= 0; using 40"
    end
  end
  return s, problems
end

---@class Testing.Conformance.Loaded
---@field config table Validated project configuration (always usable).
---@field settings Testing.Conformance.Settings
---@field problems string[]
---@field path? string The executed file.
---@field error? string The file could not be used at all.

---Derive the plugin name from a directory name (`sessions.nvim` -> `sessions`).
---@param root string
---@return string
local function derive_plugin(root)
  return (vim.fs.basename(root):gsub("%.nvim$", ""))
end

---Load `<root>/.testing.lua` and the suite's settings. Never raises.
---@param root string Absolute project root.
---@param ids table<string, boolean> Known check ids.
---@return Testing.Conformance.Loaded
function M.load(root, ids)
  local project = require("testing.config.project")
  ---@type Testing.Conformance.Loaded
  local loaded = {
    config = vim.deepcopy(require("testing.config.DEFAULTS").project),
    settings = vim.deepcopy(M.DEFAULTS),
    problems = {},
  }
  loaded.config.plugin = derive_plugin(root)

  local path = vim.fs.normalize(root .. "/" .. project.FILE_NAME)
  local lst = vim.uv.fs_lstat(path)
  local raw
  if lst then
    local ok_sub = lst.type ~= "link"
      or require("lib.nvim.fs.is_subpath")(
        vim.uv.fs_realpath(path) or "",
        vim.uv.fs_realpath(root) or "",
        {}
      )
    local st = vim.uv.fs_stat(path)
    if not st or st.type ~= "file" then
      loaded.error = ("%s is not a regular file"):format(project.FILE_NAME)
    elseif not ok_sub then
      loaded.error = ("%s resolves outside the project root; refusing to execute it"):format(
        project.FILE_NAME
      )
    elseif st.size > M.MAX_BYTES then
      loaded.error = ("%s is larger than %d bytes"):format(project.FILE_NAME, M.MAX_BYTES)
    else
      local chunk, lerr = loadfile(path, "t")
      if not chunk then
        loaded.error = ("cannot load %s: %s"):format(project.FILE_NAME, tostring(lerr))
      else
        local ok, value = pcall(chunk)
        if not ok then
          loaded.error = ("%s raised: %s"):format(project.FILE_NAME, tostring(value))
        elseif type(value) ~= "table" then
          loaded.error = ("%s must return a table"):format(project.FILE_NAME)
        else
          raw = value
          loaded.path = path
        end
      end
    end
  end

  if raw then
    local config, problems = project.validate(raw)
    loaded.config = config
    for _, p in ipairs(problems) do
      -- `conformance.<own key>` is validated below, whatever the project loader knows
      local key = p:match("^unknown key 'conformance%.([%w_]+)")
      if not (key and OWN[key]) then
        loaded.problems[#loaded.problems + 1] = p
      end
    end
    if config.plugin == "" then
      config.plugin = derive_plugin(root)
    end
  end
  local settings, sproblems = M.parse(
    raw and type(raw.conformance) == "table" and raw.conformance or (raw and raw.conformance) or nil,
    ids,
    loaded.config.conformance and loaded.config.conformance.load_budget_ms or nil
  )
  loaded.settings = settings
  for _, p in ipairs(sproblems) do
    loaded.problems[#loaded.problems + 1] = p
  end
  return loaded
end

return M
