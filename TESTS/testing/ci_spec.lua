-- TESTS/testing/ci_spec.lua -- `testing ci`: the `ci` section of `.testing.lua` (validation, profiles that include
-- profiles, presets, placeholders), the needs check before the first step (a missing tool is exit 3, never green),
-- fail-fast and --keep-going, a partial --step run (no sentinel), the deadline of a step (the tree is killed), the
-- suite as an in-process step on a real project, and the document testing-ci/1 in the state directory.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local ci = require("testing.ci")
  local schema = require("testing.ci.schema")
  local cli = require("testing.cli")

  -- ------------------------------------------------------------------ schema

  do
    local p, problems = schema.resolve({
      profiles = { fast = { "stylua", "lint" }, full = { "fast", "suite", "lint" } },
      steps = { lint = { preset = "luacheck", args = { "lua" } } },
    })
    eq(problems, {}, "schema: a valid section has no problems")
    eq(p.default, "full", "schema: `full` is the default without `default`")
    eq(
      p.profiles.full,
      { "stylua", "lint", "suite" },
      "schema: a profile includes a profile, no duplicates"
    )
    eq(
      p.steps.lint.argv,
      { "luacheck", "--formatter", "plain", "--codes", "lua" },
      "schema: args replace the preset's defaults after its fixed arguments"
    )
    eq(
      p.steps.stylua.argv,
      { "stylua", "--check", "." },
      "schema: a preset named in a profile is a step"
    )
    eq(p.steps.suite.inprocess, "run", "schema: the suite runs in-process")
    eq(p.steps.suite.stamp, true, "schema: the suite stamps by default")
    eq(p.steps.lint.needs, { "luacheck" }, "schema: the preset's needs")
  end

  local function problems_of(raw)
    local _, problems = schema.resolve(raw)
    return table.concat(problems, "\n")
  end
  has(problems_of({ profiles = { a = { "b" }, b = { "a" } } }), "cycle", "schema: a profile cycle")
  has(
    problems_of({ profiles = { full = { "x" } } }),
    '"x" is neither',
    "schema: an unknown name in a profile"
  )
  has(
    problems_of({ profiles = { full = { "s" } }, steps = { s = { run = { "x" } } }, extra = 1 }),
    "unknown key 'ci.extra'",
    "schema: an unknown top key is an error"
  )
  has(
    problems_of({ profiles = { full = { "s" } }, steps = { s = { run = { "x" }, tiemout = "1s" } } }),
    "unknown key 'ci.steps.s.tiemout'",
    "schema: a typo in a step is an error"
  )
  has(
    problems_of({ profiles = { full = { "s" } }, steps = { s = { preset = "nope" } } }),
    "unknown preset",
    "schema: an unknown preset"
  )
  has(
    problems_of({
      profiles = { full = { "s" } },
      steps = { s = { preset = "stylua", run = { "x" } } },
    }),
    "exclude each other",
    "schema: run and preset"
  )
  has(
    problems_of({ profiles = { full = { "s" } }, steps = { s = { run = { "x", "${HOME}" } } } }),
    "unknown placeholder ${HOME}",
    "schema: only ${root} and ${deps.<name>}"
  )
  has(
    problems_of({ profiles = { full = { "s" } }, steps = { s = { run = "make test" } } }),
    "argv list",
    "schema: a shell string is not a step"
  )
  has(
    problems_of({ profiles = { a = { "stylua" }, b = { "stylua" } } }),
    "name the default profile",
    "schema: several profiles, no full, no default"
  )
  eq(schema.duration("2m"), 120000, "duration: minutes")
  eq(schema.duration("30s"), 30000, "duration: seconds")
  eq(schema.duration(1500), 1500, "duration: milliseconds")
  eq(schema.duration("1x"), nil, "duration: an unknown unit")
  eq(schema.duration(0), nil, "duration: zero is no deadline")

  -- -------------------------------------------------------------------- args

  do
    local a = ci.parse({ "--profile=fast", "--step", "a,b", "--keep-going", "--", "--jobs", "4" })
    eq(a.profile, "fast", "args: --profile=")
    eq(a.steps, { "a", "b" }, "args: --step with a separate value")
    eq(a.keep_going, true, "args: --keep-going")
    eq(a.suite_args, { "--jobs", "4" }, "args: everything after -- goes to the suite")
    local none, why = ci.parse({ "--frobnicate" })
    eq(none, nil, "args: an unknown argument")
    has(why, "--frobnicate", "args: ... is named")
  end

  -- -------------------------------------------------------- runs on projects

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"
  local cache_dir = tmp .. "/cache"
  local nvim = vim.v.progpath

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end

  ---@param name string
  ---@param ci_lua string The Lua text of the `ci` table.
  ---@param files? table<string, string>
  ---@return string root
  local function project(name, ci_lua, files)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = " .. ci_lua .. " }\n"
    )
    for rel, text in pairs(files or {}) do
      write(root .. "/" .. rel, text)
    end
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  ---@param root string
  ---@param ... string
  ---@return { code: integer, out: string, err: string, last: string }
  local function run(root, ...)
    local out, err = {}, {}
    local argv = { "ci", "--root=" .. root }
    vim.list_extend(argv, { ... })
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      cache_dir = cache_dir,
      color = false,
      affected = { provider = false },
    })
    package.loaded["proj.mod"] = nil
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end
  local function doc_of(root)
    local path = require("testing.state").dir(root, { state_dir = state_dir }) .. "/ci.json"
    return vim.json.decode(read(path))
  end

  local echo = "lua/proj/echo.lua"
  local ECHO =
    "io.stdout:write((_G.arg[1] or '') .. '|' .. (vim.uv.os_getenv('CI_SPEC') or '') .. '\\n')\n"
  local sleeper = "lua/proj/sleep.lua"
  local SLEEP = "vim.wait(60000, function() return false end, 100)\n"
  local exit1 = "lua/proj/exit1.lua"
  local EXIT1 = "io.stderr:write('lua/proj/mod.lua:1:2: a finding\\n')\nos.exit(1)\n"

  local function nv(script, ...)
    local parts = {
      ("%q"):format(nvim),
      '"--headless"',
      '"-u"',
      '"NONE"',
      '"-i"',
      '"NONE"',
      '"-l"',
      ("%q"):format(script),
    }
    for _, a in ipairs({ ... }) do
      parts[#parts + 1] = ("%q"):format(a)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  -- green: two steps, placeholders, env, the sentinel and the document
  do
    local root = project(
      "green",
      ("{ profiles = { full = { 'a', 'b' } }, steps = { a = { run = %s, env = { CI_SPEC = 'yes' } }, b = { run = %s } } }"):format(
        nv(echo, "${root}"),
        nv(echo, "second")
      ),
      { [echo] = ECHO }
    )
    local res = run(root)
    eq(res.code, 0, "green: exit 0 (" .. res.err .. ")")
    eq(res.last, ci.SENTINEL, "green: the sentinel is the last line")
    has(res.out, root .. "|yes", "green: ${root} and the step's env reach the process")
    has(res.out, "second|", "green: the second step ran")
    has(res.out, "ci: GREEN full 2/2", "green: the verdict line")
    local doc = doc_of(root)
    eq(doc.schema, "testing-ci/1", "green: the document")
    eq(doc.verdict, "green", "green: the document's verdict")
    eq(doc.partial, false, "green: not partial")
    eq(doc.dirty, false, "green: a clean tree")
    ok(type(doc.tree) == "string" and #doc.tree == 40, "green: the tree id")
    ok(type(doc.pipeline_sha) == "string" and #doc.pipeline_sha == 64, "green: the pipeline hash")
    eq(#doc.steps, 2, "green: one entry per step")
    eq(doc.steps[1].state, "green", "green: the step's state")
  end

  -- red: fail-fast skips the rest, the finding is in the document; --keep-going runs on
  do
    local root = project(
      "red",
      ("{ profiles = { full = { 'bad', 'after' } }, steps = { bad = { run = %s }, after = { run = %s } } }"):format(
        nv(exit1),
        nv(echo, "after")
      ),
      { [exit1] = EXIT1, [echo] = ECHO }
    )
    local res = run(root)
    eq(res.code, 1, "red: exit 1")
    lacks(res.out, ci.SENTINEL, "red: no sentinel")
    lacks(res.out, "after|", "red: fail-fast, the next step did not run")
    has(res.out, "ci: RED bad", "red: the verdict names the step")
    local doc = doc_of(root)
    eq(doc.verdict, "red", "red: the document")
    eq(doc.first_red, "bad", "red: first_red")
    eq(doc.steps[2].state, "skipped", "red: the rest is skipped")
    has(table.concat(doc.steps[1].errors, "\n"), "a finding", "red: the first error lines")

    res = run(root, "--keep-going")
    eq(res.code, 1, "keep-going: still exit 1")
    has(res.out, "after|", "keep-going: the next step ran")
  end

  -- a missing tool: exit 3 before anything runs, the step and the places are named
  do
    local root = project(
      "missing",
      ("{ profiles = { full = { 'a', 'b' } }, steps = { a = { run = %s }, b = { run = { 'does-not-exist-tool-xyz' } } } }"):format(
        nv(echo, "first")
      ),
      { [echo] = ECHO }
    )
    local res = run(root)
    eq(res.code, 3, "missing: exit 3")
    has(res.err, "step b needs does-not-exist-tool-xyz", "missing: step and tool named")
    has(res.err, "searched", "missing: where it was looked for")
    lacks(res.out, "first|", "missing: nothing ran, not even the steps before")
  end

  -- --step: a partial run, no sentinel; an unknown step and profile are usage errors
  do
    local root = project(
      "partial",
      ("{ profiles = { full = { 'a', 'b' } }, steps = { a = { run = %s }, b = { run = %s } } }"):format(
        nv(echo, "A"),
        nv(echo, "B")
      ),
      { [echo] = ECHO }
    )
    local res = run(root, "--step=b")
    eq(res.code, 0, "partial: exit 0")
    lacks(res.out, "A|", "partial: only the chosen step")
    lacks(res.out, ci.SENTINEL, "partial: never the sentinel")
    has(res.out, "partial", "partial: the verdict line says so")
    eq(doc_of(root).partial, true, "partial: the document says so")
    eq(doc_of(root).verdict, "green-partial", "partial: verdict green-partial")
    eq(run(root, "--step=zz").code, 2, "partial: an unknown step is exit 2")
    eq(run(root, "--profile=zz").code, 2, "partial: an unknown profile is exit 2")
  end

  -- a deadline: the step is red, marked as timed out, and the run ends at about the deadline
  do
    local root = project(
      "timeout",
      ("{ profiles = { full = { 'slow' } }, steps = { slow = { run = %s, timeout = '1500ms' } } }"):format(
        nv(sleeper)
      ),
      { [sleeper] = SLEEP }
    )
    local t0 = vim.uv.hrtime()
    local res = run(root)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    eq(res.code, 1, "timeout: exit 1")
    has(res.out, "timed out after 1500 ms", "timeout: the reason")
    ok(ms < 20000, "timeout: the run ended near the deadline (" .. ms .. " ms)")
  end

  -- when.os: a step for another system is skipped, the run stays green and complete
  do
    local other = require("testing.platform").is_windows() and "linux" or "windows"
    local root = project(
      "os",
      ("{ profiles = { full = { 'here', 'there' } }, steps = { here = { run = %s }, there = { run = { 'does-not-exist-tool-xyz' }, when = { os = { '%s' } } } } }"):format(
        nv(echo, "here"),
        other
      ),
      { [echo] = ECHO }
    )
    local res = run(root)
    eq(res.code, 0, "os: exit 0 (the other system's tool is not needed here)")
    eq(res.last, ci.SENTINEL, "os: complete")
    eq(doc_of(root).steps[2].state, "skipped", "os: the step is skipped")
  end

  -- the suite in-process: green, red, and options after -- reach it
  do
    local PASS = "return function(H)\n  H.ok(require('proj.mod').value == 1, 'the module')\nend\n"
    local FAIL = "return function(H)\n  H.ok(false, 'red on purpose')\nend\n"
    local CFG =
      "{ profiles = { full = { 'suite' } }, steps = { suite = { preset = 'suite', stamp = false } } }"
    local root = project("suite", CFG, { ["TESTS/a_spec.lua"] = PASS })
    local res = run(root)
    eq(res.code, 0, "suite: green (" .. res.err .. ")")
    eq(res.last, ci.SENTINEL, "suite: the sentinel")

    local red =
      project("suite-red", CFG, { ["TESTS/a_spec.lua"] = PASS, ["TESTS/b_spec.lua"] = FAIL })
    res = run(red)
    eq(res.code, 1, "suite: a red case makes the step red")
    has(res.out, "ci: RED suite", "suite: named")

    res = run(red, "--", "--file", "TESTS/a_spec.lua")
    eq(res.code, 0, "suite: options after -- reach the suite (" .. res.err .. ")")
    -- a selection after -- is part of the suite only: the run is partial, never the sentinel
    lacks(res.out, ci.SENTINEL, "suite: a selection after -- prints no sentinel")
    eq(doc_of(red).partial, true, "suite: a selection after -- is a partial run")
    eq(doc_of(red).partial_why, "suite options", "suite: ... and the document says why")
    eq(doc_of(red).suite_args, { "--file", "TESTS/a_spec.lua" }, "suite: the options are recorded")

    res = run(root, "--", "--jobs", "1")
    eq(res.last, ci.SENTINEL, "suite: an option that selects nothing keeps the run complete")
  end

  -- options after -- without a suite step, a timeout on an in-process preset, an unknown dependency in args
  do
    local root = project(
      "nosuite",
      ("{ profiles = { full = { 'a' } }, steps = { a = { run = %s } } }"):format(nv(echo, "a")),
      { [echo] = ECHO }
    )
    local res = run(root, "--", "--jobs", "1")
    eq(res.code, 2, "-- without a suite step: exit 2")
    has(res.err, "no suite step", "-- without a suite step: said so")

    root = project(
      "inproc-timeout",
      "{ profiles = { full = { 's' } }, steps = { s = { preset = 'suite', timeout = '1m' } } }"
    )
    res = run(root)
    eq(res.code, 2, "a timeout on an in-process preset is an error")
    has(res.err, "takes no timeout", "... named")

    root = project(
      "inproc-deps",
      "{ profiles = { full = { 's' } }, steps = { s = { preset = 'suite', stamp = false, args = { '--rtp', '${deps.no-such-dep-xyz}' } } } }",
      { ["TESTS/a_spec.lua"] = "return function(H) H.ok(true, 'x') end\n" }
    )
    res = run(root)
    eq(res.code, 3, "a missing dependency in an in-process step's args is exit 3 before the run")
    has(res.err, "no-such-dep-xyz", "... named")
  end

  -- a relative command below the root (the root is not the current directory) and a `.sh` step
  do
    local root = project(
      "relative",
      "{ profiles = { full = { 'sh' } }, steps = { sh = { run = { 'tools/hello.sh', '${root}' } } } }",
      { ["tools/hello.sh"] = 'echo "hello from $1"\n' }
    )
    local res = run(root)
    eq(res.code, 0, "sh: a .sh step below the root runs (" .. res.err .. ")")
    has(res.out, "hello from " .. root, "sh: through bash, with its arguments")
    eq(
      doc_of(root).os,
      require("testing.platform").is_windows() and "windows" or doc_of(root).os,
      "the document names the system"
    )
  end

  -- the transitional .ci-last.json: written only where git ignores it (the tree never becomes dirty)
  do
    local CFG = ("{ profiles = { full = { 'a' } }, steps = { a = { run = %s } } }"):format(
      nv(echo, "x")
    )
    local plain = project("legacy-off", CFG, { [echo] = ECHO })
    eq(run(plain).code, 0, "legacy: green")
    eq(
      vim.uv.fs_stat(plain .. "/.ci-last.json"),
      nil,
      "legacy: not written when git does not ignore it"
    )
    local ignored = project("legacy-on", CFG, { [echo] = ECHO, [".gitignore"] = ".ci-last.json\n" })
    eq(run(ignored).code, 0, "legacy: green")
    local legacy = vim.json.decode(read(ignored .. "/.ci-last.json"))
    eq(legacy.state, "green", "legacy: the old format's state")
    eq(legacy.dirty, false, "legacy: the tree is still clean")
  end

  -- configuration errors: no section, a bad section
  do
    local root = tmp .. "/nosection"
    write(root .. "/.testing.lua", "return { plugin = 'proj' }\n")
    local res = run(root)
    eq(res.code, 2, "no ci section: exit 2")
    has(res.err, "no `ci` section", "no ci section: said so")
    root = project("badsection", "{ profiles = { full = { 'nope' } } }")
    res = run(root)
    eq(res.code, 2, "bad section: exit 2")
    has(res.err, '"nope" is neither', "bad section: the problem")
    root = project("notatable", "5")
    res = run(root)
    eq(res.code, 2, "ci = 5: exit 2")
    lacks(res.err, "no `ci` section", "ci = 5: not reported as a missing section")
    has(res.err, "'ci'", "ci = 5: the key is named")
    eq(run(root, "--step=").code, 2, "an empty --step is a usage error")
  end

  vim.fn.delete(tmp, "rf")
end
