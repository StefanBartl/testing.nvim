---@module 'testing.health'
---@brief `:checkhealth testing` diagnostics.
---@description
--- Read-only: reports the Neovim version, the lib.nvim modules the plugin calls and the state of the
--- configuration and the command. Nothing is created or changed, and no lazy-loaded plugin is
--- loaded to probe it.

local M = {}

---@type { [1]: string, [2]: string }[]
local REQUIRED_LIB = {
  { "lib.nvim.health", "health helpers" },
  { "lib.nvim.notify", "messages" },
  { "lib.nvim.bindings.usercmd.composer", "the :Testing command" },
  { "lib.nvim.bindings.keymap", "named keymap actions" },
}

---@return nil
function M.check()
  local health = vim.health

  health.start("testing.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("testing.nvim needs Neovim 0.10+", { "Upgrade Neovim to 0.10 or newer" })
  end

  -- lib.nvim is a hard dependency: without it nothing below can be probed.
  local lib_ok = true
  for _, req in ipairs(REQUIRED_LIB) do
    if pcall(require, req[1]) then
      health.ok(("%s -- %s"):format(req[1], req[2]))
    else
      lib_ok = false
      health.error(
        ("%s missing -- %s"):format(req[1], req[2]),
        { 'Install or update "StefanBartl/lib.nvim" and list it as a dependency' }
      )
    end
  end
  if not lib_ok then
    return
  end

  health.start("testing.nvim: configuration")
  local config = require("testing.config")
  local cfg = config.get()
  health.ok(("notify prefix: %s"):format(cfg.notify_prefix))
  if cfg.keymaps == false or next(cfg.keymaps) == nil then
    health.info("no keymap is configured or bound by default")
  else
    health.info("keymap overrides are set, see docs/BINDINGS.md")
  end

  health.start("testing.nvim: bindings")
  if vim.fn.exists(":Testing") == 2 then
    health.ok(":Testing is registered")
  else
    -- The normal state before the plugin loaded (lazy `cmd =`), not a defect.
    health.info(":Testing is not registered yet; it is after the plugin loads or setup() runs")
  end
end

return M
