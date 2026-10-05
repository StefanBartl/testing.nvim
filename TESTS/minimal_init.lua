-- TESTS/minimal_init.lua -- puts testing.nvim and lib.nvim on the runtimepath for a headless run.
--
-- Loaded by TESTS/run.lua (`dofile`); it does not run anything itself. lib.nvim is a hard runtime
-- dependency, so a missing checkout is fatal: the message names every place that was searched
-- and the process exits with code 1 (a run that cannot load its dependency must never look green).
--
-- lib.nvim is looked up, in this order:
--   1. $LIB_NVIM_DIR
--   2. <repo>/.deps/lib.nvim   (what CI checks out)
--   3. <repo>/../lib.nvim      (a sibling checkout)

local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this)))

---@param dir string|nil
---@return boolean
local function is_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

local candidates = {
  { "$LIB_NVIM_DIR", vim.env.LIB_NVIM_DIR },
  { ".deps/lib.nvim", root .. "/.deps/lib.nvim" },
  { "sibling ../lib.nvim", vim.fs.dirname(root) .. "/lib.nvim" },
}

local lib
for _, c in ipairs(candidates) do
  if is_lib(c[2]) then
    lib = c[2]
    break
  end
end

if not lib then
  local lines = { "error: lib.nvim not found. Searched:" }
  for _, c in ipairs(candidates) do
    lines[#lines + 1] = ("  - %s (%s)"):format(c[1], c[2] or "unset")
  end
  lines[#lines + 1] =
    "Set LIB_NVIM_DIR, or clone it to .deps/lib.nvim, or place it beside this repo."
  io.stderr:write(table.concat(lines, "\n"), "\n")
  os.exit(1)
end

vim.opt.rtp:prepend(root)
vim.opt.rtp:append(lib)

return { root = root, lib = lib }
