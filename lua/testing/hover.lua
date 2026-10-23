---@module 'testing.hover'
---@brief The last result of a test, shown where the test is written: hover over a case or a spec file.
---@description
--- Reads `testing.state` (the one shared result store) and turns one position into a few lines: the status,
--- the duration, how long ago the case ran, and for a red case the first failing assertion with a small diff.
--- Pure functions (`describe_case`, `describe_file`) do the formatting; `position` is the thin editor side that
--- finds the project, the file and the line. Nothing here runs a test or touches the file system beyond the
--- two reads `testing.state` does.
---
--- **Never a stale green.** A spec file that changed (or vanished) since its result was recorded gets the
--- title `outdated` and its status is worded in the past tense ("was pass"), because the case may not exist
--- any more or may behave differently. A file the store knows nothing about says "no result yet" rather than
--- staying silent: a spec file without an answer is itself information.
---
--- **Hostile text.** Titles, messages and values come from the code under test and went through
--- `testing.state` already; they pass `testing.report.util.clean` once more here and are cut, so nothing
--- reaches a float that a terminal could interpret.
---
--- Registered with hover.nvim as an `on_request` position (asked for `:Hover show`, never on the automatic
--- trigger), softly: no hover.nvim is a machine without the optional half. `:Testing hover` shows the same
--- text in a plain float, which needs no hover.nvim.

local M = {}

---@type boolean
local registered = false

---Lines of a failure diff shown at most.
---@type integer
M.MAX_DIFF_LINES = 12
---Longest line shown (bytes).
---@type integer
M.MAX_LINE = 200

local BAD = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---@param s any
---@return string
local function safe(s)
  local util = require("testing.report.util")
  local text = util.clean(tostring(s or ""), { bidi = true })
  local cut, truncated = util.cap(text, M.MAX_LINE)
  return truncated and (cut .. "...") or cut
end

---"3 min ago", from two epoch seconds.
---@param ts? number
---@param now number
---@return string
function M.ago(ts, now)
  if type(ts) ~= "number" or ts <= 0 then
    return "at an unknown time"
  end
  local d = now - ts
  if d < 0 then
    return "just now"
  elseif d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%d min ago"):format(math.floor(d / 60))
  elseif d < 86400 then
    return ("%d h ago"):format(math.floor(d / 3600))
  end
  return ("%d d ago"):format(math.floor(d / 86400))
end

---@param ms number
---@return string
local function duration(ms)
  if ms >= 1000 then
    return ("%.2f s"):format(ms / 1000)
  end
  return ("%d ms"):format(math.floor(ms + 0.5))
end

---The words for a stale reason.
---@type table<string, string>
local WHY = {
  changed = "the file changed since the run",
  gone = "the file is gone",
  ["no result"] = "no result recorded",
}

