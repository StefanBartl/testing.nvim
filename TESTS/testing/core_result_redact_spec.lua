-- TESTS/testing/core_result_redact_spec.lua -- the free-text redaction of the Result-IR (`result.encode` with
-- `redact`): a profile path loses its `Users/<name>` segment and nothing else (a `users` directory of a project,
-- a REST route and the `file:line` of an error stay readable), a long token without a blank is read in linear
-- time, and `result.normalizer` builds its path matchers once.

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
  local LEAK = "[/\\]Users[/\\][^/\\%s]" -- what the validator (`abs_path_leak`) refuses
  for _, case in ipairs({
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
  }
  for name, text in pairs(shapes) do
    local t0 = vim.uv.hrtime()
    redacted(text)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < LIMIT_MS, ("redacting %s (%d bytes) took %.0f ms"):format(name, #text, ms))
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
