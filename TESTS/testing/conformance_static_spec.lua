-- TESTS/testing/conformance_static_spec.lua -- the static checks of the conformance suite (K1 static half,
-- K7, K15 and its rules): every rule holds on the conformant fixture plugin and fails on a copy that
-- violates exactly that rule. No child editor is started here (the runtime half has its own spec).

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")

  ---A probe that never starts an editor: K1's runtime half sees an empty module list.
  local function probe(name)
    if name == "require" then
      return { results = {} }
    end
    return nil, "no child editor in this spec"
  end

  local function run(root, only, extra)
    return conformance.run(
      root,
      vim.tbl_extend("force", { only = only, probe = probe, settings = {} }, extra or {})
    )
  end

  ---Is there a finding of `rule` containing `needle`?
  local function has_finding(report, check, rule, needle)
    for _, f in ipairs(S.check(report, check).findings) do
      if f.rule == rule and f.message:find(needle, 1, true) then
        return f
      end
    end
    return nil
  end

  local function expect(report, check, rule, needle, msg)
    local f = has_finding(report, check, rule, needle)
    ok(
      f ~= nil,
      ("%s: no %s finding with %q (%s)"):format(msg, rule, needle, S.messages(report, check))
    )
    return f
  end

  S.run(function()
    -- ===================================================================
    -- 1. the conformant fixture: nothing to report
    local good = S.new_repo()
    local report = run(good, { "K1", "K7", "K15" })
    for _, id in ipairs({ "K1", "K7", "K15" }) do
      local r = S.check(report, id)
      ok(r.status == "pass", "the conformant fixture passes " .. S.messages(report, id))
    end
    local k15 = S.check(report, "K15")
    ok(next(k15.rule_status) ~= nil, "K15 carries one verdict per rule")
    for id, st in pairs(k15.rule_status) do
      ok(
        st.status == "pass",
        ("rule %s passes on the conformant fixture (is %s)"):format(id, st.status)
      )
    end
    ok(
      k15.rule_status["NEW-36"] ~= nil and k15.rule_status["NEW-48"] ~= nil,
      "named rules are there"
    )
    ok(#report.manual > 40, "the manual rules are listed in the report")
    for _, m in ipairs(report.manual) do
      ok(m.status == "manual" and m.reason ~= "", "a manual rule says why: " .. m.id)
    end

    -- ===================================================================
    -- 2. K15 rules: one mutation each. `rule`, the text the finding must carry, and the level the
    --    check's status shows (critical rule = error = `fail`, recommended = warn).
    local cases = {
      {
        name = ".luarc.json missing",
        mutate = function(r)
          S.remove(r, ".luarc.json")
        end,
        rule = "NEW-03",
        needle = ".luarc.json is missing",
        status = "warn",
      },
      {
        name = "workspace.library (flat key)",
        mutate = function(r)
          S.write(r .. "/.luarc.json", '{\n  "workspace.library": ["x"]\n}\n')
        end,
        rule = "NEW-36",
        needle = "workspace.library",
        status = "warn",
      },
      {
        name = "workspace.library (nested object)",
        mutate = function(r)
          S.write(r .. "/.luarc.json", '{ "workspace": { "library": ["x"] } }')
        end,
        rule = "NEW-36",
        needle = "workspace.library",
        status = "warn",
      },
      {
        name = ".claude exists and is not in ignoreDir",
        mutate = function(r)
          vim.fn.mkdir(r .. "/.claude", "p")
          S.write(r .. "/.luarc.json", '{ "workspace.ignoreDir": [".deps"] }')
        end,
        rule = "NEW-37",
        needle = ".claude/",
        status = "warn",
      },
      {
        name = "vim in diagnostics.globals",
        mutate = function(r)
          S.write(r .. "/.luarc.json", '{\n  "diagnostics.globals": ["vim"]\n}\n')
        end,
        rule = "NEW-38",
        needle = "lists vim",
        status = "warn",
      },
      {
        name = ".luarc.json with a trailing comma",
        mutate = function(r)
          S.write(r .. "/.luarc.json", '{\n  "a": 1,\n}\n')
        end,
        rule = "NEW-50",
        needle = "not strict JSON",
        status = "warn",
      },
      {
        name = "no stylua.toml",
        mutate = function(r)
          S.remove(r, "stylua.toml")
        end,
        rule = "NEW-45",
        needle = "no stylua.toml",
        status = "warn",
      },
      {
        name = "stylua line_endings does not match .gitattributes",
        mutate = function(r)
          S.write(r .. "/stylua.toml", 'column_width = 100\nline_endings = "Windows"\n')
        end,
        rule = "NEW-45",
        needle = 'line_endings is "Windows", .gitattributes sets eol=lf',
        status = "warn",
      },
      {
        name = "stylua without line_endings while .gitattributes sets eol=lf",
        mutate = function(r)
          S.write(r .. "/stylua.toml", "column_width = 100\n")
        end,
        rule = "NEW-45",
        needle = "line_endings is not set",
        status = "warn",
      },
      {
        name = "busted syntax in TESTS/ without a busted std",
        mutate = function(r)
          S.write(
            r .. "/TESTS/a_spec.lua",
            'describe("x", function()\n  it("y", function() end)\nend)\n'
          )
        end,
        rule = "NEW-49",
        needle = "no busted std declared",
        status = "warn",
      },
      {
        name = "TESTS/ missing",
        mutate = function(r)
          S.remove(r, "TESTS")
        end,
        rule = "NEW-39",
        needle = "no TESTS/ directory",
        status = "fail",
      },
      {
        name = "scripts/test.sh missing",
        mutate = function(r)
          S.remove(r, "scripts/test.sh")
        end,
        rule = "NEW-39",
        needle = "scripts/test.sh",
        status = "fail",
      },
      {
        name = "a spec under lua/",
        mutate = function(r)
          S.write(
            r .. "/lua/goodp/x_spec.lua",
            'describe("x", function()\n  it("y", function() end)\nend)\n'
          )
        end,
        rule = "NEW-48",
        needle = "ships with the runtime tree",
        status = "fail",
      },
      {
        name = "test/ with Lua files (tests/ is TESTS/ on a case-insensitive file system)",
        mutate = function(r)
          S.write(r .. "/test/a.lua", "return {}\n")
        end,
        rule = "NEW-48",
        needle = "test/ holds Lua files",
        status = "fail",
      },
      {
        name = "LICENSE missing",
        mutate = function(r)
          S.remove(r, "LICENSE")
        end,
        rule = "NEW-06",
        needle = "no LICENSE",
        status = "fail",
      },
      {
        name = "LICENSE is not MIT",
        mutate = function(r)
          S.write(r .. "/LICENSE", "All rights reserved.\n")
        end,
        rule = "REL-28",
        needle = "does not look like the MIT license",
        status = "warn",
      },
      {
        name = "README without a License section",
        mutate = function(r)
          S.patch(r, "README.md", "## License", "## Terms")
        end,
        rule = "REL-28",
        needle = "no License section",
        status = "warn",
      },
      {
        name = "README missing",
        mutate = function(r)
          S.remove(r, "README.md")
        end,
        rule = "NEW-11",
        needle = "no README.md",
        status = "fail",
      },
      {
        name = "README without an installation section",
        mutate = function(r)
          S.patch(r, "README.md", "## Installation", "## Usage")
        end,
        rule = "REL-10",
        needle = "no installation section",
        status = "warn",
      },
      {
        name = "doc/*.txt missing",
        mutate = function(r)
          S.remove(r, "doc")
        end,
        rule = "NEW-13",
        needle = "no doc/*.txt",
        status = "fail",
      },
      {
        name = "docs/BINDINGS.md missing",
        mutate = function(r)
          S.remove(r, "docs/BINDINGS.md")
        end,
        rule = "NEW-15",
        needle = "no docs/BINDINGS.md",
        status = "fail",
      },
      {
        name = "docs/ROADMAP.md exists",
        mutate = function(r)
          S.write(r .. "/docs/ROADMAP.md", "# Roadmap\n")
        end,
        rule = "NEW-14",
        needle = "docs/ROADMAP.md must not exist",
        status = "fail",
      },
      {
        name = "config/DEFAULTS.lua missing",
        mutate = function(r)
          S.remove(r, "lua/goodp/config/DEFAULTS.lua")
        end,
        rule = "NEW-07",
        needle = "DEFAULTS.lua",
        status = "warn",
      },
      {
        name = "config/init.lua missing",
        mutate = function(r)
          S.remove(r, "lua/goodp/config/init.lua")
        end,
        rule = "NEW-27",
        needle = "config/init.lua",
        status = "warn",
      },
      {
        name = "bindings/autocmds missing",
        mutate = function(r)
          S.remove(r, "lua/goodp/bindings/autocmds.lua")
        end,
        rule = "NEW-08",
        needle = "lacks: autocmds",
        status = "warn",
      },
      {
        name = "health.lua missing",
        mutate = function(r)
          S.remove(r, "lua/goodp/health.lua")
        end,
        rule = "NEW-10",
        needle = "health.lua",
        status = "fail",
      },
      {
        name = "a vault reference in the README",
        mutate = function(r)
          S.write(r .. "/README.md", "# goodp\n\n## License\n\nSee WKDBooks/Development/x.md\n")
        end,
        rule = "REL-35",
        needle = "refers to the author's vault",
        status = "warn",
      },
      {
        name = "dir = vim.env in the README",
        mutate = function(r)
          S.patch(r, "README.md", "opts = {},", "opts = {},\n  dir = vim.env.PLUGIN_DIR,")
        end,
        rule = "REL-13",
        needle = "local development spec",
        status = "warn",
      },
      {
        name = "the README spec has no lazy trigger",
        mutate = function(r)
          S.patch(r, "README.md", '  cmd = "Goodp",\n', "")
        end,
        rule = "LUA-93",
        needle = "names no trigger",
        status = "warn",
      },
      {
        name = "lazy = false together with cmd",
        mutate = function(r)
          S.patch(r, "README.md", '  cmd = "Goodp",', '  cmd = "Goodp",\n  lazy = false,')
        end,
        rule = "LUA-93",
        needle = "contradiction",
        status = "warn",
      },
      {
        name = "config that is neither validated nor typed",
        mutate = function(r)
          S.write(r .. "/lua/goodp/config/init.lua", "return {}\n")
          S.remove(r, "lua/goodp/config/@types")
        end,
        rule = "LUA-82",
        needle = "validates the options",
        status = "warn",
      },
      {
        name = "an os.tmpname() call",
        mutate = function(r)
          S.write(r .. "/lua/goodp/tmp.lua", "local M = {}\nM.path = os.tmpname()\nreturn M\n")
        end,
        rule = "SEC-47",
        needle = "vim.fn.tempname()",
        status = "warn",
      },
      {
        name = "glob on a concatenated path",
        mutate = function(r)
          S.write(r .. "/lua/goodp/g.lua", 'return vim.fn.glob(root .. "/*.lua")\n')
        end,
        rule = "XP-01",
        needle = "reads its argument as a pattern",
        status = "warn",
      },
      {
        name = "an open CDX tag",
        mutate = function(r)
          S.write(r .. "/lua/goodp/c.lua", "--- CDX: decide this\nreturn {}\n")
        end,
        rule = "CMT-15",
        needle = "open CDX tag",
        status = "pass", -- info only: the tag is listed, never judged
      },
    }
    for _, case in ipairs(cases) do
      local repo = S.new_repo()
      case.mutate(repo)
      local rep = run(repo, { "K15" })
      local f = expect(rep, "K15", case.rule, case.needle, case.name)
      ok(f ~= nil and not f.waived, case.name .. ": the finding is open")
      ok(
        S.check(rep, "K15").status == case.status,
        ("%s: K15 status %s, expected %s (%s)"):format(
          case.name,
          S.check(rep, "K15").status,
          case.status,
          S.messages(rep, "K15")
        )
      )
      local verdict = S.check(rep, "K15").rule_status[case.rule]
      ok(
        verdict and verdict.status ~= "pass" or case.status == "pass",
        case.name .. ": the rule's own verdict"
      )
    end

    -- the exemptions the fleet runs of rules.nvim taught: no false positive for them
    local exempt = S.new_repo()
    S.write(exempt .. "/.luarc.json", '{ "workspace.ignoreDir": ["**/.claude", "./.deps/"] }')
    vim.fn.mkdir(exempt .. "/.claude", "p")
    vim.fn.mkdir(exempt .. "/.deps", "p")
    S.write(exempt .. "/stylua.toml", "column_width = 100\n")
    S.remove(exempt, "stylua.toml")
    S.write(exempt .. "/.stylua.toml", 'line_endings = "Unix"\n')
    -- a lazy.nvim plugin spec and a generator's template share the name `*_spec.lua` with real tests
    S.write(exempt .. "/lua/goodp/plugin_spec.lua", 'return { "StefanBartl/goodp.nvim" }\n')
    S.write(exempt .. "/lua/goodp/tmpl_spec.lua", 'describe("${name}", function() end)\n')
    S.write(
      exempt .. "/TESTS/a_spec.lua",
      'describe("x", function()\n  it("y", function() end)\nend)\n'
    )
    S.write(exempt .. "/.luacheckrc", 'std = "luajit"\nexclude_files = { "TESTS/**" }\n')
    S.write(exempt .. "/lua/goodp/dyn.lua", 'return require("goodp.x." .. "y")\n')
    local rep = run(exempt, { "K1", "K15" })
    ok(S.check(rep, "K15").status == "pass", "exemptions hold " .. S.messages(rep, "K15"))
    ok(
      S.check(rep, "K1").status == "pass",
      "a dynamic require prefix is not a module " .. S.messages(rep, "K1")
    )
    S.write(exempt .. "/.luacheckrc", 'std = "luajit+busted"\n')
    ok(S.check(run(exempt, { "K15" }), "K15").status == "pass", "a busted std is accepted")

    -- ===================================================================
    -- 3. K1 static half: case and in-tree resolution (XP-06)
    local k1 = S.new_repo()
    S.write(k1 .. "/lua/goodp/Foo.lua", "return {}\n")
    S.write(k1 .. "/lua/goodp/Sub/Deep.lua", "return {}\n")
    S.write(
      k1 .. "/lua/goodp/uses.lua",
      table.concat({
        'local a = require("goodp.foo")',
        'local b = require("goodp.sub.deep")',
        'local c = require("goodp.nope")',
        '-- local d = require("goodp.commented")',
        'local e = require("goodp.Foo")',
        'local f = require "goodp.Sub.Deep"',
        'local g = require("goodp.config")',
        "return {}",
        "",
      }, "\n")
    )
    rep = run(k1, { "K1" })
    local case_hit = expect(
      rep,
      "K1",
      "XP-06",
      'require("goodp.foo") does not match the directory spelling `goodp.Foo`',
      "case"
    )
    ok(
      case_hit.file == "lua/goodp/uses.lua" and case_hit.line == 1,
      "the finding names file and line"
    )
    expect(rep, "K1", "XP-06", "`goodp.Sub.Deep`", "case in a directory name")
    expect(
      rep,
      "K1",
      "NEW-47",
      'require("goodp.nope") resolves to no file',
      "an in-tree module that does not exist"
    )
    ok(not has_finding(rep, "K1", "NEW-47", "commented"), "a commented require is ignored")
    ok(not has_finding(rep, "K1", "XP-06", 'require("goodp.Foo")'), "the exact spelling is fine")
    ok(
      not has_finding(rep, "K1", "XP-06", 'require("goodp.config")'),
      "a directory with init.lua resolves"
    )
    ok(S.check(rep, "K1").status == "fail", "K1 fails")

    -- ===================================================================
    -- 4. K7: soft dependencies and health.lua
    local k7 = S.new_repo()
    S.write(
      k7 .. "/lua/goodp/soft.lua",
      'local ok = pcall(require, "undeclared-dep.sub")\nreturn ok\n'
    )
    rep = run(k7, { "K7" })
    local k7f =
      expect(rep, "K7", "REL-17", '"undeclared-dep"', "a soft dependency without a health check")
    ok(k7f.file == "lua/goodp/soft.lua" and k7f.line == 1, "K7 names file and line")
    ok(S.check(rep, "K7").status == "warn", "K7 is a warning")
    S.patch(
      k7,
      "lua/goodp/health.lua",
      'vim.health.ok("goodp is loaded")',
      'vim.health.ok("goodp is loaded (undeclared-dep)")'
    )
    ok(S.check(run(k7, { "K7" }), "K7").status == "pass", "a mention in health.lua is a check")
    -- a mention in a module health.lua requires counts
    local k7b = S.new_repo()
    S.write(k7b .. "/lua/goodp/soft.lua", 'local ok = pcall(require, "other-dep")\nreturn ok\n')
    S.write(k7b .. "/lua/goodp/deps.lua", '-- checks other-dep\nreturn { "other-dep" }\n')
    S.patch(
      k7b,
      "lua/goodp/health.lua",
      "local M = {}",
      'local M = {}\nlocal deps = require("goodp.deps")'
    )
    ok(S.check(run(k7b, { "K7" }), "K7").status == "pass", "a module required by health.lua counts")
    local k7c = S.new_repo()
    S.remove(k7c, "lua/goodp/health.lua")
    rep = run(k7c, { "K7" })
    ok(S.check(rep, "K7").status == "n/a", "without health.lua K7 does not apply (NEW-10 is K15's)")
    local k7d = S.new_repo()
    S.remove(k7d, "lua/goodp/util.lua")
    S.patch(k7d, "lua/goodp/health.lua", 'if pcall(require, "which-key") then', "if false then")
    S.patch(
      k7d,
      "lua/goodp/health.lua",
      'if pcall(require, "lib.nvim.bindings.keymap") then',
      "if true then"
    )
    rep = run(k7d, { "K7" })
    ok(S.check(rep, "K7").status == "pass", "no soft dependency: pass " .. S.messages(rep, "K7"))

    -- ===================================================================
    -- 5. hostile file names and contents: the suite never raises and prints nothing raw
    local hostile = S.new_repo()
    local names = { "we ird [1] 'q' $x %s", "\xc3\xbc", "100%", "a.b c" }
    if vim.fn.has("win32") ~= 1 then
      names[#names + 1] = "esc\27[31mred"
      names[#names + 1] = "new\nline"
    end
    local created = 0
    for _, name in ipairs(names) do
      local f = io.open(hostile .. "/lua/goodp/" .. name .. ".lua", "wb")
      if f then
        f:write("--- CDX: look at this\nreturn {}\n")
        f:close()
        created = created + 1
      end
    end
    ok(created >= 4, "the hostile names exist on this platform (" .. created .. ")")
    S.write(
      hostile .. "/README.md",
      '# goodp\n\n## Installation\n\n```lua\n{ "StefanBartl/goodp.nvim", cmd = "Goodp" }\n```\n\n'
        .. "## License\n\nWKDBooks/Development \27]0;pwned\7 \27[31mred\27[0m \226\128\174bidi \255\254 end\n"
    )
    rep = run(hostile, { "K1", "K7", "K15" })
    ok(rep.verdict ~= nil, "the report is complete")
    local text = table.concat(conformance.terminal(rep, { verbose = true, manual = true }), "\n")
    ok(not text:find("[%z\1-\8\11-\31\127]"), "the terminal text holds no control character")
    ok(not text:find("\226\128\174", 1, true), "no bidi override reaches the terminal")
    local md = conformance.markdown(rep)
    ok(not md:find("\27", 1, true), "no ESC in the Markdown")
    local json = assert(conformance.json(rep))
    local decoded = vim.json.decode(json)
    ok(decoded.schema_version == 1, "the JSON decodes")
    local cdx = 0
    for _, f in ipairs(S.check(rep, "K15").findings) do
      if f.rule == "CMT-15" then
        cdx = cdx + 1
      end
    end
    ok(cdx >= 4, "the tags of the oddly named files are listed (" .. cdx .. ")")
    local vault = has_finding(rep, "K15", "REL-35", "refers to the author's vault")
    ok(
      vault ~= nil and vault.file == "README.md" and vault.line == 11,
      "the vault line is found with its line number"
    )
    ok(not vault.message:find("\27", 1, true), "its message is clean")
  end)
end
