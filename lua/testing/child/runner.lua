---@module 'testing.child.runner'
---@brief Runs ONE spec file inside a child editor and writes its records: shared by the per-file child and the warm pool.
---@description
--- `testing.child.boot` (a fresh editor per file) and the warm pool member (`testing.child.pool_boot`,
--- an editor that runs file after file) both end up here, so a case is produced, selected, guarded and
--- streamed by exactly one piece of code whatever process model carries it:
---
---   * the file runs through `testing.run.inproc` (the same driver an in-process run uses) with the
---     selector, the `--lf` ids, the timeouts, the assertion policy and the seed of the job;
---   * the guard layer (`job.guard`, the configuration `options.guard_config` built in the parent) is
---     installed for the run of the file and uninstalled with it; its findings and effects land in the
---     cases the fragment carries;
---   * every case is streamed (`progress`) the moment it is over and written again as its final
---     record (`case`) when the file ends, then a `done` record closes the fragment
---     (`testing.child.fragment`): what a kill by the parent leaves behind is exactly the progress;
---   * `ctx.prompts` (per-file child) names the prompts the boot answered with "cancelled" on the case
---     that was running.
---
--- The module returns data and never exits the editor: the caller decides what the end of the file
--- means (a per-file child ends the process, a pool member resets itself).

local fragment = require("testing.child.fragment")

local M = {}

---@class Testing.Child.RunnerCtx
---@field prompts? string[] Names of the prompts answered with "cancelled", appended to by the boot as they happen.
---@field soft? Testing.Isolation.Session Soft isolation around the file (warm pool).

---@class Testing.Child.RunnerResult
---@field ok boolean The driver ran (a red case is still `ok`).
---@field err? string The driver or the fragment failed.
---@field report? Testing.Inproc.Report

---The selector and the `--lf` map of a job (what the parent's selection options said).
---@param job table
---@return Testing.Select.Selector selector
---@return table<string, table<string, true>>|nil lf
local function build_selector(job)
  local select_mod = require("testing.run.select")
  local rel = (job.entry or {}).rel
  local sel = job.selector or {}
  local header_cache
  local selector = select_mod.new({
    filter = sel.filter,
    tags = sel.tags,
    exclude_tags = sel.exclude_tags,
    header_tags = function(r)
      if header_cache == nil then
        header_cache = select_mod.file_header_tags(job.root .. "/" .. r)
      end
      return header_cache
    end,
  })
  local lf
  if job.lf_ids then
    local ids = {}
    for _, id in ipairs(job.lf_ids) do
      ids[id] = true
    end
    lf = { [rel] = ids }
  end
  return selector, lf
end

---List what the file of `job` would run (`kind = "list"`): the describe bodies run HERE, in a
---throwaway editor with the sanitized environment and the sandbox, no `it` body does. The items go
---into the fragment as one `list` record. This is how `isolated = "case"` learns the case ids
---without running the spec's top-level code in the parent editor.
---@param job table
---@return Testing.Child.RunnerResult
function M.list(job)
  local inproc = require("testing.run.inproc")
  local entry = job.entry or {}
  local selector, lf = build_selector(job)
  local ok, items = pcall(inproc.list, {
    root = job.root,
    files = { entry },
    selector = selector,
    lf = lf,
    timeouts = job.timeouts or {},
  })
  if not ok then
    return { ok = false, err = "the listing failed: " .. tostring(items) }
  end
  local wok, werr = fragment.append(job.fragment, { k = "list", items = items })
  if not wok then
    return { ok = false, err = "cannot write the fragment: " .. tostring(werr) }
  end
  return { ok = true }
end

---Run the file of `job` and write its records.
---@param job table The job (see `testing.child.boot`): `entry`, `root`, `fragment`, `selector`, `lf_ids`, `timeouts`, `assertions`, `seed`, `guard`.
---@param ctx? Testing.Child.RunnerCtx
---@return Testing.Child.RunnerResult
function M.run(job, ctx)
  ctx = ctx or {}
  local inproc = require("testing.run.inproc")
  local project = require("testing.run.project")

  local entry = job.entry or {}
  local rel = entry.rel
  local selector, lf = build_selector(job)

  local prompts = ctx.prompts
  local noted = prompts and #prompts or 0
  local write_failed

  ---Fix up a case before it is written: the `<late>` bucket belongs to this file, and the prompts that
  ---were answered with "cancelled" since the last case are named on it.
  ---@param case Testing.Result.Case
  local function annotate(case)
    if case.file == "<late>" then
      case.file = rel
      case.id = rel .. "::late assertions"
    end
    if prompts and #prompts > noted then
      local counts = {}
      for i = noted + 1, #prompts do
        counts[prompts[i]] = (counts[prompts[i]] or 0) + 1
      end
      local names = vim.tbl_keys(counts)
      table.sort(names)
      for _, name in ipairs(names) do
        case.notes[#case.notes + 1] = ("%s() was called %d time(s) and answered with 'cancelled' (a child has no stdin)"):format(
          name,
          counts[name]
        )
      end
      noted = #prompts
    end
  end

  ---@param kind "case"|"progress"
  ---@param case Testing.Result.Case
  local function write(kind, case)
    annotate(case)
    local ok, err = fragment.append(job.fragment, { k = kind, case = case })
    if not ok then
      write_failed = err
    end
  end

  local release = project.guard_exit()
  local ran, report = pcall(inproc.run, {
    root = job.root,
    files = { entry },
    selector = selector,
    lf = lf,
    timeouts = job.timeouts or {},
    assertions = job.assertions,
    seed = job.seed,
    skip_facts = true,
    soft = ctx.soft,
    -- the guard layer is installed for this file's run and uninstalled with it (a pool member that
    -- runs many files must not stack patches); its findings are in the cases when `on_case` sees them
    guard_cfg = job.guard,
    -- streamed while the file runs: what a kill by the pool leaves behind
    on_case_early = function(case)
      write("progress", case)
    end,
    -- the final cases, when the file is over
    on_case = function(case)
      write("case", case)
    end,
  })
  release()
  if not ran then
    return { ok = false, err = "the driver failed: " .. tostring(report) }
  end
  if write_failed then
    return { ok = false, err = "cannot write the fragment: " .. tostring(write_failed) }
  end
  local dok, derr = fragment.append(job.fragment, {
    k = "done",
    files_run = report.files_run,
    files_unselected = report.files_unselected,
    total = report.total,
    -- what the guard layer had to say that no case carries: the parent prints it (`run.isolated`)
    notes = report.notes,
    unattached = report.unattached,
  })
  if not dok then
    return { ok = false, err = "cannot write the fragment: " .. tostring(derr) }
  end
  return { ok = true, report = report }
end

return M
