-- TESTS/testing/isolation_soft_spec.lua -- soft isolation: what a spec file changed in THIS editor is undone before
-- the next file, and every difference is a named finding (restored or not). The polluter really pollutes (an
-- autocmd group, a global, a loaded module, a variable, the cwd, ...), the verification really looks again,
-- and a restore that lies is caught.

-- @cache-env ISO_LEAK_ENV
-- (the variable the spec leaks on purpose: its outer value joins the key)
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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local isolation = require("testing.isolation")
  local snapshot = require("testing.isolation.snapshot")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")

  local is_windows = vim.fn.has("win32") == 1
  local function norm(p)
    p = vim.fs.normalize(p):gsub("/+$", "")
    return is_windows and p:lower() or p
  end

  ---Findings of a report as one string per finding.
  local function messages(report)
    local out = {}
    for _, f in ipairs(report.findings) do
      out[#out + 1] = f.message
    end
    return out
  end
  local function joined(report)
    return table.concat(messages(report), "\n")
  end

  -- everything the polluter touches is removed again here, whatever the session did
  local cwd0 = vim.uv.cwd()
  local windows0 = #vim.api.nvim_list_wins()
  local buf_keep
  local function cleanup()
    pcall(vim.api.nvim_del_augroup_by_name, "IsoLeakGroup")
    pcall(vim.api.nvim_del_user_command, "IsoLeakCmd")
    pcall(vim.api.nvim_del_keymap, "n", "<Plug>(iso-leak)")
    pcall(vim.api.nvim_del_var, "iso_leak_var")
    pcall(vim.fn.setenv, "ISO_LEAK_ENV", vim.NIL)
    rawset(_G, "iso_leak_global", nil)
    package.loaded["iso.leak.mod"] = nil
    package.loaded["iso.keep.mod"] = nil
    package.loaded["testing.iso_fake_kept"] = nil
    package.loaded["lib.iso_fake_kept"] = nil
    pcall(vim.api.nvim_set_current_dir, cwd0)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if b ~= buf_keep and vim.api.nvim_buf_get_name(b):find("iso%-leak") then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
  cleanup()

  ---Everything a careless spec file leaves behind.
  local function pollute()
    local group = vim.api.nvim_create_augroup("IsoLeakGroup", { clear = true })
    vim.api.nvim_create_autocmd(
      "BufEnter",
      { group = group, pattern = "*.iso", command = "echo 1" }
    )
    rawset(_G, "iso_leak_global", { 1 })
    package.loaded["iso.leak.mod"] = { loaded = true }
    vim.g.iso_leak_var = "leaked"
    vim.fn.setenv("ISO_LEAK_ENV", "1")
    vim.api.nvim_create_user_command("IsoLeakCmd", function() end, {})
    vim.keymap.set("n", "<Plug>(iso-leak)", function() end)
    vim.api.nvim_set_current_dir(assert(vim.uv.os_tmpdir()))
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, vim.fs.joinpath(vim.uv.os_tmpdir(), "iso-leak-buffer.txt"))
    vim.cmd("topleft split")
    vim.api.nvim_win_set_buf(0, b)
  end

  ---Is the editor as `pollute` found it?
  local function clean_state()
    local report = {}
    report.global = rawget(_G, "iso_leak_global") == nil
    report.module = package.loaded["iso.leak.mod"] == nil
    report.var = vim.g.iso_leak_var == nil
    report.env = vim.env.ISO_LEAK_ENV == nil
    report.group = not pcall(vim.api.nvim_get_autocmds, { group = "IsoLeakGroup" })
    report.cmd = vim.api.nvim_get_commands({}).IsoLeakCmd == nil
    report.map = vim.fn.maparg("<Plug>(iso-leak)", "n") == ""
    report.cwd = norm(vim.uv.cwd()) == norm(cwd0)
    report.windows = #vim.api.nvim_list_wins() == windows0
    local buf_leaked = false
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find("iso%-leak") then
        buf_leaked = true
      end
    end
    report.buffer = not buf_leaked
    return report
  end

  local only_windows_of_runner = #vim.api.nvim_list_wins()
  ok(only_windows_of_runner >= 1, "the runner has a window")
  buf_keep = vim.api.nvim_get_current_buf()

  -- ================================================================== the session, with a real polluter
  local session = isolation.new({ severity = "warn" })
  eq(
    session.backend_name,
    "internal",
    "the internal backend is used (the guard layer exports none)"
  )
  local frame = session:enter("TESTS/leak_spec.lua")
  ok(frame ~= nil, "enter takes a snapshot")
  local windows_before = #vim.api.nvim_list_wins()
  pollute()
  local dirty = clean_state()
  for name, is_clean in pairs(dirty) do
    ok(not is_clean or name == "windows", "the polluter really polluted: " .. name)
  end
  ok(#vim.api.nvim_list_wins() == windows_before + 1, "and opened a window")
  local report = session:leave(frame)
  local post = clean_state()
  for name, is_clean in pairs(post) do
    ok(is_clean or name == "windows", "restored: " .. name)
  end
  eq(#vim.api.nvim_list_wins(), windows_before, "restored: the window is closed again")
  eq(norm(vim.uv.cwd()), norm(cwd0), "restored: the working directory")
  eq(report.unrestored, 0, "nothing was left unrestored")
  ok(report.restored >= 9, "the report counts what it restored (" .. report.restored .. ")")

  -- every leak is a NAMED finding, with the file that leaked it
  local text = joined(report)
  has(
    text,
    "TESTS/leak_spec.lua leaves autocmd BufEnter (pattern *.iso) in group `IsoLeakGroup`",
    "autocmd"
  )
  has(text, "TESTS/leak_spec.lua leaves global `iso_leak_global`", "global")
  has(text, "TESTS/leak_spec.lua leaves module `iso.leak.mod` stays loaded", "module")
  has(text, "global variable g:iso_leak_var", "vim.g")
  has(text, "environment variable ISO_LEAK_ENV", "env")
  has(text, "user command :IsoLeakCmd", "user command")
  has(text, "keymap n <Plug>(iso-leak)", "keymap")
  has(text, "working directory changed", "cwd")
  has(text, "buffer", "buffer")
  has(text, "window", "window")
  has(text, "(restored before the next file)", "and that it was restored")
  for _, f in ipairs(report.findings) do
    eq(f.guard, "state", "the guard is `state`")
    eq(f.severity, "warn", "severity follows the configuration")
  end
  -- the items carry the same, structured
  local kinds = {}
  for _, item in ipairs(report.items) do
    kinds[item.kind] = (kinds[item.kind] or 0) + 1
    ok(item.restored, "restored: " .. item.name)
  end
  for _, kind in ipairs({
    "autocmd",
    "global",
    "package",
    "vim.g",
    "env",
    "command",
    "keymap",
    "cwd",
    "buffer",
    "window",
  }) do
    ok(kinds[kind], "an item of kind " .. kind)
  end
  -- the findings are in a stable order (autocmd before global before package: `snapshot.ORDER`)
  local sorted = vim.deepcopy(report.items)
  table.sort(sorted, function(x, y)
    local rank = {}
    for i, k in ipairs(snapshot.ORDER) do
      rank[k] = i
    end
    if rank[x.kind] ~= rank[y.kind] then
      return rank[x.kind] < rank[y.kind]
    end
    return false
  end)
  eq(report.items[1].kind, sorted[1].kind, "items are listed in the order they are undone")
  eq(report.items[#report.items].kind, "package", "modules last")

  -- a clean file is silent
  local frame2 = session:enter("TESTS/clean_spec.lua")
  local clean = session:leave(frame2)
  eq(
    { #clean.findings, #clean.items, clean.restored, clean.unrestored },
    { 0, 0, 0, 0 },
    "no leak, no finding"
  )
  local totals = session:totals()
  eq(
    { totals.files, totals.leaky_files },
    { 2, 1 },
    "the session counts the files and the leaky ones"
  )
  ok(totals.restored >= 9, "and what it restored")

  -- ================================================================== severity and the reporting switches
  local quiet = isolation.new({}) -- no severity: restore, report nothing
  local fq = quiet:enter("TESTS/quiet_spec.lua")
  pollute()
  local rq = quiet:leave(fq)
  eq(#rq.findings, 0, "no severity: no finding")
  ok(#rq.items >= 9, "but the items are still there")
  eq(
    clean_state().global and clean_state().group and clean_state().cwd,
    true,
    "and the editor is restored"
  )

  local strict = isolation.new({ severity = "error" })
  local fe = strict:enter("TESTS/strict_spec.lua")
  rawset(_G, "iso_leak_global", 1)
  local re = strict:leave(fe)
  eq(re.findings[1].severity, "error", "severity = error")
  eq(rawget(_G, "iso_leak_global"), nil, "and the global is gone")

  local only_left = isolation.new({ severity = "warn", report_restored = false })
  local fo = only_left:enter("TESTS/only_left_spec.lua")
  rawset(_G, "iso_leak_global", 1)
  local ro = only_left:leave(fo)
  eq(#ro.findings, 0, "report_restored = false: a restored leak is not reported")
  eq(#ro.items, 1, "but it is in the items")

  -- ================================================================== the keep list
  local kept = isolation.new({ severity = "warn", keep = { "iso.keep*" } })
  local fk = kept:enter("TESTS/keep_spec.lua")
  package.loaded["iso.keep.mod"] = { kept = true }
  package.loaded["iso.leak.mod"] = { kept = false }
  package.loaded["testing.iso_fake_kept"] = {}
  package.loaded["lib.iso_fake_kept"] = {}
  local rk = kept:leave(fk)
  ok(package.loaded["iso.keep.mod"] ~= nil, "soft_keep: a module the project listed stays loaded")
  ok(package.loaded["testing.iso_fake_kept"] ~= nil, "testing.* itself is never unloaded")
  ok(package.loaded["lib.iso_fake_kept"] ~= nil, "lib.* (lib.nvim) is never unloaded")
  eq(package.loaded["iso.leak.mod"], nil, "a module that is not kept is unloaded")
  local ktext = joined(rk)
  ok(not ktext:find("iso.keep.mod", 1, true), "a kept module is no finding")
  ok(not ktext:find("iso_fake_kept", 1, true), "neither are testing.* / lib.*")
  has(ktext, "iso.leak.mod", "the other one is")
  eq(snapshot.is_kept("vim.lsp"), true, "the editor's own modules are kept")
  eq(snapshot.is_kept("vim"), true, "vim itself")
  eq(snapshot.is_kept("jit.util"), true, "the Lua runtime")
  eq(snapshot.is_kept("vimtex"), false, "a name that only STARTS like `vim` is not the editor's")
  eq(snapshot.is_kept("libfoo"), false, "nor is `libfoo` the lib namespace")
  eq(snapshot.is_kept("my.mod", { "my.mod" }), true, "an exact name")
  eq(snapshot.is_kept("my.mod2", { "my.mod" }), false, "exact means exact")
  eq(snapshot.is_kept("my.mod2", { "my.*" }), true, "a prefix pattern")

  -- ================================================================== what cannot be restored is named
  local victim = vim.api.nvim_create_buf(true, false)
  local sess3 = isolation.new({ severity = "warn" })
  local f3 = sess3:enter("TESTS/wipe_spec.lua")
  vim.api.nvim_buf_delete(victim, { force = true })
  local r3 = sess3:leave(f3)
  eq(r3.unrestored, 1, "a wiped buffer cannot be brought back")
  has(
    joined(r3),
    "(NOT restored: a wiped buffer cannot be brought back)",
    "and the finding says so"
  )
  eq(r3.items[1].restored, false, "the item is marked")

  -- the restore is verified: a backend whose restore does nothing is caught, a lying one too
  local flag = { v = false }
  local real = snapshot
  local liar = {
    capture = function()
      return { flag = flag.v }
    end,
    diff = function(before, later)
      if before.flag ~= later.flag then
        return {
          {
            kind = "global",
            change = "added",
            key = "global:flag",
            name = "global `flag`",
            restore = function()
              return true
            end,
          },
        }
      end
      return {}
    end,
    restore = function()
      return {} -- claims success, did nothing
    end,
  }
  local sess4 = isolation.new({ severity = "warn", backend = liar })
  eq(sess4.backend_name, "injected", "an injected backend is used")
  local f4 = sess4:enter("TESTS/liar_spec.lua")
  flag.v = true
  local r4 = sess4:leave(f4)
  eq(r4.unrestored, 1, "a restore that did not work is found by looking again")
  has(joined(r4), "NOT restored", "and reported as such")
  ok(real ~= nil, "the real backend is untouched")

  -- a backend that raises never takes the run with it
  local broken = isolation.new({
    severity = "warn",
    backend = {
      capture = function()
        return {}
      end,
      diff = function()
        error("diff exploded")
      end,
      restore = function()
        return {}
      end,
    },
  })
  local fb = broken:enter("TESTS/broken_spec.lua")
  local rb = broken:leave(fb)
  eq(rb.unrestored, 1, "a failing backend is one unrestored item")
  has(joined(rb), "diff exploded", "naming the reason")
  local nb = isolation.new({
    severity = "warn",
    backend = {
      capture = function()
        error("capture exploded")
      end,
      diff = function()
        return {}
      end,
      restore = function()
        return {}
      end,
    },
  })
  local fnil = nb:enter("TESTS/nocapture_spec.lua")
  eq(fnil, nil, "a snapshot that fails gives no frame")
  has(
    joined(nb:leave(fnil)),
    "could not take its snapshot",
    "and `leave` says the file ran unprotected"
  )

  -- ================================================================== the seam: the guard layer's backend
  local saved_state = package.loaded["testing.guard.state"]
  package.loaded["testing.guard.state"] = {
    soft_backend = function()
      return liar
    end,
  }
  local b, name = isolation.backend()
  local _
  eq(
    { b == liar, name },
    { true, "testing.guard.state" },
    "the guard layer's backend is taken when it offers one"
  )
  package.loaded["testing.guard.state"] = {
    soft_backend = function()
      return { capture = 1 }
    end,
  }
  _, name = isolation.backend()
  eq(name, "internal", "a backend that is not complete is ignored")
  package.loaded["testing.guard.state"] = {
    soft_backend = function()
      error("no")
    end,
  }
  _, name = isolation.backend()
  eq(name, "internal", "a backend that raises is ignored")
  package.loaded["testing.guard.state"] = saved_state
  _, name = isolation.backend()
  eq(name, "internal", "without an export the internal one")

  -- ================================================================== through the runner: a polluted file sequence
  local inproc = require("testing.run.inproc")
  local result = require("testing.core.result")
  local root = S.new_root()
  local polluter = [[
return function(H)
  local group = vim.api.nvim_create_augroup("IsoSeqGroup", { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", { group = group, pattern = "*.isoseq", command = "echo 1" })
  rawset(_G, "iso_seq_global", true)
  package.loaded["iso.seq.mod"] = { x = 1 }
  vim.api.nvim_set_current_dir(vim.uv.os_tmpdir())
  H.eq(1, 1, "polluter ran")
end
]]
  local victim_spec = [[
return function(H)
  H.eq(rawget(_G, "iso_seq_global"), nil, "the global of the previous file is gone")
  H.eq(package.loaded["iso.seq.mod"], nil, "the module of the previous file is gone")
  H.eq(pcall(vim.api.nvim_get_autocmds, { group = "IsoSeqGroup" }), false, "the autocmd group is gone")
  H.eq(vim.uv.cwd():lower(), (ROOT):lower(), "the working directory is the one the run started in")
end
]]
  victim_spec = victim_spec:gsub("ROOT", function()
    return string.format("%q", cwd0)
  end)
  local entries = S.project(root, {
    ["TESTS/a_polluter_spec.lua"] = polluter,
    ["TESTS/b_victim_spec.lua"] = victim_spec,
  }, { "TESTS/a_polluter_spec.lua", "TESTS/b_victim_spec.lua" })
  local files = { entries[1].path, entries[2].path }
  local function sequence(extra)
    local opts = vim.tbl_extend("force", { root = root, files = files, dialect = "a" }, extra or {})
    local rep = inproc.run(opts)
    pcall(vim.api.nvim_del_augroup_by_name, "IsoSeqGroup")
    rawset(_G, "iso_seq_global", nil)
    package.loaded["iso.seq.mod"] = nil
    pcall(vim.api.nvim_set_current_dir, cwd0)
    return rep
  end

  -- WITHOUT soft isolation the second file sees the first one's leaks: the fixture does pollute
  local plain = sequence()
  local victim_case
  for _, c in ipairs(plain.result.cases) do
    if c.file == "TESTS/b_victim_spec.lua" then
      victim_case = c
    end
  end
  eq(victim_case.status, "fail", "control: without soft isolation the next file fails on the leak")
  eq(plain.exit_code, 1, "control: and the run is red")

  -- WITH soft isolation it is green, and the polluter's case carries the named leaks
  local soft_session = isolation.new({ severity = "warn" })
  local soft = sequence({ soft = soft_session })
  eq(soft.exit_code, 0, "soft: the next file sees a clean state, the run is green")
  eq(soft.failed, 0, "soft: nothing failed")
  local by = {}
  for _, c in ipairs(soft.result.cases) do
    by[c.file] = c
  end
  eq(by["TESTS/b_victim_spec.lua"].status, "pass", "soft: the victim passes")
  eq(by["TESTS/b_victim_spec.lua"].guards, nil, "soft: and has no finding")
  local pc = by["TESTS/a_polluter_spec.lua"]
  eq(pc.status, "pass", "soft: severity warn does not fail the polluter")
  ok(pc.guards and #pc.guards >= 4, "soft: the polluter's case lists its leaks")
  local gtext = {}
  for _, g in ipairs(pc.guards) do
    eq(g.guard, "state", "the guard is `state`")
    eq(g.severity, "warn", "a warning")
    gtext[#gtext + 1] = g.message
  end
  local gjoined = table.concat(gtext, "\n")
  has(
    gjoined,
    "TESTS/a_polluter_spec.lua leaves autocmd BufEnter (pattern *.isoseq) in group `IsoSeqGroup`",
    "autocmd"
  )
  has(gjoined, "global `iso_seq_global`", "global")
  has(gjoined, "module `iso.seq.mod`", "module")
  has(gjoined, "working directory changed", "cwd")
  local valid, problems = result.validate(soft.result, { allow_abs_paths = true })
  eq({ valid, problems }, { true, {} }, "the IR with findings is valid")
  eq(soft_session:totals().leaky_files, 1, "the session counted one leaky file")

  -- severity error: the polluter itself is red, the victim is still green (the leak is contained)
  local hard = sequence({ soft = isolation.new({ severity = "error" }) })
  eq(hard.exit_code, 1, "error: the run is red")
  by = {}
  for _, c in ipairs(hard.result.cases) do
    by[c.file] = c
  end
  eq(by["TESTS/a_polluter_spec.lua"].status, "fail", "error: the polluter fails")
  local guard_assertion
  for _, a in ipairs(by["TESTS/a_polluter_spec.lua"].assertions) do
    if a.kind == "guard" and not a.ok then
      guard_assertion = a
    end
  end
  ok(guard_assertion ~= nil, "error: with a failed `guard` assertion")
  has(guard_assertion.msg, "guard state: TESTS/a_polluter_spec.lua leaves", "that names the leak")
  eq(by["TESTS/b_victim_spec.lua"].status, "pass", "error: the next file is not dragged down")
  valid, problems = result.validate(hard.result, { allow_abs_paths = true })
  eq({ valid, problems }, { true, {} }, "error: the IR is valid")

  -- severity off: restored, silently
  local silent = sequence({ soft = isolation.new({}) })
  eq(silent.exit_code, 0, "silent: green")
  eq(silent.result.cases[1].guards, nil, "silent: no finding on the polluter")

  -- the `soft_keep` list reaches the run: a kept module survives the polluter
  local keep_session = isolation.new({ severity = "warn", keep = { "iso.seq.*" } })
  local keep_run = sequence({ soft = keep_session })
  eq(keep_run.exit_code, 1, "kept module: the victim now sees it (the project asked for it)")
  S.cleanup()
  cleanup()
end
