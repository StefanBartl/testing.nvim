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
  }) do
    eq(ledger.redact_secrets(line), line, "unchanged: " .. line)
  end
end
