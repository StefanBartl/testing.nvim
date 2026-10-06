-- Fixture plugin of the conformance specs: configuration of testing.nvim.
return {
  plugin = "goodp",
  -- the keymap is opt-in: the suite switches it on with `setup`
  setup = { keymaps = { open = "<leader>go" } },
  conformance = { load_budget_ms = 5000 },
}
