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

  -- A lib.nvim that is too old (module missing): the report must name it and the needed commit,
  -- not only stop. Simulated by a failing preload of a module that is otherwise loaded.
  local mod = "lib.nvim.fs.write.atomic"
  local saved_loaded, saved_preload = package.loaded[mod], package.preload[mod]
  package.loaded[mod] = nil
  package.preload[mod] = function()
    error("simulated: module not found")
  end
  local ran_old, err_old = pcall(function()
    vim.cmd("checkhealth testing")
  end)
  package.loaded[mod], package.preload[mod] = saved_loaded, saved_preload
  ok(ran_old, "`:checkhealth testing` runs with an old lib.nvim: " .. tostring(err_old))
  local old_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  has(old_text, mod .. " missing", "an old lib.nvim: the report names the missing module")
  has(old_text, "6304829", "an old lib.nvim: the report names the lib.nvim commit that is needed")
end
