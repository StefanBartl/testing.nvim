-- TESTS/testing/conformance_hardening_spec.lua -- `testing conformance` reads a repository it does not trust:
-- a hostile file must not make it run for hours (SEC-30/32), a link on an intermediate directory must not make
-- it read outside the repository (SEC-42), and memory is bounded as a whole.

---@diagnostic disable: need-check-nil
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")
  local fsx = require("testing.conformance.fsx")

  local function probe(name)
    if name == "require" then
      return { results = {} }
    end
    return nil, "no child editor in this spec"
  end

  S.run(function()
    -- ===================================================================
    -- 1. quadratic patterns: a line of a million characters is cut before any check looks at it
    local repo = S.new_repo()
    S.write(
      repo .. "/README.md",
      "# goodp\n\n## Installation\n\n" .. string.rep("[", 400000) .. "\n"
    )
    S.write(
      repo .. "/lua/goodp/hostile.lua",
      "local x = require" .. string.rep(" ", 200000) .. '("goodp")\nreturn x\n'
    )
    local started = vim.uv.hrtime()
    local report =
      conformance.run(repo, { only = { "K1", "K7", "K15" }, probe = probe, settings = {} })
    local seconds = (vim.uv.hrtime() - started) / 1e9
    ok(seconds < 20, ("a hostile line costs no time (took %.1f s)"):format(seconds))
    local noted = false
    for _, p in ipairs(report.problems) do
      if p:find("were cut before the checks looked at them", 1, true) then
        noted = true
      end
    end
    ok(noted, "the report says that lines were cut: " .. vim.inspect(report.problems))

    -- the cap itself
    local lines, cut = fsx.cap_lines("short\n" .. string.rep("x", fsx.MAX_LINE + 5) .. "\nshort2\n")
    ok(#lines == 3 and cut == 1, "one long line is cut")
    ok(#lines[2] == fsx.MAX_LINE, "to the cap")
    lines, cut = fsx.cap_lines("a\r\nb\r\n")
    ok(vim.deep_equal(lines, { "a", "b" }) and cut == 0, "CRLF is one terminator")

    -- sources: a big Lua file is not taken, and the whole is bounded
    local big = S.new_repo()
    S.write(
      big .. "/lua/goodp/big.lua",
      "return {}\n-- " .. string.rep("y", fsx.MAX_SOURCE_BYTES + 10) .. "\n"
    )
    local report2 = conformance.run(big, { only = { "K15" }, probe = probe, settings = {} })
    local skipped = false
    for _, p in ipairs(report2.problems) do
      if p:find("were not read", 1, true) then
        skipped = true
      end
    end
    ok(
      skipped,
      "a Lua file over the size cap is reported as not read: " .. vim.inspect(report2.problems)
    )

    -- ===================================================================
    -- 2. a junction or symbolic link on an INTERMEDIATE directory leads out of the repository
    local outside = vim.fs.normalize(vim.fn.tempname()) .. "-outside"
    S.write(outside .. "/BINDINGS.md", "| `gl` | :Evil |\n")
    local linked = S.new_repo()
    vim.fn.delete(linked .. "/docs", "rf")
    local made = vim.uv.fs_symlink(outside, linked .. "/docs", { dir = true, junction = true })
    ok(made, "the test could make a link (a junction on Windows)")
    local fs = fsx.new(linked)
    ok(fs:read("docs/BINDINGS.md") == nil, "a file below a link to the outside is not read")
    ok(not fs:exists("docs/BINDINGS.md"), "and does not exist for the checks")
    ok(not fs:is_dir("docs"), "the linked directory itself is absent")
    -- an ordinary directory and an ordinary link INSIDE the repository still work
    local plain = fsx.new(S.new_repo())
    ok(plain:is_dir("lua"), "an ordinary directory is there")
    vim.fn.delete(outside, "rf")

    -- ===================================================================
    -- 2b. false positives of K1 found on the fleet: a telescope extension, a negative test, a dependency's command
    local fp = S.new_repo()
    S.write(
      fp .. "/lua/telescope/_extensions/goodp.lua",
      'local pickers = require("telescope.pickers")\nreturn pickers\n'
    )
    S.write(
      fp .. "/TESTS/neg_spec.lua",
      'local lib = require("lib")\nlocal m = lib.try_require("goodp.no.such.module")\nlocal n = require("goodp.also.missing")\nreturn function(H) H.ok(not m and n, "neg") end\n'
    )
    local rfp = conformance.run(fp, { only = { "K1" }, probe = probe, settings = {} })
    local k1 = S.check(rfp, "K1")
    for _, f in ipairs(k1.findings) do
      ok(
        not f.message:find("telescope", 1, true),
        "a telescope extension is not a missing module: " .. f.message
      )
      ok(not f.message:find("goodp.no.such", 1, true), "try_require is not require: " .. f.message)
      ok(
        f.level ~= "error" or f.file ~= "TESTS/neg_spec.lua",
        "a spec's own negative test is not an error"
      )
    end
    local seen_neg = false
    for _, f in ipairs(k1.findings) do
      if f.message:find("goodp.also.missing", 1, true) then
        seen_neg = true
        ok(f.level == "warn", "a require of a missing module in a spec is a warning")
      end
    end
    ok(seen_neg, "but it is still named: " .. S.messages(rfp, "K1"))
    ok(
      require("testing.conformance.util").required_names('x = require   ("a.b") -- require("c.d")')[1]
        == "a.b",
      "the scanner reads a spaced call"
    )
    ok(
      #require("testing.conformance.util").required_names('lib.try_require("a.b")') == 0,
      "not try_require"
    )
    ok(
      #require("testing.conformance.util").required_names('require("a.b." .. x)') == 0,
      "not a prefix"
    )

    -- a command that a dependency registers while a module loads is not the module's side effect
    S.write(
      fp .. "/lua/goodp/uses.lua",
      'vim.api.nvim_create_user_command("OwnCmd", function() end, {})\nreturn {}\n'
    )
    local function require_probe(effects)
      return function(name)
        if name == "require" then
          return { results = { { module = "goodp.uses", ok = true, effects = effects } } }
        end
        return nil, "no child editor in this spec"
      end
    end
    local dep = conformance.run(fp, {
      only = { "K1" },
      settings = {},
      probe = require_probe({
        globals = {},
        keymaps = 0,
        commands = { "KitPreview" },
        autocmds = 1,
        autocmd_groups = { lib_kit_toast_resize = 1 },
      }),
    })
    local has_effect = false
    for _, f in ipairs(S.check(dep, "K1").findings) do
      if f.message:find("side effect", 1, true) then
        has_effect = true
      end
    end
    ok(
      not has_effect,
      "a dependency's command and autocmd group are not counted: " .. S.messages(dep, "K1")
    )
    local own_run = conformance.run(fp, {
      only = { "K1" },
      settings = {},
      probe = require_probe({
        globals = {},
        keymaps = 0,
        commands = { "OwnCmd" },
        autocmds = 0,
        autocmd_groups = {},
      }),
    })
    has_effect = false
    for _, f in ipairs(S.check(own_run, "K1").findings) do
      if f.message:find("OwnCmd", 1, true) then
        has_effect = true
      end
    end
    ok(has_effect, "the plugin's own command still is: " .. S.messages(own_run, "K1"))

    -- ===================================================================
    -- 2c. K14 compared substrings: `gl` was "documented" by the word "global", `:Foo` by `:FooBar`
    local k14 = require("testing.conformance.checks.k14_docs")
    ok(k14.norm_key("<C-Bslash><C-A>") == k14.norm_key("<C-\\><C-a>"), "<Bslash> is the backslash")
    ok(k14.norm_key("<A-x>") == "<m-x>", "<A- is <M-")
    local docs_repo = S.new_repo()
    S.write(docs_repo .. "/lua/goodp/foo_cmd.lua", 'return { command = "Foo" }\n')
    local function k14_run(doc_text)
      S.write(docs_repo .. "/docs/BINDINGS.md", doc_text)
      local facts = {
        leader = " ",
        commands = { { name = "Foo" } },
        keymaps = {
          { lhs = "gl", mode = "n" },
          { lhs = "K", mode = "n" },
          { lhs = "<C-\\><C-A>", mode = "i" },
        },
        autocmds = {},
      }
      facts.keymaps[3].lhs = "<C-Bslash><C-A>"
      local probe14 = function(name)
        if name == "main" then
          return { load = { ok = true }, facts1 = facts, guard = { effects = {}, findings = {} } }
        end
        return { results = {} }
      end
      return conformance.run(docs_repo, { only = { "K14" }, settings = {}, probe = probe14 })
    end
    local prose =
      "# Bindings\n\nThe global lookup and the Kind of thing is in :FooBar and the g l word.\n"
    local r14 = k14_run(prose)
    local msgs = S.messages(r14, "K14")
    ok(
      msgs:find("keymap", 1, true) ~= nil,
      "prose that merely contains the letters documents nothing: " .. msgs
    )
    ok(msgs:find(":Foo", 1, true) ~= nil, ":FooBar does not document :Foo: " .. msgs)
    local good14 =
      "# Bindings\n\n| Key | Does |\n|---|---|\n| `gl` | lookup |\n| `K` | hover |\n| `<C-\\><C-a>` | x |\n\n`:Foo` runs it.\n"
    r14 = k14_run(good14)
    ok(
      S.check(r14, "K14").status == "pass",
      "a table of keys documents them (also <Bslash>): " .. S.messages(r14, "K14")
    )

    -- ===================================================================
    -- 2d. the Markdown report is a document that GitHub renders: text of the repository is data in it
    local render = require("testing.conformance.render")
    local md_repo = S.new_repo("x[click](http-evil).nvim")
    local md_report = conformance.run(md_repo, { only = { "K15" }, probe = probe, settings = {} })
    md_report.checks[1].findings = {
      {
        check = "K15",
        rule = "NEW-1",
        level = "warn",
        file = "a`b.lua",
        line = 3,
        message = "[click](http://evil.example/) ![i](http://evil.example/x.png) <b>x</b> | cell",
      },
    }
    local md_text = render.markdown(md_report)
    ok(not md_text:find("](http://evil", 1, true), "no live link in the Markdown")
    ok(not md_text:find("<b>", 1, true), "no HTML tag in the Markdown")
    ok(not md_text:find("![i]", 1, true), "no image in the Markdown")
    ok(md_text:find("\\[click\\]", 1, true) ~= nil, "the text is there, escaped")
    ok(md_text:find("``", 1, true) ~= nil, "a file name with a backtick gets a longer fence")
    local title = md_text:match("^# Conformance: ([^\n]*)")
    ok(
      title ~= nil and not title:find("[click]", 1, true),
      "the directory name in the title is escaped: " .. tostring(title)
    )

    -- ===================================================================
    -- 2e. K6: an error about a dependency that is not installed on THIS machine is the environment's
    local function k6_run(missing)
      local probe6 = function(name, ctx)
        ctx.missing_deps = missing
        if name == "main" then
          return {
            load = { ok = true },
            health = {
              ok = true,
              lines = {
                'goodp: require("goodp.health").check()',
                "- ERROR: picker = telescope but telescope.nvim is not installed",
              },
            },
          }
        end
        return { results = {} }
      end
      return conformance.run(S.new_repo(), { only = { "K6" }, settings = {}, probe = probe6 })
    end
    local k6_here = S.check(k6_run({ "telescope.nvim" }), "K6")
    ok(
      k6_here.status == "warn",
      "a missing dependency limits the error to a warning: " .. k6_here.status
    )
    local k6_msg = k6_here.findings[1] and k6_here.findings[1].message or ""
    ok(k6_msg:find("not installed here", 1, true) ~= nil, "and says why: " .. k6_msg)
    ok(S.check(k6_run({}), "K6").status == "fail", "without a missing dependency it is an error")

    -- ===================================================================
    -- 2f. K3: a switch that the plugin never had is not the plugin's REL-20 violation
    local k3_repo = S.new_repo()
    local function k3_run(settings)
      local k3_probe = function(name)
        if name == "main" then
          return { load = { ok = true }, facts1 = { keymaps = { { lhs = "gx", mode = "n" } } } }
        end
        if name == "keymaps_off" then
          return {
            opts = {},
            setup = { ok = true },
            facts = { keymaps = { { lhs = "gx", mode = "n" } }, leader = " " },
          }
        end
        return { results = {} }
      end
      return conformance.run(k3_repo, { only = { "K3" }, settings = settings, probe = k3_probe })
    end
    S.patch(
      k3_repo,
      ".testing.lua",
      "conformance = { load_budget_ms = 5000 }",
      "conformance = { load_budget_ms = 5000, keymaps_off = { zzzswitch = false } }"
    )
    local k3_none = S.check(k3_run({}), "K3")
    ok(k3_none.status == "n/a", "an option nobody names is not checked: " .. k3_none.status)
    ok(
      (k3_none.reason or ""):find("conformance.keymaps_off", 1, true) ~= nil,
      "and the reason names the way out"
    )
    S.write(k3_repo .. "/lua/goodp/switch.lua", "return { keymaps = true }\n")
    S.patch(k3_repo, ".testing.lua", "zzzswitch = false", "keymaps = false")
    local k3_real = S.check(k3_run({}), "K3")
    ok(k3_real.status == "fail", "a plugin that names the option is checked: " .. k3_real.status)
    ok(
      (k3_real.findings[1] and k3_real.findings[1].message or ""):find(
        "conformance.keymaps_off",
        1,
        true
      ) ~= nil,
      "the first finding names the way out"
    )

    -- ===================================================================
    -- 2g. K15 false positives of the fleet measurement
    local function k15_findings(repo_path, rule)
      local r = conformance.run(repo_path, { only = { "K15" }, probe = probe, settings = {} })
      local out = {}
      for _, f in ipairs(S.check(r, "K15").findings) do
        if f.rule == rule then
          out[#out + 1] = f
        end
      end
      return out
    end
    local hy = S.new_repo()
    -- REL-35: a feature that is about `wkdbook-x/...` paths names such a directory as an example
    S.write(
      hy .. "/lua/goodp/example.lua",
      '-- e.g. "wkdbook-x/proj/README.md" is resolved below the repos dir\nreturn {}\n'
    )
    ok(#k15_findings(hy, "REL-35") == 0, "the word alone is not a reference to the vault")
    S.write(hy .. "/lua/goodp/vault.lua", "-- see WKDBooks/Development/notes.md\nreturn {}\n")
    local vault_hits = k15_findings(hy, "REL-35")
    ok(
      #vault_hits == 1 and vault_hits[1].message:find("WKDBooks/Development", 1, true),
      "a vault path is"
    )
    -- XP-01: completion globs what the user typed
    S.write(
      hy .. "/lua/goodp/complete.lua",
      'return function(arg_lead) return vim.fn.glob(arg_lead .. "*", false, true) end\n'
    )
    ok(#k15_findings(hy, "XP-01") == 0, "completion of an argument is a glob on purpose")
    S.write(
      hy .. "/lua/goodp/glob.lua",
      'return function(dir) return vim.fn.glob(dir .. "/*.md") end\n'
    )
    ok(#k15_findings(hy, "XP-01") == 1, "a glob on a concatenated path still is one")
    -- LUA-82: a hand-written validator is a validator
    S.write(
      hy .. "/lua/goodp/config/check.lua",
      "local function check(o)\n"
        .. "  if type(o.a) ~= 'string' then return false end\n"
        .. "  if type(o.b) ~= 'number' then return false end\n"
        .. "  if type(o.c) ~= 'table' then return false end\n"
        .. "  if type(o.d) ~= 'boolean' then return false end\n"
        .. "  if type(o.e) ~= 'string' then return false end\n"
        .. "  return true\nend\nreturn check\n"
    )
    local lua82 = k15_findings(hy, "LUA-82")
    for _, f in ipairs(lua82) do
      ok(
        not f.message:find("validates the options", 1, true),
        "five type checks are a validator: " .. f.message
      )
    end

    -- ===================================================================
    -- 2h. the command line: it says what it runs, and an output path that leads back INTO the repository is refused
    local cli_repo = S.new_repo()
    local errs = {}
    local function cli_run(argv)
      errs = {}
      return conformance.main(argv, {
        out = function() end,
        err = function(line)
          errs[#errs + 1] = line
        end,
        run = function()
          return conformance.run(cli_repo, { only = { "K15" }, probe = probe, settings = {} })
        end,
      })
    end
    local plain_code = cli_run({ cli_repo, "--json" })
    ok(plain_code == 0, "a report-only run exits 0")
    ok(
      table.concat(errs, "\n"):find("runs the repository's own code", 1, true) ~= nil,
      "the run says that it executes the repository's code: " .. table.concat(errs, "\n")
    )
    local away = vim.fs.normalize(vim.fn.tempname()) .. "-away"
    vim.fn.mkdir(away, "p")
    local back = vim.uv.fs_symlink(cli_repo, away .. "/back", { dir = true, junction = true })
    ok(back, "the test could make a link back into the repository")
    local refused = cli_run({ cli_repo, "--json-file", away .. "/back/report.json" })
    ok(
      refused == 2,
      "a report path that leads into the repository is refused (exit " .. refused .. ")"
    )
    ok(vim.uv.fs_stat(cli_repo .. "/report.json") == nil, "and nothing was written there")
    vim.fn.delete(away, "rf")

    -- ===================================================================
    -- 3. "nothing was observed" is not "nothing happened": K8 and K9 need the guards to have run
    local function main_probe(guard)
      return function(name)
        if name == "main" then
          return { load = { ok = true }, guard = guard }
        end
        return { results = {} }
      end
    end
    local function status(report3, id)
      return S.check(report3, id).status
    end
    local none = { findings = {}, effects = { spawned = {}, network = {}, fs_outside_tmp = {} } }
    local repo3 = S.new_repo()
    local blind = conformance.run(repo3, {
      only = { "K8", "K9" },
      settings = {},
      probe = main_probe(vim.tbl_extend("force", none, { available = false, err = "boom" })),
    })
    ok(status(blind, "K8") == "n/a", "K8 without guards is not a pass: " .. status(blind, "K8"))
    ok(status(blind, "K9") == "n/a", "K9 without guards is not a pass: " .. status(blind, "K9"))
    ok(S.check(blind, "K9").blocked ~= nil or S.messages(blind, "K9") ~= nil, "and it says why")
    local seen = conformance.run(repo3, {
      only = { "K8", "K9" },
      settings = {},
      probe = main_probe(vim.tbl_extend("force", none, { available = true })),
    })
    ok(status(seen, "K8") == "pass", "K8 with guards that saw nothing passes")
    ok(status(seen, "K9") == "pass", "K9 with guards that saw nothing passes")
    local effect = vim.deepcopy(none)
    effect.available = true
    effect.effects.spawned = { "git status" }
    local saw =
      conformance.run(repo3, { only = { "K9" }, settings = {}, probe = main_probe(effect) })
    ok(status(saw, "K9") == "fail", "K9 with a recorded process fails: " .. status(saw, "K9"))
  end)
end
