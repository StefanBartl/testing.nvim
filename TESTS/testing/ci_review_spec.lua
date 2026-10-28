-- TESTS/testing/ci_review_spec.lua -- `testing ci`, the cases of the review of 2026-10-28 (a suite is green only with its Result-IR,
-- presets that cannot drop their gate, a failed report is exit 3, the per-profile document, an early stop that
-- still writes its document, a tree a step changed, ...). Split off ci_spec.lua for the per-file deadline; the
-- helpers are the same.

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
    git(root, "init", "-q")
    git(root, "symbolic-ref", "HEAD", "refs/heads/main")
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

  -- ------------------------------------------------ review fixes (2026-10-28)

  local FAIL2 = "return function(H)\n  H.ok(false, 'red on purpose')\nend\n"

  -- an in-process suite is green only when its Result-IR says so: exit 0 without a result is infra, and a result
  -- file left from an earlier run is not this run's
  do
    local root = project(
      "no-ir",
      "{ profiles = { full = { 'suite' } }, steps = { suite = { preset = 'suite', stamp = false } } }",
      { ["TESTS/a_spec.lua"] = FAIL2 }
    )
    local cli_mod = require("testing.cli")
    local real_main = cli_mod.main
    local stale = tmp .. "/stale-ir.json"
    write(stale, vim.json.encode({ run = { verdict = { kind = "green" } }, cases = {} }))
    cli_mod.main = function(argv, services)
      if argv[1] == "run" then
        return 0 -- like `--help`: exit 0, no result written
      end
      return real_main(argv, services)
    end
    local res1 = run(root)
    local res2 = run(root, "--", "--json", stale)
    cli_mod.main = real_main
    eq(res1.code, 3, "no IR: exit 0 without a result is infra, not green")
    lacks(res1.out, ci.SENTINEL, "no IR: no sentinel")
    has(res1.out, "wrote no result", "no IR: said why")
    eq(res2.code, 3, "stale IR: the old file is not this run's result")
  end

  -- a suite step whose args run no suite is refused before anything runs
  do
    local root = project(
      "suite-help",
      "{ profiles = { full = { 'suite' } }, steps = { suite = { preset = 'suite', args = { '--help' } } } }",
      { ["TESTS/a_spec.lua"] = FAIL2 }
    )
    local res = run(root)
    eq(res.code, 2, "suite args --help: exit 2")
    has(res.err, "runs no suite", "suite args --help: said why")
    eq(run(root, "--", "--list").code, 2, "-- --list: exit 2")
  end

  -- presets: stylua keeps --check whatever args says, conformance is a gate
  do
    local p = schema.resolve({
      profiles = { full = { "s", "conformance" } },
      steps = { s = { preset = "stylua", args = { "lua" } } },
    })
    eq(p.steps.s.argv, { "stylua", "--check", "lua" }, "stylua: args never drop --check")
    eq(p.steps.conformance.argv, { "--gate" }, "conformance: a gate by default")
  end

  -- a report that cannot be written is exit 3, and no sentinel
  do
    local root = project(
      "junit-fail",
      ("{ profiles = { full = { 'a' } }, steps = { a = { run = %s } } }"):format(nv(echo, "x")),
      { [echo] = ECHO }
    )
    write(tmp .. "/afile", "a file, not a directory\n")
    local res = run(root, "--junit=" .. tmp .. "/afile/x.xml")
    eq(res.code, 3, "junit write failure: exit 3")
    lacks(res.out, ci.SENTINEL, "junit write failure: no sentinel")
    eq(doc_of(root).verdict, "infra", "junit write failure: the document says so")
  end

  -- a stamping suite (the default) that is green-partial: the run is partial, not red
  do
    local SKIP = table.concat({
      "describe('s', function()",
      "  it('a', function() assert.is_true(true) end)",
      "  pending('later')",
      "end)",
      "",
    }, "\n")
    local root = project(
      "stamp-partial",
      "{ profiles = { full = { 'suite' } } }",
      { ["TESTS/s_spec.lua"] = SKIP }
    )
    local res = run(root)
    eq(res.code, 0, "stamp + green-partial: exit 0 (" .. res.err .. ")")
    lacks(res.out, ci.SENTINEL, "stamp + green-partial: no sentinel")
    eq(doc_of(root).partial, true, "stamp + green-partial: partial")
    has(
      tostring(doc_of(root).steps[1].reason),
      "no stamp",
      "stamp + green-partial: no stamp, said why"
    )
  end

  -- ci-<profile>.json is the last complete run of a profile: a --step run does not replace it
  do
    local root = project(
      "per-profile",
      ("{ profiles = { full = { 'a', 'b' } }, steps = { a = { run = %s }, b = { run = %s } } }"):format(
        nv(echo, "A"),
        nv(echo, "B")
      ),
      { [echo] = ECHO }
    )
    eq(run(root).code, 0, "per-profile: green")
    local dir = require("testing.state").dir(root, { state_dir = state_dir })
    local full = vim.json.decode(read(dir .. "/ci-full.json"))
    eq(full.partial, false, "per-profile: ci-full.json is the complete run")
    eq(run(root, "--step=a").code, 0, "per-profile: a --step run")
    eq(
      vim.json.decode(read(dir .. "/ci-full.json")).partial,
      false,
      "per-profile: --step did not replace it"
    )
    eq(
      vim.json.decode(read(dir .. "/ci.json")).partial,
      true,
      "per-profile: ci.json is the last run"
    )
  end

  -- a run that stops before its first step still writes its document and its agent verdict
  do
    local root = project(
      "early",
      "{ profiles = { full = { 'b' } }, steps = { b = { run = { 'does-not-exist-tool-xyz' } } } }"
    )
    local res = run(root, "--agent")
    eq(res.code, 3, "early: exit 3")
    has(vim.split(res.out, "\n")[1], "ci INFRA", "early: the agent's first line is the verdict")
    local doc = doc_of(root)
    eq(doc.verdict, "infra", "early: the document")
    has(table.concat(doc.problems, "\n"), "does-not-exist-tool-xyz", "early: with the problem")
  end

  -- every step skipped for this system: partial, no sentinel
  do
    local other = require("testing.platform").is_windows() and "linux" or "windows"
    local root = project(
      "all-skipped",
      ("{ profiles = { full = { 'x' } }, steps = { x = { run = %s, when = { os = { '%s' } } } } }"):format(
        nv(echo, "x"),
        other
      ),
      { [echo] = ECHO }
    )
    local res = run(root)
    eq(res.code, 0, "all skipped: exit 0")
    lacks(res.out, ci.SENTINEL, "all skipped: no sentinel")
    has(tostring(doc_of(root).partial_why), "no step ran", "all skipped: said why")
  end

  -- a step that changes the tree: partial, no sentinel
  do
    local touch = "lua/proj/touch.lua"
    local root = project(
      "tree-changed",
      ("{ profiles = { full = { 't' } }, steps = { t = { run = %s } } }"):format(nv(touch)),
      {
        [touch] = "local f = assert(io.open('lua/proj/mod.lua', 'ab')); f:write('-- touched\\n'); f:close()\n",
      }
    )
    local res = run(root)
    eq(res.code, 0, "tree changed: exit 0")
    lacks(res.out, ci.SENTINEL, "tree changed: no sentinel")
    eq(doc_of(root).tree_changed, true, "tree changed: the document says so")
  end

  -- arguments and pipeline checks
  do
    local none, why = ci.parse({ "--step", "--keep-going" })
    eq(none, nil, "parse: an option is no value")
    has(why, "needs a value", "parse: said so")
    has(
      problems_of({
        profiles = { full = { "s" } },
        steps = { s = { run = { "x" }, env = { Path = "a", PATH = "b" } } },
      }),
      "differ only in case",
      "schema: env names that differ only in case"
    )
    local root = project(
      "outside",
      "{ profiles = { full = { 'o' } }, steps = { o = { run = { '../escape.sh' } } } }"
    )
    local res = run(root)
    eq(res.code, 2, "outside the root: exit 2")
    has(res.err, "outside the root", "outside the root: said so")
    if require("testing.platform").is_windows() then
      local bat = project(
        "bat-meta",
        "{ profiles = { full = { 'b' } }, steps = { b = { run = { 'tools/x.bat', 'a&b' } } } }",
        { ["tools/x.bat"] = "@echo %1\r\n" }
      )
      res = run(bat)
      eq(res.code, 2, "a batch file with a cmd.exe metacharacter in an argument: exit 2")
      has(res.err, "cmd.exe", "... said why")
    end
  end

  vim.fn.delete(tmp, "rf")
end
