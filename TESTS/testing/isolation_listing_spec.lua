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

  -- the listings of several files run side by side (up to `jobs`), not one editor after the other: the start of an editor
  -- and the load of the file are the cost, and the cases themselves only start once their file is listed
  local real_child = require("testing.child")
  local many_root = S.new_root()
  local many_files, many_rels = {}, {}
  for k = 1, 6 do
    local rel = ("TESTS/f%d_spec.lua"):format(k)
    many_rels[#many_rels + 1] = rel
    many_files[rel] = ('describe("f%d", function()\n  it("a", function() assert.is_true(true) end)\nend)\n'):format(
      k
    )
  end
  local many = S.project(many_root, many_files, many_rels, "busted")
  for _, jobs in ipairs({ 1, 3 }) do
    local active, peak, listed = 0, 0, 0
    local listing_plans = {}
    local spy = setmetatable({
      build = function(spec)
        local plan = real_child.build(spec)
        if spec.kind == "list" then
          listing_plans[plan] = true
        end
        return plan
      end,
      spawn = function(plan, on_exit, ...)
        if not listing_plans[plan] then
          return real_child.spawn(plan, on_exit, ...)
        end
        listed = listed + 1
        active = active + 1
        peak = math.max(peak, active)
        return real_child.spawn(plan, function(...)
          active = active - 1
          return on_exit(...)
        end, ...)
      end,
    }, { __index = real_child })
    local rep = S.run(many_root, many, { options = case_options({ jobs = jobs }), child = spy })
    eq(rep.exit_code, 0, ("jobs=%d: green"):format(jobs))
    eq(#rep.result.cases, 6, ("jobs=%d: every case of every file ran"):format(jobs))
    eq(listed, 6, ("jobs=%d: one listing per file"):format(jobs))
    if jobs == 1 then
      eq(peak, 1, "jobs=1: one listing child at a time")
    else
      ok(peak >= 2, ("jobs=%d: listings overlap (peak %d)"):format(jobs, peak))
      ok(peak <= jobs, ("jobs=%d: but never more than --jobs (peak %d)"):format(jobs, peak))
    end
  end

  S.cleanup()
end
