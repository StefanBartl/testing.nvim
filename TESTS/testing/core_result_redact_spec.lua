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
  ---Does the validator (`abs_path_leak`) refuse `text` as free text of a note?
  ---@param text string
  ---@return boolean
  local function leaks(text)
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
      if finding:find("user home path", 1, true) then
        return true
      end
    end
    return false
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
  eq(msg_of("no at sign here"), "no at sign here", "text without an address")

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
