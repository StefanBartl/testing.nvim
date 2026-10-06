-- TESTS/testing/guard_window_timeout_spec.lua -- the guard layer's snapshot at the start of a case belongs to the
-- runner: a (persistent) case deadline of the spec must not cut it off ("guard state: snapshot failed:
-- testing: timeout: case exceeded ... ms"), and the time it takes is not the next case's.

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
  local inproc = require("testing.run.inproc")
  local guards = require("testing.run.guards")

  ---A guard layer whose snapshot (`begin_case`) is slow from the second case on.
  local begun = 0
  local mod = {
    install = function()
      local h = {}
      function h:begin_case()
        begun = begun + 1
        if begun >= 2 then
          local until_ = vim.uv.hrtime() + 250 * 1e6
          while vim.uv.hrtime() < until_ do
            -- busy: the count hook of the timeout guard gets its chances
          end
        end
      end
      function h:end_case()
        return { findings = {}, effects = {} }
      end
      function h:collect()
        return { notes = {} }
      end
      function h:uninstall()
        return {}
      end
      return h
    end,
  }

  local root = S.new_root()
  local file = S.project(root, {
    ["TESTS/a_spec.lua"] = 'describe("d", function()\n  it("one", function() assert.is_true(true) end)\n  it("two", function() assert.is_true(true) end)\nend)\n',
  }, { "TESTS/a_spec.lua" }, "busted")[1]

  local session = guards.install({}, mod)
  local rep = inproc.run({
    root = root,
    files = { file },
    guard_session = session,
    timeouts = { case_ms = 100 },
  })
  session:uninstall()
  eq(session.error, nil, "the slow snapshot was not cut off by the case deadline")
  eq(
    { rep.result.cases[1].status, rep.result.cases[2].status },
    { "pass", "pass" },
    "and its time was not charged to the case"
  )
  eq(begun, 2, "the layer opened a window per case")
end
