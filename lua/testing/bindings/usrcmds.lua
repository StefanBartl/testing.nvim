---@module 'testing.bindings.usrcmds'
---@brief Registers the `:Testing` user command (lib.nvim composer verb).
---@description
--- `:Testing health` runs `:checkhealth testing`, `:Testing config` prints the effective
--- configuration. Routes, completion and usage text all come from one route tree
--- (lib.nvim.bindings.usercmd.composer).

local M = {}

local registered = false

---The route tree of `:Testing`.
---@return table[]
function M.routes()
  return {
    {
      path = { "health" },
      desc = "Run :checkhealth testing",
      run = function()
        vim.cmd("checkhealth testing")
      end,
    },
    {
      path = { "config" },
      desc = "Show the effective configuration",
      run = function()
        require("testing.notify").get().info(vim.inspect(require("testing.config").get()))
      end,
    },
  }
end

---Register `:Testing`. Safe to call twice.
---@return boolean ok False when lib.nvim is missing; the error is shown once.
function M.register()
  if registered then
    return true
  end
  local ok, err = pcall(function()
    require("lib.nvim.bindings.usercmd.composer").verb("Testing", {
      desc = "testing.nvim: health, config",
      routes = M.routes(),
    })
  end)
  if not ok then
    -- lib.nvim itself is what failed to load, so its notifier is not an option here.
    vim.schedule(function()
      vim.notify(
        ("[testing] :Testing is unavailable: %s"):format(tostring(err)),
        vim.log.levels.WARN
      )
    end)
    return false
  end
  registered = true
  return true
end

return M