---Content of one case.
---@param c Testing.State.Case
---@param file_ts? number
---@param stale boolean
---@param why? string
---@param now number
---@return { lines: string[], title: string, highlight?: string }
function M.describe_case(c, file_ts, stale, why, now)
  local verb = stale and "was" or "is"
  local lines = {
    ("%s %s - %s, %s"):format(verb, safe(c.status), duration(c.duration_ms), M.ago(file_ts, now)),
  }
  if stale then
    lines[#lines + 1] = ("outdated: %s"):format(WHY[why or ""] or safe(why or "unknown"))
  end
  if c.flaky then
    lines[#lines + 1] = "flaky: passed on a retry"
  end
  if BAD[c.status] or c.status == "skip" then
    if c.message and c.message ~= "" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = safe(c.message)
    end
    if BAD[c.status] and c.expected and c.actual and c.expected ~= c.actual then
      local diff = require("testing.report.term").diff_lines(c.expected, c.actual, {
        width = M.MAX_LINE,
        diff_context = 1,
      }, function(_, s)
        return s
      end)
      lines[#lines + 1] = ""
      if diff then
        for i, l in ipairs(diff) do
          if i > M.MAX_DIFF_LINES then
            lines[#lines + 1] = "..."
            break
          end
          lines[#lines + 1] = safe(l)
        end
      else
        lines[#lines + 1] = "expected: " .. safe(c.expected:match("[^\n]*"))
        lines[#lines + 1] = "actual:   " .. safe(c.actual:match("[^\n]*"))
      end
    end
  end
  local name = c.name and c.name ~= "" and c.name or c.id
  local title = safe(name)
  if stale then
    title = title .. " (outdated)"
  end
  local highlight
  if stale then
    highlight = "HoverWarn"
  elseif BAD[c.status] then
    highlight = "HoverError"
  end
  return { lines = lines, title = title, highlight = highlight }
end

---Content of one spec file.
---@param file string
---@param sum Testing.State.FileSummary|nil
---@param now number
---@return { lines: string[], title: string, highlight?: string }
function M.describe_file(file, sum, now)
  local title = safe(file)
  if not sum then
    return {
      lines = { "no result yet - run :Testing file" },
      title = title,
      highlight = "HoverWarn",
    }
  end
  local parts = {}
  for _, status in ipairs({ "pass", "fail", "error", "timeout", "crash", "xpass", "xfail", "skip" }) do
    local n = sum.counts[status]
    if n and n > 0 then
      parts[#parts + 1] = ("%d %s"):format(n, status)
    end
  end
  local verb = sum.stale and "was" or "is"
  local lines = {
    ("%d case(s) %s: %s - %s, %s"):format(
      sum.total,
      verb,
      table.concat(parts, ", "),
      duration(sum.duration_ms),
      M.ago(sum.ts, now)
    ),
  }
  if sum.stale then
    lines[#lines + 1] = ("outdated: %s"):format(WHY[sum.stale_reason or ""] or "unknown")
  end
  local shown = 0
  for _, id in ipairs(sum.failed) do
    if shown >= 8 then
      lines[#lines + 1] = ("... and %d more"):format(#sum.failed - shown)
      break
    end
    shown = shown + 1
    lines[#lines + 1] = "red: " .. safe(id)
  end
  local highlight
  if sum.stale then
    highlight = "HoverWarn"
  elseif #sum.failed > 0 then
    highlight = "HoverError"
  end
  return {
    lines = lines,
    title = title .. (sum.stale and " (outdated)" or ""),
    highlight = highlight,
  }
end

---Content for a file and a line of a project, from a loaded state.
---@param st Testing.State
---@param file string Project-relative.
---@param line integer 1-based
---@param now? number
---@return { lines: string[], title: string, highlight?: string }
function M.content(st, file, line, now)
  local state = require("testing.state")
  now = now or os.time()
  local c = state.case_at(st, file, line, { exact = true })
  if c then
    local stale, why = state.is_stale(st, file)
    local rec = st.files[c.file]
    return M.describe_case(c, rec and rec.ts or st.ts, stale, why, now)
  end
  return M.describe_file(file, state.file_summary(st, file), now)
end

---Whether a path looks like something this plugin has results for.
---@param st Testing.State
---@param rel string
---@return boolean
local function relevant(st, rel)
  if st.files[rel] then
    return true
  end
  return rel:match("_spec%.lua$") ~= nil or rel:match("^TESTS/") ~= nil
end

---The content for a buffer position, or nil when the buffer is not a test file of a project.
---@param bufnr integer
---@param row integer 1-based
---@param opts? { state_dir?: string }
---@return { lines: string[], title: string, highlight?: string }|nil
function M.at(bufnr, row, opts)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  local root = require("testing.bindings.usrcmds").resolve_root(nil, name)
  local rel = require("lib.nvim.fs.relpath")(vim.fs.normalize(name), root)
  if rel:sub(1, 3) == "../" or rel:match("^%a:") or rel:sub(1, 1) == "/" then
    return nil
  end
  local st = require("testing.state").load(root, opts)
  if not relevant(st, rel) then
    return nil
  end
  return M.content(st, rel, row)
end

---The position preview hover.nvim asks for.
---@param bufnr integer
---@param row integer 1-based
---@param _col integer
---@return { lines: string[], title?: string, highlight?: string }|nil
function M.position(bufnr, row, _col)
  local ok, content = pcall(M.at, bufnr, row)
  return ok and content or nil
end

---`:Testing hover`: the same text in a plain float.
function M.show()
  local content = M.at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1])
  local notify = require("testing.notify").get()
  if not content then
    notify.info("this buffer is not a test file of a project")
    return
  end
  local width = 20
  for _, l in ipairs(content.lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width, vim.o.columns - 4),
    height = math.min(#content.lines, 20),
    style = "minimal",
    border = "rounded",
    title = " " .. content.title .. " ",
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave" }, {
    once = true,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end,
  })
end

---Whether the position preview is registered with hover.nvim right now (read back from its registry).
---@return boolean
function M.registered()
  local ok, reg = pcall(require, "hover.registry")
  if not ok or type(reg.contributors) ~= "function" then
    return registered
  end
  for _, c in ipairs(reg.contributors() or {}) do
    if c.name == "testing.nvim" and (c.positions or 0) > 0 then
      return true
    end
  end
  return false
end

---Register with hover.nvim when it is installed; silent otherwise.
---@return boolean
function M.setup()
  local ok, reg = pcall(require, "hover.registry")
  if not ok or type(reg.register) ~= "function" then
    registered = false
    return false
  end
  reg.register("testing.nvim", { positions = { { fn = M.position, on_request = true } } })
  registered = true
  return true
end

return M
