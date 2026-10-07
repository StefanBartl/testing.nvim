---@module 'testing.run.retry'
---@brief `--retry-failed <n>`: a red case runs again; one that passes is FLAKY, and flaky is never green by itself.
---@description
--- A test that fails and then passes is not a test that passes: it is a test that cannot be trusted, and a
--- run that turns it green hides exactly that (Bazel calls such a case FLAKY and does not let it pass either).
--- So this module repeats, and it keeps the verdict honest:
---
---   * only the files that have a red case run again, and only the cases that were red are looked at (the
---     rest of such a file ran again too, but what it did the first time stands);
---   * a case that passes on a retry stays what it was, a failure, and is marked `flaky = true` with
---     `retries = <the retry that passed>` and a note: the run stays RED, the exit code is 1;
---   * `--allow-flaky` is the explicit choice to count it as green: the passing result replaces the red one
---     (`flaky = true`, `retries = k`, a note that holds the first failure), the verdict and the exit code are
---     recounted, and the flaky cases are listed in the output, never silently;
---   * a case that fails on every retry is plainly red (`retries = n`);
---   * a `timeout` or a `crash` is not repeated: it already cost the whole time limit, and a process that
---     died is a verdict about the process; `xpass` is a verdict about the expectation, not about luck;
---   * a flaky file is never stored in the result cache (a case with `retries > 0` is refused there, and the
---     file is reported to `testing.run.cached` as flaky).
---
--- The runner is given by the caller (`opts.rerun`): this module knows nothing about processes.

local M = {}

---Most retries (`--retry-failed` is refused above it).
---@type integer
M.MAX = 10

---Statuses that are repeated.
---@type table<string, true>
M.RETRYABLE = { fail = true, error = true }

---@class Testing.Retry.Opts
---@field retries integer 1..`M.MAX`.
---@field allow_flaky? boolean A case that passes on a retry counts as green.
---@field strict? boolean The runner's `--strict` (a skipped case makes the exit code red).
---@field files Testing.Discover.File[] The files the report is about (the retry only touches these).
---@field rerun fun(files: Testing.Discover.File[]): Testing.Inproc.Report|nil, string|nil Runs these files again.
---@field bad table<string, true> The statuses that make a run red (`inproc.BAD`).

---@class Testing.Retry.Info
---@field retries integer The bound that was asked for.
---@field allow_flaky boolean
---@field flaky { id: string, file: string, retry: integer }[] Cases that failed and then passed.
---@field red { id: string, file: string, retries: integer }[] Cases that failed on every retry.
---@field missing { id: string, file: string, absent: integer }[] Cases a retry's output did not contain at all (not run again, neither flaky nor red by retry).
---@field files integer Files that ran again.
---@field error? string Why the retries stopped early (a runner that raised).

---The first line of what went wrong in a case (a thrown error, or the first failed assertion).
---@param c Testing.Result.Case
---@return string
local function first_failure(c)
  if c.error and c.error.message then
    return (tostring(c.error.message):match("^[^\r\n]*"))
  end
  for _, a in ipairs(c.assertions or {}) do
    if a.ok == false then
      return (tostring(a.msg or "an assertion failed"):match("^[^\r\n]*"))
    end
  end
  return c.status
end

