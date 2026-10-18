-- TESTS/testing/platform_spec.lua -- testing.platform: one answer to "which system", from lib.nvim.cross.platform, with the
-- editor's own has() as the fallback for a process that boots without lib.nvim.

return function(H)
  local eq = H.eq
  local platform = require("testing.platform")

  local win_name, mac_name =
    "lib.nvim.cross.platform.is_windows", "lib.nvim.cross.platform.is_macos"
  local saved_win, saved_mac = package.loaded[win_name], package.loaded[mac_name]

  -- the answer is lib.nvim's, not the editor's
  package.loaded[win_name] = function()
    return true
  end
  package.loaded[mac_name] = function()
    return false
  end
  eq(platform.is_windows(), true, "windows: the answer of lib.nvim.cross.platform")
  eq(platform.is_macos(), false, "macos: the answer of lib.nvim.cross.platform")
  eq(platform.is_case_insensitive(), true, "case blind where lib.nvim says windows")

  package.loaded[win_name] = function()
    return false
  end
  package.loaded[mac_name] = function()
    return true
  end
  eq(platform.is_case_insensitive(), true, "and where it says macos")

  package.loaded[mac_name] = function()
    return false
  end
  eq(platform.is_case_insensitive(), false, "but on neither")

  -- a process without lib.nvim: the editor's own answer (the module cannot be required, a function that fails likewise)
  package.loaded[win_name] = function()
    error("broken")
  end
  package.loaded[mac_name] = function()
    return "not a boolean"
  end
  eq(
    platform.is_windows(),
    vim.fn.has("win32") == 1,
    "a failing lib answer falls back to has('win32')"
  )
  eq(
    platform.is_macos(),
    vim.fn.has("mac") == 1,
    "and a lib answer that is no boolean to has('mac')"
  )

  package.loaded[win_name], package.loaded[mac_name] = saved_win, saved_mac

  -- the platform is asked here and nowhere else in the plugin (LUA-07)
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
    .. "/lua/testing"
  local offenders = {}
  for name, kind in vim.fs.dir(root, { depth = 10 }) do
    if kind == "file" and name:match("%.lua$") and name ~= "platform.lua" then
      local lines = vim.fn.readfile(root .. "/" .. name)
      for index, line in ipairs(lines) do
        if line:find('has("win32")', 1, true) or line:find('has("mac")', 1, true) then
          offenders[#offenders + 1] = name .. ":" .. index
        end
      end
    end
  end
  eq(table.concat(offenders, ", "), "", "no module asks the editor for the system itself")
end
