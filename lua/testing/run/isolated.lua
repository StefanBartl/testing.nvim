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
--- CASE MODE (`isolated = "case"`, busted files). A fresh child per CASE, exact and slow (about 0.3 s of
--- process start per case on Windows, 0.05 s on Linux: a 200-case file costs a minute there). The
--- cases of the file are LISTED first, in this editor (the describe blocks run, no `it` body does, the
--- same as `--list`, under a silent soft-isolation restore); each listed id then gets a child that
--- is told to run only that id (the `lf_ids` of the job: the describe blocks and hooks run again in
--- the child, so every case sees exactly what the file's own top level gives it). The results of the
--- cases of a file are merged in listing order, which is source order, whatever order the children
--- finish in, so the IR is the same for every `jobs`. Honesty rules: an id that was listed but that
--- its child did not report is an `error` case (the describe blocks differ between runs); a child
--- that dies or times out yields its `crash`/`timeout` case under THE CASE'S id; a file whose
--- listing fails is one `error` case; a file that lists no case at all runs as one child per file
--- (the dialect's empty-file policy applies). Every other dialect has ONE case per file: `case`
--- degrades to `file`, with a note on the file's first case.
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
--- WARM POOL (`pool.reuse`, `isolated = "file"`, never for `script` files or CASE mode). Instead of a
--- process per file, `testing.run.pool` lends out embedded editors (`testing.rpc`): the file runs in a
--- member (`testing.child.pool_boot.run`, through the same `testing.child.runner` a child per file uses),
--- then a second request (`finish`) restores what it changed, resets and VERIFIES the member. A member
--- that crashes, times out (the same hard deadlines, supervised the same way) or cannot prove it is clean
--- is DISCARDED and its process tree killed; the next file gets a new one, and a `pool.discarded` finding
--- on the file's last case says why. The merged IR, its order and the exit code are those of a child per
--- file. When no member can be started every file runs in a child of its own, with one note.
---
--- TRACE. A child (or member) that timed out or died leaves `{ kind = "trace" }` on its `timeout` /
--- `crash` case (`opts.options.trace`): `M.write_trace` for a child per file, the RPC driver's own trace
--- for a member.
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
local guards_mod = require("testing.run.guards")

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

---Unique id for a synthetic case in CASE mode: the id of the case the child was started for.
---@param case_id string
---@param existing Testing.Result.Case[]
---@return string
local function free_case_id(case_id, existing)
  local taken = {}
  for _, c in ipairs(existing) do
    taken[c.id] = true
  end
  local id, n = case_id, 1
  while taken[id] do
    n = n + 1
    id = ("%s#dup%d"):format(case_id, n)
  end
  return id
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
---@field guard_cfg? table The guard configuration the child got (for the "not measured" notes of a `script` case).
---@field case_id? string CASE mode: the id the child was started for; a synthetic case (timeout, crash) takes it.

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

---Note on the case of a `script` file that has no guard record: nothing was measured.
local SCRIPT_UNMEASURED_NOTE =
  "guards: no record from this `script` file (guards are off, or the file ended the editor with :cquit / :qa! instead of returning or os.exit); no finding and no effect is measured, an empty list is not a result"

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
  local rec = input.frag.script_guards
  if rec then
    -- one window for the whole file: its findings and effects belong to the file's one case
    guards_mod.attach({ case }, rec.findings, rec.effects)
    for _, n in ipairs(rec.notes or {}) do
      if type(n) == "string" then
        case.notes[#case.notes + 1] = n
      end
    end
    if type(rec.error) == "string" then
      case.notes[#case.notes + 1] = "guards: " .. rec.error
    end
    for _, n in ipairs(guards_mod.unmeasured_notes(input.guard_cfg)) do
      case.notes[#case.notes + 1] = n
    end
  else
    -- no record: an empty list of findings or effects says nothing (a consumer must be able to tell
    -- "clean" from "not measured")
    case.notes[#case.notes + 1] = SCRIPT_UNMEASURED_NOTE
  end
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
    if input.case_id then
      extra.id = free_case_id(input.case_id, cases)
    end
    cases[#cases + 1] = extra
  end
  return cases
end

-- =========================================================
-- Trace artifact of a child that did not finish
-- =========================================================

---Why a warm-pool member was thrown away after a file that ran fine (`finding.id = pool.discarded`).
M.LEAK_REASON = "the reset left state behind"

---Most trace files kept in ONE run's trace directory (the oldest go first).
M.KEEP_TRACES = 40

---Run directories under the trace base are removed once their newest change is older than this
---(seconds). A whole directory goes, never single files of a run that may still be going.
M.KEEP_RUN_SECONDS = 7 * 24 * 3600

---@type string|nil
local run_id
local trace_seq = 0

---The id of this run: `<date>-<time>-<pid>`, fixed for the life of the editor. It names the
---sub-directory the run's traces go to, so two runs (CI jobs, the fleet) never share a folder.
---@return string
function M.run_id()
  if not run_id then
    run_id = ("%s-%d"):format(os.date("!%Y%m%d-%H%M%S"), vim.fn.getpid())
  end
  return run_id
end

---The folder that holds one sub-directory per run: `<state>/testing-traces`.
---@return string
function M.trace_base()
  return vim.fs.normalize(vim.fn.stdpath("state")) .. "/testing-traces"
end

---The directory the trace artifacts of THIS run are written to: `<state>/testing-traces/<run-id>/`
---(it survives the run, unlike the editor's own temp directory, so a CI job can upload it). An
---explicit `dir` is used as it is.
---@param dir? string
---@return string
function M.trace_dir(dir)
  if dir and dir ~= "" then
    return (vim.fs.normalize(dir):gsub("/+$", ""))
  end
  return M.trace_base() .. "/" .. M.run_id()
end

---Remove the oldest files of one trace directory above `M.KEEP_TRACES`.
---@param dir string
local function prune_traces(dir)
  local entries = {}
  for name, typ in vim.fs.dir(dir) do
    if typ == "file" and name:match("%.trace%.json$") then
      local st = vim.uv.fs_stat(dir .. "/" .. name)
      entries[#entries + 1] = { path = dir .. "/" .. name, t = st and st.mtime.sec or 0 }
    end
  end
  if #entries <= M.KEEP_TRACES then
    return
  end
  table.sort(entries, function(a, b)
    return a.t < b.t
  end)
  for i = 1, #entries - M.KEEP_TRACES do
    pcall(os.remove, entries[i].path)
  end
end

---Remove whole run directories of the trace base whose newest change is older than
---`M.KEEP_RUN_SECONDS`. Only directories named like a run id are touched, never this run's own, and
---never anything younger: the artifacts of another run that is still going are safe.
---@param base string
---@param now? integer Seconds since the epoch (a spec passes its own).
local function prune_runs(base, now)
  now = now or os.time()
  local mine = M.run_id()
  for name, typ in vim.fs.dir(base) do
    if
      typ == "directory"
      and name ~= mine
      and name:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%d+$")
    then
      local st = vim.uv.fs_stat(base .. "/" .. name)
      local newest = st and st.mtime.sec or 0
      for fname in vim.fs.dir(base .. "/" .. name) do
        local fst = vim.uv.fs_stat(base .. "/" .. name .. "/" .. fname)
        if fst and fst.mtime.sec > newest then
          newest = fst.mtime.sec
        end
      end
      if now - newest > M.KEEP_RUN_SECONDS then
        pcall(vim.fn.delete, base .. "/" .. name, "rf")
      end
    end
  end
end
M._prune_runs = prune_runs

---@class Testing.Isolated.TraceInput
---@field dir? string Trace directory (default `M.trace_dir()`: this run's folder below `M.trace_base()`).
---@field base? string Folder with one sub-directory per run (default `M.trace_base()`; a spec's seam).
---@field root string Project root.
---@field rel string The spec file the child ran.
---@field reason string `timeout` | `crash`
---@field h Testing.Child.Handle
---@field frag Testing.Child.Fragment
---@field describe string How the process ended.
---@field err string Its stderr.

---Write what is known about a per-file child that timed out or died: the cases it finished, how it
---ended and the end of its stderr, as one small redacted JSON file (`testing.rpc.trace`, the format of
---the RPC driver's trace, without calls: a per-file child has no RPC).
---@param input Testing.Isolated.TraceInput
---@return { kind: string, path: string }|nil artifact
function M.write_trace(input)
  local trace_mod = require("testing.rpc.trace")
  local tr = trace_mod.new()
  local records = #input.frag.cases > 0 and input.frag.cases or input.frag.progress
  for _, c in ipairs(records or {}) do
    tr:event("case", ("%s: %s"):format(tostring(c.id), tostring(c.status)))
  end
  tr:event("end", input.describe)
  local dir = M.trace_dir(input.dir)
  if input.base and (not input.dir or input.dir == "") then
    dir = input.base .. "/" .. M.run_id()
  end
  local stem = input.rel:gsub("[^%w_%-]", "_")
  local h = input.h
  local snap = tr:snapshot({
    reason = input.reason,
    child = {
      pid = h.pid,
      file = input.rel,
      exit = h.exit,
      exit_text = input.describe,
      kill_reason = h.reason,
      abandoned = h.abandoned,
      argv = h.plan and h.plan.argv or nil,
    },
    stderr = input.err,
  })
  trace_seq = trace_seq + 1
  local path = ("%s/%s-%d-%d.trace.json"):format(dir, stem, h.pid or 0, trace_seq)
  local artifact, err = trace_mod.write(snap, { path = path, root = input.root })
  if not artifact then
    error(err, 0)
  end
  pcall(prune_traces, dir)
  if not input.dir or input.dir == "" then
    pcall(prune_runs, input.base or M.trace_base())
  end
  return artifact
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
---@field soft? Testing.Isolation.Session Soft isolation of the files that run in this editor (`isolated = "soft"`).
---@field guard_cfg? Testing.Run.GuardConfig Guard configuration: given to the in-process files and, with `in_child`, to every child (job key `guard`).
---@field lib_async? table `lib.nvim.async` (seam for specs: the lib.nvim version check).
---@field rpc? table `testing.rpc` for the warm pool (seam for specs).
---@field trace_dir? string Where the trace artifact of a child that timed out or died is written (default: `<state>/testing-traces`).
---@field list_cases? fun(entry: table, accept: fun(id: string): boolean): string[]|nil, string|nil Lists the case ids of a busted file for `isolated = "case"` (seam for specs; default: `inproc.list` under a silent restore).

---@class Testing.Isolated.Slot
---@field index integer
---@field entry Testing.Inproc.Entry
---@field kind "synthetic"|"unselected"|"child"|"inproc"
---@field state "waiting"|"running"|"done"
---@field cases? Testing.Result.Case[]
---@field output? string
---@field lf_ids? string[]
---@field case_id? string CASE mode: the case this child runs.
---@field note? string Note for the first case of the file (isolation degraded).
---@field not_first? boolean A further case child of a file already counted.
---@field label? string Header of its output.
---@field handle? Testing.Child.Handle
---@field plan? Testing.Child.Plan
---@field fragment? string Where the running child writes its records (its own plan, or the pool member's file).

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

---What the isolated driver needs from lib.nvim, or why this checkout of it is too old (a stale
---`.deps/lib.nvim` is found before the sibling checkout and used to end in "attempt to call method
---'with' (a nil value)" with no report).
---@param lib? table Replaces `require("lib.nvim.async")` (specs).
---@return string|nil problem
function M.lib_problem(lib)
  lib = lib or async
  local sem = type(lib) == "table" and lib.Semaphore or nil
  if type(sem) == "table" and type(sem.new) == "function" and type(sem.with) == "function" then
    return nil
  end
  local found = vim.api.nvim_get_runtime_file("lua/lib/nvim/async/init.lua", false)[1]
  return ("lib.nvim is too old for the isolated driver (`lib.nvim.async.Semaphore:with` is missing%s). Update it (git pull), or remove the stale copy that comes first in the search order: $LIB_NVIM_DIR, .deps/lib.nvim, ../lib.nvim, stdpath('data')/lazy/lib.nvim."):format(
    found and (" in " .. vim.fs.normalize(found)) or ""
  )
end

---Run the planned files; same report as `inproc.run`.
---@param opts Testing.Isolated.Opts
---@return Testing.Inproc.Report
function M.run(opts)
  local problem = M.lib_problem(opts.lib_async)
  if problem then
    error(problem, 0)
  end
  local root = opts.root:gsub("\\", "/"):gsub("/+$", "")
  local o = opts.options or options_mod.of({})
  -- a hand-built options table (a spec) may lack the keys of the warm pool and of the guards
  local pool_opts = o.pool or { size = 0, reuse = false }
  local state_mode = (o.guards or {}).state
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

  -- without a guard layer nothing measures effects, and the cases say so
  local effects_measured = opts.guard_cfg ~= nil and guards_mod.available()
  local notes, unattached = {}, {}

  ---@param case Testing.Result.Case
  local function record(case)
    local has_note = false
    for _, n in ipairs(case.notes) do
      if n == EFFECTS_NOTE then
        has_note = true
      end
    end
    if not has_note and not effects_measured then
      case.notes[#case.notes + 1] = EFFECTS_NOTE
    elseif effects_measured then
      for _, note in ipairs(guards_mod.unmeasured_notes(opts.guard_cfg)) do
        if not vim.tbl_contains(case.notes, note) then
          case.notes[#case.notes + 1] = note
        end
      end
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
    local mode, mode_note = "none", nil
    if not entry.missing and entry.dialect ~= "unknown" then
      mode, mode_note = options_mod.isolation_of(o, entry)
    end
    slot.note = mode_note
    local case_ids, list_err
    if mode == "case" then
      -- a child per case: the cases are listed here first (see the module header)
      case_ids, list_err = M.list_case_ids(opts, o, root, entry, accept, selector, timeouts, lf_ids)
    end
    if list_err then
      slot.kind, slot.state = "synthetic", "done"
      slot.cases = {
        synthetic(
          rel,
          vim.fs.basename(rel),
          "error",
          ("%s: cannot list the cases for isolated=case: %s"):format(rel, tostring(list_err))
        ),
      }
    elseif entry.missing then
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
    elseif mode == "case" and case_ids and #case_ids > 0 then
      -- one slot per listed case, in listing (= source) order: the merge order of the file
      for k, id in ipairs(case_ids) do
        slots[#slots + 1] = {
          index = i,
          entry = entry,
          state = "waiting",
          kind = "child",
          case_id = id,
          lf_ids = { id },
          label = ("%s [%s]"):format(rel, id:sub(#rel + 3)),
          not_first = k > 1,
          note = k == 1 and mode_note or nil,
        } --[[@as Testing.Isolated.Slot]]
      end
      slot = nil
    elseif mode ~= "none" then
      -- a child per file (also: `case` for a file that lists no case, so the dialect's empty-file
      -- policy decides what that is)
      slot.kind = "child"
      if lf_ids then
        local list = vim.tbl_keys(lf_ids)
        table.sort(list)
        slot.lf_ids = list
      end
    else
      slot.kind = "inproc"
    end
    if slot then
      slots[#slots + 1] = slot
    end
  end

  local hrtime = vim.uv.hrtime
  local started = hrtime()
  local sem = async.Semaphore.new(o.jobs)
  ---@type Testing.Isolated.Slot[]
  local live = {}

  ---@param slot Testing.Isolated.Slot
  ---@param message string
  local function fail_slot(slot, message)
    local case = synthetic(slot.entry.rel, vim.fs.basename(slot.entry.rel), "error", message)
    if slot.case_id then
      case.id = slot.case_id
    end
    slot.cases = { case }
    slot.state = "done"
  end

  ---The guard configuration a child gets in its job (nil: no guard layer wanted).
  ---@param throwaway? boolean The child runs ONE case (a file of a one-case dialect, or `isolated = "case"`) and ends with it: nothing it leaves behind can reach another case.
  ---@return table|nil
  local function guard_for_child(throwaway)
    return opts.guard_cfg
        and options_mod.guard_config(
          o,
          { root = root, seed = opts.seed, in_child = true, throwaway = throwaway }
        )
      or nil
  end

  ---Everything the parent needs to turn a finished (or dead) child into the cases of its file.
  ---@class Testing.Isolated.Ended
  ---@field h Testing.Child.Handle
  ---@field exit { code?: integer, signal?: integer }
  ---@field fragment string
  ---@field out string
  ---@field stdout string
  ---@field err string
  ---@field describe string
  ---@field trace? fun(reason: string): { kind: string, path: string }|nil Writes the trace of the process (pool member: its RPC calls too).

  ---Classify what a child left behind, add the trace artifact of a dead one and store the cases.
  ---@param slot Testing.Isolated.Slot
  ---@param kind "cases"|"script"
  ---@param ended Testing.Isolated.Ended
  local function conclude(slot, kind, ended)
    local rel = slot.entry.rel
    local h = ended.h
    local frag = fragment_mod.read(ended.fragment)
    slot.output = ended.out
    ---@type Testing.Result.Case[]
    local cases = M.classify({
      rel = rel,
      kind = kind,
      frag = frag,
      code = ended.exit.code,
      signal = ended.exit.signal,
      reason = h.reason,
      out = ended.out,
      stdout = ended.stdout,
      err = ended.err,
      assertions = o.assertions,
      wall_ms = (vim.uv.hrtime() / 1e6) - h.started_ms,
      file_ms = timeouts.file_ms,
      case_ms = timeouts.case_ms,
      grace_ms = grace,
      describe_exit = ended.describe,
      abandoned = h.abandoned,
      case_id = slot.case_id,
      guard_cfg = guard_for_child(true),
    })
    if slot.case_id then
      -- CASE mode: the child must have reported the case it was started for
      local found = false
      for _, c in ipairs(cases) do
        found = found or c.id == slot.case_id
      end
      if not found then
        local missing = synthetic(
          rel,
          vim.fs.basename(rel),
          "error",
          ("%s: the case was listed but its child did not report it (the describe blocks of the file differ between runs?): %s"):format(
            rel,
            slot.case_id:sub(#rel + 3)
          )
        )
        missing.id = slot.case_id
        cases[#cases + 1] = missing
      end
    end
    -- the child's output explains a red file: one note on its first red case
    if ended.out ~= "" then
      for _, c in ipairs(cases) do
        if inproc.BAD[c.status] then
          c.notes[#c.notes + 1] = "output of the child (tail): " .. tail(ended.out, M.TAIL_CHARS)
          break
        end
      end
    end
    -- what the guard layer of the child said that no case carries (`done` record of the fragment)
    local done = frag.done
    if type(done) == "table" then
      for _, n in ipairs(type(done.notes) == "table" and done.notes or {}) do
        if type(n) == "string" and not vim.tbl_contains(notes, n) then
          notes[#notes + 1] = n
        end
      end
      for _, f in ipairs(type(done.unattached) == "table" and done.unattached or {}) do
        if type(f) == "table" then
          unattached[#unattached + 1] = f
        end
      end
    end
    -- a child that timed out or died leaves a trace of what it did
    if o.trace then
      local why
      for _, c in ipairs(cases) do
        if c.status == "timeout" or c.status == "crash" then
          why = c
        end
      end
      if why then
        local artifact
        local aok, aerr = pcall(function()
          if ended.trace then
            artifact = ended.trace(why.status)
          else
            artifact = M.write_trace({
              dir = opts.trace_dir,
              root = root,
              rel = rel,
              reason = why.status,
              h = h,
              frag = frag,
              describe = ended.describe,
              err = ended.err,
            })
          end
        end)
        if artifact then
          why.artifacts[#why.artifacts + 1] = artifact
        elseif not aok then
          why.notes[#why.notes + 1] = "trace: " .. tostring(aerr)
        end
      end
    end
    slot.cases = cases
    slot.state = "done"
  end

  ---@param slot Testing.Isolated.Slot
  local function unlive(slot)
    for i, s in ipairs(live) do
      if s == slot then
        table.remove(live, i)
        break
      end
    end
    slot.handle = nil
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
      disable_first_run = o.disable_first_run,
      selector = opts.selector_spec,
      lf_ids = slot.lf_ids,
      timeouts = timeouts,
      seed = opts.seed,
      env_allow = o.env_allow,
      extra_env = opts.child_env,
      nvim = opts.nvim,
      base = opts.sandbox_base,
      -- what the child boot reads from the job (`testing.child.runner`): the guard layer's configuration
      -- (`options.guard_config`), fixed LANG/TZ, the trace artifact. A one-case child is thrown away
      -- with its case: the state guard would only name what dies with the process.
      guard = guard_for_child(entry.dialect ~= "busted" or o.isolated == "case"),
      deterministic = o.determinism,
      trace = o.trace,
    })
    slot.plan = plan
    slot.fragment = plan.fragment
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
    conclude(slot, kind, {
      h = h,
      exit = h.exit or {},
      fragment = plan.fragment,
      out = child.text(h.out),
      stdout = child.text(h.stdout),
      err = child.text(h.err),
      describe = child.describe_exit(h.exit or {}),
    })
    child.cleanup(plan)
  end

  -- ---- the warm pool (`isolated=file` + `pool.reuse`) -------------------------------------
  ---@type Testing.Pool|nil
  local pool
  local pool_fallback_note
  -- Where the members write their records. NOT the member's sandbox: that is removed the moment its
  -- process ends (a crash, a kill), and the cases a file finished before it died are in this fragment.
  ---@type string|nil
  local frag_dir

  ---@return Testing.Pool
  local function get_pool()
    if pool then
      return pool
    end
    local size = pool_opts.size > 0 and pool_opts.size or math.min(o.jobs, 4)
    size = math.max(1, math.min(size, o.jobs))
    local mode = state_mode
    pool = require("testing.run.pool").new({
      size = size,
      rpc = opts.rpc,
      spawn_opts = {
        root = root,
        minit = opts.minit,
        rtp_prepend = opts.rtp_prepend,
        rtp = opts.rtp,
        env_allow = o.env_allow,
        extra_env = opts.child_env,
        nvim = opts.nvim,
        base = opts.sandbox_base,
        deterministic = o.determinism,
        disable_first_run = o.disable_first_run,
        -- the guard layer is installed per file by `testing.child.runner`, not once by the member boot
        guard = false,
        track_schedule = false,
        defer_plugins = true,
        trace_dir = M.trace_dir(opts.trace_dir),
        trace_name = "pool",
      },
      init_opts = {
        filetype = o.filetype,
        keep = o.soft_keep or {},
        severity = (mode == "warn" or mode == "error") and mode or nil,
      },
    })
    return pool
  end

  ---Does this slot run in a pool member? `script` files (self-running, they end the process) and
  ---`isolated=case` (a fresh child per case is the point) never do.
  ---@param slot Testing.Isolated.Slot
  ---@return boolean
  local function pooled(slot)
    return pool_opts.reuse
      and not slot.case_id
      and slot.entry.dialect ~= "script"
      and pool_fallback_note == nil
  end

  ---Run the file of `slot` in a pool member. Returns false when no member could be started (the
  ---caller then runs a child of its own, and says so once).
  ---@param slot Testing.Isolated.Slot
  ---@return boolean handled
  local function run_pooled(slot)
    local entry = slot.entry
    local rel = entry.rel
    local pl = get_pool()
    local acquired = async.await(function(resume)
      pl:acquire(function(m, e)
        resume({ member = m, err = e })
      end)
    end)
    local member = acquired.member
    if not member then
      pool_fallback_note = ("the warm pool could not start a member (%s): every file runs in a child of its own"):format(
        tostring(acquired.err)
      )
      return false
    end
    if state.stopped then
      pl:release(member)
      slot.state = "done"
      return true
    end
    local mchild = member.child
    local h = mchild.proc()
    if not frag_dir then
      frag_dir = vim.fs.normalize(vim.fn.tempname()) .. "-testing-pool"
      vim.fn.mkdir(frag_dir, "p")
    end
    local frag_path = ("%s/m%d-%d.ndjson"):format(frag_dir, member.id, member.files + 1)
    local job = (child.job or require("testing.child").job)({
      entry = serializable(entry),
      root = root,
      kind = "cases",
      assertions = o.assertions,
      selector = opts.selector_spec,
      lf_ids = slot.lf_ids,
      timeouts = timeouts,
      seed = opts.seed,
      guard = guard_for_child(),
      trace = o.trace,
    }, frag_path, nil)

    -- the supervisor watches this member like any child
    local is_busted = entry.dialect == "busted"
    h.reason, h.kill_requested_ms, h.first_kill_ms = nil, nil, nil
    h.started_ms = hrtime() / 1e6
    h.deadline = timeouts.file_ms and (h.started_ms + timeouts.file_ms + grace) or nil
    h.stall_limit = (is_busted and timeouts.case_ms) and (timeouts.case_ms + grace) or nil
    h.progress_ms = h.started_ms
    h.frag_size = 0
    slot.handle, slot.fragment, slot.state = h, frag_path, "running"
    live[#live + 1] = slot

    local got = async.await(function(resume)
      mchild.exec_async(
        "return require('testing.child.pool_boot').run(...)",
        { job },
        function(ok, ret)
          resume({ ok = ok, ret = ret })
        end
      )
    end)
    local answer = got.ok and type(got.ret) == "table" and got.ret or nil
    -- phase 2, a request of its own (the editor went back to its main loop in between): restore,
    -- reset and prove the member clean; still supervised like the file itself
    local fin
    if answer and answer.ok and not (h.ended or h.exited) then
      local got2 = async.await(function(resume)
        mchild.exec_async(
          "return require('testing.child.pool_boot').finish()",
          {},
          function(ok, ret)
            resume({ ok = ok, ret = ret })
          end
        )
      end)
      fin = got2.ok and type(got2.ret) == "table" and got2.ret or nil
      if fin then
        pl:account(fin.ms)
      end
      if not fin and not got2.ok then
        got = got2
      end
    end
    unlive(slot)

    local dead = h.ended or h.exited
    local exit, out, err = { code = 0 }, "", ""
    local reuse_blocker
    if dead then
      exit = h.exit or {}
      err = child.text(h.err)
      local why = mchild.death_text()
      if why ~= "" then
        err = err ~= "" and (err .. "\n" .. why) or why
      end
      reuse_blocker = "the member " .. (h.reason and "was killed" or "died")
    elseif answer and answer.ok and fin then
      out = tostring(answer.output or "")
    else
      -- the member is alive but the driver failed (or the answer is garbage): unknown state, drop it
      exit = { code = 3 }
      err = tostring(
        (answer and answer.err)
          or (answer and answer.ok and "the member did not answer its verification (finish)")
          or got.ret
      )
      reuse_blocker = "the driver failed in the member"
    end
    local leak_lines = {}
    if fin and not dead then
      for _, l in ipairs(type(fin.unrestored) == "table" and fin.unrestored or {}) do
        leak_lines[#leak_lines + 1] = "not restored: " .. tostring(l)
      end
      for _, l in ipairs(type(fin.leaks) == "table" and fin.leaks or {}) do
        leak_lines[#leak_lines + 1] = tostring(l)
      end
      for _, l in ipairs(type(fin.sandbox) == "table" and fin.sandbox or {}) do
        leak_lines[#leak_lines + 1] = "sandbox: " .. tostring(l)
      end
      if #leak_lines > 0 then
        reuse_blocker = M.LEAK_REASON
      end
    end

    conclude(slot, "cases", {
      h = h,
      exit = exit,
      fragment = frag_path,
      out = out,
      stdout = out,
      err = err,
      describe = child.describe_exit(exit),
      trace = function(reason)
        return mchild.write_trace(reason)
      end,
    })
    os.remove(frag_path)

    -- a red case in a member that ran files before: the pool cannot see every kind of leftover, so the
    -- case says where it ran and how to tell a leak of an earlier file from a bug of its own
    member.history = member.history or {}
    if #member.history > 0 then
      local from = math.max(1, #member.history - 2)
      local previous = table.concat(vim.list_slice(member.history, from, #member.history), ", ")
      for _, c in ipairs(slot.cases or {}) do
        if inproc.BAD[c.status] then
          c.notes[#c.notes + 1] = ("ran in a reused warm-pool member after %s; if it passes with --no-pool-reuse, an earlier file left state behind that the pool could not see"):format(
            previous
          )
        end
      end
    end
    member.history[#member.history + 1] = rel

    -- a member that cannot prove it is clean is thrown away, and a finding says why
    if reuse_blocker == M.LEAK_REASON and slot.cases and #slot.cases > 0 then
      local mode = state_mode
      result.add_guard_finding(slot.cases[#slot.cases], {
        guard = "pool",
        id = "pool.discarded",
        severity = mode == "error" and "error" or (mode == "warn" and "warn" or "info"),
        message = ("%s leaves state the warm pool could not reset (the member was discarded, the next file gets a fresh one): %s"):format(
          rel,
          table.concat(vim.list_slice(leak_lines, 1, 8), "; ")
            .. (#leak_lines > 8 and ("; ... and %d more"):format(#leak_lines - 8) or "")
        ),
      })
    end
    pl:release(member, reuse_blocker)
    return true
  end

  ---@param slot Testing.Isolated.Slot
  local function run_slot(slot)
    if pooled(slot) and run_pooled(slot) then
      return
    end
    if slot.state == "done" then
      return
    end
    run_child(slot)
  end

  -- one coroutine per child file; the semaphore decides how many run at once, FIFO
  for _, slot in ipairs(slots) do
    if slot.kind == "child" then
      async.run(
        function()
          local ok, err = sem:with(run_slot, slot)
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
            local st = vim.uv.fs_stat(slot.fragment or slot.plan.fragment)
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
      soft = opts.soft,
      guard_cfg = opts.guard_cfg
        and options_mod.guard_config(o, { root = root, seed = opts.seed, in_child = false }),
    })
    if not guard_ok then
      fail_slot(slot, ("%s: internal error: %s"):format(entry.rel, tostring(report)))
      return
    end
    for _, n in ipairs(report.notes or {}) do
      -- the same diagnostic of every in-process file is one line
      if not vim.tbl_contains(notes, n) then
        notes[#notes + 1] = n
      end
    end
    vim.list_extend(unattached, report.unattached or {})
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
    if not slot.not_first then
      files_run = files_run + 1
    end
    if slot.output and slot.output ~= "" and opts.on_output then
      pcall(opts.on_output, slot.label or slot.entry.rel, slot.output)
    end
    if slot.note and slot.cases and slot.cases[1] then
      slot.cases[1].notes[#slot.cases[1].notes + 1] = slot.note
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
        -- a file with several case slots is one file, and a file that already ran is not "unrun"
        if not slot.not_first then
          files_unrun = files_unrun + 1
        end
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
  if pool then
    pool:shutdown()
  end
  if frag_dir then
    pcall(vim.fn.delete, frag_dir, "rf")
  end
  for _, slot in ipairs(slots) do
    if slot.plan then
      child.cleanup(slot.plan)
    end
  end
  if not loop_ok then
    error(loop_err, 0)
  end

  if pool_fallback_note then
    notes[#notes + 1] = pool_fallback_note
  end
  local pool_stats
  if pool then
    pool_stats = vim.deepcopy(pool.stats)
    if pool_stats.files > 0 then
      local fin = 0
      for _, v in pairs(pool_stats.finish_ms) do
        fin = fin + v
      end
      notes[#notes + 1] = ("warm pool: %d file(s) in %d member(s) (%d reused a member, %d member(s) discarded; starting members %.1f s, verifying files %.1f s)"):format(
        pool_stats.files,
        pool_stats.spawned,
        pool_stats.reused,
        pool_stats.discarded,
        pool_stats.boot_ms / 1000,
        fin / 1000
      )
    end
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
    notes = notes,
    unattached = unattached,
    pool = pool_stats,
  }
end

---The case ids of a busted file, for `isolated = "case"`: the describe blocks run in a THROWAWAY
---child (`kind = "list"`: no `it` body runs, the same walk as `--list`), with the sanitized
---environment, the sandbox and the file timeout of every other child, so what a spec does at load
---time (reads a secret from the environment, writes outside the sandbox, loops) neither sees the
---runner's environment nor stays behind in the runner. Selection (`--filter`, `--tags`, `--lf`) is
---applied in that child: only accepted ids get a case child. The guard layer is NOT installed for
---the listing (no case window exists); the process boundary is the protection.
---@param opts Testing.Isolated.Opts
---@param o Testing.Run.Options
---@param root string
---@param entry Testing.Inproc.Entry
---@param accept fun(id: string): boolean
---@param _selector Testing.Select.Selector (unused: the child builds its own from `opts.selector_spec`)
---@param timeouts Testing.Child.Timeouts
---@param lf_ids table<string, true>|nil
---@return string[]|nil ids Nil with an `err` when the file cannot be listed.
---@return string|nil err
function M.list_case_ids(opts, o, root, entry, accept, _selector, timeouts, lf_ids)
  if opts.list_cases then
    return opts.list_cases(entry, accept)
  end
  local child = opts.child or require("testing.child")
  local lf_list
  if lf_ids then
    lf_list = vim.tbl_keys(lf_ids)
    table.sort(lf_list)
  end
  local plan = child.build({
    entry = serializable(entry),
    root = root,
    kind = "list",
    minit = opts.minit,
    host = options_mod.host_of(o, entry),
    rtp_prepend = opts.rtp_prepend,
    rtp = opts.rtp,
    filetype = o.filetype,
    disable_first_run = o.disable_first_run,
    selector = opts.selector_spec,
    lf_ids = lf_list,
    timeouts = timeouts,
    seed = opts.seed,
    env_allow = o.env_allow,
    extra_env = opts.child_env,
    nvim = opts.nvim,
    base = opts.sandbox_base,
    deterministic = o.determinism,
    trace = false,
  })
  local pok, perr = child.prepare(plan)
  if not pok then
    child.cleanup(plan)
    return nil, tostring(perr)
  end
  local done = false
  local handle, serr = child.spawn(plan, function()
    done = true
  end)
  if not handle then
    child.cleanup(plan)
    return nil, tostring(serr)
  end
  local limit = (timeouts.file_ms or 60000) + (opts.grace_ms or M.GRACE_MS)
  if not vim.wait(limit, function()
    return done
  end, 10) then
    child.kill_tree(handle)
    -- the process tree is going down; a stubborn process must not keep the run waiting
    if not vim.wait(M.GRACE_MS, function()
      return done
    end, 10) then
      child.abandon(handle)
    end
    child.cleanup(plan)
    return nil, ("listing the cases timed out after %d ms"):format(limit)
  end
  local frag = require("testing.child.fragment").read(plan.fragment)
  local exit = handle.exit or {}
  local text = child.text(handle.out)
  child.cleanup(plan)
  if not frag.list then
    return nil,
      ("the listing child produced no list (%s)%s"):format(
        child.describe_exit(exit),
        text ~= "" and (": " .. tail(text, 400)) or ""
      )
  end
  local ids = {}
  for _, item in ipairs(frag.list) do
    if type(item) == "table" then
      if item.note then
        return nil, tostring(item.note)
      end
      ids[#ids + 1] = item.id
    end
  end
  return ids, nil
end

return M
