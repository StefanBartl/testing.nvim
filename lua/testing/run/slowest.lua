---@module 'testing.run.slowest'
---@brief `--order slowest-first`: which weight a spec file has when the children start.
---@description
--- With `--jobs n` the children of an isolated run start in file order, and the longest file that starts last
--- decides the wall time (a file of 10 s that starts when everything else is done adds 10 s to the end). Starting
--- the longest files first fills the pool the way a long job should, and it changes nothing else: the files are
--- MERGED in file order, so the IR, the printed output, `--maxfail` and the exit code are the same for every
--- order (`testing.run.isolated`, `opts.dispatch_weights`).
---
--- The weights are the durations the runner remembers (`durations.json` beside the history, the file `--shard`
--- reads; `shard.durations` in `.testing.lua` names a file of the repository instead). Without a remembered
--- duration a file has no weight and starts in file order after the weighted ones: heuristics order, they never
--- filter, and a missing history is a note, never an error.

local M = {}

---The weights of a project.
---@param root string
---@param cfg Testing.ProjectConfig
---@param state_dir? string
---@return table<string, number> weights Spec path -> milliseconds; empty when nothing is remembered.
---@return string[] notes
function M.weights(root, cfg, state_dir)
  local shard = require("testing.run.shard")
  local notes = {}
  local path
  if cfg and cfg.shard and cfg.shard.durations then
    path = root .. "/" .. cfg.shard.durations
  else
    path = shard.durations_path(root, { state_dir = state_dir })
  end
  local durations, note = shard.read_durations(path)
  if note then
    notes[#notes + 1] = note
  end
  if next(durations) == nil then
    notes[#notes + 1] =
      "slowest-first: no remembered duration yet (a complete run records them): file order"
  end
  return durations, notes
end

---The start order of `n` slots: the slots whose weight is known, heaviest first (ties keep file order), then the
---slots without a weight in file order. A permutation of `1..n`.
---@param n integer
---@param weight_of fun(i: integer): number|nil
---@return integer[] order
function M.order(n, weight_of)
  local known, unknown = {}, {}
  for i = 1, n do
    local w = weight_of(i)
    if w ~= nil then
      known[#known + 1] = { i = i, w = w }
    else
      unknown[#unknown + 1] = i
    end
  end
  table.sort(known, function(a, b)
    if a.w ~= b.w then
      return a.w > b.w
    end
    return a.i < b.i
  end)
  local out = {}
  for _, k in ipairs(known) do
    out[#out + 1] = k.i
  end
  for _, i in ipairs(unknown) do
    out[#out + 1] = i
  end
  return out
end

return M
