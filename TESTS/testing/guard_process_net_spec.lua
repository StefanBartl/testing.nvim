-- TESTS/testing/guard_process_net_spec.lua -- the process / network guard in a REAL child editor:
-- every spawn and network entry point is blocked and logged (redacted), a tag / the config list / a
-- dynamic allow lets a call through (still logged), the runner's own calls outside the case window and
-- inside `suspended` are never touched.

-- @cache-allow net
-- (the calls are made against the guard, which blocks them: nothing leaves the process)
return function(H)
  local ok, eq = H.ok, H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/guard_support.lua")
  local r = S.run("process_net")

  for name, c in pairs(r) do
    eq(c.install_error, nil, name .. ": installs")
    eq(c.unrestored, {}, name .. ": uninstall restores everything")
    eq(c.body_error, nil, name .. ": the scenario body itself ran without an error")
  end

  -- ---------------------------------------------------------------- RED: spawn
  local c = r.red_spawn_blocked
  for _, api in ipairs({
    "vim_system",
    "jobstart",
    "fn_system",
    "fn_systemlist",
    "io_popen",
    "os_execute",
    "uv_spawn",
  }) do
    eq(c.value[api], "blocked", api .. " is blocked")
  end
  eq(#S.of(c, "process.spawn_blocked"), 7, "one finding per entry point")
  eq(c.findings[1].severity, "error", "severity error")
  ok(
    S.find(c, "process.spawn_blocked", { "via vim.system", "@spawn", "allow_exec" }) ~= nil,
    "the message names the way out (tag and config key)"
  )
  eq(#c.effects.spawned, 1, "the ledger folds the identical argv into one entry")
  ok(
    c.effects.spawned[1]:find("nvim --version", 1, true),
    "the argv is logged, the program by name only"
  )
  ok(
    c.effects.spawned[1]:find("[blocked]", 1, true) and c.effects.spawned[1]:find("(x7)", 1, true),
    "blocked, counted 7 times"
  )
  -- vim.system calls uv.spawn inside: still ONE attempt per call (re-entrancy)
  eq(c.collect.effects.spawned[1], c.effects.spawned[1], "collect() carries the ledger")

  -- ---------------------------------------------------------------- RED: network
  c = r.red_network_blocked
  eq(c.value.tcp_connect, "blocked", "tcp:connect is blocked")
  eq(c.value.getaddrinfo, "blocked", "uv.getaddrinfo is blocked")
  eq(c.value.udp_send, "blocked", "udp:send is blocked")
  eq(c.value.sockconnect, "blocked", "sockconnect is blocked")
  if c.value.net_request ~= nil then
    eq(c.value.net_request, "blocked", "vim.net.request is blocked")
  end
  ok(
    S.find(c, "network.blocked", { "127.0.0.1:9", "@network", "allow_hosts" }) ~= nil,
    "message names tag and key"
  )
  local joined = table.concat(c.effects.network, "\n")
  ok(joined:find("tcp.connect 127.0.0.1:9", 1, true), "the host is logged")
  ok(joined:find("dns example.invalid", 1, true), "the DNS lookup is logged")
  ok(
    not joined:find("abc123", 1, true) and not joined:find("pw@", 1, true),
    "no credential of a URL reaches the ledger"
  )
  eq(#c.effects.spawned, 0, "a blocked network call does not log a spawn (vim.net.request -> curl)")

  -- ---------------------------------------------------------------- RED: redaction
  c = r.red_secrets_redacted
  eq(c.value.a, "blocked", "blocked")
  eq(c.value.b, "blocked", "blocked")
  local blob = table.concat(c.effects.spawned, "\n") .. "\n" .. vim.json.encode(c.findings)
  for _, secret in ipairs({
    "sk-abcdefghijklmnopqrstuvwx",
    "hunter2",
    "ghp_abcdefghijklmnopqrstuvwxyz0123",
    "pw@",
    "zzz",
  }) do
    ok(
      not blob:find(secret, 1, true),
      "the secret " .. secret:sub(1, 6) .. "... is not in ledger or findings"
    )
  end
  ok(blob:find("<REDACTED>", 1, true), "the mask is visible")
  ok(blob:find("plain arg", 1, true), "ordinary arguments stay readable")

  -- ---------------------------------------------------------------- warn mode
  c = r.red_warn_mode_lets_it_through
  eq(c.value.code, 0, "warn: the call runs")
  eq(c.findings[1].severity, "warn", "warn: only a warning")
  ok(not c.effects.spawned[1]:find("[blocked]", 1, true), "warn: not marked blocked")

  -- ---------------------------------------------------------------- GREEN
  c = r.green_tag_spawn
  eq(c.value.code, 0, "@spawn lets a process run")
  eq(c.value.net, "blocked", "@spawn does not allow the network")
  eq(#S.of(c, "process.spawn_blocked"), 0, "no spawn finding")
  ok(c.effects.spawned[1] == "nvim --version", "an allowed spawn is still logged")

  c = r.green_tag_in_name
  eq(c.value.code, 0, "@spawn in the test name works")
  eq(c.findings, {}, "no finding")
  eq(#c.effects.spawned, 1, "logged")

  c = r.green_tag_network
  eq(c.findings, {}, "@network: no finding")
  for k, v in pairs(c.value) do
    -- the call is let through; whether it succeeds (a refused connection) is not the guard's business
    ok(v ~= "blocked", "@network lets " .. k .. " through, got " .. v)
  end
  eq(#c.effects.spawned, 0, "@network does not allow (and does not log) a spawn of its own")
  ok(#c.effects.network >= 4, "an allowed network call is still logged")
  ok(not table.concat(c.effects.network):find("[blocked]", 1, true), "none is marked blocked")

  c = r.green_config_allow_exec
  eq(c.value.code, 0, "allow_exec lets the listed executable through (case-insensitive, no .exe)")
  eq(c.value.other, "blocked", "an unlisted executable is still blocked")
  eq(#S.of(c, "process.spawn_blocked"), 1, "only the unlisted one is a finding")

  c = r.green_config_allow_host
  eq(c.value.local_ok, "ok", "allow_hosts lets the listed host through")
  eq(c.value.remote, "blocked", "an unlisted host is blocked")

  c = r.green_dynamic_allow
  eq(c.value.code, 0, "handle:allow() lets the executable through for the case")
  eq(c.findings, {}, "no finding")

  c = r.green_suspended_and_outside_the_window
  eq(c.value.code, 0, "suspended: the harness spawn works")
  eq(c.findings, {}, "suspended: no finding")
  eq(c.effects.spawned, {}, "suspended: not in the ledger")
  eq(c.extra.outside, 0, "outside the case window nothing is blocked")
  eq(c.collect.effects.spawned, {}, "outside the case window nothing is logged")

  eq(r.green_no_spawn.findings, {}, "no spawn, no finding")
  eq(
    r.green_no_spawn.effects,
    { spawned = {}, network = {}, fs_outside_tmp = {} },
    "empty effects have the IR shape"
  )
end
