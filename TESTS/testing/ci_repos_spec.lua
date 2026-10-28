-- TESTS/testing/ci_repos_spec.lua -- `testing ci --repos`: the arguments, which repositories (explicit, file, root with
-- cached detection, include/exclude), the scheduling (verify first, --force, --jobs) through a fake process, the table
-- and the exit code, and one real run over two temporary repositories (one green, one red; the second run skips the
-- proven one).

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

  local repos = require("testing.ci.repos")
  local ci = require("testing.ci")
  local cli = require("testing.cli")

  -- ------------------------------------------------------------------ arguments

  do
    eq(repos.wanted({ "--profile=fast" }), false, "wanted: a plain run")
    eq(repos.wanted({ "--repos=a" }), true, "wanted: --repos")
    eq(repos.wanted({ "--repos-root", "x" }), true, "wanted: --repos-root")
    eq(repos.wanted({ "--", "--repos-x" }), false, "wanted: not after --")

    local a = repos.parse({
      "--repos=a,b",
      "--repos-root",
      "/r",
      "--repos-root=/s",
      "--repos-include=x,y",
      "--repos-exclude=z",
      "--force",
      "--jobs=3",
      "--profile=fast",
      "--keep-going",
      "--reuse",
      "--refresh",
      "--state-dir=/st",
    })
    eq(a.repos, { "a", "b" }, "args: --repos")
    eq(a.roots, { "/r", "/s" }, "args: --repos-root is repeatable")
    eq({ a.include, a.exclude }, { { "x", "y" }, { "z" } }, "args: include and exclude")
    eq(
      { a.force, a.jobs, a.profile, a.keep_going, a.reuse, a.refresh, a.state_dir },
      { true, 3, "fast", true, true, true, "/st" },
      "args: the flags"
    )
    local none, why = repos.parse({ "--jobs=0" })
    eq(none, nil, "args: --jobs=0")
    has(why, "1 to 16", "args: ... is named")
    none, why = repos.parse({ "--frobnicate" })
    eq(none, nil, "args: an unknown argument")
    has(why, "--frobnicate", "args: ... is named")
    none = repos.parse({ "--repos" })
    eq(none, nil, "args: --repos needs a value")
  end

  -- ------------------------------------------------------------------ temporary repositories

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-repos"
  vim.fn.mkdir(tmp, "p")
  local nvim = vim.v.progpath
  local state = tmp .. "/state"

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
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

  ---A repository whose pipeline has one step: a script that exits with `exit_code`.
  ---@param dir string
  ---@param exit_code integer
  local function repo(dir, exit_code)
    write(dir .. "/step.lua", ("os.exit(%d)\n"):format(exit_code))
    write(
      dir .. "/.testing.lua",
      "return { plugin = 'p', minit = false, ci = { profiles = { full = { 'step' } }, steps = { step = { run = { "
        .. ("%q"):format(nvim)
        .. ", '--headless', '-u', 'NONE', '-i', 'NONE', '-l', 'step.lua' } } } } }\n"
    )
    git(dir, "init", "-q")
    git(dir, "symbolic-ref", "HEAD", "refs/heads/main")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "init")
  end

  -- ------------------------------------------------------------------ which repositories

  do
    local root = tmp .. "/root"
    write(root .. "/a/.testing.lua", "return { ci = {} }\n")
    write(root .. "/b/.testing.lua", "return { plugin = 'b' }\n")
    write(root .. "/c/.testing.lua", "-- ci = nothing here, only a comment\nreturn {}\n")
    write(root .. "/d/.testing.lua", "return {\n  plugin = 'd',\n  ci = { profiles = {} },\n}\n")
    write(root .. "/.hidden/.testing.lua", "return { ci = {} }\n")
    write(root .. "/plain.txt", "x")
    eq(repos.has_ci(root .. "/a"), true, "has_ci: a ci key")
    eq(repos.has_ci(root .. "/b"), false, "has_ci: no ci key")
    eq(repos.has_ci(root .. "/c"), false, "has_ci: a comment is not a key")
    eq(repos.has_ci(root .. "/d"), true, "has_ci: a ci key in a long table")
    eq(repos.has_ci(root .. "/missing"), false, "has_ci: no file")
    local function ci_of(text)
      write(root .. "/t/.testing.lua", text)
      return repos.has_ci(root .. "/t")
    end
    eq(
      ci_of("return { url = 'a--b', ci = {} }\n"),
      true,
      "has_ci: a -- inside a string before the key"
    )
    eq(ci_of("return { ['ci'] = {} }\n"), true, "has_ci: a bracketed key")
    eq(ci_of("return {\n  plugin = 'p',\n  ci = {},\n}\n"), true, "has_ci: a key on its own line")
    eq(ci_of("--[[ a block\n ci = {}\n]] return {}\n"), false, "has_ci: a multi-line block comment")
    eq(ci_of("return { x = { ci = {} } }\n"), false, "has_ci: a nested key is not the section")
    eq(ci_of("return { note = 'x, ci = 1' }\n"), false, "has_ci: ci = inside a string")
    eq(ci_of("return { ci == 1 }\n"), false, "has_ci: a comparison is not a key")

    local cache = tmp .. "/cache.json"
    local function resolve(args)
      local parsed = repos.parse(args)
      return repos.resolve(parsed, cache)
    end
    local found = resolve({ "--repos-root=" .. root })
    eq(
      found,
      { root .. "/a", root .. "/d" },
      "resolve: the directories below a root that have a ci section"
    )

    write(root .. "/e/.testing.lua", "return { ci = {} }\n")
    found = resolve({ "--repos-root=" .. root })
    eq(#found, 2, "resolve: the detection is cached, a new repository is not seen")
    found = resolve({ "--repos-root=" .. root, "--refresh" })
    eq(#found, 3, "resolve: --refresh finds it")
    os.remove(root .. "/e/.testing.lua")
    found = resolve({ "--repos-root=" .. root })
    eq(#found, 2, "resolve: a cached directory that lost its section is dropped")

    found = resolve({ "--repos-root=" .. root, "--repos-exclude=a" })
    eq(found, { root .. "/d" }, "resolve: exclude")
    found = resolve({ "--repos-root=" .. root, "--repos-include=d" })
    eq(found, { root .. "/d" }, "resolve: include narrows")
    found = resolve({ "--repos-root=" .. root, "--repos-include=a,nope" })
    eq(
      found,
      { root .. "/a", root .. "/nope" },
      "resolve: an included name that does not exist is still asked for"
    )
    -- several roots: an included name found in one root is not asked for in the others
    local root2 = tmp .. "/root2"
    write(root2 .. "/z/.testing.lua", "return { ci = {} }\n")
    found = resolve({ "--repos-root=" .. root, "--repos-root=" .. root2, "--repos-include=a,z" })
    eq(
      found,
      { root .. "/a", root2 .. "/z" },
      "resolve: include over several roots, no phantom repository"
    )
    found = resolve({ "--repos-root=" .. root, "--repos-root=" .. root2, "--repos-include=z,nope" })
    eq(found, { root2 .. "/z", root .. "/nope" }, "resolve: a name in no root is asked for once")
    -- $VAR is expanded before the path is made absolute
    vim.env.TESTING_CI_REPOS_ROOT = root
    found = resolve({ "--repos=$TESTING_CI_REPOS_ROOT/a" })
    eq(found, { root .. "/a" }, "resolve: $VAR in --repos")
    write(tmp .. "/envlist.txt", "$TESTING_CI_REPOS_ROOT/b\n")
    found = resolve({ "--repos-file=" .. tmp .. "/envlist.txt" })
    eq(found, { root .. "/b" }, "resolve: $VAR in a list file")
    write(tmp .. "/list.txt", "# my repos\n" .. root .. "/b\n\n" .. root .. "/a  # again\n")
    found = resolve({ "--repos-file=" .. tmp .. "/list.txt", "--repos=" .. root .. "/a" })
    eq(
      found,
      { root .. "/a", root .. "/b" },
      "resolve: a list file, comments dropped, no duplicates"
    )
    local none, why = resolve({})
    eq(none, nil, "resolve: nothing named")
    has(why, "no repository", "resolve: ... says so")
    none, why = resolve({ "--repos-root=" .. tmp .. "/absent" })
    eq(none, nil, "resolve: a root that is not a directory")
    has(why, "not a directory", "resolve: ... says so")
  end

  -- ------------------------------------------------------------------ scheduling through a fake process

  local function run(args, system)
    local out, err = {}, {}
    local real = repos.system
    repos.system = system or real
    local pass, code = pcall(cli.main, vim.list_extend({ "ci" }, args), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
    })
    repos.system = real
    if not pass then
      error(code, 0)
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n"), lines = out }
  end

  do
    local seen, active, peak = {}, 0, 0
    ---Each child ends a moment later, with the code `codes[<repo>][<kind>]` (default 0).
    local function fake(codes)
      return function(argv, opts, on_exit)
        local kind, dir = "run", nil
        for _, a in ipairs(argv) do
          kind = a == "verify" and "verify" or kind
          dir = a:match("^%-%-root=(.*)$") or dir
        end
        local name = vim.fs.basename(dir)
        seen[#seen + 1] = name .. ":" .. kind
        active = active + 1
        peak = math.max(peak, active)
        opts.stdout(nil, kind .. " of " .. name .. "\npartial")
        vim.defer_fn(function()
          active = active - 1
          on_exit({ code = (codes[name] or {})[kind] or 0, stdout = "", stderr = "" })
        end, 40)
        return {}
      end
    end

    -- verify first; a proven repository is not run; a not proven one is; the worst code is the exit code
    local res = run(
      { "--repos=" .. tmp .. "/p,q,r", "--profile=fast", "--keep-going", "--reuse" },
      fake({ p = { verify = 0 }, q = { verify = 1 }, r = { verify = 1, run = 1 } })
    )
    eq(res.code, 1, "fake: the worst result decides (r is red)")
    has(table.concat(seen, " "), "p:verify", "fake: verify comes first")
    ok(not table.concat(seen, " "):find("p:run", 1, true), "fake: a proven repository is not run")
    has(table.concat(seen, " "), "r:verify r:run", "fake: a repository that is not proven is run")
    has(res.out, "p | verify of p", "fake: output lines carry the repository's name")
    has(res.out, "r | partial", "fake: the last unfinished line is flushed")
    ok(res.out:find("p  *proven *skipped") ~= nil, "fake: the table says proven\n" .. res.out)
    has(res.out, "ci repos: RED 2/3 (1 proven, not run)", "fake: the verdict line")
    ok(res.lines[#res.lines] ~= ci.SENTINEL, "fake: no sentinel after a red run")

    -- the options reach the children
    seen = {}
    local argvs = {}
    run({
      "--repos=" .. tmp .. "/x",
      "--profile=fast",
      "--keep-going",
      "--reuse",
      "--state-dir=" .. tmp .. "/s",
    }, function(argv, opts, on_exit)
      argvs[#argvs + 1] = table.concat(argv, " ")
      vim.defer_fn(function()
        on_exit({ code = argvs[#argvs]:find(" verify ", 1, true) and 1 or 0 })
      end, 10)
      return {}
    end)
    has(
      argvs[1],
      " ci verify --profile=fast --state-dir=" .. tmp .. "/s --root=",
      "fake: verify gets the profile and the state dir"
    )
    has(argvs[2], "--no-agent", "fake: the run is quiet")
    has(argvs[2], "--keep-going --reuse", "fake: the run gets its flags")
    has(argvs[2], "--profile=fast", "fake: ... and the profile")

    -- --force does not ask verify
    seen = {}
    res = run({ "--repos=" .. tmp .. "/p,q", "--force" }, fake({}))
    eq(seen, { "p:run", "q:run" }, "fake: --force runs without verify, in order")
    has(res.out, "forced", "fake: the table says forced")
    eq(res.code, 0, "fake: all green is exit 0")
    eq(res.lines[#res.lines], ci.SENTINEL, "fake: the sentinel after a green run")

    -- --jobs: at most that many at the same time, all of them done
    seen, active, peak = {}, 0, 0
    run({ "--repos=a,b,c,d,e", "--force", "--jobs=2" }, fake({}))
    eq(peak, 2, "fake: --jobs=2 runs two at a time")
    eq(#seen, 5, "fake: every repository ran")
    seen, active, peak = {}, 0, 0
    run({ "--repos=a,b,c", "--force" }, fake({}))
    eq(peak, 1, "fake: the default is one at a time")

    -- infrastructure and usage
    res = run({ "--repos=a,b", "--force" }, fake({ a = { run = 3 }, b = { run = 1 } }))
    eq(res.code, 3, "fake: infrastructure outranks red")
    has(res.out, "INFRA", "fake: ... in the verdict")
    res = run({ "--repos=a", "--force" }, function()
      error("no such program")
    end)
    eq(res.code, 3, "fake: a process that cannot start is exit 3")
    has(res.err, "cannot start a process for a", "fake: ... named")
    -- a process that cannot start is infrastructure on the verify path, too
    res = run({ "--repos=a" }, function()
      error("no such program")
    end)
    eq(res.code, 3, "fake: a verify that cannot start is exit 3")

    -- a child killed by a signal reports code 0 with a signal: infrastructure, never proven or green
    res = run({ "--repos=a" }, function(_, _, on_exit)
      vim.defer_fn(function()
        on_exit({ code = 0, signal = 9, stdout = "", stderr = "" })
      end, 10)
      return {}
    end)
    eq(res.code, 3, "fake: a signal exit is exit 3, not proven")
    ok(res.out:find("INFRA", 1, true) ~= nil, "fake: ... INFRA in the verdict")
    ok(res.lines[#res.lines] ~= ci.SENTINEL, "fake: no sentinel after a signal exit")

    -- --jobs>1 with mixed codes: every repository finishes, the worst decides
    seen, active, peak = {}, 0, 0
    res = run(
      { "--repos=a,b,c,d", "--force", "--jobs=3" },
      fake({ a = { run = 1 }, b = { run = 0 }, c = { run = 2 }, d = { run = 0 } })
    )
    eq(#seen, 4, "fake: --jobs=3 with mixed codes: all ran")
    eq(res.code, 2, "fake: --jobs=3 with mixed codes: the worst decides")
    has(res.out, "ci repos: ERROR 2/4", "fake: ... and the tally counts the green ones")
    res = run({ "--repos-root=" .. tmp .. "/absent" })
    eq(res.code, 2, "usage: a missing root is exit 2")
    eq(run({ "--repos" }).code, 2, "usage: --repos without a value is exit 2")
  end

  -- ------------------------------------------------------------------ real children

  do
    local green, red = tmp .. "/real/green", tmp .. "/real/red"
    repo(green, 0)
    repo(red, 1)
    local args = { "--repos-root=" .. tmp .. "/real", "--state-dir=" .. state, "--profile=full" }
    local res = run(args)
    eq(res.code, 1, "real: one red repository makes the run red (" .. res.err .. ")")
    has(res.out, "green | ", "real: lines of the green repository")
    has(res.out, "red   | ", "real: lines of the red repository")
    ok(
      res.out:find("green  *not proven *green") ~= nil,
      "real: green ran and is green\n" .. res.out
    )
    ok(res.out:find("red  *not proven *red") ~= nil, "real: red ran and is red\n" .. res.out)

    res = run(args)
    eq(res.code, 1, "real: the second run is still red")
    ok(
      res.out:find("green  *proven *skipped") ~= nil,
      "real: the green repository is proven now, not run\n" .. res.out
    )
    ok(res.out:find("red  *not proven *red") ~= nil, "real: the red one runs again")

    res = run({ "--repos=" .. green, "--state-dir=" .. state, "--profile=full", "--force" })
    eq(res.code, 0, "real: --force runs the proven repository: green")
    ok(
      res.out:find("green  *forced *green") ~= nil,
      "real: ... and the table says forced\n" .. res.out
    )
    eq(res.lines[#res.lines], ci.SENTINEL, "real: the sentinel after a green run")
  end

  vim.env.TESTING_CI_REPOS_ROOT = nil
  vim.fn.delete(tmp, "rf")
end
