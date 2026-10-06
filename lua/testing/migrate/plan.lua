---@module 'testing.migrate.plan'
---@brief Turns a migration report into a list of file operations, as data. Writes nothing.
---@description
--- `M.plan(report, opts)` returns the operations that make a repository run on testing.nvim with its
--- specs UNCHANGED. Every operation carries the complete new text, the unified diff against the text
--- that was read, and the lines that disappear, so nothing is overwritten without being shown.
---
---   * `.testing.lua`           created when absent (never touched when present): `plugin`, `roots`,
---                              `dialect` (the project's own harness `h` for `return function(H)` specs on
---                              it, `script` for self-running scripts), `spec_pattern`, `deps`,
---                              `isolated`, `host`. `assertions` and `timeouts` are NOT set: they are
---                              notes ("set it when a run asks for it"), a measurement decides;
---   * `scripts/test.sh`        created, or replaced when it still starts plenary / the old runner;
---   * `TESTS/minimal_init.lua` created when absent (then with what `scripts/minimal_init.lua` set up
---                              besides the old runner, as a commented block, and that old file is
---                              DELETED); otherwise only the plenary statements are removed (self-contained
---                              call lines only, the rest of the file is kept as is);
---   * `.github/workflows/*`    edited line by line (`testing.migrate.ci`); a reference to the deleted
---                              `scripts/minimal_init.lua` points to the new file.
---
--- The Lua files the plan CREATES are formatted with the `stylua.toml` of the repository
--- (`testing.migrate.format`); without `stylua` on PATH they stay in the template's style and a note says
--- so. Notes also list the lines of README / TESTS README / `.luacheckrc` that still talk about the old
--- runner (to reword by hand), and count (never change) such comments in the specs.
---
--- Idempotent by construction: each operation tests for its own result, so the plan of a migrated
--- repository is empty (`plan.empty`). Specs, `TESTS/harness.lua` and `TESTS/run.lua` are never in the
--- plan: the old runner stays until both runners give the same verdict.

local render = require("testing.scaffold.render")
local scaffold = require("testing.scaffold")
local text = require("testing.migrate.text")
local ci = require("testing.migrate.ci")
local format = require("testing.migrate.format")
local legacy_init = require("testing.migrate.legacy_init")

local M = {}

---@param s string
---@return string
local function q(s)
  return render.lua_quote(s)
end

