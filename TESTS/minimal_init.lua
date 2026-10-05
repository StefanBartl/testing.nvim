-- TESTS/minimal_init.lua -- puts testing.nvim and lib.nvim on the runtimepath for a headless child.
--
-- Named by `minit` in .testing.lua; isolated child runs load it (`nvim -u TESTS/minimal_init.lua`),
-- it does not run anything itself. lib.nvim is a hard runtime dependency, so a missing checkout is
-- fatal: the message names all four places that were searched (testing.deps) and the process exits
-- with code 3 (a run that cannot load its dependency must never look green).

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

vim.opt.rtp:prepend(root)

local deps = require("testing.deps")
local lib, why = deps.resolve("lib.nvim", root)
if not lib then
  io.stderr:write(why, "\n")
  os.exit(3)
end
vim.opt.rtp:append(lib.dir)

return { root = root, lib = lib.dir }
