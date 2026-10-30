-- TESTS/testing/setup_spec.lua -- the facade (`require("testing").setup`) and the :Testing command.
---@diagnostic disable: assign-type-mismatch -- a wrong type is handed in on purpose

return function(H)
  local eq, ok = H.eq, H.ok
  local testing = require("testing")
  local config = require("testing.config")

  config.reset()
  eq(vim.fn.exists(":Testing"), 0, "no command before setup() or plugin/ ran")

  local returned = testing.setup({ notify_prefix = "[spec]" })
  eq(returned, testing, "setup returns the facade")
  eq(testing.get_config().notify_prefix, "[spec]", "setup applies the options")
  eq(vim.fn.exists(":Testing"), 2, "setup registers :Testing")

  -- idempotent: a second call neither errors nor changes the command
  testing.setup({ notify_prefix = "[spec2]" })
  eq(testing.get_config().notify_prefix, "[spec2]", "a second setup replaces the options")
  eq(vim.fn.exists(":Testing"), 2, ":Testing is still registered")

  -- completion comes from the same route tree as the dispatch
  local candidates = vim.fn.getcompletion("Testing ", "cmdline")
  ok(vim.tbl_contains(candidates, "health"), "health is offered as a subcommand")
  ok(vim.tbl_contains(candidates, "config"), "config is offered as a subcommand")

  -- the config route runs without raising
  local ran, err = pcall(function()
    vim.cmd("Testing config")
  end)
  ok(ran, "`:Testing config` runs: " .. tostring(err))

  -- an invalid option is dropped, the good default survives
  testing.setup({ notify_prefix = 42 })
  eq(testing.get_config().notify_prefix, "[testing]", "an invalid option falls back to the default")

  -- nothing is bound by default: the one action (`hover`) declares no default key
  local actions = require("testing.bindings.keymaps").ACTIONS
  eq(vim.tbl_keys(actions), { "hover" }, "the only keymap action is hover")
  eq(actions.hover.default, nil, "hover has no default key")
  local function mapped(lhs)
    return vim.fn.maparg(lhs, "n", false, true).desc
  end
  require("testing.bindings.keymaps").register(config.get())
  eq(mapped("<leader>th"), nil, "no hover key is bound without an opt-in")
  testing.setup({ keymaps = { hover = "<leader>th" } })
  ok(
    mapped("<leader>th") ~= nil and mapped("<leader>th") ~= "",
    "keymaps = { hover = lhs } binds the key"
  )
  pcall(vim.keymap.del, "n", "<leader>th")

  -- hover.nvim: `setup()` never loads it. Not loaded yet, one retry in a named group waits for it
  local saved_loaded, saved_preload =
    package.loaded["hover.registry"], package.preload["hover.registry"]
  local required, registered = 0, nil
  package.loaded["hover.registry"] = nil
  package.preload["hover.registry"] = function()
    required = required + 1
    error("hover.nvim must not be required by setup()")
  end
  testing.setup()
  eq(required, 0, "setup() does not require hover.nvim")
  local okg, armed = pcall(vim.api.nvim_get_autocmds, { group = "TestingHoverRegister" })
  ok(okg and #armed > 0, "setup() without hover.nvim loaded arms the retry")
  package.preload["hover.registry"] = nil
  package.loaded["hover.registry"] = {
    register = function(name)
      registered = name
    end,
  }
  vim.api.nvim_exec_autocmds("User", { pattern = "LazyLoad", modeline = false })
  eq(registered, "testing.nvim", "hover.nvim loaded later: the retry registers")
  -- loaded before setup(): registered at once, nothing armed
  registered = nil
  testing.setup()
  eq(registered, "testing.nvim", "hover.nvim loaded before setup(): registered at once")
  ok(
    not pcall(vim.api.nvim_get_autocmds, { group = "TestingHoverRegister" }),
    "and no retry is armed"
  )
  package.loaded["hover.registry"], package.preload["hover.registry"] = saved_loaded, saved_preload

  config.reset()
  -- `setup()` registered :Testing in this editor: leave it as found
  pcall(vim.api.nvim_del_user_command, "Testing")
end