---@param items string[]
---@return string
local function lua_list(items)
  local parts = {}
  for _, s in ipairs(items) do
    parts[#parts + 1] = q(s)
  end
  return #parts == 0 and "{}" or ("{ " .. table.concat(parts, ", ") .. " }")
end

---The `dialect` value of `.testing.lua` for the report.
---@param report Testing.Migrate.Report
---@param risk fun(msg: string)
---@return string|table<string, string> dialect
---@return table<string, string> want Per file: the dialect it should run in (`auto` = let the sniffer decide).
local function dialect_of(report, risk)
  local invoked = {}
  for _, s in ipairs(report.runner.scripts_invoked or {}) do
    invoked[s] = true
  end
  local has_harness = report.harness.file ~= nil
  ---@type table<string, string>
  local want = {}
  local files = {}
  for _, f in ipairs(report.specs.files) do
    files[#files + 1] = f.rel
    local d = f.dialect
    if d == "a" or d == "b" or d == "c" or d == "h" then
      want[f.rel] = (has_harness or f.harness) and "h" or "auto"
    elseif d == "unknown" then
      if invoked[f.rel] then
        want[f.rel] = "script"
      else
        want[f.rel] = "auto"
        risk(
          ("%s: dialect unknown and not started by `-l`/`luafile` in the old runner; left on `auto` (the run reports it)"):format(
            text.show(f.rel)
          )
        )
      end
    else
      want[f.rel] = "auto"
    end
  end
  -- self-running scripts without the `_spec` suffix
  for _, s in ipairs(report.runner.scripts_no_suffix or {}) do
    want[s] = "script"
    files[#files + 1] = s
  end
  if #files == 0 then
    return "auto", want
  end
  local count = {}
  for _, f in ipairs(files) do
    count[want[f]] = (count[want[f]] or 0) + 1
  end
  local star, best = "auto", -1
  local names = vim.tbl_keys(count)
  table.sort(names)
  for _, n in ipairs(names) do
    if count[n] > best then
      star, best = n, count[n]
    end
  end
  local table_form = {}
  for _, f in ipairs(files) do
    if want[f] ~= star then
      if text.is_safe_rel(f) then
        table_form[f] = want[f]
      else
        risk(
          ("%s cannot be named in .testing.lua (unsafe path); set its dialect by hand"):format(
            text.show(f)
          )
        )
      end
    end
  end
  if next(table_form) == nil then
    return star, want
  end
  table_form["*"] = star
  return table_form, want
end

---Render `.testing.lua`.
---@param c table Keys in order of appearance.
---@return string
local function render_config(c)
  local out = {
    "-- .testing.lua -- configuration of testing.nvim for this project.",
    "-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the",
    "-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust",
    "-- as running the specs).",
    "return {",
  }
  local function add(comment, line)
    out[#out + 1] = "  -- " .. comment
    out[#out + 1] = "  " .. line
  end
  add("Lua module root of the project.", "plugin = " .. q(c.plugin) .. ",")
  if c.roots then
    add(
      "Where the specs live (relative to this directory).",
      "roots = " .. lua_list(c.roots) .. ","
    )
  end
  if type(c.dialect) == "string" then
    add(
      'How the spec files are run: "auto" = sniffed per file, "h" = on the project\'s own TESTS/harness.lua,\n  -- "script" = a self-running script in its own process.',
      "dialect = " .. q(c.dialect) .. ","
    )
  else
    out[#out + 1] =
      '  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project\'s own'
    out[#out + 1] = '  -- TESTS/harness.lua, "script" = a self-running script in its own process.'
    out[#out + 1] = "  dialect = {"
    local keys = vim.tbl_keys(c.dialect)
    table.sort(keys, function(a, b)
      if a == "*" or b == "*" then
        return a == "*"
      end
      return a < b
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = ("    [%s] = %s,"):format(q(k), q(c.dialect[k]))
    end
    out[#out + 1] = "  },"
  end
  if c.spec_pattern then
    add(
      "Lua patterns a file name must match to be a spec (the old runner started these files by name).",
      "spec_pattern = " .. lua_list(c.spec_pattern) .. ","
    )
  end
  add(
    "Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,\n  -- stdpath('data')/lazy/<name>.",
    "deps = " .. lua_list(c.deps) .. ","
  )
  add(
    '"none" = all specs in one nvim, "file" = one nvim per spec file\n  -- (nothing leaks from one file into the next).',
    "isolated = " .. q(c.isolated) .. ","
  )
  if c.host then
    add(
      '"c" = child started from a -c command (v:vim_did_enter is 0, <cword> works),\n  -- "l" = `nvim -l`.',
      "host = " .. q(c.host) .. ","
    )
  end
  if c.env_allow then
    add(
      "Environment variables the specs read; a child editor inherits an allowlist only (never secrets).",
      "env_allow = " .. lua_list(c.env_allow) .. ","
    )
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

---Is `l` a self-contained call statement (balanced brackets, nothing that opens a block)?
---@param l string
---@return boolean
local function is_removable_statement(l)
  if not l:match("^%s*[%a_][%w_%.:]*%s*%(") then
    return false
  end
  if
    l:match("%f[%w_]function%f[^%w_]")
    or l:match("%f[%w_]then%s*$")
    or l:match("%f[%w_]do%s*$")
  then
    return false
  end
  local function count(ch)
    local _, n = l:gsub("%" .. ch, "")
    return n
  end
  return count("(") == count(")") and count("{") == count("}") and count("[") == count("]")
end

---Remove the plenary statements of `TESTS/minimal_init.lua`.
---@param src string
---@param report Testing.Migrate.Report
---@return string|nil new_text nil when nothing (safe) can be removed.
---@return string[] kept Plenary lines that stay, with the reason.
local function edit_minit(src, report)
  local lines, shape = text.lines(src)
  local kept = {}
  local drop = {}
  for _, pl in ipairs(report.minimal_init.plenary_lines) do
    if pl.kind == "code" then
      if is_removable_statement(lines[pl.lnum] or "") then
        drop[pl.lnum] = true
      else
        kept[#kept + 1] = ("line %d: `%s` (not a self-contained call: edit by hand)"):format(
          pl.lnum,
          text.show(pl.text, 100)
        )
      end
    end
  end
  if next(drop) == nil then
    return nil, kept
  end
  local out = {}
  for i, l in ipairs(lines) do
    if not drop[i] then
      out[#out + 1] = l
    end
  end
  local new_text = text.join(out, shape)
  if not loadstring(new_text) then
    -- A removal that breaks the file is worse than a stale line.
    return nil,
      { "removing the plenary statements would leave a file that does not compile: edit by hand" }
  end
  return new_text, kept
end

---@param before string|nil
---@param after string|nil Nil: the file is deleted.
---@param path string
---@param extra table
---@return Testing.Migrate.Op
local function make_op(before, after, path, extra)
  local op = {
    path = path,
    action = after == nil and "delete" or (before == nil and "create" or "modify"),
    before = before,
    after = after,
    diff = text.unified(before, after, path),
    removed = before and text.removed_lines(before, after or "") or {},
  }
  for k, v in pairs(extra) do
    op[k] = v
  end
  return op
end

---Plan the migration.
---@param report Testing.Migrate.Report
---@param opts? Testing.Migrate.PlanOpts
---@return Testing.Migrate.Plan
function M.plan(report, opts)
  opts = opts or {}
  local owner = opts.owner or scaffold.DEFAULT_OWNER
  ---@type Testing.Migrate.Plan
  local plan = {
    root = report.root,
    name = report.name,
    ops = {},
    notes = {},
    risks = vim.deepcopy(report.risks or {}),
    empty = true,
  }
  local function note(msg)
    plan.notes[#plan.notes + 1] = msg
  end
  local function risk(msg)
    plan.risks[#plan.risks + 1] = msg
  end
  ---A Lua file the plan creates, formatted for the stylua configuration of the repository.
  ---@param src string
  ---@param rel string
  ---@return string
  local function formatted(src, rel)
    local out, hint = format.lua(src, rel, report.root, opts.format)
    if hint then
      note(hint)
    end
    return out
  end
  if report.error then
    plan.error = report.error
    return plan
  end
  if report.third_party then
    plan.skipped = ("the origin (%s) is not a repository of %s: not a migration target"):format(
      text.show(report.origin or "?", 120),
      owner
    )
    return plan
  end

  -- ---------------------------------------------------------------- dependencies
  local dep_names = {}
  local fleet_deps = {}
  for _, d in ipairs(report.deps.list) do
    if require("testing.deps").is_valid_name(d.name) then
      dep_names[#dep_names + 1] = d.name
      if d.kind == "fleet" then
        fleet_deps[#fleet_deps + 1] = d.name
      end
    else
      risk(
        ("dependency name %s is not a valid directory name: skipped"):format(text.show(d.name, 60))
      )
    end
  end

  -- ---------------------------------------------------------------- .testing.lua
  local dialect, want = dialect_of(report, risk)
  local scripts = report.runner.scripts_no_suffix or {}
  local conf = {
    plugin = report.plugin or report.name:gsub("%.nvim$", ""),
    dialect = dialect,
    deps = dep_names,
    isolated = report.policy.isolated,
    host = report.policy.host,
    env_allow = report.env and #report.env.allow > 0 and report.env.allow or nil,
  }
  local has_script = false
  for _, w in pairs(want) do
    has_script = has_script or w == "script"
  end
  -- also the scripts the sniffer recognises by itself: the old CI started them with `nvim -l`
  for _, f in ipairs(report.specs.files) do
    has_script = has_script or f.dialect == "script"
  end
  if has_script then
    if conf.host == nil then
      conf.host = "l"
    elseif conf.host ~= "l" then
      risk(
        'busted specs and self-running scripts in one repository: `host` is one value, check the scripts under host "c"'
      )
    end
  end
  local plenary_dirs = report.runner.plenary_dirs or {}
  if #plenary_dirs > 0 and not (#plenary_dirs == 1 and plenary_dirs[1] == "TESTS") then
    local roots = {}
    for _, d in ipairs(plenary_dirs) do
      if text.is_safe_rel(d) then
        roots[#roots + 1] = d
      end
    end
    -- directories whose specs the old CI ran through a runner script of their own (mdview's
    -- TESTS/nvim/harness.lua) are roots too, or those specs would silently stop running
    for _, d in ipairs(report.runner.runner_dirs or {}) do
      if text.is_safe_rel(d) and not vim.tbl_contains(roots, d) then
        roots[#roots + 1] = d
      end
    end
    -- self-running scripts outside those directories must stay reachable
    for _, s in ipairs(scripts) do
      local covered = false
      for _, r in ipairs(roots) do
        covered = covered or s:sub(1, #r + 1) == r .. "/"
      end
      if not covered and text.is_safe_rel(vim.fs.dirname(s)) then
        roots[#roots + 1] = vim.fs.dirname(s)
      end
    end
    if #roots > 0 then
      conf.roots = roots
    end
  end
  if #scripts > 0 then
    local patterns = { "_spec%.lua$" }
    for _, s in ipairs(scripts) do
      -- the whole relative path, anchored: `smoke%.lua$` would also name `TESTS/old_smoke.lua`
      if text.is_safe_rel(s) and s:match("^[%w_%./%-]+$") then
        patterns[#patterns + 1] = "^" .. (s:gsub("[%-%.]", "%%%0")) .. "$"
      else
        risk(
          ("%s: a name with unusual characters cannot be put in spec_pattern"):format(text.show(s))
        )
      end
    end
    conf.spec_pattern = patterns
  end
  if not report.dot_testing then
    plan.config = conf
    local after = formatted(render_config(conf), ".testing.lua")
    plan.ops[#plan.ops + 1] = make_op(nil, after, ".testing.lua", {
      kind = "config",
      reason = "the project configuration for testing.nvim (dialects, dependencies, isolation)",
    })
  else
    note(".testing.lua exists and is kept as it is (the migration never overwrites it)")
    -- Read as text, never executed: the keys the migration would have set that the file does not name.
    local existing = report.texts[".testing.lua"] or ""
    local missing = {}
    if not existing:find("isolated", 1, true) and report.policy.isolated == "file" then
      missing[#missing + 1] = 'isolated = "file" (the old runner ran one nvim per spec file)'
    end
    for _, d in ipairs(dep_names) do
      if not existing:find(d, 1, true) then
        missing[#missing + 1] = ("%s in deps"):format(d)
      end
    end
    if #missing > 0 then
      note(".testing.lua does not name: " .. table.concat(missing, "; "))
    end
  end

  -- Measured, not guessed: a zero-assertion case or a slow case shows in the first run, so these are hints.
  do
    local existing = report.dot_testing and (report.texts[".testing.lua"] or "") or ""
    if not existing:find("assertions", 1, true) then
      note(
        '`assertions` is not set (default "error": a case without assertions FAILS). The old runner let such cases pass: set `assertions = "warn"` in .testing.lua only if the first run reports cases without assertions, and fix them later'
      )
    end
    if report.policy.timeouts and not existing:find("timeouts", 1, true) then
      note(
        "`timeouts` is not set (default case_ms 10000). The old runner had no limit per case: set `timeouts = { case_ms = <ms> }` in .testing.lua only if a run reports a case that timed out"
      )
    end
  end

  -- ---------------------------------------------------------------- scripts/test.sh
  local sentinel = report.harness.sentinel
  if not report.test_sh.migrated then
    local plugin_for_app = scaffold.sanitize_plugin(conf.plugin) or "plugin"
    local extra = { RUN_ARGS = "" }
    if type(sentinel) == "string" and sentinel:match("^[%u%d_]+$") then
      extra.RUN_ARGS = " --sentinel " .. render.sh_quote(sentinel)
    end
    local vars, verr = scaffold.build_vars(plugin_for_app, dep_names, owner, extra)
    local after, rerr
    if vars then
      after, rerr = scaffold.render_template("test.sh.tpl", vars)
    end
    if after then
      local before = report.texts["scripts/test.sh"]
      plan.ops[#plan.ops + 1] = make_op(before, after, "scripts/test.sh", {
        kind = "script",
        exec = true,
        reason = before
            and (report.test_sh.plenary and "replaces the plenary runner script" or "replaces the old runner script (review the diff: it did not mention plenary)")
          or "the runner entry point of the project (resolves testing.nvim and the dependencies, exits 1 when one is missing)",
      })
      if before and not report.test_sh.plenary then
        risk(
          "scripts/test.sh did not mention plenary but is replaced: review its diff (its own arguments are gone, everything now goes to `testing run`, e.g. `--file <fragment>`)"
        )
      end
    else
      risk("scripts/test.sh cannot be rendered: " .. tostring(verr or rerr))
    end
  end

  -- ---------------------------------------------------------------- TESTS/minimal_init.lua
  local legacy = report.legacy_init
  local retire = legacy ~= nil and legacy.legacy == true
  local retired_init = false
  if not report.minimal_init.exists then
    local plugin_for_app = scaffold.sanitize_plugin(conf.plugin) or "plugin"
    local vars = scaffold.build_vars(plugin_for_app, dep_names, owner)
    local after = vars and scaffold.render_template("minimal_init.lua.tpl", vars)
    if after then
      local carried = 0
      if retire then
        ---@cast legacy -?
        local base = after
        local section = legacy_init.section(legacy.blocks, legacy.rel)
        local tail = "return { root = root, deps = found }"
        local at = after:find(tail, 1, true)
        if section and at then
          after = after:sub(1, at - 1) .. section .. "\n" .. after:sub(at)
          for _, b in ipairs(legacy.blocks) do
            carried = carried + (b.kind == "carry" and 1 or 0)
          end
          -- a carried statement must neither shadow what the template defines nor break the file
          local clash
          for _, name in ipairs({
            "this",
            "root",
            "DEPS",
            "MARKERS",
            "env_name",
            "valid",
            "found",
            "failures",
          }) do
            if
              ("\n" .. section):find("\nlocal%s+" .. name .. "[%s=,]")
              or ("\n" .. section):find("\nlocal%s+function%s+" .. name .. "%f[^%w_]")
            then
              clash = name
            end
          end
          if clash then
            risk(
              ("%s defines a local `%s` that the new TESTS/minimal_init.lua uses itself: rename it in the carried block"):format(
                legacy.rel,
                clash
              )
            )
          end
          if not loadstring(after) or after:lower():find("plenary", 1, true) then
            after, carried = base, 0
            risk(
              ("what %s sets up could not be carried over safely (the result would not compile or still names the old runner): copy it into TESTS/minimal_init.lua by hand, the removed file is in the diff"):format(
                legacy.rel
              )
            )
          end
        end
      end
      after = formatted(after, "TESTS/minimal_init.lua")
      plan.ops[#plan.ops + 1] = make_op(nil, after, "TESTS/minimal_init.lua", {
        kind = "minit",
        reason = retire
            and ("runtimepath for isolated child runs (`minit` of .testing.lua), plus %d block(s) carried over from %s"):format(
              carried,
              legacy and legacy.rel or ""
            )
          or "runtimepath for isolated child runs (`minit` of .testing.lua); fails with all four searched places when a dependency is missing",
      })
      retired_init = retire
    end
  elseif not report.plenary.keep_ci and #report.minimal_init.plenary_lines > 0 then
    local before = report.texts["TESTS/minimal_init.lua"] or ""
    local after, kept = edit_minit(before, report)
    if after then
      plan.ops[#plan.ops + 1] = make_op(before, after, "TESTS/minimal_init.lua", {
        kind = "minit",
        reason = "the plenary statements are removed, everything else of the file is kept",
      })
    end
    for _, k in ipairs(kept) do
      note("TESTS/minimal_init.lua keeps: " .. k)
    end
  end
  if legacy then
    if retired_init then
      local dropped, carried = {}, 0
      for _, b in ipairs(legacy.blocks) do
        if b.kind == "carry" then
          carried = carried + 1
        else
          dropped[#dropped + 1] = b.reason
        end
      end
      plan.ops[#plan.ops + 1] = make_op(report.texts[legacy.rel], nil, legacy.rel, {
        kind = "minit",
        reason = ("the old runner's init script: its runtimepath and dependency lookup are in TESTS/minimal_init.lua now, %d block(s) of its own state were carried over, %d replaced (%s)"):format(
          carried,
          #dropped,
          #dropped > 0 and table.concat(dropped, "; ") or "none"
        ),
      })
    elseif retire then
      note(
        ("%s and TESTS/minimal_init.lua both exist: %s stays; merge by hand what it sets up besides the old runner (swapfile/shada, clipboard, options, environment) into TESTS/minimal_init.lua and delete it"):format(
          legacy.rel,
          legacy.rel
        )
      )
    else
      note(
        ("%s does not mention the old runner and no workflow or script starts it: it stays as it is"):format(
          legacy.rel
        )
      )
    end
  end
  do
    local comments = 0
    for _, pl in ipairs(report.minimal_init.plenary_lines) do
      if pl.kind == "comment" then
        comments = comments + 1
      end
    end
    if comments > 0 and not report.plenary.keep_ci then
      note(
        ("TESTS/minimal_init.lua keeps %d comment line(s) that mention plenary: reword them by hand"):format(
          comments
        )
      )
    end
  end

  -- ---------------------------------------------------------------- CI
  local added = {}
  local wrapped = false
  local unmappable = report.runner.unmappable or {}
  local ctx = {
    keep_cmd = function(cmd)
      for _, s in ipairs(unmappable) do
        if cmd:find(s, 1, true) then
          return true
        end
      end
      return false
    end,
    read_script = function(rel)
      return text.read(report.root .. "/" .. rel)
    end,
    drop_plenary = not report.plenary.keep_ci,
    fleet_deps = fleet_deps,
    is_self = report.is_self == true,
    owner = owner,
    dep_step = function(name, prefix)
      return scaffold.dep_step(name, owner, prefix)
    end,
    artifact_step = function(suffix)
      local t, err = scaffold.render_template("ci_artifact_step.yml.tpl", { SUFFIX = suffix })
      return t and (t:gsub("\n+$", "")) or nil, err
    end,
  }
  local any_runner = false
  local rels = {}
  for _, wf in ipairs(report.ci.workflows) do
    rels[#rels + 1] = wf.rel
  end
  table.sort(rels)
  local plenary_removed = 0
  for _, rel in ipairs(rels) do
    local src = report.texts[rel] or ""
    local edit = ci.edit(src, ctx)
    local runner_edit = edit.text ~= nil
    if retired_init then
      -- what the workflow still says about the init script that is deleted points to the new one
      local base = edit.text or src
      local moved = base:gsub("scripts/minimal_init%.lua", "TESTS/minimal_init.lua")
      if moved ~= base then
        edit.text = moved
        edit.changes[#edit.changes + 1] = "scripts/minimal_init.lua -> TESTS/minimal_init.lua"
      end
    end
    wrapped = wrapped or edit.wrapped
    for _, d in ipairs(edit.added_deps) do
      added[d] = true
    end
    for _, n in ipairs(edit.notes) do
      note(("%s: %s"):format(rel, n))
    end
    if edit.text then
      any_runner = any_runner or runner_edit
      local op = make_op(src, edit.text, rel, {
        kind = "ci",
        reason = table.concat(edit.changes, "; "),
        changes = edit.changes,
      })
      plan.ops[#plan.ops + 1] = op
    end
    if not runner_edit then
      for _, wf in ipairs(report.ci.workflows) do
        if wf.rel == rel then
          for _, job in ipairs(wf.jobs) do
            for _, c in ipairs(job.commands) do
              if c:match("^testsh:") then
                any_runner = true
              end
            end
          end
        end
      end
    end
    -- plenary mentions that stay in the workflow (comments, a kept checkout)
    local after = edit.text or src
    for _, l in ipairs((text.lines(after))) do
      if l:lower():find("plenary", 1, true) then
        plenary_removed = plenary_removed + 1
      end
    end
  end
  if plenary_removed > 0 and not report.plenary.keep_ci then
    note(
      ("%d line(s) of the workflows still mention plenary (comments): reword them by hand"):format(
        plenary_removed
      )
    )
  end
  if next(added) ~= nil then
    local names = vim.tbl_keys(added)
    table.sort(names)
    risk(
      "the CI did not check out "
        .. table.concat(names, ", ")
        .. " yet: the migration adds the steps from `ci-verified`, confirm that branch exists in each"
    )
  end
  if not any_runner and not wrapped and #report.ci.workflows > 0 then
    risk(
      'no CI step that starts the specs was recognised: wire `bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"` into the workflow by hand'
    )
  end
  if #report.ci.workflows == 0 then
    note("the repository has no CI workflow: `testing init` writes a 3-OS job")
  end

  -- ---------------------------------------------------------------- remaining facts
  if report.makefile and report.makefile.plenary then
    note("Makefile still starts plenary: change the target to `bash scripts/test.sh`")
  end
  if report.harness.run_lua then
    note("TESTS/run.lua (the old runner) stays: delete it once both runners give the same verdict")
  end
  if report.harness.sentinel then
    note(
      ("scripts/test.sh passes --sentinel %s: the green-run sentinel the old runner printed"):format(
        text.show(report.harness.sentinel, 60)
      )
    )
  end
  if #report.deps.optional > 0 then
    local names = {}
    for _, d in ipairs(report.deps.optional) do
      names[#names + 1] = d.name
    end
    note(
      "optional dependencies (only used behind pcall, not in `deps`): " .. table.concat(names, ", ")
    )
  end

  if
    retired_init and (report.texts["TESTS/run.lua"] or ""):find("scripts/minimal_init.lua", 1, true)
  then
    note(
      "TESTS/run.lua (the old runner, kept) names scripts/minimal_init.lua, which is deleted: point it to TESTS/minimal_init.lua"
    )
  end

  -- ---------------------------------------------------------------- prose that still talks about the old runner
  local cleanup = report.cleanup
  if cleanup then
    for _, f in ipairs(cleanup.files) do
      local parts = {}
      for _, l in ipairs(f.lines) do
        parts[#parts + 1] = ("%d: %s"):format(l.lnum, text.show(vim.trim(l.text), 90))
      end
      note(
        ("cleanup hint, %s (reword what is about running the tests; line: text): %s"):format(
          text.show(f.rel, 100),
          table.concat(parts, " | ")
        )
      )
    end
    if cleanup.specs.total > 0 then
      local parts = {}
      for _, l in ipairs(cleanup.specs.samples) do
        parts[#parts + 1] = ("%s:%d"):format(text.show(l.rel, 100), l.lnum)
      end
      note(
        ("%d line(s) in spec files mention plenary (first: %s): the migration never changes specs, this is only reported"):format(
          cleanup.specs.total,
          table.concat(parts, ", ")
        )
      )
    end
  end

  plan.empty = #plan.ops == 0
  plan.analysis = M.summarize(report, plan)
  return plan
end

---Compact facts of the report that the rendered plan shows (the plan stands alone, without the report).
---@param report Testing.Migrate.Report
---@param plan Testing.Migrate.Plan
---@return Testing.Migrate.Analysis
function M.summarize(report, plan)
  local plenary_lines = 0
  for _, op in ipairs(plan.ops) do
    for _, l in ipairs(op.removed) do
      if l:lower():find("plenary", 1, true) then
        plenary_lines = plenary_lines + 1
      end
    end
  end
  local deps, optional = {}, {}
  for _, d in ipairs(report.deps.list) do
    deps[#deps + 1] = d.name .. (d.kind == "external" and " (external, not in fleet)" or "")
  end
  for _, d in ipairs(report.deps.optional) do
    optional[#optional + 1] = d.name
  end
  local workflows = {}
  for _, wf in ipairs(report.ci.workflows) do
    local jobs = {}
    for _, j in ipairs(wf.jobs) do
      jobs[#jobs + 1] = ("%s%s%s"):format(
        j.id,
        j.timeout and (" timeout " .. j.timeout .. "m") or " no timeout",
        j.matrix_os and ", os matrix" or ""
      )
    end
    workflows[#workflows + 1] = ("%s: %s"):format(
      wf.rel,
      #jobs > 0 and table.concat(jobs, "; ") or (wf.parse_error or "no jobs")
    )
  end
  return {
    specs_total = report.specs.total,
    by_dialect = report.specs.by_dialect,
    own_harness = report.harness.file ~= nil,
    run_lua = report.harness.run_lua,
    sentinel = report.harness.sentinel,
    plenary_lines = plenary_lines,
    deps = deps,
    optional_deps = optional,
    ci = workflows,
    policy = report.policy,
  }
end

return M
