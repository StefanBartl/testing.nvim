-- TESTS/testing/config_spec.lua -- testing.config: validation, merge over the defaults, reset.

return function(H)
  local eq, ok = H.eq, H.ok
  local config = require("testing.config")
  local DEFAULTS = require("testing.config.DEFAULTS")

  config.reset()
  eq(config.get(), DEFAULTS, "a fresh config equals the defaults")
  ok(config.get() ~= DEFAULTS, "the active config is a copy, never the DEFAULTS table itself")

  -- validate: what passes, what is dropped and why
  local valid, problems = config.validate(nil)
  eq(valid, {}, "nil is no options")
  eq(problems, {}, "nil is no problem")

  valid, problems = config.validate("x")
  eq(valid, {}, "a non-table is ignored")
  eq(#problems, 1, "a non-table is reported once")

  valid, problems = config.validate({ notify_prefix = 3, keymaps = "no", nope = true })
  eq(valid, {}, "wrong types and unknown keys are dropped")
  eq(#problems, 3, "each dropped key is reported")
  H.has(table.concat(problems, "\n"), "unknown option 'nope'", "an unknown key is named")

  valid = config.validate({ notify_prefix = "" })
  eq(valid, {}, "an empty prefix is dropped")

  valid = config.validate({ notify_prefix = "[t]", keymaps = false })
  eq(valid, { notify_prefix = "[t]", keymaps = false }, "valid keys pass, false counts for keymaps")

  -- setup: defaults first, valid options on top, bad options never overwrite a good default
  problems = config.setup({ notify_prefix = "[mine]" })
  eq(problems, {}, "valid options raise no problem")
  eq(config.get().notify_prefix, "[mine]", "a valid option is applied")
  eq(config.get().keymaps, {}, "an untouched key keeps its default")

  ---@type any
  local not_a_string = 5
  problems = config.setup({ notify_prefix = not_a_string })
  eq(#problems, 1, "an invalid option is reported")
  eq(config.get().notify_prefix, DEFAULTS.notify_prefix, "setup rebuilds from the defaults")

  config.setup({ keymaps = { run = "<leader>x" } })
  eq(config.get().keymaps, { run = "<leader>x" }, "a keymap override is merged in")
  config.setup({ keymaps = false })
  eq(config.get().keymaps, false, "keymaps = false replaces the table")

  config.reset()
  eq(config.get(), DEFAULTS, "reset restores the defaults")
end
