-- TESTS/testing/core_result_spec.lua -- testing.core.result: the IR builder, verdict rules, summary,
-- deterministic JSON, path placeholders, and the validator.

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
  local result = require("testing.core.result")
  local assert_mod = require("testing.core.assert")
  local json = require("lib.nvim.json")

  ---Encode or fail the spec with the encoder's own message.
  ---@param r any
  ---@param opts? Testing.Result.EncodeOpts
  ---@return string
  local function enc(r, opts)
    local s, e = result.encode(r, opts)
    if not s then
      error("encode failed: " .. tostring(e), 2)
    end
    return s
  end

  ---@param problems string[]
  ---@return string
  local function joined(problems)
    return table.concat(problems, "\n")
  end

  ---A fully built result (pass, fail with several failures, error, zero assertions, skip) from a
  ---deterministic context: the same bytes on every call.
  ---@return Testing.Result
  local function build()
    local t = -5
    local a = assert_mod.new({
      clock = function()
        t = t + 5
        return t
      end,
    })
    local res = result.new({
      id = "2026-09-20T18:04:11Z-3f9c",
      project_key = "demo.nvim@a1b2",
      nvim = "0.12.0",
      os = "windows",
      arch = "x86_64",
      git = { sha = "7ec32e0", dirty = false },
      seed = 42,
      jobs = 1,
      duration_ms = 30,
      argv = { "--isolated=file" },
    })
    result.add_case(
      res,
      a.run_case({ file = "TESTS/a_spec.lua", describe = "demo", name = "passes" }, function(c)
        c.eq(1, 1, "one is one")
      end)
    )
    result.add_case(
      res,
      a.run_case({ file = "TESTS/a_spec.lua", describe = "demo", name = "fails twice" }, function(c)
        c.eq(1, 2, "first")
        c.ok(false, "second")
      end)
    )
    result.add_case(
      res,
      a.run_case({ file = "TESTS/a_spec.lua", describe = "demo", name = "throws" }, function(c)
        c.ok(true, "before")
        error("boom")
      end)
    )
    result.add_case(
      res,
      a.run_case({ file = "TESTS/a_spec.lua", describe = "demo", name = "empty" }, function() end)
    )
    local skipped = result.new_case({ file = "TESTS/b_spec.lua", name = "skipped", param = 2 })
    skipped.status = "skip"
    skipped.reason = "needs a display"
    result.add_case(res, skipped)
    return result.finalize(res)
  end

  -- ---------------------------------------------------------------------------------------------
  -- Ids and builders
  eq(result.SCHEMA_VERSION, 1, "schema_version is 1")
  eq(
    result.STATUSES,
    { "pass", "fail", "error", "skip", "xfail", "xpass", "timeout", "crash" },
    "the status enum of D.3.2"
  )
  eq(result.case_id({ file = "TESTS/a_spec.lua", name = "x" }), "TESTS/a_spec.lua::x", "file::case")
  eq(
    result.case_id({ file = "TESTS\\sub\\a_spec.lua", describe = "d", name = "x", param = "p" }),
    "TESTS/sub/a_spec.lua::d::x#p",
    "backslashes become slashes, one describe, a param"
  )
  eq(
    result.case_id({ file = "f.lua", describe = { "a", "b" }, name = "x", param = 0 }),
    "f.lua::a::b::x#0",
    "describe path joined by ::, param 0 counts"
  )
  eq(result.make_run_id(0, 0x3f9c), "1970-01-01T00:00:00Z-3f9c", "run id: UTC timestamp and 4 hex")
  ok(
    result.make_run_id():match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ%-%x%x%x%x$"),
    "default run id shape"
  )

  local fresh = result.new()
  eq(fresh.schema_version, 1, "a new result carries the schema version")
  eq(fresh.cases, {}, "a new result has no cases")
  eq(
    fresh.summary,
    { pass = 0, fail = 0, error = 0, skip = 0, xfail = 0, xpass = 0, timeout = 0, crash = 0 },
    "all eight counters exist from the start"
  )
  local good, problems = result.validate(fresh)
  ok(good, "an empty result is valid: " .. joined(problems))

  local case = result.new_case({ file = "a.lua", name = "x" })
  eq(
    case.effects,
    { spawned = {}, network = {}, fs_outside_tmp = {} },
    "effects are always present"
  )
  eq(case.artifacts, {}, "artifacts default to an empty list")

  -- ---------------------------------------------------------------------------------------------
  -- Verdict rules (finish_case)
  ---@param status any
  ---@param assertions any
  ---@return Testing.Result.Case
  local function case_with(status, assertions)
    local c = result.new_case({ file = "a.lua", name = "x" })
    c.status = status
    c.assertions = assertions
    return c
  end
  local pass_rec = { ok = true, kind = "eq" }
  local fail_rec = { ok = false, kind = "eq", msg = "no" }

  eq(result.finish_case(case_with("pass", { pass_rec })).status, "pass", "all ok -> pass")
  eq(
    result.finish_case(case_with("pass", { pass_rec, fail_rec })).status,
    "fail",
    "one failure -> fail"
  )
  local empty = result.finish_case(case_with("pass", {}))
  eq(empty.status, "fail", "no assertion -> fail (P4)")
  eq(empty.assertions[1].kind, "no_assertions", "with the synthetic record")
  has(empty.assertions[1].msg, "no assertions", "and a clear message")
  eq(
    result.finish_case(case_with("pass", { fail_rec }), { expect_fail = true }).status,
    "xfail",
    "expected failure"
  )
  eq(
    result.finish_case(case_with("pass", { pass_rec }), { expect_fail = true }).status,
    "xpass",
    "unexpected pass"
  )
  eq(
    result.finish_case(case_with("pass", {}), { expect_fail = true }).status,
    "fail",
    "empty is never xfail"
  )
  for _, status in ipairs({ "error", "skip", "timeout", "crash", "xfail", "xpass" }) do
    eq(result.finish_case(case_with(status, {})).status, status, status .. " is not recomputed")
  end
  eq(#result.finish_case(case_with("skip", {})).assertions, 0, "a skip gets no synthetic assertion")

  -- ---------------------------------------------------------------------------------------------
  -- Summary
  local res = build()
  eq(
    res.summary,
    { pass = 1, fail = 2, error = 1, skip = 1, xfail = 0, xpass = 0, timeout = 0, crash = 0 },
    "counters: pass, fail (failing + empty), error, skip"
  )
  eq(#res.cases, 5, "five cases")
  eq(res.cases[2].id, "TESTS/a_spec.lua::demo::fails twice", "stable ids")
  eq(res.cases[5].id, "TESTS/b_spec.lua::skipped#2", "param ids")
  eq(#res.cases[2].assertions, 2, "both failures of one case are in the IR (P1)")
  eq(res.cases[3].status, "error", "a throwing body is error")
  eq(res.cases[4].status, "fail", "an empty case fails")
  ---@type any
  local tagged = { { status = "pass" }, { status = "pass" }, { status = "bogus" } }
  eq(result.summarize(tagged).pass, 2, "counting")
  ---@type any
  local unknown = { { status = "bogus" } }
  eq(
    result.summarize(unknown),
    { pass = 0, fail = 0, error = 0, skip = 0, xfail = 0, xpass = 0, timeout = 0, crash = 0 },
    "an unknown status is not counted"
  )

  -- ---------------------------------------------------------------------------------------------
  -- IR validity, in memory and after a JSON round trip
  -- The in-memory result still carries the host's absolute assertion paths (the encoder
  -- normalizes them): validate the normalized form, repo before home (a checkout under $HOME,
  -- e.g. /home/runner/work/... on a CI runner, must read <REPO>, not <HOME>/work/...).
  local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local host_roots = {
    repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this))),
    home = vim.uv.os_homedir(),
  }
  local ci_host = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
  good, problems =
    result.validate(result.normalize(res, host_roots, { case_insensitive = ci_host }))
  ok(good, "the built result is valid: " .. joined(problems))

  -- the decoded IR is checked as it would be written: through the host's own roots (a checkout
  -- below /home/<user> or /Users/<user> is a home path until it is normalized)
  local text = enc(res, { roots = host_roots, case_insensitive = ci_host })
  has(text, '"schema_version":1', "the schema version is in the JSON")
  has(text, '"status":"fail"', "statuses are in the JSON")
  local decoded, derr = json.decode(text)
  eq(derr, nil, "the JSON decodes")
  good, problems = result.validate(decoded)
  ok(good, "the decoded IR is valid: " .. joined(problems))
  eq(decoded.summary.fail, 2, "the summary survives the round trip")
  eq(decoded.cases[2].assertions[1].expected, "2", "assertion detail survives the round trip")
  eq(
    decoded.cases[3].error.message:find("boom", 1, true) ~= nil,
    true,
    "the error survives the round trip"
  )

  -- ---------------------------------------------------------------------------------------------
  -- Determinism of the serialization
  -- Built from one call site in a loop: the traceback of the throwing case names the call site, so
  -- two different lines would (rightly) differ.
  local built, builds = {}, {}
  for i = 1, 2 do
    built[i] = build()
    builds[i] = enc(built[i])
  end
  local first = builds[1]
  eq(first, builds[2], "two independent builds serialize to the same bytes")

  local ordered = { schema_version = 1 }
  ordered.summary = built[1].summary
  ordered.cases = built[1].cases
  ordered.run = built[1].run
  eq(enc(ordered), first, "key insertion order does not matter")
  eq(first:sub(1, 10), '{"cases":[', "keys are sorted (cases before run before schema_version)")

  local pretty = enc(res, { indent = 2 })
  has(pretty, "\n", "indent pretty-prints")
  eq(select(1, json.decode(pretty)) ~= nil, true, "pretty output decodes")

  local bad_run = build()
  bad_run.run.duration_ms = 0 / 0
  local none, why = result.encode(bad_run)
  eq(none, nil, "NaN cannot be encoded")
  has(why, "cannot encode", "and the error says so")

  -- invalid UTF-8 would make the JSON undecodable: it is replaced
  local utf = build()
  utf.cases[1].notes = { "a\255b" }
  text = enc(utf)
  local round = json.decode(text)
  eq(round.cases[1].notes, { "a?b" }, "invalid UTF-8 bytes become ?")
  local valid_utf8 = build()
  valid_utf8.cases[1].notes = { "caf\195\169" }
  round = json.decode(enc(valid_utf8))
  eq(round.cases[1].notes, { "caf\195\169" }, "valid UTF-8 stays as it is")

  -- ---------------------------------------------------------------------------------------------
  -- Placeholders
  local roots = {
    repo = "E:\\repos\\demo.nvim",
    home = "C:\\Users\\bob",
    tmp = "C:\\Users\\bob\\AppData\\Local\\Temp",
    state = "C:\\Users\\bob\\AppData\\Local\\nvim-data",
  }
  local function norm(s, opts)
    return result.normalize(s, roots, opts)
  end
  eq(
    norm("E:\\repos\\demo.nvim\\TESTS\\a_spec.lua:3: x"),
    "<REPO>/TESTS/a_spec.lua:3: x",
    "repo, backslashes"
  )
  eq(norm("E:/repos/demo.nvim/lua/x.lua"), "<REPO>/lua/x.lua", "repo, forward slashes")
  eq(
    norm("C:\\Users\\bob\\AppData\\Local\\Temp\\lua_1\\f.txt"),
    "<TMP>/lua_1/f.txt",
    "the longest root wins over home"
  )
  eq(norm("C:/Users/bob/AppData/Local/nvim-data/spec"), "<STATE>/spec", "state")
  eq(norm("C:/Users/bob/.config/x"), "<HOME>/.config/x", "home")
  eq(
    norm("a C:\\Users\\bob\\x and E:/repos/demo.nvim/y"),
    "a <HOME>/x and <REPO>/y",
    "several roots in one string"
  )
  eq(norm("E:/repos/demo.nvim"), "<REPO>", "the root itself")
  eq(norm("e:/REPOS/Demo.nvim/x"), "e:/REPOS/Demo.nvim/x", "case-sensitive by default")
  eq(
    norm("e:/REPOS/Demo.nvim/x", { case_insensitive = true }),
    "<REPO>/x",
    "case-insensitive on request (Windows)"
  )
  eq(
    result.normalize("/home/bobby/x", { home = "/home/bob" }),
    "/home/bobby/x",
    "a root is not matched inside a longer name"
  )
  eq(
    result.normalize("/home/bob/x", { home = "/home/bob/" }),
    "<HOME>/x",
    "a trailing slash on the root is ignored"
  )
  eq(
    result.normalize("/var/tmp/x", { tmp = "/tmp" }),
    "/var/tmp/x",
    "a POSIX root is not matched in the middle of a path"
  )
  eq(result.normalize("/tmp/x", { tmp = "/tmp" }), "<TMP>/x", "a POSIX root at the start")
  -- a checkout below the home directory (a Linux/macOS CI runner): the repo root wins over home
  local posix = { repo = "/home/runner/work/p/p", home = "/home/runner", tmp = "/tmp" }
  eq(
    result.normalize("/home/runner/work/p/p/TESTS/a_spec.lua", posix),
    "<REPO>/TESTS/a_spec.lua",
    "a POSIX repo below home becomes <REPO>, not <HOME>/work/..."
  )
  eq(
    result.normalize("/home/runner/.config/x", posix),
    "<HOME>/.config/x",
    "other paths below home stay <HOME>"
  )
  eq(
    norm("no path here\\n"),
    "no path here\\n",
    "a string without a root is untouched (backslashes kept)"
  )
  eq(result.normalize("x", {}), "x", "no roots, no change")
  eq(result.normalize("x", { repo = "" }), "x", "an empty root is ignored")
  eq(result.normalize(42, roots), 42, "non-strings pass through")

  local nested = { list = { "C:\\Users\\bob\\a", { deep = "E:\\repos\\demo.nvim\\b" } }, n = 1 }
  local copy = result.normalize(nested, roots)
  eq(copy, { list = { "<HOME>/a", { deep = "<REPO>/b" } }, n = 1 }, "nested tables are normalized")
  eq(nested.list[1], "C:\\Users\\bob\\a", "the input is not mutated")

  -- the whole IR: no user name after normalization, a leak is caught without it
  local leaky = build()
  leaky.run.root = "E:\\repos\\demo.nvim"
  -- the assertion files recorded by build() are this machine's real spec path: make every one a
  -- path of the synthetic demo repository, so the test does not depend on where the checkout is
  for _, c in ipairs(leaky.cases) do
    for _, rec in ipairs(c.assertions or {}) do
      rec.file = "E:/repos/demo.nvim/TESTS/a_spec.lua"
    end
  end
  leaky.cases[3].error.message = "E:/repos/demo.nvim/TESTS/a_spec.lua:7: boom"
  leaky.cases[3].error.traceback = "stack traceback:\n\tE:/repos/demo.nvim/TESTS/a_spec.lua:7: in main chunk"
    .. "\nC:\\Users\\bob\\AppData\\Local\\Temp\\lua_9\\x.lua:1"
  good, problems = result.validate(leaky, { forbid = { "bob" } })
  eq(good, false, "an IR with raw paths is invalid")
  has(joined(problems), 'forbidden text "bob"', "the user name is reported")
  has(joined(problems), "user home path", "a raw home path is reported")

  local clean = enc(leaky, { roots = roots, case_insensitive = true })
  ok(not clean:lower():find("bob", 1, true), "no user name in the serialized IR")
  ok(not clean:find("Users", 1, true), "no home path in the serialized IR")
  has(clean, "<REPO>/TESTS/a_spec.lua", "the repo placeholder is in the IR")
  has(clean, "<TMP>/lua_9/x.lua:1", "the temp placeholder is in the IR")
  good, problems = result.validate(json.decode(clean), { forbid = { "bob" } })
  ok(good, "the normalized IR validates, with the user name forbidden: " .. joined(problems))

  -- ---------------------------------------------------------------------------------------------
  -- The validator rejects every broken shape
  ---@param mutate fun(r: any)
  ---@param needle string
  ---@param label string
  local function rejects(mutate, needle, label)
    local r = build()
    mutate(r)
    local valid, probs = result.validate(r)
    eq(valid, false, label .. ": invalid")
    has(joined(probs), needle, label)
  end

  eq(select(1, result.validate(nil)), false, "nil is not a result")
  eq(select(1, result.validate("x")), false, "a string is not a result")
  rejects(function(r)
    r.schema_version = 2
  end, "schema_version", "wrong schema_version")
  rejects(function(r)
    r.cases[1].status = "green"
  end, "is not one of", "status outside the enum")
  rejects(function(r)
    r.cases[1].status = nil
  end, "cases[1].status", "missing status")
  rejects(function(r)
    r.cases[2].id = r.cases[1].id
  end, "duplicate id", "duplicate case id")
  rejects(function(r)
    r.cases[1].id = "other.lua::x"
  end, "must start with '<file>::'", "id not prefixed by its file")
  rejects(function(r)
    r.summary.pass = 5
  end, "summary.pass", "summary does not match the cases")
  rejects(function(r)
    r.summary.weird = 1
  end, "unknown status key", "unknown summary key")
  rejects(function(r)
    r.summary = nil
  end, "summary: must be a table", "missing summary")
  rejects(function(r)
    r.cases[1].assertions = {}
  end, "without a single assertion", "pass without assertions (P4)")
  rejects(function(r)
    r.cases[1].assertions[1].ok = false
  end, "'pass' but an assertion failed", "pass with a failed assertion")
  rejects(function(r)
    r.cases[2].assertions[1].ok = true
    r.cases[2].assertions[2].ok = true
  end, "'fail' without a failed assertion", "fail without a failed assertion")
  rejects(function(r)
    r.cases[3].error = nil
  end, "status 'error' needs", "error without error info")
  rejects(function(r)
    r.cases[1].assertions[1].ok = "yes"
  end, "assertions[1].ok", "assertion ok is not a boolean")
  rejects(function(r)
    r.cases[1].assertions[1].line = 0
  end, "assertions[1].line", "assertion line below 1")
  rejects(function(r)
    r.cases[1].effects.spawned = nil
  end, "effects.spawned", "missing effects list")
  rejects(function(r)
    r.cases[1].effects = nil
  end, "effects: must be a table", "missing effects")
  rejects(function(r)
    r.cases[1].duration_ms = -1
  end, "duration_ms", "negative duration")
  rejects(function(r)
    r.cases[1].tags = "x"
  end, "tags", "tags not a list")
  rejects(function(r)
    r.run.jobs = 0
  end, "run.jobs", "jobs below 1")
  rejects(function(r)
    r.run.argv = "x"
  end, "run.argv", "argv not a list")
  rejects(function(r)
    r.run.id = ""
  end, "run.id", "empty run id")
  rejects(function(r)
    r.run.git = { sha = 1 }
  end, "run.git", "bad git")
  rejects(function(r)
    r.run = nil
  end, "run: must be a table", "missing run")
  rejects(function(r)
    r.cases = "x"
  end, "cases: must be a list", "cases not a list")
  rejects(function(r)
    r.cases[1].file = "/home/someone/x_spec.lua"
    r.cases[1].id = "/home/someone/x_spec.lua::passes"
  end, "user home path", "a raw /home path")

  good, problems = result.validate(leaky, { allow_abs_paths = true })
  ok(good, "allow_abs_paths skips the path check: " .. joined(problems))

  -- every problem is reported, capped
  ---@type any
  local broken = build()
  for i = 1, 150 do
    broken.cases[#broken.cases + 1] = { id = "x" .. i }
  end
  problems = select(2, result.validate(broken))
  ok(#problems <= 100, "the problem list is capped")
  ok(#problems > 5, "but reports many problems at once")
end
