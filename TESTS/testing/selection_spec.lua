-- TESTS/testing/selection_spec.lua -- selection and order of a run (testing.run.select): literal
-- filters, the tag syntax, --lf/--ff grouping, the deterministic shuffle with its seed.

-- @cache-allow random
-- (`math.random` only checks that the private shuffle PRNG does not touch it)
return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local sel = require("testing.run.select")

  -- tags in titles: `#word` of describe/it, never the file part, never the duplicate counter
  eq(sel.tags_of_id("TESTS/a_spec.lua::parser::parses #slow input"), { "slow" }, "one tag")
  eq(
    sel.tags_of_id("TESTS/a_spec.lua::group #net::does it #slow #flaky-1"),
    { "net", "slow", "flaky-1" },
    "describe and it tags, in order"
  )
  eq(sel.tags_of_id("TESTS/c#1_spec.lua::x_spec.lua"), {}, "a # in the file part is no tag")
  eq(sel.tags_of_id("TESTS/a_spec.lua::it #2"), {}, "a trailing #<digits> is the duplicate counter")
  eq(
    sel.tags_of_id("TESTS/a_spec.lua::it #slow#2"),
    { "slow" },
    "but a tag before the counter is one"
  )
  eq(sel.tags_of_id("TESTS/a_spec.lua::it #a #a"), { "a" }, "tags are unique")

  -- header tags
  eq(sel.header_tags("-- @tags slow integration\nreturn 1\n"), { "slow", "integration" }, "header")
  eq(sel.header_tags("--@tags: a, b,c\n"), { "a", "b", "c" }, "colon and commas")
  eq(sel.header_tags("local x = 1 -- @tags nope\n"), {}, "only a comment line of its own")
  eq(sel.header_tags("-- @tags bad/tag ok\n"), { "ok" }, "invalid tag characters are dropped")
  local late = ("\n"):rep(sel.HEADER_LINES) .. "-- @tags toolate\n"
  eq(sel.header_tags(late), {}, "a header after the scanned lines does not count")

  -- file selection: plain substring of the PROJECT-RELATIVE path, never a pattern
  local s = sel.new({ file = { "core_" } })
  eq(s.file_ok("TESTS/testing/core_assert_spec.lua"), true, "substring selects")
  eq(s.file_ok("TESTS/testing/args_spec.lua"), false, "other files are out")
  s = sel.new({ file = { "a.c" } })
  eq(
    s.file_ok("TESTS/abc_spec.lua"),
    false,
    "a Lua pattern character is literal ('.' is not 'any')"
  )
  eq(s.file_ok("TESTS/a.c_spec.lua"), true, "the literal text selects")
  s = sel.new({ file = { "spec" } })
  eq(s.file_ok("TESTS/x_spec.lua"), true, "matches inside the relative path")
  eq(sel.new({}).file_ok("anything"), true, "no --file selects every file")

  -- case selection: filter = substring of the id (literal), any of several; no filter = all
  s = sel.new({ filter = { "parses", "50%" } })
  eq(s.active, true, "a filter is a case-level restriction")
  eq(s.case_ok("TESTS/a_spec.lua::p::parses x", "TESTS/a_spec.lua"), true, "first filter")
  eq(s.case_ok("TESTS/a_spec.lua::p::gives 50% off", "TESTS/a_spec.lua"), true, "'%' is literal")
  eq(s.case_ok("TESTS/a_spec.lua::p::other", "TESTS/a_spec.lua"), false, "no match")
  eq(sel.new({}).active, false, "no restriction is not a partial run")
  s = sel.new({ filter = { "a_spec.lua::a_spec.lua" } })
  eq(
    s.case_ok("TESTS/a_spec.lua::a_spec.lua", "TESTS/a_spec.lua"),
    true,
    "a file case is selectable"
  )

  -- tags: any listed tag selects, exclusion wins, header tags apply to every case of the file
  local header = {
    ["TESTS/h_spec.lua"] = { "slow" },
  }
  local function tagged(spec)
    spec.header_tags = function(rel)
      return header[rel] or {}
    end
    return sel.new(spec)
  end
  s = tagged({ tags = { "slow" } })
  eq(s.case_ok("TESTS/a_spec.lua::x #slow", "TESTS/a_spec.lua"), true, "title tag")
  eq(s.case_ok("TESTS/a_spec.lua::x", "TESTS/a_spec.lua"), false, "untagged is out")
  eq(s.case_ok("TESTS/h_spec.lua::h_spec.lua", "TESTS/h_spec.lua"), true, "header tag of the file")
  s = tagged({ tags = { "slow", "net" }, exclude_tags = { "flaky" } })
  eq(s.case_ok("TESTS/a_spec.lua::x #net", "TESTS/a_spec.lua"), true, "any of the tags")
  eq(s.case_ok("TESTS/a_spec.lua::x #net #flaky", "TESTS/a_spec.lua"), false, "exclusion wins")
  s = tagged({ exclude_tags = { "slow" } })
  eq(s.case_ok("TESTS/a_spec.lua::x", "TESTS/a_spec.lua"), true, "exclude only: untagged stays")
  eq(s.case_ok("TESTS/h_spec.lua::h_spec.lua", "TESTS/h_spec.lua"), false, "excluded by header tag")
  s = tagged({ tags = { "slow" }, filter = { "alpha" } })
  eq(
    s.case_ok("TESTS/a_spec.lua::alpha #slow", "TESTS/a_spec.lua"),
    true,
    "filter and tag together"
  )
  eq(s.case_ok("TESTS/a_spec.lua::beta #slow", "TESTS/a_spec.lua"), false, "both must hold")

  -- --lf grouping
  local by_file = sel.group_failed({
    "TESTS/a_spec.lua::d::one",
    "TESTS/a_spec.lua::d::two",
    "TESTS/b_spec.lua::b_spec.lua",
    "TESTS/c_spec.lua::d::three",
    "no-separator",
  })
  eq(sel.file_of_id("TESTS/a_spec.lua::d::one"), "TESTS/a_spec.lua", "file part of an id")
  eq(vim.tbl_count(by_file), 4, "grouped by file")
  eq(
    sel.lf_ids("TESTS/a_spec.lua", by_file),
    { ["TESTS/a_spec.lua::d::one"] = true, ["TESTS/a_spec.lua::d::two"] = true },
    "case ids of a busted file"
  )
  eq(sel.lf_ids("TESTS/b_spec.lua", by_file), nil, "the file itself failed: all its cases run")
  eq(sel.lf_ids("TESTS/other_spec.lua", by_file), nil, "an unknown file has no restriction here")
  eq(sel.file_case_id("TESTS/sub/x_spec.lua"), "TESTS/sub/x_spec.lua::x_spec.lua", "file case id")

  -- failed first: stable, the rest keep their order
  local files = { { rel = "a" }, { rel = "b" }, { rel = "c" }, { rel = "d" } }
  local ordered = sel.failed_first(files, function(f)
    return f.rel
  end, { c = true, a = true })
  eq(
    vim.tbl_map(function(f)
      return f.rel
    end, ordered),
    { "a", "c", "b", "d" },
    "failed files first, stable"
  )

  -- the PRNG is private and deterministic: pinned values (a change of the algorithm changes every
  -- stored seed, so it must be deliberate)
  local nxt = sel.rng(42)
  local seq = {}
  for _ = 1, 6 do
    seq[#seq + 1] = nxt(100)
  end
  eq(seq, { 54, 2, 24, 6, 37, 94 }, "the sequence of seed 42 is pinned")
  local nxt2 = sel.rng(42)
  eq(nxt2(100), 54, "the same seed starts the same way")
  local before = math.random(1, 1000000)
  math.randomseed(1)
  local a1 = sel.rng(7)(1000)
  math.randomseed(999)
  local a2 = sel.rng(7)(1000)
  eq(a1, a2, "math.random (which specs may reseed) does not influence the shuffle")
  ok(type(before) == "number", "math.random still works")

  -- shuffle: a permutation, deterministic per seed, different per seed, input untouched
  local input = {}
  for i = 1, 20 do
    input[i] = i
  end
  local s1 = sel.shuffle(input, 7)
  local s1b = sel.shuffle(input, 7)
  local s2 = sel.shuffle(input, 8)
  eq(s1, s1b, "same seed, same order")
  ok(not vim.deep_equal(s1, s2), "another seed, another order")
  ok(not vim.deep_equal(s1, input), "the order actually changed")
  local sorted = vim.deepcopy(s1)
  table.sort(sorted)
  eq(sorted, input, "nothing lost, nothing duplicated")
  eq(input[1], 1, "the input list is not modified")
  eq(sel.shuffle({}, 1), {}, "an empty list stays empty")
  eq(sel.shuffle({ "x" }, 1), { "x" }, "one element stays")
  eq(sel.shuffle(input, 7), s1, "pinned: seed 7 on 1..20 is reproducible later in the same run")

  -- seeds typed back by a user are accepted whatever their size
  local big = sel.shuffle(input, 123456789012345)
  eq(#big, 20, "a 15 digit seed works")
  local zero = sel.shuffle(input, 0)
  eq(#zero, 20, "seed 0 works")

  -- a fresh seed is a positive integer that can be typed back
  for _, args in ipairs({ { 1, 1 }, { 1790000000, 999999999 }, { 2147483647, 5 } }) do
    local seed = sel.fresh_seed(args[1], args[2])
    ok(seed >= 1 and seed < 2147483647 and seed == math.floor(seed), "fresh seed " .. seed)
  end
  ok(sel.fresh_seed(100, 1) ~= sel.fresh_seed(100, 2), "the clock part makes seeds differ")
end
