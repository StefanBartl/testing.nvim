---@module 'testing.conformance.checks.common'
---@brief What the runtime checks have in common: getting the session data or the right "not applicable" answer.

local M = {}

---The data of the `main` session, or the outcome that says why there is none.
---
---  * no `lua/<plugin>`           -> `na`
---  * the editor could not run    -> `error` (infrastructure)
---  * the plugin has no entry module (`require("<plugin>")` finds nothing) -> `na`
---  * the entry module raises     -> `blocked` (K1 reports the cause)
---@param ctx Testing.Conformance.Ctx
---@return table|nil data
---@return Testing.Conformance.Outcome|nil outcome
function M.main(ctx)
  if not ctx.plugin then
    return nil, { na = ctx.plugin_problem or "no Lua module root of the plugin" }
  end
  local data, err = ctx.probe("main")
  if not data then
    return nil, { error = err or "the child editor did not answer" }
  end
  if type(data.load) ~= "table" or data.load.ok == nil then
    return nil,
      {
        error = "the child editor reported no load result: "
          .. tostring(data.load and data.load.err),
      }
  end
  if not data.load.ok then
    if data.load.missing then
      return nil,
        {
          na = ("`require(%q)` finds no entry module (no lua/%s/init.lua or lua/%s.lua)"):format(
            ctx.plugin,
            ctx.plugin,
            ctx.plugin
          ),
        }
    end
    return nil,
      {
        blocked = ("`require(%q)` raises (see K1): %s"):format(
          ctx.plugin,
          require("testing.conformance.util").relativize(
            (tostring(data.load.err):match("^[^\n]*") or ""),
            ctx.root
          )
        ),
      }
  end
  return data
end

---Does the plugin's own source name `name`? A command, an autocommand group or a global that the source never
---spells was registered by a DEPENDENCY that the plugin loads (`ui.nvim`'s `:KitPreview`, `lib.nvim`'s
---`:LibLogger`): it is not the plugin's surface, whoever's `require` happened to trigger it.
---@param ctx Testing.Conformance.Ctx
---@return fun(name: string): boolean own
function M.owned(ctx)
  local corpus
  local memo = {}
  return function(name)
    if memo[name] ~= nil then
      return memo[name]
    end
    if not corpus then
      local parts = {}
      for _, dir in ipairs({ "lua", "plugin" }) do
        for _, src in ipairs(ctx.sources(dir)) do
          parts[#parts + 1] = src.text
        end
      end
      corpus = table.concat(parts, "\n")
    end
    local own = name == "" or #name <= 2 or corpus:find(name, 1, true) ~= nil
    memo[name] = own
    return own
  end
end

---New global keymaps of a facts table without the `<Plug>`/`<SNR>` handles (internal, not user keys).
---@param facts table|nil
---@return table[]
function M.user_keymaps(facts)
  local out = {}
  for _, k in ipairs(facts and facts.keymaps or {}) do
    local lhs = tostring(k.lhs or "")
    local lower = lhs:lower()
    if lower:sub(1, 6) ~= "<plug>" and lower:sub(1, 5) ~= "<snr>" then
      out[#out + 1] = k
    end
  end
  return out
end

---Bound lib.nvim registry entries of a facts table: `{ surface, name, lhs, mode, bound, desc }`.
---@param facts table|nil
---@return table[]
function M.registry_keymaps(facts)
  local out = {}
  local reg = facts and facts.registry
  for _, sig in ipairs(reg and reg.keymaps or {}) do
    local parts = vim.split(sig, "\1", { plain = true })
    out[#out + 1] = {
      surface = parts[1],
      name = parts[2],
      lhs = parts[3] ~= "" and parts[3] or nil,
      mode = parts[4],
      bound = parts[5] == "bound",
      desc = parts[6] ~= "" and parts[6] or nil,
    }
  end
  return out
end

return M
