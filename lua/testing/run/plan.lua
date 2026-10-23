---@module 'testing.run.plan'
---@brief What a run is going to do, before it starts: the files in run order and an estimate of the cases.
---@description
--- The `run_start` event of `--events` carries this (`testing.run.events`), so a progress bar has a denominator
--- before the first case: `files` (the plan) and `cases_estimate`.
---
--- The count is an ESTIMATE and says so (`cases_estimated = true`): `describe`/`it` positions of a file are
--- counted from its source without running anything (`testing.discover.positions`, the regex backend: no parser,
--- fast, deterministic), a file of a dialect without such blocks (`script`, a harness) counts as one case, and a
--- file that cannot be read counts as one. A table-driven case, a generated `it` or a skipped branch makes the real
--- number differ; a reader shows the estimate as a guess and replaces it with what the stream says.
---
--- The source is read with a size cap and never executed.

local M = {}

---Files larger than this are not scanned (counted as one case).
---@type integer
M.MAX_FILE_BYTES = 512 * 1024

---Estimated cases of the source text of one file.
---@param text string
---@return integer
function M.estimate_text(text)
  local ok, cases = pcall(function()
    return (require("testing.discover.positions").cases(text, { backend = "regex" }))
  end)
  if not ok or type(cases) ~= "table" then
    return 1
  end
  return math.max(1, #cases)
end

---@class Testing.Plan
---@field files string[] Project-relative paths in run order.
---@field estimates table<string, integer> Estimated cases per file.
---@field cases_estimate integer

---The plan of a list of discovered files.
---@param root string
---@param files { rel: string, path?: string }[]
---@return Testing.Plan
function M.build(root, files)
  local plan = { files = {}, estimates = {}, cases_estimate = 0 }
  for _, f in ipairs(files) do
    local rel = f.rel
    local n = 1
    local path = f.path or (root .. "/" .. rel)
    local st = vim.uv.fs_stat(path)
    if st and st.type == "file" and st.size <= M.MAX_FILE_BYTES then
      local text = require("lib.nvim.fs.read")(path)
      if text then
        n = M.estimate_text(text)
      end
    end
    plan.files[#plan.files + 1] = rel
    plan.estimates[rel] = n
    plan.cases_estimate = plan.cases_estimate + n
  end
  return plan
end

return M
