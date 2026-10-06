-- Minimal init of the RPC child specs (`minit`): a "plugin" with a mapping that does its work later
-- (a timer), so `settle` has something to wait for, and a marker that proves the minit ran.
vim.g.rpc_minit_ran = vim.env.TESTING_PROBE_ENV or true
vim.keymap.set("n", "gz", function()
  vim.defer_fn(function()
    vim.g.deferred = "done"
  end, 250)
end, { desc = "fixture: deferred work" })
vim.keymap.set("n", "gs", function()
  vim.schedule(function()
    vim.g.scheduled = "done"
  end)
end, { desc = "fixture: scheduled work" })
