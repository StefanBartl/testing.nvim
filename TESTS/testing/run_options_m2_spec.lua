-- TESTS/testing/run_options_m2_spec.lua -- the M2 keys as the OTHER layers read them: `options.of` (flags win
-- over `.testing.lua`, garbage degrades), the one adapter `options.guard_config` (what the guard layer is
-- configured with), `isolation_of` (case / soft / the degrade note).

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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local options = require("testing.run.options")
  local args_mod = require("testing.args")
  local project = require("testing.config.project")

  local function plan(project_over, argv)
    local cfg = project.validate(project_over or {})
    return { project = cfg, args = argv and assert(args_mod.parse(argv)) or nil }
  end

  -- ------------------------------------------------------------------ defaults
  local d = options.of({})
  eq(d.guards.fs, "warn", "default guards.fs")
  eq(d.guards.scheduled_error, "error", "default guards.scheduled_error")
  eq(d.guards.prompt, "error", "default guards.prompt")
  eq(d.guards.process_net, "off", "default guards.process_net")
  eq(d.guards.clock, false, "default guards.clock")
  eq(d.guard_allow, { fs = {}, spawn = {}, network = {} }, "default guard_allow")
  eq(d.pool, { size = 0, reuse = false }, "default pool")
  eq({ d.determinism, d.trace, d.strict }, { true, true, false }, "determinism, trace, strict")
  eq(d.soft_keep, {}, "default soft_keep")
  eq(options.of(plan()).guards, d.guards, "a validated empty config gives the same")

  -- ------------------------------------------------------------------ config, then flags on top
  local c = options.of(plan({
    isolated = "case",
    soft_keep = { "a.b", "c*" },
    guards = { fs = "error", state = "off", clock = true },
    guard_allow = { fs = { "/x" }, spawn = { "git" }, network = { "h1" } },
    pool = { size = 3, reuse = true },
    determinism = false,
    trace = false,
  }))
  eq(c.isolated, "case", "config isolated = case")
  eq(c.soft_keep, { "a.b", "c*" }, "config soft_keep")
  eq({ c.guards.fs, c.guards.state, c.guards.clock }, { "error", "off", true }, "config guards")
  eq(c.guards.prompt, "error", "an unnamed guard keeps its default")
  eq(c.guard_allow, { fs = { "/x" }, spawn = { "git" }, network = { "h1" } }, "config guard_allow")
  eq(c.pool, { size = 3, reuse = true }, "config pool")
  eq({ c.determinism, c.trace }, { false, false }, "config determinism and trace")

  local f = options.of(plan({
    isolated = "case",
    guards = { fs = "error", state = "off", clock = true },
    guard_allow = { fs = { "/x" }, spawn = { "git" } },
    pool = { size = 3, reuse = true },
  }, {
    "r",
    "--isolated",
    "soft",
    "--guard",
    "fs=warn",
    "--guard",
    "process-net=error",
    "--guard",
    "clock=off",
    "--allow-fs",
    "/y",
    "--allow-spawn",
    "git",
    "--allow-network",
    "h2",
    "--pool-size",
    "8",
    "--no-pool-reuse",
    "--no-determinism",
    "--no-trace",
    "--strict",
  }))
  eq(f.isolated, "soft", "--isolated wins")
  eq(f.guards.fs, "warn", "--guard fs=warn wins over the config")
  eq(f.guards.state, "off", "a guard the flags do not name keeps the config")
  eq(f.guards.process_net, "error", "--guard process-net=error (dash spelling)")
  eq(f.guards.clock, false, "--guard clock=off")
  eq(f.guard_allow.fs, { "/x", "/y" }, "allow lists add up (config, then flags)")
  eq(f.guard_allow.spawn, { "git" }, "and are de-duplicated")
  eq(f.guard_allow.network, { "h2" }, "network from the flag")
  eq(f.pool, { size = 8, reuse = false }, "--pool-size and --no-pool-reuse win")
  eq({ f.determinism, f.trace, f.strict }, { false, false, true }, "the flags turn the config off")
  local only_cfg_off = options.of(plan({ determinism = false }, { "r" }))
  eq(only_cfg_off.determinism, false, "a flag that is absent leaves the config alone")

  -- garbage in a hand-built plan degrades (never raises)
  local g = options.of({
    project = {
      guards = { fs = "loud", clock = "yes", prompt = 7 },
      guard_allow = { fs = "x", spawn = { 1, "", "ok" } },
      pool = { size = -4, reuse = "y" },
      soft_keep = "nope",
      isolated = "weird",
    },
    args = { guard = { "fs=loud", "nope=warn", "garbage" } },
  })
  eq(g.guards.fs, "warn", "a bad mode keeps the default")
  eq(g.guards.clock, false, "a non-boolean clock keeps the default")
  eq(g.guards.prompt, "error", "a non-string mode keeps the default")
  eq(g.guard_allow, { fs = {}, spawn = { "ok" }, network = {} }, "bad allow entries are dropped")
  eq(g.pool, { size = 0, reuse = false }, "a bad pool degrades")
  eq(g.soft_keep, {}, "a bad soft_keep degrades")
  eq(g.isolated, "auto", "a bad isolated degrades")

  -- ------------------------------------------------------------------ isolation_of
  local case_opts = options.of(plan({ isolated = "case" }))
  local mode, note = options.isolation_of(case_opts, { dialect = "busted" })
  eq({ mode, note }, { "case", nil }, "case: busted is a child per case, no note")
  mode, note = options.isolation_of(case_opts, { dialect = "h" })
  eq(mode, "file", "case: a one-case-per-file dialect gets a child per file")
  has(note, "isolated=case degraded to file", "and says it degraded")
  has(note, "dialect-h", "naming the dialect")
  mode, note = options.isolation_of(case_opts, { dialect = "script" })
  eq({ mode, note }, { "file", nil }, "case: a script is a file in a child anyway, no note")
  eq(options.any_isolated(case_opts, { { dialect = "busted" } }), true, "case needs children")
  eq(options.any_isolated(case_opts, { { dialect = "a" } }), true, "and so does its degrade")
  local soft_opts = options.of(plan({ isolated = "soft" }))
  eq(options.isolation_of(soft_opts, { dialect = "busted" }), "none", "soft: this process")
  eq(
    options.any_isolated(soft_opts, { { dialect = "busted" }, { dialect = "a" } }),
    false,
    "no child"
  )
  eq(options.any_isolated(soft_opts, { { dialect = "script" } }), true, "except for a script")
  eq(options.is_soft(soft_opts), true, "is_soft")
  eq(options.is_soft(case_opts), false, "case is not soft")
  eq(options.is_soft(options.of({})), false, "auto is not soft")

  -- ------------------------------------------------------------------ the adapter: guard_config
  local o = options.of(plan({
    guards = { fs = "error", state = "warn", process_net = "warn", clock = true },
    guard_allow = { fs = { "/x" }, spawn = { "git" }, network = { "localhost" } },
  }, { "r", "--strict" }))
  local cfg = options.guard_config(o, { root = "/proj", seed = 99, in_child = true })
  eq(cfg.repo, "/proj", "repo is the root")
  eq(cfg.strict, true, "--strict travels")
  eq(cfg.restore, false, "restoring between files is the runner's soft isolation, not the guard's")
  eq(cfg.guards.fs, { mode = "error", allow = { "/x" } }, "fs: mode and allowed paths")
  eq(cfg.guards.state.mode, "warn", "state: mode")
  eq(cfg.guards.scheduled_error, { mode = "error" }, "scheduled_error")
  eq(cfg.guards.prompt, { mode = "error" }, "prompt")
  eq(cfg.guards.deprecation, { mode = "warn" }, "deprecation")
  eq(
    cfg.guards.process_net,
    { mode = "warn", allow_exec = { "git" }, allow_hosts = { "localhost" } },
    "process_net: allow_spawn becomes allow_exec, allow_network becomes allow_hosts"
  )
  eq(cfg.guards.clock, { mode = "warn", seed = 99 }, "clock on: a mode and the seed of the run")
  local off = options.guard_config(options.of({}), {})
  eq(off.guards.clock.mode, "off", "clock off by default")
  eq(off.guards.process_net.mode, "off", "process_net off by default")
  eq(off.repo, nil, "no root, no repo")
  eq(off.strict, false, "not strict by default")

  -- JSON-safe (it travels to a child in the job) and a fresh table every time
  local text = vim.json.encode(cfg)
  eq(vim.json.decode(text).guards.fs.allow, { "/x" }, "the configuration survives JSON")
  cfg.guards.fs.allow[1] = "changed"
  eq(o.guard_allow.fs, { "/x" }, "mutating the result does not touch the options")
  ok(options.guard_config(o, {}) ~= options.guard_config(o, {}), "a fresh table per call")

  -- the guard layer accepts exactly what the adapter produces, for every combination of modes
  local gcfg = require("testing.guard.config")
  for _, mode_name in ipairs({ "off", "warn", "error" }) do
    local opts_m = options.of(plan({
      guards = {
        fs = mode_name,
        state = mode_name,
        scheduled_error = mode_name,
        prompt = mode_name,
        deprecation = mode_name,
        process_net = mode_name,
        clock = mode_name ~= "off",
      },
    }))
    local _, problems = gcfg.normalize(options.guard_config(opts_m, { root = "/p", seed = 1 }))
    eq(problems, {}, "the guard layer finds nothing to complain about (" .. mode_name .. ")")
  end

  -- the state guard's categories never exceed the project's mode for the guard: "warn" must not fail a case
  local rank = { off = 0, info = 1, warn = 2, error = 3 }
  local warn_cfg = options.guard_config(options.of(plan({ guards = { state = "warn" } })), {})
  local cats = warn_cfg.guards.state.categories
  ok(type(cats) == "table", "categories are given")
  for cat, m in pairs(cats) do
    ok(
      rank[m] <= rank.warn,
      ("state = warn: category %s is %s, never more than warn"):format(cat, m)
    )
  end
  eq(cats.modules, "info", "a category below the mode keeps its own level")
  eq(cats.autocmds, "warn", "a category above the mode is capped (autocmds: error -> warn)")
  local err_cfg = options.guard_config(options.of(plan({ guards = { state = "error" } })), {})
  eq(
    err_cfg.guards.state.categories.autocmds,
    "error",
    "state = error keeps the guard layer's own levels"
  )
  eq(err_cfg.guards.state.categories.modules, "info", "info stays info")
end
