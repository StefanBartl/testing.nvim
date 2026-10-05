---@module 'testing.run.inproc'
---@brief In-process driver: runs the discovered spec files in the current Neovim and builds the Result-IR.
---@description
--- Walks the planned files in order. Every file runs in the dialect discovery found for it
--- (`testing.dialect.run_file`: a, b, c, d, h = one case per file; busted = one case per `it`), under
--- a timeout guard (`testing.run.timeout`), and every case lands in the IR with its status, duration,
--- tags and the assertions it collected. Output is NOT printed here: reporters render the IR
--- (`testing.report`), the caller prints.
---
--- Honesty rules the driver enforces (guard rail L2):
---   * a file that raises, does not load or does not return `function(H)` is an `error` case with the
---     spec path in the message, never a skipped file;
---   * a file the project's runner lists but that is missing on disk is an `error` case;
---   * a file whose dialect is unknown is a `skip` case with the reason (never green; `strict` makes
---     the run red);
---   * a timeout (file or case) is the status `timeout`;
---   * assertions that arrive after their case ended make the run red (synthetic case);
---   * the run never decides "green" from a dropped case: cases that a selection or `--maxfail` kept
---     from running are not in the IR, and the report says how many files were not run.
---
--- Mapping: dialect a-d/h: ONE CASE = ONE SPEC FILE, id `<rel>::<file name>`. Busted: ONE CASE = ONE
--- `it`, id `<rel>::<describe>::...::<it>`. Effects (spawned processes, network, writes) are NOT
--- measured in M1: every case says so in its notes, and the empty `effects` lists are not a
--- measurement.
---
--- Pure orchestration: the clock is injectable; the editor APIs used are `vim.uv`, `vim.fs`,
--- `vim.fn.tempname`/`stdpath`, `vim.env` and `vim.deepcopy`.

local result = require("testing.core.result")
local assert_mod = require("testing.core.assert")
local select_mod = require("testing.run.select")
local timeout = require("testing.run.timeout")

local M = {}

---Every case carries this note: the IR's `effects` lists are empty because nothing measures them
---in M1, not because nothing happened (a consumer must not read "not collected" as "none").
local EFFECTS_NOTE = "effects: not collected (M1); the empty effects lists are not a measurement"

---Statuses that make a run red. `skip` is not among them: it is reported, never green, and red
---only under `strict`.
---@type table<string, true>
M.BAD = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

-- =========================================================
-- Plan entries
-- =========================================================

---@class Testing.Inproc.Entry
---@field path string Absolute path.
---@field rel string Path relative to the root.
---@field dialect string
---@field harness? string
---@field missing? boolean
---@field reason? string

