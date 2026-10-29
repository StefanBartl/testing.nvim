---@module 'testing.ci.events'
---@brief The events of a pipeline run (`testing ci --events=<file>`): NDJSON, one flushed line per event.
---@description
--- What a UI needs to show a run live without reading its terminal text: `run_start` (the planned steps),
--- `step_start`, `step_end` (state, time, findings), `run_done` (verdict, exit code). The suite step's own events
--- (file n of m) go to a file of their own, named in its `step_start` (`suite_events`): the suite runs in this
--- process and writes them itself. Like the suite's stream it is a convenience, never part of the verdict: a file
--- that cannot be opened or written is one note on stderr and the stream is off.

local M = {}

M.SCHEMA = "testing-ci-events/1"

---@class Testing.Ci.Events
---@field emit fun(event: string, fields?: table)
---@field close fun()

---@param path string|nil Where the stream goes; nil: a writer that writes nothing.
---@param note fun(msg: string) Where the one note goes when the stream fails.
---@return Testing.Ci.Events
function M.open(path, note)
  local f
  if path and path ~= "" then
    local err
    f, err = io.open(vim.fn.fnamemodify(path, ":p"), "wb")
    if not f then
      note(
        ("testing ci: note: the events file %s cannot be opened (%s); no events"):format(
          path,
          tostring(err)
        )
      )
    end
  end
  local function emit(event, fields)
    if not f then
      return
    end
    local line = vim.tbl_extend("force", fields or {}, { v = 1, event = event, ts = os.time() })
    local ok = pcall(function()
      assert(f:write(require("lib.nvim.json.canonical").encode(line), "\n"))
      assert(f:flush())
    end)
    if not ok then
      note(
        ("testing ci: note: writing the events file %s failed; no more events"):format(
          tostring(path)
        )
      )
      pcall(f.close, f)
      f = nil
    end
  end
  return {
    emit = emit,
    close = function()
      if f then
        pcall(f.close, f)
        f = nil
      end
    end,
  }
end

return M
