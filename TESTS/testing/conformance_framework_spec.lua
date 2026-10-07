-- TESTS/testing/conformance_framework_spec.lua -- the framework around the checks: settings and waivers,
-- skipping, report determinism, the four renderings (terminal, Markdown, JSON, Result-IR through the
-- JUnit and GitHub reporters), `main` with its flags and exit codes, the read-only file access, the rules.nvim
-- bridge. No child editor: the runtime sessions are replaced by a fake `probe`.

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")

  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 400))
    )
  end

  local function probe(name)
    if name == "require" then
      return { results = {} }
    end
    return nil, "no child editor in this spec"
  end

  ---A repository with one K15 error and one K15 warning.
  local function flawed()
    local r = S.new_repo()
    S.remove(r, "LICENSE") -- NEW-06, critical: an error
    S.remove(r, "stylua.toml") -- NEW-45, recommended: a warning
    return r
  end

  S.run(function()
    -- ===================================================================
    -- 1. the settings of `.testing.lua`
    local settings = require("testing.conformance.settings")
    local ids = require("testing.conformance.catalog").ids()
    local s, problems = settings.parse(nil, ids)
    eq(problems, {}, "no table, no problem")
    eq(s.gate, false, "report first: the gate is off by default")
    eq(s.load_budget_ms, 40, "the default budget")
    eq(s.keymaps_off, { keymaps = false }, "the default off switch")

    s, problems = settings.parse({
      gate = true,
      skip = { "K10", "K99" },
      keymaps_off = { mappings = false },
      timeout_ms = 5000,
      waivers = {
        { check = "K4", file = "lua/a.lua", reason = "the which-key group is set elsewhere" },
        { check = "K4", reason = "no" },
        { check = "K42", reason = "an unknown check id is not a waiver" },
        { reason = "no check at all" },
        "not a table",
        { check = "K5", rule = "", reason = "an empty rule is invalid" },
      },
    }, ids, 25)
    eq(s.gate, true, "gate = true")
    eq(s.skip, { "K10" }, "a known id is kept")
    eq(s.keymaps_off, { mappings = false }, "keymaps_off")
    eq(s.timeout_ms, 5000, "timeout_ms")
    eq(s.load_budget_ms, 25, "the validated budget of the project loader")
    eq(#s.waivers, 1, "only the waiver with a reason and a known check survives")
    eq(s.waivers[1].file, "lua/a.lua", "its file")
    eq(#problems, 6, "every rejected key is named")
    local text = table.concat(problems, "\n")
    has(text, 'unknown check id "K99"', "an unknown id in skip")
    has(text, "needs a reason of at least", "a waiver without a reason")
    has(text, "conformance.waivers[3]", "the position of the invalid waiver")
    has(text, "check must be one of the check ids", "a waiver for an unknown check")

    s, problems =
      settings.parse({ gate = "yes", timeout_ms = 5, rules_bridge = "x", skip = "K1" }, ids)
    eq(s.gate, false, "an invalid gate keeps the default")
    eq(s.timeout_ms, 20000, "an invalid timeout keeps the default")
    eq(#problems, 4, "four problems")

    -- loading: the raw file is executed once; the project loader's "unknown key" warnings for the suite's own keys are dropped
    local repo = S.new_repo()
    S.write(
      repo .. "/.testing.lua",
      [[return {
  plugin = "goodp",
  conformance = {
    load_budget_ms = 12,
    gate = true,
    skip = { "K10" },
    waivers = { { check = "K4", reason = "documented in the README" } },
    typo_key = 1,
  },
}]]
    )
    local loaded = settings.load(repo, ids)
    eq(loaded.settings.gate, true, "loaded: gate")
    eq(loaded.settings.load_budget_ms, 12, "loaded: the budget comes through the project config")
    eq(loaded.settings.skip, { "K10" }, "loaded: skip")
    eq(#loaded.settings.waivers, 1, "loaded: waiver")
    local joined = table.concat(loaded.problems, "\n")
    ok(
      not joined:find("conformance.gate", 1, true),
      "the suite's own keys raise no unknown-key warning"
    )
    has(joined, "conformance.typo_key", "a real typo still does")
    for _, bad in ipairs({
      { "return {", "cannot load" },
      { 'error("no")', "raised" },
      { "return 5", "must return a table" },
    }) do
      S.write(repo .. "/.testing.lua", bad[1])
      has(
        settings.load(repo, ids).error,
        bad[2],
        "an unusable .testing.lua is an error: " .. bad[1]
      )
    end
    S.remove(repo, ".testing.lua")
    loaded = settings.load(repo, ids)
    ok(
      loaded.error == nil and loaded.config.plugin == "goodp",
      "without a file the plugin is derived from the directory"
    )

    -- ===================================================================
    -- 2. waivers
    local f = flawed()
    local report = conformance.run(f, { only = { "K15" }, probe = probe })
    eq(S.check(report, "K15").status, "fail", "flawed: K15 fails")
    eq(report.summary.findings.error, 1, "one error finding")
    eq(report.summary.findings.warn, 1, "one warning")

    S.write(
      f .. "/.testing.lua",
      [[return {
  plugin = "goodp",
  conformance = {
    waivers = {
      { check = "K15", rule = "NEW-06", reason = "the license lives in the parent monorepo" },
      { check = "K15", text = "no stylua.toml", reason = "formatted by the shared config" },
      { check = "K15", rule = "NEW-99", reason = "this waiver matches nothing and is stale" },
      { check = "K15", rule = "NEW-45", reason = "" },
    },
  },
}]]
    )
    report = conformance.run(f, { only = { "K15" }, probe = probe })
    local k15 = S.check(report, "K15")
    eq(k15.status, "pass", "waived findings do not count")
    eq(#k15.findings, 2, "but they stay in the report")
    for _, finding in ipairs(k15.findings) do
      ok(
        finding.waived == true and #finding.waiver_reason > 8,
        "a waived finding carries the reason"
      )
    end
    eq(report.summary.waived, 2, "the summary counts them")
    eq(report.summary.findings.error, 0, "and the error is gone from the open findings")
    local problem_text = table.concat(report.problems, "\n")
    has(problem_text, "matched no finding", "a waiver that matches nothing is reported as stale")
    has(problem_text, "rule NEW-99", "and named")
    has(problem_text, "needs a reason", "a waiver with an empty reason is refused")

    -- a waiver cannot hide another check's finding
    S.write(
      f .. "/.testing.lua",
      'return { plugin = "goodp", conformance = { waivers = { { check = "K7", reason = "the wrong check" } } } }'
    )
    report = conformance.run(f, { only = { "K15" }, probe = probe })
    eq(S.check(report, "K15").status, "fail", "a waiver of K7 does not waive K15")

    -- a directory waiver ends with a slash
    S.write(
      f .. "/.testing.lua",
      'return { plugin = "goodp", conformance = { waivers = { { check = "K15", file = "lua/", reason = "everything below lua is accepted" } } } }'
    )
    S.write(f .. "/lua/goodp/c.lua", "--- CDX: x\nreturn {}\n")
    report = conformance.run(f, { only = { "K15" }, probe = probe })
    local waived_cdx = false
    for _, finding in ipairs(S.check(report, "K15").findings) do
      waived_cdx = waived_cdx or (finding.rule == "CMT-15" and finding.waived == true)
    end
    ok(waived_cdx, "a file ending with a slash waives everything below it")

    -- a waiver limited to a level never hides a finding of another level
    S.write(
      f .. "/.testing.lua",
      'return { plugin = "goodp", conformance = { waivers = { { check = "K15", level = "warn", reason = "only the warnings are accepted" } } } }'
    )
    report = conformance.run(f, { only = { "K15" }, probe = probe })
    local k15w = S.check(report, "K15")
    eq(k15w.status, "fail", "the error is still open when only warnings are waived")
    for _, finding in ipairs(k15w.findings) do
      eq(
        finding.waived == true,
        finding.level == "warn",
        "only the warning is waived: " .. finding.message
      )
    end
    ok(
      not table.concat(report.problems, " | "):find("hides", 1, true),
      "a waiver with a level is scoped: it is not named as too wide"
    )

    -- an unscoped waiver that hides an error is named
    S.write(
      f .. "/.testing.lua",
      'return { plugin = "goodp", conformance = { waivers = { { check = "K15", reason = "everything of K15 is accepted" } } } }'
    )
    report = conformance.run(f, { only = { "K15" }, probe = probe })
    has(
      table.concat(report.problems, " | "),
      "hides 1 error finding(s)",
      "an unscoped waiver says it hides an error"
    )

    -- an expired waiver no longer applies and says so; a future one does; a bad date is refused
    local function with_expiry(day)
      S.write(
        f .. "/.testing.lua",
        ('return { plugin = "goodp", conformance = { waivers = { { check = "K15", rule = "NEW-06", expires = %q, reason = "the license lives in the parent" } } } }'):format(
          day
        )
      )
      return conformance.run(f, { only = { "K15" }, probe = probe })
    end
    report = with_expiry("2020-01-31")
    eq(S.check(report, "K15").status, "fail", "an expired waiver hides nothing")
    has(table.concat(report.problems, " | "), "expired on 2020-01-31", "and says that it expired")
    report = with_expiry("2999-12-31")
    local open_errors = 0
    for _, finding in ipairs(S.check(report, "K15").findings) do
      if finding.rule == "NEW-06" and not finding.waived then
        open_errors = open_errors + 1
      end
    end
    eq(open_errors, 0, "a waiver that has not expired applies")
    report = with_expiry("2027-02-30")
    has(
      table.concat(report.problems, " | "),
      "expires must be",
      "a day that does not exist is refused"
    )
    eq(settings.valid_date("2028-02-29"), true, "a leap day is a day")
    eq(settings.valid_date("2027-02-29"), false, "and not in a year that has none")
    eq(settings.valid_date("27-1-1"), false, "the format is YYYY-MM-DD")

    -- ===================================================================
    -- 3. skipping
    report = conformance.run(
      S.new_repo(),
      { only = { "K4", "K7", "K15" }, skip = { "K7" }, probe = probe }
    )
    eq(#report.checks, 3, "only selects, skip keeps the entry")
    eq(S.check(report, "K7").status, "n/a", "a skipped check is n/a")
    has(S.check(report, "K7").reason, "skipped (--skip)", "and says it was skipped")
    local cfg_skip = S.new_repo()
    S.write(
      cfg_skip .. "/.testing.lua",
      'return { plugin = "goodp", conformance = { skip = { "K15" } } }'
    )
    report = conformance.run(cfg_skip, { only = { "K15" }, probe = probe })
    has(
      S.check(report, "K15").reason,
      "conformance.skip",
      "a check skipped by the configuration says so"
    )

    -- ===================================================================
    -- 4. the checks as a framework: a raising check, na, blocked, error, report-only
    local runner = require("testing.conformance.runner")
    local ctx = runner.context(S.new_repo(), settings.load(S.new_repo(), ids), { probe = probe })
    local function result_of(check)
      return runner.run_check(
        vim.tbl_extend(
          "force",
          { id = "KX", title = "t", rules = {}, kind = "static", level = "error" },
          check
        ),
        ctx,
        false
      )
    end
    local r = result_of({
      run = function()
        error("kaboom")
      end,
    })
    eq(r.status, "error", "a check that raises is `error`, never a crash")
    has(r.reason, "kaboom", "with its message")
    eq(
      result_of({
        run = function()
          return { na = "nothing here" }
        end,
      }).status,
      "n/a",
      "na"
    )
    r = result_of({
      run = function()
        return { blocked = "K1 failed" }
      end,
    })
    ok(
      r.status == "n/a" and r.reason == "blocked: K1 failed",
      "blocked is n/a and names the blocker"
    )
    eq(
      result_of({
        run = function()
          return { error = "child died" }
        end,
      }).status,
      "error",
      "error"
    )
    r = result_of({
      run = function()
        return "not a table"
      end,
    })
    eq(r.status, "error", "a check that returns no outcome is an error")
    r = result_of({
      report_only = true,
      run = function()
        return { findings = { { check = "KX", rule = "R", level = "error", message = "m" } } }
      end,
    })
    ok(r.status == "warn" and r.findings[1].level == "warn", "a report-only check can never fail")
    r = result_of({
      run = function()
        return {
          findings = {
            { check = "KX", rule = "B", level = "warn", message = "b", file = "z.lua", line = 2 },
            { check = "KX", rule = "A", level = "warn", message = "a", file = "a.lua", line = 9 },
            { check = "KX", rule = "A", level = "info", message = "a", file = "a.lua", line = 1 },
          },
          volatile = { "17.5 ms" },
          notes = { "stable" },
        }
      end,
    })
    eq(
      { r.findings[1].line, r.findings[2].file, r.findings[3].file },
      { 1, "a.lua", "z.lua" },
      "findings are sorted"
    )
    eq(r.notes, { "stable" }, "a volatile note is dropped without timings")
    ok(r.duration_ms == nil, "and so is the duration")
    r = runner.run_check({
      id = "KX",
      title = "t",
      rules = {},
      kind = "static",
      level = "error",
      run = function()
        return { volatile = { "17.5 ms" } }
      end,
    }, ctx, true)
    ok(r.duration_ms ~= nil and r.notes[1] == "17.5 ms", "with timings both are kept")

    -- an infrastructure error (the child did not run): verdict `error`, exit 3 in both modes
    report = conformance.run(S.new_repo(), { only = { "K2" }, probe = probe })
    eq(S.check(report, "K2").status, "error", "no child: K2 is an error")
    eq(report.verdict, "error", "the verdict is error")
    eq(conformance.exit_code(report), 3, "report-only exits 3 for an infrastructure error")
    report.mode = "gate"
    eq(conformance.exit_code(report), 3, "so does the gate")

    -- ===================================================================
    -- 5. determinism: the same repository gives the same bytes
    local det = S.new_repo()
    local a = assert(
      conformance.json(conformance.run(det, { probe = probe, only = { "K1", "K7", "K15" } }))
    )
    local b = assert(
      conformance.json(conformance.run(det, { probe = probe, only = { "K1", "K7", "K15" } }))
    )
    eq(a, b, "two runs, identical JSON")
    ok(not a:find(det, 1, true), "the root never appears in the report")
    ok(not a:find(vim.fs.dirname(det), 1, true), "nor does its parent")
    local decoded = vim.json.decode(a)
    eq(decoded.root, "<REPO>", "the root is a placeholder")
    eq(decoded.name, "goodp.nvim", "the directory name is the name")
    eq(decoded.schema_version, 1, "schema version")
    local keys = {}
    for k in pairs(decoded) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    eq(keys, {
      "checks",
      "manual",
      "mode",
      "name",
      "plugin",
      "problems",
      "root",
      "schema_version",
      "summary",
      "tool",
      "verdict",
    }, "the top-level keys")
  end)
end
