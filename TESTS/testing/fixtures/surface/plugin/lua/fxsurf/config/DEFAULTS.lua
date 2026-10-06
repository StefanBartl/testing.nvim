-- Typed defaults of the fixture plugin.

---@class Fxsurf.Config
---@field keymaps table<string, string|false>
---@field notify boolean
---@field limits { max: integer, names: string[] }

---@type Fxsurf.Config
return {
  keymaps = {},
  notify = true,
  limits = { max = 10, names = { "a" } },
}
