-- luacheck configuration. Neovim embeds LuaJIT; `vim` is the only global the plugin uses.
std = "luajit"

-- Line width is stylua's job (column_width = 100).
max_line_length = false

globals = { "vim" }

-- The specs may use busted syntax (describe/it/assert.*): declared explicitly, because luacheck
-- applies its busted defaults only to directories called spec/ test/ tests/, never to TESTS/.
files["TESTS/**/*.lua"] = { std = "+busted" }

-- 212/213: unused argument / loop variable -- callbacks with a fixed signature.
ignore = {
  "212",
  "213",
}

exclude_files = {
  "**/@types/**",
  ".deps/**",
}
