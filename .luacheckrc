-- luacheck configuration for testing.nvim.
-- Neovim embeds LuaJIT; `vim` is the only global the plugin and its specs use.
std = "luajit"

-- Line width is stylua's job (column_width = 100); doc comments may be longer.
max_line_length = false

globals = { "vim" }

read_globals = {
  -- Neovim's LuaJIT ships the 5.2-style shims that luacheck's stock luajit std predates.
  table = { fields = { "unpack", "pack" } },
  math = { fields = { "type" } },
}

-- 212/213: unused argument / loop variable -- callbacks with a fixed signature.
ignore = {
  "212",
  "213",
}

-- Type-only modules (`return {}` carrying annotations) have nothing to lint.
-- The specs use a tiny harness (TESTS/harness.lua), not busted: no busted `std` is needed.
exclude_files = {
  "**/@types/**",
  ".deps/**",
}
