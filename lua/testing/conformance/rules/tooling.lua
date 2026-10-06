---@module 'testing.conformance.rules.tooling'
---@brief Static rules about the tooling files: `.luarc.json`, `stylua.toml`, `.luacheckrc`.
---@description
--- A rule is `{ id, also?, title, gate, severity, run }`; `run(ctx)` returns a list of items
--- `{ message, file?, line?, level? }` (empty = the rule holds), or `nil, reason` when the rule does not
--- apply. The ids and severities are those of the gates (`NEW_PROJECT.md`); the predicates follow the
--- `check` blocks of the rules where the gate has one, with the corrections the fleet runs of rules.nvim
--- brought (both spellings of `stylua.toml`, busted only where `TESTS/` uses it).

local M = {}

---1-based number of the first line of `lines` that contains `needle` (plain), or 1.
---@param lines string[]
---@param needle string
---@return integer
local function line_of(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then
      return i
    end
  end
  return 1
end

---The `.luarc.json` as a decoded table plus its lines.
---@param ctx Testing.Conformance.Ctx
---@return table|nil decoded
---@return string[]|nil lines
---@return string|nil err `nil, nil, nil` when the file does not exist.
local function luarc(ctx)
  local text = ctx.fs:read(".luarc.json")
  if not text then
    return nil, nil, nil
  end
  local ok, decoded = pcall(vim.json.decode, text)
  local lines = ctx.fs:lines(".luarc.json") or {}
  if not ok then
    return nil, lines, tostring(decoded):sub(1, 120)
  end
  return decoded, lines, nil
end

---Value of a LuaLS setting: the flat spelling (`"workspace.library"`) or the nested one.
---@param decoded table|nil
---@param dotted string
---@return any
local function setting(decoded, dotted)
  if type(decoded) ~= "table" then
    return nil
  end
  if decoded[dotted] ~= nil then
    return decoded[dotted]
  end
  local node = decoded
  for seg in dotted:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[seg]
  end
  return node
end

---@type table[]
M.rules = {
  {
    id = "NEW-03",
    title = ".luarc.json exists",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      if not ctx.fs:is_file(".luarc.json") then
        return { { message = ".luarc.json is missing", file = ".luarc.json" } }
      end
      return {}
    end,
  },
  {
    id = "NEW-36",
    also = { "LLS-01" },
    title = ".luarc.json does not set workspace.library",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local decoded, lines, err = luarc(ctx)
      if not lines then
        return nil, "no .luarc.json (NEW-03)"
      end
      if err then
        return nil, ".luarc.json is not valid JSON (NEW-50)"
      end
      if setting(decoded, "workspace.library") ~= nil then
        return {
          {
            message = "workspace.library replaces LuaLS' own library injection: vim and every other plugin become unknown",
            file = ".luarc.json",
            line = line_of(lines, "library"),
          },
        }
      end
      return {}
    end,
  },
  {
    id = "NEW-37",
    also = { "LLS-03" },
    title = "workspace.ignoreDir excludes the directories that can hold a copy of the code",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local decoded, lines, err = luarc(ctx)
      if not lines then
        return nil, "no .luarc.json (NEW-03)"
      end
      if err then
        return nil, ".luarc.json is not valid JSON (NEW-50)"
      end
      local ignored = setting(decoded, "workspace.ignoreDir")
      local covered = {}
      for _, entry in ipairs(type(ignored) == "table" and ignored or {}) do
        if type(entry) == "string" then
          local name = entry:gsub("\\", "/"):gsub("^%./", ""):gsub("^%*%*/", ""):gsub("/+$", "")
          covered[name] = true
        end
      end
      local items = {}
      for _, dir in ipairs({ ".claude", ".deps" }) do
        if ctx.fs:is_dir(dir) and not covered[dir] then
          items[#items + 1] = {
            message = ("workspace.ignoreDir does not list %s/, which exists here and can hold a copy of this code"):format(
              dir
            ),
            file = ".luarc.json",
            line = line_of(lines, "ignoreDir"),
          }
        end
      end
      return items
    end,
  },
  {
    id = "NEW-38",
    title = "diagnostics.globals does not list vim",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local decoded, lines, err = luarc(ctx)
      if not lines then
        return nil, "no .luarc.json (NEW-03)"
      end
      if err then
        return nil, ".luarc.json is not valid JSON (NEW-50)"
      end
      local globals = setting(decoded, "diagnostics.globals")
      for _, g in ipairs(type(globals) == "table" and globals or {}) do
        if g == "vim" then
          return {
            {
              message = "diagnostics.globals lists vim: it turns the typed `vim` into `any`",
              file = ".luarc.json",
              line = line_of(lines, '"vim"'),
            },
          }
        end
      end
      return {}
    end,
  },
  {
    id = "NEW-50",
    title = ".luarc.json is strict JSON",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local _, lines, err = luarc(ctx)
      if not lines then
        return nil, "no .luarc.json (NEW-03)"
      end
      if err then
        return { { message = "not strict JSON: " .. err, file = ".luarc.json", line = 1 } }
      end
      return {}
    end,
  },
  {
    id = "NEW-45",
    title = "stylua.toml exists and its line_endings match .gitattributes",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local rel
      for _, candidate in ipairs({ "stylua.toml", ".stylua.toml" }) do
        if ctx.fs:is_file(candidate) then
          rel = candidate
          break
        end
      end
      if not rel then
        return {
          { message = "no stylua.toml (stylua would format with tabs)", file = "stylua.toml" },
        }
      end
      local attributes = ctx.fs:read(".gitattributes")
      if not attributes then
        return {}
      end
      local want
      if attributes:find("eol%s*=%s*lf") then
        want = "Unix"
      elseif attributes:find("eol%s*=%s*crlf") then
        want = "Windows"
      end
      if not want then
        return {}
      end
      local lines = ctx.fs:lines(rel) or {}
      local text = table.concat(lines, "\n")
      local have = text:match("line_endings%s*=%s*[\"'](%a+)[\"']")
      if have ~= want then
        return {
          {
            message = ("line_endings is %s, .gitattributes sets eol=%s (a Linux runner reports every file as unformatted)"):format(
              have and ('"' .. have .. '"') or "not set",
              want == "Unix" and "lf" or "crlf"
            ),
            file = rel,
            line = have and line_of(lines, "line_endings") or 1,
          },
        }
      end
      return {}
    end,
  },
  {
    id = "NEW-49",
    title = ".luacheckrc declares the busted std where TESTS/ uses busted",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      local text = ctx.fs:read(".luacheckrc")
      if not text then
        return { { message = ".luacheckrc is missing", file = ".luacheckrc" } }
      end
      local uses_busted = false
      for _, src in ipairs(ctx.sources("TESTS")) do
        for _, line in ipairs(src.lines) do
          if line:match("^%s*describe%(") or line:match("^%s*it%(") then
            uses_busted = true
            break
          end
        end
        if uses_busted then
          break
        end
      end
      if not uses_busted then
        return {}
      end
      if text:find("exclude_files", 1, true) and text:find("TESTS", 1, true) then
        return {}
      end
      if not text:find("busted", 1, true) then
        return {
          {
            message = "no busted std declared, and TESTS/ uses describe/it",
            file = ".luacheckrc",
            line = 1,
          },
        }
      end
      return {}
    end,
  },
}

return M
