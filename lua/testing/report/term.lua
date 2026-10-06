---@module 'testing.report.term'
---@brief Terminal reporter: per-file verdict lines, failure details with a line diff, summary.
---@description
--- Pure: `render` takes the Result-IR and returns the lines to print; it never prints, reads the
--- environment or touches the terminal (guard rail L1: the IR is the only input). Whether to colour
--- is decided by the caller with `use_color`, which takes the facts (TTY, environment) as arguments.
---
--- Output keeps the shapes of the transitional lib.nvim runner (`ok    name`, `FAIL  name`, indented
--- detail lines, `N spec(s) failed`) so existing log scrapers keep working, then adds the parts the
--- old runner never had: file:line of every failed assertion, expected/actual, a line diff for
--- multi-line values, the `--durations` list, the seed of a shuffled run and a summary line.
---
--- Every string that came from the code under test passes `testing.report.util.clean` first, so a
--- test cannot inject terminal escape sequences, bidi overrides or invalid UTF-8 into the log.

local util = require("testing.report.util")
local result_mod = require("testing.core.result")

local M = {}

---@class Testing.Report.TermOpts
---@field color? boolean Colour the output (default false; see `use_color`).
---@field width? integer Terminal width in columns (default 100); longer lines are truncated.
---@field durations? integer Print the N slowest cases (default 0 = none).
---@field diff_max_cells? integer Largest `#expected * #actual` (in lines, after trimming equal head and tail) the O(n*m) diff may handle; above it the values are printed plainly. Default 40000.
---@field diff_context? integer Unchanged lines shown around a change (default 2).
---@field max_value_lines? integer Lines of an expected/actual value or traceback shown (default 20).
---@field max_diff_lines? integer Lines of one diff shown (default 60).

---Defaults as data. 40000 cells is 200 x 200 lines: the DP table of `lib.lua.diff.myers` stays under
---a megabyte and a few milliseconds, while a hostile assertion with two 100k-line values would need
---10^10 cells and hang the reporter (SEC-32).
---@class Testing.Report.TermDefaults
---@field color boolean
---@field width integer
---@field durations integer
---@field diff_max_cells integer
---@field diff_context integer
---@field max_value_lines integer
---@field max_diff_lines integer

---@type Testing.Report.TermDefaults
M.DEFAULTS = {
  color = false,
  width = 100,
  durations = 0,
  diff_max_cells = 40000,
  diff_context = 2,
  max_value_lines = 20,
  max_diff_lines = 60,
}

---Decide whether to colour: an explicit `color` wins, then `NO_COLOR` (any non-empty value, see
---no-color.org) disables, `FORCE_COLOR` / `CLICOLOR_FORCE` (not empty, not `0`) enables, otherwise
---colour only on a TTY. Pure: the facts come in as arguments.
---@param facts? { color?: boolean, is_tty?: boolean, env?: table<string, string|nil> }
---@return boolean
function M.use_color(facts)
  facts = facts or {}
  if facts.color ~= nil then
    return facts.color
  end
  local env = facts.env or {}
  if env.NO_COLOR and env.NO_COLOR ~= "" then
    return false
  end
  for _, name in ipairs({ "FORCE_COLOR", "CLICOLOR_FORCE" }) do
    local v = env[name]
    if v and v ~= "" and v ~= "0" then
      return true
    end
  end
  return facts.is_tty == true
end

local SGR = { red = "31", green = "32", yellow = "33", cyan = "36", dim = "2", bold = "1" }

---@param on boolean
---@return fun(kind: string, s: string): string
local function painter(on)
  if not on then
    return function(_, s)
      return s
    end
  end
  return function(kind, s)
    return "\27[" .. SGR[kind] .. "m" .. s .. "\27[0m"
  end
end

---Make a string one printable line of at most `cols` columns.
---@param s string
---@param cols integer
---@return string
local function fit(s, cols)
  s = util.clean((s:gsub("\t", "\\t")), { c1 = true, bidi = true })
  if cols < 4 then
    cols = 4
  end
  local out = require("lib.lua.strings.width").truncate(s, cols, { ellipsis = "..." })
  return out
end

