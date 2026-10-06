---@module 'testing.isolation'
---@brief Soft isolation: what a spec file changed in THIS editor is undone before the next file runs.
---@description
--- `--isolated=soft` runs every spec file in the runner's own process (fast) and puts the editor back
--- between the files. It is the cheap sibling of `--isolated=file` (a child per file): good enough to
--- find "this file leaks X into the next one", not an exact isolation, and it says so (see
--- `testing.isolation.snapshot` for what is covered and what is not).
---
--- USE
---   local session = isolation.new({ keep = project.soft_keep, severity = "warn" })
---   local frame = session:enter(rel)      -- snapshot before the file
---   ... run the file ...
---   local report = session:leave(frame)   -- snapshot after, diff, restore, verify
---   report.findings                       -- Testing.Result.GuardFinding[], named, ready for the IR
---
--- RESTORE OR REPORT. `leave` restores what it can, captures the state AGAIN and compares it with the
--- state before the file: a difference that is still there is reported as "NOT restored". Every
--- difference, restored or not, is a named finding ("<file> leaves autocmd BufEnter (pattern *) in
--- group `Leak`"), with the severity the `state` guard is configured to (`guards.state`: "off" =
--- restore silently, "warn", "error" = the file's last case fails). Nothing is restored behind the
--- user's back: a restored leak is still a leak the project should fix.
---
--- THE SEAM WITH THE GUARD LAYER. The state snapshot is a "backend": `capture() -> snapshot`,
--- `diff(before, after, { keep }) -> entries`, `restore(entries) -> failures` (key -> reason), and
--- optionally `refocus(snapshot)`. An entry is `{ kind, change, key, name, restore?, why? }` (see
--- `testing.isolation.snapshot`). `M.backend()` takes the guard layer's own implementation when
--- `testing.guard.state` exports `soft_backend()` (a function returning such a table) and falls back
--- to the internal one; the module that owns the leak vocabulary (the `state` guard of
--- `testing.guard`) can therefore replace the snapshot without this module changing.

local M = {}

---Most findings one file produces; the rest is one summary finding.
M.MAX_FINDINGS = 30

---@class Testing.Isolation.Backend
---@field capture fun(): table
---@field diff fun(before: table, after: table, opts?: { keep?: string[] }): Testing.Isolation.Entry[]
---@field restore fun(entries: Testing.Isolation.Entry[]): table<string, string>
---@field refocus? fun(before: table)

---@param b any
---@return boolean
local function is_backend(b)
  return type(b) == "table"
    and type(b.capture) == "function"
    and type(b.diff) == "function"
    and type(b.restore) == "function"
end

---The state backend: the guard layer's when it offers one, else the internal one.
---@return Testing.Isolation.Backend backend
---@return string name `testing.guard.state` or `internal`
function M.backend()
  local ok, state = pcall(require, "testing.guard.state")
  if ok and type(state) == "table" and type(state.soft_backend) == "function" then
    local bok, b = pcall(state.soft_backend)
    if bok and is_backend(b) then
      return b, "testing.guard.state"
    end
  end
  return require("testing.isolation.snapshot"), "internal"
end

---@class Testing.Isolation.Opts
---@field keep? string[] Modules never unloaded (`soft_keep`: exact names or `prefix*`).
---@field severity? "warn"|"error" Severity of the findings; nil = restore without reporting.
---@field report_restored? boolean Report a difference that WAS restored too (default true). False when the guard layer's `state` guard names the leaks per case already: then only what could not be restored is reported here.
---@field backend? Testing.Isolation.Backend Replaces `M.backend()` (specs).
---@field keep_prefixes? string[] Replaces the built-in prefixes of the modules never unloaded (`vim`, `jit`, `testing`, `lib`, ...). The warm pool leaves `lib` out: a module of lib.nvim that registered an autocmd when it loaded must load again after that autocmd was restored away.
---@field skip_kinds? string[] Entry kinds (`buffer`, `window`, `tab`, ...) this session neither reports nor restores: someone else puts them back AND checks (the warm pool's reset, which wipes every buffer and closes every window and tab, then verifies).

---@class Testing.Isolation.Frame
---@field rel string
---@field before table
---@field started integer hrtime

---@class Testing.Isolation.Item
---@field kind string
---@field change string
---@field name string
---@field restored boolean
---@field why? string

---@class Testing.Isolation.Report
---@field findings Testing.Result.GuardFinding[]
---@field items Testing.Isolation.Item[] Every difference, restored or not, in a stable order.
---@field restored integer
---@field unrestored integer
---@field ms number Time spent in this file's enter + leave.

---@class Testing.Isolation.Session
---@field backend Testing.Isolation.Backend
---@field backend_name string
---@field keep string[]
---@field severity? "warn"|"error"
---@field report_restored boolean
---@field skip table<string, true> Entry kinds that are left alone (`skip_kinds`).
---@field keep_prefixes? string[]
---@field reports table<string, Testing.Isolation.Report> The last report per file, for the run's summary.
local Session = {}
Session.__index = Session

---A session. Cheap; the state is captured per file in `enter`.
---@param opts? Testing.Isolation.Opts
---@return Testing.Isolation.Session
function M.new(opts)
  opts = opts or {}
  local backend, name
  if opts.backend then
    backend, name = opts.backend, "injected"
  else
    backend, name = M.backend()
  end
  local skip = {}
  for _, kind in ipairs(opts.skip_kinds or {}) do
    skip[kind] = true
  end
  return setmetatable({
    backend = backend,
    backend_name = name,
    keep = opts.keep or {},
    severity = opts.severity,
    report_restored = opts.report_restored ~= false,
    skip = skip,
    keep_prefixes = opts.keep_prefixes,
    reports = {},
  }, Session)
end

---Snapshot before a file runs.
---@param rel string Spec file (project-relative), named in the findings.
---@return Testing.Isolation.Frame|nil frame Nil when the snapshot itself failed (the file then runs unprotected; `leave(nil)` reports that).
function Session:enter(rel)
  local started = vim.uv.hrtime()
  local ok, snap = pcall(self.backend.capture)
  if not ok then
    return nil
  end
  return { rel = rel, before = snap, started = started }
end

---@param rel string
---@param item Testing.Isolation.Item
---@param restored boolean
---@param why string|nil
---@return string
local function describe(rel, item, restored, why)
  local head
  if item.change == "added" then
    head = ("%s leaves %s"):format(rel, item.name)
  else
    head = ("%s changes state: %s"):format(rel, item.name)
  end
  if restored then
    return head .. " (restored before the next file)"
  end
  return head .. (" (NOT restored: %s)"):format(why or "unknown reason")
end

---The entries of a diff without the kinds this session leaves alone.
---@param self Testing.Isolation.Session
---@param entries Testing.Isolation.Entry[]
---@return Testing.Isolation.Entry[]
local function wanted(self, entries)
  if next(self.skip) == nil then
    return entries
  end
  local out = {}
  for _, e in ipairs(entries) do
    if not self.skip[e.kind] then
      out[#out + 1] = e
    end
  end
  return out
end

---Diff, restore and verify after a file ran.
---@param frame Testing.Isolation.Frame|nil
---@return Testing.Isolation.Report
function Session:leave(frame)
  ---@type Testing.Isolation.Report
  local report = { findings = {}, items = {}, restored = 0, unrestored = 0, ms = 0 }
  local sev = self.severity
  if not frame then
    if sev then
      report.findings[1] = {
        guard = "state",
        severity = "warn",
        message = "soft isolation could not take its snapshot; this file ran without a restore",
      }
    end
    return report
  end
  local ok, err = pcall(function()
    local b = self.backend
    local after = b.capture()
    local entries = wanted(
      self,
      b.diff(frame.before, after, { keep = self.keep, keep_prefixes = self.keep_prefixes })
    )
    if #entries == 0 then
      return
    end
    local failures = b.restore(entries)
    if b.refocus then
      pcall(b.refocus, frame.before)
    end
    -- never trust a restore: look again, whatever is still different was not restored
    local left = {}
    local again = b.capture()
    for _, e in
      ipairs(
        wanted(
          self,
          b.diff(frame.before, again, { keep = self.keep, keep_prefixes = self.keep_prefixes })
        )
      )
    do
      left[e.key] = true
    end
    for _, e in ipairs(entries) do
      local restored = not left[e.key] and failures[e.key] == nil
      local why = failures[e.key]
        or (left[e.key] and (e.why or "it was still there afterwards"))
        or nil
      report.items[#report.items + 1] =
        { kind = e.kind, change = e.change, name = e.name, restored = restored, why = why }
      if restored then
        report.restored = report.restored + 1
      else
        report.unrestored = report.unrestored + 1
      end
    end
  end)
  if not ok then
    report.items[#report.items + 1] = {
      kind = "isolation",
      change = "changed",
      name = "soft isolation failed",
      restored = false,
      why = tostring(err),
    }
    report.unrestored = report.unrestored + 1
  end
  if sev then
    local listed = report.items
    if not self.report_restored then
      listed = {}
      for _, item in ipairs(report.items) do
        if not item.restored then
          listed[#listed + 1] = item
        end
      end
    end
    for i, item in ipairs(listed) do
      if i > M.MAX_FINDINGS then
        report.findings[#report.findings + 1] = {
          guard = "state",
          severity = sev,
          message = ("%s: ... and %d more difference(s) not listed"):format(
            frame.rel,
            #listed - M.MAX_FINDINGS
          ),
        }
        break
      end
      report.findings[#report.findings + 1] = {
        guard = "state",
        severity = sev,
        message = describe(frame.rel, item, item.restored, item.why),
      }
    end
  end
  report.ms = (vim.uv.hrtime() - frame.started) / 1e6
  self.reports[frame.rel] = report
  return report
end

---Totals over the run (for a one-line summary).
---@return { files: integer, leaky_files: integer, restored: integer, unrestored: integer }
function Session:totals()
  local t = { files = 0, leaky_files = 0, restored = 0, unrestored = 0 }
  for _, r in pairs(self.reports) do
    t.files = t.files + 1
    if #r.items > 0 then
      t.leaky_files = t.leaky_files + 1
    end
    t.restored = t.restored + r.restored
    t.unrestored = t.unrestored + r.unrestored
  end
  return t
end

return M
