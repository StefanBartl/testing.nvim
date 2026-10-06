-- TESTS/testing/setup_spec.lua -- the facade (`require("testing").setup`) and the :Testing command.

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

  -- nothing is bound by default: the plugin declares no keymap action yet
  eq(next(require("testing.bindings.keymaps").ACTIONS), nil, "no keymap action is declared")
  eq(require("testing.bindings.keymaps").register(config.get()), false, "no keymap is bound")

  config.reset()
  -- `setup()` registered :Testing in this editor: leave it as found
  pcall(vim.api.nvim_del_user_command, "Testing")
end
