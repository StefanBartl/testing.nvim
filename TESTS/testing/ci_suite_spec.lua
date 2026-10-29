-- TESTS/testing/ci_suite_spec.lua -- `testing ci` with the suite as an in-process step: green, red, options after --
-- (a selection makes the run partial, a stamping step then runs as a plain run), --state-dir for the document and the
-- stamp, a suite whose own verdict is green-partial. Split off ci_spec.lua for the per-file deadline; same helpers.

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

    -- --suite-events: the suite writes its events there (a UI shows the run from them), and the run stays complete
    do
      local evfile = tmp .. "/suite-events.ndjson"
      local ev_root = project("suite-events", CFG, { ["TESTS/a_spec.lua"] = PASS })
      local ev_res = run(ev_root, "--suite-events=" .. evfile)
      eq(ev_res.code, 0, "suite-events: green (" .. ev_res.err .. ")")
      eq(ev_res.last, ci.SENTINEL, "suite-events: still a complete run with the sentinel")
      eq(doc_of(ev_root).partial, false, "suite-events: not partial")
      local body = read(evfile) or ""
      has(body, '"event":"run_start"', "suite-events: the plan of the run")
      has(body, '"event":"file_end"', "suite-events: a file ended")
      has(body, '"event":"run_done"', "suite-events: the run is done")
      local none = project(
        "no-suite",
        "{ profiles = { full = { 'lint' } }, steps = { lint = { run = { 'x' } } } }"
      )
      local none_res = run(none, "--suite-events=" .. tmp .. "/never.ndjson", "--step=nope")
      ok(none_res.code ~= 0, "suite-events: an unknown step is still an error")
    end

    -- the suite runs in a throwaway state and cache directory, and the stamp still lands in the real one
    do
      local seen = tmp .. "/iso-seen.txt"
      local SPEC = ("return function(H)\n  local f = assert(io.open(%q, 'wb'))\n  f:write(vim.fn.stdpath('state'), '\\n', vim.fn.stdpath('cache'))\n  f:close()\n  H.ok(true, 'seen')\nend\n"):format(
        seen
      )
      local iso = project("suite-iso", CFG, { ["TESTS/a_spec.lua"] = SPEC })
      local outer_state, outer_cache = vim.fn.stdpath("state"), vim.fn.stdpath("cache")
      local iso_res = run(iso)
      eq(iso_res.code, 0, "suite isolation: green (" .. iso_res.err .. iso_res.out .. ")")
      local lines = vim.split(read(seen) or "", "\n", { plain = true })
      ok(
        lines[1] and lines[1] ~= outer_state,
        "suite isolation: the spec saw another state directory"
      )
      ok(lines[2] and lines[2] ~= outer_cache, "suite isolation: ... and another cache directory")
      ok(
        vim.fn.isdirectory(vim.fs.dirname(lines[1] or "")) == 0,
        "suite isolation: the scratch directory is removed afterwards"
      )
      eq(
        vim.fn.stdpath("state"),
        outer_state,
        "suite isolation: the outer state directory is restored"
      )
      -- the stamp of a stamping step is written below the real state directory, not the scratch one
      local stamped = project(
        "suite-iso-stamp",
        "{ profiles = { full = { 'suite' } } }",
        { ["TESTS/a_spec.lua"] = PASS }
      )
      local stamp_res = run(stamped)
      eq(stamp_res.code, 0, "suite isolation: a stamping run is green (" .. stamp_res.err .. ")")
      ok(
        vim.uv.fs_stat(require("testing.stamp").path(stamped, { state_dir = state_dir })) ~= nil,
        "suite isolation: the stamp is written below the real state directory"
      )
    end

    local red =
      project("suite-red", CFG, { ["TESTS/a_spec.lua"] = PASS, ["TESTS/b_spec.lua"] = FAIL })
    res = run(red)
    eq(res.code, 1, "suite: a red case makes the step red")
    has(res.out, "ci: RED suite", "suite: named")
    -- the findings come from the suite's Result-IR, whatever reporter the inner run printed
    local sdoc = doc_of(red).steps[1]
    eq(sdoc.findings_total, 1, "suite: one finding from the IR")
    eq(sdoc.findings[1].file, "TESTS/b_spec.lua", "suite: at the red spec")
    has(sdoc.findings[1].text, "red on purpose", "suite: with the assertion's message")

    res = run(red, "--", "--file", "TESTS/a_spec.lua")
    eq(res.code, 0, "suite: options after -- reach the suite (" .. res.err .. ")")
    -- a selection after -- is part of the suite only: the run is partial, never the sentinel
    lacks(res.out, ci.SENTINEL, "suite: a selection after -- prints no sentinel")
    eq(doc_of(red).partial, true, "suite: a selection after -- is a partial run")
    eq(doc_of(red).partial_why, "suite options", "suite: ... and the document says why")
    eq(doc_of(red).suite_args, { "--file", "TESTS/a_spec.lua" }, "suite: the options are recorded")

    res = run(root, "--", "--jobs", "1")
    eq(res.last, ci.SENTINEL, "suite: an option that selects nothing keeps the run complete")

    -- a stamping suite step (the default) with a selection after --: a plain run (a stamp refuses a selection
    -- with exit 2), the run is partial
    local stamping = project(
      "suite-stamp",
      "{ profiles = { full = { 'suite' } } }",
      { ["TESTS/a_spec.lua"] = PASS, ["TESTS/b_spec.lua"] = FAIL }
    )
    res = run(stamping, "--", "--file", "TESTS/a_spec.lua")
    eq(res.code, 0, "stamp + selection: the selected run, not a refused stamp (" .. res.err .. ")")
    eq(doc_of(stamping).partial, true, "stamp + selection: partial")
    res = run(stamping, "--", "--file", "TESTS/b_spec.lua")
    eq(res.code, 1, "stamp + selection: a red selected file is red, not a usage error")

    -- --state-dir: the document and the suite's stamp go there (a wrapper that isolates the suite's state)
    local other = tmp .. "/real-state"
    local green_only =
      project("state-dir", "{ profiles = { full = { 'suite' } } }", { ["TESTS/a_spec.lua"] = PASS })
    res = run(green_only, "--state-dir=" .. other)
    eq(res.code, 0, "state-dir: green (" .. res.err .. ")")
    local st = require("testing.state")
    ok(
      vim.uv.fs_stat(st.dir(green_only, { state_dir = other }) .. "/ci.json") ~= nil,
      "state-dir: the document is there"
    )
    ok(
      vim.uv.fs_stat(require("testing.stamp").path(green_only, { state_dir = other })) ~= nil,
      "state-dir: the stamp is there"
    )
    eq(
      vim.uv.fs_stat(st.dir(green_only, { state_dir = state_dir }) .. "/ci.json"),
      nil,
      "state-dir: not in the services' state directory"
    )

    -- options after -- that run no suite are refused
    eq(run(root, "--", "--cache-clear").code, 2, "-- --cache-clear: exit 2")
    eq(run(root, "--", "--help").code, 2, "-- --help: exit 2")
  end

  -- a suite whose own verdict is green-partial (a skipped case): the ci run is partial, no sentinel
  do
    local SKIP = table.concat({
      "describe('s', function()",
      "  it('a', function() assert.is_true(true) end)",
      "  pending('later')",
      "end)",
      "",
    }, "\n")
    local root = project(
      "suite-partial",
      "{ profiles = { full = { 'suite' } }, steps = { suite = { preset = 'suite', stamp = false } } }",
      { ["TESTS/s_spec.lua"] = SKIP }
    )
    local res = run(root)
    eq(res.code, 0, "suite green-partial: exit 0 (" .. res.err .. ")")
    lacks(res.out, ci.SENTINEL, "suite green-partial: no sentinel")
    eq(doc_of(root).partial, true, "suite green-partial: the run is partial")
    has(tostring(doc_of(root).partial_why), "suite green-partial", "suite green-partial: said why")
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

  vim.fn.delete(tmp, "rf")
end
