-- TESTS/testing/na_case_spec.lua -- the n/a convention (testing.policy): a case that prints a line starting with `n/a`
-- does not apply here (a platform, an optional tool). Without assertions it is a `skip` that does NOT keep the run from
-- green; with assertions before the line it stays `pass`. Both are counted and shown with their reason, carried in the
-- IR as `case.na`, and red under `--strict`. The honest form of `if not windows then return end` (rule NEW-43).

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      ("%s: %q found in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end

  local policy = require("testing.policy")
  local result = require("testing.core.result")
  local verdict = require("testing.report.verdict")

  -- ------------------------------------------------------------------ n/a lines
  for _, line in ipairs({
    "n/a  needs Windows",
    "  N/A: tesseract is not installed",
    "[n/a] no nvim_ui_send",
    "n/a",
  }) do
    eq(policy.is_na_line(line), true, ("%q is an n/a line"):format(line))
  end
  for _, line in ipairs({ "", "n/ab", "na  needs Windows", "it is n/a here", "skip  windows" }) do
    eq(policy.is_na_line(line), false, ("%q is not an n/a line"):format(line))
  end
  eq(policy.is_na_line(nil), false, "nil is not")
  eq(
    policy.na_reason({ "a", "  n/a  windows only", "n/a later" }),
    "n/a  windows only",
    "the first, trimmed"
  )
  eq(policy.na_reason({ "skip  x" }), nil, "a skip line is not one")

  -- ------------------------------------------------------------------ apply on a finished case
  local function case_with(assertions, status)
    local c = result.new_case({ file = "TESTS/x_spec.lua", name = "x" })
    c.assertions = assertions
    c.status = status
    return c
  end
  local none =
    case_with({ { ok = false, kind = "no_assertions", msg = "case made no assertions" } }, "fail")
  local _, what = policy.apply(none, { printed = { "n/a  needs Windows" } })
  eq(what, "na", "no assertions and an n/a line: changed")
  eq(none.status, "skip", "it is a skip")
  eq(none.na, "n/a  needs Windows", "with the reason in case.na")
  eq(none.assertions, {}, "the synthetic failure is gone")

  local asserted = case_with({ { ok = true, kind = "ok", msg = "a check" } }, "pass")
  _, what = policy.apply(asserted, { printed = { "n/a  the rest needs tesseract" } })
  eq(what, "na", "asserted, then an n/a line: changed")
  eq(asserted.status, "pass", "the checks it made stand: still a pass")
  eq(asserted.na, "n/a  the rest needs tesseract", "and it carries the reason")

  local failed = case_with({ { ok = false, kind = "ok", msg = "a check" } }, "fail")
  _, what = policy.apply(failed, { printed = { "n/a  needs Windows" } })
  eq(what, nil, "a failed case is never turned into n/a")
  eq(failed.status, "fail", "it stays red")
  eq(failed.na, nil, "and carries no n/a")

  local both =
    case_with({ { ok = false, kind = "no_assertions", msg = "case made no assertions" } }, "fail")
  policy.apply(both, { printed = { "skip  later", "n/a  needs Windows" } })
  eq(both.na, "n/a  needs Windows", "n/a wins over a skip line of the same case")

  -- ------------------------------------------------------------------ counts and verdict
  local res = {
    cases = {
      { status = "pass" },
      { status = "skip", na = "n/a  a" },
      { status = "pass", na = "n/a  b" },
      { status = "skip", reason = "skip  c" },
    },
  }
  local skipped, na = result.skip_counts(res)
  eq({ skipped, na }, { 1, 2 }, "skip_counts: one plain skip, two n/a")
  local v = verdict.build({
    exit_code = 0,
    files_total = 1,
    files_selected = 1,
    files_cached = 0,
    cases_total = 3,
    cases_skipped = 0,
    cases_na = 2,
  })
  eq(v.kind, "green", "n/a alone keeps the verdict green")
  has(verdict.counts(v), "2 case(s) n/a here", "the shared count line names them")
  local d =
    verdict.from_result({ cases = { { status = "pass" }, { status = "skip", na = "n/a  a" } } })
  eq(
    { d.kind, d.cases.skipped, d.cases.na },
    { "green", 0, 1 },
    "a verdict from the cases alone counts the same"
  )

  -- ------------------------------------------------------------------ the run driver end to end
  local cli = require("testing.cli")
  local root = vim.fs.normalize(vim.fn.tempname())
  local state = root .. "-state"
  vim.fn.mkdir(root .. "/TESTS", "p")
  vim.fn.mkdir(state, "p")
  local function put(rel, text)
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  put("TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  -- the whole case does not apply (casedesk: `if not windows then return end` in an `it`)
  put("TESTS/win_spec.lua", "return function(H)\n  print('n/a  needs Windows')\nend\n")
  -- the rest of the file does not apply (images.nvim: asserts, then `if not tool then return end`)
  put(
    "TESTS/part_spec.lua",
    "return function(H)\n  H.ok(true, 'what can be checked')\n  print('n/a  the rest needs tesseract')\nend\n"
  )
  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ root }, argv), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
    })
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end
  local function ir_of(path)
    local fh = assert(io.open(path, "rb"))
    local text = fh:read("a")
    fh:close()
    return vim.json.decode(text)
  end

  for _, mode in ipairs({ "none", "file" }) do
    local jpath = root .. "-" .. mode .. ".json"
    local r = run({ "--isolated", mode, "--json", jpath })
    local tag = "isolated " .. mode .. ": "
    eq(r.code, 0, tag .. "n/a cases keep the run green: exit 0\n" .. r.out .. r.err)
    eq(r.last, "TESTING_OK", tag .. "and the sentinel is printed")
    has(r.out, "verdict: green", tag .. "the verdict is green, not green-partial")
    has(r.out, "2 case(s) n/a here", tag .. "the count is shown")
    has(r.out, "n/a here: n/a  needs Windows", tag .. "the reason of the skipped one")
    has(r.out, "n/a here: n/a  the rest needs tesseract", tag .. "the reason of the passing one")
    lacks(r.out, "a skip is never green", tag .. "no skip reason")
    local ir = ir_of(jpath)
    local by_file = {}
    for _, c in ipairs(ir.cases) do
      by_file[c.file] = c
    end
    eq(
      { by_file["TESTS/win_spec.lua"].status, by_file["TESTS/win_spec.lua"].na },
      { "skip", "n/a  needs Windows" },
      tag .. "the IR: a skip with na"
    )
    eq(
      { by_file["TESTS/part_spec.lua"].status, by_file["TESTS/part_spec.lua"].na },
      { "pass", "n/a  the rest needs tesseract" },
      tag .. "the IR: a pass with na"
    )
    eq(ir.run.verdict.cases.na, 2, tag .. "the IR verdict counts them")
    eq({ result.validate(ir) }, { true, {} }, tag .. "the IR stays valid")
    vim.fn.delete(jpath)

    local strict = run({ "--isolated", mode, "--strict" })
    eq(strict.code, 1, tag .. "--strict: a job that must run those checks is red\n" .. strict.out)
    ok(strict.last ~= "TESTING_OK", tag .. "--strict: no sentinel")
  end

  -- the cache never stores an n/a case: a replay would turn a `--strict` red into a green (strict is part of the key),
  -- and would keep saying "n/a" after the tool is installed
  for i = 1, 2 do
    local cached = run({ "--isolated", "none", "--strict", "--cached" })
    eq(cached.code, 1, ("--strict --cached, run %d: still red\n%s"):format(i, cached.out))
    lacks(
      cached.out,
      "part_spec.lua (cached)",
      ("run %d: the passing n/a case is not replayed"):format(i)
    )
    if i == 2 then
      -- a_spec (a plain pass) comes from the cache; part_spec (a pass with na) ran again
      has(cached.out, "1 from cache, 2 ran", "run 2: only the plain pass was stored")
    end
  end
  local plain_cached = run({ "--isolated", "none", "--cached" })
  has(plain_cached.out, "2 case(s) n/a here", "--cached without --strict: the n/a cases ran again")

  -- a case that turned red after it said n/a (a guard, a timeout) is red, not "does not apply"
  local turned = {
    cases = { { status = "fail", na = "n/a  rest", assertions = {}, notes = {} } },
  }
  result.finalize(turned)
  eq(turned.cases[1].na, nil, "finalize drops na from a red case")
  eq(
    { result.skip_counts({ cases = { { status = "timeout", na = "n/a  x" } } }) },
    { 0, 0 },
    "and it is never counted"
  )
  -- the IR check: na is a string, and only on a pass or a skip
  local vpath = root .. "-validate.json"
  run({ "--isolated", "none", "--json", vpath })
  local vir = ir_of(vpath)
  vim.fn.delete(vpath)
  eq({ result.validate(vir) }, { true, {} }, "validate: the run's IR is valid")
  for _, c in ipairs(vir.cases) do
    if c.file == "TESTS/a_spec.lua" then
      c.na = 3
    end
  end
  has(
    table.concat(select(2, result.validate(vir)), "\n"),
    ".na: must be a string, on a pass or a skip only",
    "validate: a non-string na is refused"
  )

  -- a case that runs other cases in this editor (this spec) is not n/a because of THEIR n/a lines
  local runner_case = result.new_case({ file = "TESTS/runner_spec.lua", name = "runs others" })
  runner_case.assertions = { { ok = true, kind = "ok", msg = "a check" } }
  local guarded = policy.guard({}, function()
    policy.guard({}, function()
      print("n/a  a nested case does not apply")
      local inner = result.new_case({ file = "TESTS/inner_spec.lua", name = "inner" })
      inner.assertions = { { ok = false, kind = "no_assertions", msg = "none" } }
      inner.status = "fail"
      return inner
    end)
    return runner_case
  end)
  eq(guarded.na, nil, "the outer case is not n/a because a nested case printed an n/a line")
  eq(guarded.status, "pass", "and stays a plain pass")

  -- a plain skip still keeps the run from green: n/a did not widen the skip convention
  put("TESTS/skip_spec.lua", "return function(H)\n  print('skip  not ready')\nend\n")
  local partial = run({ "--isolated", "none" })
  eq(partial.code, 0, "a skip: exit 0")
  has(partial.out, "1 case(s) skipped: a skip is never green", "a skip: still partial")
  ok(partial.last ~= "TESTING_OK", "a skip: no sentinel")

  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
end
