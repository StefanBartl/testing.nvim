-- Scenarios of the deprecation guard (RED: a deprecated API is used, GREEN: it is not).
-- Run by TESTS/testing/guard_deprecation_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")

local function only_dep(extra, top)
  ---@type table<string, any>
  local g = { deprecation = vim.tbl_extend("force", {}, extra or {}) }
  for _, name in ipairs({ "fs", "state", "scheduled_error", "prompt", "process_net", "clock" }) do
    g[name] = "off"
  end
  return vim.tbl_extend("force", { guards = g }, top or {})
end

B.case("red_deprecated_default_warn", {
  cfg = only_dep(),
  body = function()
    vim.deprecate("vim.old_function()", "vim.new_function()", "0.13", "Nvim")
    vim.deprecate("vim.old_function()", "vim.new_function()", "0.13", "Nvim")
    vim.deprecate("other.thing", nil, "2.0", "plugin.nvim")
  end,
})

B.case("red_strict_is_error", {
  cfg = only_dep({}, { strict = true }),
  body = function()
    vim.deprecate("vim.old_function()", "vim.new_function()", "0.13", "Nvim")
  end,
})

B.case("red_mode_error", {
  cfg = only_dep({ mode = "error" }),
  body = function()
    vim.deprecate("vim.old_function()", "vim.new_function()", "0.13", "Nvim")
  end,
})

B.case("green_no_deprecated_api", {
  cfg = only_dep(),
  body = function()
    vim.api.nvim_get_current_buf()
  end,
})

B.case("green_mode_off", {
  cfg = only_dep({ mode = "off" }),
  body = function()
    return { patched = debug.getinfo(vim.deprecate, "S").short_src:find("guard", 1, true) ~= nil }
  end,
})

B.finish()
