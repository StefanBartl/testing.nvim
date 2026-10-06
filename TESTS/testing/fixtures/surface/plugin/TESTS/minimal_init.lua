-- minimal init of the fixture plugin: puts the plugin and lib.nvim on the runtimepath.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here)))
vim.opt.rtp:prepend(root)
local lib = vim.env.LIB_NVIM_DIR
if lib and lib ~= "" then
  vim.opt.rtp:append(lib)
end
