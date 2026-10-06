-- TESTS/testing/args_m5_spec.lua -- the M5 options of `testing.args`: --shard, --watch (+ debounce/poll), --profile,
-- --jobs auto, the `budget` subcommand and its options, and the RESERVED names (cache, affected, conformance,
-- surface) that must parse so that the integration step can dispatch them.

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
  local parse = args_mod.parse

  ---@param argv string[]
  ---@return string problem
  local function refused(argv)
    local a, why = parse(argv)
    eq(a, nil, "refused: " .. table.concat(argv, " "))
    return why or ""
  end

  -- --shard
  local a = assert(parse({ "root", "--shard", "2/4" }))
  eq(a.shard, { index = 2, count = 4 }, "--shard 2/4")
  eq(a.given.shard, true, "given")
  a = assert(parse({ "root", "--shard=1/1" }))
  eq(a.shard, { index = 1, count = 1 }, "--shard=1/1 is the whole list")
  a = assert(parse({ "root", "--list", "--shard", "3/3" }))
  eq(a.list, true, "--list --shard parses together")
  eq(a.shard.index, 3, "shard of a list")
  a = assert(parse({ "list", "root", "--shard", "1/2" }))
  eq(a.command, "list", "the list subcommand with a shard")
  eq(a.shard.count, 2, "keeps the shard")
  for _, bad in ipairs({
    "0/3",
    "4/3",
    "1/0",
    "a/b",
    "1",
    "/",
    "1/",
    "/3",
    "1/2/3",
    "1.5/3",
    "-1/3",
    " 1/3",
    "1/3 ",
    "1/1001",
    "0000001/2",
  }) do
    has(refused({ "root", "--shard", bad }), "--shard", ("--shard %q names the option"):format(bad))
  end
  has(refused({ "root", "--shard" }), "needs a value", "--shard without a value")
  eq(args_mod.parse_shard("2/4"), { index = 2, count = 4 }, "parse_shard")
  eq(select(2, args_mod.parse_shard("5/4")) ~= nil, true, "parse_shard says why")

  -- --watch and its companions
  a = assert(parse({ "root", "--watch" }))
  eq(a.watch, true, "--watch")
  a = assert(parse({ "root", "--watch", "--watch-debounce", "250", "--watch-poll" }))
  eq(a.watch_debounce_ms, 250, "--watch-debounce")
  eq(a.watch_poll, true, "--watch-poll")
  has(
    refused({ "root", "--watch-debounce", "250" }),
    "--watch-debounce needs --watch",
    "debounce without watch"
  )
  has(refused({ "root", "--watch-poll" }), "--watch-poll needs --watch", "poll without watch")
  has(refused({ "root", "--watch", "--list" }), "--list", "watch with list")
  has(refused({ "root", "--watch", "--shard", "1/2" }), "--shard", "watch with shard")
  has(refused({ "root", "--watch", "--profile" }), "--profile", "watch with profile")
  has(refused({ "root", "--watch", "--watch-debounce", "0" }), "--watch-debounce", "debounce 0")
  has(refused({ "root", "--watch", "--watch-debounce", "x" }), "--watch-debounce", "debounce text")

  -- --profile
  a = assert(parse({ "root", "--profile" }))
  eq(a.profile, true, "--profile")
  eq(assert(parse({ "root" })).profile, false, "off by default")
  has(refused({ "root", "--profile", "--list" }), "--profile", "profile with list")

  -- --jobs auto
  a = assert(parse({ "root", "--jobs", "auto" }))
  eq(a.jobs_auto, true, "--jobs auto")
  eq(a.jobs, nil, "the caller resolves it")
  eq(a.given.jobs, true, "and it counts as given")
  a = assert(parse({ "root", "--jobs", "3" }))
  eq(a.jobs, 3, "a number still works")
  eq(a.jobs_auto, nil, "and is not auto")
  has(refused({ "root", "--jobs", "many" }), "'auto'", "the message names the word")
  has(refused({ "root", "--jobs", "0" }), "--jobs", "0 jobs")

  -- the budget subcommand
  a = assert(parse({ "budget" }))
  eq(a.command, "budget", "budget is a subcommand")
  eq(a.root, nil, "its root is optional here (the CLI defaults to the cwd)")
  a = assert(parse({
    "budget",
    "root",
    "--baseline",
    "b.json",
    "--factor",
    "1.5",
    "--update",
    "--runs",
    "7",
    "--filter",
    "discover",
  }))
  eq(a.baseline, "b.json", "--baseline")
  eq(a.factor, 1.5, "--factor is a number")
  eq(a.factor_text, "1.5", "and keeps the text")
  eq(a.budget_update, true, "--update")
  eq(a.budget_runs, 7, "--runs")
  eq(a.filter, { "discover" }, "--filter selects cases")
  for _, bad in ipairs({ "0.5", "abc", "0", "-2", "1001", "nan", "inf" }) do
    has(refused({ "budget", "--factor", bad }), "--factor", ("--factor %q"):format(bad))
  end
  has(refused({ "root", "--factor", "2" }), "belongs to `budget`", "--factor outside budget")
  has(refused({ "root", "--update" }), "belongs to `budget`", "--update outside budget")
  has(
    refused({ "root", "--baseline", "x.json" }),
    "belongs to `budget`",
    "--baseline outside budget"
  )
  has(refused({ "root", "--runs", "3" }), "belongs to `budget`", "--runs outside budget")

  -- the cache and affected options (wired by `testing.cli`, see integration_cache_spec)
  a = assert(parse({ "root", "--cached" }))
  eq(a.cache, true, "--cached")
  a = assert(parse({ "root", "--no-cache" }))
  eq(a.no_cache, true, "--no-cache")
  eq(a.cache, nil, "--no-cache does not set --cached")
  a = assert(parse({ "root", "--no-cache", "--cached" }))
  eq(
    { a.no_cache, a.cache },
    { true, true },
    "both are kept: the order never decides, --no-cache wins in the run"
  )
  a = assert(parse({ "root", "--cache-refresh" }))
  eq(a.cache_refresh, true, "--cache-refresh")
  a = assert(parse({ "root", "--cache-clear" }))
  eq(a.cache_clear, true, "--cache-clear")
  a = assert(parse({ "root", "--affected" }))
  eq(a.affected, true, "--affected alone")
  a = assert(parse({ "root", "--affected=origin/main" }))
  eq(a.affected, "origin/main", "--affected=<rev>")
  a = assert(parse({ "root", "--affected", "TESTS" }))
  eq(a.affected, true, "--affected never swallows the next argument")
  eq(a.root, "root", "the root is still the first positional")
  eq(a.paths, { "TESTS" }, "and TESTS is a path")
  a = assert(parse({ "root", "--changed" }))
  eq(a.changed, true, "--changed")
  a = assert(parse({ "root", "--since", "HEAD~3" }))
  eq(a.since, "HEAD~3", "--since")
  eq(assert(parse({ "root" })).cache, nil, "no cache decision by default")
  a = assert(parse({ "conformance", "root" }))
  eq(a.command, "conformance", "conformance is a subcommand name")
  eq(a.root, "root", "with a root")
  a = assert(parse({ "surface" }))
  eq(a.command, "surface", "surface is a subcommand name")
  eq(assert(parse({ "run", "root" })).command, "run", "run still works")
  eq(
    assert(parse({ "./conformance" })).command,
    "run",
    "a directory called conformance is spelled ./conformance"
  )

  -- the usage text lists everything and marks what is reserved
  local usage = args_mod.usage()
  for _, needle in ipairs({
    "--shard",
    "--watch",
    "--watch-debounce",
    "--watch-poll",
    "--profile",
    "--baseline",
    "--factor",
    "--update",
    "--runs",
    "budget",
    "--cached",
    "--affected",
    "--since",
    "--changed",
    "--cache-clear",
    "--no-cache",
    "auto",
  }) do
    has(usage, needle, "usage mentions " .. needle)
  end
  ok(not usage:find("RESERVED", 1, true), "nothing is marked reserved any more")
  has(usage, "--cache-refresh", "usage mentions --cache-refresh")
  has(usage, "conformance  run the conformance checks", "usage lists conformance")
  has(usage, "surface  list the plugin's surface", "usage lists surface")
end
