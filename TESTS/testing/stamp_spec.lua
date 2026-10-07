-- TESTS/testing/stamp_spec.lua -- the stamp format and its untrusted-input rules: SHA-256/HMAC against known
-- vectors, the canonical text, validation of every field of a file that anyone may have edited, the age and origin
-- rules, the own flags of `stamp` and `verify`, the git facts (injected git, argv only).

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 400))
    )
  end

  local sha = require("testing.stamp.sha")
  local stamp = require("testing.stamp")
  local scli = require("testing.stamp.cli")
  local collect = require("testing.stamp.collect")
  local write = require("testing.stamp.write")

  local K1 = ("a"):rep(64)
  local K2 = ("b"):rep(64)
  local TREE = ("c"):rep(40)

  local function sample(extra)
    extra = extra or {}
    return stamp.build({
      head = {
        commit = ("d"):rep(40),
        tree = TREE,
        dirty = false,
        run = "run-1",
        ts = 1700000000,
        summary = { files = 3, keyed = 2, cases = 5, cached = 1, ran = 2 },
      },
      origin = extra.origin or { kind = "local", trusted = false },
      env = { runner = "r1", nvim = "v0.12.0|api14", os = "Windows/x64", config = "cfg1" },
      -- deliberately unsorted: the stamp sorts by byte order
      records = extra.records or {
        { file = "TESTS/b_spec.lua", uncacheable = "reads the clock" },
        { file = "TESTS/a_spec.lua", key = K1 },
        { file = "TESTS/Z_spec.lua", key = K2 },
      },
      secret = extra.secret,
    })
  end

  ---Encode, let `mutate` change the decoded table, decode again (what a forger with an editor does).
  ---@param st table
  ---@param mutate fun(raw: table)
  ---@return table|nil, string|nil
  local function forge(st, mutate)
    local raw = vim.json.decode((stamp.encode(st)))
    mutate(raw)
    return stamp.decode(vim.json.encode(raw))
  end

  -- ---------------------------------------------------------------- SHA-256 and HMAC (no NUL trouble)
  for _, m in ipairs({ "", "abc", ("a"):rep(55), ("a"):rep(56), ("a"):rep(64), ("xyz"):rep(777) }) do
    eq(sha.hex(m), vim.fn.sha256(m), "sha256 of " .. #m .. " bytes equals the editor's")
  end
  eq(
    sha.hmac(("\11"):rep(20), "Hi There"),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
    "RFC 4231 test case 1"
  )
  eq(
    sha.hmac("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
    "RFC 4231 test case 2"
  )
  eq(
    sha.hmac(("\170"):rep(131), "Test Using Larger Than Block-Size Key - Hash Key First"),
    "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
    "RFC 4231 test case 6: a key longer than the block is hashed first"
  )
  ok(sha.equal("abc", "abc"), "equal strings are equal")
  ok(not sha.equal("abc", "abd"), "a differing last byte is not equal")
  ok(not sha.equal("abc", "ab"), "another length is not equal")
  ok(not sha.equal("abc", nil), "nil is not equal")

  -- ---------------------------------------------------------------- the canonical text
  local st = sample()
  eq(
    vim.tbl_map(function(f)
      return f.file
    end, st.files),
    { "TESTS/Z_spec.lua", "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
    "files are sorted by BYTE order (upper case before lower case), whatever the locale"
  )
  eq(stamp.payload(st), stamp.payload(sample()), "the same facts give the same bytes")
  eq(st.digest, vim.fn.sha256(stamp.payload(st)), "the digest is the hash of the canonical text")
  eq(st.hmac, nil, "no secret: no HMAC")
  local mac = sample({ secret = ("s"):rep(20) })
  eq(mac.hmac, sha.hmac(("s"):rep(20), stamp.payload(mac)), "with a secret: the HMAC of the text")
  ok(stamp.hmac_ok(mac, ("s"):rep(20)), "the right secret checks")
  ok(not stamp.hmac_ok(mac, ("t"):rep(20)), "another secret does not")
  ok(not stamp.hmac_ok(st, ("s"):rep(20)), "a stamp without HMAC never checks")
  local text = stamp.encode(mac)
  ok(not text:find(("s"):rep(20), 1, true), "the secret is not in the file")
  ok(not text:find("[A-Za-z]:[/\\]"), "no absolute path in the file")

  -- ---------------------------------------------------------------- round trip
  local back, why = stamp.decode((stamp.encode(mac)))
  ok(back, "a stamp reads back: " .. tostring(why))
  eq(back.files, mac.files, "files survive")
  eq(back.digest, mac.digest, "digest survives")
  eq(back.head.run, "run-1", "head survives")
  eq(back.head.summary.keyed, 2, "the display summary survives")
  ok(stamp.hmac_ok(back, ("s"):rep(20)), "the HMAC still checks after the round trip")

  -- ---------------------------------------------------------------- hostile files
  local function refuses(mutate, needle, msg)
    local got, w = forge(mac, mutate)
    ok(got == nil, msg .. ": refused")
    has(w, needle, msg .. ": says why")
  end
  refuses(function(r)
    r.schema = "testing-stamp/2"
  end, "unknown schema", "another schema")
  refuses(function(r)
    r.v = 2
  end, "unknown schema", "another version")
  refuses(function(r)
    r.head.ts = -1
  end, "timestamp", "a negative time")
  refuses(function(r)
    r.head.ts = 1.5
  end, "timestamp", "a fractional time")
  refuses(function(r)
    r.head.ts = 99999999999
  end, "timestamp", "a time after 2100")
  refuses(function(r)
    r.head.ts = "1700000000"
  end, "timestamp", "a time as text")
  refuses(function(r)
    r.head.commit = "not-hex"
  end, "commit", "a bad commit")
  refuses(function(r)
    r.head.tree = ("c"):rep(39)
  end, "tree", "a bad tree length")
  refuses(function(r)
    r.head.run = "a\nb"
  end, "run id", "a control character in the run id")
  refuses(function(r)
    r.origin.kind = "cloud"
  end, "origin", "an unknown origin kind")
  refuses(function(r)
    r.origin.trusted = "yes"
  end, "origin", "a non-boolean trust flag")
  refuses(function(r)
    r.origin.ref = "refs/heads/x y"
  end, "origin ref", "a space in the ref")
  refuses(function(r)
    r.env.nvim = 5
  end, "environment", "a number as a version")
  refuses(function(r)
    r.env.os = "a\27[31mb"
  end, "environment", "an escape sequence in an environment fact")
  refuses(function(r)
    r.files = {}
  end, "no files", "no files")
  refuses(function(r)
    r.files = { a = r.files[1] }
  end, "no files", "files as an object")
  refuses(function(r)
    r.files[1].file = "../x_spec.lua"
  end, "bad file entry", "a path that climbs out")
  refuses(function(r)
    r.files[1].file = "/etc/passwd"
  end, "bad file entry", "an absolute path")
  refuses(function(r)
    r.files[1].file = "C:/x.lua"
  end, "bad file entry", "a drive path")
  refuses(function(r)
    r.files[1].file = "a\\b.lua"
  end, "bad file entry", "a backslash")
  refuses(function(r)
    r.files[2].file = r.files[1].file
  end, "ascending", "a duplicate file")
  refuses(function(r)
    r.files[1], r.files[2] = r.files[2], r.files[1]
  end, "ascending", "unsorted files")
  refuses(function(r)
    r.files[2].key = "short"
  end, "bad key", "a short key")
  refuses(function(r)
    r.files[2].key = ("A"):rep(64)
  end, "bad key", "an upper case key")
  refuses(function(r)
    r.files[3].uncacheable = "line\nbreak"
  end, "bad reason", "a newline in a reason")
  refuses(function(r)
    r.files[3].uncacheable = ("x"):rep(stamp.MAX_REASON + 1)
  end, "bad reason", "an over-long reason")
  refuses(function(r)
    r.files[2].uncacheable = "also a reason"
  end, "bad key", "a file that has both a key and a reason")
  refuses(function(r)
    r.digest = ("0"):rep(64)
  end, "digest does not match", "a digest that does not match")
  refuses(function(r)
    r.files[1].key = K1
    r.files[2].key = K2
  end, "digest does not match", "keys edited without a new digest")
  refuses(function(r)
    r.hmac = "zz"
  end, "bad hmac", "a malformed HMAC")
  local huge = { schema = stamp.SCHEMA, v = 1, files = {} }
  for i = 1, stamp.MAX_FILES + 1 do
    huge.files[i] = { file = ("f%06d"):format(i), key = K1 }
  end
  has(select(2, stamp.validate(huge)), "head", "a huge file list is judged by its head first")
  local big = stamp.decode(("x"):rep(stamp.MAX_BYTES + 1))
  eq(big, nil, "a file over the size cap is refused before it is decoded")
  has(select(2, stamp.decode(("x"):rep(stamp.MAX_BYTES + 1))), "larger than", "and says so")
  eq(stamp.decode("not json"), nil, "text that is not JSON")
  eq(stamp.decode("[1,2]"), nil, "a JSON array")
  eq(stamp.decode("null"), nil, "JSON null")
  eq(stamp.decode(nil), nil, "nothing")
  -- an unknown extra field is dropped, never carried
  local extra = forge(mac, function(r)
    r.head.evil = "x"
    r.extra = { 1 }
  end)
  ok(extra and extra.extra == nil and extra.head.evil == nil, "unknown fields are dropped")
  -- a stamp may not hold the order of its own payload hostage: edited run id changes the digest
  refuses(function(r)
    r.head.run = "run-2"
  end, "digest does not match", "an edited run id")

  -- ---------------------------------------------------------------- age and the clock
  eq(stamp.parse_age("7d"), 7 * 86400, "days")
  eq(stamp.parse_age("12h"), 12 * 3600, "hours")
  eq(stamp.parse_age("30m"), 1800, "minutes")
  eq(stamp.parse_age("90s"), 90, "seconds")
  eq(stamp.parse_age("90"), 90, "a bare number is seconds")
  eq(stamp.parse_age("0"), nil, "zero is refused")
  eq(stamp.parse_age("-1d"), nil, "negative is refused")
  eq(stamp.parse_age("9999d"), nil, "more than ten years is refused")
  eq(stamp.parse_age("7 d"), nil, "a space is refused")
  eq(stamp.parse_age("forever"), nil, "a word is refused")
  eq(stamp.parse_age(nil), nil, "no value")
  eq(stamp.DEFAULT_MAX_AGE, 7 * 86400, "the default limit is 7 days")

  -- ---------------------------------------------------------------- where it was written
  local function env_of(t)
    return function(name)
      return t[name]
    end
  end
  eq(stamp.origin(env_of({})).kind, "local", "no CI variable: local")
  eq(stamp.origin(env_of({})).trusted, false, "a local stamp is not a trusted CI stamp")
  local o = stamp.origin(
    env_of({ CI = "true", GITHUB_EVENT_NAME = "push", GITHUB_REF = "refs/heads/main" })
  )
  eq(
    { o.kind, o.event, o.ref, o.trusted },
    { "ci", "push", "refs/heads/main", true },
    "a push to main is trusted"
  )
  o = stamp.origin(
    env_of({ CI = "true", GITHUB_EVENT_NAME = "pull_request", GITHUB_REF = "refs/pull/3/merge" })
  )
  eq(o.trusted, false, "a pull request never writes a trusted stamp")
  o = stamp.origin(env_of({
    CI = "true",
    GITHUB_EVENT_NAME = "pull_request_target",
    GITHUB_REF = "refs/heads/main",
  }))
  eq(o.trusted, false, "not even pull_request_target on main")
  o = stamp.origin(
    env_of({ CI = "true", GITHUB_EVENT_NAME = "push", GITHUB_REF = "refs/heads/feature" })
  )
  eq(o.trusted, false, "a push to another branch is not trusted")
  o = stamp.origin(env_of({
    CI = "true",
    GITHUB_EVENT_NAME = "push",
    GITHUB_REF = "refs/heads/release",
    TESTING_STAMP_TRUSTED_REFS = "refs/heads/release, refs/heads/main",
  }))
  eq(o.trusted, true, "the trusted refs are configurable")
  o = stamp.origin(env_of({ CI = "true" }))
  eq(
    { o.kind, o.trusted },
    { "ci", false },
    "a CI run that cannot say its event or ref is not trusted"
  )
  o = stamp.origin(
    env_of({ CI = "true", GITHUB_EVENT_NAME = "push\nx", GITHUB_REF = "refs/heads/main" })
  )
  eq(o.event, nil, "a hostile event name is not recorded")
  eq(o.trusted, false, "and does not count as trusted")

  -- ---------------------------------------------------------------- own flags of stamp and verify
  local rest, own, bad = scli.split_argv({
    "verify",
    ".",
    "--stamp",
    "a.json",
    "--json",
    "--max-age=2d",
    "--isolated",
    "file",
  })
  eq(bad, nil, "verify flags parse")
  eq(
    rest,
    { "verify", ".", "--isolated", "file" },
    "the run options stay for the parser, the command word stays"
  )
  eq(
    { own.stamp, own.json, own.max_age, own.allow_dirty, own.from_note, own.require_hmac },
    { "a.json", true, 2 * 86400, false, false, false },
    "verify own flags"
  )
  rest, own = scli.split_argv({ "stamp", ".", "--out", "s.json", "--note", "--jobs", "2" })
  eq(rest, { ".", "--jobs", "2" }, "stamp: the command word goes, the run options stay")
  eq({ own.out, own.note, own.command }, { "s.json", true, "stamp" }, "stamp own flags")
  bad = select(3, scli.split_argv({ "verify", ".", "--stamp" }))
  has(bad, "needs a value", "a flag without its value")
  bad = select(3, scli.split_argv({ "verify", ".", "--stamp", "--json" }))
  has(bad, "needs a value", "a flag followed by a flag has no value")
  bad = select(3, scli.split_argv({ "verify", ".", "--max-age", "soon" }))
  has(bad, "--max-age", "a bad duration is a usage error")
  rest = scli.split_argv({ "verify", ".", "--", "--json" })
  eq(rest, { "verify", ".", "--", "--json" }, "after `--` nothing is taken out")

  -- ---------------------------------------------------------------- what makes a run no stamp run
  local args_mod = require("testing.args")
  local function refused(argv)
    return write.refuse(assert(args_mod.parse(argv)))
  end
  eq(refused({ "." }), nil, "a plain run is fine")
  eq(
    refused({ ".", "--cached", "--jobs", "2", "--isolated", "file" }),
    nil,
    "cache and isolation are fine"
  )
  for _, flag in ipairs({
    { ".", "--changed" },
    { ".", "--since", "HEAD~1" },
    { ".", "--affected" },
    { ".", "--filter", "x" },
    { ".", "--file", "x" },
    { ".", "--tags", "x" },
    { ".", "--exclude-tags", "x" },
    { ".", "--lf" },
    { ".", "--shard", "1/2" },
    { ".", "--maxfail", "1" },
    { ".", "--list" },
    { ".", "--watch" },
    { ".", "TESTS/a_spec.lua" },
    { ".", "--shuffle" },
  }) do
    ok(refused(flag) ~= nil, "refused: " .. table.concat(flag, " "))
  end
  local secret, problem = write.secret(env_of({}))
  eq({ secret, problem }, {}, "no secret, no problem")
  secret, problem = write.secret(env_of({ TESTING_STAMP_SECRET = "q9x7" }))
  eq(secret, nil, "a short secret is not used")
  has(problem, "shorter than", "and refused")
  ok(not problem:find("q9x7", 1, true), "the message does not echo the secret")
  secret = write.secret(env_of({ TESTING_STAMP_SECRET = ("k"):rep(16) }))
  eq(secret, ("k"):rep(16), "a long enough secret is used")

  -- ---------------------------------------------------------------- git facts (argv only, injected git)
  local calls = {}
  local function fake(status_out, opts)
    opts = opts or {}
    return function(argv)
      calls[#calls + 1] = argv
      local sub = argv[2]
      if sub == "rev-parse" and argv[3] == "HEAD" then
        return { code = opts.no_commit and 128 or 0, stdout = ("e"):rep(40) .. "\n", stderr = "" }
      elseif sub == "rev-parse" then
        return { code = 0, stdout = TREE .. "\n", stderr = "" }
      elseif sub == "status" then
        return { code = opts.no_git and 128 or 0, stdout = status_out, stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "" }
    end
  end
  local facts = collect.git_facts("/x", fake(""))
  eq(
    { facts.git, facts.dirty, facts.commit, facts.tree },
    { true, false, ("e"):rep(40), TREE },
    "a clean tree"
  )
  for _, argv in ipairs(calls) do
    eq(argv[1], "git", "every call is an argv list starting with git")
    for _, a in ipairs(argv) do
      ok(type(a) == "string" and not a:find("[;&|`]"), "no shell syntax in an argument: " .. a)
    end
  end
  facts = collect.git_facts("/x", fake("M  a.lua\0?? b.lua\0 M c.lua\0"))
  eq(
    { facts.dirty, facts.changed_count, facts.changes },
    { true, 3, { "a.lua", "b.lua", "c.lua" } },
    "a dirty tree names the changes"
  )
  facts = collect.git_facts("/x", fake("", { no_git = true }))
  eq(facts.git, false, "not a git checkout")
  facts = collect.git_facts("/x", fake("", { no_commit = true }))
  eq({ facts.git, facts.commit }, { true, nil }, "no commit yet")
  local hostile = collect.git_facts("/x", function(argv)
    if argv[3] == "HEAD" then
      return { code = 0, stdout = "--upload-pack=evil\n", stderr = "" }
    end
    return { code = 0, stdout = "", stderr = "" }
  end)
  eq(hostile.commit, nil, "something that is not an object id is dropped, never passed on")
  local nok, nerr = collect.note_write("/x", "--evil", "f", function()
    error("git must not be called")
  end)
  eq({ nok }, { false }, "a note is never attached to something that is not an object id")
  has(nerr, "no tree", "and says so")
  eq(
    collect.note_read("/x", "refs/heads/x", function()
      error("git must not be called")
    end),
    nil,
    "a note is never looked up for a name that is not an object id"
  )

  -- ---------------------------------------------------------------- reasons are cleaned
  eq(
    collect.clean_reason("reads 'C:/p/x' here\nand\27[31m there", "C:/p"),
    "reads '<root>/x' here and [31m there",
    "the root and control characters go"
  )
  ok(#collect.clean_reason(("y"):rep(1000), "") <= stamp.MAX_REASON, "a reason is capped")
  eq(collect.clean_reason("", ""), "no key", "an empty reason has a text")
end
