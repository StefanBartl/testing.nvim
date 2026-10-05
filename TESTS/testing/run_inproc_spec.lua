-- TESTS/testing/run_inproc_spec.lua -- the in-process driver on a temp fixture project (never on
-- lib.nvim): discovery order + sentinel hint, ALL failures of a file visible, error files, the
-- zero-assertion rule, the IR on disk (validated, placeholders, no user name).

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
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local inproc = require("testing.run.inproc")
  local json = require("lib.nvim.json")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local root = vim.fs.normalize(vim.fn.tempname())
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

  -- discovery: runner order first, unlisted specs after (alphabetical), the sentinel is read
  local found = inproc.discover(root)
  local names = vim.tbl_map(function(p)
    return vim.fs.basename(p)
  end, found.files)
  eq(names[1], "c_error_spec.lua", "listed first")
  eq(names[2], "a_pass_spec.lua", "listed second")
  eq(
    names[3],
    "ghost_spec.lua",
    "listed third: the missing ghost stays in the list (it fails when loaded)"
  )
  eq(names[4], "b_multi_fail_spec.lua", "listed fourth")
  eq(names[5], "d_empty_spec.lua", "unlisted specs come last, alphabetically")
  eq(names[6], "e_load_error_spec.lua", "unlisted: sixth")
  eq(found.sentinel, "FIXTURE_OK", "sentinel taken from the project's runner")
  local noted = table.concat(found.notes, "\n")
  has(noted, "ghost_spec.lua", "a listed but missing spec is noted")
  has(noted, "d_empty_spec.lua", "an unlisted spec is noted")
  eq(#inproc.discover(root, { "a_pass" }).files, 1, "--only filters by substring")
  eq(#inproc.discover(root .. "/nothing").files, 0, "no TESTS dir: no files")

  -- the run
  local out = {}
  local report = inproc.run({
    root = root,
    files = found.files,
    say = function(line)
      out[#out + 1] = line
    end,
  })
  local text = table.concat(out, "\n")
  eq(report.total, 6, "six files ran")
  eq(report.failed, 5, "five are not green")
  eq(report.exit_code, 1, "exit code 1")

  local by = {}
  for _, c in ipairs(report.result.cases) do
    by[vim.fs.basename(c.file)] = c
  end
  eq(by["a_pass_spec.lua"].status, "pass", "green file")
  eq(by["c_error_spec.lua"].status, "error", "a raise is an error case")
  eq(by["b_multi_fail_spec.lua"].status, "fail", "failed checks are a fail case")
  eq(by["d_empty_spec.lua"].status, "fail", "no assertion at all fails (kernel rule P4)")
  eq(by["e_load_error_spec.lua"].status, "error", "a file that does not even load is an error")
  eq(
    by["b_multi_fail_spec.lua"].id,
    "TESTS/b_multi_fail_spec.lua::b_multi_fail_spec.lua",
    "case id"
  )

  -- P1: ALL failures of the file are visible, in the output and in the IR
  has(text, "b_multi_fail_spec.lua:2: first wrong", "first failure with its line")
  has(text, "b_multi_fail_spec.lua:4: second wrong", "second failure")
  has(text, "b_multi_fail_spec.lua:5: third wrong", "third failure")
  local failed_in_ir = 0
  for _, a in ipairs(by["b_multi_fail_spec.lua"].assertions) do
    if not a.ok then
      failed_in_ir = failed_in_ir + 1
    end
  end
  eq(failed_in_ir, 3, "the IR carries all three failed assertions")
  has(text, "error: ", "an error file shows its message")
  has(text, "boom", "the message of the raise")
  has(text, "ok    a_pass_spec.lua", "line shape of the old runner for a green file")
  has(text, "FAIL  b_multi_fail_spec.lua", "line shape of the old runner for a red file")
  has(text, "5 spec(s) failed", "failure summary line")
  ok(not text:find("FIXTURE_OK", 1, true), "no sentinel from the driver itself")
  has(text, "timings: 6 file(s)", "timing line")

  -- green only: exit code 0, no failure line
  out = {}
  local green = inproc.run({
    root = root,
    files = { T .. "a_pass_spec.lua" },
    say = function(line)
      out[#out + 1] = line
    end,
  })
  eq(green.exit_code, 0, "all green: exit 0")
  eq(green.failed, 0, "nothing failed")
  eq(green.result.summary.pass, 1, "summary counts the pass")

  -- the IR on disk: validated, placeholders, no user name
  local file = root .. "/out/result.json"
  local wrote, err = inproc.write_json(report.result, file, root)
  ok(wrote, "write_json: " .. tostring(err))
  local f = assert(io.open(file, "rb"))
  local body = f:read("*a")
  f:close()
  local decoded = assert(json.decode(body))
  eq(decoded.schema_version, 1, "schema_version")
  eq(#decoded.cases, 6, "six cases in the file")
  eq(decoded.summary.pass, 1, "summary in the file")
  eq(decoded.summary.error, 3, "three error cases in the file")
  ok(not body:find(root, 1, true), "the fixture root is replaced by a placeholder")
  has(body, "<REPO>/TESTS/b_multi_fail_spec.lua", "assertion files are <REPO>-relative")
  local valid, problems = require("testing.core.result").validate(decoded)
  ok(valid, "the file validates: " .. table.concat(problems, "; "))
  local user = vim.env.USERNAME or vim.env.USER
  if user and #user >= 3 then
    ok(not body:lower():find(user:lower(), 1, true), "the user name does not appear in the IR")
  end

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
  local case = scrubbed.cases[1]
  case.assertions[1].msg = vim.inspect(vim.fn.tempname() .. "\\x") .. " HOMEPATH=\\Users\\someone"
  local s_file = root .. "/out/scrub.json"
  local s_ok, s_err = inproc.write_json(scrubbed, s_file, root)
  ok(s_ok, "escaped paths do not make the IR invalid: " .. tostring(s_err))

  vim.fn.delete(root, "rf")

  -- F1: a listed spec that is missing is an error case (not a note only)
  eq(by["ghost_spec.lua"].status, "error", "a listed spec missing on disk is an error case")
  -- F7: every case says that its effects were not measured
  has(table.concat(by["a_pass_spec.lua"].notes, "\n"), "effects: not collected", "effects note")

  -- F6: names inside comments of TESTS/run.lua are not a spec list
  local r3 = vim.fs.normalize(vim.fn.tempname())
  write(
    r3 .. "/TESTS/run.lua",
    'local specs = {\n  "a_spec.lua",\n  -- "ghost_spec.lua",\n}\n--[[ "block_spec.lua" ]]\n'
      .. 'local s = "x -- not a comment"\nio.stdout:write("\\nR3_OK\\n")\n'
  )
  write(r3 .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')
  local f3 = inproc.discover(r3)
  eq(#f3.files, 1, "commented-out names are not listed")
  eq(vim.fs.basename(f3.files[1]), "a_spec.lua", "only the real entry")
  eq(f3.sentinel, "R3_OK", "the sentinel after a string that contains '--' is still found")
  eq(f3.total, 1, "total counts the unfiltered list")
  eq(#inproc.discover(r3, { "nothing" }).files, 0, "filtered")
  eq(inproc.discover(r3, { "nothing" }).total, 1, "total ignores the filter")

  -- F8: call site after a tail call; a late assertion cannot land on another case
  write(
    r3 .. "/TESTS/t_spec.lua",
    'return function(H)\n  local function helper()\n    return H.eq(1, 2, "tail")\n  end\n  helper()\n  return H.eq(3, 4, "last")\nend\n'
  )
  local silent = function() end
  local rt = inproc.run({ root = r3, files = { r3 .. "/TESTS/t_spec.lua" }, say = silent })
  local asserts = rt.result.cases[1].assertions
  eq(#asserts, 2, "two assertions")
  ok(
    asserts[1].file and asserts[1].file:find("t_spec.lua", 1, true),
    "a tail call in a helper: call site is the spec, not the runner: " .. tostring(asserts[1].file)
  )
  eq(asserts[1].line, 5, "the line of the helper call")
  eq(
    asserts[2].file,
    nil,
    "a spec that tail calls its last assertion has no call site: none, not a wrong one"
  )

  write(
    r3 .. "/TESTS/late_spec.lua",
    'return function(H)\n  H.eq(1, 1, "now")\n  vim.defer_fn(function()\n    pcall(H.eq, 1, 2, "late one")\n  end, 20)\nend\n'
  )
  write(
    r3 .. "/TESTS/next_spec.lua",
    'return function(H)\n  H.eq(1, 1, "next")\n  vim.wait(80)\nend\n'
  )
  local rl = inproc.run({
    root = r3,
    files = { r3 .. "/TESTS/late_spec.lua", r3 .. "/TESTS/next_spec.lua" },
    say = silent,
  })
  eq(rl.exit_code, 1, "a late assertion turns the run red")
  eq(rl.result.cases[2].status, "pass", "the late call did not land on the next file's case")
  local late_case = rl.result.cases[3]
  ok(late_case and late_case.status == "fail", "a synthetic case carries the late assertion")
  has(late_case.assertions[1].msg, "after its case", "says why")
  vim.fn.delete(r3, "rf")

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
  has(json_text, '"status":"pass"', "status stays")
  local back = assert(require("lib.nvim.json").decode(json_text))
  local v_ok, v_problems = rr.validate(back, { forbid = { "pass", "PCNAME" } })
  ok(not v_ok and #v_problems > 0, "the validator still flags the word where it stands alone")
  local clean_ok = rr.validate(back, { forbid = { "PCNAME" } })
  ok(clean_ok, "redacted IR validates")
  local mail_ok = rr.validate(vim.tbl_deep_extend("force", back, {
    cases = { { assertions = { { msg = "x@y.org" } } } },
  }))
  ok(not mail_ok, "the validator refuses an e-mail address")
end
