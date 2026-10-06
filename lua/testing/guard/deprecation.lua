---@module 'testing.guard.deprecation'
---@brief `vim.deprecate` captured: a finding per deprecated API a case touched (0.12 migration).
---@description
--- While a case is open `vim.deprecate(name, alternative, version, plugin, backtrace)` is recorded
--- instead of printed: finding `deprecation.used`, severity `warn` by default and `error` under
--- `strict`. Each API is reported once per case. The original is not called (a message printed
--- into a headless run says nothing the finding does not say better).
---
--- Limit: only calls that go through the Lua function `vim.deprecate` are seen (the runtime's own
--- deprecations do; a `:echoerr` of a plugin that formats its own text does not).

local M = {}

---@class Testing.Guard.Deprecation
---@field h Testing.Guard.Handle
---@field cfg table
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.Deprecation
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg }, G)
end

function G:install()
  local h, g = self.h, self
  h.patcher:wrap(vim, "deprecate", function(orig)
    return function(name, alternative, version, plugin, backtrace)
      if not h:is_active() then
        return orig(name, alternative, version, plugin, backtrace)
      end
      local text = ("%s is deprecated"):format(tostring(name))
      if alternative then
        text = text .. (", use %s instead"):format(tostring(alternative))
      end
      text = text .. (" (removal in %s %s)"):format(tostring(plugin or "Nvim"), tostring(version))
      h:finding(
        "deprecation",
        "deprecation.used",
        ("%s uses a deprecated API: %s"):format(h:label(), text),
        { mode = g.cfg.mode, stack = backtrace ~= false and h:stack(3) or nil }
      )
      h:log("deprecations", text)
      return nil
    end
  end, "vim.deprecate")
end

return M
