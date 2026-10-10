-- TESTS/testing/child_wrapped_spec.lua -- the pcall rule (testing.core.protected) in REAL child editors: the
-- dialect hands the spec file to `run_case` in a child editor per file, in a warm pool member and in a child
-- per case, as it does in-process. A framework of another file that runs the spec under its own pcall is not
-- the spec's pcall: the failed check must be RECORDED. If the spec file did not reach the child's case, the
-- lowest-frame fallback would still answer a plain question, but the check would be raised into the
-- framework's pcall and vanish (a false green). So the fixtures here are the ones where the foreign
-- framework's closure IS the case body (`return support.spec_swallow(function(H) ... end)`).

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local options_mod = require("testing.run.options")
  local project = require("testing.config.project")
  local fx = dir .. "/fixtures"

  ---@param path string
  ---@param mark string
  ---@return integer
  local function line_of(path, mark)
    for i, line in ipairs(vim.fn.readfile(path)) do
      if line:find("MARK:" .. mark, 1, true) then
        return i
      end
    end
    error("mark not found: " .. mark)
  end

  local H_SWALLOW = fx .. "/h/h_wrap_swallow.fixture.lua"
  local A_SWALLOW = fx .. "/a_wrap_swallow.fixture.lua"
  local B_WRAP = fx .. "/busted_wrap.fixture.lua"
  local H_ASK = fx .. "/h/h_wrap_ask.fixture.lua"
  local HARNESS = fx .. "/h/harness.lua"

  ---@return table[]
  local function entries()
    return {
      { path = H_ASK, rel = "TESTS/h_wrap_ask_spec.lua", dialect = "h", harness = HARNESS },
      { path = H_SWALLOW, rel = "TESTS/h_wrap_swallow_spec.lua", dialect = "h", harness = HARNESS },
      { path = A_SWALLOW, rel = "TESTS/a_wrap_swallow_spec.lua", dialect = "a" },
      { path = B_WRAP, rel = "TESTS/busted_wrap_spec.lua", dialect = "busted" },
    }
  end

  ---@param report table
  ---@return table<string, Testing.Result.Case>
  local function by_id(report)
    local map = {}
    for _, c in ipairs(report.result.cases) do
      map[c.id] = c
    end
    return map
  end

  ---@param case Testing.Result.Case|nil
  ---@return integer passed
  ---@return table[] failed
  local function split(case)
    local passed, failed = 0, {}
    for _, rec in ipairs(case and case.assertions or {}) do
      if rec.ok then
        passed = passed + 1
      else
        failed[#failed + 1] = rec
      end
    end
    return passed, failed
  end

  ---The same checks in every process model.
  ---@param report table
  ---@param label string
  local function check(report, label)
    local map = by_id(report)
    eq(#report.result.cases, 5, label .. ": the four files report five cases")

    local asked = map["TESTS/h_wrap_ask_spec.lua::h_wrap_ask_spec.lua"]
    eq(asked and asked.status, "pass", label .. ": a question the spec asks itself is answered (h)")

    for _, w in ipairs({
      { "h", "TESTS/h_wrap_swallow_spec.lua::h_wrap_swallow_spec.lua", H_SWALLOW },
      { "a", "TESTS/a_wrap_swallow_spec.lua::a_wrap_swallow_spec.lua", A_SWALLOW },
    }) do
      local case = map[w[2]]
      eq(
        case and case.status,
        "fail",
        label .. ": the framework's pcall swallows nothing (" .. w[1] .. ")"
      )
      local passed, failed = split(case)
      eq(#failed, 1, label .. ": the failed check is recorded (" .. w[1] .. ")")
      eq(passed, 2, label .. ": the two checks that hold are recorded (" .. w[1] .. ")")
      eq(
        failed[1] and failed[1].line,
        line_of(w[3], "w1"),
        label .. ": with the spec's line (" .. w[1] .. ")"
      )
    end

    local swallowed = map["TESTS/busted_wrap_spec.lua::wrapped::swallowed by the framework"]
    eq(
      swallowed and swallowed.status,
      "fail",
      label .. ": the framework's pcall swallows nothing (busted)"
    )
    local _, bfailed = split(swallowed)
    -- the check itself, not the "case made no assertions" the policy would add if the check were lost
    eq(
      bfailed[1] and bfailed[1].kind,
      "eq",
      label .. ": the failed check is recorded, not a case without assertions (busted)"
    )
    eq(#bfailed, 1, label .. ": one failure (busted)")
    eq(
      bfailed[1] and bfailed[1].line,
      line_of(B_WRAP, "w1"),
      label .. ": with the spec's line (busted)"
    )
    local itself = map["TESTS/busted_wrap_spec.lua::wrapped::asks itself"]
    eq(
      itself and itself.status,
      "pass",
      label .. ": a question the spec asks itself is answered (busted)"
    )
  end

  -- ================================================================== a child editor per file
  local root = S.new_root()
  check(S.run(root, entries(), { options = { isolated = "file" } }), "child per file")

  -- ================================================================== a warm pool member that runs several files
  local pool = options_mod.of({
    project = { isolated = "file", pool = { reuse = true, size = 2 } },
    args = { jobs = 2 },
  })
  pool.host_given = false
  check(S.run(root, entries(), { options = pool }), "warm pool")

  -- ================================================================== a child editor per case (busted files; the others per file)
  local per_case = options_mod.of({ project = project.validate({ isolated = "case" }) })
  per_case.host_given = false
  check(S.run(root, entries(), { options = per_case }), "child per case")

  S.cleanup()
end