---Add `text` (possibly multi-line) at `indent` to `lines`, each line truncated to the width.
---@param lines string[]
---@param indent integer
---@param text string
---@param width integer
---@param first_prefix? string Put in front of the first line (after the indent).
---@param max_lines? integer
local function emit(lines, indent, text, width, first_prefix, max_lines)
  local pad = (" "):rep(indent)
  local parts = util.split_lines(text)
  local shown = parts
  if max_lines and #parts > max_lines then
    shown = { unpack(parts, 1, max_lines) }
  end
  for i, line in ipairs(shown) do
    local prefix = (i == 1 and first_prefix) or ""
    lines[#lines + 1] = pad .. prefix .. fit(line, width - indent - #prefix)
  end
  if max_lines and #parts > max_lines then
    lines[#lines + 1] = pad .. ("... %d more line(s)"):format(#parts - max_lines)
  end
end

-- =========================================================
-- Diff
-- =========================================================

---Line diff of two texts as display lines (`- `, `+ `, `  `), with trimmed equal head/tail (cheap and
---exact) and a bound on the DP part.
---@param expected string
---@param actual string
---@param o Testing.Report.TermOpts
---@param paint fun(kind: string, s: string): string
---@return string[]|nil lines Nil when the input is over the limit (caller prints plainly).
---@return string|nil note Why there is no diff.
function M.diff_lines(expected, actual, o, paint)
  local a, b = util.split_lines(expected), util.split_lines(actual)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do
    tail = tail + 1
  end
  local mid_a = { unpack(a, head + 1, #a - tail) }
  local mid_b = { unpack(b, head + 1, #b - tail) }
  local limit = o.diff_max_cells or M.DEFAULTS.diff_max_cells
  if #mid_a * #mid_b > limit then
    return nil,
      ("diff skipped: %d x %d changed lines exceed the limit of %d cells"):format(
        #mid_a,
        #mid_b,
        limit
      )
  end
  ---@type { op: string, value: string }[]
  local ops = {}
  for i = 1, head do
    ops[#ops + 1] = { op = "equal", value = a[i] }
  end
  local mid = require("lib.lua.diff").myers.diff(mid_a, mid_b)
  for _, op in ipairs(mid) do
    ops[#ops + 1] = op
  end
  for i = #a - tail + 1, #a do
    ops[#ops + 1] = { op = "equal", value = a[i] }
  end

  -- keep changed ops and `context` equal ops around them
  local context = o.diff_context or M.DEFAULTS.diff_context
  local keep = {}
  for i, op in ipairs(ops) do
    if op.op ~= "equal" then
      for k = math.max(1, i - context), math.min(#ops, i + context) do
        keep[k] = true
      end
    end
  end
  local width = o.width or M.DEFAULTS.width
  local out = {}
  local gap = 0
  local function flush_gap()
    if gap > 0 then
      out[#out + 1] = paint("dim", ("  @@ %d unchanged line(s)"):format(gap))
      gap = 0
    end
  end
  for i, op in ipairs(ops) do
    if keep[i] then
      flush_gap()
      local text = fit(op.value, width - 12)
      if op.op == "delete" then
        out[#out + 1] = paint("red", "- " .. text)
      elseif op.op == "insert" then
        out[#out + 1] = paint("green", "+ " .. text)
      else
        out[#out + 1] = "  " .. text
      end
    else
      gap = gap + 1
    end
  end
  flush_gap()
  return out, nil
end

---Index of the first byte where two strings differ (nil when equal).
---@param a string
---@param b string
---@return integer|nil
local function first_difference(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    if a:byte(i) ~= b:byte(i) then
      return i
    end
  end
  if #a ~= #b then
    return n + 1
  end
  return nil
end

---Append the expected/actual part of one failed assertion.
---@param lines string[]
---@param a Testing.Result.Assertion
---@param indent integer
---@param o Testing.Report.TermOpts
---@param paint fun(kind: string, s: string): string
local function value_block(lines, a, indent, o, paint)
  local width = o.width or M.DEFAULTS.width
  local maxv = o.max_value_lines or M.DEFAULTS.max_value_lines
  local pad = (" "):rep(indent)
  local exp, act = a.expected, a.actual
  if exp and act and (exp:find("[\r\n]") or act:find("[\r\n]")) then
    local diff, note = M.diff_lines(exp, act, o, paint)
    if diff then
      lines[#lines + 1] = pad .. paint("dim", "diff (- expected, + actual):")
      local cap = o.max_diff_lines or M.DEFAULTS.max_diff_lines
      for i, l in ipairs(diff) do
        if i > cap then
          lines[#lines + 1] = pad .. ("  ... %d more diff line(s)"):format(#diff - cap)
          break
        end
        lines[#lines + 1] = pad .. "  " .. l
      end
      return
    end
    lines[#lines + 1] = pad .. paint("dim", note or "diff skipped")
  end
  local one_line = not ((exp and exp:find("[\r\n]")) or (act and act:find("[\r\n]")))
  if exp then
    lines[#lines + 1] = pad .. "expected:"
    emit(lines, indent + 2, exp, width, nil, maxv)
  end
  if act then
    lines[#lines + 1] = pad .. "actual:"
    emit(lines, indent + 2, act, width, nil, maxv)
  end
  if exp and act and one_line then
    local at = first_difference(exp, act)
    if at and (#exp > width - indent - 4 or #act > width - indent - 4) then
      lines[#lines + 1] = pad .. paint("dim", ("first difference at byte %d"):format(at))
    end
  end
end

-- =========================================================
-- Rendering
-- =========================================================

---@param c Testing.Result.Case
---@param indent integer
---@param lines string[]
---@param o Testing.Report.TermOpts
---@param paint fun(kind: string, s: string): string
local function case_details(c, indent, lines, o, paint)
  local width = o.width or M.DEFAULTS.width
  local maxv = o.max_value_lines or M.DEFAULTS.max_value_lines
  local pad = (" "):rep(indent)
  local cls = util.class_of(c.status)
  if c.status == "skip" then
    emit(lines, indent, "skipped" .. (c.reason and (": " .. c.reason) or ""), width)
    return
  end
  if c.status == "xpass" then
    emit(lines, indent, "unexpectedly passed (expected failure)", width)
  end
  if c.status == "timeout" or c.status == "crash" then
    emit(lines, indent, c.status .. (c.error and (": " .. (c.error.message or "")) or ""), width)
  end
  if c.status == "error" and c.error then
    emit(lines, indent, "error: " .. tostring(c.error.message), width)
    local trace = c.error.traceback
    if type(trace) == "string" and trace ~= "" then
      -- a Lua traceback starts with the message already printed above
      local msg = tostring(c.error.message)
      if trace:sub(1, #msg) == msg then
        trace = trace:sub(#msg + 1):gsub("^\r?\n", "")
      end
      emit(lines, indent + 2, trace, width, nil, maxv)
    end
  end
  if cls == "bad" then
    for _, a in ipairs(c.assertions or {}) do
      if a.ok == false then
        local where = a.file and (a.file .. (a.line and (":" .. a.line) or "")) or nil
        if not where and c.file then
          where = c.file .. (c.line and (":" .. c.line) or "")
        end
        local msg = a.msg or a.kind or "failed"
        if where then
          -- a long absolute path (a deep temp dir, a CI checkout) must not push the message out of
          -- the line: keep the tail of the path, which names the file, and the whole message
          local first = tostring(msg):match("^[^\n]*") or ""
          local budget = math.max(30, width - indent - 2 - #first)
          if #where > budget then
            local cut = #where - (budget - 3) + 1
            while cut <= #where and where:byte(cut) >= 0x80 and where:byte(cut) < 0xC0 do
              cut = cut + 1 -- never start inside a multi-byte character
            end
            where = "..." .. where:sub(cut)
          end
        end
        local head = (where and (where .. "  ") or "") .. msg
        emit(lines, indent, head, width)
        if a.expected or a.actual then
          value_block(lines, a, indent + 2, o, paint)
        end
        if a.diff and a.diff ~= "" then
          lines[#lines + 1] = pad .. "  " .. paint("dim", "diff:")
          emit(lines, indent + 4, a.diff, width, nil, o.max_diff_lines)
        end
      end
    end
  end
end

---Guard findings (state leaks, writes, prompts, ...) of the run, one line each: a `warn` is a warning, an
---`error` also failed its case (the failure is listed above; the guard says which guard it was).
---@param result Testing.Result
---@param paint fun(kind: string, s: string): string
---@param width integer
---@return string[]
local function guards_block(result, paint, width)
  local found = util.guard_findings(result)
  if #found == 0 then
    return {}
  end
  local warns, errors, infos = 0, 0, 0
  local shown = {}
  for _, f in ipairs(found) do
    if f.severity == "error" then
      errors = errors + 1
      shown[#shown + 1] = f
    elseif f.severity == "warn" then
      warns = warns + 1
      shown[#shown + 1] = f
    else
      infos = infos + 1
    end
  end
  if #shown == 0 then
    return {}
  end
  local head = ("guard findings: %d warning(s), %d failure(s)"):format(warns, errors)
  if infos > 0 then
    head = head .. (" (+%d info, see the IR)"):format(infos)
  end
  local out = { paint("bold", head) }
  local max = 40
  for i, f in ipairs(shown) do
    if i > max then
      out[#out + 1] = ("  ... and %d more (all of them, with their stacks: --json <file>)"):format(
        #shown - max
      )
      break
    end
    local kind = f.severity == "error" and "red" or "yellow"
    local label = (f.severity == "error" and "error" or "warn ") .. " [" .. f.guard .. "] "
    -- the message names the culprit ("spec X leaves autocmd Y in group Z"): a screen-wide cut would hide
    -- exactly that, so it is shortened only at a generous bound
    out[#out + 1] = "  " .. paint(kind, label) .. fit(f.message, math.max(width - 2 - #label, 400))
  end
  return out
end

---@param result Testing.Result
---@param n integer
---@param paint fun(kind: string, s: string): string
---@return string[]
local function durations_block(result, n, paint, width)
  local list = {}
  for _, c in ipairs(result.cases or {}) do
    list[#list + 1] = c
  end
  table.sort(list, function(x, y)
    local dx, dy = x.duration_ms or 0, y.duration_ms or 0
    if dx ~= dy then
      return dx > dy
    end
    return (x.id or "") < (y.id or "")
  end)
  local out = { paint("bold", ("slowest %d:"):format(math.min(n, #list))) }
  for i = 1, math.min(n, #list) do
    local c = list[i]
    out[#out + 1] = ("  %8.1f ms  %s"):format(c.duration_ms or 0, fit(c.id or "?", width - 15))
  end
  return out
end

---Render a result as terminal lines.
---@param result Testing.Result
---@param opts? Testing.Report.TermOpts
---@return string[] lines No trailing newlines, none containing one.
function M.render(result, opts)
  local o = vim.tbl_extend("force", M.DEFAULTS, opts or {})
  local paint = painter(o.color == true)
  local width = o.width or M.DEFAULTS.width
  local lines = {}
  local failed_files = 0

  for _, g in ipairs(util.group_by_file(result)) do
    local bad, skipped, cached = 0, 0, 0
    for _, c in ipairs(g.cases) do
      if c.cached then
        cached = cached + 1
      end
      local cls = util.class_of(c.status)
      if cls == "bad" then
        bad = bad + 1
      elseif cls == "skip" then
        skipped = skipped + 1
      end
    end
    local label, kind
    if bad > 0 then
      failed_files = failed_files + 1
      label, kind = "FAIL", "red"
    elseif skipped == #g.cases then
      label, kind = "skip", "yellow"
    else
      label, kind = "ok", "green"
    end
    local suffix = (bad == 0 and skipped > 0 and skipped < #g.cases)
        and (" (%d skipped)"):format(skipped)
      or ""
    if cached > 0 and cached == #g.cases then
      -- not executed in this run (`--cached`): never look the same as a file that ran
      suffix = suffix .. " (cached)"
    end
    lines[#lines + 1] = paint(kind, label)
      .. (" "):rep(6 - #label)
      .. fit(g.file, width - 6 - #suffix)
      .. suffix
    local multi = #g.cases > 1
    for _, c in ipairs(g.cases) do
      local cls = util.class_of(c.status)
      if cls == "bad" or c.status == "skip" then
        local indent = 6
        if multi then
          local title = ("%s  %s%s"):format(
            c.status,
            util.short_name(c),
            c.line and (":" .. c.line) or ""
          )
          lines[#lines + 1] = ("    "):rep(1)
            .. paint(cls == "bad" and "red" or "yellow", fit(title, width - 4))
          indent = 8
        end
        case_details(c, indent, lines, o, paint)
      end
    end
  end

  if failed_files > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = paint("red", ("%d spec(s) failed"):format(failed_files))
  end

  local guard_lines = guards_block(result, paint, width)
  if #guard_lines > 0 then
    lines[#lines + 1] = ""
    for _, l in ipairs(guard_lines) do
      lines[#lines + 1] = l
    end
  end

  if (o.durations or 0) > 0 and #(result.cases or {}) > 0 then
    lines[#lines + 1] = ""
    for _, l in ipairs(durations_block(result, o.durations, paint, width)) do
      lines[#lines + 1] = l
    end
  end

  local counts = result_mod.summarize(result.cases or {})
  local parts, bad_total, skip_total = {}, 0, 0
  for _, status in ipairs(result_mod.STATUSES) do
    local n = counts[status]
    if n > 0 or status == "pass" then
      parts[#parts + 1] = ("%d %s"):format(n, status)
    end
    local cls = util.class_of(status)
    if cls == "bad" then
      bad_total = bad_total + n
    elseif cls == "skip" then
      skip_total = skip_total + n
    end
  end
  local run = result.run or {}
  lines[#lines + 1] = ""
  if run.seed ~= nil then
    local hint = bad_total > 0 and ("  (reproduce: --shuffle --seed %d)"):format(run.seed) or ""
    lines[#lines + 1] = ("seed: %d%s"):format(run.seed, hint)
  end
  local ncached = 0
  for _, c in ipairs(result.cases or {}) do
    if c.cached then
      ncached = ncached + 1
    end
  end
  local summary = ("summary: %s (%d case(s)%s) in %.2f s"):format(
    table.concat(parts, ", "),
    #(result.cases or {}),
    ncached > 0 and (", %d cached, not run"):format(ncached) or "",
    (run.duration_ms or 0) / 1000
  )
  lines[#lines + 1] =
    paint(bad_total > 0 and "red" or (skip_total > 0 and "yellow" or "green"), summary)
  return lines
end

return M
