---@diagnostic disable: need-check-nil
-- TESTS/testing/pool_run_reset_spec.lua -- the WARM POOL with real editors: what a member must prove after a file
-- (`testing.child.pool_boot`: reset, restore, VERIFY). A Lua loop is ended by the file's own guard and the member goes
-- on; a member that cannot prove it is clean is thrown away and a finding names the leak (a timer, a job, a process),
-- while wiping buffers and windows is no leak; `guards.state = "error"` turns the finding into a failure; modules
-- and the editor's own registries are put back.

-- @cache-env LC_ALL NVIM TZ
-- (the variables the child environment of the pool run is built from: their values join the key)
return function(H)
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local P = dofile(dir .. "/pool_run_support.lua")(H)
  local ok, eq, has, S, run, findings, statuses =
    P.ok, P.eq, P.has, P.S, P.run, P.findings, P.statuses

  -- ===================================================================
  -- 3b. a Lua loop is ended by the file's own guard inside the member: the file is a timeout, the member
  --     is reset, verified clean and used again
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/b_spec.lua"] = "return function(H) while true do end end",
      ["TESTS/c_spec.lua"] = "return function(H) H.ok(true, 'c') end",
    }
    local order = { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" }
    -- the deadline applies to EVERY file of the run: it has to be far above what loading a file takes on a busy
    -- machine (a deadline of 1500 ms turned a_spec or c_spec into a timeout once, under a second heavy suite)
    local rep =
      run(files, order, { size = 1, extra = { timeouts = { file_ms = 6000 }, grace_ms = 300 } })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:timeout", "TESTS/c_spec.lua:pass" },
      "soft timeout: only the looping file is red"
    )
    eq(rep.pool.spawned, 1, "soft timeout: the member went on")
    for _, n in ipairs(rep.notes) do
      ok(
        not n:find("diff of", 1, true),
        "soft timeout: the guard layer's own checks were not cut off by the deadline: " .. n
      )
    end
  end

  -- ===================================================================
  -- 4. a member that cannot prove it is clean is discarded, with a finding that names the leak
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      -- a timer that outlives the file: neither the soft isolation nor the reset can stop it
      ["TESTS/b_spec.lua"] = [==[return function(H)
  local t = vim.uv.new_timer()
  t:start(600000, 600000, function() end)
  H.ok(true, "b leaves a running timer")
end]==],
      ["TESTS/c_spec.lua"] = [==[return function(H)
  H.ok(vim.uv.cwd() ~= nil, "c")
end]==],
    }
    local order = { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" }
    local rep = run(files, order, { size = 1 })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass", "TESTS/c_spec.lua:pass" },
      "leak: the verdicts do not change (the leak is a finding, the file passed)"
    )
    eq(rep.pool.discarded, 1, "leak: the leaking member was discarded")
    eq(rep.pool.spawned, 2, "leak: the next file got a new member")
    local f = findings(rep, "pool")
    eq(#f, 1, "leak: one pool finding")
    eq(f[1].id, "pool.discarded", "leak: stable id")
    eq(f[1].severity, "warn", "leak: severity follows the state guard (warn by default)")
    has(f[1].message, "TESTS/b_spec.lua", "leak: the file is named")
    has(f[1].message, "timer", "leak: what was left behind is named")
    local b = S.case_of(rep, "TESTS/b_spec.lua")
    local landed = false
    for _, g in ipairs(b.guards) do
      landed = landed or g.guard == "pool"
    end
    ok(landed, "leak: the finding is on the case of the leaking file")
  end

  -- ===================================================================
  -- 4b. a file that wipes the first buffer and closes windows is NOT a leak: the reset puts buffers,
  --     windows and tabs back (the soft isolation could not recreate a wiped buffer or close the last
  --     window, and would call every such file a leak)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  vim.cmd("tabnew")
  vim.cmd("vsplit")
  -- a float survives `:only`
  vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = 1, col = 1, width = 4, height = 1,
  })
  vim.cmd("tabonly | only | %bwipeout!")
  H.ok(true, "a wiped every buffer")
