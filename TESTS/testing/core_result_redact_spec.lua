-- TESTS/testing/core_result_redact_spec.lua -- the free-text redaction of the Result-IR (`result.encode` with
-- `redact`): a profile path loses its `Users/<name>` segment and nothing else (a `users` directory of a project,
-- a REST route and the `file:line` of an error stay readable), a lowercase `users` is a profile folder only as the
-- first folder below a root (drive, WSL / Cygwin mount, UNC share) where the file system does not tell the spellings
-- apart, the validator (`abs_path_leak`) knows the same shapes, a long token without a blank is read in linear
-- time (by the redaction, by the validator and through `inproc.sanitize`), and `result.normalizer` builds its path
-- matchers once.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local result = require("testing.core.result")
  local json = require("lib.nvim.json")

  local REDACT = { env_names = {}, words = {} }

  ---Encode a one-case IR whose free-text fields all hold `text`, redact it, decode it again.
  ---@param text string
  ---@return table case
  local function redacted(text)
    local ir = {
      cases = {
        {
          id = "a_spec.lua::x",
          assertions = { { msg = text, expected = text, actual = text } },
          error = { message = text, traceback = text },
          notes = { text },
          reason = text,
        },
      },
    }
    local encoded, err = result.encode(ir, { redact = REDACT })
    assert(encoded, err)
    return assert(json.decode(encoded)).cases[1]
  end

  ---@param text string
  ---@return string
  local function msg_of(text)
    return redacted(text).assertions[1].msg
  end

  -- ---------------------------------------------------------------- what is no profile path stays
  for _, text in ipairs({
    "/api/users/42",
    "GET https://example.com/users/profile ok",
    "lua/myapp/users/model.lua:12: attempt to index a nil value",
    "E:/work/proj/lua/myapp/users/model.lua:12: in function 'f'",
    "tests/Users.lua:3: boom",
    -- a lowercase `users` is no profile folder when nothing marks it as the first folder below a root
    "GET /users/42",
    '"/users/42"',
    "expected /users/42 got /users/43",
    "(/users/42)",
    "route:/users/42",
    "see users/42 and /users/",
    "https://h.example/users/42",
    "/api//v1/users/42",
    [[D:\data\users\maria\x]],
    [[\\fs01\data\users\maria\x]],
    "/mnt/c/proj/users/maria/x",
    "/mnt/wsl/users/maria",
  }) do
    local case = redacted(text)
    eq(case.assertions[1].msg, text, "message: " .. text)
    eq(case.assertions[1].expected, text, "expected: " .. text)
    eq(case.error.message, text, "error message: " .. text)
    eq(case.error.traceback, text, "traceback: " .. text)
    eq(case.notes[1], text, "note: " .. text)
    eq(case.reason, text, "reason: " .. text)
  end
  -- the difference that explains a failure survives
  ok(msg_of("/api/users/42") ~= msg_of("/api/users/43"), "expected and actual stay distinguishable")

  -- ---------------------------------------------------------------- a profile path loses its segment
  ---Does the validator report `what` (a part of its finding) for `text` as free text of a note?
  ---@param text string
  ---@param what string
  ---@return boolean
  local function reports(text, what)
    local c = result.new_case({ file = "a_spec.lua", name = "x" })
    c.assertions[1] = { ok = true, kind = "eq" }
    c.notes = { text }
    result.finish_case(c)
    local ir = result.new({ id = "2026-10-08T10:00:00Z-0011", nvim = "0.12.0", os = "linux" })
    result.add_case(ir, c)
    result.finalize(ir)
    local sink = {}
    local valid = result.validate(ir, { leak_warnings = sink })
    ok(valid, "the fixture of the validator is a valid IR")
    for _, finding in ipairs(sink) do
      if finding:find(what, 1, true) then
        return true
      end
    end
    return false
  end

  ---Does the validator (`abs_path_leak`) refuse `text` as a user home path?
  ---@param text string
  ---@return boolean
  local function leaks(text)
    return reports(text, "user home path")
  end

  ---Does the validator refuse `text` as an e-mail address?
  ---@param text string
  ---@return boolean
  local function mails(text)
    return reports(text, "e-mail address")
  end

  -- Which `users` is a profile folder: `Users` with a capital U wherever it stands; any other spelling only as the
  -- first folder below a root that does not tell the spellings apart (a drive, `/mnt/<letter>`, `/cygdrive/<letter>`,
  -- a UNC share; `//host/users` unless a `:` or a word in front makes it the tail of a URL). The validator knows the
  -- same shapes, so it neither lets one through nor refuses a project directory.
  for _, text in ipairs({
    "GET /users/42",
    "route:/users/42",
    "https://h.example/users/42",
    "/api//v1/users/42",
    [[D:\data\users\maria\x]],
    [[\\fs01\data\users\maria\x]],
    "/mnt/c/proj/users/maria/x",
    "E:/work/proj/lua/myapp/users/model.lua:12: in function 'f'",
    "the /Users/ folder",
  }) do
    ok(not leaks(text), "the validator leaves a project directory alone: " .. text)
  end
  for _, text in ipairs({
    "/Users/maria/x",
    "C:/Users/maria",
    "/mnt/c/users/maria/x",
    [[\\fs01\users\maria\x]],
    "//fs01/users/maria/x",
    [[c:\USERS\bob]],
    "/cygdrive/d/Users//bob",
  }) do
    ok(leaks(text), "the validator refuses a profile path: " .. text)
  end

  local LEAK = "[/\\]Users[/\\][^/\\%s]" -- what the validator (`abs_path_leak`) refuses
  for _, case in ipairs({
    -- a lowercase or upper-case spelling as the first folder below a root, the name goes
    { [[\\fs01\users\maria\x]], "maria", [[\\fs01\<USER-PATH>\x]] },
    { "//fs01/users/maria/x", "maria", "//fs01/<USER-PATH>/x" },
    { "wrote //fs01/users/maria/x", "maria", "wrote //fs01/<USER-PATH>/x" },
    -- (written like this at the start of a token it cannot be told from a protocol-relative URL: the private reading wins)
    { "//cdn.example/users/42", "42", "//cdn.example/<USER-PATH>" },
    { '"//fs01/USERS/maria"', "maria", '"//fs01/<USER-PATH>"' },
    { "/mnt/c/users/maria/x", "maria", "/mnt/c/<USER-PATH>/x" },
    { "see /mnt/d/USERS//bob/x", "bob", "see /mnt/d/<USER-PATH>/x" },
    { "/cygdrive/c/users/maria", "maria", "/cygdrive/c/<USER-PATH>" },
    { [[wrote c:\users\bob\x]], "bob", [[wrote <HOME>\x]] },
    { "wrote C:/USERS/bob/x", "bob", "wrote <HOME>/x" },
    { "C:/users/'bob'", "", "C:/<USER-PATH>'bob'" },
    { "see /Users/bob/x", "bob", "see <HOME>/x" },
    { "file:/Users/42", "42", "file:<HOME>" },
    { "/mnt/c/Users/maria/y", "maria", "/mnt/c/<USER-PATH>/y" },
    { [[\\fs01\data\Users\bob]], "bob", [[\\fs01\data\<USER-PATH>]] },
    { [[D:\Data\Users\bob\x]], "bob", [[D:\Data\<USER-PATH>\x]] },
    { [[\Users\jdoe at the start]], "jdoe", [[\<USER-PATH> at the start]] },
    { "/Users/jdoe", "jdoe", "/<USER-PATH>" },
    {
      "https://kunde.example/Users/maria/a.txt",
      "maria",
      "https://kunde.example/<USER-PATH>/a.txt",
    },
    { [[//host/share/Users//maria/x]], "maria", "//host/share/<USER-PATH>/x" },
    { [["/srv/Users/maria"]], "maria", [["/srv/<USER-PATH>"]] },
    { "/srv/Users/<name>/z", "", "/srv/<USER-PATH><name>/z" },
  }) do
    local text, name, want = case[1], case[2], case[3]
    local got = msg_of(text)
    eq(got, want, "the segment goes, the rest stays: " .. text)
    ok(not got:find(LEAK), "the validator finds nothing in " .. got)
    ok(leaks(text), "the validator refuses the text before: " .. text)
    ok(not leaks(got), "and finds nothing in " .. got)
    ok(name == "" or not got:find(name, 1, true), "the name is gone from " .. got)
  end
  -- nothing follows the separator: no name, nothing to remove
  eq(msg_of("the /Users/ folder"), "the /Users/ folder", "a bare Users directory is no leak")

  -- ---------------------------------------------------------------- e-mail shapes
  eq(msg_of("mail bob@example.com now"), "mail <EMAIL> now", "an address is replaced")
  eq(msg_of("a.b+c@d-e.example.org"), "<EMAIL>", "the whole address, dots and plus included")
  eq(msg_of("a@b.co"), "<EMAIL>", "a local part of one letter at the start of the text")
  ok(mails("a@b.co"), "the validator finds it, too")
  eq(msg_of("no at sign here"), "no at sign here", "text without an address")
  for _, text in ipairs({
    "bob@localhost",
    "bob@x",
    "bob@x.c",
    "bob@.com",
    "@example.com",
    "bob @example.com",
    "bob@ example.com",
    "bob@, example.com",
    "a@@b.com",
    "user@<EMAIL>",
  }) do
    eq(msg_of(text), text, "no address, nothing to remove: " .. text)
    ok(not mails(text), "the validator leaves it alone, too: " .. text)
  end

  -- An `@` right behind an address has no local part of its own: the characters in front of it belong to the domain
  -- that was just read.
  eq(msg_of("a@b.com@c.org"), "<EMAIL>@c.org", "an @ behind an address has no local part")
  ok(
    mails("a@b.com@c.org") and not mails("<EMAIL>@c.org"),
    "and the validator reads it the same way"
  )

  -- Addresses that follow each other without a separator: the next one begins inside the run of characters the last one
  -- ended in (`.com1alice` is the end of one domain and the start of the next local part), and it is the local part
  -- that must go: a name left in front of a placeholder is the leak. However many there are; the validator finds the
  -- text before and nothing after, so the redaction changes a text exactly when the validator refuses it.
  for _, case in ipairs({
    { "a@b.com1@c.org", "<EMAIL><EMAIL>", {} },
    { "bob@x.com1alice@y.org1carol@z.org", "<EMAIL><EMAIL><EMAIL>", { "bob", "alice", "carol" } },
    { "x@y.com_alice@z.org_carol@w.org", "<EMAIL><EMAIL><EMAIL>", { "alice", "carol" } },
    {
      "report-bob@x.com-alice@y.org-carol@w.org.pdf",
      "<EMAIL><EMAIL><EMAIL>",
      { "bob", "alice", "carol" },
    },
    { "a@b.com1c@d.org1e@f.org1g@h.org1i@j.org", ("<EMAIL>"):rep(5), { "1c", "1e", "1g", "1i" } },
    { ("a@b.co1"):rep(8), ("<EMAIL>"):rep(8) .. "1", {} },
    {
      "mail bob@x.com1alice@y.org, carol@z.org.",
      "mail <EMAIL><EMAIL>, <EMAIL>.",
      { "alice", "carol" },
    },
  }) do
    local text, want, names = case[1], case[2], case[3]
    local got = msg_of(text)
    eq(got, want, "every address goes: " .. text)
    ok(mails(text), "the validator refuses the text before: " .. text)
    ok(not mails(got), "and finds nothing in " .. got)
    ok(not got:find("@", 1, true), "no half of an address is left in " .. got)
    for _, name in ipairs(names) do
      ok(not got:find(name, 1, true), name .. " is gone from " .. got)
    end
  end

  -- ---------------------------------------------------------------- linear in the length of a token
  -- One token without a blank was re-scanned from every position by the patterns of the redaction (quadratic:
  -- 20 000 bytes took seconds, 40 000 more than twenty). A linear pass over 60 000 bytes takes milliseconds.
  local SIZE, LIMIT_MS = 60000, 1500
  local shapes = {
    run = ("x"):rep(SIZE),
    path = ("a/"):rep(SIZE / 2),
    dotted = ("a."):rep(SIZE / 2),
    at_then_run = "a@" .. ("a"):rep(SIZE),
    profile_chain = ("/Users/x"):rep(SIZE / 8),
    address_like = ("a.b@"):rep(SIZE / 4),
    -- the e-mail scan: a long local part without a domain, an `@` after every character, a domain of dots, and
    -- addresses written one after the other without a separator
    local_then_at = ("a"):rep(SIZE) .. "@",
    at_pairs = ("a@"):rep(SIZE / 2),
    at_then_dots = "a@" .. ("a."):rep(SIZE / 2),
    glued_addresses = ("a@b.co1"):rep(SIZE / 7),
    -- runs of separators: the prefix of a rule that is itself a separator re-reads the run from every position
    slashes = ("/"):rep(SIZE),
    backslashes = ("\\"):rep(SIZE),
    drive_slashes = "a:" .. ("/"):rep(SIZE),
    spaced_slashes = (" " .. ("/"):rep(7)):rep(SIZE / 8),
    -- the roots of a lowercase `users`: mounts and UNC shares written one after the other
    mounts = ("/mnt/c/"):rep(SIZE / 7),
    drives = ("c:/"):rep(SIZE / 3),
    unc_hosts = ("//a"):rep(SIZE / 3),
    unc_host = "//" .. ("x"):rep(SIZE),
    unc_roots = ("//h/users"):rep(SIZE / 9),
    lowercase_chain = ("/users/x"):rep(SIZE / 8),
  }
  for name, text in pairs(shapes) do
    local t0 = vim.uv.hrtime()
    redacted(text)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < LIMIT_MS, ("redacting %s (%d bytes) took %.0f ms"):format(name, #text, ms))
  end

  -- The validator reads the same texts (`inproc.sanitize` runs it after every redaction, over every free-text field):
  -- its e-mail pattern started a read at every position of a run (30 000 bytes without an `@` took five seconds, `a@`
  -- and 30 000 more ten), and a message with a long token costs that per field.
  for name, text in pairs(shapes) do
    local t0 = vim.uv.hrtime()
    leaks(text)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < LIMIT_MS, ("validating %s (%d bytes) took %.0f ms"):format(name, #text, ms))
  end
  do
    local inproc = require("testing.run.inproc")
    local SANITIZED = 40000 -- four fields of this size go through the redaction and the validator
    for name, text in pairs({
      run = ("x"):rep(SANITIZED),
      at_then_run = "a@" .. ("a"):rep(SANITIZED),
      slashes = ("/"):rep(SANITIZED),
      token_hex = ("0123456789abcdef"):rep(SANITIZED / 16),
    }) do
      local c = result.new_case({ file = "TESTS/a_spec.lua", name = "x" })
      c.assertions[1] = { ok = false, kind = "eq", msg = text, expected = text, actual = text }
      c.notes = { text }
      result.finish_case(c)
      local ir = result.new({ id = "2026-10-08T10:00:00Z-0012", nvim = "0.12.0", os = "linux" })
      result.add_case(ir, c)
      result.finalize(ir)
      local t0 = vim.uv.hrtime()
      local decoded, _, err = inproc.sanitize(ir, "E:/repos/demo")
      local ms = (vim.uv.hrtime() - t0) / 1e6
      ok(decoded ~= nil, "sanitize works on " .. name .. ": " .. tostring(err))
      ok(ms < LIMIT_MS, ("sanitizing %s (4 x %d bytes) took %.0f ms"):format(name, #text, ms))
    end
  end

  -- ---------------------------------------------------------------- normalizer: matchers once
  local here = vim.fs.normalize(vim.uv.cwd() or ".")
  local tmp = vim.fs.normalize(vim.uv.os_tmpdir() or here)
  local roots = { repo = here, tmp = tmp }
  local real = vim.uv.fs_realpath
  local calls = 0
  vim.uv.fs_realpath = function(...)
    calls = calls + 1
    return real(...)
  end
  local good, err = pcall(function()
    local normalize = result.normalizer(roots)
    eq(calls, 0, "nothing is resolved before the first text")
    local first = normalize(here .. "/x.lua")
    local resolved = calls
    ok(resolved > 0 and resolved <= 2, "one realpath per root on the first text, got " .. resolved)
    for _ = 1, 25 do
      normalize("short " .. here .. "/y.lua text")
      normalize("no path at all")
    end
    eq(calls, resolved, "the next texts resolve nothing again")
    eq(first, "<REPO>/x.lua", "and the path is still a placeholder")
    eq(normalize({ n = here .. "/z" }), { n = "<REPO>/z" }, "a table is normalized in depth")
    eq(
      result.normalize(here .. "/x.lua", roots),
      first,
      "result.normalize is the one-shot form of the same function"
    )
  end)
  vim.uv.fs_realpath = real
  ok(good, tostring(err))
end
