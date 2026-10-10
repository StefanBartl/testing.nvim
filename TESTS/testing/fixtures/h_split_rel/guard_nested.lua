-- Third file of the split fixture harnesses of this directory (never a spec): reachable only through the table `H.util`.

local M = {}

---Runs fn protected and re-raises its error unchanged.
---@param fn fun()
function M.guarded(fn)
  local ok, err = pcall(fn)
  if not ok then
    error(err, 0)
  end
end

return M
