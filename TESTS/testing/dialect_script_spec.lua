-- TESTS/testing/dialect_script_spec.lua -- dialect script: the verdict of a self-running script from its
-- exit code and its output (pickers.nvim / cmdlog.nvim / filetree.nvim style). The child process
-- itself is the driver's; this is the pure judgement.

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
  local script = require("testing.dialect.script")
  local assert_mod = require("testing.core.assert")
  local result = require("testing.core.result")

  ---@param run table
  ---@param opts? table
  ---@return Testing.Result.Case
  local function judge(run, opts)
    return script.build_case(assert_mod.new(), "TESTS/pickers_spec.lua", run, opts)
  end
  ---@param case Testing.Result.Case
  ---@return string[]
  local function failed_msgs(case)
    local out = {}
    for _, rec in ipairs(case.assertions) do
      if not rec.ok then
        out[#out + 1] = rec.msg
      end
    end
    return out
  end

  -- ------------------------------------------------------------------ the summary and the failure lines
  eq(
    script.parse_summary("x\n1001 passed, 0 failed\n"),
    { passed = 1001, failed = 0 },
    "pickers' summary"
  )
  eq(
    script.parse_summary("380 passed, 2 failed, 1 skipped"),
    { passed = 380, failed = 2, skipped = 1 },
    "cmdlog's summary"
  )
  eq(
    script.parse_summary("filetree.nvim smoke: 20 passed, 0 failed"),
    { passed = 20, failed = 0 },
    "with a prefix"
  )
  eq(
    script.parse_summary("3 passed\n7 passed, 1 failed"),
    { passed = 7, failed = 1 },
    "the last summary wins"
  )
  eq(script.parse_summary("pick_item passed through"), {}, "words without a number are no summary")
  eq(script.parse_summary(""), {}, "no output, no summary")
  eq(
    script.failure_lines(
      "ok a\n  FAIL b  -> detail\n[FAIL] c: why\nnot ok 4\nfine FAIL in the middle\r\n"
    ),
    { "FAIL b  -> detail", "[FAIL] c: why", "not ok 4" },
    "failure lines in every fleet form, trimmed, CRLF tolerated"
  )

  -- ------------------------------------------------------------------ verdicts
  local case = judge({ code = 0, stdout = "ok a\n1001 passed, 0 failed\n", stderr = "" })
  eq(case.status, "pass", "exit 0 and a clean summary: pass")
  eq(case.id, "TESTS/pickers_spec.lua::pickers_spec.lua", "one case per script, id <rel>::<file>")
  has(case.assertions[1].msg, "1001 checks passed", "the summary is the assertion")

  case = judge({ code = 0, stdout = "all good\n", stderr = "" })
  eq(case.status, "pass", "exit 0 and no summary at all: the exit code is the verdict")
  eq(case.assertions[1].kind, "exit", "recorded as such")

  case =
    judge({ code = 0, stdout = "ok a\n  FAIL b  -> detail\n3 passed, 1 failed\n", stderr = "" })
  eq(case.status, "fail", "exit 0 with a failure line is still red (a script that forgot os.exit)")
  eq(failed_msgs(case), { "FAIL b  -> detail" }, "with the line as the assertion")

  case = judge({ code = 0, stdout = "3 passed, 2 failed\n", stderr = "" })
  eq(case.status, "fail", "exit 0 with `2 failed` in the summary is red")
  has(failed_msgs(case)[1], "summary says 2 failed", "naming it")

  case = judge({ code = 1, stdout = "  FAIL one\n  FAIL two\n2 passed, 2 failed\n", stderr = "" })
  eq(case.status, "fail", "exit 1 with failure lines: fail")
  eq(failed_msgs(case), { "FAIL one", "FAIL two" }, "each line is a failed assertion")

  case = judge({ code = 1, stdout = "", stderr = "something odd\nmore\n" })
  eq(case.status, "fail", "exit 1 with nothing recognisable: fail")
  eq(
    failed_msgs(case),
    { "exit code 1: something odd" },
    "naming the exit code and the first stderr line"
  )

  case = judge({
    code = 1,
    stdout = "",
    stderr = "E5113: Error while calling lua chunk: x.lua:3: attempt to index nil\nstack traceback:\n",
  })
  eq(case.status, "error", "a Lua error is an error, not a failed assertion")
  has(case.error.message, "E5113", "with its message")

  case = judge({ code = 2, stdout = "ok\nFAIL x\n", stderr = "" })
  has(case.notes[1], "exit code 2", "an exit code other than 0/1 with failure lines is noted")

  case = judge({ code = 139, stdout = "", stderr = "" })
  eq(case.status, "crash", "exit 139 (segfault) is a crash")
  case = judge({ code = -1073741819, stdout = "", stderr = "" })
  eq(case.status, "crash", "so is a Windows access violation")
  case = judge({ code = 3, crashed = true })
  eq(case.status, "crash", "and what the driver flags as crashed")
  case = judge({ timed_out = true, timeout_ms = 5000, code = nil })
  eq(case.status, "timeout", "a killed script is a timeout")
  has(case.error.message, "5000 ms", "naming the deadline")
  case = judge({ code = nil, stdout = "", stderr = "" })
  eq(case.status, "error", "no exit code at all is an error")

  -- zero checks: the assertion policy and the skip convention apply
  case = judge({ code = 0, stdout = "0 passed, 0 failed\n" })
  eq(case.status, "fail", "a summary of 0 passed asserted nothing: fail")
  case = judge({ code = 0, stdout = "0 passed, 0 failed\n" }, { assertions = "warn" })
  eq(case.status, "pass", "assertions = warn: pass with a warning")
  case = judge({
    code = 0,
    stdout = "skip  everything needs telescope\n0 passed, 0 failed, 1 skipped\n",
  })
  eq(case.status, "skip", "a printed skip line and no checks: skip")
  eq(case.notes[1], "the script skipped 1 check(s)", "the skipped count is a note")

  -- the case lands in a valid IR
  local told
  case = judge({ code = 0, stdout = "5 passed, 0 failed\n" }, {
    on_case = function(c)
      told = c
    end,
  })
  ok(told == case, "on_case is told")
  local valid, problems = result.validate({
    schema_version = 1,
    run = result.new_run({
      id = "i",
      root = "<REPO>",
      project_key = "k",
      nvim = "0.12",
      os = "windows",
    }),
    cases = { case },
    summary = result.summarize({ case }),
  })
  eq(problems, {}, "a script case validates")
  ok(valid, "valid")
  for _, status in ipairs({ "timeout", "crash", "error" }) do
    local c = judge({
      timed_out = status == "timeout",
      crashed = status == "crash",
      code = status == "error" and nil or 1,
    })
    ok(
      result.validate({
        schema_version = 1,
        run = result.new_run({
          id = "i",
          root = "<REPO>",
          project_key = "k",
          nvim = "0.12",
          os = "windows",
        }),
        cases = { c },
        summary = result.summarize({ c }),
      }),
      status .. " case validates"
    )
  end
end
