-- TESTS/testing/args_spec.lua -- testing.args: every argument form, every refusal.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
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

  -- defaults
  local a = assert(parse({ "root" }))
  eq(a.command, "run", "run is the default command")
  eq(a.root, "root", "the first positional is the root")
  eq(a.paths, {}, "no further positionals")
  eq(a.timings, true, "timings default on")
  eq(a.given, {}, "nothing given")
  eq(a.json, nil, "no json")
  eq(a.github, false, "github default off")

  -- value options: both forms, equal result
  local sp = assert(parse({ "r", "--json", "o.json", "--reporter", "term" }))
  local eqf = assert(parse({ "r", "--json=o.json", "--reporter=term" }))
  eq(sp.json, "o.json", "--k v")
  eq(eqf.json, "o.json", "--k=v")
  eq(sp.reporter, eqf.reporter, "both forms agree")
  eq(assert(parse({ "r", "--json=a=b.json" })).json, "a=b.json", "only the first = splits")
  eq(assert(parse({ "r", "--filter", "-x" })).filter, { "-x" }, "a single-dash value is a value")
  eq(assert(parse({ "r", "--filter=--odd" })).filter, { "--odd" }, "--k=--v reaches a -- value")
  has(refused({ "r", "--filter", "--odd" }), "needs a value", "a -- value in the space form")

  -- repeatable options and aliases
  a = assert(parse({ "r", "--rtp", "a", "--rtp=b", "--only", "x", "--file", "y", "--only=z" }))
  eq(a.rtp, { "a", "b" }, "--rtp repeats")
  eq(a.file, { "x", "y", "z" }, "--only is an alias of --file")
  eq(a.given.file, true, "the alias records the canonical name")
  a = assert(parse({ "r", "--tags", "a,b", "--tags=c", "--exclude-tags", "slow" }))
  eq(a.tags, { "a", "b", "c" }, "tags split on commas and repeat")
  eq(a.exclude_tags, { "slow" }, "exclude-tags")
  has(refused({ "r", "--tags", "a;b" }), "invalid tag", "a tag is a word, not a shell fragment")
  eq(
    assert(parse({ "r", "--json", "1", "--json", "2" })).json,
    "2",
    "a repeated scalar is last-wins"
  )

  -- flags
  a =
    assert(parse({ "r", "--github", "--strict", "--shuffle", "--lf", "--no-timings", "--dry-run" }))
  eq(a.github and a.strict and a.shuffle and a.lf, true, "flags")
  eq(a.timings, false, "--no-timings")
  eq(a.list, true, "--dry-run is --list")
  eq(assert(parse({ "r", "--list" })).list, true, "--list")
  has(refused({ "r", "--github=1" }), "takes no value", "a flag with a value")

  -- numbers
  a = assert(parse({ "r", "-x" }))
  eq(a.maxfail, 1, "-x is --maxfail 1")
  eq(assert(parse({ "r", "--maxfail", "5" })).maxfail, 5, "--maxfail N")
  eq(assert(parse({ "r", "--shuffle", "--seed=42" })).seed, 42, "--seed with --shuffle")
  eq(assert(parse({ "r", "--durations", "0" })).durations, 0, "--durations 0 is allowed")
  eq(assert(parse({ "r", "--case-timeout", "250" })).case_timeout_ms, 250, "--case-timeout")
  eq(assert(parse({ "r", "--file-timeout=900" })).file_timeout_ms, 900, "--file-timeout")
  has(refused({ "r", "--maxfail", "0" }), ">= 1", "maxfail 0")
  has(refused({ "r", "--maxfail", "abc" }), "integer", "not a number")
  refused({ "r", "--maxfail", "0x10" })
  refused({ "r", "--maxfail", "1e3" })
  refused({ "r", "--maxfail", "-3" })
  refused({ "r", "--case-timeout", "0" })
  has(refused({ "r", "--seed", "7" }), "--seed needs --shuffle", "seed without shuffle")
  has(refused({ "r", "--lf", "--ff" }), "exclude each other", "lf and ff")

  -- reporter
  has(refused({ "r", "--reporter", "nope" }), "unknown reporter", "unknown reporter")
  for _, name in ipairs(args_mod.REPORTERS) do
    eq(assert(parse({ "r", "--reporter", name })).reporter, name, "reporter " .. name)
  end

  -- missing values
  has(refused({ "r", "--json" }), "needs a value", "a trailing option")
  has(refused({ "r", "--json=" }), "needs a value", "an empty inline value")
  has(refused({ "r", "--json", "--github" }), "needs a value", "the next token is an option")

  -- unknown options
  has(refused({ "r", "--frobnicate" }), "unknown option --frobnicate", "unknown long option")
  has(refused({ "r", "-z" }), "unknown option -z", "unknown short option")
  refused({ "r", "-xx" })

  -- positionals, root and the terminator
  a = assert(parse({ "root", "p1", "p2" }))
  eq(a.root, "root", "first positional is the root")
  eq(a.paths, { "p1", "p2" }, "the others are paths")
  a = assert(parse({ "--root", "R", "p1" }))
  eq(a.root, "R", "--root")
  eq(a.paths, { "p1" }, "with --root every positional is a path")
  a = assert(parse({ "r", "--", "--json", "-x" }))
  eq(a.paths, { "--json", "-x" }, "after -- everything is positional")
  eq(a.json, nil, "and no option")
  eq(assert(parse({ "-" })).root, "-", "a lone dash is a positional")

  -- subcommands
  for _, name in ipairs(args_mod.SUBCOMMANDS) do
    local c = assert(parse({ name, "r" }))
    eq(c.command, name, "subcommand " .. name)
    eq(c.root, "r", "the root after the subcommand " .. name)
  end
  eq(assert(parse({ "list", "r" })).list, true, "the list subcommand lists")
  a = assert(parse({ "r", "list" }))
  eq(a.command, "run", "a subcommand name later on is not a subcommand")
  eq(a.paths, { "list" }, "it is a path")
  eq(assert(parse({ "doctor" })).root, nil, "doctor without a root parses")

  -- help short-circuits
  eq(assert(parse({ "-h" })).help, true, "-h")
  eq(assert(parse({ "--help" })).help, true, "--help")
  eq(assert(parse({ "--lf", "--ff", "-h" })).help, true, "help wins over a conflicting pair")

  -- nothing is executed or interpreted
  a = assert(parse({ "r", "--filter", "os.exit(7); $(rm -rf /) `x`" }))
  eq(a.filter, { "os.exit(7); $(rm -rf /) `x`" }, "user text stays text")

  -- per-file isolation: --isolated, --jobs, --host, --env-allow
  a = assert(parse({ "r" }))
  eq(a.isolated, nil, "isolated is unset by default (the config / the dialect decides)")
  eq(a.jobs, nil, "jobs is unset by default")
  eq(a.host, nil, "host is unset by default")
  eq(a.env_allow, {}, "env_allow is empty by default")
  a = assert(parse({ "r", "--isolated", "file", "--jobs", "4", "--host", "l" }))
  eq(a.isolated, "file", "--isolated file")
  eq(a.jobs, 4, "--jobs 4")
  eq(a.host, "l", "--host l")
  eq(a.given.isolated and a.given.jobs and a.given.host, true, "and they are recorded as given")
  a = assert(parse({ "r", "--isolated=none", "--jobs=2", "--host=c" }))
  eq({ a.isolated, a.jobs, a.host }, { "none", 2, "c" }, "the = form")
  a = assert(parse({ "r", "--env-allow", "A", "--env-allow", "LUA_*" }))
  eq(a.env_allow, { "A", "LUA_*" }, "--env-allow is repeatable")
  has(
    refused({ "r", "--isolated", "maybe" }),
    "'none', 'file', 'case' or 'soft'",
    "--isolated maybe"
  )
  has(refused({ "r", "--isolated" }), "needs a value", "--isolated without a value")
  has(refused({ "r", "--jobs", "0" }), "integer >= 1", "--jobs 0")
  has(refused({ "r", "--jobs", "many" }), "integer >= 1", "--jobs many")
  has(refused({ "r", "--jobs", "-2" }), "integer >= 1", "--jobs -2")
  has(refused({ "r", "--host", "x" }), "'c' or 'l'", "--host x")
  has(refused({ "r", "--env-allow", "*" }), "whole environment", "--env-allow *")
  has(refused({ "r", "--env-allow", "NVIM_LISTEN_ADDRESS" }), "NVIM", "--env-allow NVIM_...")
  has(refused({ "r", "--env-allow", "A B" }), "--env-allow", "--env-allow with a space")

  -- usage is generated from the same table
  local usage = args_mod.usage()
  for _, flag in ipairs({
    "--json",
    "--junit",
    "--github",
    "--rtp",
    "--only",
    "-x",
    "--dry-run",
    "--isolated",
    "--jobs",
    "--host",
    "--env-allow",
  }) do
    has(usage, flag, "usage names " .. flag)
  end
  has(
    usage,
    "exit: 0 green, 1 failures, 2 usage/config error, 3 infrastructure error",
    "exit codes"
  )
end
