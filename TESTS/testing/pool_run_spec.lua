---@diagnostic disable: need-check-nil
-- TESTS/testing/pool_run_spec.lua -- the WARM POOL with real editors (`testing.run.pool`, `testing.child.pool_boot`,
-- `testing.run.isolated` with `pool.reuse`): files run one after the other in a member that is
-- restored and VERIFIED clean between them, the verdict is the one a child per file gives, a crash or a
-- timeout kills only its member, a member that cannot prove it is clean is thrown away and says why.

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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local options_mod = require("testing.run.options")

  ---Run `files` (rel -> body, in `order`) through the real isolated driver.
  ---@param files table<string, string>
  ---@param order string[]
  ---@param cfg? { reuse?: boolean, size?: integer, jobs?: integer, guards?: table, extra?: table, dialect?: string }
  ---@return Testing.Inproc.Report report
  ---@return string root
  local function run(files, order, cfg)
    cfg = cfg or {}
    local root = S.new_root()
    local entries = S.project(root, files, order, cfg.dialect)
    local o = options_mod.of({
      project = {
        isolated = "file",
        pool = { reuse = cfg.reuse ~= false, size = cfg.size or 0 },
        guards = cfg.guards,
      },
      args = { jobs = cfg.jobs or 1 },
    })
    o.host_given = false
    local extra = vim.tbl_extend("force", {
      options = o,
      timeouts = { file_ms = 30000 },
      trace_dir = root .. "/traces",
      guard_cfg = options_mod.guard_config(o, { root = root }),
    }, cfg.extra or {})
    return S.run(root, entries, extra), root
  end

  ---Findings of the guard `name` over the whole report.
  ---@param report table
  ---@param name string
  ---@return Testing.Result.GuardFinding[]
  local function findings(report, name)
    local out = {}
    for _, c in ipairs(report.result.cases) do
      for _, g in ipairs(c.guards or {}) do
        if g.guard == name then
          out[#out + 1] = g
        end
      end
    end
    return out
  end

  ---Files i = 1..n. File i leaves EVERYTHING it can behind (a global, a `vim.g` key, a loaded module,
  ---an autocmd group, a user command, a mapping, a buffer, an option, an environment variable, the
  ---working directory) and asserts that it sees nothing of the files before it.
  ---@param n integer
  ---@return table<string, string> files
  ---@return string[] order
  local function leaky_files(n)
    local files, order = {}, {}
    for i = 1, n do
      local rel = ("TESTS/leak%d_spec.lua"):format(i)
      order[#order + 1] = rel
      files[rel] = ([==[
return function(H)
  local me = %d
  for j = 1, me - 1 do
    H.ok(_G["LEAK_" .. j] == nil, "global of file " .. j .. " is gone")
    H.ok(vim.g["leak_g" .. j] == nil, "vim.g key of file " .. j .. " is gone")
    H.ok(package.loaded["leak_mod_" .. j] == nil, "module of file " .. j .. " is gone")
    H.ok(vim.fn.exists(":LeakCmd" .. j) == 0, "command of file " .. j .. " is gone")
    H.ok(vim.fn.mapcheck("<F" .. (j + 4) .. ">", "n") == "", "mapping of file " .. j .. " is gone")
    H.ok(vim.env["LEAK_ENV_" .. j] == nil, "environment variable of file " .. j .. " is gone")
    local found = 0
    for _, a in ipairs(vim.api.nvim_get_autocmds({ event = "BufEnter" })) do
      if a.group_name == "LeakGroup" .. j then
        found = found + 1
      end
    end
    H.ok(found == 0, "autocmd group of file " .. j .. " is gone")
  end
  H.ok(#vim.api.nvim_list_bufs() == 1, "one buffer at the start of file " .. me)
  H.ok(#vim.api.nvim_list_wins() == 1, "one window at the start of file " .. me)
  H.ok(vim.fn.getcwd() == vim.uv.cwd(), "cwd consistent")
  H.ok(vim.o.tabstop == 8, "options are back (file " .. me .. ")")

  _G["LEAK_" .. me] = true
  vim.g["leak_g" .. me] = me
  package.loaded["leak_mod_" .. me] = { me = me }
  vim.api.nvim_create_user_command("LeakCmd" .. me, function() end, {})
  vim.keymap.set("n", "<F" .. (me + 4) .. ">", "<Nop>")
  vim.env["LEAK_ENV_" .. me] = "x"
  local group = vim.api.nvim_create_augroup("LeakGroup" .. me, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, callback = function() end })
  vim.cmd("enew")
  vim.cmd("vsplit")
  vim.o.tabstop = 3 + me
  H.ok(true, "file " .. me .. " ran")
end
]==]):format(i)
    end
    return files, order
  end

  ---Statuses per file, in IR order.
  ---@param rep table
  ---@return string[]
  local function statuses(rep)
    return S.statuses(rep)
  end

  -- ===================================================================
  -- 1. ONE member runs six files that litter the editor; none of them sees the litter of another
  do
    local files, order = leaky_files(6)
    local rep = run(files, order, { size = 1 })
    local expected = {}
    for _, rel in ipairs(order) do
      expected[#expected + 1] = rel .. ":pass"
    end
    eq(statuses(rep), expected, "pool: every file passes and sees a clean editor")
    ok(rep.pool ~= nil, "the report carries the pool statistics")
    eq(rep.pool.spawned, 1, "pool: ONE editor was started for six files")
    eq(rep.pool.reused, 5, "pool: five files reused it")
    eq(rep.pool.discarded, 0, "pool: nothing had to be discarded")
    eq(#findings(rep, "pool"), 0, "pool: no discard finding")

    -- the control: a child per file gives the same verdict (the pool is a speed-up, not another judge)
    local ctrl = run(files, order, { reuse = false })
    eq(statuses(ctrl), expected, "control: a child per file, the same verdict")
    ok(ctrl.pool == nil, "control: no pool, no pool statistics")
  end

  -- ===================================================================
  -- 2. a crash kills ONLY its member: the next file gets a new one, the files before it are untouched
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/b_spec.lua"] = "return function(H) H.ok(true, 'b') end",
      ["TESTS/c_spec.lua"] = "return function(H) vim.cmd('cquit 3') end",
      ["TESTS/d_spec.lua"] = "return function(H) H.ok(true, 'd') end",
      ["TESTS/e_spec.lua"] = "return function(H) H.ok(true, 'e') end",
    }
    local order = {
      "TESTS/a_spec.lua",
      "TESTS/b_spec.lua",
      "TESTS/c_spec.lua",
      "TESTS/d_spec.lua",
      "TESTS/e_spec.lua",
    }
    local rep, root = run(files, order, { size = 1 })
    eq(statuses(rep), {
      "TESTS/a_spec.lua:pass",
      "TESTS/b_spec.lua:pass",
      "TESTS/c_spec.lua:crash",
      "TESTS/d_spec.lua:pass",
      "TESTS/e_spec.lua:pass",
    }, "crash: only the file that crashed is red")
    eq(rep.pool.spawned, 2, "crash: a second member took over after the crash")
    eq(rep.pool.discarded, 1, "crash: exactly the member that crashed was discarded")
    local c = S.case_of(rep, "TESTS/c_spec.lua")
    has(c.error.message, "exit code 3", "crash: the exit code is named")
    local artifact = c.artifacts[1]
    ok(artifact and artifact.kind == "trace", "crash: the case carries a trace artifact")
    local path = artifact.path:gsub("^<TMP>", vim.fs.dirname(vim.fn.tempname()))
    local trace_dir = root .. "/traces"
    local found
    for name in vim.fs.dir(trace_dir) do
      found = name
    end
    ok(
      found ~= nil and found:find("%.trace%.json$") ~= nil,
      "crash: the trace file is on disk (" .. tostring(path) .. ")"
    )
    local trace = vim.json.decode(S.slurp(trace_dir .. "/" .. found) --[[@as string]])
    eq(trace.reason, "crash", "crash: the trace says why it was written")
    ok(#trace.calls >= 3, "crash: the trace holds the calls of the member (boot, init, the file)")
  end

  -- ===================================================================
  -- 2b. the cases a file finished BEFORE its member died are kept (the member's sandbox is gone with its
  --     process; the records are not in it)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[describe("dies", function()
  it("one", function() assert.is_true(true) end)
  it("two", function() assert.is_true(true) end)
  it("three", function() vim.cmd("cquit 3") end)
end)]==],
      ["TESTS/b_spec.lua"] = [==[describe("after", function()
  it("still runs in a new member", function() assert.is_true(true) end)
end)]==],
    }
    local rep = run(
      files,
      { "TESTS/a_spec.lua", "TESTS/b_spec.lua" },
      { size = 1, dialect = "busted" }
    )
    local got = {}
    for _, c in ipairs(rep.result.cases) do
      got[#got + 1] = c.id:match("::(.-)$") .. ":" .. c.status
    end
    ok(
      vim.tbl_contains(got, "dies::one:pass") and vim.tbl_contains(got, "dies::two:pass"),
      "crash mid-file: the cases that finished are kept: " .. vim.inspect(got)
    )
    local crashed = false
    for _, c in ipairs(rep.result.cases) do
      crashed = crashed or (c.file == "TESTS/a_spec.lua" and c.status == "crash")
    end
    ok(crashed, "crash mid-file: and the file ends in a crash case: " .. vim.inspect(got))
    ok(
      vim.tbl_contains(got, "after::still runs in a new member:pass"),
      "the next file ran in a new member"
    )
    eq(rep.pool.spawned, 2, "crash mid-file: a new member for the next file")
  end

  -- ===================================================================
  -- 3. a file that hangs in C (the file's own best-effort guard cannot interrupt it) is a timeout, killed
  --    with its member; the next file is not delayed by it
  do
    local files = {
      ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'a') end",
      ["TESTS/b_spec.lua"] = "return function(H) vim.uv.sleep(120000) end",
      ["TESTS/c_spec.lua"] = "return function(H) H.ok(true, 'c') end",
    }
    local order = { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/c_spec.lua" }
    local rep, root = run(files, order, {
      size = 1,
      extra = { timeouts = { file_ms = 1500 }, grace_ms = 300 },
    })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:timeout", "TESTS/c_spec.lua:pass" },
      "timeout: only the hung file is red"
    )
    eq(rep.pool.discarded, 1, "timeout: the member that hung was discarded")
    eq(rep.pool.spawned, 2, "timeout: the next file got a new member")
    local b = S.case_of(rep, "TESTS/b_spec.lua")
    has(b.error.message, "process tree was killed", "timeout: killed from outside")
    ok(b.artifacts[1] and b.artifacts[1].kind == "trace", "timeout: a trace artifact")
    local n = 0
    for name in vim.fs.dir(root .. "/traces") do
      if name:find("%.trace%.json$") then
        n = n + 1
      end
    end
    eq(n, 1, "timeout: one trace file")
  end

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
    local rep =
      run(files, order, { size = 1, extra = { timeouts = { file_ms = 1500 }, grace_ms = 300 } })
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

  -- ===================================================================
  -- 6. what a file writes below stdpath() does not survive it (a respawned child loses its sandbox)
  do
    local files = {
      ["TESTS/a_spec.lua"] = [==[return function(H)
  local dir = vim.fn.stdpath("data") .. "/leakdir"
  vim.fn.mkdir(dir, "p")
  local f = assert(io.open(dir .. "/x.txt", "wb"))
  f:write("x")
  f:close()
  vim.fn.mkdir(vim.fn.stdpath("state") .. "/sub", "p")
  H.ok(vim.uv.fs_stat(dir .. "/x.txt") ~= nil, "a wrote below stdpath('data')")
end]==],
      ["TESTS/b_spec.lua"] = [==[return function(H)
  H.ok(vim.uv.fs_stat(vim.fn.stdpath("data") .. "/leakdir/x.txt") == nil, "b does not see the file of a")
  H.ok(vim.uv.fs_stat(vim.fn.stdpath("state") .. "/sub") == nil, "b does not see the directory of a")
end]==],
    }
    local rep = run(files, { "TESTS/a_spec.lua", "TESTS/b_spec.lua" }, { size = 1 })
    eq(
      statuses(rep),
      { "TESTS/a_spec.lua:pass", "TESTS/b_spec.lua:pass" },
      "sandbox: emptied between files"
    )
    eq(rep.pool.spawned, 1, "sandbox: cleaning it needed no new member")
  end

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
  -- 10. the same files, the same verdicts and the same ORDER whatever the pool size and the jobs
  do
    local files, order = leaky_files(5)
    local expected
    for _, c in ipairs({
      { size = 1, jobs = 1 },
      { size = 2, jobs = 3 },
      { size = 3, jobs = 3 },
      { reuse = false, jobs = 3 },
    }) do
      local rep = run(files, order, c)
      local got = statuses(rep)
      expected = expected or got
      eq(
        got,
        expected,
        ("pool size=%s jobs=%s reuse=%s: same IR order and verdicts"):format(
          tostring(c.size),
          tostring(c.jobs),
          tostring(c.reuse)
        )
      )
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
