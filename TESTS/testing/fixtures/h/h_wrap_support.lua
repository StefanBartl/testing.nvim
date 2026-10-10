-- A spec framework of another file (never a spec): `spec` hands the body on, `spec_swallow` runs it under a pcall
-- of its own and keeps the error. The pcall is the framework's, not the spec's.

local M = {}

---@param body fun(H: table)
---@return fun(H: table)
function M.spec(body)
  return function(H)
    body(H)
  end
end

---@param body fun(H: table)
---@return fun(H: table)
function M.spec_swallow(body)
  return function(H)
    local ok = pcall(body, H)
    return ok
  end
end

return M
