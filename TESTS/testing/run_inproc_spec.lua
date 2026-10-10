-- TESTS/testing/run_inproc_spec.lua -- the in-process driver on temp fixture projects (never on a
-- real repo): dialect per file through discovery, ALL failures of a file visible, error cases with
-- the spec path, the zero-assertion rule, missing/unknown files, deep directories, selection inside
-- busted files, --maxfail, timeouts (file and case), strict mode, the IR on disk (validated,
-- placeholders, no user name, kernel redaction), list/dry run.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local inproc = require("testing.run.inproc")
  local discover = require("testing.discover")
  local select_mod = require("testing.run.select")
  local json = require("lib.nvim.json")
  local timeout = require("testing.run.timeout")
  local outer_depth = timeout.depth()

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param prefix string
  ---@return string
  local function new_root(prefix)
    local root = vim.fs.normalize(vim.fn.tempname()) .. "-" .. prefix
    vim.fn.mkdir(root .. "/TESTS", "p")
    return root
  end

  ---Run a fixture root the way the CLI does (discovery, runner order), without selection.
  ---@param root string
  ---@param extra? table
  ---@return Testing.Inproc.Report
  ---@return Testing.Discover.Result
  local function run_root(root, extra)
    local disc = discover.discover(root, { scan_lua_dir = false })
    local ordered = discover.order(disc)
    local opts = vim.tbl_extend("force", { root = root, files = ordered }, extra or {})
    return inproc.run(opts), disc
  end

  ---@param report Testing.Inproc.Report
  ---@return table<string, Testing.Result.Case>
  local function by_id_or_file(report)
    local by = {}
    for _, c in ipairs(report.result.cases) do
      by[vim.fs.basename(c.file)] = by[vim.fs.basename(c.file)] or c
      by[c.id] = c
    end
    return by
  end

  -- =====================================================================
  -- dialect A files: order from the project's runner, statuses, P1/P4
  local root = new_root("a")
  local T = root .. "/TESTS/"
  write(
    T .. "run.lua",
    'local specs = {\n  "c_error_spec.lua",\n  "a_pass_spec.lua",\n  "ghost_spec.lua",\n  "b_multi_fail_spec.lua",\n}\n'
      .. 'io.stdout:write("\\nFIXTURE_OK\\n")\n'
  )
  write(
    T .. "a_pass_spec.lua",
    'return function(H)\n  H.eq(1, 1, "one")\n  H.ok(true, "two")\nend\n'
  )
  write(
    T .. "b_multi_fail_spec.lua",
    'return function(H)\n  H.eq(1, 2, "first wrong")\n  H.eq(3, 3, "fine")\n  H.ok(false, "second wrong")\n'
      .. '  H.eq("a", "b", "third wrong")\nend\n'
  )
  write(T .. "c_error_spec.lua", 'return function(H)\n  H.eq(1, 1, "fine")\n  error("boom")\nend\n')
  write(T .. "d_empty_spec.lua", "return function(H)\n  local _ = H\nend\n")
  write(T .. "e_load_error_spec.lua", "return function(H\n")

  local report, disc = run_root(root)
  eq(disc.runner.sentinel, "FIXTURE_OK", "the sentinel of the project's runner is still discovered")
  local names = vim.tbl_map(function(c)
    return vim.fs.basename(c.file)
  end, report.result.cases)
  eq(
    vim.list_slice(names, 1, 4),
    { "c_error_spec.lua", "a_pass_spec.lua", "ghost_spec.lua", "b_multi_fail_spec.lua" },
    "the runner's order first, the ghost stays in the list"
  )
  eq(report.total, 6, "six files, six cases")
  eq(report.files_run, 6, "all ran")
  eq(report.failed, 5, "five are red")
  eq(report.exit_code, 1, "exit code 1")
  local by = by_id_or_file(report)
  eq(by["a_pass_spec.lua"].status, "pass", "green file")
  eq(by["c_error_spec.lua"].status, "error", "a raise is an error case")
  eq(by["b_multi_fail_spec.lua"].status, "fail", "failed checks are a fail case")
  eq(by["d_empty_spec.lua"].status, "fail", "no assertion at all fails (kernel rule P4)")
  eq(by["e_load_error_spec.lua"].status, "error", "a file that does not even load is an error")
  eq(by["ghost_spec.lua"].status, "error", "a listed spec missing on disk is an error case")
  has(by["ghost_spec.lua"].error.message, "not on disk", "and says why")
  eq(
    by["b_multi_fail_spec.lua"].id,
    "TESTS/b_multi_fail_spec.lua::b_multi_fail_spec.lua",
    "case id"
  )
  -- M0 follow-up: a spec that does not return a function is a readable error WITH the spec path
  -- (plain paths run in dialect A, so that the sniffer, which calls such files `unknown`, is not asked)
  local nonfn = new_root("nonfn")
  write(nonfn .. "/TESTS/f_number_spec.lua", "return 7\n")
  write(nonfn .. "/TESTS/g_nothing_spec.lua", "local x = 1\n")
  local nf = inproc.run({
    root = nonfn,
    files = { nonfn .. "/TESTS/f_number_spec.lua", nonfn .. "/TESTS/g_nothing_spec.lua" },
  })
  local nby = by_id_or_file(nf)
  eq(nby["f_number_spec.lua"].status, "error", "a spec returning a number is an error")
  has(nby["f_number_spec.lua"].error.message, "TESTS/f_number_spec.lua", "names the spec path")
  has(nby["f_number_spec.lua"].error.message, "function(H)", "says what is expected")
  has(nby["f_number_spec.lua"].error.message, "number", "and what it got")
  eq(nby["g_nothing_spec.lua"].status, "error", "a spec returning nothing is an error")
  has(nby["g_nothing_spec.lua"].error.message, "nothing", "says it returned nothing")
  has(nby["g_nothing_spec.lua"].error.message, "TESTS/g_nothing_spec.lua", "with the path")
  vim.fn.delete(nonfn, "rf")

  -- P1: ALL failures of the file are in the IR, with their lines
  local failed_in_ir, lines = 0, {}
  for _, a in ipairs(by["b_multi_fail_spec.lua"].assertions) do
    if not a.ok then
      failed_in_ir = failed_in_ir + 1
      lines[#lines + 1] = a.line
    end
  end
  eq(failed_in_ir, 3, "the IR carries all three failed assertions")
  eq(lines, { 2, 4, 5 }, "with the lines of the spec")
  has(by["c_error_spec.lua"].error.message, "boom", "the message of the raise")
  ok(by["c_error_spec.lua"].error.traceback ~= "", "and a traceback")
  has(table.concat(by["a_pass_spec.lua"].notes, "\n"), "effects: not collected", "effects note")

  -- green only
  local green = inproc.run({ root = root, files = { T .. "a_pass_spec.lua" } })
  eq(green.exit_code, 0, "all green: exit 0")
  eq(green.failed, 0, "nothing failed")
  eq(green.result.summary.pass, 1, "summary counts the pass")
  eq(green.stopped, false, "not stopped")

  -- the seed travels into the IR header
  local seeded = inproc.run({ root = root, files = { T .. "a_pass_spec.lua" }, seed = 31337 })
  eq(seeded.result.run.seed, 31337, "run.seed")

  -- progress hook sees every case
  local seen = 0
  inproc.run({
    root = root,
    files = { T .. "a_pass_spec.lua", T .. "b_multi_fail_spec.lua" },
    on_case = function()
      seen = seen + 1
    end,
  })
  eq(seen, 2, "on_case is called for every case")

  -- =====================================================================
  -- the IR on disk: validated, placeholders, no user name; the input is not changed
  local file = root .. "/out/result.json"
  local before = vim.deepcopy(report.result)
  local wrote, err = inproc.write_json(report.result, file, root)
  ok(wrote, "write_json: " .. tostring(err))
  eq(report.result, before, "write_json does not modify the result it is given")
  local f = assert(io.open(file, "rb"))
  local body = f:read("*a")
  f:close()
  local decoded = assert(json.decode(body))
  eq(decoded.schema_version, 1, "schema_version")
  eq(#decoded.cases, 6, "six cases in the file")
  eq(decoded.summary.pass, 1, "summary in the file")
  ok(not body:find(root, 1, true), "the fixture root is replaced by a placeholder")
  has(body, "<REPO>/TESTS/b_multi_fail_spec.lua", "assertion files are <REPO>-relative")
  local valid, problems = require("testing.core.result").validate(decoded)
  ok(valid, "the file validates: " .. table.concat(problems, "; "))
  local user = vim.env.USERNAME or vim.env.USER
  if user and #user >= 3 then
    ok(not body:lower():find(user:lower(), 1, true), "the user name does not appear in the IR")
  end
  eq(H.glob(root .. "/out/*.atomic-tmp*"), {}, "atomic write leaves no temp file")

  -- sanitize hands out the decoded, validated IR for reporters
  local ir, text, serr = inproc.sanitize(report.result, root)
  ok(ir ~= nil and text ~= nil, "sanitize: " .. tostring(serr))
  assert(ir and text, "sanitize returned nothing")
  eq(ir.schema_version, 1, "the sanitized IR")
  ok(not text:find(root, 1, true), "no absolute root in it")

  -- an IR that cannot validate is not written
  local broken = vim.deepcopy(report.result)
  broken.summary.pass = 99
  local bad_file = root .. "/out/bad.json"
  local bad_ok, bad_err = inproc.write_json(broken, bad_file, root)
  eq(bad_ok, false, "a wrong summary is refused")
  has(bad_err, "failed validation", "the reason is the validation")
  eq(vim.uv.fs_stat(bad_file), nil, "nothing is written for an invalid IR")

  -- the scrubber handles an escaped (doubled-backslash) path and an env-style home path
  local scrubbed = vim.deepcopy(report.result)
  scrubbed.cases[1].assertions[1] = {
    ok = true,
    kind = "ok",
    msg = vim.inspect(vim.fn.tempname() .. "\\x") .. " HOMEPATH=\\Users\\someone",
  }
  local s_ok, s_err = inproc.write_json(scrubbed, root .. "/out/scrub.json", root)
  ok(s_ok, "escaped paths do not make the IR invalid: " .. tostring(s_err))

  -- L2: a cosmetic privacy check never discards a verdict. Synthetic user-home paths in assertion
  -- texts (a spec about an anonymizer) are redacted to a placeholder, however they are shaped
  local synthetic = {
    [[C:\Users\mbeispiel\Documents]],
    "/mnt/c/Users/maria/y",
    [[\\fs01\data\Users\bob]],
    [[D:\Data\Users\bob\x]],
    [[\Users\jdoe at the start]],
    "https://kunde.example/Users/maria/a.txt",
  }
  local many = vim.deepcopy(report.result)
  many.cases[1].assertions = {}
  for i = 1, 99 do
    local p = synthetic[(i % #synthetic) + 1]
    many.cases[1].assertions[i] = {
      ok = true,
      kind = "ok",
      msg = ("path %d: %s"):format(i, p),
      expected = p,
      actual = p,
    }
  end
  many.cases[1].status = "pass"
  many.summary = require("testing.core.result").summarize(many.cases)
  local m_ir, m_text, m_err = inproc.sanitize(many, root)
  ok(m_ir ~= nil, "99 synthetic user paths do not discard the verdict: " .. tostring(m_err))
  assert(m_ir and m_text, "sanitize returned nothing")
  eq(m_ir.warnings, nil, "the redaction removed them all: no warning left")
  ok(not m_text:find("mbeispiel", 1, true), "the synthetic user name is gone")
  ok(not m_text:find("bob", 1, true), "also from the mid-path and UNC shapes")
  has(m_ir.cases[1].assertions[1].msg, "path 1: ", "the text around the path stays readable")
  ok(
    m_ir.cases[1].assertions[1].msg:find("<HOME>", 1, true)
      or m_ir.cases[1].assertions[1].msg:find("<USER-PATH>", 1, true),
    "and the path is a placeholder"
  )
  eq(m_ir.cases[1].status, "pass", "the verdict is kept")

  -- what redaction cannot reach (the id of a case is the project's own word) becomes a warning in
  -- the IR; the verdict and the file stay, and the warning does not repeat the leaked text
  local named = vim.deepcopy(report.result)
  named.cases[1].id = named.cases[1].id .. [[ reads C:\Users\mbeispiel\x]]
  local w_file = root .. "/out/warned.json"
  local w_ok, w_err = inproc.write_json(named, w_file, root)
  ok(w_ok, "a leak in a name is no reason to refuse the IR: " .. tostring(w_err))
  local w_ir = assert(require("lib.nvim.json").decode(table.concat(vim.fn.readfile(w_file), "\n")))
  ok(type(w_ir.warnings) == "table" and #w_ir.warnings >= 1, "the IR carries a warning")
  ok(not table.concat(w_ir.warnings, " "):find("mbeispiel", 1, true), "which names no leaked text")
  eq(#w_ir.cases, #report.result.cases, "and every case stays")

  -- F4: redaction in the kernel: env dumps, e-mail shapes, user and host words; structure intact
  local rr = require("testing.core.result")
  local res = rr.new({ root = "/p" })
  local c = rr.new_case({ file = "x_spec.lua", name = "x_spec.lua" })
  c.assertions[1] = {
    ok = true,
    kind = "eq",
    msg = 'env {"COMPUTERNAME=PCNAME", "SECRETVAR=a b c", "OTHER=1"} mail me@host.example by pass',
  }
  c.assertions[2] = { ok = true, kind = "eq", msg = "StefanPass/lib.nvim is public, pass is not" }
  rr.add_case(res, rr.finish_case(c))
  rr.finalize(res)
  local json_text = assert(rr.encode(res, {
    redact = {
      env_names = { "COMPUTERNAME", "SECRETVAR" },
      words = { { text = "pass", ph = "<USER>" }, { text = "PCNAME", ph = "<HOST>" } },
    },
  }))
  ok(not json_text:find("PCNAME", 1, true), "env value gone")
  ok(not json_text:find("a b c", 1, true), "an env value with spaces is gone as a whole")
  has(json_text, "SECRETVAR=<ENV>", "the name stays, the value goes")
  has(json_text, "OTHER=1", "a variable that is not in the environment is left alone")
  ok(not json_text:find("me@host", 1, true), "e-mail shape gone")
  has(json_text, "<EMAIL>", "placeholder")
  has(json_text, "StefanPass/lib.nvim", "a word inside a longer name is not corrupted")
  has(json_text, '"kind":"eq"', "structural values stay: a user called 'pass' cannot break the IR")
  local back = assert(json.decode(json_text))
  local v_ok, v_problems = rr.validate(back, { forbid = { "pass", "PCNAME" } })
  ok(not v_ok and #v_problems > 0, "the validator still flags the word where it stands alone")
  ok(rr.validate(back, { forbid = { "PCNAME" } }), "redacted IR validates")

  -- the driver wires that redaction: an env-style dump from a spec does not reach the file
  write(
    T .. "z_secret_spec.lua",
    'return function(H)\n  H.ok(false, "dump: PATH=" .. (vim.env.PATH or "x"))\nend\n'
  )
  local secret = run_root(root)
  local sfile = root .. "/out/secret.json"
  local sok, serr2 = inproc.write_json(secret.result, sfile, root)
  ok(sok, "an environment dump in a message does not break the IR: " .. tostring(serr2))
  local sbody = assert(io.open(sfile, "rb")):read("*a")
  ok(not sbody:find(vim.env.PATH or "\1\1\1", 1, true), "and the PATH value is not in the file")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- the depth gap of M0: a spec five directories down is found and run
  root = new_root("deep")
  write(root .. "/TESTS/a/b/c/d/e/deep_spec.lua", 'return function(H)\n  H.eq(1, 1, "deep")\nend\n')
  write(root .. "/TESTS/top_spec.lua", 'return function(H)\n  H.eq(1, 1, "top")\nend\n')
  report = run_root(root)
  eq(report.total, 2, "both specs ran, the deep one included")
  local deep = by_id_or_file(report)["deep_spec.lua"]
  ok(deep ~= nil and deep.status == "pass", "the deep spec passed")
  eq(deep.file, "TESTS/a/b/c/d/e/deep_spec.lua", "with its relative path")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- busted files: one case per it, selection inside the file, tags into the IR
  root = new_root("busted")
  T = root .. "/TESTS/"
  write(
    T .. "calc_spec.lua",
    table.concat({
      "describe('calc', function()",
      "  it('adds', function() assert.are.equal(2, 1 + 1) end)",
      "  it('breaks #slow', function() assert.are.equal(1, 2) end)",
      "  describe('inner #net', function()",
      "    it('subtracts', function() assert.are.equal(0, 1 - 1) end)",
      "  end)",
      "end)",
      "",
    }, "\n")
  )
  write(
    T .. "other_spec.lua",
    "describe('other', function()\n  it('ok', function() assert.is_true(true) end)\nend)\n"
  )
  report = run_root(root)
  by = by_id_or_file(report)
  eq(report.total, 4, "four it cases")
  eq(by["TESTS/calc_spec.lua::calc::adds"].status, "pass", "it passes")
  eq(by["TESTS/calc_spec.lua::calc::breaks #slow"].status, "fail", "it fails")
  eq(
    by["TESTS/calc_spec.lua::calc::breaks #slow"].tags,
    { "slow" },
    "the title tag lands in the IR"
  )
  eq(by["TESTS/calc_spec.lua::calc::inner #net::subtracts"].tags, { "net" }, "a describe tag too")
  eq(report.failed, 1, "one red case")

  local sel = select_mod.new({ filter = { "adds" } })
  report = run_root(root, { selector = sel })
  eq(report.total, 1, "the filter selects one case inside a busted file")
  eq(report.result.cases[1].id, "TESTS/calc_spec.lua::calc::adds", "the right one")
  sel = select_mod.new({ exclude_tags = { "slow", "net" } })
  report = run_root(root, { selector = sel })
  eq(report.total, 2, "excluded tags remove their cases")
  eq(report.failed, 0, "the failing #slow case did not run")
  sel = select_mod.new({ tags = { "net" } })
  report = run_root(root, { selector = sel })
  eq(
    vim.tbl_map(function(cs)
      return cs.id
    end, report.result.cases),
    { "TESTS/calc_spec.lua::calc::inner #net::subtracts" },
    "--tags selects by describe tag"
  )

  -- --lf: only the remembered cases of the file; the file itself failed: everything in it
  local lf = select_mod.group_failed({ "TESTS/calc_spec.lua::calc::breaks #slow" })
  report = run_root(root, { lf = lf })
  by = by_id_or_file(report)
  ok(by["TESTS/calc_spec.lua::calc::breaks #slow"] ~= nil, "the remembered case runs")
  ok(by["TESTS/calc_spec.lua::calc::adds"] == nil, "the others of that file do not")

  -- the list: busted describe bodies run, it bodies do not
  write(
    T .. "listing_spec.lua",
    "describe('listing', function()\n  it('never runs', function() _G.__listing_ran = true end)\nend)\n"
  )
  local disc2 = discover.discover(root, { scan_lua_dir = false })
  local items = inproc.list({ root = root, files = discover.order(disc2) })
  local ids = vim.tbl_map(function(it)
    return it.id
  end, items)
  ok(vim.tbl_contains(ids, "TESTS/listing_spec.lua::listing::never runs"), "list names the it")
  ok(vim.tbl_contains(ids, "TESTS/calc_spec.lua::calc::adds"), "and the others")
  eq(rawget(_G, "__listing_ran"), nil, "no it body ran for the list")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- unknown dialect: an error case with the reason (a file that did not run is never green)
  root = new_root("unknown")
  T = root .. "/TESTS/"
  write(T .. "good_spec.lua", 'return function(H)\n  H.eq(1, 1, "good")\nend\n')
  write(T .. "mystery_spec.lua", "local x = 1\nreturn x\n")
  report = run_root(root)
  by = by_id_or_file(report)
  eq(by["mystery_spec.lua"].status, "error", "an unknown dialect is an error, visible")
  has(by["mystery_spec.lua"].error.message, "dialect unknown", "with the reason")
  eq(report.skipped, 0, "not a skip")
  eq(report.exit_code, 1, "the exit code is red: CI reads only that")
  eq(report.result.summary.error, 1, "and it is in the IR summary")

  -- findings: info stays a note, strict makes warn/error a failing case of its own
  local finding = {
    rule = "NEW-48",
    kind = "legacy_location",
    severity = "warn",
    path = "TESTS/good_spec.lua",
    message = "legacy",
  }
  local info = { rule = "NEW-43", kind = "project_harness", severity = "info", message = "fyi" }
  report = run_root(root, { findings = { finding, info } })
  by = by_id_or_file(report)
  has(
    table.concat(by["good_spec.lua"].notes, "\n"),
    "finding [NEW-48 warn] legacy",
    "a finding is attached to its file"
  )
  eq(report.result.summary.fail, 0, "not strict: findings are notes only")
  report = run_root(root, { findings = { finding, info }, strict = true })
  eq(report.exit_code, 1, "strict: a warn finding fails the run")
  local fcase
  for _, cs in ipairs(report.result.cases) do
    if cs.file == "<findings>" then
      fcase = cs
    end
  end
  ok(fcase ~= nil and fcase.status == "fail", "as a failing case of its own")
  eq(#fcase.assertions, 1, "one assertion: the info finding is not counted")
  has(fcase.assertions[1].msg, "legacy", "naming the finding")
  report = inproc.run({
    root = root,
    files = { T .. "good_spec.lua" },
    findings = { info },
    strict = true,
  })
  eq(report.exit_code, 0, "strict with only an info finding stays green")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- --maxfail
  root = new_root("maxfail")
  T = root .. "/TESTS/"
  write(T .. "a_spec.lua", 'return function(H)\n  H.eq(1, 2, "a")\nend\n')
  write(T .. "b_spec.lua", 'return function(H)\n  H.eq(1, 1, "b")\nend\n')
  write(T .. "c_spec.lua", 'return function(H)\n  H.eq(1, 2, "c")\nend\n')
  write(T .. "d_spec.lua", 'return function(H)\n  H.eq(1, 2, "d")\nend\n')
  report = run_root(root, { maxfail = 1 })
  eq(report.total, 1, "-x: stops after the first failure")
  eq(report.stopped, true, "reports that it stopped")
  eq(report.files_unrun, 3, "and how many files it did not reach")
  eq(report.exit_code, 1, "red")
  report = run_root(root, { maxfail = 2 })
  eq(report.total, 3, "--maxfail 2: a, b, c ran")
  eq(report.files_unrun, 1, "d did not")
  report = run_root(root, { maxfail = 99 })
  eq(report.total, 4, "a threshold that is never reached runs everything")
  eq(report.stopped, false, "and does not report a stop")
  -- inside a busted file the remaining its are not run either
  write(
    T .. "e_spec.lua",
    "describe('e', function()\n  it('1', function() assert.are.equal(1, 2) end)\n  it('2', function() assert.are.equal(1, 1) end)\n"
      .. "  it('3', function() assert.are.equal(1, 2) end)\nend)\n"
  )
  for _, name in ipairs({ "a", "b", "c", "d" }) do
    vim.fn.delete(T .. name .. "_spec.lua")
  end
  report = run_root(root, { maxfail = 1 })
  eq(report.total, 1, "a busted file stops at the first failing it")
  eq(report.result.cases[1].id, "TESTS/e_spec.lua::e::1", "which is the first")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- timeouts
  root = new_root("timeout")
  T = root .. "/TESTS/"
  write(
    T .. "a_hang_spec.lua",
    "return function(H)\n  H.eq(1, 1, 'before')\n  while true do end\nend\n"
  )
  write(T .. "b_after_spec.lua", 'return function(H)\n  H.eq(1, 1, "after")\nend\n')
  local t0 = vim.uv.hrtime()
  report = run_root(root, { timeouts = { file_ms = 300 } })
  ok((vim.uv.hrtime() - t0) / 1e6 < 20000, "a hanging spec does not hang the run")
  by = by_id_or_file(report)
  eq(by["a_hang_spec.lua"].status, "timeout", "the hanging file is a timeout")
  has(by["a_hang_spec.lua"].error.message, "testing: timeout:", "with the timeout message")
  has(by["a_hang_spec.lua"].error.message, "TESTS/a_hang_spec.lua", "naming the file")
  eq(by["b_after_spec.lua"].status, "pass", "the next file still ran")
  eq(report.exit_code, 1, "a timeout is red")
  eq(report.result.summary.timeout, 1, "and counted in the IR")
  eq(timeout.depth(), outer_depth, "the driver released its guard")

  -- a spec that swallows the timeout error is a timeout nevertheless
  write(
    T .. "a_hang_spec.lua",
    "return function(H)\n  H.eq(1, 1, 'before')\n  for _ = 1, 3 do pcall(function() while true do end end) end\nend\n"
  )
  report = run_root(root, { timeouts = { file_ms = 300 } })
  eq(
    by_id_or_file(report)["a_hang_spec.lua"].status,
    "timeout",
    "swallowing does not turn a timeout into a pass"
  )

  -- the runner's own work after a timed-out case (streaming it to the parent) is not cut off by the deadline the hook
  -- still holds: a raise inside it lands wherever the hook happens to be, e.g. inside the first-time `require` of the
  -- JSON encoder, and leaves that module as "loop or previous error" for the rest of a reused warm-pool member
  write(T .. "a_hang_spec.lua", "return function(H)\n  while true do end\nend\n")
  local streamed = {}
  report = run_root(root, {
    timeouts = { file_ms = 300 },
    on_case_early = function(case)
      local x = 0
      for i = 1, 3000000 do
        x = x + i
      end
      streamed[case.file] = x
    end,
  })
  eq(
    by_id_or_file(report)["a_hang_spec.lua"].status,
    "timeout",
    "a timed-out file whose case is streamed is a timeout"
  )
  ok(
    streamed["TESTS/a_hang_spec.lua"] ~= nil,
    "the deadline did not cut off the streaming of the timed-out case"
  )
  eq(timeout.depth(), outer_depth, "and the guard is released")

  -- a hopeless vim.wait is a timeout as well
  write(
    T .. "a_hang_spec.lua",
    "return function(H)\n  H.eq(1, 1, 'before')\n  vim.wait(60000, function() return false end)\nend\n"
  )
  t0 = vim.uv.hrtime()
  report = run_root(root, { timeouts = { file_ms = 300 } })
  eq(by_id_or_file(report)["a_hang_spec.lua"].status, "timeout", "vim.wait on nothing: timeout")
  ok((vim.uv.hrtime() - t0) / 1e6 < 20000, "and not after 60 s")

  -- busted: a case timeout kills one it, the file goes on
  write(
    T .. "a_hang_spec.lua",
    "describe('h', function()\n  it('spins', function() while true do end end)\n  it('fine', function() assert.are.equal(1, 1) end)\nend)\n"
  )
  report = run_root(root, { timeouts = { case_ms = 200, file_ms = 30000 } })
  by = by_id_or_file(report)
  eq(by["TESTS/a_hang_spec.lua::h::spins"].status, "timeout", "the spinning it is a timeout")
  eq(
    by["TESTS/a_hang_spec.lua::h::fine"].status,
    "pass",
    "the next it of the same file ran and passed"
  )
  eq(report.exit_code, 1, "red")

  -- without limits nothing is guarded
  write(T .. "a_hang_spec.lua", 'return function(H)\n  H.eq(1, 1, "no limit")\nend\n')
  report = run_root(root, {})
  eq(report.exit_code, 0, "no timeouts configured: nothing interferes")
  eq(timeout.depth(), outer_depth, "guards are released")
  vim.fn.delete(root, "rf")

  -- =====================================================================
  -- late assertions make the run red
  root = new_root("late")
  T = root .. "/TESTS/"
  write(
    T .. "late_spec.lua",
    'return function(H)\n  H.eq(1, 1, "now")\n  vim.defer_fn(function()\n    pcall(H.eq, 1, 2, "late one")\n  end, 20)\nend\n'
  )
  write(T .. "next_spec.lua", 'return function(H)\n  H.eq(1, 1, "next")\n  vim.wait(80)\nend\n')
  report = run_root(root)
  by = by_id_or_file(report)
  eq(report.exit_code, 1, "a late assertion turns the run red")
  eq(by["next_spec.lua"].status, "pass", "the late call did not land on the next file's case")
  local late_case = report.result.cases[#report.result.cases]
  ok(late_case.status == "fail", "a synthetic case carries the late assertion")
  has(late_case.assertions[1].msg, "after its case", "says why")

  -- a tail call in a helper: the call site is the spec, not the runner
  write(
    T .. "tail_spec.lua",
    'return function(H)\n  local function helper()\n    return H.eq(1, 2, "tail")\n  end\n  helper()\nend\n'
  )
  report = inproc.run({ root = root, files = { T .. "tail_spec.lua" } })
  local a1 = report.result.cases[1].assertions[1]
  ok(
    a1.file and a1.file:find("tail_spec.lua", 1, true),
    "call site is the spec: " .. tostring(a1.file)
  )
  eq(a1.line, 5, "a tail call loses its frame: the line is the call of the helper")
  vim.fn.delete(root, "rf")

  -- a busted file that registers no case (platform dependent specs): red by default, a skip with a
  -- warning under assertions = "warn", and a skip is never green under --strict
  root = new_root("nocase")
  write(
    root .. "/TESTS/platform_spec.lua",
    "describe('p', function()\n"
      .. "  if vim.fn.has('nonexistent_platform') == 1 then\n"
      .. "    it('only there', function() assert.is_true(true) end)\n"
      .. "  end\n"
      .. "end)\n"
  )
  report = run_root(root, { assertions = "error" })
  eq(report.exit_code, 1, 'no case registered, assertions = "error": red')
  report = run_root(root, { assertions = "warn" })
  eq(report.exit_code, 0, 'no case registered, assertions = "warn": not red')
  eq(report.result.summary.skip, 1, "but one skip is recorded")
  eq(report.result.cases[1].reason, "no case registered on this platform", "with the reason")
  report = run_root(root, { assertions = "warn", strict = true })
  eq(report.exit_code, 1, "under --strict that skip is never green")
  vim.fn.delete(root, "rf")
end
