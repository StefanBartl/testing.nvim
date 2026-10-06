-- TESTS/testing/surface_coverage_spec.lua -- surface x hits -> coverage (pure): the statuses hit / missing /
-- untracked / ignored / listed, the ratio, the other spellings of a key, the thresholds (0 = report only),
-- the baseline and its diff, hits from a Result-IR and from a tracker sink, per-file numbers, and the
-- aggregate written into a Result-IR that still validates.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function near(actual, expected, msg)
    return ok(
      type(actual) == "number" and math.abs(actual - expected) < 1e-9,
      ("%s: expected %s, got %s"):format(msg, tostring(expected), tostring(actual))
    )
  end

  local coverage = require("testing.surface.coverage")

  ---@param id string
  ---@param kind string
  ---@param extra? table
  local function entry(id, kind, extra)
    return vim.tbl_extend(
      "force",
      { id = id, kind = kind, name = id:gsub("^%a+:", "") },
      extra or {}
    )
  end
  local surface = {
    version = 1,
    plugin = "fx",
    root = "/p",
    notes = {},
    counts = {},
    entries = {
      entry("binding:<leader>a", "binding", { detail = { lhs = "<leader>a", modes = { "n" } } }),
      entry(
        "binding:<leader>b@nx",
        "binding",
        { detail = { lhs = "<leader>b", modes = { "n", "x" } } }
      ),
      entry("binding:<leader>c", "binding", { detail = { lhs = "<leader>c", modes = { "n" } } }),
      entry("command:Open", "command"),
      entry("command:Fx status", "command"),
      entry("autocmd:g:BufEnter", "autocmd"),
      entry("api:fx.open", "api"),
      entry("config:a.b", "config"),
      entry("health:fx", "health"),
    },
  }
  local function hits_of(list, wrapped)
    local h = coverage.new_hits()
    for _, id in ipairs(list) do
      h.hit[id] = true
      h.counts[id] = 2
    end
    if wrapped then
      h.wrapped = {}
      for _, id in ipairs(wrapped) do
        h.wrapped[id] = true
      end
    end
    return h
  end
  local function status_of(cov, id)
    for _, e in ipairs(cov.entries) do
      if e.id == id then
        return e.status
      end
    end
  end

  -- ------------------------------------------------------------------ statuses and ratio
  local cov =
    coverage.compute(surface, hits_of({ "binding:<leader>a", "command:Open", "api:fx.open" }))
  eq(status_of(cov, "binding:<leader>a"), "hit", "an exercised binding")
  eq(status_of(cov, "binding:<leader>c"), "missing", "a binding nobody triggered")
  eq(status_of(cov, "command:Fx status"), "missing", "a route nobody ran")
  eq(status_of(cov, "api:fx.open"), "hit", "an api entry that was called (not in the ratio)")
  eq(status_of(cov, "config:a.b"), "listed", "config keys cannot be observed")
  eq(status_of(cov, "health:fx"), "listed", "neither can health")
  eq(cov.total, 6, "the ratio counts binding + command + autocmd entries (api is not in it)")
  eq(cov.hit, 2, "two of them were hit")
  near(cov.ratio, 2 / 6, "ratio")
  eq(
    cov.missing,
    { "binding:<leader>b@nx", "binding:<leader>c", "command:Fx status", "autocmd:g:BufEnter" },
    "missing ids in surface order"
  )
  eq(cov.by_kind.binding.total, 3, "per kind: total")
  near(cov.by_kind.binding.ratio, 1 / 3, "per kind: ratio")
  eq(cov.by_kind.api, nil, "api is not a coverage kind by default")
  eq(cov.entries[1].count, 2, "the hit count is carried")

  local cov_api = coverage.compute(surface, hits_of({ "api:fx.open" }), { kinds = { "api" } })
  eq({ cov_api.total, cov_api.hit }, { 1, 1 }, "kinds can be asked for")

  -- ------------------------------------------------------------------ untracked / ignored
  local tracked = coverage.compute(
    surface,
    hits_of({ "binding:<leader>a" }, { "binding:<leader>a", "binding:<leader>c", "command:Open" })
  )
  eq(
    status_of(tracked, "command:Fx status"),
    "untracked",
    "a handler no run wrapped is untracked, never missing"
  )
  eq(status_of(tracked, "binding:<leader>c"), "missing", "wrapped and never run is missing")
  eq(
    tracked.untracked,
    { "binding:<leader>b@nx", "command:Fx status", "autocmd:g:BufEnter" },
    "untracked ids"
  )
  eq(tracked.total, 3, "untracked entries are out of the ratio")
  eq(tracked.by_kind.command.untracked, 1, "and counted per kind")

  local ignored = coverage.compute(surface, hits_of({}), { ignore = { "^command:" } })
  eq(status_of(ignored, "command:Open"), "ignored", "an ignored id")
  eq(ignored.total, 4, "is out of the ratio")

  -- ------------------------------------------------------------------ other spellings of a key
  local spelled = coverage.compute(surface, hits_of({ "binding:<leader>b@n", "binding:<LEADER>c" }))
  eq(
    status_of(spelled, "binding:<leader>b@nx"),
    "hit",
    "a hit on one mode of a multi-mode entry counts"
  )
  eq(status_of(spelled, "binding:<leader>c"), "hit", "another spelling of the same key counts")
  eq(spelled.extra, {}, "and is no stranger")
  local stray = coverage.compute(surface, hits_of({ "binding:zz", "command:Gone" }))
  eq(stray.extra, { "binding:zz", "command:Gone" }, "a hit that is in no entry is reported")

  -- ------------------------------------------------------------------ an IR of a run that was not tracked
  local plain_ir =
    coverage.from_ir({ cases = { { id = "a::b", file = "a_spec.lua", status = "pass" } } })
  eq(plain_ir.not_tracked, true, "an IR without cases[].surface is an untracked run")
  local untracked_cov = coverage.compute(surface, plain_ir)
  eq(untracked_cov.total, 0, "nothing was measured")
  eq(untracked_cov.missing, {}, "so no entry is missing")
  eq(
    status_of(untracked_cov, "command:Open"),
    "untracked",
    "everything that could be tracked is untracked"
  )
  local tracked_ir = coverage.from_ir({
    cases = { { id = "a::b", file = "a_spec.lua", surface = { hit = { "command:Open" } } } },
  })
  eq(tracked_ir.not_tracked, nil, "a tracked IR is not")
  local both = coverage.merge(coverage.merge(coverage.new_hits(), plain_ir), tracked_ir)
  eq(both.not_tracked, false, "one tracked source among untracked ones is evidence")

  -- ------------------------------------------------------------------ nothing to cover, nothing measured
  local empty = coverage.compute({ plugin = "e", entries = {}, counts = {} }, hits_of({}))
  eq(empty.ratio, nil, "no entries: no ratio")
  local no_entries = coverage.check(empty, { overall = 1, kinds = { binding = 1 } })
  eq(#no_entries, 1, "a threshold on a surface nobody could read does not pass")
  eq(no_entries[1].scope, "overall", "overall")
  ok(no_entries[1].reason:find("no entry", 1, true) ~= nil, "and says why")
  eq(
    coverage.check(empty, { overall = 0, kinds = { binding = 1 } }),
    {},
    "a kind the plugin does not have passes: there is nothing to cover"
  )
  -- every entry untracked: the tracking was installed too late; no ratio is not a pass
  local late =
    coverage.compute(surface, { hit = {}, counts = {}, wrapped = {}, exact = false, notes = {} })
  eq(late.ratio, nil, "nothing was measured")
  local unmeasured = coverage.check(late, { overall = 0.9, kinds = { command = 1.0 } })
  eq(#unmeasured, 2, "the overall and the kind threshold both fail")
  for _, f in ipairs(unmeasured) do
    ok(f.reason:find("untracked", 1, true) ~= nil, "named: " .. f.reason)
    eq(f.ratio, nil, "without a ratio")
  end

  -- ------------------------------------------------------------------ thresholds
  eq(
    coverage.thresholds(nil, nil, nil),
    { overall = 0, kinds = {}, problems = {} },
    "no gate by default"
  )
  eq(
    coverage.thresholds({ bindings = 1.0, commands = 0 }, { threshold = 0.5 }, nil),
    { overall = 0.5, kinds = { binding = 1.0, command = 0 }, problems = {} },
    "config: coverage.bindings / coverage.commands and surface.threshold"
  )
  eq(
    coverage.thresholds(
      { bindings = 1.0 },
      { threshold = 0.5 },
      { overall = 0.9, kinds = { binding = 0.2 } }
    ),
    { overall = 0.9, kinds = { binding = 0.2 }, problems = {} },
    "the command line wins"
  )
  local bad = coverage.thresholds({ bindings = 0 / 0, commands = 7 }, { threshold = -1 }, nil)
  eq(bad.overall, 0, "a negative threshold is ignored")
  eq(bad.kinds, {}, "so are NaN and a threshold above 1: NaN would pass every comparison")
  eq(#bad.problems, 3, "each one is named")
  eq(coverage.check(cov, { overall = 0, kinds = {} }), {}, "0 only reports")
  eq(coverage.check(cov, { overall = 0.3, kinds = {} }), {}, "at the threshold is fine")
  local fails = coverage.check(cov, { overall = 0.5, kinds = { binding = 0.2, command = 0.9 } })
  eq(#fails, 2, "overall and command fail, binding does not")
  eq({ fails[1].scope, fails[2].scope }, { "overall", "command" }, "which ones")
  near(fails[1].ratio, 2 / 6, "the ratio is in the failure")
  eq(fails[2].threshold, 0.9, "and the threshold")

  -- ------------------------------------------------------------------ baseline and diff
  local base = coverage.baseline(cov)
  eq(base.version, 1, "baseline version")
  eq(base.entries["binding:<leader>a"], "hit", "baseline: hit")
  eq(base.entries["binding:<leader>c"], "missing", "baseline: missing")
  eq(base.entries["config:a.b"], nil, "baseline: only entries that count")
  local text = vim.json.encode(base)
  local parsed = assert(coverage.parse_baseline(text))
  eq(coverage.diff(parsed, cov).regressions, {}, "the same run has no regression")
  eq(
    { coverage.parse_baseline("{}") },
    { nil, "the baseline is not a surface baseline (no `entries`)" },
    "garbage is refused"
  )
  eq(
    select(2, coverage.parse_baseline('{"version":2,"entries":{}}')) ~= nil,
    true,
    "another version is refused"
  )

  local later_surface = vim.deepcopy(surface)
  table.remove(later_surface.entries, 4) -- command:Open is gone
  later_surface.entries[#later_surface.entries + 1] = entry("command:Brand new", "command")
  later_surface.entries[#later_surface.entries + 1] = entry("command:New and tested", "command")
  local later = coverage.compute(
    later_surface,
    hits_of({ "command:New and tested", "binding:<leader>c", "command:Fx status" })
  )
  local d = coverage.diff(parsed, later)
  eq(d.regressions, { "api:fx.open", "binding:<leader>a" }, "was hit, is not now")
  eq(d.removed, { "command:Open" }, "was hit, the entry is gone")
  eq(d.new_missing, { "command:Brand new" }, "new and not exercised")
  eq(d.new_hit, { "command:New and tested" }, "new and exercised")
  eq(d.fixed, { "binding:<leader>c", "command:Fx status" }, "was missing, is hit now")
  near(d.ratio_before, 2 / 6, "ratio before")

  -- ------------------------------------------------------------------ hits from a Result-IR
  local result = require("testing.core.result")
  local ir = result.new({})
  local function add_case(name, file, surface_hit)
    local c = result.new_case({ file = file, name = name })
    c.assertions[1] = { ok = true, kind = "ok", msg = "m" }
    c.surface = surface_hit and { hit = surface_hit } or nil
    result.add_case(ir, c)
  end
  add_case("one", "a_spec.lua", { "binding:<leader>a", "command:Open" })
  add_case("two", "a_spec.lua", { "binding:<leader>a" })
  add_case("three", "b_spec.lua", { "autocmd:g:BufEnter" })
  add_case("untracked", "c_spec.lua", nil)
  result.finalize(ir)
  local from_ir = coverage.from_ir(ir)
  local runs_hits = coverage.new_hits()
  runs_hits.exact = true
  runs_hits.wrapped = { ["command:Open"] = true }
  eq(
    from_ir.hit,
    { ["binding:<leader>a"] = true, ["command:Open"] = true, ["autocmd:g:BufEnter"] = true },
    "IR: the ids"
  )
  eq(from_ir.counts["binding:<leader>a"], 2, "IR: executions are counted per case")
  eq(#from_ir.cases, 3, "IR: a case without surface is not a tracked case")
  eq(
    coverage.from_ir({ cases = {} }).notes[1] ~= nil,
    true,
    "IR without surface: says the run was not tracked"
  )
  eq(coverage.from_ir("garbage").hit, {}, "IR: garbage is no hit")

  local cov_ir = coverage.compute(surface, from_ir)
  eq(cov_ir.hit, 3, "coverage from the IR")
  local files = coverage.by_file(cov_ir, from_ir)
  eq(files["a_spec.lua"].hit, 2, "per file: a_spec.lua exercised two entries")
  near(files["a_spec.lua"].ratio, 2 / 6, "per file: ratio of the whole surface")
  eq(files["b_spec.lua"].hit, 1, "per file: b_spec.lua")
  eq(files["c_spec.lua"], nil, "per file: untracked files are not listed")
  ok(
    vim.tbl_contains(files["b_spec.lua"].missing, "command:Open"),
    "per file: what the file did not exercise"
  )

  coverage.annotate_ir(ir, cov_ir, files)
  eq(ir.surface.total, 6, "the aggregate is in the IR")
  eq(ir.surface.hit, 3, "its hits")
  eq(ir.surface.kinds.binding.total, 3, "per kind")
  coverage.annotate_ir(ir, cov_ir, files, runs_hits)
  eq(ir.surface.exact, true, "the aggregate says whether the run was exact")
  eq(ir.surface.wrapped, { "command:Open" }, "and what was wrapped")
  local back = coverage.from_ir(ir)
  eq(back.exact, true, "from_ir reads them back")
  eq(back.wrapped, { ["command:Open"] = true }, "from_ir: wrapped")
  local valid, problems = result.validate(ir)
  ok(valid, "the IR still validates with surface data: " .. table.concat(problems, "; "))

  -- ------------------------------------------------------------------ hits from a sink
  local sink = table.concat({
    vim.json.encode({
      k = "case",
      id = "a::x",
      file = "a_spec.lua",
      hit = { "command:Open" },
      counts = { ["command:Open"] = 3 },
    }),
    vim.json.encode({
      k = "case",
      id = "a::y",
      file = "a_spec.lua",
      hit = { "command:Open" },
      counts = { ["command:Open"] = 1 },
    }),
    vim.json.encode({
      k = "run",
      file = "s.lua",
      hit = { "binding:<leader>c" },
      counts = { ["binding:<leader>c"] = 5 },
      wrapped = { "binding:<leader>c", "command:Open" },
    }),
    "this is not json",
    vim.json.encode({
      k = "run",
      hit = { "command:Open" },
      counts = { ["command:Open"] = 9 },
      wrapped = { "command:Gone" },
    }),
  }, "\n")
  local from_sink = coverage.from_sink_text(sink)
  eq(
    from_sink.counts["command:Open"],
    4,
    "sink: counts come from the case lines when there are some"
  )
  eq(from_sink.counts["binding:<leader>c"], 5, "sink: a run line counts when no case line does")
  eq(from_sink.hit["binding:<leader>c"], true, "sink: run lines are hits")
  eq(
    from_sink.wrapped,
    { ["binding:<leader>c"] = true, ["command:Open"] = true, ["command:Gone"] = true },
    "sink: wrapped is the union"
  )
  eq(#from_sink.cases, 4, "sink: two cases and two runs (a run with hits or a file)")
  eq(#from_sink.notes, 1, "sink: a line that is no JSON is counted")
  local missing_sink, err = coverage.from_sink(vim.fn.tempname() .. "-nope")
  eq(missing_sink, nil, "an unreadable sink is an error")
  ok(err and err:find("cannot read", 1, true), "with a reason")

  -- ------------------------------------------------------------------ merge
  local merged = coverage.merge(coverage.new_hits(), from_sink)
  coverage.merge(merged, from_ir)
  eq(merged.hit["autocmd:g:BufEnter"], true, "merge: ids of both")
  eq(merged.counts["command:Open"], 5, "merge: counts are added")
  -- ------------------------------------------------------------------ action aliases
  -- the name of a registered action is the stable identity; a spec may bind other keys
  local aliased = {
    plugin = "fx",
    entries = {
      entry("binding:<leader>s", "binding", {
        aliases = { "action:Fx.save" },
        detail = { lhs = "<leader>s", modes = { "n" } },
      }),
      entry("binding:<leader>q", "binding", {
        aliases = { "action:Fx.quit" },
        detail = { lhs = "<leader>q", modes = { "n" } },
      }),
    },
    counts = {},
  }
  local by_alias = coverage.compute(aliased, hits_of({ "binding:<leader>zzz", "action:Fx.save" }))
  eq(
    status_of(by_alias, "binding:<leader>s"),
    "hit",
    "a hit under the action name counts (the spec bound other keys)"
  )
  eq(status_of(by_alias, "binding:<leader>q"), "missing", "the other action is still missing")
  eq(by_alias.extra, { "binding:<leader>zzz" }, "the alias is no stranger, the foreign key is")

  -- ------------------------------------------------------------------ untrackable entries
  local string_rhs = {
    plugin = "fx",
    entries = {
      entry("binding:<leader>c", "binding", {
        detail = { lhs = "<leader>c", modes = { "n" }, untrackable = true },
      }),
      entry("command:Plain", "command"),
    },
    counts = {},
  }
  local ut = coverage.compute(string_rhs, hits_of({}, { "command:Plain" }))
  eq(
    status_of(ut, "binding:<leader>c"),
    "untracked",
    "a string rhs can never be observed: untracked, whatever the runs say"
  )
  eq(status_of(ut, "command:Plain"), "missing", "a wrapped handler nobody ran is missing")
  eq(ut.total, 1, "only the observable one is in the ratio")
  local ut_exact = coverage.compute(string_rhs, hits_of({}, {}))
  eq(status_of(ut_exact, "binding:<leader>c"), "untracked", "also when no run wrapped anything")

  -- ------------------------------------------------------------------ exact: never created is missing
  local runs_clean = coverage.from_sink_text(table.concat({
    vim.json.encode({
      k = "run",
      hit = {},
      wrapped = { "command:Open" },
      existing = { commands = 0, autocmds = 0 },
    }),
    vim.json.encode({ k = "run", hit = {}, wrapped = {}, existing = {} }),
  }, "\n"))
  eq(runs_clean.exact, true, "sink: every run says nothing existed before its tracker")
  local exact_cov = coverage.compute(surface, runs_clean)
  eq(
    status_of(exact_cov, "command:Fx status"),
    "missing",
    "exact: a handler no run created is missing, not untracked"
  )
  local runs_dirty = coverage.from_sink_text(table.concat({
    vim.json.encode({
      k = "run",
      hit = {},
      wrapped = { "command:Open" },
      existing = { commands = 2, autocmds = 0 },
    }),
    vim.json.encode({ k = "run", hit = {}, wrapped = {}, existing = {} }),
  }, "\n"))
  eq(
    runs_dirty.exact,
    false,
    "sink: one run with handlers that existed before the tracker spoils it"
  )
  local dirty_cov = coverage.compute(surface, runs_dirty)
  eq(
    status_of(dirty_cov, "command:Fx status"),
    "untracked",
    "not exact: maybe it was one of the unwrappable ones"
  )
  eq(coverage.from_sink_text("").exact, nil, "no run lines: exactness is unknown")
  eq(
    coverage.from_ir({ cases = {}, surface = { exact = true } }).exact,
    true,
    "IR: the run says so"
  )
  local merged_exact = coverage.merge(coverage.merge(coverage.new_hits(), runs_clean), runs_dirty)
  eq(merged_exact.exact, false, "merge: exact needs every source")

  -- ------------------------------------------------------------------ input files are bounded
  local big = vim.fn.tempname()
  local bf = assert(io.open(big, "wb"))
  bf:write("{}")
  bf:close()
  local saved = coverage.MAX_BYTES
  coverage.MAX_BYTES = 1
  local bigtext, berr = coverage.read_bounded(big)
  coverage.MAX_BYTES = saved
  eq(bigtext, nil, "a file above the bound is refused")
  ok(berr and berr:find("larger than", 1, true), "with a reason")
  eq(coverage.read_bounded(big), "{}", "and read below it")
  vim.fn.delete(big)
end
