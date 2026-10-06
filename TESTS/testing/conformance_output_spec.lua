-- TESTS/testing/conformance_output_spec.lua -- what comes out of the suite and what goes in: the four
-- renderings of a report, `main` with its flags and exit codes, the read-only file access (`fsx`), the
-- rules.nvim bridge. No child editor: the runtime sessions are replaced by a fake `probe`.

---@diagnostic disable: need-check-nil, missing-fields -- the case body is the guard: a nil raises and fails the case; hand-built reports are partial on purpose
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
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 500))
    )
  end

  local function probe(name)
    if name == "require" then
      return { results = {} }
    end
    return nil, "no child editor in this spec"
  end

  ---Run `main` with a fake `run` (static checks only) and capture what it printed.
  local function main(argv, over)
    local out, err = {}, {}
    local services = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      run = function(root, opts)
        opts = vim.tbl_extend("force", opts or {}, { probe = probe })
        if not opts.only or #opts.only == 0 then
          opts.only = { "K7", "K15" }
        end
        return conformance.run(root, opts)
      end,
    }
    for k, v in pairs(over or {}) do
      services[k] = v
    end
    local code = conformance.main(argv, services)
    return code, table.concat(out, "\n"), table.concat(err, "\n")
  end

  S.run(function()
    local flawed = S.new_repo()
    S.remove(flawed, "LICENSE") -- NEW-06: a critical rule, an error
    S.remove(flawed, "stylua.toml") -- NEW-45: a warning
    local clean = S.new_repo()

    -- ===================================================================
    -- 1. the renderings
    local report = conformance.run(flawed, { probe = probe, only = { "K7", "K15" } })
    local lines = conformance.terminal(report)
    eq(
      lines[1],
      "conformance: goodp.nvim (plugin goodp)  [report]",
      "the header names the repository and the mode"
    )
    local text = table.concat(lines, "\n")
    has(text, "ok     K7", "a passing check")
    has(text, "FAIL   K15", "a failing check")
    has(text, "no LICENSE file  [NEW-06]", "a finding with its rule")
    has(text, "LICENSE  no LICENSE file", "and its file")
    ok(text:find("warn  .-no stylua.toml") ~= nil, "a warning is marked as one")
    has(
      text,
      "summary: 2 check(s): 1 ok, 1 fail, 0 warn, 0 n/a, 0 error; 1 error / 1 warn / 0 info finding(s), 0 waived; ",
      "the summary line"
    )
    has(text, "verdict fail", "and the verdict")
    ok(not text:find("manual rules", 1, true), "the manual rules are listed only on request")
    has(
      table.concat(conformance.terminal(report, { manual = true }), "\n"),
      "manual rules (",
      "the manual list on request"
    )

    local md = conformance.markdown(report)
    has(md, "# Conformance: goodp.nvim", "Markdown title")
    has(md, "| K15 | fail |", "a row per check")
    has(md, "## K15:", "a section per check with findings")
    has(md, "## Manual rules", "the manual rules")
    has(md, "| NEW-09 | recommended | NEW_PROJECT |", "a manual rule row")
    local escaped = conformance.markdown({
      name = "x|y",
      mode = "report",
      verdict = "pass",
      checks = {
        { id = "K1", status = "pass", title = "a|b", rules = {}, findings = {}, notes = {} },
      },
      manual = {},
      problems = {},
    })
    has(escaped, "a\\|b", "a pipe in a cell is escaped")

    local json = assert(conformance.json(report))
    ok(json:sub(-1) == "\n", "JSON ends with a newline")
    local decoded = vim.json.decode(json)
    eq(decoded.checks[2].id, "K15", "JSON: the checks in order")
    eq(decoded.checks[2].findings[1].rule, "NEW-06", "JSON: findings with rules")
    eq(decoded.checks[2].rule_status["NEW-06"].status, "fail", "JSON: the per-rule verdict")
    eq(decoded.summary.fail, 1, "JSON: the summary")

    -- the Result-IR: one case per check, through the report layer's JUnit and GitHub reporters
    local result = conformance.to_result(report)
    eq(#result.cases, 2, "IR: one case per check")
    eq(result.cases[2].status, "fail", "IR: a failing check is a failed case")
    eq(result.cases[1].status, "pass", "IR: a passing check passes")
    eq(result.cases[2].assertions[1].file, "LICENSE", "IR: the assertion carries file")
    local valid, problems = require("testing.core.result").validate(result)
    ok(valid, "IR validates: " .. vim.inspect(problems))
    local outputs, errors =
      require("testing.report").run_reporters(result, { reporters = { "junit", "github" } })
    eq(errors, {}, "the reporters render the conformance result")
    has(table.concat(outputs[1].lines, "\n"), "<testcase", "JUnit has cases")
    has(table.concat(outputs[2].lines, "\n"), "NEW-06", "the GitHub annotation names the rule")
    local with_na = conformance.to_result({
      name = "x",
      checks = {
        {
          id = "K3",
          title = "t",
          kind = "runtime",
          rules = {},
          status = "n/a",
          reason = "nothing to do",
          findings = {},
          notes = {},
        },
        {
          id = "K6",
          title = "t",
          kind = "runtime",
          rules = {},
          status = "error",
          reason = "child died",
          findings = {},
          notes = {},
        },
      },
    })
    eq(
      { with_na.cases[1].status, with_na.cases[2].status },
      { "skip", "error" },
      "IR: n/a is skip, error is error"
    )

    -- hostile text in a report that did not come from a check (a hand-built report): the renderers clean again
    local hostile = {
      schema_version = 1,
      tool = "testing.conformance",
      root = "<REPO>",
      name = "evil\27[31m\226\128\174name",
      plugin = "p\27]0;x\7",
      mode = "report",
      verdict = "fail",
      problems = { "problem \27[2J" },
      manual = {
        {
          id = "M-1",
          title = "t\27[1m",
          reason = "r\1",
          severity = "critical",
          gate = "g",
          status = "manual",
        },
      },
      summary = {
        checks = 1,
        pass = 0,
        fail = 1,
        warn = 0,
        ["n/a"] = 0,
        error = 0,
        manual = 1,
        waived = 1,
        findings = { error = 1, warn = 0, info = 0 },
      },
      checks = {
        {
          id = "K1",
          title = "ti\27tle",
          kind = "static",
          rules = { "R\27" },
          status = "fail",
          reason = "re\27ason",
          notes = { "n\27ote" },
          findings = {
            {
              check = "K1",
              rule = "R-1",
              level = "error",
              message = "m\27[0m\226\128\174x",
              file = "a\27b.lua",
              line = 3,
            },
            {
              check = "K1",
              rule = "R-2",
              level = "warn",
              message = "w",
              waived = true,
              waiver_reason = "why\27[1m",
            },
          },
        },
      },
    }
    for label, rendered in pairs({
      terminal = table.concat(
        conformance.terminal(hostile, { verbose = true, manual = true }),
        "\n"
      ),
      markdown = conformance.markdown(hostile),
    }) do
      ok(
        not rendered:find("[%z\1-\8\11-\31\127]"),
        label .. ": no control character reaches the output"
      )
      ok(
        not rendered:find("\226\128\174", 1, true),
        label .. ": no bidi override reaches the output"
      )
    end
    has(
      table.concat(conformance.terminal(hostile), "\n"),
      "\\x1B",
      "an ESC is made visible, not dropped"
    )

    -- ===================================================================
    -- 2. main: flags and exit codes
    local code, out = main({ flawed })
    eq(code, 0, "report-only (the default): exit 0 although a check failed")
    has(out, "FAIL   K15", "and the report is printed")
    code = main({ "--gate", flawed })
    eq(code, 1, "--gate: exit 1 when a check failed")
    code = main({ "--gate", clean })
    eq(code, 0, "--gate on a clean repository: exit 0")
    code = main({ "--gate", "--report-only", flawed })
    eq(code, 0, "the last of --gate / --report-only wins")
    S.write(flawed .. "/.testing.lua", 'return { plugin = "goodp", conformance = { gate = true } }')
    eq((main({ flawed })), 1, "conformance.gate = true in .testing.lua makes the gate the default")
    eq((main({ "--report-only", flawed })), 0, "--report-only overrides it")
    S.remove(flawed, ".testing.lua")

    code, out = main({ "--json", flawed })
    eq(code, 0, "--json exits like the mode")
    eq(vim.json.decode(out).tool, "testing.conformance", "--json prints the report as JSON")
    code, out = main({ "--markdown", flawed })
    eq(code, 0, "--markdown exits like the mode")
    has(out, "# Conformance: goodp.nvim", "--markdown prints Markdown")
    code, out = main({ "--only", "K15", flawed })
    eq(code, 0, "--only exits like the mode")
    ok(out:find("K7 ", 1, true) == nil and out:find("K15", 1, true) ~= nil, "--only selects")
    code, out = main({ "--only=K7,K15", "--skip=K7", flawed })
    eq(code, 0, "--only=... --skip=... exits like the mode")
    has(out, "n/a    K7", "--skip wins over --only for the same id")
    code, out = main({ "--list" })
    eq(code, 0, "--list exits 0")
    local listed = vim.split(out, "\n")
    eq(#listed, 15, "--list names the 15 checks")
    ok(listed[1]:find("^K1 ") ~= nil and listed[15]:find("^K15") ~= nil, "in order")
    has(listed[3], "REL-20", "with their rules")
    code, out = main({ "--help" })
    eq(code, 0, "--help exits 0")
    has(out, "--gate", "and shows the flags")
    local _, _, usage_err = main({ "--only", "K99" })
    has(usage_err, 'unknown check id "K99"', "an unknown check id is a usage error")
    eq((main({ "--only", "K99" })), 2, "exit 2")
    eq((main({ "--nope" })), 2, "an unknown option is exit 2")
    eq((main({ "a", "b" })), 2, "two paths are exit 2")
    eq((main({ "--only" })), 2, "a missing value is exit 2")
    _, _, usage_err = main({ "--nope" })
    has(usage_err, "usage: testing conformance", "a usage error shows the usage")

    -- an infrastructure error is exit 3, in report-only mode too
    eq((main({ flawed }, {
      run = function()
        error("exploded")
      end,
    })), 3, "a raising run is exit 3")
    eq((main({ "--only", "K2", clean }, {
      run = function(root, opts)
        return conformance.run(root, vim.tbl_extend("force", opts, { probe = probe }))
      end,
    })), 3, "a check that could not run is exit 3")
    eq(
      (main({ "/this/does/not/exist/at/all" }, { run = conformance.run })),
      3,
      "a root that is no directory is exit 3"
    )

    -- report files: written outside the repository, never inside it (SEC-47)
    local outdir = vim.fs.normalize(vim.fn.tempname()) .. "-out"
    code = main({
      "--json-file",
      outdir .. "/r.json",
      "--markdown-file=" .. outdir .. "/r.md",
      "--junit-file",
      outdir .. "/j.xml",
      flawed,
    })
    eq(code, 0, "writing the reports works")
    eq(vim.json.decode(S.slurp(outdir .. "/r.json")).verdict, "fail", "the JSON file")
    has(S.slurp(outdir .. "/r.md"), "# Conformance", "the Markdown file")
    has(S.slurp(outdir .. "/j.xml"), "<testsuite", "the JUnit file")
    vim.fn.delete(outdir, "rf")
    local before = S.slurp(flawed .. "/README.md")
    code, _, usage_err = main({ "--json-file", flawed .. "/report.json", flawed })
    eq(code, 2, "a report file inside the checked repository is refused")
    has(usage_err, "inside the checked repository", "with the reason")
    ok(vim.uv.fs_stat(flawed .. "/report.json") == nil, "and nothing was written")
    eq(S.slurp(flawed .. "/README.md"), before, "the repository is untouched")
    eq((main({ "--junit-file", flawed .. "/x/j.xml", flawed })), 2, "also for the JUnit file")

    -- an unusable .testing.lua is a configuration error: exit 2, and the report says why
    local broken_cfg = S.new_repo()
    S.write(broken_cfg .. "/.testing.lua", "return {")
    local ccode, cout = main({ broken_cfg })
    eq(ccode, 2, "an unusable .testing.lua is exit 2")
    has(cout, "cannot load .testing.lua", "and the report names the reason")

    -- the default root is the current directory of the caller
    code, out = main({}, { cwd = clean })
    eq(code, 0, "no path: exit 0 on a clean repository")
    has(out, "conformance: goodp.nvim", "no path: services.cwd")

    -- ===================================================================
    -- 3. fsx: literal paths, bounded, never out of the root
    local fsx = require("testing.conformance.fsx")
    local root = S.new_repo()
    local fs = fsx.new(root)
    ok(fs:is_file("README.md") and fs:is_dir("lua/goodp"), "relative paths work")
    ok(fs:read("README.md"):find("goodp", 1, true) ~= nil, "read")
    for _, bad in ipairs({ "../x", "lua/../../x", "/etc/passwd", "C:/Windows", "a\0b", "", "..\\x" }) do
      ok(fs:stat(bad) == nil, "refused: " .. vim.inspect(bad))
      ok(fs:read(bad) == nil, "refused (read): " .. vim.inspect(bad))
    end
    local _, why = fs:read("lua/../../outside")
    eq(why, "not found", "a traversal reads as absent")
    ok(not fsx.check_rel("../x") and fsx.check_rel("a/b"), "check_rel")
    -- a file that is too large is not read
    local big = root .. "/big.txt"
    local fh = assert(io.open(big, "wb"))
    fh:write(("x"):rep(fsx.MAX_BYTES + 1))
    fh:close()
    local content, err = fs:read("big.txt")
    ok(
      content == nil and err:find("larger than", 1, true) ~= nil,
      "a file above the limit is refused: " .. tostring(err)
    )
    -- lines: LF and CRLF, no final newline
    S.write(root .. "/crlf.txt", "a\r\nb\r\n\r\nc")
    eq(fs:lines("crlf.txt"), { "a", "b", "", "c" }, "lines of a CRLF file")
    S.write(root .. "/empty.txt", "")
    eq(fs:lines("empty.txt"), {}, "an empty file has no lines")
    -- walk: sorted, skips .git/.claude/.deps, honours the limit and the extension
    S.write(root .. "/lua/goodp/z.lua", "return 1")
    S.write(root .. "/.deps/dep/lua/d.lua", "return 1")
    S.write(root .. "/.claude/worktrees/w/lua/goodp/copy.lua", "return 1")
    local walked = fs:walk("lua", { ext = "lua" })
    ok(vim.deep_equal(walked, vim.fn.sort(vim.deepcopy(walked))), "walk is sorted")
    ok(vim.tbl_contains(walked, "lua/goodp/z.lua"), "walk finds files")
    ok(#fs:walk(".", { ext = "lua" }) > 0, "walk from the root")
    for _, rel in ipairs(fs:walk(".", { ext = "lua" })) do
      ok(
        not rel:find("^%.deps") and not rel:find("^%.claude"),
        "walk skips copies of the code: " .. rel
      )
    end
    eq(#fs:walk("lua", { ext = "lua", limit = 2 }), 2, "walk honours the limit")
    eq(fs:walk("nope"), {}, "walk of a missing directory")
    local listing = fs:list("lua/goodp")
    ok(listing[1].name < listing[2].name, "list is sorted")
    -- a symbolic link out of the root is treated as absent
    local outside = vim.fs.normalize(vim.fn.tempname()) .. "-secret.txt"
    S.write(outside, "secret")
    local linked, lerr = vim.uv.fs_symlink(outside, root .. "/link.txt")
    if linked then
      ok(fs:read("link.txt") == nil, "a symlink out of the root is not followed")
      ok(not vim.tbl_contains(fs:walk("."), "link.txt"), "nor listed by a walk")
    else
      ok(
        tostring(lerr):find("EPERM", 1, true)
          or tostring(lerr):find("ENOTSUP", 1, true)
          or tostring(lerr):find("operation not permitted", 1, true),
        "a symlink can only be refused for permission (Windows without the privilege): "
          .. tostring(lerr)
      )
    end
    vim.fn.delete(outside)

    -- ===================================================================
    -- 4. the rules.nvim bridge (soft)
    local bridge = require("testing.conformance.rules_bridge")
    local absent = bridge.run(root, {
      loader = function()
        return nil, "rules.nvim is not installed"
      end,
    })
    ok(absent.available == false and absent.status == "n/a", "no rules.nvim: a clear n/a")
    has(absent.reason, "rules.nvim", "and the reason")
    eq(
      conformance.run(root, { probe = probe, only = { "K7" } }).bridge,
      nil,
      "without --bridge the report has no bridge section"
    )
    report = conformance.run(flawed, {
      probe = probe,
      only = { "K15" },
      bridge = {
        loader = function()
          return {
            { id = "NEW-06", severity = "critical", status = "fail", findings = { {} } },
            { id = "NEW-45", severity = "recommended", status = "pass", findings = {} },
            { id = "NEW-36", severity = "recommended", status = "pass", findings = {} },
            { id = "NEW-09", severity = "recommended", status = "manual", findings = {} },
            { id = "REL-99", severity = "critical", status = "manual", findings = {} },
            { id = "NEW-07", severity = "recommended", status = "waived", findings = {} },
          }
        end,
      },
    })
    ok(report.bridge.available, "the bridge ran")
    eq(
      report.bridge.drift,
      { { rule = "NEW-45", testing = "fail", rules_nvim = "pass" } },
      "a verdict that differs is drift"
    )
    local manual_ids = {}
    for _, m in ipairs(report.manual) do
      manual_ids[m.id] = m
    end
    ok(
      manual_ids["REL-99"] ~= nil and manual_ids["REL-99"].source == "rules.nvim",
      "a manual rule of rules.nvim is merged"
    )
    ok(
      manual_ids["NEW-09"] ~= nil and manual_ids["NEW-09"].source == "testing",
      "a rule known on both sides is listed once"
    )
    eq(report.verdict, "fail", "the bridge never changes the verdict")

    -- the real thing, when rules.nvim is a sibling checkout: an unconfigured ruleset is a clear n/a
    local found = require("testing.deps").resolve("rules.nvim", S.repo)
    local saved_rtp = vim.o.runtimepath
    local real = bridge.run(root, {})
    vim.o.runtimepath = saved_rtp -- the bridge puts a found checkout of rules.nvim on the runtimepath
    if found then
      ok(real.available == false, "rules.nvim without a ruleset is not a run")
      has(real.reason, "no ruleset configured", "and says so")
    else
      ok(real.available == false, "no rules.nvim on this machine: n/a")
      has(real.reason, "rules.nvim is not installed", "and says so")
    end
  end)
end
