---@module 'testing.conformance.rules.layout'
---@brief Static rules about the repository layout: required files and folders, where tests live, README sections.

local M = {}

---Names of the entries of `rel` that are directories (exact spelling).
---@param ctx Testing.Conformance.Ctx
---@param rel string
---@return string[]
local function subdirs(ctx, rel)
  local out = {}
  for _, e in ipairs(ctx.fs:list(rel)) do
    if e.type == "directory" then
      out[#out + 1] = e.name
    end
  end
  return out
end

---The module roots below `lua/`: the plugin first, every other directory after it.
---@param ctx Testing.Conformance.Ctx
---@return string[]
local function module_roots(ctx)
  local out = {}
  if ctx.plugin and ctx.fs:is_dir("lua/" .. ctx.plugin) then
    out[1] = ctx.plugin
  end
  for _, name in ipairs(subdirs(ctx, "lua")) do
    if name ~= ctx.plugin then
      out[#out + 1] = name
    end
  end
  return out
end

---Is there a Lua file named `<name>` or a directory `<name>/` holding Lua files below `bindings/`?
---@param ctx Testing.Conformance.Ctx
---@param bindings string
---@param names string[]
---@return boolean
local function has_binding(ctx, bindings, names)
  for _, name in ipairs(names) do
    if ctx.fs:is_file(bindings .. "/" .. name .. ".lua") then
      return true
    end
    for _, e in ipairs(ctx.fs:list(bindings .. "/" .. name)) do
      if e.type == "file" and e.name:match("%.lua$") then
        return true
      end
    end
  end
  return false
end

---The headings (`## Text`) of the README with their line numbers.
---@param ctx Testing.Conformance.Ctx
---@return { text: string, line: integer }[]|nil
local function readme_headings(ctx)
  local lines = ctx.fs:lines("README.md")
  if not lines then
    return nil
  end
  local out, fenced = {}, false
  for i, line in ipairs(lines) do
    if line:match("^%s*```") then
      fenced = not fenced
    elseif not fenced then
      local hashes, text = line:match("^(#+)%s+(.-)%s*#*%s*$")
      if hashes and #hashes <= 3 then
        out[#out + 1] = { text = text, line = i }
      end
    end
  end
  return out
end

---@type table[]
M.rules = {
  {
    id = "NEW-39",
    title = "TESTS/ with minimal_init.lua and scripts/test.sh",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      local items = {}
      local root_names = {}
      for _, e in ipairs(ctx.fs:list(".")) do
        root_names[e.name] = e.type
      end
      if root_names["TESTS"] ~= "directory" then
        items[#items + 1] =
          { message = "no TESTS/ directory in the repository root", file = "TESTS" }
      elseif not ctx.fs:is_file("TESTS/minimal_init.lua") then
        items[#items + 1] =
          { message = "TESTS/minimal_init.lua is missing", file = "TESTS/minimal_init.lua" }
      end
      if not ctx.fs:is_file("scripts/test.sh") then
        items[#items + 1] =
          { message = "scripts/test.sh (the runner) is missing", file = "scripts/test.sh" }
      end
      return items
    end,
  },
  {
    id = "NEW-48",
    title = "test files never live under lua/<plugin>/ or in tests/, test/, docs/TESTS",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      local items = {}
      for _, src in ipairs(ctx.sources("lua")) do
        if src.rel:match("_spec%.lua$") then
          local text = src.text
          -- "*_spec.lua" is ambiguous in this ecosystem: a lazy.nvim plugin spec has the name too, and so does
          -- a generator's template ("${" is never valid Lua). Only describe/it at the start of a line
          -- marks a real test.
          local template = text:find("${", 1, true) ~= nil
          local busted = false
          for _, line in ipairs(src.lines) do
            if line:match("^%s*describe%(") or line:match("^%s*it%(") then
              busted = true
              break
            end
          end
          if busted and not template then
            items[#items + 1] =
              { message = "a spec file ships with the runtime tree", file = src.rel, line = 1 }
          end
        end
      end
      local top = {}
      for _, e in ipairs(ctx.fs:list(".")) do
        top[e.name] = e.type
      end
      for _, dir in ipairs({ "tests", "test", "spec" }) do
        if top[dir] == "directory" and #ctx.fs:walk(dir, { ext = "lua", limit = 1 }) > 0 then
          items[#items + 1] = {
            message = ("%s/ holds Lua files: tests live in TESTS/ (NEW-48)"):format(dir),
            file = dir,
          }
        end
      end
      if ctx.fs:is_dir("docs") then
        for _, e in ipairs(ctx.fs:list("docs")) do
          if e.type == "directory" and e.name == "TESTS" then
            items[#items + 1] =
              { message = "docs/TESTS exists: tests live in TESTS/ (NEW-48)", file = "docs/TESTS" }
          end
        end
      end
      return items
    end,
  },
  {
    id = "NEW-06",
    title = "LICENSE exists",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      for _, name in ipairs({ "LICENSE", "LICENSE.md", "LICENSE.txt" }) do
        if ctx.fs:is_file(name) then
          return {}
        end
      end
      return { { message = "no LICENSE file", file = "LICENSE" } }
    end,
  },
  {
    id = "REL-28",
    title = "the LICENSE is MIT and the README has a License section",
    gate = "RELEASE",
    severity = "recommended",
    run = function(ctx)
      local items = {}
      for _, name in ipairs({ "LICENSE", "LICENSE.md", "LICENSE.txt" }) do
        local text = ctx.fs:read(name)
        if text then
          if
            not (
              text:find("MIT License", 1, true)
              or text:find("Permission is hereby granted", 1, true)
            )
          then
            items[#items + 1] =
              { message = "the LICENSE does not look like the MIT license", file = name, line = 1 }
          end
          break
        end
      end
      local headings = readme_headings(ctx)
      if headings then
        local found = false
        for _, h in ipairs(headings) do
          found = found or h.text:lower():find("licen[sc]e") ~= nil
        end
        if not found then
          items[#items + 1] = { message = "the README has no License section", file = "README.md" }
        end
      end
      return items
    end,
  },
  {
    id = "NEW-11",
    also = { "REL-01" },
    title = "README.md exists",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      if not ctx.fs:is_file("README.md") then
        return { { message = "no README.md", file = "README.md" } }
      end
      return {}
    end,
  },
  {
    id = "REL-10",
    title = "the README has an installation section",
    gate = "RELEASE",
    severity = "recommended",
    run = function(ctx)
      local headings = readme_headings(ctx)
      if not headings then
        return nil, "no README.md (NEW-11)"
      end
      for _, h in ipairs(headings) do
        if h.text:lower():find("install") then
          return {}
        end
      end
      -- a link to the installation page counts: `[Installation](docs/installation.md)`
      for _, line in ipairs(ctx.fs:lines("README.md") or {}) do
        for label, target in line:gmatch("%[([^%]]*)%]%(([^%)]*)%)") do
          if label:lower():find("install") or target:lower():find("install") then
            return {}
          end
        end
      end
      return { { message = "the README has no installation section", file = "README.md" } }
    end,
  },
  {
    id = "NEW-13",
    also = { "REL-05" },
    title = "doc/<plugin>.txt exists",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      for _, e in ipairs(ctx.fs:list("doc")) do
        if e.type == "file" and e.name:match("%.txt$") then
          return {}
        end
      end
      return { { message = "no doc/*.txt (vimdoc for :help)", file = "doc" } }
    end,
  },
  {
    id = "NEW-15",
    also = { "REL-06" },
    title = "docs/BINDINGS.md exists",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      if not ctx.fs:is_file("docs/BINDINGS.md") then
        return { { message = "no docs/BINDINGS.md", file = "docs/BINDINGS.md" } }
      end
      return {}
    end,
  },
  {
    id = "NEW-14",
    also = { "REL-07" },
    title = "no docs/ROADMAP.md in the plugin repository",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      if ctx.fs:exists("docs/ROADMAP.md") then
        return {
          {
            message = "docs/ROADMAP.md must not exist: open tasks live in the vault, not in the repository",
            file = "docs/ROADMAP.md",
            line = 1,
          },
        }
      end
      return {}
    end,
  },
  {
    id = "NEW-07",
    title = "lua/<plugin>/config/DEFAULTS.lua exists",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      for _, name in ipairs(module_roots(ctx)) do
        if ctx.fs:is_file("lua/" .. name .. "/config/DEFAULTS.lua") then
          return {}
        end
      end
      return {
        {
          message = "no lua/<plugin>/config/DEFAULTS.lua",
          file = "lua/" .. (ctx.plugin or "<plugin>") .. "/config/DEFAULTS.lua",
        },
      }
    end,
  },
  {
    id = "NEW-27",
    title = "lua/<plugin>/config/init.lua exists (defaults and entry are separate)",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      for _, name in ipairs(module_roots(ctx)) do
        if ctx.fs:is_file("lua/" .. name .. "/config/init.lua") then
          return {}
        end
      end
      return {
        {
          message = "no lua/<plugin>/config/init.lua",
          file = "lua/" .. (ctx.plugin or "<plugin>") .. "/config/init.lua",
        },
      }
    end,
  },
  {
    id = "NEW-08",
    title = "bindings/ has keymaps, usrcmds and autocmds",
    gate = "NEW_PROJECT",
    severity = "recommended",
    run = function(ctx)
      -- Both the file (`bindings/usrcmds.lua`) and the directory form (`bindings/usrcmds/*.lua`) count, and
      -- `usrcmds`/`usercmds` are both spellings of this fleet.
      for _, name in ipairs(module_roots(ctx)) do
        local bindings = "lua/" .. name .. "/bindings"
        if ctx.fs:is_dir(bindings) then
          local missing = {}
          if not has_binding(ctx, bindings, { "keymaps" }) then
            missing[#missing + 1] = "keymaps"
          end
          if not has_binding(ctx, bindings, { "usrcmds", "usercmds" }) then
            missing[#missing + 1] = "usrcmds"
          end
          if not has_binding(ctx, bindings, { "autocmds" }) then
            missing[#missing + 1] = "autocmds"
          end
          if #missing == 0 then
            return {}
          end
          return {
            { message = "bindings/ lacks: " .. table.concat(missing, ", "), file = bindings },
          }
        end
      end
      return {
        {
          message = "no lua/<plugin>/bindings/ directory",
          file = "lua/" .. (ctx.plugin or "<plugin>") .. "/bindings",
        },
      }
    end,
  },
  {
    id = "NEW-10",
    also = { "REL-16" },
    title = "lua/<plugin>/health.lua exists",
    gate = "NEW_PROJECT",
    severity = "critical",
    run = function(ctx)
      for _, name in ipairs(module_roots(ctx)) do
        if ctx.fs:is_file("lua/" .. name .. "/health.lua") then
          return {}
        end
      end
      return {
        {
          message = "no lua/<plugin>/health.lua (:checkhealth)",
          file = "lua/" .. (ctx.plugin or "<plugin>") .. "/health.lua",
        },
      }
    end,
  },
}

return M
