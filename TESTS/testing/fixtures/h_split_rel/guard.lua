-- Helper file of the split fixture harnesses of this directory (never a spec): cleans up and raises again.

local M = {}

---Runs fn protected and re-raises its error unchanged (the shape of lib.nvim's `with_patched`).
---@param fn fun()
function M.guarded(fn)
  local ok, err = pcall(fn)
  if not ok then
    error(err, 0)
  end
end

return M
