-- TESTS/testing/report_verdict_spec.lua -- testing.report.verdict: the three-valued verdict (green, green-partial,
-- red), its counts line, the red lines (last green run, what changed since), and how term, github and junit show it.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack))
    )
  end

  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local verdict = require("testing.report.verdict")
  local result = require("testing.core.result")

  local function facts(over)
    return vim.tbl_extend("force", {
      exit_code = 0,
      files_total = 10,
      files_selected = 10,
      files_cached = 4,
      files_unrun = 0,
      cases_total = 20,
      cases_skipped = 0,
    }, over or {})
  end

  -- green: everything looked at, nothing skipped, exit 0 ------------------------------------------------------
  local g = verdict.build(facts())
  eq(g.kind, "green", "a complete run without a skip is green")
  eq(
    g.files,
    { total = 10, selected = 10, cached = 4, ran = 6, skipped = 0, unrun = 0 },
    "n cached, m ran, k skipped"
  )
  eq(g.reasons, nil, "green has no reasons")
  eq(g.exit_code, 0, "the exit code is the run's")
  eq(
    verdict.line(g),
    "verdict: green (4 from cache, 6 ran, 0 skipped on purpose; 10 spec file(s))",
    "the line of a green run"
  )
  eq(verdict.red_lines(g), {}, "green has no red lines")

  -- green-partial: exit 0, but not everything was looked at -----------------------------------------------------
  local p = verdict.build(facts({ files_selected = 7, files_cached = 2, selection = "--changed" }))
  eq(p.kind, "green-partial", "a selection is partial")
  eq(p.files.skipped, 3, "k = what was not selected")
  eq(p.files.ran, 5, "m = selected - cached")
  has(p.reasons[1], "3 spec file(s) not selected (--changed)", "the reason names k and the cause")
  has(verdict.line(p), "no sentinel", "a partial line says there is no sentinel")
  has(verdict.line(p), "3 skipped on purpose", "and counts the files left out")
  eq(
    verdict.build(facts({ case_selection = true })).kind,
    "green-partial",
    "a case selection is partial"
  )
  local s = verdict.build(facts({ cases_skipped = 2 }))
  eq(s.kind, "green-partial", "a skipped case is never green")
  has(s.reasons[1], "2 case(s) skipped", "the skip is counted")
  local u = verdict.build(facts({ files_unrun = 3 }))
  eq(u.kind, "green-partial", "a file a stop left unrun is partial, never green")
  eq(u.files.ran, 3, "an unrun file is not counted as run")
  local both =
    verdict.build(facts({ files_selected = 8, cases_skipped = 1, case_selection = true }))
  eq(#both.reasons, 3, "every reason is named")

  -- red: the exit code decides, whatever else is true ---------------------------------------------------------
  local r = verdict.build(facts({ exit_code = 1, files_selected = 5, cases_skipped = 3 }))
  eq(r.kind, "red", "a non-zero exit is red")
  eq(r.reasons, nil, "red carries no partial reasons")
  eq(r.exit_code, 1, "the exit code stays what it was")
  eq(
    verdict.red_lines(r),
    { "last green run: none recorded for this project" },
    "no green run recorded"
  )
  local r2 = verdict.build(facts({
    exit_code = 1,
    last_green = { ts = 1790000000, sha = "3f2a1b9" },
    changed_since = verdict.changed_since_of({ "lua/a.lua", "TESTS/a_spec.lua" }),
  }))
  eq(verdict.red_lines(r2), {
    "last green run: 2026-09-21 14:13:20Z at 3f2a1b9; 2 file(s) changed since: lua/a.lua, TESTS/a_spec.lua",
  }, "the last green run and the files changed since")
  local many = {}
  for i = 1, 30 do
    many[i] = ("f%02d.lua"):format(i)
  end
  local cs = verdict.changed_since_of(many)
  eq(cs.count, 30, "the count of changed files stays complete")
  eq(#cs.files, verdict.MAX_CHANGED, "the names are bounded")
  local r3 = verdict.build(facts({ exit_code = 1, last_green = { ts = 0 }, changed_since = cs }))
  has(verdict.red_lines(r3)[1], "30 file(s) changed since", "the line says how many")
  has(verdict.red_lines(r3)[1], "... 18 more", "and how many names were left out")
  has(
    verdict.red_lines(verdict.build(facts({ exit_code = 1, last_green = { ts = 0 } })))[1],
    "what changed since is unknown",
    "without git facts the line says so"
  )
  has(
    verdict.red_lines(verdict.build(facts({
      exit_code = 1,
      last_green = { ts = 0 },
      changed_since = { count = 0, files = {} },
    })))[1],
    "nothing changed since",
    "a red run with no change since the green run says so"
  )
  local hostile = verdict.build(facts({
    exit_code = 1,
    last_green = { ts = 0 },
    changed_since = { count = 1, files = { "a\27[2Jb\n::error::x.lua" } },
  }))
  local hl = verdict.red_lines(hostile)[1]
  ok(not hl:find("[%c]"), "a file name from git cannot carry a control character into the line")

  -- the verdict of an IR ---------------------------------------------------------------------------------------
  local ir = F.mixed()
  eq(verdict.of(ir).kind, "red", "an IR without a stored verdict gets one from its cases (red)")
  ir.run.verdict = p
  eq(verdict.of(ir).kind, "green-partial", "a stored verdict wins")
  ir.run.verdict = { kind = "weird" }
  eq(verdict.of(ir).kind, "red", "a verdict that is no kind is not trusted")
  local only_green = result.new({
    id = "x",
    root = "<REPO>",
    project_key = "k",
    nvim = "0.12.0",
    os = "linux",
    duration_ms = 1,
  })
  F.add(only_green, { file = "TESTS/a_spec.lua", name = "a" })
  eq(verdict.of(only_green).kind, "green", "green cases give green")
  F.add(only_green, { file = "TESTS/b_spec.lua", name = "b", status = "skip", reason = "later" })
  eq(verdict.of(only_green).kind, "green-partial", "a skip gives partial: never green")

  -- the reporters show it -----------------------------------------------------------------------------------------
  local term = require("testing.report.term")
  local github = require("testing.report.github")
  local junit = require("testing.report.junit")
  local base = F.mixed()
  local plain = term.render(base)
  for _, l in ipairs(plain) do
    ok(
      not l:find("verdict:", 1, true),
      "an IR without a verdict prints no verdict line (old IRs unchanged)"
    )
  end
  base.run.verdict =
    verdict.build(facts({ exit_code = 1, last_green = { ts = 0, sha = "abc1234" } }))
  local shown = term.render(base)
  has(shown[#shown - 1], "verdict: red (", "term: the verdict line follows the summary")
  has(shown[#shown], "last green run:", "term: and the last green run for a red verdict")
  base.run.verdict = p
  shown = term.render(base)
  has(shown[#shown], "verdict: green-partial (", "term: a partial run says green-partial")
  has(shown[#shown], "no sentinel", "term: and that there is no sentinel")

  local md = table.concat(github.summary_markdown(base), "\n")
  has(md, "verdict: green-partial", "github summary: the verdict")
  only_green.run.verdict = p
  has(
    table.concat(github.summary_markdown(only_green), "\n"),
    "passed (partial",
    "github summary: the heading never says plain 'passed' for a partial run"
  )
  local ann = table.concat(github.render(base), "\n")
  has(ann, "::notice title=testing::verdict: green-partial", "github: a partial run gets a notice")
  local green_ir = F.mixed()
  green_ir.run.verdict = g
  ok(
    not table.concat(github.render(green_ir), "\n"):find("::notice", 1, true),
    "github: a green verdict adds no annotation"
  )
  has(
    table.concat(junit.render(base), "\n"),
    '<property name="verdict" value="green-partial"/>',
    "junit: a property"
  )
  ok(
    not table.concat(junit.render(F.mixed()), "\n"):find('name="verdict"', 1, true),
    "junit: without a verdict no property (old output unchanged)"
  )

  -- exit 1 without a red case (a cache audit found a stale pass): no reporter may look green -----------------------------------
  local audit_ir = result.new({
    id = "y",
    root = "<REPO>",
    project_key = "k",
    nvim = "0.12.0",
    os = "linux",
    duration_ms = 1,
  })
  F.add(audit_ir, { file = "TESTS/a_spec.lua", name = "a" })
  audit_ir.run.verdict = verdict.build(facts({ exit_code = 1, last_green = { ts = 0 } }))
  audit_ir.run.cache = {
    findings = {
      {
        code = "cache.stale_pass",
        file = "TESTS/a_spec.lua",
        message = "TESTS/a_spec.lua: the stored result differs",
      },
    },
  }
  has(
    table.concat(github.summary_markdown(audit_ir), "\n"),
    "## testing.nvim: FAILED",
    "github summary: a red verdict is never headed 'passed'"
  )
  has(
    table.concat(github.render(audit_ir), "\n"),
    "::error title=testing::verdict: red",
    "github: and gets an error annotation"
  )
  local audit_xml = table.concat(junit.render(audit_ir), "\n")
  has(audit_xml, 'failures="1"', "junit: the red verdict is one failed case of its own")
  has(
    audit_xml,
    "cache.stale_pass TESTS/a_spec.lua: the stored result differs",
    "junit: with the finding"
  )
  ok(
    not table.concat(junit.render(F.mixed()), "\n"):find('name="run verdict"', 1, true),
    "junit: a run with red cases adds nothing"
  )
  local colored = term.render(audit_ir, { color = true })
  local sum
  for _, l in ipairs(colored) do
    if l:find("summary:", 1, true) then
      sum = l
    end
  end
  has(sum, "\27[31m", "term: the summary line of a red verdict is red")
  ok(not sum:find("\27[32m", 1, true), "term: and not green")

  -- a `testing stamp` run that exits 1 without a red case: asked for a stamp, not given one ---------------------------
  local clean_v = verdict.build(facts())
  local refused = verdict.stamp_refused(clean_v)
  eq(refused.kind, "red", "a refused stamp is red: the process exits 1")
  eq(refused.exit_code, 1, "with exit code 1, the one the process has")
  eq(refused.stamp_refused, true, "and says why")
  eq(refused.reasons, { "stamp not written" }, "the reason")
  eq(clean_v.kind, "green", "the verdict it was made from is not touched")
  eq(clean_v.exit_code, 0, "neither its exit code")
  eq(clean_v.reasons, nil, "nor its reasons")
  eq(refused.files, clean_v.files, "the counts stay")
  local skipped_v = verdict.build(facts({ cases_skipped = 2 }))
  local refused_skip = verdict.stamp_refused(skipped_v)
  eq(
    refused_skip.reasons,
    { "2 case(s) skipped: a skip is never green", "stamp not written" },
    "the reasons of a partial run stay, the refusal is added"
  )
  eq(
    skipped_v.reasons,
    { "2 case(s) skipped: a skip is never green" },
    "and the partial verdict keeps its own"
  )
  local refused_lines = verdict.red_lines(refused)
  eq(#refused_lines, 1, "one red line")
  has(refused_lines[1], "no case failed; stamp not written", "it says what is: the cases are fine")
  ok(
    not refused_lines[1]:find("last green run", 1, true),
    "a last green run would suggest the run itself was red"
  )
  local refused_ir = F.mixed()
  refused_ir.run.verdict = refused
  local refused_term = term.render(refused_ir)
  has(refused_term[#refused_term - 1], "verdict: red (", "term: the verdict line says red")
  has(refused_term[#refused_term], "no case failed; stamp not written", "term: and why")
end
