-- TESTS/testing/guard_ledger_spec.lua -- the effects ledger (testing.core.ledger): bounded, deduplicating,
-- redacting, mergeable from several children, deterministic, and compatible with the IR `effects`.

return function(H)
  local ok, eq = H.ok, H.eq
  local ledger = require("testing.core.ledger")
  local result = require("testing.core.result")

  -- ---------------------------------------------------------------- add / dedupe / sort
  local l = ledger.new()
  l:add("spawned", "git status")
  l:add("spawned", "git status")
  l:add("spawned", "curl x", { blocked = true })
  l:add("spawned", "curl x") -- same text, allowed: a different entry than the blocked one
  l:add("network", "dns example.org")
  eq(l:total("spawned"), 4, "total counts every occurrence")
  eq(#l:entries("spawned"), 3, "identical entries are folded, blocked and allowed stay apart")
  eq(l:entries("spawned")[1].text, "curl x", "sorted by text")
  eq(l:entries("spawned")[1].blocked, nil, "allowed before blocked")
  eq(l:entries("spawned")[2].blocked, true, "blocked after allowed")
  eq(l:entries("spawned")[3].count, 2, "count of the folded entry")
  ok(not l:is_empty(), "not empty")
  eq(ledger.new():is_empty(), true, "a fresh ledger is empty")
  ---@diagnostic disable-next-line: param-type-mismatch
  eq(l:add("spawned", 5), false, "a non-string text is refused")
  eq(l:add("", "x"), false, "an empty kind is refused")

  -- ---------------------------------------------------------------- IR effects
  local fx = l:to_effects()
  local keys = vim.tbl_keys(fx)
  table.sort(keys)
  eq(keys, { "fs_outside_tmp", "network", "spawned" }, "exactly the three IR lists")
  eq(
    fx.spawned,
    { "curl x", "curl x [blocked]", "git status (x2)" },
    "entries as strings, sorted, with marks"
  )
  eq(fx.network, { "dns example.org" }, "network list")
  eq(fx.fs_outside_tmp, {}, "an empty IR list is present")
  l:add("prompts", "vim.fn.input('x')")
  eq(l:to_effects().prompts, nil, "kinds the IR does not know are not in the default effects")
  eq(l:to_effects({ extra = true }).prompts, { "vim.fn.input('x')" }, "but available on request")

  local run = result.new()
  local case = result.new_case({ file = "a_spec.lua", name = "x" })
  case.effects = l:to_effects()
  case.assertions[1] = { ok = true, kind = "eq", message = "m" }
  result.add_case(run, result.finish_case(case))
  result.finalize(run)
  local valid, problems = result.validate(run)
  ok(
    valid,
    "a case carrying ledger effects validates against the IR schema: " .. vim.inspect(problems)
  )

  -- ---------------------------------------------------------------- bounds (SEC-32)
  local b = ledger.new({ max_entries = 3, max_text = 10, max_kinds = 2 })
  for i = 1, 5 do
    b:add("spawned", "cmd" .. i)
  end
  eq(#b:entries("spawned"), 3, "at most max_entries distinct entries")
  eq(b:dropped("spawned"), 2, "what did not fit is counted, not lost silently")
  ok(b:to_effects().spawned[4]:find("2 more not recorded", 1, true), "and the effects list says so")
  b:add("spawned", "cmd1") -- an existing entry still counts up
  eq(b:entries("spawned")[1].count, 2, "known entries keep counting when the bound is reached")
  b:add("network", "a-very-long-text-that-is-cut")
  eq(b:entries("network")[1].text, "a-very-lon...", "texts are cut at max_text")
  eq(b:add("third", "x"), false, "at most max_kinds kinds")

  -- ---------------------------------------------------------------- redaction
  local red = ledger.redactor({ repo = "/work/proj", tmp = "/var/tmp", home = "/home/stefan" })
  local r = ledger.new({ redact = red })
  r:add("fs_outside_tmp", "write /work/proj/a.txt")
  r:add("fs_outside_tmp", "write /var/tmp/x/b.txt")
  r:add("fs_outside_tmp", "write /home/stefan/.config/c.txt")
  eq(
    r:to_effects().fs_outside_tmp,
    { "write <HOME>/.config/c.txt", "write <REPO>/a.txt", "write <TMP>/x/b.txt" },
    "paths become <REPO> / <TMP> / <HOME>"
  )

  local function secrets(text, gone, kept)
    local out = ledger.redact_secrets(text)
    for _, g in ipairs(gone) do
      ok(not out:find(g, 1, true), ("%q must be gone from %q"):format(g, out))
    end
    for _, k in ipairs(kept or {}) do
      ok(out:find(k, 1, true), ("%q must stay in %q"):format(k, out))
    end
  end
  secrets("Authorization: Bearer abcdefgh12345", { "abcdefgh12345" }, { "Authorization", "Bearer" })
  secrets(
    "https://user:pw123@host.example/p?token=t0k&q=1",
    { "pw123", "t0k" },
    { "host.example", "q=1" }
  )
  secrets(
    "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123",
    { "ghp_abcdefghijklmnopqrstuvwxyz0123" },
    { "GITHUB_TOKEN" }
  )
  secrets("--password hunter2 --verbose", { "hunter2" }, { "--password", "--verbose" })
  secrets("key sk-abcdefghijklmnopqrstuvwx used", { "sk-abcdefghijklmnopqrstuvwx" }, { "used" })
  secrets("AKIAABCDEFGHIJKLMNOP", { "AKIAABCDEFGHIJKLMNOP" })
  -- ordinary text stays readable
  eq(
    ledger.redact_secrets("passed: 5 tests --author=Stefan Basic setup"),
    "passed: 5 tests --author=Stefan Basic setup",
    "no false positives on ordinary words"
  )
  eq(
    ledger.format_argv({ "curl", "--token", "abc", "-H", "X: y", "a b" }),
    'curl --token <REDACTED> -H "X: y" "a b"',
    "argv: a secret flag masks its value, arguments with spaces are quoted"
  )
  eq(ledger.redact_secrets(""), "", "empty text")

  -- ---------------------------------------------------------------- merge / determinism
  local a, c = ledger.new(), ledger.new()
  a:add("spawned", "git status")
  a:add("network", "dns a.example")
  c:add("spawned", "git status")
  c:add("spawned", "ls", { blocked = true })
  c:add("network", "dns b.example")
  local ab, ba = ledger.new(), ledger.new()
  ok(ab:merge(a) and ab:merge(c), "merge of ledgers")
  ok(ba:merge(c) and ba:merge(a), "merge in the other order")
  eq(ab:encode(), ba:encode(), "the merge order does not change a single byte")
  eq(ab:total("spawned"), 3, "counts add up")
  eq(ab:entries("spawned")[1].text, "git status", "merged entry")
  eq(ab:entries("spawned")[1].count, 2, "folded across children")

  local json = ab:encode()
  local back, err = ledger.deserialize(vim.json.decode(json))
  ok(back ~= nil, "a decoded encode() is a ledger again: " .. tostring(err))
  eq(assert(back):encode(), json, "encode -> decode -> deserialize -> encode is stable")
  eq(
    json,
    '{"version":1,"kinds":[{"kind":"network","dropped":0,"entries":[{"text":"dns a.example","count":1},{"text":"dns b.example","count":1}]},{"kind":"spawned","dropped":0,"entries":[{"text":"git status","count":2},{"text":"ls","count":1,"blocked":true}]}]}',
    "the byte layout is fixed (sorted kinds and entries, fixed key order)"
  )

  -- malformed input is refused as a whole, nothing is half merged
  local tgt = ledger.new()
  tgt:add("spawned", "keep")
  local before = tgt:encode()
  for label, bad in pairs({
    version = { version = 2, kinds = {} },
    kinds = { version = 1, kinds = "x" },
    entry = { version = 1, kinds = { { kind = "spawned", entries = { { text = 5, count = 1 } } } } },
    count = {
      version = 1,
      kinds = { { kind = "spawned", entries = { { text = "x", count = 0 } } } },
    },
    mixed = {
      version = 1,
      kinds = {
        { kind = "spawned", entries = { { text = "fine", count = 1 } } },
        { kind = "network", entries = { { text = "bad" } } },
      },
    },
  }) do
    local merged, why = tgt:merge(bad)
    eq(merged, false, label .. ": refused")
    ok(type(why) == "string", label .. ": says why")
    eq(tgt:encode(), before, label .. ": the target is unchanged")
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  eq(select(1, ledger.deserialize("nope")), nil, "a non-table is not a ledger")

  -- the bounds of the receiving ledger apply to a merge
  local small = ledger.new({ max_entries = 1 })
  small:merge(ab)
  eq(#small:entries("spawned"), 1, "merge respects max_entries")
  ok(small:dropped("spawned") >= 1, "and counts what it dropped")

  -- clear
  l:clear()
  eq(l:is_empty(), true, "clear empties the ledger")
end
