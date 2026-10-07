---@module 'testing.explain'
---@brief `testing explain <spec>...`: why a spec file is selected, taken from the cache, run or left out.
---@description
--- Asks, per spec file, the same questions a run asks and says the answer:
---
---   * SELECTION: selected, or left out (`--changed`, `--since`, `--affected`), with the reason of
---     `testing.affected.select` (the same call the run makes);
---   * CACHE: `hit` (a valid entry exists under the key), `miss` (none; what differs from the most recent entry
---     of the file: a file with its old and new hash, the Neovim version, an environment variable by name,
---     the configuration), `uncacheable` (why there is no key: the file and line the scanner found it at,
---     and the way out), `off` (a case selection makes the cache unusable);
---   * the lines the key is the hash of (`--parts`).
---
--- `testing explain --all` does this for every spec file and sums it up: the hit rate and the reasons of the
--- files that have no key, most frequent first. `--json` prints the same as one JSON document.
---
--- It changes nothing: no entry is written, read counters and ages are untouched, the history is not
--- touched. The key and the explanation come from ONE call of `testing.cache.key` (`testing.cache.explain`).
--- Everything that came from the project (file names, reasons) passes the same cleaning as the lines of a run.
---
--- The options of a run (`--config`, `--isolated`, `--env-allow`, `--changed`, ...) are accepted and mean what they
--- mean there: the key depends on them. `<root>` defaults to the current directory.

local M = {}

---Flags of `explain` that are not options of a run (they are removed before the run parser sees the arguments).
---@type table<string, string>
M.OWN = { ["--json"] = "json", ["--all"] = "all", ["--parts"] = "parts" }

---@class Testing.Explain.Own
---@field json boolean
---@field all boolean
---@field parts boolean

