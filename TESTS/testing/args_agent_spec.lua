-- TESTS/testing/args_agent_spec.lua -- the options of the agent reporter and of `--order`, and `repeat_argv` (the
-- arguments of a run without what selects and shows, for the `rerun:` line).

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack))
    )
  end
  local args = require("testing.args")

  local a =
    assert(args.parse({ ".", "--reporter", "agent", "--agent-budget", "900", "--format", "jsonl" }))
  eq(a.reporter, "agent", "--reporter agent")
  eq(a.agent_budget, 900, "--agent-budget")
  eq(a.format, "jsonl", "--format")
  ok(vim.tbl_contains(args.REPORTERS, "agent"), "agent is a known reporter")

  local _, why = args.parse({ ".", "--agent-budget", tostring(args.AGENT_BUDGET_MIN - 1) })
  has(why, "needs an integer >=", "a budget below the minimum is refused")
  _, why = args.parse({ ".", "--format", "yaml" })
  has(why, "'text' or 'jsonl'", "an unknown format is refused")

  a = assert(args.parse({ ".", "--order", "priority" }))
  eq(a.order, "priority", "--order priority")
  _, why = args.parse({ ".", "--order", "alphabetical" })
  has(why, "must be 'priority'", "an unknown order is refused")
  _, why = args.parse({ ".", "--order", "priority", "--shuffle" })
  has(why, "exclude each other", "--order and --shuffle exclude each other")
  ok(args.parse({ ".", "--order", "priority", "--ff" }) ~= nil, "--ff stays valid next to --order")
  ok(args.parse({ ".", "--order", "priority", "--lf" }) ~= nil, "--lf stays valid next to --order")
  has(args.usage(), "--agent-budget", "the usage names the budget")
  has(args.usage(), "--order", "and the order")

  -- repeat_argv ---------------------------------------------------------------------------------------------------------------------
  eq(
    args.repeat_argv({
      ".",
      "--reporter",
      "agent",
      "--cached",
      "--file",
      "cfg",
      "--filter=x",
      "tests/sub",
      "--json",
      "out.json",
      "-x",
      "--rtp",
      "../lib.nvim",
      "--jobs",
      "4",
      "--order",
      "priority",
      "--agent-budget",
      "900",
      "--strict",
      "--changed",
    }),
    { ".", "--rtp", "../lib.nvim", "--jobs", "4", "--strict" },
    "selection, output and order options and the path positionals are dropped, the rest stays"
  )
  eq(
    args.repeat_argv({
      "run",
      "/abs/root",
      "--shard",
      "1/2",
      "--since",
      "HEAD~1",
      "--durations",
      "3",
    }),
    { "run", "/abs/root" },
    "the subcommand word and the root stay"
  )
  eq(args.repeat_argv({}), {}, "nothing")
  eq(
    args.repeat_argv({ ".", "--no-such-option", "--seed", "5", "--shuffle", "--maxfail", "2" }),
    { ".", "--no-such-option" },
    "an option the parser does not know stays; a shuffle and its seed do not"
  )
  eq(
    args.repeat_argv({ ".", "--", "--file", "x" }),
    { "." },
    "after -- there are only positionals, and they are paths"
  )
  eq(args.repeat_argv({ ".", "--file" }), { "." }, "an option that lost its value does not raise")
end
