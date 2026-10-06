---@module 'testing.conformance.checks.k03_keymaps_off'
---@brief K3: `setup({ keymaps = false })` registers no keymaps (REL-20, NEW-21).
---@description
--- Every keymap of a plugin must be switchable off from the configuration. The check needs something to
--- switch off: when the default `setup()` of `.testing.lua` registers no keymap, the check does not apply
--- (a plugin whose keymaps are opt-in lists them in `setup` of `.testing.lua`, then the check runs).
--- Otherwise a second editor calls `setup(<setup> + conformance.keymaps_off)` (default
--- `{ keymaps = false }`) and everything it registers is a finding: a mapping from `plugin/`, from the
--- module's top level, or from `setup()` itself. `<Plug>` mappings are handles, not keys, and are ignored.

local util = require("testing.conformance.util")
local common = require("testing.conformance.checks.common")

local M = {
  id = "K3",
  title = "setup({ keymaps = false }) registers no keymaps",
  rules = { "REL-20", "NEW-21" },
  kind = "runtime",
  level = "error",
}

---Bound registry entries (what lib.nvim bound on its own) in a facts table.
---@param facts table
---@return table[]
local function bound_entries(facts)
  local out = {}
  for _, e in ipairs(common.registry_keymaps(facts)) do
    if e.bound then
      out[#out + 1] = e
    end
  end
  return out
end

---@param ctx Testing.Conformance.Ctx
---@return Testing.Conformance.Outcome
function M.run(ctx)
  local data, out = common.main(ctx)
  if not data then
    return out --[[@as Testing.Conformance.Outcome]]
  end
  local default_keys = common.user_keymaps(data.facts1)
  if #default_keys == 0 and #bound_entries(data.facts1 or {}) == 0 then
    return {
      na = "the plugin registers no keymap with the `setup` of .testing.lua (nothing to switch off; "
        .. "list the keymaps in `setup` to check them)",
    }
  end

  -- the switch has to exist: when nothing in the plugin's sources even names the option, `keymaps = false` is
  -- not this plugin's spelling and the check would blame it for an option it never had
  local switch_names = vim.tbl_keys(ctx.settings.keymaps_off or {})
  table.sort(switch_names)
  if #switch_names > 0 then
    local named = false
    for _, dir in ipairs({ "lua", "plugin" }) do
      for _, src in ipairs(ctx.sources(dir)) do
        for _, key in ipairs(switch_names) do
          local pos = 1
          while not named do
            local i, j = src.text:find(key, pos, true)
            if not i then
              break
            end
            local before = i > 1 and src.text:sub(i - 1, i - 1) or ""
            local after = src.text:sub(j + 1, j + 1)
            named = not before:match("[%w_]") and not after:match("[%w_]")
            pos = j + 1
          end
        end
        if named then
          break
        end
      end
      if named then
        break
      end
    end
    if not named then
      return {
        na = (
          "nothing in lua/ or plugin/ names the option `%s`: name the plugin's own switch in "
          .. "`conformance.keymaps_off` of .testing.lua"
        ):format(table.concat(switch_names, ", ")),
      }
    end
  end

  local off, err = ctx.probe("keymaps_off")
  if not off then
    return { error = err }
  end
  local findings = {}
  local opts_text = util.show((vim.inspect(off.opts):gsub("%s+", " ")), 80)
  if type(off.setup) == "table" and off.setup.ok == false then
    findings[#findings + 1] = util.finding(
      "K3",
      "REL-20",
      "error",
      ("setup(%s) raised, so the keymaps cannot be switched off: %s"):format(
        opts_text,
        util.relativize(tostring(off.setup.err):match("^[^\n]*") or "?", ctx.root)
      )
    )
  end
  local facts = off.facts
  if type(facts) ~= "table" or facts.err then
    return { error = "the child editor reported no facts" }
  end
  local remaining = common.user_keymaps(facts)
  for i, k in ipairs(remaining) do
    if i > 20 then
      findings[#findings + 1] =
        util.finding("K3", "REL-20", "error", ("... and %d more keymap(s)"):format(#remaining - 20))
      break
    end
    findings[#findings + 1] = util.finding(
      "K3",
      "REL-20",
      "error",
      ("keymap %s%s is still registered with setup(%s)%s"):format(
        util.keymap_label(k, facts.leader),
        k.desc and (" (" .. k.desc .. ")") or "",
        opts_text,
        i == 1
            and "; if the plugin switches its keymaps off with another option, name it in `conformance.keymaps_off`"
          or ""
      )
    )
  end
  if #remaining == 0 then
    for _, e in ipairs(bound_entries(facts)) do
      findings[#findings + 1] = util.finding(
        "K3",
        "REL-20",
        "error",
        ("lib.nvim registry still binds %s.%s (%s)"):format(e.surface, e.name, e.lhs or "?")
      )
    end
  end
  return {
    findings = findings,
    notes = {
      ("%d keymap(s) with the default setup, %d with keymaps off"):format(
        #default_keys,
        #remaining
      ),
    },
  }
end

return M
