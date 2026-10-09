-- TESTS/testing/config_m5_spec.lua -- the M5 keys of `.testing.lua`: shard, watch, budget and `jobs = "auto"`:
-- defaults, valid values, and one warning that names the key for every invalid one (the default stays).

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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local project = require("testing.config.project")
  local defaults = require("testing.config.DEFAULTS").project

  -- defaults: shard has no `durations` (opt-in, LUA-86), everything else is a plain default
  eq(defaults.shard, { balance = "size" }, "shard default")
  eq(defaults.watch, { debounce_ms = 150, poll_ms = 1000, max_wait_ms = 0 }, "watch default")
  eq(defaults.budget, { factor = 2.0, baseline = "TESTS/bench/baseline.json" }, "budget default")
  local cfg, problems = project.validate(nil)
  eq(problems, {}, "no file: no problem")
  eq(cfg.budget.factor, 2.0, "the effective budget factor")
  eq(cfg.jobs, 1, "jobs stays 1 by default (auto is opt-in)")

  -- valid values
  cfg, problems = project.validate({
    jobs = "auto",
    shard = { balance = "history", durations = "TESTS/durations.json" },
    watch = { debounce_ms = 300, poll_ms = 2500 },
    budget = { factor = 1.25, baseline = "bench/base.json" },
  })
  eq(problems, {}, "valid M5 keys: no warning")
  eq(cfg.jobs, "auto", 'jobs = "auto" is kept for the CLI to resolve')
  eq(cfg.shard, { balance = "history", durations = "TESTS/durations.json" }, "shard")
  eq(cfg.watch, { debounce_ms = 300, poll_ms = 2500, max_wait_ms = 0 }, "watch")
  eq(cfg.budget, { factor = 1.25, baseline = "bench/base.json" }, "budget")
  for _, balance in ipairs({ "size", "count", "hash", "history" }) do
    local _, p = project.validate({ shard = { balance = balance } })
    eq(p, {}, "shard.balance = " .. balance)
  end
  local _, p = project.validate({ jobs = 8 })
  eq(p, {}, "a number for jobs still works")

  -- invalid: one warning that names the key, the default stays
  local function bad(raw, key, field, expected_default)
    local c, probs = project.validate(raw)
    eq(#probs, 1, ("%s: exactly one warning (%s)"):format(key, vim.inspect(probs)))
    has(probs[1], ("'%s'"):format(key), key .. ": the warning names the key")
    local value = c
    for part in field:gmatch("[^.]+") do
      value = value and value[part]
    end
    eq(value, expected_default, key .. ": the default stays")
  end
  bad({ jobs = "many" }, "jobs", "jobs", 1)
  bad({ jobs = 0 }, "jobs", "jobs", 1)
  bad({ jobs = 257 }, "jobs", "jobs", 1)
  bad({ shard = { balance = "random" } }, "shard.balance", "shard.balance", "size")
  bad({ shard = { balance = 3 } }, "shard.balance", "shard.balance", "size")
  bad({ shard = { durations = "../outside.json" } }, "shard.durations", "shard.durations", nil)
  bad({ shard = { durations = "/abs/path.json" } }, "shard.durations", "shard.durations", nil)
  bad({ shard = { durations = "" } }, "shard.durations", "shard.durations", nil)
  bad({ watch = { debounce_ms = 0 } }, "watch.debounce_ms", "watch.debounce_ms", 150)
  bad({ watch = { debounce_ms = 1.5 } }, "watch.debounce_ms", "watch.debounce_ms", 150)
  bad({ watch = { debounce_ms = "fast" } }, "watch.debounce_ms", "watch.debounce_ms", 150)
  bad({ watch = { poll_ms = -5 } }, "watch.poll_ms", "watch.poll_ms", 1000)
  bad({ watch = { max_wait_ms = -1 } }, "watch.max_wait_ms", "watch.max_wait_ms", 0)
  bad({ watch = { max_wait_ms = "5s" } }, "watch.max_wait_ms", "watch.max_wait_ms", 0)
  cfg = project.validate({ watch = { max_wait_ms = 8000 } })
  eq(cfg.watch.max_wait_ms, 8000, "watch.max_wait_ms: a positive value is kept")
  cfg = project.validate({ watch = { max_wait_ms = 0 } })
  eq(cfg.watch.max_wait_ms, 0, "watch.max_wait_ms: 0 (off) is valid")
  bad({ budget = { factor = 0.5 } }, "budget.factor", "budget.factor", 2.0)
  bad({ budget = { factor = 1001 } }, "budget.factor", "budget.factor", 2.0)
  bad({ budget = { factor = "2" } }, "budget.factor", "budget.factor", 2.0)
  bad(
    { budget = { baseline = "../b.json" } },
    "budget.baseline",
    "budget.baseline",
    "TESTS/bench/baseline.json"
  )
  bad(
    { budget = { baseline = 7 } },
    "budget.baseline",
    "budget.baseline",
    "TESTS/bench/baseline.json"
  )
  bad({ shard = 3 }, "shard", "shard.balance", "size")
  bad({ watch = "yes" }, "watch", "watch.debounce_ms", 150)
  bad({ budget = { slack = 1 } }, "budget.slack", "budget.factor", 2.0)
  bad({ shard = { weights = {} } }, "shard.weights", "shard.balance", "size")

  -- the defaults of one validate call are not shared with the next (ERR-51: deep copies)
  local c1 = project.validate({ shard = { balance = "count" } })
  ---@cast c1 table
  c1.shard.balance = "mutated"
  c1.watch.debounce_ms = 1
  local c2 = project.validate(nil)
  eq(c2.shard.balance, "size", "validate copies the defaults deeply (shard)")
  eq(c2.watch.debounce_ms, 150, "validate copies the defaults deeply (watch)")
  eq(defaults.shard.balance, "size", "and DEFAULTS itself is untouched")

  -- from a file on disk (the whole load path): `.testing.lua` with the keys
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local f = assert(io.open(root .. "/.testing.lua", "wb"))
  f:write('return { jobs = "auto", watch = { debounce_ms = 90 }, budget = { factor = 4 } }\n')
  f:close()
  local loaded = project.load(root)
  eq(loaded.error, nil, "loads")
  eq(loaded.problems, {}, "without warnings")
  eq(loaded.config.jobs, "auto", "jobs")
  eq(
    loaded.config.watch,
    { debounce_ms = 90, poll_ms = 1000, max_wait_ms = 0 },
    "a partial group keeps the other defaults"
  )
  eq(loaded.config.budget.factor, 4, "budget.factor")
  eq(loaded.config.budget.baseline, "TESTS/bench/baseline.json", "budget.baseline default")
  vim.fn.delete(root, "rf")
end
