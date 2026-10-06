---@module 'testing.run.project'
---@brief One `testing run` of a project: discovery, selection, order, the run, reporters, history, exit code.
---@description
--- The command-line layer (`testing.cli`) has already parsed the arguments, loaded `.testing.lua`,
--- resolved the dependencies and put them on the runtimepath. What is left, in this order:
---
---   1. the project's `minit` (when the file exists) runs in this editor, the way the old runners
---      `dofile`d their `minimal_init.lua`; a raise is exit code 3;
---   2. discovery (`testing.discover`): spec files, dialect per file, findings (NEW-48 legacy
---      places, symlinks, unknown dialects), the project's own `TESTS/run.lua` order and sentinel;
---   3. selection and order (`testing.run.select`): `--file`, paths, `--lf`/`--ff` (history),
---      `--shuffle`/`--seed`; `--filter`/`--tags`/`--exclude-tags` are applied per case by the driver;
---   4. `--list`: print what would run, exit 0 (exit 2 when nothing is selected);
---   5. the run (`testing.run.inproc`, or the isolated driver for child editors: a child per file or per
---      case, see `testing.run.options`) under the exit guard (a spec cannot end the run with
---      `os.exit`). The guard layer is configured here by ONE adapter (`options.guard_config`);
---      `isolated = "soft"` adds the soft isolation (`testing.isolation`), which restores what a file
---      changed before the next file runs;
---   6. reporters (`testing.report`): the terminal gets the real IR (clickable paths), files and CI
---      output get the sanitized IR (placeholders, redaction, validated); a reporter that fails is
---      exit code 3;
---   7. history (`testing.history`) and the transitional sentinel.
---
--- Exit codes: 0 green, 1 red (a failed/errored/timed-out case; under `--strict` also a skip or a
--- finding), 2 nothing to run / nothing selected, 3 infrastructure (minit, IR, reporter, driver).
---
--- Sentinel (`LIB_TESTS_OK` style, printed last): only on exit 0 of a COMPLETE run with no skipped
--- case. A filtered, partial or skip-containing run prints a distinct last line instead.

local util = require("testing.report.util")

---@param s any
---@return string
local function safe(s)
  return util.clean(s, { bidi = true, c1 = true })
end

local M = {}

M.EXIT_OK = 0
M.EXIT_FAILED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

---@class Testing.Run.Services
---@field out fun(s: string) stdout line sink
---@field err fun(s: string) stderr line sink
---@field inproc? table `testing.run.inproc` (seam for specs)
---@field isolated? table `testing.run.isolated` (seam for specs)
---@field discover? table `testing.discover` (seam for specs)
---@field state_dir? string Overrides `stdpath('state')` (history).
---@field cache_dir? string Overrides `stdpath('cache')` (the result cache, specs).
---@field cache? table Replaces `testing.cache` (specs).
---@field affected? Testing.Run.AffectedSeams Replaces single seams of the affected selection (specs).
---@field color? boolean Overrides the colour decision of the terminal reporter.

local guard_count = 0

