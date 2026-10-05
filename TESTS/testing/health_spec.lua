-- TESTS/testing/health_spec.lua -- `:checkhealth testing` resolves and reports without errors.

return function(H)
  local ok = H.ok

  local ran, err = pcall(function()
    vim.cmd("checkhealth testing")
  end)
  ok(ran, "`:checkhealth testing` runs: " .. tostring(err))

  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  H.has(text, "testing.nvim", "the report has the plugin's section")
  H.has(text, "lib.nvim.notify", "the report lists the lib.nvim modules")
  ok(not text:find("ERROR", 1, true), "the report holds no error:\n" .. text)
end
