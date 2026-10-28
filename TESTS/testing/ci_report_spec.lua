-- TESTS/testing/ci_report_spec.lua -- the reporters of `testing ci` (testing.ci.report): the error format turns
-- output lines into findings (also Windows paths with a drive colon), and the terminal, agent and JUnit reports of a
-- fixed testing-ci/1 document match their golden text.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local report = require("testing.ci.report")
  local presets = require("testing.ci.presets")

  -- ------------------------------------------------------------- error format

  do
    local luacheck = presets.get("luacheck").efm
    local f, n = report.findings(luacheck, {
      "Checking lua/a.lua",
      "lua/a.lua:3:7: (W211) unused variable 'x'",
      [[C:\repo\lua\b.lua:10:1: (W113) accessing undefined variable 'y']],
      "Total: 2 warnings / 0 errors in 2 files",
    })
    eq(n, 2, "luacheck: two findings")
    eq(
      f[1],
      { file = "lua/a.lua", line = 3, col = 7, text = "(W211) unused variable 'x'" },
      "luacheck: the first"
    )
    eq(f[2].file, [[C:\repo\lua\b.lua]], "luacheck: a Windows path keeps its drive colon")
    eq(f[2].line, 10, "luacheck: ... and the line after it")

    local s =
      report.findings(presets.get("stylua").efm, { "Diff in lua/x.lua:", "    1 |-local a=1" })
    eq(s, { { file = "lua/x.lua", text = "" } }, "stylua: one finding per file, no line")

    -- a grouped report line is not a file: %f takes no blanks
    local grouped = report.findings(
      "FAIL %f:%l  %m",
      { "FAIL x40 module 'lib.nvim.foo' not found  (first: TESTS/a_spec.lua:3  a::b; 39 more)" }
    )
    eq(grouped, {}, "a line with blanks before the colon is no finding")

    eq({ report.findings(nil, { "x:1:2: y" }) }, { {}, 0 }, "no error format: no findings")
    local pat = report.compile("100%% %f(%l)")
    eq(pat, "^100%% (%S-)%((%d+)%)$", "compile: %% and magic characters are literal")
    local bad = pcall(report.compile, "%f:%l:%t")
    eq(bad, false, "compile: an unsupported item is an error, not a literal letter")
    for _, name in ipairs(presets.names()) do
      local efm = presets.get(name).efm
      for _, item in ipairs(type(efm) == "table" and efm or (efm and { efm } or {})) do
        ok(pcall(report.compile, item), "the error format of preset " .. name .. " compiles")
      end
    end
    eq(presets.get("suite").efm, nil, "suite: no error format, the findings come from the IR")

    -- the suite's findings from its Result-IR
    local ir_f, ir_n = report.ir_findings({
      cases = {
        { id = "a::ok", file = "TESTS/a_spec.lua", status = "pass", assertions = {} },
        {
          id = "a::bad",
          name = "bad",
          file = "TESTS/a_spec.lua",
          line = 4,
          status = "fail",
          assertions = {
            { ok = true, kind = "eq" },
            {
              ok = false,
              kind = "eq",
              msg = "values differ\nexpected 1",
              file = "TESTS/a_spec.lua",
              line = 9,
            },
          },
        },
        {
          id = "b::boom",
          file = "TESTS/b_spec.lua",
          line = 2,
          status = "error",
          assertions = {},
          error = { message = "attempt to index nil", traceback = "..." },
        },
      },
    })
    eq(ir_n, 2, "ir: the two red cases")
    eq(
      ir_f[1],
      { file = "TESTS/a_spec.lua", line = 9, text = "fail bad: values differ" },
      "ir: at the failed assertion, its first line"
    )
    eq(
      ir_f[2],
      { file = "TESTS/b_spec.lua", line = 2, text = "error b::boom: attempt to index nil" },
      "ir: an error at the case"
    )
    eq({ report.ir_findings(nil) }, { {}, 0 }, "ir: no IR, no findings")

    local many = {}
    for i = 1, report.MAX_FINDINGS + 5 do
      many[i] = ("f.lua:%d:1: m"):format(i)
    end
    local capped, total = report.findings(luacheck, many)
    eq(#capped, report.MAX_FINDINGS, "the list is capped")
    eq(total, report.MAX_FINDINGS + 5, "the total is not")
  end

  -- --------------------------------------------------------- golden reports

  local RED = {
    schema = "testing-ci/1",
    profile = "full",
    partial = false,
    partial_why = vim.NIL,
    head_moved = false,
    exit = 1,
    verdict = "red",
    first_red = "luacheck",
    steps = {
      {
        name = "stylua",
        state = "green",
        ms = 400,
        reason = vim.NIL,
        errors = {},
        findings = {},
        findings_total = 0,
      },
      {
        name = "luacheck",
        state = "red",
        ms = 1250,
        reason = vim.NIL,
        errors = { "Total: 2 warnings" },
        findings = {
          { file = "lua/a.lua", line = 3, col = 7, text = "(W211) unused variable 'x'" },
          { file = "lua/b.lua", line = 1, col = 1, text = '(W113) <y> & "z"' },
        },
        findings_total = 2,
      },
      {
        name = "suite",
        state = "skipped",
        ms = 0,
        reason = "an earlier step failed",
        errors = {},
        findings = {},
        findings_total = 0,
      },
    },
  }

  eq(report.term(RED, "SENTINEL"), {
    "  stylua         green       0.4 s",
    "  luacheck       red         1.2 s  2 finding(s)",
    "  suite          skipped     0.0 s  an earlier step failed",
    "ci: RED luacheck (exit 1)",
  }, "term: red")

  eq(report.agent(RED), {
    "ci RED luacheck (2 findings) exit 1",
    "[luacheck] red",
    "  lua/a.lua:3:7: (W211) unused variable 'x'",
    '  lua/b.lua:1:1: (W113) <y> & "z"',
  }, "agent: the verdict first, then only the findings")

  -- the headline names the step that decided the exit code, not merely the first red one (--keep-going)
  local MIXED = vim.deepcopy(RED)
  MIXED.exit, MIXED.deciding = 3, "suite"
  MIXED.steps[3] = vim.tbl_extend(
    "force",
    MIXED.steps[3],
    { state = "infra", reason = "the suite wrote no result" }
  )
  eq(report.term(MIXED, "SENTINEL")[4], "ci: INFRA suite (exit 3)", "term: the deciding step")
  eq(report.agent(MIXED)[1], "ci INFRA suite (2 findings) exit 3", "agent: the deciding step")

  -- a run that stopped before its first step: its problems in the agent report
  local EARLY =
    { profile = "full", exit = 3, first_red = vim.NIL, problems = { "step b needs x" }, steps = {} }
  eq(
    report.agent(EARLY),
    { "ci INFRA ? (0 findings) exit 3", "  step b needs x" },
    "agent: an early stop"
  )

  local GREEN = vim.deepcopy(RED)
  GREEN.exit, GREEN.verdict, GREEN.first_red = 0, "green", vim.NIL
  GREEN.steps = { RED.steps[1] }
  eq(report.term(GREEN, "SENTINEL"), {
    "  stylua         green       0.4 s",
    "ci: GREEN full 1/1",
    "SENTINEL",
  }, "term: green ends with the sentinel")
  eq(report.agent(GREEN), { "ci GREEN full 1/1" }, "agent: green is one line")

  local PARTIAL = vim.deepcopy(GREEN)
  PARTIAL.partial, PARTIAL.partial_why = true, "--step"
  eq(report.term(PARTIAL, "SENTINEL")[2], "ci: GREEN full 1/1 (partial: --step)", "term: partial")
  eq(#report.term(PARTIAL, "SENTINEL"), 2, "term: partial has no sentinel")
  eq(
    report.agent(PARTIAL),
    { "ci PARTIAL full 1/1 (partial: --step)" },
    "agent: a partial run never reads GREEN"
  )

  local MOVED = vim.deepcopy(GREEN)
  MOVED.head_moved = true
  eq(#report.term(MOVED, "SENTINEL"), 2, "term: HEAD moved, no sentinel")
  eq(
    report.term(MOVED, "SENTINEL")[2],
    "ci: GREEN full 1/1 (HEAD moved during the run)",
    "term: HEAD moved is said"
  )
  eq(
    report.agent(MOVED),
    { "ci PARTIAL full 1/1 (HEAD moved during the run)" },
    "agent: HEAD moved is no proof"
  )

  -- a finding read back from the document has vim.NIL for a missing line (stylua): no crash, file only
  local STYLUA = vim.deepcopy(RED)
  STYLUA.first_red = "stylua"
  STYLUA.steps = {
    {
      name = "stylua",
      state = "red",
      ms = 300,
      reason = vim.NIL,
      errors = {},
      findings = { { file = "lua/x.lua", line = vim.NIL, col = vim.NIL, text = "" } },
      findings_total = 1,
    },
  }
  eq(report.agent(STYLUA), {
    "ci RED stylua (1 finding) exit 1",
    "[stylua] red",
    "  lua/x.lua",
  }, "agent: a finding without a line")
  local xml = report.junit(STYLUA)
  ok(
    xml:find('<testcase name="lua/x.lua" classname="ci.stylua"', 1, true) ~= nil,
    "junit: a finding without a line"
  )

  -- the cap and the reason reach the JUnit report
  local CAPPED = vim.deepcopy(STYLUA)
  CAPPED.steps[1].findings_total = 5
  CAPPED.steps[1].reason = "timed out after 1000 ms"
  local cx = report.junit(CAPPED)
  ok(
    cx:find('<testcase name="4 more finding(s)"', 1, true) ~= nil,
    "junit: the findings over the cap are counted"
  )
  ok(
    cx:find("(stylua: timed out after 1000 ms)", 1, true) ~= nil,
    "junit: the reason is in the body"
  )
  ok(
    cx:find('tests="2" failures="2"', 1, true) ~= nil,
    "junit: the counters include the extra case"
  )
  eq(report.agent(CAPPED)[4], "  ... 4 more", "agent: the findings over the cap are counted")

  local NOFIND = vim.deepcopy(RED)
  NOFIND.steps[2].findings, NOFIND.steps[2].findings_total = {}, 0
  NOFIND.steps[2].reason = "timed out after 1500 ms"
  eq(report.agent(NOFIND), {
    "ci RED luacheck (0 findings) exit 1",
    "[luacheck] red: timed out after 1500 ms",
    "  Total: 2 warnings",
  }, "agent: a red step without findings shows its last lines")

  eq(
    report.junit(RED),
    table.concat({
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<testsuites name="testing ci full" tests="4" failures="2" errors="0" skipped="1">',
      '  <testsuite name="stylua" tests="1" failures="0" errors="0" skipped="0" time="0.400">',
      '    <testcase name="stylua" classname="ci.stylua" time="0.400"/>',
      "  </testsuite>",
      '  <testsuite name="luacheck" tests="2" failures="2" errors="0" skipped="0" time="1.250">',
      '    <testcase name="lua/a.lua:3:7: (W211) unused variable &apos;x&apos;" classname="ci.luacheck" time="1.250">',
      "      <failure message=\"(W211) unused variable &apos;x&apos;\"><![CDATA[lua/a.lua:3:7: (W211) unused variable 'x']]></failure>",
      "    </testcase>",
      '    <testcase name="lua/b.lua:1:1: (W113) &lt;y&gt; &amp; &quot;z&quot;" classname="ci.luacheck" time="0.000">',
      '      <failure message="(W113) &lt;y&gt; &amp; &quot;z&quot;"><![CDATA[lua/b.lua:1:1: (W113) <y> & "z"]]></failure>',
      "    </testcase>",
      "  </testsuite>",
      '  <testsuite name="suite" tests="1" failures="0" errors="0" skipped="1" time="0.000">',
      '    <testcase name="suite" classname="ci.suite" time="0.000">',
      '      <skipped message="an earlier step failed"/>',
      "    </testcase>",
      "  </testsuite>",
      "</testsuites>",
      "",
    }, "\n"),
    "junit: golden"
  )
end
