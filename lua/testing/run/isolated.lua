---@module 'testing.run.isolated'
---@brief The isolated driver: one child editor per spec file, a pool of them, one merged Result-IR.
---@description
--- Same contract as `testing.run.inproc.run` (it returns the same report) but the files that need
--- isolation run in a child editor of their own (`testing.child`), because shared `package.loaded`,
--- globals, autocmds and a hung or crashing native library would otherwise decide the verdict of the
--- files after them. Files that do not need isolation (`options.isolation_of`) still run in this
--- editor, in file order.
---
--- THE POOL. `jobs` children at most run at once; the permits are a `lib.nvim.async.Semaphore`
--- (`Semaphore:with` releases on every path). A single supervisor loop on the main thread polls the
--- children for their hard deadlines, merges finished files STRICTLY IN FILE ORDER (a file is merged
--- only when all files before it are), prints their captured output in that order and applies
--- `--maxfail` on the merged order, so the IR, the terminal lines and the exit code are the same for
--- `jobs = 1` and `jobs = 8` whatever order the children finish in. A failing child never stops the
--- others; after `--maxfail` the running children are killed and their results dropped (files after
--- the stop point are "not run", exactly as in-process).
---
--- WHAT BECOMES OF A CHILD (`classify`)
---   * it finished (`done` record, exit code 0): its cases, as it recorded them;
---   * the hard deadline killed it: the cases it finished, plus ONE `timeout` case for the file;
---   * it died (exit code != 0, signal, native crash, `os.exit` by the spec, no `done` record, an
---     unreadable fragment): the cases it finished, plus ONE `crash` case with the exit description
---     and the tail of its stderr. The run goes on; the exit code of the run is 1;
---   * a `script` file (self-running): ONE case; the verdict is the exit code AND the `[FAIL]` lines
---     it printed (never greener than the script's own report); a signal / native crash is `crash`.
---
--- HARD DEADLINES. A child that stops reporting is killed with its whole process tree:
---   * file: `file_ms` + `GRACE_MS` since the start (the child's own best-effort guard fires at
---     `file_ms` and normally ends the file with a precise message first);
---   * case (busted files only): `case_ms` + `GRACE_MS` without a NEW record in the fragment once the
---     first one is there (loading a file with big `describe` bodies, on a loaded machine, is not a
---     stuck case; until the first record only the file deadline counts).
---
--- The parent does not trust a fragment (`testing.child.fragment.check`). Path placeholders and
--- redaction are applied once, on the merged IR, by the same `sanitize` an in-process run uses.

local async = require("lib.nvim.async")
local result = require("testing.core.result")
local assert_mod = require("testing.core.assert")
local select_mod = require("testing.run.select")
local inproc = require("testing.run.inproc")
local options_mod = require("testing.run.options")
local fragment_mod = require("testing.child.fragment")

local M = {}

---Time a killed-by-deadline child gets on top of the configured limit (ms).
M.GRACE_MS = 2000
---Supervisor period (ms).
M.POLL_MS = 25
---A kill that did not end the process within this time is repeated on the root process (ms).
M.KILL_RETRY_MS = 3000
---How long the pool waits for killed children to be gone before it gives up (ms).
M.REAP_MS = 10000
---Cap of the output tail kept in a note / crash message (characters).
M.TAIL_CHARS = 1500

local EFFECTS_NOTE = "effects: not collected (M1); the empty effects lists are not a measurement"

---@param s string
---@return string
local function tail(s, n)
  s = s:gsub("%s+$", "")
  if #s <= n then
    return s
  end
  -- keep whole UTF-8 characters
  local cut = #s - n + 1
  while cut <= #s and s:byte(cut) >= 0x80 and s:byte(cut) < 0xC0 do
    cut = cut + 1
  end
  return "..." .. s:sub(cut)
end

---@param rel string
---@param name string
---@param status Testing.Status
---@param message string
---@return Testing.Result.Case
local function synthetic(rel, name, status, message)
  local case = result.new_case({ file = rel, name = name })
  case.status = status
  case.error = { message = message, traceback = message }
  return case
end

---Unique id for a synthetic case next to the cases a child already reported.
---@param rel string
---@param existing Testing.Result.Case[]
---@return string name
local function free_name(rel, existing)
  local base = vim.fs.basename(rel)
  local taken = {}
  for _, c in ipairs(existing) do
    taken[c.id] = true
  end
  local name, n = base, 1
  while taken[rel .. "::" .. name] do
    n = n + 1
    name = ("%s#%d"):format(base, n)
  end
  return name
end

---@class Testing.Isolated.ClassifyInput
---@field rel string
---@field kind "cases"|"script"
---@field frag Testing.Child.Fragment
---@field code integer|nil Exit code (nil: not available).
---@field signal integer|nil
---@field reason? "file"|"stall"|"cancel" Why the parent killed the child.
---@field out string Everything the child printed (stdout and stderr, arrival order).
---@field stdout string What it wrote to stdout.
---@field err string What it wrote to stderr.
---@field assertions? "error"|"warn" Policy for a script case without assertions.
---@field wall_ms number
---@field file_ms? integer
---@field case_ms? integer
---@field grace_ms integer
---@field describe_exit string Text for "how it ended".
---@field abandoned? boolean The process did not end after the kill and was given up on.

---Signals / NTSTATUS values that mean "the editor itself died", for a script whose own non-zero exit
---code is otherwise its verdict.
---@param code integer|nil
---@param signal integer|nil
---@return boolean
local function died_natively(code, signal)
  if signal and signal ~= 0 then
    return true
  end
  if not code then
    return false
  end
  if code >= 0xC0000000 then
    return true
  end
  -- 128 + SIGILL/SIGABRT/SIGBUS/SIGFPE/SIGSEGV as a shell reports a signalled child
  return code == 132 or code == 134 or code == 135 or code == 136 or code == 139
end

---Cases of a `script` file: one case, built by `testing.dialect.script` from the exit code AND the
---printed failure lines (never greener than the script's own report).
---@param input Testing.Isolated.ClassifyInput
---@return Testing.Result.Case[]
local function classify_script(input)
  local rel = input.rel
  local a = assert_mod.new()
  local case = require("testing.dialect.script").build_case(a, rel, {
    code = input.code,
    stdout = input.stdout,
    stderr = input.err,
    timed_out = input.reason == "file",
    crashed = died_natively(input.code, input.signal),
    timeout_ms = input.file_ms,
  }, { assertions = input.assertions })
  case.duration_ms = input.wall_ms
  return { case }
end

---@param input Testing.Isolated.ClassifyInput
---@return string
local function abandoned_note(input)
  if not input.abandoned then
    return ""
  end
  return "\nthe process did not end after the kill and was abandoned (it may still be running)"
end

---Turn what a child left behind into the cases of its file. Pure: inputs in, cases out.
---@param input Testing.Isolated.ClassifyInput
---@return Testing.Result.Case[] cases
function M.classify(input)
  if input.kind == "script" then
    return classify_script(input)
  end
  local rel = input.rel
  local cases = {}
  local problem
  do
    -- a finished file has its final records; a killed or dead one only what was streamed
    local source = input.frag.cases
    if #source == 0 and input.frag.done == nil then
      source = input.frag.progress or {}
    end
    local ok, problems = fragment_mod.check(source, rel)
    if ok then
      cases = source
    else
      problem = "the child returned an invalid result:\n  "
        .. table.concat(vim.list_slice(problems, 1, 5), "\n  ")
    end
  end

  local extra
  if input.reason == "file" then
    extra = synthetic(
      rel,
      free_name(rel, cases),
      "timeout",
      ("testing: timeout: file exceeded %s ms (+%d ms grace); the child's process tree was killed: %s"):format(
        tostring(input.file_ms),
        input.grace_ms,
        rel
      ) .. abandoned_note(input)
    )
  elseif input.reason == "stall" then
    extra = synthetic(
      rel,
      free_name(rel, cases),
      "timeout",
      ("testing: timeout: a case exceeded %s ms (+%d ms grace) without finishing; the child's process tree was killed: %s"):format(
        tostring(input.case_ms),
        input.grace_ms,
        rel
      ) .. abandoned_note(input)
    )
  elseif problem then
    extra = synthetic(rel, free_name(rel, {}), "error", problem)
    if input.reason == nil and (input.code ~= 0 or (input.signal or 0) ~= 0) then
      extra.status = "crash"
    end
  elseif input.frag.done == nil or input.code ~= 0 or (input.signal or 0) ~= 0 then
    local why
    -- a signalled child reports exit code 0 plus a signal on POSIX (libuv): that is a death, not a quit
    if input.frag.done == nil and input.code == 0 and (input.signal or 0) == 0 then
      why =
        "the editor exited with code 0 before the file was finished (the spec quit the editor, or stdin ended)"
    else
      why = "the editor died: " .. input.describe_exit
    end
    local err_tail = tail(input.err, M.TAIL_CHARS)
    extra = synthetic(
      rel,
      free_name(rel, cases),
      "crash",
      ("%s: %s%s"):format(rel, why, err_tail ~= "" and ("\nstderr: " .. err_tail) or "")
    )
  end
  if extra then
    extra.duration_ms = input.wall_ms
    cases[#cases + 1] = extra
  end
  return cases
end

-- =========================================================
-- The pool
-- =========================================================

---@class Testing.Isolated.Opts
---@field root string
---@field files (Testing.Discover.File|string)[]
---@field dialect? string
---@field argv? string[]
---@field selector? Testing.Select.Selector
---@field selector_spec? { filter?: string[], tags?: string[], exclude_tags?: string[] } What the children rebuild their selector from.
---@field lf? table<string, table<string, true>>
---@field maxfail? integer
---@field seed? integer
---@field timeouts? Testing.Child.Timeouts
---@field findings? Testing.Discover.Finding[]
---@field strict? boolean
---@field on_case? fun(case: Testing.Result.Case)
---@field on_output? fun(rel: string, text: string) Captured output of a file, called in file order.
---@field clock? Testing.Assert.Clock
---@field options? Testing.Run.Options
---@field rtp_prepend? string[]
---@field rtp? string[]
---@field child_env? table<string, string> `$<NAME>_DIR` of the resolved dependencies, set in every child.
---@field minit? string Absolute path of the project's minimal init (run in each child).
---@field grace_ms? integer
---@field poll_ms? integer
---@field nvim? string
---@field sandbox_base? string
---@field child? table `testing.child` (seam for specs)

---@class Testing.Isolated.Slot
---@field index integer
---@field entry Testing.Inproc.Entry
---@field kind "synthetic"|"unselected"|"child"|"inproc"
---@field state "waiting"|"running"|"done"
---@field cases? Testing.Result.Case[]
---@field output? string
---@field lf_ids? string[]
---@field handle? Testing.Child.Handle
---@field plan? Testing.Child.Plan

---Plain, JSON-safe copy of a discovered file for the job.
---@param entry table
---@return table
local function serializable(entry)
  local out = {}
  for k, v in pairs(entry) do
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
      out[k] = v
    end
  end
  return out
end

---Run the planned files; same report as `inproc.run`.
---@param opts Testing.Isolated.Opts
---@return Testing.Inproc.Report
function M.run(opts)
  local root = opts.root:gsub("\\", "/"):gsub("/+$", "")
  local o = opts.options or options_mod.of({})
  local child = opts.child or require("testing.child")
  local grace = opts.grace_ms or M.GRACE_MS
  local poll = opts.poll_ms or M.POLL_MS
  local timeouts = opts.timeouts or {}
  local maxfail = opts.maxfail
  local entries = inproc.entries_of(root, opts.files, opts.dialect or "a")

  local a = assert_mod.new({ clock = opts.clock })
  local res = inproc.begin_result(root, { seed = opts.seed, argv = opts.argv, jobs = o.jobs })

  local header_cache = {}
  ---@param rel string
  ---@return string[]
  local function header_tags(rel)
    if header_cache[rel] == nil then
      header_cache[rel] = select_mod.file_header_tags(root .. "/" .. rel)
    end
    return header_cache[rel]
  end
  local selector = opts.selector or select_mod.new({ header_tags = header_tags })

  local state = { stopped = false, fatal = nil }
  local bad_total = 0
  local files_run, files_unrun, files_unselected = 0, 0, 0
  local failed_files = {}

  ---@param case Testing.Result.Case
  local function record(case)
    local has_note = false
    for _, n in ipairs(case.notes) do
      if n == EFFECTS_NOTE then
        has_note = true
      end
    end
    if not has_note then
      case.notes[#case.notes + 1] = EFFECTS_NOTE
    end
    case.tags = select_mod.union(select_mod.tags_of_id(case.id), header_tags(case.file))
    result.add_case(res, case)
    if inproc.BAD[case.status] then
      bad_total = bad_total + 1
      failed_files[case.file] = true
    end
    if opts.on_case then
      pcall(opts.on_case, case)
    end
  end

  -- ---- classify every entry --------------------------------------------------------------
  ---@type Testing.Isolated.Slot[]
  local slots = {}
  for i, entry in ipairs(entries) do
    local rel = entry.rel
    local slot = { index = i, entry = entry, state = "waiting", kind = "child" } --[[@as Testing.Isolated.Slot]]
    local lf_ids = opts.lf and select_mod.lf_ids(rel, opts.lf) or nil
    local function accept(id)
      if lf_ids ~= nil and not lf_ids[id] then
        return false
      end
      return selector.case_ok(id, rel)
    end
    local is_busted = entry.dialect == "busted" and not entry.missing
    if entry.missing then
      slot.kind, slot.state = "synthetic", "done"
      slot.cases = {
        synthetic(
          rel,
          vim.fs.basename(rel),
          "error",
          entry.reason or "listed in the project's runner but not on disk"
        ),
      }
    elseif entry.dialect == "unknown" then
      slot.kind, slot.state = "synthetic", "done"
      slot.cases = {
        synthetic(
          rel,
          vim.fs.basename(rel),
          "error",
          ("dialect unknown, file not run: %s (set `dialect` in .testing.lua to run it)"):format(
            tostring(entry.reason or "?")
          )
        ),
      }
    elseif not is_busted and not accept(select_mod.file_case_id(rel)) then
      slot.kind, slot.state = "unselected", "done"
    elseif options_mod.isolation_of(o, entry) == "file" then
      slot.kind = "child"
      if lf_ids then
        local list = vim.tbl_keys(lf_ids)
        table.sort(list)
        slot.lf_ids = list
      end
    else
      slot.kind = "inproc"
    end
    slots[i] = slot
  end

  local hrtime = vim.uv.hrtime
  local started = hrtime()
  local sem = async.Semaphore.new(o.jobs)
  ---@type Testing.Isolated.Slot[]
  local live = {}

  ---@param slot Testing.Isolated.Slot
  ---@param message string
  local function fail_slot(slot, message)
    slot.cases = { synthetic(slot.entry.rel, vim.fs.basename(slot.entry.rel), "error", message) }
    slot.state = "done"
  end

  ---@param slot Testing.Isolated.Slot
  local function run_child(slot)
    if state.stopped then
      slot.state = "done"
      return
    end
    local entry = slot.entry
    local rel = entry.rel
    local kind = entry.dialect == "script" and "script" or "cases"
    local plan = child.build({
      entry = serializable(entry),
      root = root,
      kind = kind,
      minit = opts.minit,
      assertions = o.assertions,
      host = options_mod.host_of(o, entry),
      rtp_prepend = opts.rtp_prepend,
      rtp = opts.rtp,
      filetype = o.filetype,
      selector = opts.selector_spec,
      lf_ids = slot.lf_ids,
      timeouts = timeouts,
      seed = opts.seed,
      env_allow = o.env_allow,
      extra_env = opts.child_env,
      nvim = opts.nvim,
      base = opts.sandbox_base,
    })
    slot.plan = plan
    local pok, perr = child.prepare(plan)
    if not pok then
      fail_slot(slot, ("%s: %s"):format(rel, tostring(perr)))
      child.cleanup(plan)
      return
    end
    local is_busted = entry.dialect == "busted"
    ---@type Testing.Child.Handle|nil
    local handle
    local serr
    local exited = async.await(function(resume)
      handle, serr = child.spawn(plan, resume)
      if handle then
        handle.reason = nil
        handle.deadline = timeouts.file_ms and (handle.started_ms + timeouts.file_ms + grace) or nil
        handle.stall_limit = (is_busted and timeouts.case_ms) and (timeouts.case_ms + grace) or nil
        handle.progress_ms = handle.started_ms
        handle.frag_size = 0
        slot.handle = handle
        slot.state = "running"
        live[#live + 1] = slot
      else
        resume(nil)
      end
    end)
    if not exited then
      fail_slot(slot, ("%s: %s"):format(rel, tostring(serr)))
      child.cleanup(plan)
      return
    end
    local h = exited --[[@as Testing.Child.Handle]]
    local exit = h.exit or {}
    local frag = fragment_mod.read(plan.fragment)
    local out = child.text(h.out)
    slot.output = out
    local cases = M.classify({
      rel = rel,
      kind = kind,
      frag = frag,
      code = exit.code,
      signal = exit.signal,
      reason = h.reason,
      out = out,
      stdout = child.text(h.stdout),
      err = child.text(h.err),
      assertions = o.assertions,
      wall_ms = (vim.uv.hrtime() / 1e6) - h.started_ms,
      file_ms = timeouts.file_ms,
      case_ms = timeouts.case_ms,
      grace_ms = grace,
      describe_exit = child.describe_exit(exit),
      abandoned = h.abandoned,
    })
    -- the child's output explains a red file: one note on its first red case
    if out ~= "" then
      for _, c in ipairs(cases) do
        if inproc.BAD[c.status] then
          c.notes[#c.notes + 1] = "output of the child (tail): " .. tail(out, M.TAIL_CHARS)
          break
        end
      end
    end
    slot.cases = cases
    slot.state = "done"
    child.cleanup(plan)
  end

  -- one coroutine per child file; the semaphore decides how many run at once, FIFO
  for _, slot in ipairs(slots) do
    if slot.kind == "child" then
      async.run(
        function()
          local ok, err = sem:with(run_child, slot)
          if not ok then
            if slot.handle and not slot.handle.exited then
              child.kill_tree(slot.handle)
            end
            fail_slot(slot, ("%s: internal error: %s"):format(slot.entry.rel, vim.inspect(err)))
            if slot.plan then
              child.cleanup(slot.plan)
            end
          end
        end,
        nil,
        {
          tag = "testing.run.isolated",
          on_error = function(e)
            state.fatal = tostring(e)
          end,
        }
      )
    end
  end

  -- ---- supervisor ------------------------------------------------------------------------
  local function supervise()
    local t = hrtime() / 1e6
    for _, slot in ipairs(live) do
      local h = slot.handle
      if h and not h.exited then
        if h.kill_requested_ms then
          if h.first_kill_ms == nil then
            h.first_kill_ms = h.kill_requested_ms
          end
          if t - h.first_kill_ms > M.REAP_MS and child.abandon then
            -- the kill did not end the process: stop waiting for it (an absolute upper bound)
            child.abandon(h)
          elseif t - h.kill_requested_ms > M.KILL_RETRY_MS then
            child.kill_tree(h)
            h.kill_requested_ms = t
          end
        elseif state.stopped then
          h.reason = "cancel"
          child.kill_tree(h)
        else
          if h.stall_limit then
            local st = vim.uv.fs_stat(slot.plan.fragment)
            local size = st and st.size or 0
            if size ~= h.frag_size then
              h.frag_size = size
              h.progress_ms = t
            end
          end
          if h.deadline and t >= h.deadline then
            h.reason = "file"
            child.kill_tree(h)
          elseif
            h.stall_limit
            and h.frag_size > 0 -- before the first record only the file deadline counts (loading the file)
            and t - h.progress_ms > h.stall_limit
          then
            h.reason = "stall"
            child.kill_tree(h)
          end
        end
      end
    end
  end

  ---@param slot Testing.Isolated.Slot
  local function run_inproc(slot)
    local entry = slot.entry
    local lf
    if opts.lf then
      local ids = select_mod.lf_ids(entry.rel, opts.lf)
      lf = ids and { [entry.rel] = ids } or nil
    end
    local guard_ok, report = pcall(inproc.run, {
      root = root,
      files = {
        entry --[[@as Testing.Discover.File]],
      },
      selector = selector,
      lf = lf,
      timeouts = timeouts,
      assertions = o.assertions,
      seed = opts.seed,
      skip_facts = true,
      clock = opts.clock,
    })
    if not guard_ok then
      fail_slot(slot, ("%s: internal error: %s"):format(entry.rel, tostring(report)))
      return
    end
    for _, c in ipairs(report.result.cases) do
      if c.file == "<late>" then
        c.file = entry.rel
        c.id = entry.rel .. "::late assertions"
      end
    end
    slot.cases = report.result.cases
    slot.state = "done"
  end

  local next_commit = 1

  ---@param slot Testing.Isolated.Slot
  local function commit(slot)
    if slot.kind == "unselected" then
      files_unselected = files_unselected + 1
      return
    end
    files_run = files_run + 1
    if slot.output and slot.output ~= "" and opts.on_output then
      pcall(opts.on_output, slot.entry.rel, slot.output)
    end
    for _, c in ipairs(slot.cases or {}) do
      record(c)
      if maxfail and bad_total >= maxfail then
        state.stopped = true
        break
      end
    end
  end

  local function commit_ready()
    while next_commit <= #slots do
      local slot = slots[next_commit]
      if state.stopped then
        files_unrun = files_unrun + 1
      else
        if slot.kind == "inproc" and slot.state ~= "done" then
          run_inproc(slot)
        end
        if slot.state ~= "done" then
          return
        end
        commit(slot)
      end
      next_commit = next_commit + 1
    end
  end

  local function any_alive()
    for _, slot in ipairs(live) do
      if slot.handle and not slot.handle.exited then
        return true
      end
    end
    return false
  end

  local loop_ok, loop_err = pcall(function()
    while next_commit <= #slots do
      if state.fatal then
        error(state.fatal, 0)
      end
      supervise()
      commit_ready()
      if next_commit > #slots then
        break
      end
      vim.wait(poll)
    end
  end)

  -- children that are still alive (a stop, or an error): kill them and wait until they are gone
  if any_alive() then
    state.stopped = true
    local deadline = hrtime() / 1e6 + M.REAP_MS
    while any_alive() and hrtime() / 1e6 < deadline do
      supervise()
      vim.wait(poll)
    end
  end
  for _, slot in ipairs(slots) do
    if slot.plan then
      child.cleanup(slot.plan)
    end
  end
  if not loop_ok then
    error(loop_err, 0)
  end

  local wall_ms = (hrtime() - started) / 1e6
  inproc.attach_findings(res, a, opts.findings or {}, opts.strict, record)
  res.run.duration_ms = math.floor(wall_ms * 1000 + 0.5) / 1000
  result.finalize(res)

  local skipped = res.summary.skip
  return {
    result = res,
    failed = bad_total,
    failed_files = vim.tbl_count(failed_files),
    total = #res.cases,
    files_run = files_run,
    files_unrun = files_unrun,
    files_unselected = files_unselected,
    skipped = skipped,
    stopped = state.stopped,
    wall_ms = wall_ms,
    exit_code = (bad_total > 0 or (opts.strict and skipped > 0)) and 1 or 0,
  }
end

return M
