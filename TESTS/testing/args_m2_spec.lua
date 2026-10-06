-- TESTS/testing/args_m2_spec.lua -- the flags M2 adds: `--isolated case|soft`, `--guard <name>=<mode>`,
-- `--allow-fs/-spawn/-network`, `--pool-size`, `--pool-reuse`, `--no-determinism`, `--no-trace`.

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
  local args_mod = require("testing.args")

  local function parse(argv)
    return args_mod.parse(argv)
  end
  local function refused(argv)
    local a, why = parse(argv)
    eq(a, nil, "refused: " .. table.concat(argv, " "))
    return why or ""
  end

  -- ------------------------------------------------------------------ the defaults: nothing given
  local a = assert(parse({ "r" }))
  eq(a.guard, {}, "no --guard")
  eq({ a.allow_fs, a.allow_spawn, a.allow_network }, { {}, {}, {} }, "no --allow-*")
  eq(a.pool_size, nil, "--pool-size is unset (the config decides)")
  eq(a.pool_reuse, nil, "--pool-reuse is unset")
  eq(a.determinism, nil, "determinism is unset (the config decides)")
  eq(a.trace, nil, "trace is unset (the config decides)")

  -- ------------------------------------------------------------------ --isolated
  for _, mode in ipairs({ "none", "file", "case", "soft" }) do
    a = assert(parse({ "r", "--isolated", mode }))
    eq(a.isolated, mode, "--isolated " .. mode)
    eq(a.given.isolated, true, "and it is recorded as given")
  end
  a = assert(parse({ "r", "--isolated=case" }))
  eq(a.isolated, "case", "the = form")
  local why = refused({ "r", "--isolated", "maybe" })
  for _, name in ipairs({ "'none'", "'file'", "'case'", "'soft'" }) do
    has(why, name, "the refusal names " .. name)
  end
  refused({ "r", "--isolated", "Case" })

  -- ------------------------------------------------------------------ --guard
  a = assert(parse({
    "r",
    "--guard",
    "fs=error",
    "--guard=process_net=warn",
    "--guard",
    "scheduled-error=off",
    "--guard",
    "clock=on",
  }))
  eq(
    a.guard,
    { "fs=error", "process_net=warn", "scheduled-error=off", "clock=on" },
    "--guard is repeatable and keeps what was typed"
  )
  eq(a.given.guard, true, "recorded as given")
  has(refused({ "r", "--guard", "fs" }), "<name>=<mode>", "a guard without a mode")
  has(refused({ "r", "--guard", "=error" }), "<name>=<mode>", "a mode without a guard")
  has(refused({ "r", "--guard", "nope=warn" }), "unknown guard 'nope'", "an unknown guard")
  has(refused({ "r", "--guard", "fs=loud" }), "'off', 'warn' or 'error'", "an unknown mode")
  has(refused({ "r", "--guard", "clock=warn" }), "'on' or 'off'", "clock is on or off")
  has(refused({ "r", "--guard", "fs=on" }), "'off', 'warn' or 'error'", "on is for the clock only")
  has(refused({ "r", "--guard" }), "needs a value", "--guard without a value")
  for _, name in ipairs(args_mod.GUARD_NAMES) do
    eq(args_mod.check_guard(name .. "=" .. (name == "clock" and "on" or "warn")), nil, name)
  end

  -- ------------------------------------------------------------------ --allow-*
  a = assert(parse({
    "r",
    "--allow-fs",
    "/data/a",
    "--allow-fs",
    "C:/b",
    "--allow-spawn",
    "git",
    "--allow-network",
    "localhost",
    "--allow-network=127.0.0.1",
  }))
  eq(a.allow_fs, { "/data/a", "C:/b" }, "--allow-fs is repeatable")
  eq(a.allow_spawn, { "git" }, "--allow-spawn")
  eq(a.allow_network, { "localhost", "127.0.0.1" }, "--allow-network")
  eq(a.given.allow_fs and a.given.allow_spawn and a.given.allow_network, true, "recorded as given")
  has(refused({ "r", "--allow-fs" }), "needs a value", "--allow-fs without a value")
  has(
    refused({ "r", "--allow-spawn", ("x"):rep(401) }),
    "--allow-spawn",
    "a value that is too long"
  )
  has(refused({ "r", "--allow-network", "a\nb" }), "--allow-network", "control characters")

  -- ------------------------------------------------------------------ pool / determinism / trace
  a = assert(parse({ "r", "--pool-size", "4", "--pool-reuse" }))
  eq({ a.pool_size, a.pool_reuse }, { 4, true }, "--pool-size 4 --pool-reuse")
  a = assert(parse({ "r", "--pool-size", "0", "--no-pool-reuse" }))
  eq({ a.pool_size, a.pool_reuse }, { 0, false }, "--pool-size 0 (= jobs) and --no-pool-reuse")
  eq(a.given.pool_size and a.given.pool_reuse, true, "recorded as given")
  a = assert(parse({ "r", "--pool-reuse", "--no-pool-reuse" }))
  eq(a.pool_reuse, false, "the last of --pool-reuse / --no-pool-reuse wins")
  has(refused({ "r", "--pool-size", "-1" }), "integer >= 0", "--pool-size -1")
  has(refused({ "r", "--pool-size", "many" }), "integer >= 0", "--pool-size many")
  a = assert(parse({ "r", "--no-determinism", "--no-trace" }))
  eq({ a.determinism, a.trace }, { false, false }, "--no-determinism --no-trace")
  eq(a.given.determinism and a.given.trace, true, "recorded as given")

  -- ------------------------------------------------------------------ the usage text lists them all
  local usage = args_mod.usage()
  for _, flag in ipairs({
    "--guard",
    "--allow-fs",
    "--allow-spawn",
    "--allow-network",
    "--pool-size",
    "--pool-reuse",
    "--no-pool-reuse",
    "--no-determinism",
    "--no-trace",
    "<none|file|case|soft>",
  }) do
    has(usage, flag, "usage lists " .. flag)
  end

  -- the other options still parse next to them (no flag swallowed another one's value)
  a = assert(parse({ "root", "--guard", "fs=off", "--jobs", "3", "-x", "--isolated", "soft" }))
  eq({ a.root, a.jobs, a.maxfail, a.isolated }, { "root", 3, 1, "soft" }, "a mixed command line")
end
