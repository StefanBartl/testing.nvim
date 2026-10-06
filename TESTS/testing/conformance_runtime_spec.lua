-- TESTS/testing/conformance_runtime_spec.lua -- the runtime checks of the conformance suite (K1 runtime
-- half, K2 .. K6, K8 .. K14) against REAL child editors: the conformant fixture plugin passes every one,
-- a copy that breaks one rule per check fails exactly that check, with the finding that names it.

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")

  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  ---A recursive listing of a tree with size and mtime: what a run must not change.
  local function snapshot(root)
    local out = {}
    local function walk(path, rel)
      for name, kind in vim.fs.dir(path) do
        local p, r = path .. "/" .. name, rel .. "/" .. name
        local st = vim.uv.fs_stat(p)
        out[#out + 1] = ("%s %s %s %s"):format(
          r,
          kind,
          st and st.size or "?",
          st and st.mtime.sec or "?"
        )
        if kind == "directory" then
          walk(p, r)
        end
      end
    end
    walk(root, "")
    table.sort(out)
    return table.concat(out, "\n")
  end

  local function expect(report, id, needle, msg)
    local f = S.finding(report, id, needle)
    ok(f ~= nil, ("%s: no finding with %q (%s)"):format(msg, needle, S.messages(report, id)))
    return f
  end

  local function status(report, id)
    return S.check(report, id).status
  end

  S.run(function()
    -- ===================================================================
    -- 1. the conformant fixture: every check passes, nothing is written into the repository
    local good = S.new_repo()
    local before = snapshot(good)
    local report = conformance.run(good)
    for _, check in ipairs(conformance.checks()) do
      ok(status(report, check.id) == "pass", "good fixture: " .. S.messages(report, check.id))
    end
    ok(report.verdict == "pass", "the verdict is pass")
    eq(snapshot(good), before, "the run changed nothing in the checked repository (SEC-47)")
    ok(S.check(report, "K1").notes[1]:find("8 of 8", 1, true) ~= nil, "K1 required all 8 modules")
    ok(
      S.check(report, "K4").notes[1]:find("1 keymap", 1, true) ~= nil,
      "K4 had a keymap to look at"
    )

    -- ===================================================================
    -- 2. a copy that breaks one rule per check
    local bad = S.new_repo()
    S.write(bad .. "/lua/goodp/broken.lua", 'error("boom on require")\nreturn {}\n')
    -- a module meant to run as an init script: requiring it ends the editor
    S.write(bad .. "/lua/goodp/killer.lua", "os.exit(3)\nreturn {}\n")
    S.write(
      bad .. "/lua/goodp/sidefx.lua",
      '_G.sidefx_global = 1\nvim.api.nvim_create_user_command("Goodside", function() end, {})\nreturn {}\n'
    )
    S.patch(
      bad,
      "lua/goodp/init.lua",
      '  require("goodp.bindings.autocmds").setup()\n',
      table.concat({
        '  require("goodp.bindings.autocmds").setup()',
        '  vim.api.nvim_create_autocmd("BufEnter", { callback = function() end }) -- K2: no group',
        '  vim.keymap.set("n", "<leader>gz", function() end) -- K3 and K4: always bound, no desc',
        '  vim.deprecate("goodp.old()", "goodp.new()", "9.9.9", "goodp", false) -- K8',
        '  vim.system({ vim.v.progpath, "--version" }):wait() -- K9: a process',
        '  local src = debug.getinfo(1, "S").source:sub(2)',
        "  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))",
        '  local leak = io.open(root .. "/leak.txt", "w") -- K9: a write outside tmp',
        "  if leak then",
        '    leak:write("x")',
        "    leak:close()",
        "  end",
        "  _G.goodp_leak = true -- K11",
        "",
      }, "\n")
    )
    S.patch(
      bad,
      "lua/goodp/bindings/keymaps.lua",
      '        desc = "open the goodp window",\n      },\n',
      table.concat({
        '        desc = "open the goodp window",',
        "      },",
        "      zzfrob = {",
        '        default = "<C-M-y>",',
        "        rhs = function() end,",
        '        desc = "unrelated words only",',
        "      },",
        "",
      }, "\n")
    )
    S.patch(
      bad,
      "lua/goodp/bindings/usrcmds.lua",
      "---@return nil\nfunction M.setup()\n",
      '---@return nil\nfunction M.setup()\n  vim.api.nvim_create_user_command("Goodbad", function() end, { nargs = "*" })\n'
    )
    S.patch(
      bad,
      "lua/goodp/health.lua",
      'vim.health.ok("goodp is loaded")',
      'vim.health.error("broken on purpose")'
    )
    S.patch(
      bad,
      "lua/goodp/util.lua",
      "  return ok\n",
      '  pcall(require, "never-checked-dep")\n  return ok\n'
    )
    -- a command that only a plugin/ file defines: the suite must source plugin/ INSIDE its window
    S.write(
      bad .. "/plugin/goodp.lua",
      'vim.api.nvim_create_user_command("Goodplug", function() end, { nargs = 1 })\n'
    )
    local bad_before = snapshot(bad)
    report = conformance.run(bad, { settings = { load_budget_ms = 0 } })

    -- K1: the module that raises is named with its file; the side effects are warnings
    local k1 = expect(report, "K1", 'require("goodp.broken") fails: ', "K1 a module that raises")
    ok(k1.level == "error" and k1.file == "lua/goodp/broken.lua", "K1 names the module's file")
    ok(k1.message:find("boom on require", 1, true) ~= nil, "K1 carries the error")
    ok(
      not k1.message:find(bad, 1, true),
      "K1 never prints the absolute path of the checked repository"
    )
    local killer = expect(
      report,
      "K1",
      'require("goodp.killer") fails: the editor ended',
      "K1 a module that ends the editor"
    )
    ok(
      killer.level == "error" and killer.file == "lua/goodp/killer.lua",
      "K1 names the module that ended the editor"
    )
    expect(report, "K1", "global(s) sidefx_global", "K1 a top-level global")
    expect(report, "K1", "command(s) Goodside", "K1 a top-level command")
    eq(status(report, "K1"), "fail", "K1 fails")

    -- K2: an autocmd without a group stacks
    local k2 = expect(report, "K2", "added 1 autocommand(s)", "K2 a stacking autocmd")
    ok(k2.level == "error", "K2 is an error")
    eq(status(report, "K2"), "fail", "K2 fails")

    -- K3: the raw keymap cannot be switched off
    local k3 = expect(report, "K3", "<leader>gz", "K3 a keymap that stays")
    ok(k3.level == "error", "K3 is an error")
    ok(S.finding(report, "K3", "keymaps = false") ~= nil, "K3 names the setup it used")
    eq(status(report, "K3"), "fail", "K3 fails")

    -- K4: no desc
    expect(report, "K4", "has no desc", "K4 a keymap without a desc")
    eq(status(report, "K4"), "fail", "K4 fails")

    -- K5: a command that takes arguments and has no completion
    local k5 = expect(report, "K5", ":Goodbad takes arguments", "K5 a command without completion")
    ok(k5.level == "warn", "K5 is a warning (free text is allowed to go without)")
    ok(S.finding(report, "K5", ":Goodp ") == nil, "the completed command is fine")
    expect(report, "K5", ":Goodplug takes arguments", "K5 sees a command of a plugin/ file")

    -- K6: the health check says ERROR
    local k6 = expect(report, "K6", "broken on purpose", "K6 a health error")
    ok(k6.level == "error", "K6 is an error")
    eq(status(report, "K6"), "fail", "K6 fails")

    -- K7: a soft dependency nobody checks
    expect(report, "K7", '"never-checked-dep"', "K7 a soft dependency")

    -- K8: vim.deprecate
    expect(report, "K8", "goodp.old()", "K8 a deprecation message")
    eq(status(report, "K8"), "fail", "K8 fails")

    -- K9: a process and a write outside tmp
    expect(report, "K9", "starts a process", "K9 a process")
    expect(report, "K9", "writes outside the temp directory", "K9 a write")
    eq(status(report, "K9"), "fail", "K9 fails")

    -- K10: report-only; the budget of 0 ms is exceeded
    local k10 = expect(report, "K10", "the budget is 0 ms", "K10 over budget")
    ok(k10.level == "warn", "K10 only warns")
    eq(status(report, "K10"), "warn", "K10 warns")

    -- K11: a global
    expect(report, "K11", "_G.goodp_leak", "K11 a global")
    eq(status(report, "K11"), "fail", "K11 fails")

    -- K12 / K13: report only
    expect(report, "K12", "zzfrob", "K12 an action without a command")
    expect(report, "K13", "zzfrob", "K13 a key that not every terminal delivers")
    for _, id in ipairs({ "K12", "K13" }) do
      for _, f in ipairs(S.check(report, id).findings) do
        ok(f.level ~= "error", id .. " can never be an error: " .. f.message)
      end
    end

    -- K14: a registered command the documentation does not mention
    expect(
      report,
      "K14",
      ":Goodbad is registered but not documented",
      "K14 an undocumented command"
    )
    eq(status(report, "K14"), "fail", "K14 fails")

    -- the verdict, the exit codes of the two modes
    eq(report.verdict, "fail", "the verdict is fail")
    eq(conformance.exit_code(report), 0, "report-only mode exits 0 even with failures")
    local gated = vim.deepcopy(report)
    gated.mode = "gate"
    eq(conformance.exit_code(gated), 1, "gate mode exits 1")
    ok(
      snapshot(bad):find("leak.txt", 1, true) ~= nil,
      "(the fixture plugin did write its leak file)"
    )
    ok(bad_before:find("leak.txt", 1, true) == nil, "(and it was not there before the run)")

    -- ===================================================================
    -- 3. special cases with their own child
    -- a plugin without setup(): K2 does not apply, the rest runs
    local nosetup = S.new_repo()
    S.write(nosetup .. "/lua/goodp/init.lua", "return {}\n")
    report = conformance.run(nosetup, { only = { "K1", "K2", "K3", "K11" } })
    eq(status(report, "K2"), "n/a", "no setup(): K2 does not apply")
    ok(S.check(report, "K2").reason:find("no setup()", 1, true) ~= nil, "and says why")
    eq(status(report, "K11"), "pass", "K11 still looks at the load")

    -- a dependency of .testing.lua that is not found is said, once
    local nodep = S.new_repo()
    report =
      conformance.run(nodep, { only = { "K11", "K8" }, config = { deps = { "no-such-dep.nvim" } } })
    local noted = 0
    for _, p in ipairs(report.problems) do
      if p:find("no-such-dep.nvim", 1, true) then
        noted = noted + 1
      end
    end
    eq(noted, 1, "the missing dependency is noted once, although two checks share the session")

    -- a plugin whose entry module raises: K1 fails, the rest is blocked by it (not an error)
    local raising = S.new_repo()
    S.write(raising .. "/lua/goodp/init.lua", 'error("cannot load")\n')
    report = conformance.run(raising, { only = { "K1", "K2", "K6", "K11" } })
    eq(status(report, "K1"), "fail", "K1 fails when the entry module raises")
    for _, id in ipairs({ "K2", "K6", "K11" }) do
      eq(status(report, id), "n/a", id .. " is blocked, not an error")
      ok(S.check(report, id).reason:find("blocked", 1, true) ~= nil, id .. " names the blocker")
    end
    eq(
      report.verdict,
      "fail",
      "a plugin that does not load is a failure, not an infrastructure error"
    )

    -- a plugin with no entry module at all
    local library = S.new_repo()
    S.remove(library, "lua/goodp/init.lua")
    report = conformance.run(library, { only = { "K2" } })
    eq(status(report, "K2"), "n/a", "no entry module: nothing to set up")
    ok(S.check(report, "K2").reason:find("finds no entry module", 1, true) ~= nil, "and says so")

    -- setup options that cannot travel to a child editor are an error of the configuration, said clearly
    local fn_opts = S.new_repo()
    report = conformance.run(fn_opts, {
      only = { "K2" },
      config = { setup = { on_attach = function() end } },
    })
    eq(status(report, "K2"), "error", "a function in `setup` cannot be sent to the child")
    ok(
      S.check(report, "K2").reason:find("cannot be sent", 1, true) ~= nil,
      "and the reason names it"
    )

    -- K3 on a plugin whose keymaps are opt-in and which registers none by default
    local optin = S.new_repo()
    S.write(optin .. "/.testing.lua", 'return { plugin = "goodp" }\n')
    report = conformance.run(optin, { only = { "K3", "K4", "K12" } })
    for _, id in ipairs({ "K3", "K4" }) do
      eq(status(report, id), "n/a", id .. " has nothing to check without a keymap")
      ok(
        S.check(report, id).reason:find("list the keymaps in `setup`", 1, true) ~= nil,
        id .. " says how to enable it"
      )
    end

    -- K3: a `setup` that REJECTS keymaps = false is a failure with the reason
    local strict = S.new_repo()
    S.patch(
      strict,
      "lua/goodp/config/init.lua",
      'error("goodp: keymaps must be a table or false", 0)',
      'error("goodp: keymaps must be a table", 0)'
    )
    S.patch(strict, "lua/goodp/config/init.lua", " and opts.keymaps ~= false then", " then")
    report = conformance.run(strict, { only = { "K3" } })
    local reject = expect(
      report,
      "K3",
      "raised, so the keymaps cannot be switched off",
      "K3 a setup that rejects the off switch"
    )
    ok(reject.message:find("keymaps must be a table", 1, true) ~= nil, "with the plugin's message")

    -- a configurable off switch: `conformance.keymaps_off` names what to pass
    local custom = S.new_repo()
    S.patch(
      custom,
      "lua/goodp/init.lua",
      'local config = require("goodp.config").setup(opts)',
      'local config = require("goodp.config").setup(opts)\n  if opts and opts.mappings == false then\n    config.keymaps = false\n  end'
    )
    report = conformance.run(
      custom,
      { only = { "K3" }, settings = { keymaps_off = { mappings = false } } }
    )
    eq(status(report, "K3"), "pass", "the configured off switch is used")
  end)
end
