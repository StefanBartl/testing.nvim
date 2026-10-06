-- TESTS/testing/child_rpc_env_spec.lua -- REAL child editors (testing.rpc): what the child sees. Environment
-- allowlist (secrets and $NVIM* never arrive), XDG/temp sandbox, determinism variables with their opt-out
-- (for the RPC child and for the per-file child plan), the guard hook (install once, handle forwarded,
-- effects(), a failing install fails the spawn), the prompt capture hands over to the guard.

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local rpc = require("testing.rpc")
  local deps = require("testing.deps")
  local lib = assert(deps.resolve("lib.nvim", S.repo), "lib.nvim is needed to run these specs")

  local function norm(p)
    return (vim.fs.normalize(p):gsub("/+$", ""):lower())
  end
  local function inside(path, base)
    return norm(path):sub(1, #norm(base) + 1) == norm(base) .. "/"
  end

  ---The parent's environment plus things a child must never see (or must see changed).
  ---@param extra? table<string, string>
  ---@return table<string, string>
  local function dirty_env(extra)
    local env = vim.fn.environ()
    env.GITHUB_TOKEN = "ghp_do_not_leak"
    env.ANTHROPIC_API_KEY = "sk-do-not-leak"
    env.MY_SECRET_THING = "secret"
    env.NVIM = "/tmp/parent-nvim.sock"
    env.NVIM_LISTEN_ADDRESS = "/tmp/parent-nvim-2.sock"
    env.NVIM_APPNAME = "parent-app"
    env.NVIM_SNEAKY = "sneaky"
    env.RPC_ALLOWED_ONE = "allowed"
    env.LANG = "de_AT.UTF-8"
    env.LANGUAGE = "de"
    env.LC_TIME = "de_AT.UTF-8"
    env.TZ = "Europe/Vienna"
    for k, v in pairs(extra or {}) do
      env[k] = v
    end
    return env
  end

  S.run(function()
    -- ===================================================================
    -- 1. environment: an allowlist, never a copy
    local c = S.spawn({
      parent_env = dirty_env(),
      env_allow = { "RPC_ALLOWED_*", "NVIM_SNEAKY", "NVIM_LISTEN_ADDRESS" },
    })
    local seen =
      c.lua("local t = {} for k in pairs(vim.fn.environ()) do t[#t + 1] = k end return t")
    local names = {}
    for _, n in ipairs(seen) do
      names[n:upper()] = true
    end
    for _, secret in ipairs({
      "GITHUB_TOKEN",
      "ANTHROPIC_API_KEY",
      "MY_SECRET_THING",
      "NVIM",
      "NVIM_LISTEN_ADDRESS",
      "NVIM_APPNAME",
      "NVIM_SNEAKY",
      "TESTING_CHILD_JOB",
    }) do
      ok(not names[secret], secret .. " does not reach the child")
    end
    ok(names.PATH or names.Path, "PATH does")
    eq(c.env.RPC_ALLOWED_ONE, "allowed", "what the project allows (env_allow prefix) does")
    eq(c.env.NVIM, nil, "$NVIM is never inherited")
    eq(c.env.NVIM_LISTEN_ADDRESS, nil, "$NVIM_LISTEN_ADDRESS is never inherited")
    ok(
      c.env.NVIM_LOG_FILE ~= nil and inside(c.env.NVIM_LOG_FILE, c.sandbox),
      "the editor's log is in the sandbox"
    )
    eq(c.lua_get("vim.fn.has('nvim-0.10')"), 1, "sanity: a real editor answers")

    -- ===================================================================
    -- 2. sandbox: stdpath and tempname never touch the real places
    for _, which in ipairs({ "config", "data", "state", "cache" }) do
      local p = c.lua_get("vim.fn.stdpath('" .. which .. "')")
      ok(inside(p, c.sandbox), ("stdpath(%s) is inside the sandbox: %s"):format(which, p))
    end
    ok(inside(c.lua_get("vim.fn.tempname()"), c.sandbox), "tempname() is inside the sandbox")
    eq(
      c.lua_get("vim.fn.getcwd()"):gsub("\\", "/"):lower(),
      S.repo:lower(),
      "the working directory is the project root"
    )
    for name, path in pairs(c.dirs) do
      eq(vim.fn.isdirectory(path), 1, "sandbox directory " .. name .. " exists")
    end

    -- ===================================================================
    -- 3. determinism: SET, not passed through; opt-out passes the parent's values on
    eq(c.env.LANG, "C.UTF-8", "LANG")
    eq(c.env.LC_ALL, "C.UTF-8", "LC_ALL")
    eq(c.env.TZ, "UTC", "TZ")
    eq(c.env.LANGUAGE, nil, "LANGUAGE of the parent is not passed on")
    eq(c.env.LC_TIME, nil, "nor is any other LC_*")
    eq(c.lua_get("os.date('%H:%M', 0)"), "00:00", "the time zone really is UTC (epoch 0 is 00:00)")
    eq(c.lua_get("os.date('!%H:%M', 0)"), "00:00", "(and the UTC form agrees)")

    local free = S.spawn({ parent_env = dirty_env(), deterministic = false })
    eq(free.env.LANG, "de_AT.UTF-8", "deterministic = false: LANG is the parent's")
    eq(free.env.TZ, "Europe/Vienna", "deterministic = false: TZ is the parent's")
    eq(free.env.LC_TIME, "de_AT.UTF-8", "deterministic = false: LC_* too")
    -- macOS: the editor itself exports LC_ALL from the system locale, so only elsewhere it must be absent
    if vim.fn.has("mac") == 0 then
      eq(free.env.LC_ALL, nil, "and LC_ALL is not invented")
    end

    -- an unset parent gets the same variables
    local bare_env = vim.fn.environ()
    bare_env.LANG, bare_env.TZ, bare_env.LC_ALL = nil, nil, nil
    local bare = S.spawn({ parent_env = bare_env })
    eq(
      { bare.env.LANG, bare.env.LC_ALL, bare.env.TZ },
      { "C.UTF-8", "C.UTF-8", "UTC" },
      "set even when the parent has none"
    )

    -- the per-file child (`testing.child.build`) follows the same rule
    local child_mod = require("testing.child")
    local plan = child_mod.build({
      entry = { path = S.repo .. "/TESTS/x.lua", rel = "TESTS/x.lua" },
      root = S.repo,
      parent_env = dirty_env(),
      name = "testing-child-det-spec",
    })
    eq(
      { plan.env.LANG, plan.env.LC_ALL, plan.env.TZ },
      { "C.UTF-8", "C.UTF-8", "UTC" },
      "a file child gets the determinism variables"
    )
    eq(plan.env.LANGUAGE, nil, "without LANGUAGE")
    eq(plan.env.LC_TIME, nil, "and without the parent's LC_*")
    local free_plan = child_mod.build({
      entry = { path = S.repo .. "/TESTS/x.lua", rel = "TESTS/x.lua" },
      root = S.repo,
      parent_env = dirty_env(),
      deterministic = false,
      name = "testing-child-det-spec",
    })
    eq(
      { free_plan.env.LANG, free_plan.env.TZ, free_plan.env.LC_TIME },
      { "de_AT.UTF-8", "Europe/Vienna", "de_AT.UTF-8" },
      "opt-out passes the parent's values on"
    )

    -- env module: names are matched case-insensitively, the table is changed in place
    local env_mod = require("testing.child.env")
    local mixed =
      env_mod.apply_determinism({ Tz = "Asia/Tokyo", lang = "fr", Lc_Collate = "fr", KEEP = "1" })
    eq(
      mixed,
      { LANG = "C.UTF-8", LC_ALL = "C.UTF-8", TZ = "UTC", KEEP = "1" },
      "case-insensitive replacement"
    )

    -- ===================================================================
    -- 4. the guard hook
    local rtp = { S.fixtures .. "/guard_rtp", S.repo, lib.dir }

    -- module-level collect(): installed once with the config, effects() returns what collect() says
    local g = S.spawn({ rtp_prepend = rtp, guard = { marker = "m1" } })
    eq(g.boot_info().guard, "installed", "the guard module was found and installed")
    eq(g.g.fixture_guard_marker, "m1", "install received the config")
    eq(g.g.fixture_guard_installs, 1, "install ran exactly once")
    eq(g.effects().spawned, { "fixture-spawn" }, "effects() returns what the guard collected")
    eq(g.effects().cfg_marker, "m1", "(from the installed config)")
    ok(
      g.lua_get("rawget(vim.fn, 'input') == nil"),
      "with a guard installed it owns the prompts: the driver's capture is off"
    )
    local no_handle_ok, no_handle_err = pcall(g.guard.begin_case, { id = "x" })
    ok(not no_handle_ok, "a guard whose install returns no handle cannot be forwarded to")
    has(no_handle_err, "no guard handle", "and says so")

    -- guard = false: nothing is installed even though the module exists; the ledger is empty
    local off = S.spawn({ rtp_prepend = rtp, guard = false })
    eq(off.boot_info().guard, "absent", "guard = false installs nothing")
    eq(off.g.fixture_guard_installs, nil, "the module was not even called")
    eq(off.effects(), { spawned = {}, network = {}, fs_outside_tmp = {} }, "the ledger is empty")
    ok(off.lua_get("rawget(vim.fn, 'input') ~= nil"), "and the driver's prompt capture is on")

    -- a guard that fails to install fails the spawn, loudly
    local bad, bad_err = rpc.spawn({
      root = S.repo,
      rtp_prepend = { S.fixtures .. "/guard_bad_rtp", S.repo, lib.dir },
      trace_dir = S.new_dir(),
    })
    ok(bad == nil, "an install that raises fails the spawn")
    has(bad_err, "fixture guard install failed on purpose", "with the guard's own message")

    -- the real guard (this checkout): installed, a handle that answers, the ledger shape
    local real = S.spawn({ guard = { repo = S.repo } })
    eq(real.boot_info().guard, "installed", "the real testing.guard installs in the child")
    local eff = real.effects()
    ok(
      type(eff.spawned) == "table"
        and type(eff.network) == "table"
        and type(eff.fs_outside_tmp) == "table",
      "effects() has the ledger shape: " .. vim.inspect(eff)
    )
    local begun = real.guard.begin_case({ id = "x_spec.lua::a::b", file = "x_spec.lua" })
    ok(begun == nil or type(begun) == "table", "begin_case is forwarded")
    local done = real.guard.end_case()
    ok(
      type(done) == "table" and type(done.effects) == "table",
      "end_case returns the case's findings/effects: " .. vim.inspect(done)
    )
    ok(not pcall(real.guard.no_such_method), "an unknown guard method raises")
  end)
end