---Accept discovered files and, for convenience, plain absolute paths (dialect `default_dialect`).
---@param root string
---@param files (Testing.Discover.File|string)[]
---@param default_dialect string
---@return Testing.Inproc.Entry[]
local function entries_of(root, files, default_dialect)
  local relpath = require("lib.nvim.fs.relpath")
  local out = {}
  for _, f in ipairs(files) do
    if type(f) == "string" then
      local path = slashes(f)
      out[#out + 1] = { path = path, rel = slashes(relpath(path, root)), dialect = default_dialect }
    else
      out[#out + 1] = f
    end
  end
  return out
end

-- =========================================================
-- Facts
-- =========================================================

---Facts for the IR header.
---@param root string
---@return table
local function run_facts(root)
  local uname = vim.uv.os_uname() or { sysname = "unknown", machine = "unknown" }
  local v = vim.version()
  local sys = uname.sysname:lower()
  local os_name = sys:match("^windows") and "windows" or (sys == "darwin" and "macos" or sys)
  return {
    nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    os = os_name,
    arch = uname.machine,
    project_key = require("lib.nvim.fs.project_key")(root),
  }
end

---Abbreviated HEAD and dirty flag of `root`, nil when it is not a git checkout (or git is missing).
---@param root string
---@return Testing.Result.Git|nil
local function git_facts(root)
  local job = require("lib.nvim.system.job")
  local function git(args)
    local argv = { "-C", root }
    vim.list_extend(argv, args)
    local ok, res = pcall(job.start_blocking, { command = "git", args = argv, timeout_ms = 10000 })
    if ok and res and res.code == 0 then
      return res.stdout or ""
    end
    return nil
  end
  local sha = git({ "rev-parse", "--short", "HEAD" })
  if not sha then
    return nil
  end
  local status = git({ "status", "--porcelain" })
  return { sha = vim.trim(sha), dirty = status ~= nil and vim.trim(status) ~= "" }
end

-- =========================================================
-- Run
-- =========================================================

---@class Testing.Inproc.Opts
---@field root string Project root (absolute); case files are relative to it.
---@field files (Testing.Discover.File|string)[] Planned files in run order (a plain string is an absolute path run in `dialect`).
---@field dialect? string Dialect of plain-string entries (default `a`).
---@field argv? string[] Effective arguments, stored in the IR header.
---@field selector? Testing.Select.Selector Case selection (`--filter`, `--tags`, ...); default: everything.
---@field lf? table<string, table<string, true>> `--lf`: remembered failed ids by file (`select.group_failed`); a file listed here runs only those cases (or all, see `select.lf_ids`).
---@field maxfail? integer Stop after this many bad cases (`-x` = 1).
---@field seed? integer Seed of a shuffled run, stored in the IR header.
---@field timeouts? { case_ms?: integer, file_ms?: integer } Milliseconds; nil = no limit.
---@field findings? Testing.Discover.Finding[] Discovery findings: attached to the case of their file; under `strict` a synthetic failing case.
---@field strict? boolean Warn/error findings and skipped cases make the run red.
---@field on_case? fun(case: Testing.Result.Case) Progress hook, called for every recorded case.
---@field clock? Testing.Assert.Clock Case clock in ms (default `vim.uv.hrtime`).

---@class Testing.Inproc.Report
---@field result Testing.Result The finalized IR.
---@field failed integer Cases that are red (`M.BAD`).
---@field failed_files integer Files with at least one red case.
---@field total integer Cases in the IR.
---@field files_run integer Files that were run.
---@field files_unrun integer Files not reached because `--maxfail` stopped the run.
---@field files_unselected integer Files whose cases the selection removed entirely.
---@field skipped integer Cases with status `skip`.
---@field stopped boolean `--maxfail` stopped the run.
---@field wall_ms number Wall time of the file loop.
---@field exit_code integer 0 green, 1 at least one red case (or, under `strict`, a skip / a finding).

---Make a case of `rel` for a failure of the driver itself.
---@param a Testing.Assert.Context
---@param rel string
---@param status Testing.Status
---@param message string
---@return Testing.Result.Case
local function synthetic_case(a, rel, status, message)
  a.begin_case({ file = rel, name = vim.fs.basename(rel) })
  local case = a.current() --[[@as Testing.Result.Case]]
  case.status = status
  case.error = { message = message, traceback = message }
  return a.end_case()
end

---Details of a non-passing case for messages of the driver itself.
---@param case Testing.Result.Case
---@return string
local function first_error(case)
  return case.error and case.error.message or case.status
end

---Run the planned files and build the IR.
---@param opts Testing.Inproc.Opts
---@return Testing.Inproc.Report
function M.run(opts)
  local root = slashes(opts.root):gsub("/+$", "")
  local a = assert_mod.new({ clock = opts.clock })
  local dialect = require("testing.dialect")
  local entries = entries_of(root, opts.files, opts.dialect or "a")
  local selector = opts.selector or select_mod.new({})
  local timeouts = opts.timeouts or {}
  local maxfail = opts.maxfail

  local facts = run_facts(root)
  local res = result.new({
    root = root,
    project_key = facts.project_key,
    nvim = facts.nvim,
    os = facts.os,
    arch = facts.arch,
    git = git_facts(root),
    seed = opts.seed,
    jobs = 1,
    argv = opts.argv or {},
  })

  local header_cache = {}
  ---@param rel string
  ---@return string[]
  local function header_tags(rel)
    if header_cache[rel] == nil then
      header_cache[rel] = select_mod.file_header_tags(root .. "/" .. rel)
    end
    return header_cache[rel]
  end
  if opts.selector == nil then
    selector = select_mod.new({ header_tags = header_tags })
  end

  local bad_total = 0
  local stopped = false
  local files_run, files_unrun, files_unselected = 0, 0, 0
  local failed_files = {}

  local hrtime = vim.uv.hrtime
  local started = hrtime()

  ---@param case Testing.Result.Case
  local function record(case)
    case.notes[#case.notes + 1] = EFFECTS_NOTE
    case.tags = select_mod.union(select_mod.tags_of_id(case.id), header_tags(case.file))
    result.add_case(res, case)
    if M.BAD[case.status] then
      bad_total = bad_total + 1
      failed_files[case.file] = true
    end
    if opts.on_case then
      pcall(opts.on_case, case)
    end
  end

  for _, entry in ipairs(entries) do
    local rel = entry.rel
    if stopped then
      files_unrun = files_unrun + 1
    else
      local file_id = select_mod.file_case_id(rel)
      local is_busted = entry.dialect == "busted" and not entry.missing
      local lf_ids = nil
      if opts.lf then
        lf_ids = select_mod.lf_ids(rel, opts.lf)
      end

      ---@param id string
      ---@return boolean
      local function accept(id)
        if stopped then
          return false
        end
        if lf_ids ~= nil and not lf_ids[id] then
          return false
        end
        return selector.case_ok(id, rel)
      end

      if not is_busted and not accept(file_id) then
        files_unselected = files_unselected + 1
      else
        files_run = files_run + 1
        local bad_before = bad_total
        local guard = timeout.start({
          label = rel,
          file_ms = timeouts.file_ms,
          case_ms = is_busted and timeouts.case_ms or nil,
        })
        local seen_in_file = 0
        ---@type Testing.Result.Case[]|nil
        local cases
        local ok, err = pcall(function()
          if entry.missing then
            cases = {
              synthetic_case(
                a,
                rel,
                "error",
                entry.reason or "listed in the project's runner but not on disk"
              ),
            }
          elseif entry.dialect == "unknown" then
            -- never a skip: a file that was not classified did not run, and CI reads the exit code
            cases = {
              synthetic_case(
                a,
                rel,
                "error",
                ("dialect unknown, file not run: %s (set `dialect` in .testing.lua to run it)"):format(
                  tostring(entry.reason or "?")
                )
              ),
            }
          else
            local spec = { path = entry.path, rel = rel, harness = entry.harness, root = root }
            cases = dialect.run_file(entry.dialect, a, spec, {
              select = accept,
              on_case = function(case)
                if guard:take_case() then
                  case.status = "timeout"
                end
                seen_in_file = seen_in_file + 1
                guard:arm_case()
                if M.BAD[case.status] and maxfail then
                  bad_before = bad_before + 1
                  if bad_before >= maxfail then
                    stopped = true
                  end
                end
              end,
            })
          end
        end)
        local file_fired = false
        for _ = 1, 3 do
          local sok, fired = pcall(guard.stop, guard)
          if sok then
            file_fired = fired
            break
          end
        end

        if not ok then
          -- the dialect itself raised (a bug in a shim, or the timeout hook fired inside it)
          if a.current() then
            pcall(a.end_case)
          end
          local message = tostring(err)
          cases = cases or {}
          local case = synthetic_case(a, rel, "error", message)
          if timeout.is_timeout(message) then
            case.status = "timeout"
          end
          cases[#cases + 1] = case
        end
        cases = cases or {}

        if file_fired then
          -- the file deadline passed: whatever the file did, it is a timeout, never a pass
          local marked = false
          for _, c in ipairs(cases) do
            if c.status == "error" and c.error and timeout.is_timeout(c.error.message) then
              c.status = "timeout"
              marked = true
            end
          end
          if not marked then
            local last = cases[#cases]
            if last then
              last.status = "timeout"
              last.notes[#last.notes + 1] =
                "the file deadline passed; the spec caught the timeout error and went on"
            else
              cases[1] = synthetic_case(
                a,
                rel,
                "timeout",
                ("%s file exceeded %s ms: %s"):format(
                  timeout.MARKER,
                  tostring(timeouts.file_ms),
                  rel
                )
              )
            end
          end
        end

        for _, c in ipairs(cases) do
          record(c)
        end
        if maxfail and bad_total >= maxfail then
          stopped = true
        end
      end
    end
  end
  local wall_ms = (hrtime() - started) / 1e6

  -- Assertions that arrived after their file ended (before the IR is finalized) make the run red:
  -- a synthetic case lists them, never a silent drop.
  if #a.late > 0 then
    a.begin_case({ file = "<late>", name = "late assertions" })
    for _, l in ipairs(a.late) do
      a.fail(l.msg)
    end
    record(a.end_case())
  end

  -- Discovery findings: attached to the case of their file, and under `strict` one failing case.
  local findings = opts.findings or {}
  if #findings > 0 then
    local by_rel = {}
    for _, c in ipairs(res.cases) do
      by_rel[c.file] = by_rel[c.file] or c
    end
    local strict_findings = {}
    for _, f in ipairs(findings) do
      local line = ("finding [%s %s] %s"):format(f.rule, f.severity, f.message)
      local target = f.path and by_rel[f.path]
      if target then
        target.notes[#target.notes + 1] = line
      end
      if f.severity ~= "info" then
        strict_findings[#strict_findings + 1] = line
      end
    end
    if opts.strict and #strict_findings > 0 then
      a.begin_case({ file = "<findings>", name = "strict: discovery findings" })
      for _, line in ipairs(strict_findings) do
        a.fail(line)
      end
      record(a.end_case())
    end
  end

  res.run.duration_ms = math.floor(wall_ms * 1000 + 0.5) / 1000
  result.finalize(res)

  local skipped = res.summary.skip
  local exit_code = (bad_total > 0 or (opts.strict and skipped > 0)) and 1 or 0
  local nfailed_files = 0
  for _ in pairs(failed_files) do
    nfailed_files = nfailed_files + 1
  end
  return {
    result = res,
    failed = bad_total,
    failed_files = nfailed_files,
    total = #res.cases,
    files_run = files_run,
    files_unrun = files_unrun,
    files_unselected = files_unselected,
    skipped = skipped,
    stopped = stopped,
    wall_ms = wall_ms,
    exit_code = exit_code,
  }
end

-- =========================================================
-- List (--list / --dry-run)
-- =========================================================

---@class Testing.Inproc.ListItem
---@field id string
---@field file string
---@field dialect string
---@field note? string `skip: ...` / `error: ...` for a file that cannot run.

---@class Testing.Inproc.ListOpts
---@field root string
---@field files (Testing.Discover.File|string)[]
---@field dialect? string
---@field selector? Testing.Select.Selector
---@field lf? table<string, table<string, true>>
---@field timeouts? { file_ms?: integer }

---What a run would run, without running a case. One-case-per-file dialects: the file case. Busted:
---the describe bodies run (as plenary's `--list` would) and the `it` ids are collected, no `it`
---body runs.
---@param opts Testing.Inproc.ListOpts
---@return Testing.Inproc.ListItem[] items
function M.list(opts)
  local root = slashes(opts.root):gsub("/+$", "")
  local a = assert_mod.new()
  local dialect = require("testing.dialect")
  local selector = opts.selector or select_mod.new({})
  local items = {}
  for _, entry in ipairs(entries_of(root, opts.files, opts.dialect or "a")) do
    local rel = entry.rel
    local lf_ids = opts.lf and select_mod.lf_ids(rel, opts.lf) or nil
    local function accept(id)
      if lf_ids ~= nil and not lf_ids[id] then
        return false
      end
      return selector.case_ok(id, rel)
    end
    local file_id = select_mod.file_case_id(rel)
    if entry.missing then
      items[#items + 1] = {
        id = file_id,
        file = rel,
        dialect = "unknown",
        note = "error: " .. tostring(entry.reason),
      }
    elseif entry.dialect == "unknown" then
      items[#items + 1] = {
        id = file_id,
        file = rel,
        dialect = "unknown",
        note = "error: dialect unknown, file not run: " .. tostring(entry.reason),
      }
    elseif entry.dialect ~= "busted" then
      if accept(file_id) then
        items[#items + 1] = { id = file_id, file = rel, dialect = entry.dialect }
      end
    else
      local guard = timeout.start({ label = rel, file_ms = (opts.timeouts or {}).file_ms })
      local ok, cases, list = pcall(
        dialect.run_file,
        "busted",
        a,
        { path = entry.path, rel = rel, root = root },
        { dry = true, select = accept }
      )
      for _ = 1, 3 do
        if pcall(guard.stop, guard) then
          break
        end
      end
      if not ok then
        items[#items + 1] =
          { id = file_id, file = rel, dialect = "busted", note = "error: " .. tostring(cases) }
      else
        for _, l in ipairs(list or {}) do
          items[#items + 1] = { id = l.id, file = rel, dialect = "busted" }
        end
        for _, c in ipairs(cases or {}) do
          if c.status == "error" then
            items[#items + 1] =
              { id = c.id, file = rel, dialect = "busted", note = "error: " .. first_error(c) }
          end
        end
      end
    end
  end
  return items
end

---One line with the total and the slowest files (for a human reading the log).
---@param res Testing.Result
---@param n? integer How many slow files to name (default 5)
---@return string
function M.timing_line(res, n)
  local per_file, order = {}, {}
  for _, c in ipairs(res.cases) do
    if per_file[c.file] == nil then
      per_file[c.file] = 0
      order[#order + 1] = c.file
    end
    per_file[c.file] = per_file[c.file] + c.duration_ms
  end
  table.sort(order, function(x, y)
    if per_file[x] ~= per_file[y] then
      return per_file[x] > per_file[y]
    end
    return x < y
  end)
  local parts = {}
  for i = 1, math.min(n or 5, #order) do
    parts[#parts + 1] = ("%s %.0f ms"):format(vim.fs.basename(order[i]), per_file[order[i]])
  end
  return ("timings: %d file(s) in %.0f ms; slowest: %s"):format(
    #order,
    res.run.duration_ms,
    table.concat(parts, ", ")
  )
end

-- =========================================================
-- IR out: sanitize, encode, write
-- =========================================================

---Path roots for the placeholders of the serialized IR.
---@param root string
---@return Testing.Result.PathRoots
function M.path_roots(root)
  return {
    repo = root,
    home = vim.uv.os_homedir(),
    tmp = vim.fs.dirname(vim.fn.tempname()),
    state = vim.fn.stdpath("state"),
  }
end

---Case-insensitive plain-text replacement.
---@param s string
---@param needle string
---@param repl string
---@return string
local function replace_plain_ci(s, needle, repl)
  local low, nlow = s:lower(), needle:lower()
  local out, pos = {}, 1
  while true do
    local i, j = low:find(nlow, pos, true)
    if not i then
      break
    end
    out[#out + 1] = s:sub(pos, i - 1)
    out[#out + 1] = repl
    pos = j + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

---Scrub what `result.encode` cannot: text a spec printed itself. Spec messages interpolate runtime
---values (a `vim.inspect`ed path has DOUBLED backslashes), and the validator rightly refuses such an
---IR. In place: the root paths in their escaped form become placeholders, in assertion texts and
---case errors. Users, hosts and environment values are the kernel's job (`encode`'s `redact`).
---@param res Testing.Result
---@param root string
function M.scrub_texts(res, root)
  local needles = {}
  for name, path in pairs(M.path_roots(root)) do
    if type(path) == "string" and path ~= "" then
      local doubled = path:gsub("/", "\\"):gsub("\\", "\\\\")
      needles[#needles + 1] = { doubled, result.PLACEHOLDERS[name] }
    end
  end
  table.sort(needles, function(x, y)
    return #x[1] > #y[1]
  end)
  local function scrub(s)
    if type(s) ~= "string" then
      return s
    end
    for _, n in ipairs(needles) do
      s = replace_plain_ci(s, n[1], n[2])
    end
    return s
  end
  for _, case in ipairs(res.cases) do
    for _, as in ipairs(case.assertions) do
      as.msg, as.expected, as.actual = scrub(as.msg), scrub(as.expected), scrub(as.actual)
    end
    for i, note in ipairs(case.notes) do
      case.notes[i] = scrub(note)
    end
    if case.error then
      case.error.message = scrub(case.error.message)
      case.error.traceback = scrub(case.error.traceback)
    end
  end
end

---Redaction input of the kernel: the user name, the host name and the names of the environment.
---@return Testing.Result.Redact redact
---@return string[] forbid Words the validator refuses to find in the result.
local function redaction()
  local words, forbid = {}, {}
  for _, w in ipairs({
    { vim.env.USERNAME or vim.env.USER, "<USER>" },
    { vim.uv.os_gethostname(), "<HOST>" },
    { vim.env.COMPUTERNAME or vim.env.HOSTNAME, "<HOST>" },
  }) do
    if type(w[1]) == "string" and #w[1] >= 3 then
      words[#words + 1] = { text = w[1], ph = w[2] }
      forbid[#forbid + 1] = w[1]
    end
  end
  return { env_names = vim.tbl_keys(vim.fn.environ()), words = words }, forbid
end

---The IR as it may leave the process (file, CI artifact, stdout JSON): paths replaced by
---placeholders, user/host/environment values redacted by the kernel, encoded, decoded again and
---validated, so that what is checked is exactly what a reporter or a consumer reads. The result
---passed in is not changed.
---@param res Testing.Result
---@param root string
---@return Testing.Result|nil ir The decoded, validated IR.
---@return string|nil json The text that was validated.
---@return string|nil err
function M.sanitize(res, root)
  local copy = vim.deepcopy(res)
  M.scrub_texts(copy, root)
  local redact, forbid = redaction()
  local json, err = result.encode(copy, {
    roots = M.path_roots(root),
    case_insensitive = res.run.os == "windows",
    redact = redact,
  })
  if not json then
    return nil, nil, err
  end
  local decoded, derr = require("lib.nvim.json").decode(json)
  if type(decoded) ~= "table" then
    return nil, nil, "the encoded IR does not decode again: " .. tostring(derr)
  end
  local valid, problems =
    result.validate(decoded, { forbid = forbid, forbid_free_text_only = true })
  if not valid then
    return nil, nil, "the IR failed validation:\n  " .. table.concat(problems, "\n  ")
  end
  return decoded, json, nil
end

---Serialize, write and re-validate the IR; only a validated IR reaches the disk (atomically).
---@param res Testing.Result
---@param path string Output file (parents are created).
---@param root string
---@return boolean ok
---@return string|nil err
function M.write_json(res, path, root)
  local _, json, err = M.sanitize(res, root)
  if not json then
    return false, err
  end
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, json, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

return M
