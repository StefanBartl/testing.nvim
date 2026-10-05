-- TESTS/testing/cli_spec.lua -- the exit codes of the command line: in-process (driver and discovery
-- replaced by stubs where a child cannot reach the path, output captured) and as a real child process
-- (`nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root>`) on temp fixture projects:
-- 0 green / 1 failures / 2 usage-config / 3 infrastructure.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local cli = require("testing.cli")
  local real_inproc = require("testing.run.inproc")
  local real_discover = require("testing.discover")
  local result_mod = require("testing.core.result")
  local this = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(this))))

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- parse (the grammar itself is covered by args_spec; this is the delegate of the M0 API)
  local args =
    assert(cli.parse({ "root", "--json", "o.json", "--only", "a", "--only", "b", "--no-timings" }))
  eq(args.root, "root", "root")
  eq(args.json, "o.json", "json")
  eq(args.file, { "a", "b" }, "--only is repeatable")
  eq(args.timings, false, "--no-timings")
  local bad, why = cli.parse({ "root", "--frobnicate" })
  eq(bad, nil, "unknown option is refused")
  has(why, "unknown option", "says so")

  -- M1 wired every option: nothing is parsed and then ignored
  eq(next(cli.UNWIRED), nil, "no option is left unwired")

  -- =====================================================================
  -- in-process: seams replaced, the output captured
  ---@class CliSpec.Result
  ---@field code integer
  ---@field out string
  ---@field err string

  local state_dir = vim.fs.normalize(vim.fn.tempname())
  ---@param argv string[]
  ---@param seams? table
  ---@return CliSpec.Result
  local function captured(argv, seams)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
    }
    for k, v in pairs(seams or {}) do
      sv[k] = v
    end
    local code = cli.main(argv, sv)
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local stub_root = vim.fs.normalize(vim.fn.tempname())
  write(stub_root .. "/TESTS/x_spec.lua", 'return function(H)\n  H.eq(1, 1, "x")\nend\n')

  ---A driver stub: the real module with some functions replaced.
  ---@param over? table
  ---@return table
  local function stub(over)
    local fake = {
      run = function()
        local res = result_mod.new({ root = stub_root })
        local case = result_mod.new_case({ file = "TESTS/x_spec.lua", name = "x_spec.lua" })
        case.assertions[1] = { ok = true, kind = "eq" }
        result_mod.add_case(res, result_mod.finish_case(case))
        result_mod.finalize(res)
        return {
          result = res,
          failed = 0,
          failed_files = 0,
          total = 1,
          files_run = 1,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 0,
          exit_code = 0,
        }
      end,
    }
    return setmetatable(vim.tbl_extend("force", fake, over or {}), { __index = real_inproc })
  end
  local exit_before = os.exit

  local r = captured({ stub_root }, { inproc = stub() })
  eq(r.code, 0, "stubbed green run\n" .. r.err)
  has(r.out, "TESTING_OK", "the default sentinel")

  r = captured({ stub_root }, {
    discover = setmetatable({
      discover = function()
        error("discover exploded")
      end,
    }, { __index = real_discover }),
  })
  eq(r.code, 3, "discover raising is exit 3, not a raise")
  has(r.err, "internal error: ", "says what it is")
  has(r.err, "discover exploded", "and carries the message")

  r = captured({ stub_root, "--json", stub_root .. "/o.json" }, {
    inproc = stub({
      sanitize = function()
        error("encode exploded")
      end,
    }),
  })
  eq(r.code, 3, "the IR encoder raising is exit 3")
  has(r.err, "encode exploded", "with the message")

  r = captured({ stub_root, "--json", stub_root .. "/o.json" }, {
    inproc = stub({
      sanitize = function()
        return nil, nil, "the IR failed validation"
      end,
    }),
  })
  eq(r.code, 3, "an invalid IR is exit 3")
  has(r.err, "the IR failed validation", "with the reason")
  ok(not r.out:find("TESTING_OK", 1, true), "and no sentinel")

  r = captured({ stub_root }, {
    inproc = stub({
      run = function()
        local res = stub().run().result
        res.cases[1].status = "fail"
        return {
          result = res,
          failed = 1,
          failed_files = 1,
          total = 1,
          files_run = 1,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 0,
          exit_code = 1,
        }
      end,
    }),
  })
  eq(r.code, 1, "the driver's exit code 1 is passed on")
  ok(not r.out:find("TESTING_OK", 1, true), "no sentinel on a red run")

  r = captured({ stub_root }, {
    inproc = stub({
      run = function()
        error("driver exploded")
      end,
    }),
  })
  eq(r.code, 3, "the driver raising is exit 3")
  has(r.err, "driver exploded", "with the message")
  ok(os.exit == exit_before, "the os.exit guard is released again after a raising driver")

  -- a reporter that cannot write is an infrastructure error, never a green run
  vim.fn.mkdir(stub_root .. "/blocked.xml", "p")
  r = captured({ stub_root, "--junit", stub_root .. "/blocked.xml" }, { inproc = stub() })
  eq(r.code, 3, "a reporter that fails: exit 3\n" .. r.out .. r.err)
  ok(not r.out:find("TESTING_OK", 1, true), "and no sentinel")

  write(stub_root .. "/TESTS/y_spec.lua", 'return function(H)\n  H.eq(1, 1, "y")\nend\n')
  r = captured({ stub_root, "--only", "x_spec" }, { inproc = stub() })
  eq(r.code, 0, "a filtered green run")
  has(r.out, "partial run: 1 of 2", "says it is partial")
  ok(not r.out:find("TESTING_OK", 1, true), "and prints no sentinel")

  r = captured({ stub_root, "--list" })
  eq(r.code, 0, "--list")
  has(r.out, "TESTS/x_spec.lua", "lists the file relative to the root")
  has(r.out, "2 case(s) in 2 of 2 spec file(s) would run", "and counts")

  eq(captured({ "--help" }).code, 0, "--help")
  has(captured({ "--help" }).out, "exit: 0 green", "the help names the exit codes")
  eq(captured({}).code, 2, "no root")
  r = captured({ stub_root, "--filter", "x_spec", "-x" }, { inproc = stub() })
  eq(r.code, 0, "--filter and -x are wired: " .. r.err)
  r = captured({ stub_root, "TESTS/x_spec.lua" }, { inproc = stub() })
  eq(r.code, 0, "a path below the root selects: " .. r.err)
  has(r.out, "partial run", "and the run is partial")
  r = captured({ stub_root, "nowhere" }, { inproc = stub() })
  eq(r.code, 2, "a path that holds no spec is exit 2")
  has(r.err, "below nowhere", "naming the path")
  r = captured({ "init", stub_root })
  eq(r.code, 2, "init is refused until it is implemented")
  has(r.err, "init", "and says so")
  r = captured({ stub_root, "--shuffle", "--seed" })
  eq(r.code, 2, "a usage error is exit 2")
  has(r.err, "usage:", "and prints the usage")
  r = captured({ stub_root, "--config", stub_root .. "/nope.lua" })
  eq(r.code, 2, "a missing --config file is exit 2")
  has(r.err, "not found", "and says so")

  -- doctor in-process: the report, the resolved config, a dependency that is not there
  write(
    stub_root .. "/.testing.lua",
    'return { deps = { "ghost-dep.nvim" }, timeouts = { case_ms = "x" } }\n'
  )
  r = captured({ "doctor", stub_root })
  eq(r.code, 3, "doctor: a missing dependency is exit 3\n" .. r.out)
  has(r.out, "testing doctor", "doctor prints its header")
  has(r.out, "resolved configuration:", "the resolved configuration")
  has(r.out, "ghost-dep.nvim", "the project dependency is listed")
  has(r.out, "$GHOST_DEP_NVIM_DIR", "with all four places")
  has(r.out, "stdpath('data')/lazy/ghost-dep.nvim", "including the last")
  has(r.out, "warning: key 'timeouts.case_ms' is invalid", "config warnings are shown")
  has(r.out, "ok       lib.nvim", "lib.nvim is reported as found")
  vim.fn.delete(stub_root .. "/.testing.lua")
  r = captured({ "doctor", stub_root })
  eq(r.code, 0, "doctor on a fine project: exit 0\n" .. r.out)
  has(r.out, "none (.testing.lua not found, defaults)", "says there is no config file")
  vim.fn.delete(stub_root, "rf")
  vim.fn.delete(state_dir, "rf")
  ok(os.exit == exit_before, "the os.exit guard is not left behind")

  -- =====================================================================
  -- child processes
  local entry = repo .. "/scripts/testing.lua"
  local function run(argv, env)
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", entry }
    vim.list_extend(cmd, argv)
    local res = vim.system(cmd, { text = true, env = env }):wait(60000)
    return res.code, res.stdout or "", res.stderr or ""
  end

  ---Exit code and stderr only.
  local function run_err(argv, env)
    local c, _, e = run(argv, env)
    return c, e
  end

  local root = vim.fs.normalize(vim.fn.tempname())
  write(root .. "/TESTS/run.lua", 'io.stdout:write("\\nPROJ_TESTS_OK\\n")\n')
  write(root .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')

  local code, out, errout = run({ root })
  eq(code, 0, "green project: exit 0\n" .. out .. errout)
  has(errout, "cwd is", "a cwd that is not the root is noted on stderr")
  has(out, "ok    TESTS/a_spec.lua", "the file line")
  has(out, "\nPROJ_TESTS_OK", "the transitional sentinel of the project's runner")
  ok(out:find("PROJ_TESTS_OK%s*$") ~= nil, "the sentinel is the last line")

  code = run({ "run", root })
  eq(code, 0, "the explicit run subcommand: exit 0")
  code = run({ "--root", root })
  eq(code, 0, "--root instead of a positional: exit 0")

  code, out = run({ root, "--sentinel", "CUSTOM_OK" })
  eq(code, 0, "--sentinel: exit 0")
  has(out, "CUSTOM_OK", "--sentinel overrides the hint")

  local json_file = root .. "/out/r.json"
  code, out = run({ root, "--json", json_file })
  eq(code, 0, "--json on a green project: exit 0\n" .. out)
  local f = assert(io.open(json_file, "rb"))
  local body = f:read("*a")
  f:close()
  has(body, '"schema_version":1', "the IR file exists and says its version")

  write(
    root .. "/TESTS/b_spec.lua",
    'return function(H)\n  H.eq(1, 2, "b1")\n  H.eq(2, 3, "b2")\nend\n'
  )
  code, out = run({ root })
  eq(code, 1, "a failing file: exit 1")
  has(out, "TESTS/b_spec.lua:2", "first failure visible with its line")
  has(out, "b1", "and its message")
  has(out, "TESTS/b_spec.lua:3", "second failure visible too")
  has(out, "b2", "and its message")
  has(out, "1 spec(s) failed", "failure summary")
  ok(not out:find("PROJ_TESTS_OK", 1, true), "no sentinel when anything failed")

  eq((run({})), 2, "no root: exit 2")
  eq((run({ root, "--bogus" })), 2, "unknown option: exit 2")
  eq((run({ root .. "/missing" })), 2, "root is not a directory: exit 2")
  eq((run({ root, "--only", "no_such_file" })), 2, "no spec matched: exit 2")
  eq((run({ root, "--rtp", root .. "/missing" })), 2, "--rtp that is no directory: exit 2")
  eq((run({ root, "--filter", "nothing_has_this_name" })), 2, "no case selected: exit 2")
  code, out = run({ "--help" })
  eq(code, 0, "--help: exit 0")
  has(out, "exit: 0 green", "the help names the exit codes")

  -- the reporter flags are wired
  local junit_file = root .. "/out/junit.xml"
  code = run({ root, "--junit", junit_file })
  eq(code, 1, "--junit does not change the verdict")
  local jf = assert(io.open(junit_file, "rb"))
  local xml = jf:read("*a")
  jf:close()
  has(xml, "<testsuites", "the JUnit file was written")
  code, out = run({ root, "--github", "--file", "b_spec" })
  eq(code, 1, "--github: exit 1")
  has(out, "::error", "annotations on stdout")

  -- exit 3: the IR cannot be written (the --json target is a directory)
  vim.fn.mkdir(root .. "/blocked.json", "p")
  code, out = run({ root, "--json", root .. "/blocked.json" })
  eq(code, 3, "unwritable IR: exit 3\n" .. out)
  ok(not out:find("PROJ_TESTS_OK", 1, true), "no sentinel when the IR could not be written")

  -- --list runs nothing: a spec that would fail if it ran
  write(root .. "/TESTS/boom_spec.lua", 'error("boom_spec must not run")\n')
  code, out = run({ root, "--list" })
  eq(code, 0, "--list: exit 0 although a spec would raise\n" .. out)
  has(out, "TESTS/boom_spec.lua", "--list names every file")
  ok(not out:find("boom_spec must not run", 1, true), "and ran none")
  code, out = run({ "list", root, "--only", "a_spec" })
  eq(code, 0, "the list subcommand with a filter")
  has(out, "1 case(s) in 1 of 3 spec file(s) would run", "counts the filtered files")
  vim.fn.delete(root, "rf")

  -- .testing.lua
  local cfgroot = vim.fs.normalize(vim.fn.tempname())
  write(cfgroot .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')
  write(cfgroot .. "/.testing.lua", "return {\n")
  code, errout = run_err({ cfgroot })
  eq(code, 2, "a syntax error in .testing.lua: exit 2")
  has(errout, ".testing.lua", "naming the file")
  write(cfgroot .. "/.testing.lua", "return 7\n")
  eq((run({ cfgroot })), 2, "a .testing.lua that returns no table: exit 2")
  write(cfgroot .. "/.testing.lua", 'return { timeouts = { case_ms = "x" } }\n')
  code, out, errout = run({ cfgroot })
  eq(code, 0, "an invalid value only degrades to the default: exit 0\n" .. out .. errout)
  has(errout, "config: key 'timeouts.case_ms' is invalid", "and the warning names the key")
  local rootsroot = vim.fs.normalize(vim.fn.tempname())
  write(rootsroot .. "/.testing.lua", 'return { roots = { "nowhere" } }\n')
  write(rootsroot .. "/other/o_spec.lua", 'return function(H)\n  H.eq(1, 1, "o")\nend\n')
  code = run_err({ rootsroot })
  eq(code, 2, "a configured root that does not exist: exit 2, not a quiet default")
  write(rootsroot .. "/.testing.lua", 'return { roots = { "spec" } }\n')
  write(rootsroot .. "/spec/s_spec.lua", 'return function(H)\n  H.eq(1, 1, "s")\nend\n')
  code, out, errout = run({ rootsroot })
  eq(code, 0, "a configured root is honored: exit 0\n" .. out .. errout)
  has(out, "ok    spec/s_spec.lua", "the spec of the configured root ran")
  ok(not out:find("o_spec.lua", 1, true), "and a directory that is not a root did not")
  vim.fn.delete(rootsroot, "rf")
  write(cfgroot .. "/.testing.lua", 'return { deps = { "ghost-dep.nvim" } }\n')
  code, out, errout = run({ cfgroot })
  eq(code, 3, "a missing dependency: exit 3\n" .. out .. errout)
  has(errout, "$GHOST_DEP_NVIM_DIR", "place 1 named")
  has(errout, ".deps/ghost-dep.nvim", "place 2 named")
  has(errout, "../ghost-dep.nvim", "place 3 named")
  has(errout, "stdpath('data')/lazy/ghost-dep.nvim", "place 4 named")
  ok(not out:find("a_spec.lua", 1, true), "and nothing ran")
  -- the same dependency found through the environment override
  local dep = vim.fs.normalize(vim.fn.tempname()) .. "/ghost-dep.nvim"
  vim.fn.mkdir(dep .. "/lua", "p")
  write(cfgroot .. "/.testing.lua", 'return { deps = { "ghost-dep.nvim" } }\n')
  code, out, errout = run({ cfgroot }, { GHOST_DEP_NVIM_DIR = dep })
  eq(code, 0, "the override resolves it: exit 0\n" .. out .. errout)
  vim.fn.delete(vim.fs.dirname(dep), "rf")
  vim.fn.delete(cfgroot, "rf")

  -- the entry script without lib.nvim: all four places named, exit 3 (D.3.3), not 2
  code, out, errout = run({ "--help" }, { LIB_NVIM_DIR = repo .. "/no-such-lib-checkout" })
  eq(code, 3, "lib.nvim not found: exit 3\n" .. out .. errout)
  has(errout, "$LIB_NVIM_DIR", "place 1 named")
  has(errout, ".deps/lib.nvim", "place 2 named")
  has(errout, "../lib.nvim", "place 3 named")
  has(errout, "stdpath('data')/lazy/lib.nvim", "place 4 named")
  has(errout, "no-such-lib-checkout", "the bad override is shown")

  -- F1: a spec listed in TESTS/run.lua but missing on disk fails the run (never a quiet green)
  local r2 = vim.fs.normalize(vim.fn.tempname())
  write(
    r2 .. "/TESTS/run.lua",
    'local specs = { "a_spec.lua", "gone_spec.lua" }\nio.stdout:write("\\nP2_OK\\n")\n'
  )
  write(r2 .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')
  code, out, errout = run({ r2 })
  eq(code, 1, "a listed spec that is missing: exit 1\n" .. out .. errout)
  has(out, "FAIL  TESTS/gone_spec.lua", "the missing spec is a failing case")
  ok(not out:find("P2_OK", 1, true), "no sentinel when a listed spec is missing")

  -- F2: a spec that calls os.exit cannot end the run; the file is an error, the later files run
  write(
    r2 .. "/TESTS/run.lua",
    'local specs = { "a_spec.lua", "b_spec.lua", "c_spec.lua" }\nio.stdout:write("\\nP2_OK\\n")\n'
  )
  write(r2 .. "/TESTS/b_spec.lua", 'return function(H)\n  H.eq(1, 1, "b")\n  os.exit(0)\nend\n')
  write(r2 .. "/TESTS/c_spec.lua", 'return function(H)\n  H.eq(1, 1, "c")\nend\n')
  os.remove(r2 .. "/TESTS/gone_spec.lua")
  code, out, errout = run({ r2 })
  eq(code, 1, "os.exit in a spec: exit 1, not 0\n" .. out .. errout)
  has(out, "FAIL  TESTS/b_spec.lua", "the exiting spec is a failure")
  has(out, "os.exit(0)", "says why (the reporter truncates the line)")
  has(out, "ok    TESTS/c_spec.lua", "the later file still ran")
  ok(not out:find("P2_OK", 1, true), "no sentinel")

  -- F2b: quitting the editor from a spec is 'run did not complete': exit 3, no sentinel
  write(r2 .. "/TESTS/b_spec.lua", 'return function(H)\n  H.eq(1, 1, "b")\n  vim.cmd("qa!")\nend\n')
  code, out, errout = run({ r2 })
  eq(code, 3, "qa! in a spec: exit 3\n" .. out .. errout)
  has(errout, "run did not complete", "says so on stderr")
  ok(not out:find("P2_OK", 1, true), "no sentinel")

  -- F3: a filtered run is not the project's verdict: no sentinel, a distinct last line
  write(r2 .. "/TESTS/b_spec.lua", 'return function(H)\n  H.eq(1, 1, "b")\nend\n')
  code, out = run({ r2, "--only", "a_spec" })
  eq(code, 0, "--only, green: exit 0")
  ok(not out:find("P2_OK", 1, true), "--only never prints the project sentinel")
  has(out, "partial run: 1 of 3 spec files", "the partial run says so")
  code, out = run({ r2 })
  eq(code, 0, "unfiltered, green: exit 0")
  ok(out:find("P2_OK%s*$") ~= nil, "unfiltered run prints the sentinel last")

  vim.fn.delete(r2, "rf")
end
