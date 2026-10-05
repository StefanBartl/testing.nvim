-- TESTS/testing/health_spec.lua -- `:checkhealth testing` resolves and reports without errors.

return function(H)
  local ok = H.ok
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end

  local ran, err = pcall(function()
    vim.cmd("checkhealth testing")
  end)
  ok(ran, "`:checkhealth testing` runs: " .. tostring(err))

  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  has(text, "testing.nvim", "the report has the plugin's section")
  has(text, "lib.nvim.notify", "the report lists the lib.nvim modules")
  has(text, "testing.core.result", "the report lists the kernel modules")
  has(text, "lib.nvim.json", "the report lists the primitives the kernel needs")
  ok(not text:find("ERROR", 1, true), "the report holds no error:\n" .. text)
end
