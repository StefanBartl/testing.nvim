-- fxsurf: the fixture plugin of the testing.surface specs. Three keymaps (two registered actions and
-- one plain vim.keymap.set), two commands (a plain one and a composer verb with one route) and one
-- autocmd; `M.calls` counts what ran so a spec can tell the handlers did their work.

local M = {}

---@type table<string, integer>
M.calls = {}

local function count(name)
  M.calls[name] = (M.calls[name] or 0) + 1
end

function M.open()
  count("open")
  return "opened"
end

function M.close()
  count("close")
end

function M.toggle()
  count("toggle")
end

function M.status()
  count("status")
end

function M.on_write()
  count("write")
end

---@param opts? table
function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", require("fxsurf.config.DEFAULTS"), opts or {})
  local keymap = require("lib.nvim.bindings.keymap")
  local usercmd = require("lib.nvim.bindings.usercmd")
  local autocmd = require("lib.nvim.bindings.autocmd")

  -- two registered actions (one with two modes) ...
  keymap.register("fxsurf", {
    actions = {
      open = { default = "<leader>fo", rhs = M.open, desc = "open" },
      close = { default = "<leader>fc", rhs = M.close, mode = { "n", "x" }, desc = "close" },
    },
    order = { "open", "close" },
  }, cfg.keymaps)

  -- ... and one plain map the registry of lib.nvim never sees through register()
  vim.keymap.set("n", "<leader>ft", function()
    M.toggle()
  end, { desc = "fxsurf: toggle" })

  usercmd.create("FxOpen", function()
    M.open()
  end, { desc = "open the fixture" })

  usercmd.composer.verb("Fx", {
    desc = "fixture verb",
    routes = {
      {
        path = { "status" },
        desc = "show the status",
        run = function()
          M.status()
        end,
      },
    },
  })

  autocmd.create("BufWritePost", function()
    M.on_write()
  end, { group = "fxsurf", pattern = "*.fx", desc = "count writes" })
end

return M
