---@module 'testing.conformance.checks.k07_soft_deps'
---@brief K7: every `pcall(require, ...)` soft dependency has a health check (REL-17).
---@description
--- Static. Every `pcall(require, "<module>")` of `lua/<plugin>/**` (comment lines and `@types` files
--- skipped) names a soft dependency. The dependency is the module's first segment, except for
--- lib.nvim (`lib.nvim.*`, one dependency). `health.lua` and the modules of the plugin it requires (up
--- to two levels, so a shared `deps` module counts) must mention that name. Modules of the plugin's own
--- tree and the editor's own (`vim.*`) are not dependencies. A plugin without `health.lua` is not
--- applicable here (NEW-10 is K15's), and a plugin without soft dependencies passes.

local util = require("testing.conformance.util")

local M = {
  id = "K7",
  title = "every soft dependency has a health check",
  rules = { "REL-17", "LUA-05" },
  kind = "static",
  level = "warn",
}

---The dependency a module name stands for.
---@param name string
---@return string
local function dependency_of(name)
  if name:match("^lib%.nvim") then
    return "lib.nvim"
  end
  return name:match("^[^.]+") or name
end

---@param line string
---@return string[]
local function soft_requires(line)
  local out = {}
  for name in line:gmatch("pcall%s*%(%s*require%s*,%s*[\"']([%w_%.@%-]+)[\"']") do
    if name:sub(-1) ~= "." then
      out[#out + 1] = name
    end
  end
  return out
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local plugin = ctx.plugin
  if not plugin then
    return { na = ctx.plugin_problem or "no Lua module root of the plugin" }
  end
  local health_rel = "lua/" .. plugin .. "/health.lua"
  local sources = ctx.sources("lua")
  local by_rel = {}
  for _, s in ipairs(sources) do
    by_rel[s.rel] = s
  end

  -- soft dependencies: dep -> first place (file, line)
  local deps, order = {}, {}
  for _, s in ipairs(sources) do
    local own = s.rel:sub(1, #("lua/" .. plugin .. "/")) == "lua/" .. plugin .. "/"
      or s.rel == "lua/" .. plugin .. ".lua"
    if own and not s.rel:find("/@types/", 1, true) then
      for n, line in ipairs(s.lines) do
        if not util.is_comment(line) then
          for _, name in ipairs(soft_requires(line)) do
            local dep = dependency_of(name)
            if dep ~= plugin and dep ~= "vim" then
              if not deps[dep] then
                deps[dep] = { file = s.rel, line = n, module = name }
                order[#order + 1] = dep
              end
            end
          end
        end
      end
    end
  end
  table.sort(order)

  if not by_rel[health_rel] then
    return { na = ("no %s (NEW-10 is reported by K15)"):format(health_rel) }
  end
  if #order == 0 then
    return { notes = { "no pcall(require, ...) soft dependency found" } }
  end

  -- the health corpus: health.lua plus the plugin modules it requires, two levels deep
  local corpus, seen = {}, {}
  local function add(rel, depth)
    if seen[rel] or not by_rel[rel] then
      return
    end
    seen[rel] = true
    corpus[#corpus + 1] = table.concat(by_rel[rel].lines, "\n")
    if depth >= 2 then
      return
    end
    for _, line in ipairs(by_rel[rel].lines) do
      for _, name in ipairs(util.required_names(line)) do
        if name == plugin or name:sub(1, #plugin + 1) == plugin .. "." then
          local p = "lua/" .. name:gsub("%.", "/")
          add(p .. ".lua", depth + 1)
          add(p .. "/init.lua", depth + 1)
        end
      end
    end
  end
  add(health_rel, 0)
  local text = table.concat(corpus, "\n")

  local findings = {}
  for _, dep in ipairs(order) do
    if not text:find(dep, 1, true) then
      local where = deps[dep]
      findings[#findings + 1] = util.finding(
        "K7",
        "REL-17",
        "warn",
        ("soft dependency %q (pcall(require, %q)) has no check in health.lua"):format(
          dep,
          where.module
        ),
        where.file,
        where.line
      )
    end
  end
  return {
    findings = findings,
    notes = { ("%d soft dependenc(ies): %s"):format(#order, table.concat(order, ", ")) },
  }
end

return M
