-- TESTS/testing/cli_spec.lua -- argument parsing, and the exit codes of
-- `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root>` (a real child process,
-- run on a temp fixture project): 0 green / 1 failures / 2 usage-config / 3 infrastructure.

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
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local cli = require("testing.cli")
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

  -- parse
  local args =
    assert(cli.parse({ "root", "--json", "o.json", "--only", "a", "--only", "b", "--no-timings" }))
  eq(args.root, "root", "root")
  eq(args.json, "o.json", "json")
  eq(#args.only, 2, "--only is repeatable")
  eq(args.timings, false, "--no-timings")
  local bad, why = cli.parse({ "root", "--frobnicate" })
  eq(bad, nil, "unknown option is refused")
  has(why, "unknown option", "says so")
  bad, why = cli.parse({ "root", "--json" })
  eq(bad, nil, "a missing value is refused")
  has(why, "needs a value", "says so")
  eq((cli.parse({ "one", "two" })), nil, "two roots are refused")
  eq(cli.parse({ "-h" }).help, true, "-h")

  -- child processes
  local entry = repo .. "/scripts/testing.lua"
  local function run(argv, env)
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", entry }
    vim.list_extend(cmd, argv)
    local res = vim.system(cmd, { text = true, env = env }):wait(60000)
    return res.code, res.stdout or "", res.stderr or ""
  end

  local root = vim.fs.normalize(vim.fn.tempname())
  write(root .. "/TESTS/run.lua", 'io.stdout:write("\\nPROJ_TESTS_OK\\n")\n')
  write(root .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')

  local code, out, errout = run({ root })
  eq(code, 0, "green project: exit 0\n" .. out .. errout)
  has(errout, "cwd is", "a cwd that is not the root is noted on stderr")
  has(out, "ok    a_spec.lua", "the file line")
  has(out, "\nPROJ_TESTS_OK", "the transitional sentinel of the project's runner")
  ok(out:find("PROJ_TESTS_OK%s*$") ~= nil, "the sentinel is the last line")

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
  has(out, "b_spec.lua:2: b1", "first failure visible")
  has(out, "b_spec.lua:3: b2", "second failure visible too")
  has(out, "1 spec(s) failed", "failure summary")
  ok(not out:find("PROJ_TESTS_OK", 1, true), "no sentinel when anything failed")

  eq((run({})), 2, "no root: exit 2")
  eq((run({ root, "--bogus" })), 2, "unknown option: exit 2")
  eq((run({ root .. "/missing" })), 2, "root is not a directory: exit 2")
  eq((run({ root, "--only", "no_such_file" })), 2, "no spec matched: exit 2")
  eq((run({ root, "--rtp", root .. "/missing" })), 2, "--rtp that is no directory: exit 2")
  code, out = run({ "--help" })
  eq(code, 0, "--help: exit 0")
  has(out, "exit: 0 green", "the help names the exit codes")

  -- exit 3: the IR cannot be written (the --json target is a directory)
  vim.fn.mkdir(root .. "/blocked.json", "p")
  code, out = run({ root, "--json", root .. "/blocked.json" })
  eq(code, 3, "unwritable IR: exit 3\n" .. out)
  ok(not out:find("PROJ_TESTS_OK", 1, true), "no sentinel when the IR could not be written")

  vim.fn.delete(root, "rf")

  -- F1: a spec listed in TESTS/run.lua but missing on disk fails the run (never a quiet green)
  local r2 = vim.fs.normalize(vim.fn.tempname())
  write(
    r2 .. "/TESTS/run.lua",
    'local specs = { "a_spec.lua", "gone_spec.lua" }\nio.stdout:write("\\nP2_OK\\n")\n'
  )
  write(r2 .. "/TESTS/a_spec.lua", 'return function(H)\n  H.eq(1, 1, "a")\nend\n')
  code, out, errout = run({ r2 })
  eq(code, 1, "a listed spec that is missing: exit 1\n" .. out .. errout)
  has(out, "FAIL  gone_spec.lua", "the missing spec is a failing case")
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
  has(out, "FAIL  b_spec.lua", "the exiting spec is a failure")
  has(out, "os.exit(0) called by a spec", "says why")
  has(out, "ok    c_spec.lua", "the later file still ran")
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
