---@diagnostic disable: need-check-nil
-- TESTS/testing/pool_run_member_spec.lua -- the WARM POOL with real editors: the member is the deterministic, sanitized
-- editor a child per file is (the project's own `plugin/` is not sourced at the start), and the driver around it: the
-- guard layer inside the member, `script` files never pooled, the fallback to a child per file when no member can be
-- started.

-- @cache-env LC_ALL NVIM TZ
-- (the variables the child environment of the pool run is built from: their values join the key)
return function(H)
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local P = dofile(dir .. "/pool_run_support.lua")(H)
  local ok, eq, S, options_mod, run, leaky_files, statuses =
    P.ok, P.eq, P.S, P.options_mod, P.run, P.leaky_files, P.statuses

  -- ===================================================================
  -- 7. the member is the deterministic, sanitized editor a child per file is
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  H.ok(vim.env.TZ == "UTC", "TZ is UTC, got " .. tostring(vim.env.TZ))
  H.ok(vim.env.LC_ALL == "C.UTF-8", "LC_ALL is C.UTF-8, got " .. tostring(vim.env.LC_ALL))
  H.ok(vim.env.NVIM == nil, "$NVIM is not inherited")
  H.ok(vim.fn.stdpath("data"):find("testing%-child%-") ~= nil, "stdpath is in the sandbox")
  H.ok(vim.o.loadplugins == true, "plugins are loaded like in any editor")
end]==],
    }
    local rep = run(files, { "TESTS/a_spec.lua" }, { size = 1 })
    eq(statuses(rep), { "TESTS/a_spec.lua:pass" }, "member: deterministic, sandboxed")
  end

  -- ===================================================================
  -- 8. the project's own `plugin/` directory is NOT sourced at the start (a per-file child never has
  --    it on the runtimepath while the editor loads its plugins): a spec that expects its command to
  --    be absent before `setup()` sees the same in a member
  do
    local root = S.new_root()
    S.write(root .. "/plugin/leakplugin.lua", "vim.g.leakplugin_ran = true\n")
    S.write(root .. "/TESTS/minimal_init.lua", ("vim.opt.rtp:prepend(%q)\n"):format(root))
    S.write(
      root .. "/TESTS/a_spec.lua",
      "return function(H) H.ok(vim.g.leakplugin_ran == nil, 'plugin/ of the project did not run at start') end"
    )
    local o = options_mod.of({
      project = { isolated = "file", pool = { reuse = true, size = 1 } },
      args = {},
    })
    o.host_given = false
    local rep = S.run(root, { S.entry(root, "TESTS/a_spec.lua") }, {
      options = o,
      minit = root .. "/TESTS/minimal_init.lua",
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
    })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass" },
      "deferred plugins: the project's plugin/ did not run at start"
    )
    eq(rep.pool.spawned, 1, "deferred plugins: the file really ran in a member")
  end

  -- ===================================================================
  -- 9. the guard layer runs INSIDE the member (a prompt is a finding, the ledger says "measured")
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) vim.fn.input('name? ') end",
      ["TESTS/b_spec.lua"] = "return function(H) H.ok(true, 'b is fine') end",
    }
    local order = { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }
    local pooled = run(files, order, { size = 1 })
    local plain = run(files, order, { reuse = false })
    for label, rep in pairs({ pool = pooled, ["child per file"] = plain }) do
      local a = S.case_of(rep, "TESTS/a_spec.lua")
      ok(
        a.status == "error" or a.status == "fail",
        label .. ": an unanswered prompt ends the case red"
      )
      local seen = {}
      for _, g in ipairs(a.guards) do
        seen[g.guard .. ":" .. g.id] = g.severity
      end
      eq(seen["prompt:prompt.unanswered"], "error", label .. ": the prompt guard named it")
      local b = S.case_of(rep, "TESTS/b_spec.lua")
      eq(b.status, "pass", label .. ": the next file is unaffected")
      local measured = true
      for _, n in ipairs(b.notes) do
        measured = measured and not n:find("effects: not collected", 1, true)
      end
      ok(measured, label .. ": effects are measured, no 'not collected' note")
    end
  end

  -- ===================================================================
  -- 11. `script` files are never pooled (they end their own process)
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/s.lua"] = "print('[OK] script'); os.exit(0)",
    }
    local root = S.new_root()
    S.write(root .. "/TESTS/a_spec.lua", files["TESTS/a_spec.lua"])
    S.write(root .. "/TESTS/s.lua", files["TESTS/s.lua"])
    local o = options_mod.of({
      project = { isolated = "file", pool = { reuse = true, size = 1 }, assertions = "warn" },
      args = {},
    })
    o.host_given = false
    local rep = S.run(root, {
      S.entry(root, "TESTS/a_spec.lua"),
      S.entry(root, "TESTS/s.lua", "script"),
    }, { options = o, timeouts = { file_ms = 30000 }, trace_dir = root .. "/traces" })
    eq(rep.pool.files, 1, "script: only the spec file went through the pool")
    eq(
      S.case_of(rep, "TESTS/s.lua").status ~= "crash",
      true,
      "script: ran in a child of its own, not in a member"
    )
  end

  -- ===================================================================
  -- 12. no member can be started: every file still runs, in a child of its own, and the report says so once
  do
    local files, order = leaky_files(3)
    local rep = run(files, order, {
      size = 1,
      extra = {
        rpc = {
          spawn_async = function(_, cb)
            vim.schedule(function()
              cb(nil, "boom")
            end)
          end,
        },
      },
    })
    local expected = {}
    for _, rel in ipairs(order) do
      expected[#expected + 1] = rel .. ":pass"
    end
    eq(statuses(rep), expected, "fallback: the files ran in children of their own")
    local told = 0
    for _, n in ipairs(rep.notes) do
      if n:find("could not start a member", 1, true) and n:find("boom", 1, true) then
        told = told + 1
      end
    end
    eq(told, 1, "fallback: one note names the reason")
  end

  S.cleanup()
end
