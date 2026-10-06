---@module 'testing.conformance.checks.k04_keymap_desc'
---@brief K4: every keymap has a `desc` (REL-21, NEW-22).
---@description
--- Read from the editor itself (`nvim_get_keymap`): a mapping made with a raw `vim.keymap.set` counts as
--- much as one made through lib.nvim. `<Plug>` handles are not keys and are ignored. The lib.nvim
--- registry is read as well: a bound entry without a `desc` is reported once more only when the editor
--- list did not already name its key.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K4",
  title = "every keymap has a desc",
  rules = { "REL-21", "NEW-22" },
  kind = "runtime",
  level = "error",
}

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  local keys = common.user_keymaps(data.facts1)
  local entries = common.registry_keymaps(data.facts1 or {})
  local bound = 0
  for _, e in ipairs(entries) do
    if e.bound then
      bound = bound + 1
    end
  end
  if #keys == 0 and bound == 0 then
    return {
      na = "the plugin registers no keymap with the `setup` of .testing.lua (list the keymaps in `setup` to check them)",
    }
  end
  local findings, named = {}, {}
  for _, k in ipairs(keys) do
    named[k.lhs] = true
    if k.desc == nil or k.desc == "" then
      findings[#findings + 1] = util.finding(
        "K4",
        "REL-21",
        "error",
        ("keymap %s has no desc (which-key and :map show nothing for it)"):format(
          util.keymap_label(k, data.facts1.leader)
        )
      )
    end
  end
  for _, e in ipairs(entries) do
    if e.bound and e.desc == nil and not (e.lhs and named[e.lhs]) then
      findings[#findings + 1] = util.finding(
        "K4",
        "REL-21",
        "error",
        ("registry action %s.%s (%s) has no desc"):format(e.surface, e.name, e.lhs or "?")
      )
    end
  end
  return { findings = findings, notes = { ("%d keymap(s) checked"):format(#keys) } }
end

return M
