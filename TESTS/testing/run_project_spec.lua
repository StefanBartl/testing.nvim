-- TESTS/testing/run_project_spec.lua -- one `testing run` end to end, in-process through `cli.main`
-- on temp fixture projects: discovery + dialects + config + selection + order + timeouts + strict +
-- reporters + history + the sentinel rules. Real discovery, real driver, real reporters; only the
-- state directory is redirected into a temp dir.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. needle .. " in " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local cli = require("testing.cli")
  local history = require("testing.history")
  local json = require("lib.nvim.json")
  local exit_before = os.exit

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param path string
  ---@return string
  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
  end

  local state_dir = vim.fs.normalize(vim.fn.tempname())
  local made = {}

  ---@return string
  local function new_root()
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-proj"
    vim.fn.mkdir(root .. "/TESTS", "p")
    made[#made + 1] = root
    return root
  end

  ---@class ProjectSpec.Result
  ---@field code integer
  ---@field out string
  ---@field err string

  ---@param argv string[]
  ---@return ProjectSpec.Result
  local function go(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  ---@param r ProjectSpec.Result
  ---@return string
  local function both(r)
    return "\n--- out\n" .. r.out .. "\n--- err\n" .. r.err
  end

  local PASS_A = 'return function(H)\n  H.eq(1, 1, "%s")\nend\n'
  local CALC = table.concat({
    "describe('calc', function()",
    "  it('adds', function() assert.are.equal(2, 1 + 1) end)",
    "  it('breaks #slow', function() assert.are.equal(1, %d) end)",
    "  describe('inner #net', function()",
    "    it('subtracts', function() assert.are.equal(0, 1 - 1) end)",
    "  end)",
    "end)",
    "",
  }, "\n")

  -- =====================================================================
  -- a green project: the sentinel is the last line, only on a complete green run
  local root = new_root()
  write(root .. "/TESTS/a_spec.lua", PASS_A:format("a"))
  write(root .. "/TESTS/calc_spec.lua", CALC:format(1))
  local r = go({ root })
  eq(r.code, 0, "green project" .. both(r))
  ok(r.out:find("TESTING_OK%s*$") ~= nil, "the sentinel is the last line" .. both(r))
  has(r.out, "ok    TESTS/a_spec.lua", "terminal reporter: the file line")
  has(r.out, "summary: 4 pass", "and the summary")
  ok(os.exit == exit_before, "the exit guard is released")

  -- a failure: red, no sentinel, the failing case and its line are shown
  write(root .. "/TESTS/calc_spec.lua", CALC:format(2))
  r = go({ root })
  eq(r.code, 1, "a failing it is exit 1" .. both(r))
  lacks(r.out, "TESTING_OK", "no sentinel")
  has(r.out, "FAIL  TESTS/calc_spec.lua", "the file is red")
  has(r.out, "breaks #slow", "the failing it is named")

  -- =====================================================================
  -- selection
  r = go({ root, "--filter", "adds" })
  eq(r.code, 0, "--filter adds: the failing case is not selected" .. both(r))
  has(r.out, "partial run", "a filtered run says it is partial")
  lacks(r.out, "TESTING_OK", "and prints no sentinel")
  has(r.out, "summary: 1 pass", "one case ran")

  r = go({ root, "--tags", "slow" })
  eq(r.code, 1, "--tags slow selects the failing case" .. both(r))
  has(r.out, "0 pass, 1 fail (1 case(s))", "only that one")
  r = go({ root, "--exclude-tags", "slow" })
  eq(r.code, 0, "--exclude-tags slow drops it" .. both(r))
  r = go({ root, "--tags", "net", "--exclude-tags", "slow" })
  eq(r.code, 0, "tags and exclusion together" .. both(r))
  has(r.out, "summary: 1 pass", "the #net case only")

  -- header tags of a file (`-- @tags`) apply to its case
  write(root .. "/TESTS/h_spec.lua", "-- @tags slowfile\n" .. PASS_A:format("h"))
  r = go({ root, "--tags", "slowfile" })
  eq(r.code, 0, "a header tag selects the file" .. both(r))
  has(r.out, "summary: 1 pass", "just that file")
  vim.fn.delete(root .. "/TESTS/h_spec.lua")

  r = go({ root, "--file", "calc" })
  eq(r.code, 1, "--file calc" .. both(r))
  has(r.out, "FAIL  TESTS/calc_spec.lua", "only the file that matched")
  lacks(r.out, "a_spec.lua", "the other file is not in the report")
  r = go({ root, "--file", "a_spec" })
  eq(r.code, 0, "--file a_spec" .. both(r))
  has(r.out, "partial run: 1 of 2 spec files", "a partial run says so")
  r = go({ root, "TESTS/a_spec.lua" })
  eq(r.code, 0, "a path argument selects a file" .. both(r))
  r = go({ root, "--file", root:sub(1, 12) })
  eq(r.code, 2, "--file never matches the absolute path: nothing selected" .. both(r))
  r = go({ root, "--filter", "no such case" })
  eq(r.code, 2, "nothing selected is exit 2, never a green run" .. both(r))
  has(r.err, "no case matched", "and says so")

  -- --list prints the planned cases and runs nothing
  local marker = root .. "/marker.txt"
  write(
    root .. "/TESTS/marker_spec.lua",
    ('return function(H)\n  local f = io.open(%q, "w")\n  f:write("ran")\n  f:close()\n  H.eq(1, 1, "m")\nend\n'):format(
      marker
    )
  )
  r = go({ root, "--list" })
  eq(r.code, 0, "--list" .. both(r))
  has(r.out, "TESTS/calc_spec.lua::calc::adds", "busted ids are listed")
  has(r.out, "TESTS/a_spec.lua::a_spec.lua", "and file cases")
  has(r.out, "5 case(s) in 3 of 3 spec file(s) would run", "with the count")
  eq(vim.uv.fs_stat(marker), nil, "no spec ran for the list")
  r = go({ root, "--dry-run", "--tags", "net" })
  has(r.out, "inner #net::subtracts", "--dry-run honors the selection")
  has(r.out, "1 case(s)", "and counts it")
  vim.fn.delete(root .. "/TESTS/marker_spec.lua")

  -- --maxfail / -x
  write(root .. "/TESTS/b_fail_spec.lua", 'return function(H)\n  H.eq(1, 2, "bf")\nend\n')
  write(root .. "/TESTS/c_fail_spec.lua", 'return function(H)\n  H.eq(1, 2, "cf")\nend\n')
  r = go({ root, "-x" })
  eq(r.code, 1, "-x" .. both(r))
  has(r.out, "stopped after 1 failure(s) (--maxfail 1)", "says it stopped")
  has(r.out, "file(s) not run", "and how much was left")
  r = go({ root, "--maxfail", "2" })
  has(r.out, "stopped after 2 failure(s)", "--maxfail 2")
  vim.fn.delete(root .. "/TESTS/b_fail_spec.lua")
  vim.fn.delete(root .. "/TESTS/c_fail_spec.lua")

  -- --durations
  write(root .. "/TESTS/calc_spec.lua", CALC:format(1))
  r = go({ root, "--durations", "2" })
  eq(r.code, 0, "--durations" .. both(r))
  has(r.out, "slowest 2:", "the slowest cases are listed")
  r = go({ root, "--no-timings" })
  lacks(r.out, "timings:", "--no-timings")

  -- =====================================================================
  -- shuffle: deterministic per seed, the seed is printed and stored
  local sroot = new_root()
  for i = 1, 8 do
    write(sroot .. ("/TESTS/s%d_spec.lua"):format(i), PASS_A:format("s" .. i))
  end
  local function order_of(argv)
    local rr = go(argv)
    local ids = {}
    for line in rr.out:gmatch("[^\n]+") do
      local id = line:match("^(TESTS/s%d_spec%.lua)::")
      if id then
        ids[#ids + 1] = id
      end
    end
    return ids, rr
  end
  local plain = order_of({ sroot, "--list" })
  local o5a, r5 = order_of({ sroot, "--list", "--shuffle", "--seed", "5" })
  local o5b = order_of({ sroot, "--list", "--shuffle", "--seed", "5" })
  local o6 = order_of({ sroot, "--list", "--shuffle", "--seed", "6" })
  eq(#plain, 8, "eight files in the plain order")
  eq(o5a, o5b, "the same seed gives the same order")
  ok(not vim.deep_equal(o5a, plain), "a shuffled order differs from the plain one")
  ok(not vim.deep_equal(o5a, o6), "another seed, another order")
  has(r5.out, "shuffle: seed 5 (repeat with --shuffle --seed 5)", "the seed is printed")
  eq(#o5a, 8, "nothing lost")

  local ir_file = sroot .. "/out/ir.json"
  r = go({ sroot, "--shuffle", "--seed", "5", "--json", ir_file })
  eq(r.code, 0, "a shuffled run" .. both(r))
  local ir = assert(json.decode(slurp(ir_file)))
  eq(ir.run.seed, 5, "the seed is stored in the IR")
  local run_order = {}
  for _, c in ipairs(ir.cases) do
    run_order[#run_order + 1] = c.file
  end
  eq(run_order, o5a, "the run followed the listed order")
  r = go({ sroot, "--shuffle", "--json", ir_file })
  local drawn = tonumber(r.out:match("shuffle: seed (%d+)"))
  ok(drawn ~= nil, "an unpinned shuffle prints the seed it drew" .. both(r))
  eq(assert(json.decode(slurp(ir_file))).run.seed, drawn, "and stores that one")
  -- on a failure the seed is part of the report
  write(sroot .. "/TESTS/s9_spec.lua", 'return function(H)\n  H.eq(1, 2, "red")\nend\n')
  r = go({ sroot, "--shuffle", "--seed", "77" })
  eq(r.code, 1, "a failing shuffled run" .. both(r))
  has(r.out, "seed: 77  (reproduce: --shuffle --seed 77)", "the failure report carries the seed")
  vim.fn.delete(sroot .. "/TESTS/s9_spec.lua")

  -- =====================================================================
  -- --lf / --ff and the history file
  local hroot = new_root()
  write(hroot .. "/TESTS/a_spec.lua", PASS_A:format("a"))
  write(hroot .. "/TESTS/b_spec.lua", 'return function(H)\n  H.eq(1, 2, "b")\nend\n')
  write(hroot .. "/TESTS/calc_spec.lua", CALC:format(2))
  r = go({ hroot })
  eq(r.code, 1, "first run: b and calc fail" .. both(r))
  local hist = history.load(hroot, { state_dir = state_dir })
  eq(
    hist.failed,
    { "TESTS/b_spec.lua::b_spec.lua", "TESTS/calc_spec.lua::calc::breaks #slow" },
    "the failures are remembered"
  )
  r = go({ hroot, "--lf", "--json", hroot .. "/out/lf.json" })
  eq(r.code, 1, "--lf reruns the failures: still red" .. both(r))
  local lf_ids = {}
  for _, c in ipairs(assert(json.decode(slurp(hroot .. "/out/lf.json"))).cases) do
    lf_ids[#lf_ids + 1] = c.id
  end
  eq(
    lf_ids,
    { "TESTS/b_spec.lua::b_spec.lua", "TESTS/calc_spec.lua::calc::breaks #slow" },
    "only the failed cases ran (not a_spec, not the other its of calc)"
  )
  lacks(r.out, "TESTING_OK", "a red --lf run has no sentinel")
  -- --ff: the failed files first
  r = go({ hroot, "--ff", "--list" })
  local first = r.out:match("^[^\n]+")
  ok(
    first == "TESTS/b_spec.lua::b_spec.lua" or first:find("calc_spec", 1, true) ~= nil,
    "--ff lists a failed file first: " .. first
  )
  -- fix both, --lf passes and clears the memory of them
  write(hroot .. "/TESTS/b_spec.lua", PASS_A:format("b"))
  write(hroot .. "/TESTS/calc_spec.lua", CALC:format(1))
  r = go({ hroot, "--lf" })
  eq(r.code, 0, "--lf after the fix is green" .. both(r))
  has(r.out, "partial run", "but an --lf run is partial")
  lacks(r.out, "TESTING_OK", "and prints no sentinel")
  eq(
    history.load(hroot, { state_dir = state_dir }).failed,
    {},
    "and nothing is remembered any more"
  )
  r = go({ hroot, "--lf" })
  eq(r.code, 0, "--lf with no remembered failure runs everything" .. both(r))
  has(r.err, "no remembered failure", "and says so")
  has(r.out, "summary: 5 pass", "all cases ran")
  ok(r.out:find("TESTING_OK%s*$") ~= nil, "a green full run keeps the sentinel")

  -- the history file is untrusted: a corrupted one never breaks the run
  local hpath = history.path(hroot, { state_dir = state_dir })
  write(hpath, "{{{ not json\n\0\0\n[]\n")
  r = go({ hroot, "--lf" })
  eq(r.code, 0, "--lf with a corrupted history still runs" .. both(r))
  has(r.err, "unusable line(s) ignored", "and tells that it ignored the file's content")
  eq(#vim.fn.readfile(hpath), 1, "the run that met the garbage rewrote the file clean: one line")
  r = go({ hroot })
  eq(r.code, 0, "and the next run appends to it" .. both(r))
  eq(#vim.fn.readfile(hpath), 2, "two clean lines")
  -- --list never writes history
  vim.fn.delete(hpath)
  go({ hroot, "--list" })
  eq(vim.uv.fs_stat(hpath), nil, "--list leaves no history behind")

  -- =====================================================================
  -- timeouts from flags and from .testing.lua
  local troot = new_root()
  write(
    troot .. "/TESTS/hang_spec.lua",
    "return function(H)\n  H.eq(1, 1, 'x')\n  while true do end\nend\n"
  )
  write(troot .. "/TESTS/after_spec.lua", PASS_A:format("after"))
  local t0 = vim.uv.hrtime()
  local tir = troot .. "/out/t.json"
  r = go({ troot, "--file-timeout", "300", "--json", tir })
  eq(r.code, 1, "a hanging spec: exit 1, the run finished" .. both(r))
  ok((vim.uv.hrtime() - t0) / 1e6 < 30000, "and did not hang")
  local tdec = assert(json.decode(slurp(tir)))
  eq(tdec.summary.timeout, 1, "one timeout in the IR")
  eq(tdec.summary.pass, 1, "the other file ran and passed")
  has(r.out, "timeout", "the report says timeout")
  write(troot .. "/.testing.lua", "return { timeouts = { file_ms = 300 } }\n")
  r = go({ troot, "--json", tir })
  eq(r.code, 1, ".testing.lua timeouts.file_ms is honored" .. both(r))
  eq(assert(json.decode(slurp(tir))).summary.timeout, 1, "a timeout again")
  write(troot .. "/.testing.lua", "return { timeouts = { file_ms = 300 } }\n")
  write(
    troot .. "/TESTS/hang_spec.lua",
    "describe('h', function()\n  it('spins', function() while true do end end)\n  it('fine', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  r = go({ troot, "--case-timeout", "250", "--json", tir })
  eq(r.code, 1, "--case-timeout: red" .. both(r))
  tdec = assert(json.decode(slurp(tir)))
  eq(tdec.summary.timeout, 1, "--case-timeout stops one it")
  eq(tdec.summary.pass, 2, "the other it and the other file passed")

  -- =====================================================================
  -- strict: skips, unknown dialects and findings
  local kroot = new_root()
  write(kroot .. "/TESTS/ok_spec.lua", PASS_A:format("ok"))
  write(kroot .. "/TESTS/mystery_spec.lua", "local x = 1\nreturn x\n")
  r = go({ kroot })
  eq(r.code, 1, "an unknown dialect is red, also without --strict" .. both(r))
  has(r.out, "TESTS/mystery_spec.lua", "the file is in the report")
  has(r.out, "dialect unknown", "with the reason")
  lacks(r.out, "TESTING_OK", "no sentinel")
  r = go({ kroot, "--strict" })
  eq(r.code, 1, "--strict: still red" .. both(r))
  -- the dialect override of the config makes the file run (and fail on its own terms)
  write(kroot .. "/.testing.lua", 'return { dialect = "a" }\n')
  r = go({ kroot })
  eq(r.code, 1, "dialect = a runs the file as dialect A: it does not return function(H)" .. both(r))
  has(r.out, "TESTS/mystery_spec.lua", "naming the spec")
  vim.fn.delete(kroot .. "/.testing.lua")
  vim.fn.delete(kroot .. "/TESTS/mystery_spec.lua")
  r = go({ kroot, "--strict" })
  eq(r.code, 0, "strict and clean is green" .. both(r))

  -- legacy location: a finding (NEW-48) in the report, red only under --strict
  write(kroot .. "/docs/TESTS/old_spec.lua", PASS_A:format("old"))
  r = go({ kroot })
  eq(r.code, 0, "a legacy spec still runs, the run is green" .. both(r))
  has(r.out, "finding [NEW-48 warn]", "the finding is in the report")
  has(r.out, "docs/TESTS", "naming the legacy place")
  has(r.out, "summary: 2 pass", "and its spec ran")
  r = go({ kroot, "--strict" })
  eq(r.code, 1, "--strict: a NEW-48 finding fails the run" .. both(r))
  has(r.out, "FAIL  <findings>", "as a failing case of its own")
  vim.fn.delete(kroot .. "/docs", "rf")

  -- =====================================================================
  -- reporters
  local rroot = new_root()
  write(rroot .. "/TESTS/a_spec.lua", PASS_A:format("a"))
  write(rroot .. "/TESTS/calc_spec.lua", CALC:format(2))
  local junit = rroot .. "/out/junit.xml"
  r = go({ rroot, "--junit", junit })
  eq(r.code, 1, "--junit keeps the verdict" .. both(r))
  local xml = slurp(junit)
  has(xml, "<?xml", "a JUnit file")
  has(xml, "<testsuites", "with the root element")
  local ncases = select(2, xml:gsub("<testcase ", ""))
  eq(ncases, 4, "one testcase per case")
  has(xml, "<failure", "the failure is a <failure>")
  lacks(xml, rroot, "no absolute root in the file artifact")
  eq(vim.fn.glob(rroot .. "/out/*.atomic-tmp*", false, true), {}, "no temp file left")
  has(r.out, "FAIL  TESTS/calc_spec.lua", "the terminal report is still printed")

  -- CI sets GITHUB_STEP_SUMMARY for the real job: the runs below must never append to it
  local real_summary = vim.env.GITHUB_STEP_SUMMARY
  vim.env.GITHUB_STEP_SUMMARY = nil
  r = go({ rroot, "--github" })
  has(r.out, "::error", "--github: annotations on stdout")
  has(r.out, "FAIL  TESTS/calc_spec.lua", "next to the terminal report")
  local summary_file = rroot .. "/out/summary.md"
  vim.env.GITHUB_STEP_SUMMARY = summary_file
  r = go({ rroot, "--github" })
  vim.env.GITHUB_STEP_SUMMARY = nil
  eq(r.code, 1, "--github with a step summary: the verdict is unchanged" .. both(r))
  has(slurp(summary_file), "calc", "the step summary was appended")

  r = go({ rroot, "--reporter", "junit" })
  has(r.out, "<testsuites", "--reporter junit prints the XML")
  lacks(r.out, "FAIL  TESTS", "and no terminal report")
  r = go({ rroot, "--reporter", "json" })
  local printed = r.out:match("(%b{})")
  ok(printed ~= nil, "--reporter json prints the IR" .. both(r))
  local pdec = assert(json.decode(printed))
  eq(pdec.schema_version, 1, "a decodable IR")
  ok(require("testing.core.result").validate(pdec), "that validates")
  r = go({ rroot, "--reporter", "github" })
  vim.env.GITHUB_STEP_SUMMARY = real_summary
  has(r.out, "::error", "--reporter github")

  -- =====================================================================
  -- the project's own runner: order and sentinel; the sentinel rules
  local qroot = new_root()
  write(
    qroot .. "/TESTS/run.lua",
    'local specs = { "b_spec.lua", "a_spec.lua" }\nio.stdout:write("\\nQ_OK\\n")\n'
  )
  write(qroot .. "/TESTS/a_spec.lua", PASS_A:format("a"))
  write(qroot .. "/TESTS/b_spec.lua", PASS_A:format("b"))
  r = go({ qroot, "--list" })
  ok(
    r.out:find("b_spec.lua::b_spec.lua.*a_spec.lua::a_spec.lua") ~= nil,
    "the runner's order is kept" .. both(r)
  )
  r = go({ qroot })
  ok(r.out:find("Q_OK%s*$") ~= nil, "the runner's sentinel is the last line" .. both(r))
  r = go({ qroot, "--sentinel", "MINE_OK" })
  ok(r.out:find("MINE_OK%s*$") ~= nil, "--sentinel overrides it")
  write(qroot .. "/TESTS/c_spec.lua", "local x = 1\nreturn x\n")
  r = go({ qroot })
  lacks(r.out, "Q_OK", "an unclassified file: no sentinel")
  eq(r.code, 1, "and red: a file that did not run is never green")
  vim.fn.delete(qroot .. "/TESTS/c_spec.lua")
  write(
    qroot .. "/TESTS/run.lua",
    'local specs = { "b_spec.lua", "a_spec.lua", "gone_spec.lua" }\nio.stdout:write("\\nQ_OK\\n")\n'
  )
  r = go({ qroot })
  eq(r.code, 1, "a listed spec that is gone is red" .. both(r))
  lacks(r.out, "Q_OK", "no sentinel")

  -- =====================================================================
  -- minit: executed, and a raise in it is exit 3
  local mroot = new_root()
  write(mroot .. "/TESTS/minimal_init.lua", "_G.__project_spec_minit = 'ran'\n")
  write(
    mroot .. "/TESTS/m_spec.lua",
    'return function(H)\n  H.eq(_G.__project_spec_minit, "ran", "minit ran before the specs")\nend\n'
  )
  r = go({ mroot })
  eq(r.code, 0, "the project's minit ran first" .. both(r))
  _G.__project_spec_minit = nil
  write(mroot .. "/TESTS/minimal_init.lua", "error('minit is broken')\n")
  r = go({ mroot })
  eq(r.code, 3, "a raising minit is infrastructure: exit 3" .. both(r))
  has(r.err, "minit TESTS/minimal_init.lua failed", "naming it")
  has(r.err, "minit is broken", "with the reason")
  write(mroot .. "/.testing.lua", "return { minit = false }\n")
  r = go({ mroot })
  eq(r.code, 1, "minit = false: it does not run, the spec sees no global" .. both(r))

  -- =====================================================================
  -- `.testing.lua` keys that must reach the run (review V3): spec_pattern names the scripts without the
  -- `_spec` suffix (filetree/pickers/cmdlog), env_allow lets one variable into the child editors
  local proot = new_root()
  write(proot .. "/TESTS/a_spec.lua", PASS_A:format("a"))
  write(
    proot .. "/TESTS/tool.lua",
    table.concat({
      'if vim.env.TESTING_SPEC_VAR ~= "hello" then',
      '  print("[FAIL] the variable did not arrive: " .. tostring(vim.env.TESTING_SPEC_VAR))',
      "  os.exit(1)",
      "end",
      'print("[ OK ] variable")',
      "os.exit(0)",
      "",
    }, "\n")
  )
  r = go({ proot })
  eq(r.code, 0, "without spec_pattern only *_spec.lua runs (the script is not a spec)" .. both(r))
  lacks(r.out, "tool.lua", "the script is not listed")
  local SCRIPT_CFG = 'spec_pattern = { "_spec%.lua$", "/tool%.lua$" }, '
    .. 'dialect = { ["TESTS/tool.lua"] = "script", ["*"] = "auto" }'
  write(proot .. "/.testing.lua", "return { " .. SCRIPT_CFG .. " }\n")
  vim.uv.os_setenv("TESTING_SPEC_VAR", "hello")
  r = go({ proot })
  eq(r.code, 1, "spec_pattern from .testing.lua makes the script run" .. both(r))
  has(r.out, "tool.lua", "the script is listed")
  has(
    r.out .. r.err,
    "the variable did not arrive: nil",
    "and the child did not inherit the variable"
  )
  write(
    proot .. "/.testing.lua",
    "return { " .. SCRIPT_CFG .. ', env_allow = { "TESTING_SPEC_VAR" } }\n'
  )
  r = go({ proot })
  eq(r.code, 0, "env_allow from .testing.lua lets the variable into the child" .. both(r))
  vim.uv.os_unsetenv("TESTING_SPEC_VAR")

  -- assertions = "warn": the case passes, and the terminal says so (not only the IR)
  local wroot = new_root()
  write(
    wroot .. "/TESTS/quiet_spec.lua",
    "describe('d', function()\n  it('does not throw', function() end)\n  it('asserts', function() assert.is_true(true) end)\nend)\n"
  )
  r = go({ wroot })
  eq(r.code, 1, "default assertions = error: a case without assertions is red" .. both(r))
  write(wroot .. "/.testing.lua", 'return { assertions = "warn" }\n')
  r = go({ wroot })
  eq(r.code, 0, "assertions = warn: green" .. both(r))
  has(r.out, "1 case(s) passed without asserting anything", "the terminal counts them")
  has(r.out, "TESTS/quiet_spec.lua::d::does not throw", "and names the case")
  lacks(r.out, "d::asserts", "but not the one that asserts")

  ok(os.exit == exit_before, "no exit guard left behind")
  for _, d in ipairs(made) do
    vim.fn.delete(d, "rf")
  end
  vim.fn.delete(state_dir, "rf")
end
