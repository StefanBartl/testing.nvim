-- TESTS/testing/conformance_review_gate_spec.lua -- the findings of the REVIEW.md gate on the conformance suite
-- (2026-10-31), one block each: a check that could not look must say so (`error`), never `pass` or `n/a`.

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")
  local runtime = require("testing.conformance.runtime")
  local probe = require("testing.conformance.probe")
  local fsx = require("testing.conformance.fsx")

  local function status(report, id)
    return S.check(report, id).status
  end

  ---A run over faked session data: `main` is `main_data`, every other session is not there.
  local function faked(root, main_data, only)
    return conformance.run(root, {
      only = only,
      probe = function(name)
        if name == "main" then
          local copy = vim.deepcopy(main_data) --[[@as table]]
          return copy, nil
        end
        return nil, "not faked: " .. name
      end,
    })
  end

  S.run(function()
    local repo = S.new_repo()

    -- 1. setup() hung or ended the editor: the facts are an error, and the checks that read them say so
    local report = faked(repo, {
      plugin = "goodp",
      load = { ok = true, has_setup = true },
      facts1 = { err = "RPC call nvim_exec_lua timed out" },
      audit = {
        lib = true,
        actions = {},
        routes = {},
        gaps = {},
        key_risks = {},
        prefix = {},
        composer = {},
      },
      plugin_files = {},
    }, { "K3", "K4", "K5", "K13", "K14" })
    for _, id in ipairs({ "K3", "K4", "K5", "K13", "K14" }) do
      ok(
        status(report, id) == "error",
        ("%s with no facts is an error, not %s (%s)"):format(
          id,
          status(report, id),
          S.messages(report, id)
        )
      )
    end

    -- 2. a lib.nvim audit that raised is an error, not "nothing to audit"
    report = faked(repo, {
      plugin = "goodp",
      load = { ok = true, has_setup = true },
      facts1 = { keymaps = {}, commands = {}, globals = {}, leader = "\\" },
      audit = {
        lib = true,
        actions_err = "boom",
        key_risks_err = "boom",
        prefix_err = "boom",
        composer_err = "boom",
      },
      plugin_files = {},
    }, { "K5", "K12", "K13" })
    for _, id in ipairs({ "K5", "K12", "K13" }) do
      ok(
        status(report, id) == "error",
        ("%s with a raising audit is an error, not %s (%s)"):format(
          id,
          status(report, id),
          S.messages(report, id)
        )
      )
    end

    -- 3. K1 in real child editors: a module that hangs is named and the others keep their results; a plugin/
    --    file that raises is an error of K1 (it was sourced and never read)
    local real = S.new_repo()
    S.write(real .. "/lua/goodp/hang.lua", "while true do end\nreturn {}\n")
    S.write(real .. "/plugin/pf.lua", 'error("boom from plugin/pf.lua")\n')
    report = conformance.run(real, { only = { "K1" }, settings = { timeout_ms = 3000 } })
    ok(
      S.finding(report, "K1", 'require("goodp.hang") fails: the require did not return') ~= nil,
      "the hanging module is named: " .. S.messages(report, "K1")
    )
    ok(
      (S.check(report, "K1").notes[#S.check(report, "K1").notes] or ""):find(
        "8 of 9 module",
        1,
        true
      ) ~= nil,
      "every other module has its result: " .. S.messages(report, "K1")
    )
    ok(
      S.finding(report, "K1", "sourcing plugin/pf.lua fails: ") ~= nil,
      "a raising plugin/ file is a K1 finding: " .. S.messages(report, "K1")
    )

    -- 4. a log without a started module: the editor died before the first require -> infrastructure error
    local session = runtime.session
    -- the spec swaps the session in for one run (and puts the real one back below)
    ---@diagnostic disable-next-line: duplicate-set-field
    runtime.session = function(ctx, name, fn)
      if name ~= "require" then
        return session(ctx, name, fn)
      end
      pcall(fn, nil, function(_, _, progress)
        S.write(progress, "")
        error("child died during nvim_exec_lua: it ended with exit code 9")
      end)
      return nil, "child died during nvim_exec_lua: it ended with exit code 9"
    end
    local okr, empty = pcall(conformance.run, repo, { only = { "K1" } })
    runtime.session = session
    assert(okr, empty)
    ok(
      status(empty, "K1") == "error",
      "an empty log is an infrastructure error: " .. S.messages(empty, "K1")
    )
    ok(
      (S.check(empty, "K1").reason or ""):find("ended before it required a module", 1, true) ~= nil,
      "and says why: " .. tostring(S.check(empty, "K1").reason)
    )

    -- 5. the file walk: `lua` is a suffix with a dot, not "any character before lua"
    S.write(repo .. "/lua/goodp/xinitlua", "not lua\n")
    local fs = fsx.new(repo)
    ok(
      not vim.tbl_contains(fs:walk("lua", { ext = "lua" }), "lua/goodp/xinitlua"),
      "xinitlua is no Lua file"
    )
    ok(vim.tbl_contains(fs:walk("lua", { ext = "lua" }), "lua/goodp/init.lua"), "init.lua is one")

    -- 6. a path is found only in its listed spelling (Windows' fs_stat ignores case, a Linux runner does not)
    ok(fs:is_file("README.md"), "README.md is there")
    ok(not fs:is_file("README.MD"), "README.MD is not, on every platform")
    ok(not fs:is_file("Lua/goodp/init.lua"), "neither is Lua/goodp/init.lua")
    ok(fs:is_dir("docs") and not fs:is_dir("DOCS"), "docs is a directory, DOCS is not")

    -- 7. plugin/ in the editor's order: every *.vim before every *.lua
    local order_root = S.new_repo("order.nvim")
    S.write(
      order_root .. "/plugin/a.lua",
      'vim.g.cf_order = vim.list_extend(vim.g.cf_order or {}, { "a.lua" })\n'
    )
    S.write(order_root .. "/plugin/b.vim", "let g:cf_order = get(g:, 'cf_order', []) + ['b.vim']\n")
    S.write(
      order_root .. "/plugin/sub/c.lua",
      'vim.g.cf_order = vim.list_extend(vim.g.cf_order or {}, { "c.lua" })\n'
    )
    S.write(order_root .. "/plugin/z.vim", "let g:cf_order = get(g:, 'cf_order', []) + ['z.vim']\n")
    local sourced = probe.source_plugin(order_root)
    local order = vim.g.cf_order
    vim.g.cf_order = nil
    ok(#sourced == 4, "four plugin files sourced: " .. vim.inspect(sourced))
    ok(
      vim.deep_equal(order, { "b.vim", "z.vim", "a.lua", "c.lua" }),
      "vim files first, then lua: " .. vim.inspect(order)
    )

    -- 8. "workspace.library": null is no library (LuaLS reads a JSON null as unset)
    local nulled = S.new_repo("nulled.nvim")
    S.patch(
      nulled,
      ".luarc.json",
      '"runtime.version": "LuaJIT",',
      '"runtime.version": "LuaJIT",\n  "workspace.library": null,'
    )
    report = conformance.run(nulled, { only = { "K15" } })
    ok(
      S.finding(report, "K15", "workspace.library replaces") == nil,
      "a null library is not a finding: " .. S.messages(report, "K15")
    )

    -- 9. the bridge: a rule's own verdict wins over the one it gets as another rule's alias
    local owner
    for id, rule in pairs(require("testing.conformance.rules").index()) do
      if vim.tbl_contains(rule.also or {}, "NEW-14") then
        owner = id
      end
    end
    ok(owner ~= nil, "some rule lists NEW-14 under `also`")
    local ours = require("testing.conformance.rules_bridge")._ours
    -- only `rule_status` is read: the rest of a check result does not matter here
    local v1 = ours({
      ---@diagnostic disable-next-line: missing-fields
      { rule_status = { [owner] = { status = "warn" }, ["NEW-14"] = { status = "pass" } } },
    })
    local v2 = ours({
      ---@diagnostic disable-next-line: missing-fields
      { rule_status = { [owner] = { status = "pass" }, ["NEW-14"] = { status = "fail" } } },
    })
    ok(v1["NEW-14"] == "pass", "NEW-14's own pass wins over its alias' fail: " .. vim.inspect(v1))
    ok(v2["NEW-14"] == "fail", "NEW-14's own fail wins over its alias' pass: " .. vim.inspect(v2))

    -- 10. :checkhealth: an ERROR below line 500 is still read
    local hroot = vim.fs.normalize(vim.fn.tempname()) .. "-health"
    S.write(
      hroot .. "/lua/cfhealthx/health.lua",
      table.concat({
        "return { check = function()",
        '  vim.health.start("cfhealthx")',
        '  for i = 1, 600 do vim.health.info("line " .. i) end',
        '  vim.health.error("late boom")',
        "end }",
      }, "\n")
    )
    vim.opt.rtp:prepend(hroot)
    local health = probe.health("cfhealthx")
    vim.opt.rtp:remove(hroot)
    pcall(vim.cmd --[[@as function]], "silent! tabclose!")
    pcall(vim.fn.delete, hroot, "rf")
    local late = false
    for _, line in ipairs(health.lines or {}) do
      late = late or (line:find("late boom", 1, true) ~= nil)
    end
    ok(
      health.ok and #health.lines > 500,
      ("the whole report is read (%d lines)"):format(#(health.lines or {}))
    )
    ok(late, "the ERROR after line 600 is in the lines")
  end)
end