---Take the flags of `explain` out of the arguments.
---@param argv string[]
---@return string[] rest
---@return Testing.Explain.Own own
function M.split_argv(argv)
  local own = { json = false, all = false, parts = false }
  local rest = {}
  for _, a in ipairs(argv) do
    local name = M.OWN[a]
    if name then
      own[name] = true
    else
      rest[#rest + 1] = a
    end
  end
  return rest, own
end

---The discovered files a `<spec>` argument names: a path (a file, or a directory below which every file counts),
---or a part of a file name.
---@param files Testing.Discover.File[]
---@param root string
---@param arg string
---@return Testing.Discover.File[]
local function resolve(files, root, arg)
  local p = arg:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
  local r = root:gsub("/+$", "")
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    p = p:sub(#r + 2)
  end
  local exact = {}
  for _, f in ipairs(files) do
    if f.rel == p or f.rel:sub(1, #p + 1) == p .. "/" then
      exact[#exact + 1] = f
    end
  end
  if #exact > 0 then
    return exact
  end
  local part = {}
  for _, f in ipairs(files) do
    if f.rel:find(p, 1, true) then
      part[#part + 1] = f
    end
  end
  return part
end

---@param ts integer
---@return string
local function when(ts)
  return os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
end

---@param n integer
---@param word string
---@return string
local function plural(n, word)
  return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

---The terminal text of one record.
---@param rec Testing.Explain.Record
---@param sel { selected: boolean, text: string }
---@param own Testing.Explain.Own
---@return string[]
function M.render(rec, sel, own)
  local lines = { rec.file, "  selection: " .. sel.text }
  local function add(s)
    lines[#lines + 1] = s
  end
  local key = rec.key and rec.key:sub(1, 12) or nil
  if rec.status == "hit" then
    add(("  cache:     hit (key %s, stored by run %s)"):format(key, tostring(rec.stored_run)))
  elseif rec.status == "off" then
    add("  cache:     off (" .. tostring(rec.reason) .. ")")
  elseif rec.status == "miss" then
    add(("  cache:     miss (key %s: %s)"):format(key, tostring(rec.reason)))
    if rec.compare == "ok" and rec.previous then
      add(
        ("    compared with the most recent entry of this file (run %s, %s, key %s):"):format(
          rec.previous.run,
          when(rec.previous.ts),
          rec.previous.key:sub(1, 12)
        )
      )
      if #(rec.changes or {}) == 0 then
        add("      no key line differs (the entry was pruned, or the key version changed)")
      end
      for _, c in ipairs(rec.changes or {}) do
        local what
        if c.change == "changed" then
          what = ("%s -> %s"):format(tostring(c.old), tostring(c.new))
        elseif c.change == "added" then
          what = "new" .. (c.new and c.new ~= "" and (" " .. c.new) or "")
        else
          what = "gone"
        end
        local name = c.name == c.kind and "" or (" " .. c.name)
        add(("      %-8s %s%s: %s"):format(c.change, c.kind, name, what))
      end
    elseif rec.compare == "none" then
      add("    " .. tostring(rec.compare_why))
    end
  else
    add("  cache:     uncacheable: " .. tostring(rec.reason))
    if rec.location then
      local at = rec.location.file .. (rec.location.line and (":" .. rec.location.line) or "")
      add("    at: " .. at .. (rec.location.source and ("  " .. rec.location.source) or ""))
    end
    if rec.way_out then
      add("    way out: " .. rec.way_out)
    end
  end
  for _, v in ipairs(rec.vouched or {}) do
    -- the author vouches for what the key cannot see: a reviewer must be able to see it (`@cache-env *` most of all)
    add(("  vouched: %s (%s)"):format(v.directive, v.file))
  end
  if rec.flipped then
    add(
      ("    note: this key gave different results (%s); `-- @cache-allow nondeterministic` caches it anyway"):format(
        table.concat(rec.flipped, ", ")
      )
    )
  end
  if rec.parts then
    if own.parts then
      add(("  key lines (%d):"):format(#rec.parts))
      for _, l in ipairs(rec.parts) do
        add("    " .. l)
      end
    else
      add(("  key lines: %d (--parts lists them)"):format(#rec.parts))
    end
  end
  return lines
end

---The summary of `--all` as terminal lines.
---@param records Testing.Explain.Record[]
---@param summary Testing.Explain.Summary
---@param selection { selected: integer, left_out: integer, label: string }
---@return string[]
function M.render_summary(records, summary, selection)
  local lines = {
    ("testing explain --all: %s"):format(plural(summary.specs, "spec file")),
    ("  selection: %d selected, %d left out%s"):format(
      selection.selected,
      selection.left_out,
      selection.label ~= "" and (" (" .. selection.label .. ")") or ""
    ),
    ("  cache:     %d hit, %d miss, %d uncacheable%s (hit rate %.1f%%)"):format(
      summary.hit,
      summary.miss,
      summary.uncacheable,
      summary.off > 0 and (", %d off"):format(summary.off) or "",
      100 * summary.hit_rate
    ),
  }
  if #summary.reasons > 0 then
    lines[#lines + 1] = "  why the files have no key (most frequent first):"
    for _, r in ipairs(summary.reasons) do
      lines[#lines + 1] = ("    %3d  %s  (e.g. %s)"):format(
        r.count,
        r.reason,
        table.concat(r.files, ", ")
      )
    end
  end
  lines[#lines + 1] = "  per file:"
  for _, r in ipairs(records) do
    local why = r.reason and (": " .. r.reason) or ""
    lines[#lines + 1] = ("    %-11s %s%s"):format(r.status, r.file, why)
  end
  return lines
end

---Run `testing explain`.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param own Testing.Explain.Own
---@return integer exit_code
function M.main(plan, sv, own)
  local out, err = sv.out, sv.err
  local project = require("testing.run.project")
  local cached = require("testing.run.cached")
  local explain = require("testing.cache.explain")
  local args, root = plan.args, plan.root
  local function say(line)
    out(project.safe_line(line))
  end
  -- the seed of a shuffled run is part of its key, and a run without `--seed` draws a new one each time: no key
  -- computed here would be the key of any run
  if args.shuffle and args.seed == nil then
    err(
      "testing: explain: --shuffle needs --seed <n>: the seed is part of a shuffled run's cache key, and a run without --seed draws a new one each time"
    )
    return project.EXIT_USAGE
  end

  local run_opts = require("testing.run.options").of(plan)
  local discover = sv.discover or require("testing.discover")
  local disc = discover.discover(root, {
    roots = plan.project.roots,
    dialect = plan.project.dialect,
    spec_pattern = plan.project.spec_pattern,
  })
  local ordered = discover.order(disc)

  -- which spec files are asked about
  local targets = {}
  if own.all then
    targets = ordered
  else
    if #args.paths == 0 then
      err("testing: explain: name a spec file (or part of its name), or use --all")
      return project.EXIT_USAGE
    end
    local seen = {}
    for _, a in ipairs(args.paths) do
      local found = resolve(ordered, root, a)
      if #found == 0 then
        err(("testing: explain: no spec file matches '%s'"):format(project.safe_line(a)))
        return project.EXIT_USAGE
      end
      for _, f in ipairs(found) do
        if not seen[f.rel] then
          seen[f.rel] = true
          targets[#targets + 1] = f
        end
      end
    end
  end

  -- selection: the same call as the run makes
  local sel, aerr = cached.select_affected(
    plan,
    ordered,
    ordered,
    vim.tbl_extend("keep", sv.affected or {}, { cache_dir = sv.cache_dir })
  )
  if aerr then
    err("testing: " .. aerr)
    return project.EXIT_USAGE
  end
  local chosen = {}
  if sel then
    for _, f in ipairs(sel.files) do
      chosen[f.rel] = true
    end
    for _, note in ipairs(sel.notes) do
      err(project.safe_line("testing: note: " .. note))
    end
  end
  local function selection_of(rel)
    if not sel then
      return {
        selected = true,
        text = "selected: every spec file runs (no --changed, --since or --affected)",
      }
    end
    local r = sel.result
    if chosen[rel] then
      return {
        selected = true,
        text = ("selected by %s: %s"):format(sel.label, tostring((r.reason or {})[rel] or "?")),
      }
    end
    return {
      selected = false,
      text = ("left out by %s: no change reaches it (%s, source %s)"):format(
        sel.label,
        plural(#(r.changed or {}), "changed file"),
        tostring(r.source or "?")
      ),
    }
  end

  -- the cache: a case selection turns it off (as in a run)
  local off_why
  if args.list then
    off_why = "--list runs nothing"
  elseif #args.filter > 0 or #args.tags > 0 or #args.exclude_tags > 0 or args.lf then
    off_why =
      "a case selection (--filter, --tags, --exclude-tags, --lf) applies: a file would run only part of its cases"
  end
  local with_finding = {}
  for _, f in ipairs(disc.findings or {}) do
    if f.path then
      with_finding[f.path] = true
    end
  end
  local cache = sv.cache or require("testing.cache")
  local inputs =
    cached.key_inputs(plan, run_opts, { mode = "use", cache_dir = sv.cache_dir, seed = args.seed })
  local keylog = require("testing.cache.keylog").load(root, { state_dir = sv.state_dir })
  inputs.ctx.flipped = function(file, key)
    return keylog:flipped(file, key)
  end
  local deps = { cache = cache, root = root, cache_dir = sv.cache_dir }

  local records, sels = {}, {}
  local n_selected, n_left = 0, 0
  for _, f in ipairs(targets) do
    local rec
    if off_why then
      rec = { file = f.rel, status = "off", reason = off_why }
    elseif with_finding[f.rel] then
      rec = {
        file = f.rel,
        status = "uncacheable",
        reason = "the discovery has a finding for this file",
        kind = "discovery",
        way_out = explain.way_out({ kind = "discovery" }),
      }
    else
      rec = explain.explain(inputs.info_of(f), inputs.ctx, deps)
    end
    local s = selection_of(f.rel)
    if s.selected then
      n_selected = n_selected + 1
    else
      n_left = n_left + 1
    end
    records[#records + 1] = rec
    sels[#sels + 1] = s
  end
  local summary = explain.summarize(records)
  local label = sel and sel.label or ""

  if own.json then
    local specs = {}
    for i, rec in ipairs(records) do
      local item = vim.deepcopy(rec)
      item.selection = sels[i]
      if own.all and not own.parts then
        -- the key lines of every file would be the bulk of the document: a single spec always has them
        item.parts = nil
      end
      specs[#specs + 1] = item
    end
    local doc = {
      schema = "testing-explain/1",
      root = root,
      specs = specs,
      summary = own.all and summary or nil,
    }
    local text, jerr = require("lib.nvim.json").encode(doc, { indent = 2 })
    if not text then
      err("testing: explain: cannot encode the result: " .. tostring(jerr))
      return project.EXIT_INFRA
    end
    out(text)
    return project.EXIT_OK
  end

  if own.all then
    for _, line in
      ipairs(M.render_summary(records, summary, {
        selected = n_selected,
        left_out = n_left,
        label = label,
      }))
    do
      say(line)
    end
    return project.EXIT_OK
  end
  for i, rec in ipairs(records) do
    if i > 1 then
      out("")
    end
    for _, line in ipairs(M.render(rec, sels[i], own)) do
      say(line)
    end
  end
  return project.EXIT_OK
end

return M