end]==],
      -- opens a float and just ends: only the reset can close it
      ["TESTS/c_spec.lua"] = [==[return function(H)
  vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = 1, col = 1, width = 4, height = 1,
  })
  vim.cmd("vsplit")
  H.ok(#vim.api.nvim_list_wins() == 3, "c has three windows")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  H.ok(#vim.api.nvim_list_tabpages() == 1, "one tab")
  H.ok(#vim.api.nvim_list_wins() == 1, "one window")
  H.ok(#vim.api.nvim_list_bufs() == 1, "one buffer")
  H.ok(vim.api.nvim_buf_get_name(0) == "", "unnamed")
end]==],
    }
    local rep = run(
      files,
      { "TESTS/c_spec.lua", "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
      { size = 1 }
    )
    eq(
      statuses(rep),
      { "TESTS/c_spec.lua:pass", "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass" },
      "buffers: the reset makes the next file see a plain editor"
    )
    eq(rep.pool.discarded, 0, "buffers: wiping the first buffer is no reason to discard the member")
  end

  -- ===================================================================
  -- 4c. a helper process a file leaves running (a language server, a watcher) is a leak: the member is
  --     discarded and its process tree, helper included, is killed. A `jobstart` job is invisible to
  --     libuv's handle walk (its channel is counted), a `vim.system` process is a libuv handle.
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  local job = vim.fn.jobstart({ vim.v.progpath, "--headless", "-n", "-i", "NONE", "-u", "NONE", "+sleep 300" })
  H.ok(job > 0, "a started a job")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  vim.system({ vim.v.progpath, "--headless", "-n", "-i", "NONE", "-u", "NONE", "+sleep 300" })
  H.ok(true, "b started a process")
end]==],
      ["TESTS/c_spec.lua"] = "return function(H) H.ok(true, 'c') end",
    }
    local rep = run(
      files,
      { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" },
      { size = 1 }
    )
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass", "TESTS/c_spec.lua:pass" },
      "helper: the verdicts are unchanged"
    )
    eq(rep.pool.discarded, 2, "helper: both members that left a process running were discarded")
    local f = findings(rep, "pool")
    eq(#f, 2, "helper: one pool finding each")
    has(f[1].message, "1 running job(s)", "helper: the job is named")
    ok(
      f[2].message:find("active process handle(s)", 1, true) ~= nil
        or f[2].message:find("active pipe handle(s)", 1, true) ~= nil,
      "helper: the process of vim.system is named: " .. f[2].message
    )
  end

  -- ===================================================================
  -- 4d. `lib.*` modules are unloaded like any other (a lib.nvim module that registered an autocmd when it
  --     loaded must load again after the autocmd was restored away), and the editor's own provider
  --     flags are never touched (`autoload/provider/clipboard.vim` needs `g:loaded_clipboard_provider`)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  package.loaded["lib.zz_pool_mod"] = { n = 1 }
  vim.g.loaded_zz_provider = 1
  H.ok(true, "a loads a lib module and sets a provider flag")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  H.ok(package.loaded["lib.zz_pool_mod"] == nil, "the lib module of file a is unloaded")
  H.ok(vim.g.loaded_zz_provider == 1, "the editor's provider flag is left alone")
end]==],
    }
    local rep = run(files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }, { size = 1 })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass" },
      "lib modules and provider flags: as described"
    )
    eq(rep.pool.discarded, 0, "lib modules and provider flags: nothing to discard")
  end

  -- ===================================================================
  -- 4e. the editor's own registries live in modules that stay loaded: a server one file registered
  --     (found in the fleet: it showed up in the completion of the next file's `:Lsp start`) and the global
  --     diagnostic configuration are put back too
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  vim.lsp.config("zz_pool_server", { cmd = { "zz" }, filetypes = { "zz" } })
  vim.diagnostic.config({ virtual_text = false, underline = false })
  H.ok(rawget(vim.lsp.config, "_configs").zz_pool_server ~= nil, "a registered a server")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  H.ok(rawget(vim.lsp.config, "_configs").zz_pool_server == nil, "the server of file a is gone")
  H.ok(vim.diagnostic.config().underline ~= false, "the diagnostic configuration is back")
end]==],
    }
    local rep = run(files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }, { size = 1 })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass" },
      "registries: the next file sees the editor's own registries as they were"
    )
    eq(rep.pool.discarded, 0, "registries: they could be put back, no reason to discard")
  end

  -- ===================================================================
  -- 5. with `guards.state = "error"` the same leak fails the file (as the state guard does)
  do
    local files = {
      ["TESTS/b_spec.lua"] = [==[return function(H)
  local t = vim.uv.new_timer()
  t:start(600000, 600000, function() end)
  H.ok(true, "b leaves a running timer")
end]==],
    }
    local rep = run(files, { "TESTS/b_spec.lua" }, { size = 1, guards = { state = "error" } })
    eq(statuses(rep), { "TESTS/b_spec.lua:fail" }, "state = error: the leak fails the file")
    eq(findings(rep, "pool")[1].severity, "error", "state = error: severity error")
  end

  S.cleanup()
end
