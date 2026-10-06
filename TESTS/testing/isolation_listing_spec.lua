-- TESTS/testing/isolation_listing_spec.lua -- `isolated = "case"` lists the cases of a file in a THROWAWAY
-- child: the top-level code of a spec (describe bodies) neither sees the runner's environment nor
-- leaves anything behind in the runner, and a hang at load time is cut off by the file timeout.

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
  local options = require("testing.run.options")
  local project = require("testing.config.project")

  local function case_options(over)
    local o = options.of({ project = project.validate({ isolated = "case" }) })
    return vim.tbl_extend("force", o, over or {})
  end

  local probe = vim.fs.normalize(vim.fn.tempname()) .. "-listing-probe.txt"
  local root = S.new_root()
  local body = ([[
local f = assert(io.open(%q, "ab"))
f:write("env=", tostring(os.getenv("TESTING_LISTING_SECRET")), ";")
f:write("global=", tostring(rawget(_G, "listing_marker")), ";\n")
f:close()
rawset(_G, "listing_marker", "set at load time")
describe("listing", function()
  it("one", function() assert.is_true(true) end)
  it("two", function() assert.is_true(true) end)
end)
]]):format(probe)
  local entries = S.project(root, { ["TESTS/a_spec.lua"] = body }, { "TESTS/a_spec.lua" }, "busted")

  vim.fn.setenv("TESTING_LISTING_SECRET", "hunter2")
  local report = S.run(root, entries, { options = case_options() })
  ---@diagnostic disable-next-line: param-type-mismatch
  vim.fn.setenv("TESTING_LISTING_SECRET", vim.NIL)

  eq(report.exit_code, 0, "green")
  eq(#report.result.cases, 2, "both cases ran")
  local text = S.slurp(probe) or ""
  ok(text ~= "", "the load-time code ran (probe written)")
  ok(
    not text:find("hunter2", 1, true),
    "the listing did not see the runner's secret environment: " .. text
  )
  ok(
    not text:find("set at load time", 1, true),
    "nor a global left behind by an earlier load: " .. text
  )
  eq(rawget(_G, "listing_marker"), nil, "the runner's own globals stay untouched")
  pcall(os.remove, probe)

  -- a describe body that never returns is cut off by the file timeout (not a hung run)
  local hang_root = S.new_root()
  local hang = S.project(hang_root, {
    ["TESTS/hang_spec.lua"] = 'while true do end\ndescribe("x", function() it("y", function() end) end)\n',
  }, { "TESTS/hang_spec.lua" }, "busted")
  local t0 = vim.uv.hrtime()
  local hung = S.run(hang_root, hang, {
    options = case_options(),
    timeouts = { file_ms = 1500, case_ms = 1500 },
  })
  local took = (vim.uv.hrtime() - t0) / 1e6
  eq(hung.exit_code, 1, "a file that hangs at load time is red")
  ok(took < 30000, ("and the run did not hang (%d ms)"):format(took))
  local msg = hung.result.cases[1] and (hung.result.cases[1].message or "") or ""
  ok(
    hung.result.cases[1] ~= nil and hung.result.cases[1].status == "error",
    "reported as an error case: " .. msg
  )

  S.cleanup()
end
