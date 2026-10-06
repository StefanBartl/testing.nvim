-- TESTS/testing/integration_cli_spec.lua -- the integration step of M4/M5 at the seams the other specs do not
-- cross: the `conformance` and `surface` subcommands are dispatched by `testing.cli` with their own arguments and
-- exit codes, the typed configuration keys (`conformance`, `surface`, `cache`, `coverage.autocmds`) validate and
-- name the key that is wrong, `:Testing` offers the new verbs and flags and builds the right argv, and
-- `:checkhealth testing` reports the cache, the affected selection, the conformance suite and the surface.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type, duplicate-set-field

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end

  local cli = require("testing.cli")
  local project = require("testing.config.project")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))

  local function captured(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      color = false,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  -- ---------------------------------------------------------------- dispatch: conformance
  eq(next(cli.RESERVED.commands), nil, "no command is reserved any more")
  local listed = captured({ "conformance", "--list" })
  eq(listed.code, 0, "testing conformance --list: exit 0\n" .. listed.err)
  for _, id in ipairs({ "K1", "K7", "K15" }) do
    has(listed.out, id, "the check list names " .. id)
  end
  local bad = captured({ "conformance", "--no-such-option" })
  eq(bad.code, 2, "conformance has its own grammar: an unknown option is a usage error")
  has(bad.err, "testing conformance:", "and the message is the suite's own")
  local help = captured({ "conformance", "--help" })
  eq(help.code, 0, "conformance --help")
  has(help.out, "--gate", "the suite's usage names --gate")

  -- a real, static-only run on the conforming fixture: report only, exit 0, K15 has a verdict
  local good = dir .. "/fixtures/conformance/good"
  local static = captured({ "conformance", good, "--only", "K15", "--json" })
  eq(
    static.code,
    0,
    "conformance --only K15 on the fixture plugin is report only: exit 0\n" .. static.err
  )
  local report = vim.json.decode(static.out)
  eq(report.tool, "testing.conformance", "the JSON report is the suite's")
  eq(report.checks[1].id, "K15", "the report has the check that was asked for")
  eq(#report.checks, 1, "and only that one (--only)")

  -- a `require` whose name has no first segment (found in documentation.nvim): the check must not raise
  local odd = vim.fs.normalize(vim.fn.tempname()) .. "-k1odd"
  vim.fn.mkdir(odd .. "/lua/odd", "p")
  local function put(path, text)
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  put(odd .. "/.testing.lua", "return { plugin = 'odd' }\n")
  put(odd .. "/lua/odd/init.lua", "pcall(function() return require('.nothing') end)\nreturn {}\n")
  local k1 = captured({ "conformance", odd, "--only", "K1", "--json" })
  local k1_report = vim.json.decode(k1.out)
  ok(
    k1_report.checks[1].status ~= "error",
    "K1 does not raise on require('.x'): " .. tostring(k1_report.checks[1].reason)
  )
  vim.fn.delete(odd, "rf")

  -- ---------------------------------------------------------------- dispatch: surface
  local shelp = captured({ "surface", "--help" })
  eq(shelp.code, 0, "testing surface --help: exit 0")
  has(shelp.out, "--threshold", "the surface usage names its own options")
  local sbad = captured({ "surface", "--threshold", "7" })
  eq(sbad.code, 2, "surface has its own grammar: a threshold above 1 is a usage error")
  has(sbad.err, "testing surface:", "and the message is the surface's own")
  local S = dofile(dir .. "/surface_support.lua")
  S.run(function()
    local root = S.fixture()
    local res = captured({ "surface", root })
    eq(res.code, 0, "testing surface <root> lists the surface: exit 0\n" .. res.err)
    has(res.out, "command:FxOpen", "the surface lists the commands of the plugin")
    has(res.out, "binding:<leader>fo", "and its keymaps")
    local gate = captured({ "surface", root, "--threshold", "0.5" })
    eq(gate.code, 2, "a threshold without a tracked run is a usage error (never silently green)")
  end)

  -- ---------------------------------------------------------------- the usage and the parser agree
  local usage = require("testing.args").usage()
  has(usage, "conformance", "usage lists conformance")
  has(usage, "surface", "usage lists surface")
  for _, flag in ipairs({
    "--cached",
    "--no-cache",
    "--cache-refresh",
    "--cache-clear",
    "--changed",
    "--since",
    "--affected",
  }) do
    has(usage, flag, "usage lists " .. flag)
  end
  lacks(usage, "RESERVED", "nothing is marked reserved")

  -- ---------------------------------------------------------------- the typed configuration
  local cfg, problems = project.validate({
    conformance = {
      gate = true,
      skip = { "K10", "K12" },
      waivers = {
        { check = "K4", reason = "accepted: plain text commands", file = "lua/x/maps.lua" },
      },
      keymaps_off = { keymaps = false, marks = { enable = false } },
      timeout_ms = 30000,
      rules_bridge = { rulesets = { "rules/own.lua" }, families = { "NEW", "REL", "LUA" } },
    },
    surface = {
      track = true,
      threshold = 0.8,
      kinds = { "binding", "command" },
      ignore = { "^api:" },
      setup_chunk = "require('x').setup()",
    },
    cache = { enabled = true },
    coverage = { autocmds = 0.25 },
  })
  eq(problems, {}, "a complete, valid configuration has no problem: " .. vim.inspect(problems))
  eq(cfg.conformance.gate, true, "conformance.gate")
  eq(cfg.conformance.skip, { "K10", "K12" }, "conformance.skip")
  eq(cfg.conformance.waivers[1].check, "K4", "conformance.waivers")
  eq(cfg.conformance.timeout_ms, 30000, "conformance.timeout_ms")
  eq(cfg.conformance.rules_bridge.families, { "NEW", "REL", "LUA" }, "rules_bridge.families")
  eq(cfg.conformance.rules_bridge.rulesets, { "rules/own.lua" }, "rules_bridge.rulesets")
  eq(cfg.conformance.load_budget_ms, 40, "the default of load_budget_ms stays")
  eq(cfg.surface.track, true, "surface.track")
  eq(cfg.surface.threshold, 0.8, "surface.threshold")
  eq(cfg.surface.kinds, { "binding", "command" }, "surface.kinds")
  eq(cfg.surface.setup_chunk, "require('x').setup()", "surface.setup_chunk")
  eq(cfg.cache.enabled, true, "cache.enabled")
  eq(cfg.coverage.autocmds, 0.25, "coverage.autocmds")

  local defaults = project.validate({})
  eq(defaults.conformance.gate, false, "default: report only")
  eq(defaults.surface.track, false, "default: no tracking")
  eq(defaults.surface.threshold, 0, "default: no threshold")
  eq(defaults.cache.enabled, false, "default: no cache")

  for _, case in ipairs({
    { { conformance = { gate = "yes" } }, "conformance.gate" },
    { { conformance = { skip = { "K99x" } } }, "conformance.skip" },
    { { conformance = { skip = "K3" } }, "conformance.skip" },
    { { conformance = { waivers = { { check = "K4" } } } }, "conformance.waivers" },
    {
      { conformance = { waivers = { { check = "K4", reason = "short" } } } },
      "conformance.waivers",
    },
    { { conformance = { timeout_ms = 5 } }, "conformance.timeout_ms" },
    { { conformance = { rules_bridge = { families = {} } } }, "conformance.rules_bridge.families" },
    { { surface = { track = 1 } }, "surface.track" },
    { { surface = { threshold = 1.5 } }, "surface.threshold" },
    { { surface = { kinds = { "everything" } } }, "surface.kinds" },
    { { surface = { ignore = { "[" } } }, "surface.ignore" },
    { { surface = { setup_chunk = "" } }, "surface.setup_chunk" },
    { { cache = { enabled = "on" } }, "cache.enabled" },
    { { cache = { dir = "/x" } }, "cache.dir" },
    { { coverage = { autocmds = 2 } }, "coverage.autocmds" },
  }) do
    local c, p = project.validate(case[1])
    ok(#p == 1, case[2] .. ": exactly one problem: " .. vim.inspect(p))
    has(p[1] or "", case[2], "the problem names the key " .. case[2])
    eq(c.conformance.gate, false, "an invalid key never switches a gate on (" .. case[2] .. ")")
  end

  -- ---------------------------------------------------------------- :Testing
  local usrcmds = require("testing.bindings.usrcmds")
  local child = require("testing.bindings.child")
  ok(usrcmds.register(), ":Testing registers")
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end
  local verbs = complete("Testing ")
  for _, verb in ipairs({ "conformance", "surface", "budget", "cache" }) do
    ok(vim.tbl_contains(verbs, verb), ":Testing offers " .. verb .. ": " .. vim.inspect(verbs))
  end
  eq(complete("Testing cache "), { "clear", "stats" }, ":Testing cache offers its two words")
  eq(complete("Testing conformance --g"), { "--gate" }, ":Testing conformance completes its flags")
  ok(vim.tbl_contains(complete("Testing run --c"), "--cached"), ":Testing run offers --cached")
  ok(vim.tbl_contains(complete("Testing run --n"), "--no-cache"), "and --no-cache")
  ok(vim.tbl_contains(complete("Testing run --s"), "--since"), "and --since")
  ok(vim.tbl_contains(complete("Testing run --ch"), "--changed"), "and --changed")

  local argv = child.build_argv("run", {
    root = "/p",
    flags = { cached = true, no_cache = false, changed = true, since = "HEAD~2", shard = "1/4" },
  })
  local tail = table.concat(vim.list_slice(argv, 11, #argv), " ")
  eq(
    tail,
    "/p --cached --changed --since=HEAD~2 --shard=1/4",
    "the child argv carries the new flags"
  )
  local conf_argv = child.build_argv("conformance", {
    root = "/p",
    flags = { raw = { "--gate", "--only=K3" } },
  })
  eq(
    vim.list_slice(conf_argv, 10, #conf_argv),
    { "conformance", "/p", "--gate", "--only=K3" },
    "conformance gets the root and its own arguments verbatim"
  )
  local _, uerr = child.build_argv("nonsense", { root = "/p" })
  ok(uerr ~= nil, "an unknown subcommand is still refused")

  local verdict = child.interpret(
    "conformance",
    { code = 1, stdout = "K4 fail\nK5 pass", stderr = "" },
    { root = "/p" }
  )
  eq(verdict.level, "warn", "a failed gate is a warning with the report, not a failure to run")
  eq(verdict.lines, { "K4 fail", "K5 pass" }, "and the report is shown")
  local broken = child.interpret(
    "conformance",
    { code = 3, stdout = "", stderr = "boom" },
    { root = "/p" }
  )
  eq(broken.level, "error", "a check that could not run is an error")

  -- ---------------------------------------------------------------- :checkhealth testing
  local health = require("testing.health")
  local real_project_dir = health.project_dir
  local tmp = vim.fn.tempname() .. "-integration-health"
  vim.fn.mkdir(tmp, "p")
  health.project_dir = function()
    return tmp
  end
  local function report_text()
    vim.cmd("checkhealth testing")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    pcall(function()
      vim.cmd("silent! bwipeout!")
    end)
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(function()
        vim.cmd("silent! tabclose")
      end)
    end
    return text
  end
  local preload_before = package.preload["documentation.testing"]
  local loaded_before = package.loaded["documentation.testing"]
  local done, failure = pcall(function()
    package.loaded["documentation.testing"] = nil
    package.preload["documentation.testing"] = function()
      error("not installed here")
    end
    local text = report_text()
    has(text, "cache, affected selection, conformance, surface", "the report has the new section")
    has(text, "result cache:", "it reports the result cache")
    has(text, "is writable", "and that its directory can be written")
    has(text, "`testing conformance` is available (15 checks", "it reports the conformance suite")
    has(text, "`testing surface` and the tracking layer", "and the surface")
    has(
      text,
      "documentation.nvim contract is not on the runtimepath",
      "no contract: the heuristic is named"
    )

    package.loaded["documentation.testing"] = nil
    package.preload["documentation.testing"] = function()
      return { CONTRACT_VERSION = 1, affected_specs = function() end }
    end
    local with_contract = report_text()
    has(
      with_contract,
      "documentation.nvim contract is available (version 1)",
      "a contract is reported"
    )
    lacks(with_contract, "ERROR", "and nothing in the new section is an error")
  end)
  health.project_dir = real_project_dir
  package.preload["documentation.testing"] = preload_before
  package.loaded["documentation.testing"] = loaded_before
  vim.fn.delete(tmp, "rf")
  ok(done, "the health checks ran: " .. tostring(failure))
  pcall(vim.api.nvim_del_user_command, "Testing")
end