---Repeat the red cases of `report`; `report` is changed in place.
---@param report Testing.Inproc.Report
---@param o Testing.Retry.Opts
---@return Testing.Retry.Info info
function M.apply(report, o)
  local res = report.result
  local info = {
    retries = o.retries,
    allow_flaky = o.allow_flaky == true,
    flaky = {},
    red = {},
    missing = {},
    files = 0,
  }
  local in_run = {}
  for _, f in ipairs(o.files) do
    in_run[f.rel] = true
  end

  -- what is red, per file
  local pending = {}
  for _, c in ipairs(res.cases) do
    if M.RETRYABLE[c.status] and in_run[c.file] and not c.cached then
      pending[c.file] = pending[c.file] or {}
      pending[c.file][c.id] = true
    end
  end

  ---@type table<string, { attempt: integer, case: Testing.Result.Case }>
  local passed = {}
  ---@type table<string, integer> retries in which the case ran again and did not pass
  local made = {}
  ---@type table<string, integer> retries whose output did not contain the case at all
  local absent = {}
  local ran = {}
  for attempt = 1, math.min(o.retries, M.MAX) do
    local list = {}
    for _, f in ipairs(o.files) do
      if pending[f.rel] and next(pending[f.rel]) ~= nil then
        list[#list + 1] = f
      end
    end
    if #list == 0 then
      break
    end
    local again, why = o.rerun(list)
    if not again then
      info.error = tostring(why or "the retry did not run")
      break
    end
    local by_id = {}
    for _, c in ipairs(again.result.cases) do
      by_id[c.id] = c
    end
    for _, f in ipairs(list) do
      ran[f.rel] = true
      local ids = vim.tbl_keys(pending[f.rel])
      for _, id in ipairs(ids) do
        local c2 = by_id[id]
        if c2 == nil then
          -- the retry did not report the case (a file that stopped early, a renamed case): it did not run again
          absent[id] = (absent[id] or 0) + 1
        elseif c2.status == "pass" then
          made[id] = (made[id] or 0) + 1
          passed[id] = { attempt = attempt, case = c2 }
          pending[f.rel][id] = nil
        else
          made[id] = (made[id] or 0) + 1
        end
      end
    end
  end
  for _ in pairs(ran) do
    info.files = info.files + 1
  end

  local flaky_files = {}
  local replaced = false
  for i, c in ipairs(res.cases) do
    local attempts = made[c.id]
    local gone = absent[c.id]
    if (attempts or gone) and M.RETRYABLE[c.status] and in_run[c.file] then
      local hit = passed[c.id]
      if hit then
        info.flaky[#info.flaky + 1] = { id = c.id, file = c.file, retry = hit.attempt }
        flaky_files[c.file] = true
        if o.allow_flaky then
          local fresh = hit.case
          fresh.retries = hit.attempt
          fresh.flaky = true
          fresh.notes[#fresh.notes + 1] = ("flaky: failed first (%s), passed on retry %d of %d: counted as green by --allow-flaky"):format(
            first_failure(c),
            hit.attempt,
            o.retries
          )
          res.cases[i] = fresh
          replaced = true
        else
          c.retries = hit.attempt
          c.flaky = true
          c.notes[#c.notes + 1] = ("flaky: failed, then passed on retry %d of %d: the run stays red (--allow-flaky counts it as green)"):format(
            hit.attempt,
            o.retries
          )
        end
      elseif gone then
        -- never claim "failed on all N retries" for a case the retries did not even report
        if attempts then
          c.retries = attempts
        end
        c.notes[#c.notes + 1] = ("missing from the output of %d retr%s: not run again"):format(
          gone,
          gone == 1 and "y" or "ies"
        )
        info.missing[#info.missing + 1] = { id = c.id, file = c.file, absent = gone }
      else
        c.retries = attempts
        c.notes[#c.notes + 1] = ("failed on all %d retr%s as well"):format(
          attempts,
          attempts == 1 and "y" or "ies"
        )
        info.red[#info.red + 1] = { id = c.id, file = c.file, retries = attempts }
      end
    end
  end
  report.flaky_files = flaky_files

  if replaced then
    -- the verdict is recounted from the cases: what turned green is no longer red
    local bad, files = 0, {}
    for _, c in ipairs(res.cases) do
      if o.bad[c.status] then
        bad = bad + 1
        files[c.file] = true
      end
    end
    local nfiles = 0
    for _ in pairs(files) do
      nfiles = nfiles + 1
    end
    require("testing.core.result").finalize(res)
    report.failed = bad
    report.failed_files = nfiles
    report.skipped = res.summary.skip
    report.exit_code = (bad > 0 or (o.strict and report.skipped > 0)) and 1 or 0
  end
  return info
end

---The lines that tell what the retries found (for the end of the output).
---@param info Testing.Retry.Info
---@return string[]
function M.lines(info)
  local lines = {}
  if #info.flaky > 0 then
    if info.allow_flaky then
      lines[#lines + 1] = ("flaky: %d case(s) failed and then passed on a retry; --allow-flaky counts them as green, they are never cached:"):format(
        #info.flaky
      )
    else
      lines[#lines + 1] = ("flaky: %d case(s) failed and then passed on a retry: the run stays RED (--allow-flaky counts them as green):"):format(
        #info.flaky
      )
    end
    for _, f in ipairs(info.flaky) do
      lines[#lines + 1] = ("  %s  (passed on retry %d of %d)"):format(f.id, f.retry, info.retries)
    end
  end
  if #info.red > 0 then
    lines[#lines + 1] = ("retry: %d case(s) failed on all %d retr%s as well (red, not flaky)"):format(
      #info.red,
      info.retries,
      info.retries == 1 and "y" or "ies"
    )
  end
  if #info.missing > 0 then
    lines[#lines + 1] = ("retry: %d case(s) were missing from the output of a retry (not run again, still red)"):format(
      #info.missing
    )
  end
  if info.error then
    lines[#lines + 1] = "retry: stopped early: " .. info.error
  end
  return lines
end

return M