---A spec must not end the run on its own: `os.exit` raises inside the spec (so that file becomes an
---`error` case and the run goes on), and quitting the editor any other way (`:qa!`, `:cquit`)
---is reported as "run did not complete" with exit code 3. Exit code 0 alone is therefore never
---the result of an aborted run. Returns the function that removes the guard again.
---The autocmd group is unique per call so that a nested run (a spec of this very project calling
---`main`) cannot clear the guard of the run around it.
---@return fun() release
function M.guard_exit()
  local real_exit = os.exit
  rawset(os, "exit", function(code)
    error(
      ("os.exit(%s) called by a spec while the run is active; refused"):format(tostring(code)),
      2
    )
  end)
  guard_count = guard_count + 1
  local group = vim.api.nvim_create_augroup("TestingRunGuard" .. guard_count, { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      -- a spec that fires `VimLeavePre` itself (`nvim_exec_autocmds`) is not the editor quitting:
      -- `v:exiting` is only set while the editor really exits
      if vim.v.exiting == vim.NIL then
        return
      end
      io.stderr:write(
        "testing: run did not complete: the editor was quit while specs were running\n"
      )
      real_exit(M.EXIT_INFRA)
    end,
  })
  return function()
    rawset(os, "exit", real_exit)
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---`--file` / positional path: project-relative form of a path the user typed.
---@param root string
---@param p string
---@return string
local function rel_path_arg(root, p)
  p = slashes(p):gsub("^%./", ""):gsub("/+$", "")
  local r = root:gsub("/+$", "")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    p = p:sub(#r + 2)
  end
  return p
end

---Case ids, finding messages and paths come from the project under test (hostile text): control
---characters, bidi marks and invalid UTF-8 never reach a log as they are (no `::error::` line
---smuggled in through a newline, no terminal escape).
---@param sel Testing.Discover.Finding
---@return string
local function finding_line(sel)
  return safe(("finding [%s %s] %s"):format(sel.rule, sel.severity, sel.message))
end

---Print the findings (data of the discovery) after the report, where a reader of the log sees them.
---@param findings Testing.Discover.Finding[]
---@param out fun(s: string)
local function print_findings(findings, out)
  if #findings == 0 then
    return
  end
  out("")
  for _, f in ipairs(findings) do
    out(finding_line(f))
  end
end

---Absolute path of the project's `minit` when the file exists.
---@param root string
---@param cfg Testing.ProjectConfig
---@return string|nil
local function minit_path(root, cfg)
  if type(cfg.minit) ~= "string" then
    return nil
  end
  local path = root .. "/" .. cfg.minit
  local stat = vim.uv.fs_stat(path)
  if not (stat and stat.type == "file") then
    return nil
  end
  return path
end

---Run the `minit` file of the project, if there is one.
---@param root string
---@param cfg Testing.ProjectConfig
---@return boolean ok
---@return string|nil err
local function run_minit(root, cfg)
  local path = minit_path(root, cfg)
  if not path then
    return true, nil
  end
  local release = M.guard_exit()
  local ok, err = pcall(dofile, path)
  release()
  if not ok then
    return false, ("minit %s failed: %s"):format(cfg.minit, tostring(err))
  end
  return true, nil
end

---@param args Testing.Args
---@param cfg Testing.ProjectConfig
---@return { case_ms: integer|nil, file_ms: integer|nil }
local function timeouts_of(args, cfg)
  return {
    case_ms = args.case_timeout_ms or cfg.timeouts.case_ms,
    file_ms = args.file_timeout_ms or cfg.timeouts.file_ms,
  }
end

---The reporters to run on the real IR and on the sanitized one.
---@param args Testing.Args
---@return string|nil stdout_reporter `term` (default), `github`, `junit` or `json`
---@return Testing.Report.Spec[] sanitized_specs
local function reporter_plan(args)
  local primary = args.reporter or "term"
  local sanitized = {}
  if primary == "github" or primary == "junit" then
    sanitized[#sanitized + 1] = { name = primary }
  end
  if args.github and primary ~= "github" then
    sanitized[#sanitized + 1] = { name = "github" }
  end
  if args.junit then
    local path = vim.fs.normalize(vim.fn.fnamemodify(args.junit, ":p"))
    sanitized[#sanitized + 1] = { name = "junit", path = path }
  end
  return primary, sanitized
end

---@param sv Testing.Run.Services
---@return table opts Terminal reporter options.
local function term_options(sv, args, ncases)
  local term = require("testing.report.term")
  local color = sv.color
  if color == nil then
    color = term.use_color({
      is_tty = vim.uv.guess_handle(1) == "tty",
      env = {
        NO_COLOR = vim.env.NO_COLOR,
        FORCE_COLOR = vim.env.FORCE_COLOR,
        CLICOLOR_FORCE = vim.env.CLICOLOR_FORCE,
      },
    })
  end
  local durations = 0
  if args.durations ~= nil then
    durations = args.durations == 0 and math.max(ncases, 1) or args.durations
  end
  return { color = color, durations = durations }
end

---One line of the captured output of a child, made safe for a terminal and a CI log: control
---characters (ESC, OSC and CSI sequences, BEL, bare CR) and bidi overrides become a visible `\xNN` /
---`\u{NNNN}` (the spec's own `print` must not be able to clear the screen, retitle the window, or
---forge a link), and a leading `::` (a GitHub workflow command such as `::error::` or
---`::stop-commands::`) is written as `\x3A:` so that no runner executes it, whatever a reporter does with the
---indent later.
---@param line string
---@return string
local function safe_output_line(line)
  local clean = util.clean(line, { bidi = true, c1 = true })
  return (clean:gsub("^(%s*)::", "%1\\x3A:"))
end

---Plain text for any line of the run's own diagnostics (`--profile`, the cache line): see `safe_output_line`.
---@param line string
---@return string
function M.safe_line(line)
  return safe_output_line(line)
end

---The captured output of a child, as the lines printed before the report: capped, one header.
---@param rel string
---@param text string
---@return string
local function output_block(rel, text)
  local lines = {}
  for line in (text:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  local max = 200
  local shown = lines
  if #lines > max then
    shown = vim.list_slice(lines, 1, max / 2)
    shown[#shown + 1] = ("... %d line(s) omitted (the red cases keep the tail) ..."):format(
      #lines - max
    )
    vim.list_extend(shown, vim.list_slice(lines, #lines - max / 2 + 1, #lines))
  end
  local out = { safe(("output of %s:"):format(rel)) }
  for _, l in ipairs(shown) do
    out[#out + 1] = "  " .. safe_output_line(l)
  end
  return table.concat(out, "\n")
end

---Under `assertions = "warn"` a case that asserts nothing passes; the terminal says how many and which
---(the IR carries them as `no_assertions` assertions and a note, but nobody reads the IR of a green run).
---@param res Testing.Result
---@param out fun(s: string)
local function print_unasserted(res, out)
  local ids = {}
  for _, c in ipairs(res.cases) do
    for _, a in ipairs(c.assertions or {}) do
      if a.kind == "no_assertions" and a.ok then
        ids[#ids + 1] = c.id
        break
      end
    end
  end
  if #ids == 0 then
    return
  end
  local shown = math.min(#ids, 10)
  out(('\n%d case(s) passed without asserting anything (assertions = "warn"):'):format(#ids))
  for i = 1, shown do
    out(safe("  " .. ids[i]))
  end
  if #ids > shown then
    out(("  ... and %d more"):format(#ids - shown))
  end
end

---Under `assertions = "warn"` a busted file without a registered case is a skip with a warning; the
---terminal names the files (a skip is never silent, and `--strict` makes it red).
---@param res Testing.Result
---@param out fun(s: string)
local function print_no_case(res, out)
  local files = {}
  local warning = require("testing.dialect.busted").NO_CASE_WARNING
  for _, c in ipairs(res.cases) do
    for _, n in ipairs(c.notes or {}) do
      if n == warning then
        files[#files + 1] = c.file or c.id
        break
      end
    end
  end
  if #files == 0 then
    return
  end
  out(
    ('\n%d file(s) registered no case on this platform (assertions = "warn", skipped):'):format(
      #files
    )
  )
  for i = 1, math.min(#files, 10) do
    out(safe("  " .. files[i]))
  end
  if #files > 10 then
    out(("  ... and %d more"):format(#files - 10))
  end
end

---Execute one run of a project.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@return integer exit_code
function M.execute(plan, sv)
  local raw_err = sv.err
  -- every diagnostic line passes `util.clean`, one physical line at a time
  local function err(s)
    for line in (tostring(s) .. "\n"):gmatch("(.-)\n") do
      raw_err(safe(line))
    end
  end
  local options_mod = require("testing.run.options")
  local run_opts = options_mod.of(plan)

  -- the test-environment defaults go in before the minit and come out again on every exit path
  local restore_first_run = options_mod.apply_first_run_default(run_opts.disable_first_run)
  -- surface tracking (`surface.track = true`) goes in before the minit too: a minit may call `setup()`
  local tracker
  if run_opts.surface and not plan.args.list then
    if run_opts.pool.reuse then
      err(
        "testing: note: surface tracking is not active with the warm pool (--pool-reuse): no case carries `surface`"
      )
      run_opts.surface = nil
    else
      local tok, t = pcall(function()
        return require("testing.surface.track").hook_runner(run_opts.surface)
      end)
      if tok then
        tracker = t
      else
        err("testing: note: surface tracking could not be installed: " .. tostring(t))
        run_opts.surface = nil
      end
    end
  end
  local ok, code = pcall(M.execute_run, plan, sv, run_opts, err)
  if tracker then
    local left = tracker:uninstall()
    if type(left) == "table" and #left > 0 then
      err("testing: note: surface tracking could not undo: " .. table.concat(left, ", "))
    end
  end
  restore_first_run()
  if not ok then
    error(code, 0)
  end
  return code
end

---The body of `M.execute`, split off so the editor's globals are restored on every exit path.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param run_opts Testing.Run.Options
---@param err fun(s: string)
---@return integer exit_code
function M.execute_run(plan, sv, run_opts, err)
  local out = sv.out
  local args, root, cfg = plan.args, plan.root, plan.project
  local inproc = sv.inproc or require("testing.run.inproc")
  local select_mod = require("testing.run.select")
  local options_mod = require("testing.run.options")
  local mok, merr = run_minit(root, cfg)
  if not mok then
    err("testing: " .. tostring(merr))
    return M.EXIT_INFRA
  end

  -- 2. discovery
  local discover = sv.discover or require("testing.discover")
  local disc = discover.discover(
    root,
    { roots = cfg.roots, dialect = cfg.dialect, spec_pattern = cfg.spec_pattern }
  )
  local ordered, order_notes = discover.order(disc)
  for _, note in ipairs(order_notes) do
    err("testing: note: " .. note)
  end
  local total = #ordered
  local known = {}
  for _, f in ipairs(ordered) do
    known[f.rel] = true
  end

  -- 3. selection by file / path
  local selector = select_mod.new({
    file = args.file,
    filter = args.filter,
    tags = args.tags,
    exclude_tags = args.exclude_tags,
  })
  local path_args = {}
  for _, p in ipairs(args.paths) do
    path_args[#path_args + 1] = rel_path_arg(root, p)
  end
  local files = {}
  for _, f in ipairs(ordered) do
    local keep = selector.file_ok(f.rel)
    if keep and #path_args > 0 then
      keep = false
      for _, p in ipairs(path_args) do
        if f.rel == p or f.rel:sub(1, #p + 1) == p .. "/" then
          keep = true
          break
        end
      end
    end
    if keep then
      files[#files + 1] = f
    end
  end
  if #files == 0 then
    local why = {}
    if #args.file > 0 then
      why[#why + 1] = "matching " .. table.concat(args.file, ", ")
    end
    if #path_args > 0 then
      why[#why + 1] = "below " .. table.concat(path_args, ", ")
    end
    err(
      ("testing: no *_spec.lua file found in %s%s"):format(
        root,
        #why > 0 and (" " .. table.concat(why, " ")) or ""
      )
    )
    return M.EXIT_USAGE
  end

  -- 3b. --changed / --since / --affected: only the specs the changes can reach (never the default in CI)
  local selection_label
  do
    local sel, aerr =
      require("testing.run.cached").select_affected(plan, ordered, files, sv.affected)
    if aerr then
      err("testing: " .. aerr)
      return M.EXIT_USAGE
    end
    if sel then
      for _, note in ipairs(sel.notes) do
        err("testing: note: " .. note)
      end
      if #sel.files < #files then
        selection_label = sel.label
      end
      files = sel.files
      if #files == 0 then
        out(
          ("no spec file is affected by the changes (%s): nothing ran. This is not a green run (no sentinel); run without %s to run everything"):format(
            sel.label,
            sel.label:match("^%-%-%a+")
          )
        )
        return M.EXIT_OK
      end
    end
  end

  -- history: --lf / --ff
  local lf_by_file
  local remembered = {}
  if args.lf or args.ff then
    local history = require("testing.history")
    local hist = history.load(root, { state_dir = sv.state_dir })
    for _, note in ipairs(hist.notes) do
      err("testing: note: " .. note)
    end
    local by_file = select_mod.group_failed(hist.failed)
    remembered = by_file
    if args.lf then
      local only = {}
      for _, f in ipairs(files) do
        if by_file[f.rel] then
          only[#only + 1] = f
        end
      end
      if #only == 0 then
        err("testing: note: --lf: no remembered failure for the selected files, running them all")
      else
        files = only
        lf_by_file = by_file
      end
    end
    if args.ff then
      files = select_mod.failed_first(files, function(f)
        return f.rel
      end, by_file)
    end
  end

  -- order: shuffle
  local seed
  if args.shuffle then
    seed = args.seed or select_mod.fresh_seed()
    files = select_mod.shuffle(files, seed)
    if args.ff then
      files = select_mod.failed_first(files, function(f)
        return f.rel
      end, remembered)
    end
    out(("shuffle: seed %d (repeat with --shuffle --seed %d)"):format(seed, seed))
  end

  -- the selector of the driver needs the header tags of a file (cached there)
  local header_cache = {}
  selector = select_mod.new({
    filter = args.filter,
    tags = args.tags,
    exclude_tags = args.exclude_tags,
    header_tags = function(rel)
      if header_cache[rel] == nil then
        header_cache[rel] = select_mod.file_header_tags(root .. "/" .. rel)
      end
      return header_cache[rel]
    end,
  })
  local timeouts = timeouts_of(args, cfg)
  local findings = disc.findings

  -- 4. list
  if args.list then
    local items = inproc.list({
      root = root,
      files = files,
      selector = selector,
      lf = lf_by_file,
      timeouts = timeouts,
    })
    if #items == 0 then
      err("testing: no case matches the selection")
      return M.EXIT_USAGE
    end
    local nfiles, seen = 0, {}
    for _, it in ipairs(items) do
      if not seen[it.file] then
        seen[it.file] = true
        nfiles = nfiles + 1
      end
      out(safe(("%s%s"):format(it.id, it.note and ("  (" .. it.note .. ")") or "")))
    end
    print_findings(findings, out)
    out(("%d case(s) in %d of %d spec file(s) would run"):format(#items, nfiles, total))
    return M.EXIT_OK
  end

  -- 5. run: in this editor, or (per file, see `testing.run.options`) in a child editor of its own
  local release = M.guard_exit()
  local common = {
    root = root,
    files = files,
    argv = plan.argv,
    selector = selector,
    lf = lf_by_file,
    maxfail = args.maxfail,
    seed = seed,
    timeouts = timeouts,
    findings = findings,
    strict = args.strict,
    assertions = run_opts.assertions,
    -- the guard layer (`testing.guard`, optional) is configured from ONE adapter; with no such module
    -- the runner measures nothing and says so in the notes of the cases
    guard_cfg = options_mod.guard_config(run_opts, { root = root, seed = seed }),
  }
  local soft
  if options_mod.is_soft(run_opts) then
    -- `isolated = "soft"`: what a file changed is restored before the next one; `guards.state` decides
    -- whether a leak is reported (warn), fails the case (error) or is only undone (off)
    local mode = run_opts.guards.state
    soft = require("testing.isolation").new({
      keep = run_opts.soft_keep,
      severity = (mode == "warn" or mode == "error") and mode or nil,
      -- with a guard layer its `state` guard names every leak per case: this layer then reports only
      -- what it could not restore
      report_restored = not require("testing.run.guards").available(),
    })
    common.soft = soft
  end
  do
    -- `--isolated=case` degrades to a child per file for every dialect but busted: say so once
    local degraded = 0
    for _, f in ipairs(files) do
      local _, note = options_mod.isolation_of(run_opts, f)
      if note then
        degraded = degraded + 1
      end
    end
    if degraded > 0 then
      err(
        ("testing: note: --isolated=case: %d spec file(s) are not busted (one case per file) and run as one child per file"):format(
          degraded
        )
      )
    end
  end
  -- the result cache: a file whose inputs are byte-identical to an earlier green run does not run
  local cached_mod = require("testing.run.cached")
  local prep = cached_mod.prepare({
    plan = plan,
    run_opts = run_opts,
    files = files,
    selector = selector,
    lf = lf_by_file,
    findings = findings,
    seed = seed,
    cache_dir = sv.cache_dir,
    cache = sv.cache,
    getenv = sv.affected and sv.affected.getenv or nil,
  })
  if prep.why_off then
    err("testing: note: cache not used: " .. prep.why_off)
  end
  common.files = prep.run_files
  local ok, report
  if #prep.run_files == 0 then
    ok, report = true, cached_mod.empty_report(plan, seed)
  elseif options_mod.any_isolated(run_opts, prep.run_files) then
    local prepend, append, child_env = options_mod.child_rtp(plan)
    common.child_env = child_env
    common.options = run_opts
    common.selector_spec =
      { filter = args.filter, tags = args.tags, exclude_tags = args.exclude_tags }
    common.rtp_prepend, common.rtp = prepend, append
    common.minit = minit_path(root, cfg)
    common.on_output = function(rel, text)
      err(output_block(rel, text))
    end
    ok, report = pcall((sv.isolated or require("testing.run.isolated")).run, common)
  else
    ok, report = pcall(inproc.run, common)
  end
  release()
  if not ok then
    err("testing: internal error: " .. tostring(report))
    return M.EXIT_INFRA
  end
  if prep.mode ~= "off" then
    local fok, ferr = pcall(
      cached_mod.finish,
      prep,
      report,
      { cache = sv.cache, cache_dir = sv.cache_dir, root = root }
    )
    if not fok then
      err("testing: note: the cache could not be merged into the report: " .. tostring(ferr))
      return M.EXIT_INFRA
    end
  end
  for _, note in ipairs(report.notes or {}) do
    err("testing: note: " .. note)
  end
  for _, f in ipairs(report.unattached or {}) do
    -- findings of a file that has no case to carry them (everything filtered out, ...)
    err(safe(("testing: guard [%s %s] %s"):format(f.guard, f.severity, f.message)))
  end
  if soft then
    local t = soft:totals()
    if t.leaky_files > 0 then
      err(
        ("testing: note: soft isolation: %d of %d file(s) changed state (%d difference(s) restored, %d not restorable)"):format(
          t.leaky_files,
          t.files,
          t.restored,
          t.unrestored
        )
      )
    end
  end
  local res = report.result
  if #res.cases == 0 then
    err("testing: no case matched the selection; nothing ran")
    return M.EXIT_USAGE
  end
  -- 6. reporters
  local primary, sanitized_specs = reporter_plan(args)
  local reports = require("testing.report")
  local code = report.exit_code
  local infra_failed = false

  ---@param outputs Testing.Report.Output[]
  ---@param errors string[]
  local function emit(outputs, errors)
    for _, o in ipairs(outputs) do
      if not o.path and not o.err then
        for _, line in ipairs(o.lines) do
          out(line)
        end
      end
    end
    for _, e in ipairs(errors) do
      err("testing: " .. e)
      infra_failed = true
    end
  end

  if primary == "term" then
    emit(reports.run_reporters(res, {
      reporters = { "term" },
      defaults = { term = term_options(sv, args, #res.cases) },
    }))
  end
  local need_ir = #sanitized_specs > 0 or primary == "json" or args.json ~= nil
  local ir, json_text
  if need_ir then
    local serr
    ir, json_text, serr = inproc.sanitize(res, root)
    if not ir then
      err("testing: " .. tostring(serr))
      return M.EXIT_INFRA
    end
    if type(ir.warnings) == "table" and #ir.warnings > 0 then
      err(
        ("testing: note: the IR carries %d privacy warning(s) (see `warnings`)"):format(
          #ir.warnings
        )
      )
    end
  end
  if #sanitized_specs > 0 then
    emit(reports.run_reporters(ir --[[@as Testing.Result]], { reporters = sanitized_specs }))
  end
  if primary == "json" then
    out(json_text --[[@as string]])
  end
  if args.json then
    local path = vim.fs.normalize(vim.fn.fnamemodify(args.json, ":p"))
    local wrote, werr =
      require("lib.nvim.fs.write.atomic")(path, json_text --[[@as string]], { mkdirp = true })
    if not wrote then
      err(("testing: cannot write %s: %s"):format(path, tostring(werr)))
      return M.EXIT_INFRA
    end
  end

  print_findings(findings, out)
  if primary == "term" then
    print_unasserted(res, out)
    print_no_case(res, out)
  end
  if report.stopped and report.files_unrun > 0 then
    out(
      ("\nstopped after %d failure(s) (--maxfail %d): %d file(s) not run"):format(
        report.failed,
        args.maxfail or report.failed,
        report.files_unrun
      )
    )
  end
  local cache_line = cached_mod.summary_line(prep)
  if cache_line then
    -- the reasons carry names from the project's files (environment variables, modules): plain text only
    cache_line = safe_output_line(cache_line)
    if primary == "term" then
      out("\n" .. cache_line)
    else
      err("testing: note: " .. cache_line)
    end
  end
  if args.timings then
    out(
      (cache_line and primary == "term") and inproc.timing_line(res)
        or ("\n" .. inproc.timing_line(res))
    )
  end

  -- 7. history (a convenience: a failure to write is a note, never the verdict)
  local full = not selector.active and lf_by_file == nil and not report.stopped
  local ran_files = {}
  if full then
    for _, c in ipairs(res.cases) do
      ran_files[c.file] = true
    end
  end
  local hok, herr = pcall(function()
    local rok, rerr, rnote = require("testing.history").record(
      root,
      res,
      { ran_files = ran_files, known_files = known },
      { state_dir = sv.state_dir }
    )
    if not rok then
      err("testing: note: history not updated: " .. tostring(rerr))
    elseif rnote then
      err("testing: note: " .. rnote)
    end
  end)
  if not hok then
    err("testing: note: history not updated: " .. tostring(herr))
  end

  if infra_failed then
    return M.EXIT_INFRA
  end

  -- the sentinel: last line, only for a complete, green run without a skipped case
  if code == M.EXIT_OK then
    local partial_files = #files < total
    if selection_label and not selector.active and lf_by_file == nil then
      out(
        ("\npartial run: %d of %d spec files (%s; no sentinel)"):format(
          #files,
          total,
          selection_label
        )
      )
    elseif partial_files and not selector.active and lf_by_file == nil then
      out(("\npartial run: %d of %d spec files (no sentinel)"):format(#files, total))
    elseif partial_files or selector.active or lf_by_file ~= nil then
      out("\npartial run: a selection (--filter, --tags, --lf, a path) applied (no sentinel)")
    elseif report.skipped > 0 then
      out(("\n%d case(s) skipped: a skip is never green (no sentinel)"):format(report.skipped))
    else
      out("\n" .. (args.sentinel or disc.runner.sentinel or "TESTING_OK"))
    end
  end
  return code
end

return M
