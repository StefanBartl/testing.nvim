-- TESTS/testing/guard_ledger_argv_spec.lua -- secrets that sit in the argv of a spawned process
-- (curl -u, X-*-Token headers, -p, ?key=, JWT, cookies, JSON bodies) never reach the ledger / IR
-- (SEC-22), and ordinary command lines stay readable.

return function(H)
  local ok, eq = H.ok, H.eq
  local ledger = require("testing.core.ledger")

  local function gone(line, secret)
    local out = ledger.redact_secrets(line)
    ok(not out:find(secret, 1, true), ("%q must be gone from %q"):format(secret, out))
    local argv_out = ledger.format_argv(vim.split(line, " ", { plain = true }))
    ok(
      not argv_out:find(secret, 1, true),
      ("%q must be gone from argv form %q"):format(secret, argv_out)
    )
  end

  gone("curl -u admin:hunter2 https://h.example/x", "hunter2")
  gone("curl --user admin:hunter2 https://h.example/x", "hunter2")
  gone("curl --user=admin:hunter2 https://h.example/x", "hunter2")
  -- the one-letter flags of curl also take their value attached
  gone("curl -uadmin:hunter2 https://h.example/x", "hunter2")
  gone("curl -Uproxyuser:hunter2 https://h.example/x", "hunter2")
  gone("curl -bsid=abcdef https://h.example", "abcdef")
  gone('curl -H "X-Api-Token: abcdef123456" https://h.example/x', "abcdef123456")
  gone('curl -H "X-Auth-Key: abcdef123456" https://h.example/x', "abcdef123456")
  gone('curl -H "Authorization: token abcdef" https://h.example', "abcdef")
  gone('curl -H "Cookie: sid=abcdef; theme=dark" https://h.example', "abcdef")
  gone('curl -b "sid=abcdef" https://h.example', "abcdef")
  gone("curl --cookie sid=abcdef https://h.example", "abcdef")
  gone("mysql -pHunter2 -h db", "Hunter2")
  gone("sshpass -p hunter2 ssh host", "hunter2")
  gone("docker login -u me -p hunter2 registry.example", "hunter2")
  gone("curl https://h.example/f?sig=SIGVALUE1&key=ZZZZ9999&q=1", "ZZZZ9999")
  gone("curl https://h.example/f?sig=SIGVALUE1&key=ZZZZ9999&q=1", "SIGVALUE1")
  gone("echo xoxb-1234567890-abcdefghijkl", "abcdefghijkl")
  gone("echo eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl", "c2lnbmF0dXJl")
  gone([[curl -d {"password":"hunter2","user":"a"} https://h.example]], "hunter2")
  gone([[curl -d '{"api_key": "hunter2"}' https://h.example]], "hunter2")
  gone([[curl -d {\"password\":\"hunter2\"} https://h.example]], "hunter2")

  -- the surrounding structure stays readable
  local out = ledger.redact_secrets('curl -H "Authorization: token abcdef" https://h.example/x')
  ok(out:find("Authorization", 1, true) and out:find("https://h.example/x", 1, true), out)
  out = ledger.redact_secrets("curl https://h.example/f?sig=S1&key=K1&q=1")
  ok(out:find("q=1", 1, true) and out:find("h.example/f", 1, true), out)

  -- no false positives on ordinary command lines
  for _, line in ipairs({
    "git checkout -b feature/x",
    "ssh -p 2222 host",
    "docker run -u 1000:1000 img",
    "ls -u",
    "nvim --headless -u NONE -l script.lua",
    "make -j4 key",
    "git commit -m 'passed: 5 tests'",
    "wget -b https://h.example/f",
    "curl -sS --user-agent nvim-test https://h.example/x",
    "curl -fsSL -o out.txt https://h.example/x",
  }) do
    eq(ledger.redact_secrets(line), line, "unchanged: " .. line)
  end

  -- URL user info keeps working for every scheme shape the rule knows
  eq(
    ledger.redact_secrets("git clone https://me:pw@h.example/r.git"),
    "git clone https://<REDACTED>@h.example/r.git",
    "url user info"
  )
  eq(
    ledger.redact_secrets("git+ssh://me@h.example/r.git x1.y-z://u:p@h"),
    "git+ssh://<REDACTED>@h.example/r.git x1.y-z://<REDACTED>@h",
    "scheme with + . - and digits"
  )
  eq(ledger.redact_secrets("9://me@h.example"), "9://me@h.example", "a scheme needs a letter")

  -- A long run of name characters without a separator must not stall the run (the name patterns were
  -- re-scanned from every position of the run: 20 000 hex digits in one argument took tens of seconds).
  -- A linear pass over 60 000 bytes takes a few milliseconds, the quadratic one tens of seconds.
  local SIZE, LIMIT_MS = 60000, 1500
  local shapes = {
    run = ("a"):rep(SIZE),
    run_after_curl = "curl " .. ("a"):rep(SIZE),
    hex = ("deadbeef"):rep(SIZE / 8),
    dotted = ("a."):rep(SIZE / 2),
    dashed = ("a-"):rep(SIZE / 2),
    equals = ("a="):rep(SIZE / 2),
    colons = ("a:"):rep(SIZE / 2),
    schemes = ("a1."):rep(SIZE / 3) .. "://x",
    attached_flags = "curl" .. (" -u"):rep(SIZE / 3),
  }
  for name, text in pairs(shapes) do
    local t0 = vim.uv.hrtime()
    ledger.redact_secrets(text)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < LIMIT_MS, ("redacting %s (%d bytes) took %.0f ms"):format(name, #text, ms))
  end
end
