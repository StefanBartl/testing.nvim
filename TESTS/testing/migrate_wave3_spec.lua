-- TESTS/testing/migrate_wave3_spec.lua -- what the third migration wave taught the tool:
--   * `env_allow` is not derived from TESTS/run.lua (the old runner goes away with the migration): the old
--     `LIB_NVIM_PATH` override is not proposed any more, a variable a SPEC reads still is,
--   * deleting TESTS/run.lua changes the order the specs run in (its list becomes alphabetical discovery
--     order): the plan says so and suggests `isolated = "file"`, and says nothing when the order is the same.

---@diagnostic disable: missing-fields, param-type-mismatch, need-check-nil

-- @cache-env LIB_NVIM_PATH MY_SPEC_VAR REFS_RUN_VAR
-- (variables of the fixtures this spec writes: their outer values join the key)
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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end
  local migrate = require("testing.migrate")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local fleet_dir = tmp .. "/fleet"

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
  write(fleet_dir .. "/lib.nvim/lua/lib/nvim/notify/init.lua", "return {}\n")

  local HARNESS =
    'local H = {}\nfunction H.eq(a, b, msg)\n  if a ~= b then error("FAIL " .. msg, 2) end\nend\nreturn H\n'
  local SPEC = 'return function(H)\n  H.eq(1, 1, "x")\nend\n'

  ---@param name string
  ---@param run_lua string|nil Text of TESTS/run.lua.
  ---@param spec_extra? string Added to a spec.
  ---@return string root
  local function mk(name, run_lua, spec_extra)
    local root = fleet_dir .. "/" .. name
    write(
      root .. "/lua/" .. name:gsub("%.nvim$", "") .. "/init.lua",
      'return require("lib.nvim.notify")\n'
    )
    write(root .. "/TESTS/harness.lua", HARNESS)
    for _, n in ipairs({ "a", "b", "c" }) do
      write(root .. "/TESTS/" .. n .. "_spec.lua", SPEC .. (n == "a" and spec_extra or ""))
    end
    if run_lua then
      write(root .. "/TESTS/run.lua", run_lua)
    end
    return root
  end

  -- ---------------------------------------------------------------- env_allow from the old runner

  local OLD_RUN = [=[
local lib = os.getenv("LIB_NVIM_PATH")
if lib and lib ~= "" then vim.opt.rtp:prepend(lib) end
local specs = { "a_spec.lua", "b_spec.lua", "c_spec.lua" }
for _, s in ipairs(specs) do dofile("TESTS/" .. s) end
]=]
  local r1 = mk("envold.nvim", OLD_RUN)
  local report1 = migrate.analyze(r1, { fleet_root = fleet_dir })
  eq(report1.env.allow, {}, "an override that only the old run.lua read is not proposed")
  local plan1 = migrate.run(r1, { fleet_root = fleet_dir })
  local cfg_op
  for _, op in ipairs(plan1.ops) do
    if op.path == ".testing.lua" then
      cfg_op = op
    end
  end
  lacks(cfg_op.after, "LIB_NVIM_PATH", ".testing.lua does not carry the old spelling")
  lacks(cfg_op.after, "env_allow", "and has no env_allow at all")

  -- a variable a spec reads stays proposed, whatever its spelling
  local r2 = mk(
    "envspec.nvim",
    OLD_RUN,
    'local _ = os.getenv("LIB_NVIM_PATH") or os.getenv("MY_SPEC_VAR")\n'
  )
  local report2 = migrate.analyze(r2, { fleet_root = fleet_dir })
  eq(report2.env.allow, { "LIB_NVIM_PATH", "MY_SPEC_VAR" }, "what a spec reads is still proposed")
  -- ... also when only run.lua is absent from the picture
  local r3 = mk("envkeep.nvim", nil, 'local _ = os.getenv("MY_SPEC_VAR")\n')
  eq(
    migrate.analyze(r3, { fleet_root = fleet_dir }).env.allow,
    { "MY_SPEC_VAR" },
    "no run.lua: the specs decide"
  )
  -- a run.lua below the spec root (a real test) is not the old runner and is still read
  write(r3 .. "/TESTS/refs/run.lua", 'local _ = os.getenv("REFS_RUN_VAR")\n')
  eq(
    migrate.analyze(r3, { fleet_root = fleet_dir }).env.allow,
    { "MY_SPEC_VAR", "REFS_RUN_VAR" },
    "TESTS/refs/run.lua is a test, not the old runner"
  )

  -- ---------------------------------------------------------------- the order manifest of run.lua

  local function order_risks(report)
    local out = {}
    for _, r in ipairs(report.risks) do
      if r:find("alphabetical", 1, true) then
        out[#out + 1] = r
      end
    end
    return out
  end

  -- a list that is NOT alphabetical (like sessions: statusline before core, init last)
  local shuffled = mk(
    "ordered.nvim",
    'local specs = { "c_spec.lua", "a_spec.lua", "b_spec.lua" }\nfor _, s in ipairs(specs) do dofile("TESTS/" .. s) end\n'
  )
  local rep = migrate.analyze(shuffled, { fleet_root = fleet_dir })
  eq(rep.order.differs, true, "the listed order differs from discovery order")
  eq(rep.order.first, "TESTS/c_spec.lua", "c_spec.lua is the first that is out of place")
  eq(rep.order.second, "TESTS/a_spec.lua", "it runs before a_spec.lua")
  local risks = order_risks(rep)
  eq(#risks, 1, "one risk names the hazard: " .. vim.inspect(risks))
  has(risks[1], "deleting run.lua makes the order alphabetical", "it says what deleting does")
  has(risks[1], 'isolated = "file"', "and suggests isolated = file")
  has(risks[1], "keep run.lua", "or keeping run.lua")
  has(risks[1], "TESTS/c_spec.lua", "naming the specs")
  local plan = migrate.run(shuffled, { fleet_root = fleet_dir })
  ok(
    vim.iter(plan.risks):any(function(r)
      return r:find("alphabetical", 1, true) ~= nil
    end),
    "the plan carries the risk"
  )

  -- the same set in alphabetical order: nothing to say
  local sorted = mk(
    "sorted.nvim",
    'local specs = { "a_spec.lua", "b_spec.lua", "c_spec.lua" }\nfor _, s in ipairs(specs) do dofile("TESTS/" .. s) end\n'
  )
  local rep2s = migrate.analyze(sorted, { fleet_root = fleet_dir })
  eq(rep2s.order.differs, false, "alphabetical list: no hazard")
  eq(order_risks(rep2s), {}, "and no risk")
  -- no run.lua at all: nothing is removed, nothing to say
  local none = mk("norun.nvim", nil)
  eq(
    migrate.analyze(none, { fleet_root = fleet_dir }).order.differs,
    false,
    "no run.lua: no hazard"
  )
  -- a listed spec that is gone does not count as out of place
  local gone = mk(
    "gone.nvim",
    'local specs = { "a_spec.lua", "zz_spec.lua", "b_spec.lua" }\nfor _, s in ipairs(specs) do dofile("TESTS/" .. s) end\n'
  )
  eq(
    migrate.analyze(gone, { fleet_root = fleet_dir }).order.differs,
    false,
    "a missing name is skipped"
  )

  vim.fn.delete(tmp, "rf")
end
