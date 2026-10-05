-- scripts/testing.lua -- command-line entry of testing.nvim (M0 driver).
--
--   nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root> [--json out.json] [options]
--
-- Run `... -l scripts/testing.lua --help` for the options. Exit codes: 0 green, 1 failures,
-- 2 usage/config error, 3 infrastructure error.
--
-- Puts this repository and lib.nvim on the runtimepath (lib.nvim is a hard runtime dependency,
-- looked up in: $LIB_NVIM_DIR, <repo>/.deps/lib.nvim, <repo>/../lib.nvim), then hands over to
-- `testing.cli`. Without lib.nvim nothing can run, so that is exit code 2.

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

local function is_lib(dir)
  return vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

local candidates = {}
if vim.env.LIB_NVIM_DIR and vim.env.LIB_NVIM_DIR ~= "" then
  candidates[#candidates + 1] = vim.env.LIB_NVIM_DIR
end
candidates[#candidates + 1] = repo .. "/.deps/lib.nvim"
candidates[#candidates + 1] = vim.fs.dirname(repo) .. "/lib.nvim"

local lib
for _, dir in ipairs(candidates) do
  if is_lib(dir) then
    lib = dir
    break
  end
end

if not lib then
  io.stderr:write(
    "testing: lib.nvim not found (set LIB_NVIM_DIR, or place it at .deps/lib.nvim or beside this repo)\n"
  )
  os.exit(2)
end

vim.opt.rtp:prepend(repo)
vim.opt.rtp:append(lib)

os.exit(require("testing.cli").main(arg or {}))
