-- TESTS/testing/config_m2_spec.lua -- the keys M2 adds to `.testing.lua`: `isolated` = case | soft,
-- `soft_keep`, `guards`, `guard_allow`, `pool`, `determinism`, `trace`. Every key is typed: a valid value is
-- taken, an invalid one degrades to the default with ONE warning that names the key.

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
  local project = require("testing.config.project")
  local DEFAULTS = require("testing.config.DEFAULTS")

  -- ------------------------------------------------------------------ the defaults (data)
  local d = project.validate(nil)
  eq(
    d.guards,
    {
      fs = "warn",
      state = "warn",
      scheduled_error = "error",
      prompt = "error",
      deprecation = "warn",
      process_net = "off",
      clock = false,
    },
    "guards: the safe set (prompt and scheduled_error fail, state and fs warn, process_net off, clock opt-in)"
  )
  eq(d.guard_allow, { fs = {}, spawn = {}, network = {} }, "guard_allow: nothing is let through")
  eq(d.pool, { size = 0, reuse = false }, "pool: size 0 means `jobs`, no reuse")
  eq(d.determinism, true, "determinism is on")
  eq(d.trace, true, "trace is on")
  eq(d.soft_keep, {}, "soft_keep is empty")
  eq(d.isolated, "auto", "isolated stays auto")
  eq(DEFAULTS.project.guards, d.guards, "the defaults are DEFAULTS.project, as data")
  ok(d.guards ~= DEFAULTS.project.guards, "and a copy of them, never the table itself")

  -- ------------------------------------------------------------------ valid values are taken
  local good, problems = project.validate({
    isolated = "case",
    soft_keep = { "my.plugin.cache", "my.shared*" },
    guards = {
      fs = "error",
      state = "off",
      scheduled_error = "warn",
      prompt = "warn",
      deprecation = "error",
      process_net = "warn",
      clock = true,
    },
    guard_allow = {
      fs = { "~/.local/share/mine", "C:/data/x" },
      spawn = { "git", "rg" },
      network = { "localhost", "127.0.0.1" },
    },
    pool = { size = 4, reuse = true },
    determinism = false,
    trace = false,
  })
  eq(problems, {}, "every valid value passes without a warning")
  eq(good.isolated, "case", "isolated = case")
  eq(good.soft_keep, { "my.plugin.cache", "my.shared*" }, "soft_keep is taken")
  eq(good.guards.fs, "error", "guards.fs")
  eq(good.guards.state, "off", "guards.state")
  eq(good.guards.process_net, "warn", "guards.process_net")
  eq(good.guards.clock, true, "guards.clock")
  eq(good.guard_allow, {
    fs = { "~/.local/share/mine", "C:/data/x" },
    spawn = { "git", "rg" },
    network = { "localhost", "127.0.0.1" },
  }, "guard_allow")
  eq(good.pool, { size = 4, reuse = true }, "pool")
  eq({ good.determinism, good.trace }, { false, false }, "determinism and trace")
  eq(project.validate({ isolated = "soft" }).isolated, "soft", "isolated = soft")

  -- a partial group keeps the defaults of what it does not name
  local part = project.validate({ guards = { fs = "off" }, pool = { reuse = true } })
  eq(part.guards.fs, "off", "the named guard changes")
  eq(part.guards.prompt, "error", "the others keep their default")
  eq(part.pool, { size = 0, reuse = true }, "a partial pool keeps size")

  -- ------------------------------------------------------------------ invalid values degrade, each named
  local bad = {
    { "isolated", "maybe", "isolated" },
    { "isolated", "Case", "isolated" },
    { "isolated", 3, "isolated" },
    { "soft_keep", "my.mod", "soft_keep" },
    { "soft_keep", { "a b" }, "soft_keep" },
    { "soft_keep", { "a*b" }, "soft_keep" },
    { "soft_keep", { "" }, "soft_keep" },
    { "soft_keep", { 1 }, "soft_keep" },
    { "determinism", "yes", "determinism" },
    { "determinism", 1, "determinism" },
    { "trace", "no", "trace" },
    { "trace", {}, "trace" },
  }
  for _, c in ipairs(bad) do
    local got, probs = project.validate({ [c[1]] = c[2] })
    eq(#probs, 1, ("%s = %s: one warning"):format(c[1], vim.inspect(c[2])))
    has(probs[1], "'" .. c[3] .. "'", c[1] .. ": the warning names the key")
    eq(got[c[1]], d[c[1]], ("%s = %s: the default stays"):format(c[1], vim.inspect(c[2])))
  end

  -- leaves inside groups
  local group_bad = {
    { { guards = { fs = "loud" } }, "guards.fs" },
    { { guards = { fs = true } }, "guards.fs" },
    { { guards = { state = 1 } }, "guards.state" },
    { { guards = { scheduled_error = "ERROR" } }, "guards.scheduled_error" },
    { { guards = { prompt = {} } }, "guards.prompt" },
    { { guards = { deprecation = "" } }, "guards.deprecation" },
    { { guards = { process_net = "block" } }, "guards.process_net" },
    { { guards = { clock = "on" } }, "guards.clock" },
    { { guard_allow = { fs = "x" } }, "guard_allow.fs" },
    { { guard_allow = { fs = { "" } } }, "guard_allow.fs" },
    { { guard_allow = { fs = { "a\nb" } } }, "guard_allow.fs" },
    { { guard_allow = { spawn = { 1 } } }, "guard_allow.spawn" },
    { { guard_allow = { network = { ("h"):rep(401) } } }, "guard_allow.network" },
    { { pool = { size = -1 } }, "pool.size" },
    { { pool = { size = 2.5 } }, "pool.size" },
    { { pool = { size = 257 } }, "pool.size" },
    { { pool = { size = "4" } }, "pool.size" },
    { { pool = { reuse = "yes" } }, "pool.reuse" },
  }
  for _, c in ipairs(group_bad) do
    local got, probs = project.validate(c[1])
    eq(#probs, 1, c[2] .. ": one warning for " .. vim.inspect(c[1]))
    has(probs[1], "'" .. c[2] .. "'", c[2] .. ": the warning names the dotted key")
    has(probs[1], "using the default", c[2] .. ": and says the default stays")
    eq(got.guards, d.guards, c[2] .. ": guards unchanged")
    eq(got.guard_allow, d.guard_allow, c[2] .. ": guard_allow unchanged")
    eq(got.pool, d.pool, c[2] .. ": pool unchanged")
  end

  -- a malformed group, an unknown key inside a group
  local g1, p1 = project.validate({ guards = "all" })
  eq(#p1, 1, "guards = string: one warning")
  has(p1[1], "'guards' must be a table", "names the group")
  eq(g1.guards, d.guards, "and the defaults stay")
  local _, p2 = project.validate({ guards = { fsx = "error" } })
  eq(#p2, 1, "an unknown guard: one warning")
  has(p2[1], "unknown key 'guards.fsx'", "names it")
  local _, p3 = project.validate({ pool = { workers = 3 } })
  has(p3[1] or "", "unknown key 'pool.workers'", "an unknown pool key is named")
  local g4, p4 = project.validate({ guard_allow = { exec = { "git" } } })
  has(p4[1] or "", "unknown key 'guard_allow.exec'", "an unknown allow key is named")
  eq(g4.guard_allow, d.guard_allow, "and nothing was let through")

  -- one bad key does not spoil its neighbours
  local mixed, mp = project.validate({ guards = { fs = "loud", prompt = "off" }, trace = false })
  eq(#mp, 1, "one warning for the one bad leaf")
  eq(mixed.guards.fs, "warn", "the bad leaf keeps its default")
  eq(mixed.guards.prompt, "off", "the good sibling is taken")
  eq(mixed.trace, false, "and so is the key next to the group")

  -- ------------------------------------------------------------------ isolation per dialect
  local function cfg_of(isolated)
    return project.validate({ isolated = isolated })
  end
  eq(project.isolated_for(cfg_of("case"), "busted"), "case", "case: busted gets a child per case")
  for _, name in ipairs({ "a", "b", "c", "d", "h" }) do
    eq(
      project.isolated_for(cfg_of("case"), name),
      "file",
      "case: dialect " .. name .. " has ONE case per file, so a child per file"
    )
    eq(project.degraded_case(cfg_of("case"), name), true, name .. ": the degrade is reported")
  end
  eq(project.degraded_case(cfg_of("case"), "busted"), false, "busted does not degrade")
  eq(project.degraded_case(cfg_of("case"), "script"), false, "a script is a file in a child anyway")
  eq(project.degraded_case(cfg_of("file"), "a"), false, "only `case` degrades")
  eq(project.isolated_for(cfg_of("case"), "script"), "file", "a script is a child per file")
  eq(project.isolated_for(cfg_of("soft"), "busted"), "none", "soft: this process, even for busted")
  eq(project.isolated_for(cfg_of("soft"), "a"), "none", "soft: this process")
  eq(project.isolated_for(cfg_of("soft"), "script"), "file", "soft: a script still needs a child")
  eq(project.isolated_for(cfg_of("auto"), "busted"), "file", "auto is unchanged")
end
