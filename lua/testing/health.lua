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
  { "lib.nvim.json", "deterministic JSON for the Result-IR" },
  { "lib.lua.error", "safe_call around spec bodies" },
  { "lib.nvim.fs.project_key", "stable project key of a run" },
  { "lib.nvim.fs.write.atomic", "atomic write of the JSON IR" },
  { "lib.nvim.system.job", "process execution (runner)" },
}

---Kernel modules that the CLI and the in-process driver need; a failure here is a defect of the
---plugin itself, not of the environment.
---@type string[]
local KERNEL = {
  "testing.core.result",
  "testing.core.assert",
  "testing.dialect.harness_a",
  "testing.run.inproc",
  "testing.cli",
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
      health.error(("%s missing -- %s"):format(req[1], req[2]), {
        'Install or update "StefanBartl/lib.nvim" and list it as a dependency',
        "testing.nvim needs lib.nvim >= 6304829 (fs.write.atomic) and >= 89cb912 (safe_call keeps non-string errors)",
      })
    end
  end
  if not lib_ok then
    return
  end

  health.start("testing.nvim: kernel")
  for _, name in ipairs(KERNEL) do
    local ok, err = pcall(require, name)
    if ok then
      health.ok(name)
    else
      health.error(("%s failed to load: %s"):format(name, tostring(err)), {
        "This is a defect of testing.nvim; report it with this message",
      })
    end
  end
  local ir_ok, result = pcall(require, "testing.core.result")
  if ir_ok and type(result.SCHEMA_VERSION) == "number" then
    health.info(("Result-IR schema_version %d"):format(result.SCHEMA_VERSION))
  end
  -- The CLI entry is a file on the runtimepath, not a module: probe it without loading anything.
  if #vim.api.nvim_get_runtime_file("scripts/testing.lua", false) > 0 then
    health.ok("scripts/testing.lua (command-line entry) is on the runtimepath")
  else
    health.info("scripts/testing.lua is not on the runtimepath; run it by path instead")
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
