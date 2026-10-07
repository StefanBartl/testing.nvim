-- TESTS/testing/affected_git_spec.lua -- the git side of the affected selection: argv only (never a shell),
-- revisions validated before they reach git, NUL-separated output, renames counted on both sides, a real
-- repository end to end, and the freshness check of module_map.json (`testing doctor`).

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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local git = require("testing.affected.git")
  local affected = require("testing.affected")

  -- ---------------------------------------------------------------- revisions
  for _, good in ipairs({
    "HEAD",
    "HEAD~1",
    "HEAD^",
    "origin/main",
    "v1.2.3",
    "@{upstream}",
    "a1b2c3d",
  }) do
    eq(git.valid_ref(good), true, good .. " is a revision")
  end
  for _, bad in ipairs({
    "",
    "-x",
    "--output=/tmp/x",
    "--upload-pack=sh",
    "a..b",
    "a...b",
    "HEAD; rm -rf /",
    "HEAD && x",
    "$(x)",
    "`x`",
    "a b",
    "a\nb",
    "a|b",
    "a'b",
    'a"b',
    string.rep("a", 300),
  }) do
    eq(git.valid_ref(bad), false, vim.inspect(bad):sub(1, 30) .. " is no revision")
  end
  eq(git.valid_ref(nil), false, "nil")
  eq(git.valid_ref(5), false, "a number")

  -- ---------------------------------------------------------------- flags
  eq({ affected.mode_from_flags({ changed = true }) }, { "changed" }, "--changed")
  eq({ affected.mode_from_flags({ since = "v1" }) }, { "since", "v1" }, "--since")
  eq({ affected.mode_from_flags({ affected = true }) }, { "affected" }, "--affected")
  eq(
    { affected.mode_from_flags({ affected = "main" }) },
    { "affected", "main" },
    "--affected <rev>"
  )
  eq({ affected.mode_from_flags({}) }, {}, "no flag, no selection")
  has(
    select(3, affected.mode_from_flags({ changed = true, since = "x" })),
    "exclude each other",
    "two flags"
  )
  has(
    select(3, affected.mode_from_flags({ since = "--output=x" })),
    "--since",
    "a hostile revision"
  )
  has(
    select(3, affected.mode_from_flags({ affected = "a b" })),
    "--affected",
    "a hostile revision (2)"
  )

  -- ---------------------------------------------------------------- argv safety with a recording runner
  local calls
  local function recorder(diff_out)
    calls = {}
    return function(argv, cwd)
      calls[#calls + 1] = { argv = argv, cwd = cwd }
      if argv[2] == "diff" then
        return { code = 0, stdout = diff_out or "", stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end
  end
  local files, err =
    git.changed("/some/root", { mode = "since", since = "--output=/tmp/pwn", run = recorder() })
  eq(files, nil, "a hostile revision is refused")
  has(err, "must not start", "with a reason")
  eq(#calls, 0, "git was never started")
  err = select(2, git.changed("/r", { mode = "since", since = "HEAD; touch x", run = recorder() }))
  has(err, "characters", "a shell metacharacter")
  eq(#calls, 0, "git was never started (2)")
  err = select(2, git.changed("/r", { mode = "since", run = recorder() }))
  has(err, "empty", "since without a revision")
  ---@diagnostic disable-next-line: assign-type-mismatch
  err = select(2, git.changed("/r", { mode = "bogus", run = recorder() }))
  has(err, "unknown mode", "an unknown mode")

  files = git.changed("/some/root", { mode = "since", since = "v1.0", run = recorder("a.lua\0") })
  eq(files, { "a.lua" }, "a valid revision runs")
  eq(#calls, 3, "verify, diff, untracked")
  for _, c in ipairs(calls) do
    eq(c.cwd, "/some/root", "cwd is the root, not a -C that a path could spoof")
    eq(c.argv[1], "git", "the executable is a fixed word")
    for _, a in ipairs(c.argv) do
      eq(type(a), "string", "every argument is a string of its own")
    end
  end
  local diff = calls[2].argv
  eq(diff[2], "diff", "diff")
  ok(vim.tbl_contains(diff, "-z"), "NUL separated")
  ok(vim.tbl_contains(diff, "--no-renames"), "renames count on both sides")
  eq(diff[#diff], "--", "the revision part ends with `--`")
  eq(diff[#diff - 1], "v1.0", "the revision is one argument, right before it")
  eq(calls[1].argv[#calls[1].argv], "v1.0^{commit}", "verified as a commit")
  ok(vim.tbl_contains(calls[3].argv, "--exclude-standard"), "untracked files that are not ignored")

  -- the three modes pick their base
  git.changed("/r", { mode = "changed", run = recorder() })
  eq(calls[2].argv[#calls[2].argv - 1], "HEAD", "--changed is the working tree against HEAD")
  git.changed("/r", { mode = "affected", run = recorder() })
  eq(calls[2].argv[#calls[2].argv - 1], "HEAD~1", "--affected defaults to HEAD~1")
  git.changed("/r", { mode = "affected", since = "main", run = recorder() })
  eq(calls[2].argv[#calls[2].argv - 1], "main", "--affected <rev>")

  -- hostile output: a file name is data
  files = git.changed(
    "/r",
    { mode = "changed", run = recorder("ok.lua\0-rf\0--output=x\0with space.lua\0") }
  )
  eq(
    files,
    { "--output=x", "-rf", "ok.lua", "with space.lua" },
    "names are entries, sorted, never options"
  )
  local _, _, unsafe = git.changed("/r", {
    mode = "changed",
    run = recorder("../x.lua\0/etc/passwd\0C:/x.lua\0a\nb.lua\0back\\slash.lua\0ok.lua\0ok.lua\0"),
  })
  eq(
    unsafe,
    { "../x.lua", "/etc/passwd", "C:/x.lua", "a\nb.lua", "back\\slash.lua" },
    "untrusted entries are returned separately"
  )
  -- failures
  local function failing(which)
    return function(argv)
      if argv[2] == which then
        return { code = 1, stdout = "", stderr = "boom" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end
  end
  for _, which in ipairs({ "rev-parse", "diff", "ls-files" }) do
    files, err = git.changed("/r", { mode = "changed", run = failing(which) })
    eq(files, nil, which .. " failing: no files")
    ok(err ~= nil, which .. " failing: a message")
  end
  -- several commands at once: the answers come back in the order they were asked, a failure stays its own
  local par = git.run_parallel(
    { { "git", "--version" }, { "does-not-exist" }, { "git", "no-such-command" } },
    "."
  )
  eq(#par, 3, "run_parallel: one answer per command")
  eq(par[1].code, 0, "run_parallel: the first command ran")
  has(par[1].stdout, "git version", "run_parallel: and its output is the first answer")
  eq(par[2].code, 127, "run_parallel: a command that cannot start is code 127, not an error")
  ok(par[3].code ~= 0, "run_parallel: a failing command is a failing answer")
  eq(git.run_parallel({}, "."), {}, "run_parallel: nothing to run")
  local missing = git.default_run({ "does-not-exist" }, ".")
  ok(missing.code ~= 0, "an executable that is not there is a failed run, not an error")

  -- ---------------------------------------------------------------- a real repository
  local function run(cwd, ...)
    local r = vim
      .system(
        { "git", "-c", "user.name=t", "-c", "user.email=t@example.com", ... },
        { cwd = cwd, text = true }
      )
      :wait()
    ok(r.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(r.stderr))
    return r.stdout
  end
  local root = S.project()
  S.write(root .. "/with space.lua", "return 1\n")
  S.write(root .. "/.gitignore", "ignored.txt\n")
  run(root, "init", "-q")
  run(root, "add", "-A")
  run(root, "commit", "-q", "-m", "one")
  eq(git.changed(root, { mode = "changed" }), {}, "a clean tree: nothing changed")

  S.edit(root, "lua/proj/b.lua", "return { v = 99 }\n")
  S.write(root .. "/new file.lua", "return 2\n")
  S.write(root .. "/ignored.txt", "x")
  run(root, "mv", "with space.lua", "renamed.lua")
  local changed = git.changed(root, { mode = "changed" })
  eq(
    changed,
    { "lua/proj/b.lua", "new file.lua", "renamed.lua", "with space.lua" },
    "modified, untracked, the new and the OLD name of a rename; not the ignored file"
  )

  run(root, "add", "-A")
  run(root, "commit", "-q", "-m", "two")
  eq(git.changed(root, { mode = "changed" }), {}, "clean again")
  eq(
    #git.changed(root, { mode = "since", since = "HEAD~1" }),
    4,
    "since HEAD~1: what the last commit changed"
  )
  eq(#git.changed(root, { mode = "affected" }), 4, "affected defaults to HEAD~1")
  local none, nerr = git.changed(root, { mode = "since", since = "HEAD~7" })
  eq(none, nil, "a revision git does not know")
  has(nerr, "HEAD~7", "is named")
  none = git.changed(root, { mode = "since", since = "nonexistent-branch" })
  eq(none, nil, "an unknown branch")

  -- an IGNORED file (a generated module) cannot be diffed: when it is newer than the base commit it counts as changed
  S.write(root .. "/lua/proj/gen.lua", "return { gen = 1 }\n", false)
  S.write(root .. "/lua/proj/old_gen.lua", "return { gen = 0 }\n", false)
  local aged = os.time() - 7 * 24 * 3600
  vim.uv.fs_utime(root .. "/lua/proj/old_gen.lua", aged, aged)
  S.write(root .. "/.gitignore", "ignored.txt\nlua/proj/gen.lua\nlua/proj/old_gen.lua\n", false)
  local without = assert(git.changed(root, { mode = "changed" }))
  eq(
    vim.tbl_contains(without, "lua/proj/gen.lua"),
    false,
    "without `ignored_dirs` an ignored file is invisible (git does not list it)"
  )
  local with_ignored = assert(git.changed(root, { mode = "changed", ignored_dirs = { "lua" } }))
  ok(
    vim.tbl_contains(with_ignored, "lua/proj/gen.lua"),
    "a generated module newer than HEAD is changed"
  )
  ok(not vim.tbl_contains(with_ignored, "lua/proj/old_gen.lua"), "one that is older is not")
  ok(
    not vim.tbl_contains(with_ignored, "ignored.txt"),
    "and a file outside `ignored_dirs` is not looked at"
  )
  vim.fn.delete(root .. "/lua/proj/gen.lua")
  vim.fn.delete(root .. "/lua/proj/old_gen.lua")
  S.write(root .. "/.gitignore", "ignored.txt\n", false)

  -- the selection end to end on that repository
  local specs = {}
  for _, p in ipairs(H.glob(root .. "/TESTS/proj/*_spec.lua")) do
    specs[#specs + 1] = vim.fs.normalize(p):sub(#vim.fs.normalize(root) + 2)
  end
  table.sort(specs)
  local r = affected.select({
    root = root,
    specs = specs,
    mode = "since",
    since = "HEAD~1",
    provider = false,
    getenv = function() end,
  })
  eq(r.all, true, "since HEAD~1: new file.lua is unknown: everything")
  eq(r.unknown, { "new file.lua", "renamed.lua", "with space.lua" }, "named")
  S.edit(root, "lua/proj/b.lua", "return { v = 100 }\n")
  r = affected.select({
    root = root,
    specs = specs,
    mode = "changed",
    provider = false,
    getenv = function() end,
  })
  eq(r.all, false, "only b.lua changed")
  ok(vim.tbl_contains(r.files, "TESTS/proj/a_spec.lua"), "a_spec reaches proj.b")
  ok(not vim.tbl_contains(r.files, "TESTS/proj/c_spec.lua"), "c_spec does not")
  r = affected.select({
    root = root,
    specs = specs,
    mode = "since",
    since = "bad ref",
    provider = false,
    getenv = function() end,
  })
  eq(r.all, true, "a bad revision selects everything")
  has(r.all_reason, "git cannot tell", "named")
  S.write(root .. "/TESTS/proj/c_spec.lua", "return function(H) H.ok(true, 'c') end\n", false)
  r = affected.select({
    root = root,
    specs = specs,
    mode = "changed",
    provider = false,
    getenv = function() end,
  })
  ok(vim.tbl_contains(r.files, "TESTS/proj/c_spec.lua"), "an edited spec is selected")

  -- ---------------------------------------------------------------- freshness of module_map.json
  local map = root .. "/docs/map/module_map.json"
  eq(affected.graph_freshness(root).status, "missing", "no map")
  -- the code goes in first; the map is generated and committed after it
  run(root, "add", "-A")
  run(root, "commit", "-q", "-m", "three")
  S.write(map, "{}", false)
  run(root, "add", "-A")
  run(root, "commit", "-q", "-m", "four")
  local commit_time = git.last_commit_time(root)
  ok(commit_time ~= nil and commit_time > 0, "the last commit time")
  -- the map is the newest thing and the commit that added it is excluded from `code`
  local fresh = affected.graph_freshness(root)
  eq(fresh.status, "ok", "a map newer than the last code commit: " .. tostring(fresh.message))
  local old = commit_time - 86400
  vim.uv.fs_utime(map, old, old)
  local stale = affected.graph_freshness(root)
  eq(stale.status, "stale", "a map older than the last commit")
  has(stale.message, "older than the last commit", "says so")
  vim.uv.fs_utime(map, commit_time + 5, commit_time + 5)
  eq(affected.graph_freshness(root).status, "ok", "newer again")
  S.write(root .. "/lua/proj/c.lua", "return { c = 3 }\n", false)
  vim.uv.fs_utime(root .. "/lua/proj/c.lua", commit_time + 500, commit_time + 500)
  stale = affected.graph_freshness(root)
  eq(stale.status, "stale", "an uncommitted change newer than the map")
  has(stale.message, "lua/proj/c.lua", "names the file")
  local nogit = vim.fs.normalize(vim.fn.tempname())
  S.write(nogit .. "/docs/map/module_map.json", "{}")
  eq(affected.graph_freshness(nogit, { run = recorder() }).status, "unknown", "not a git checkout")

  S.remove(root)
  S.remove(nogit)
end
