-- Fixture guard whose install raises: the spawn of an RPC child must fail loudly (a guard that is not
-- installed would make every result of the run untrustworthy), not carry on without it.

local M = {}

function M.install()
  error("fixture guard install failed on purpose")
end

function M.collect()
  return {}
end

return M
