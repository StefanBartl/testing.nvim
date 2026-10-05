-- testing.nvim: registers `:Testing` at startup so `cmd = "Testing"` lazy-loading works.
if vim.g.loaded_testing then
  return
end
vim.g.loaded_testing = true
require("testing.bindings.usrcmds").register()
