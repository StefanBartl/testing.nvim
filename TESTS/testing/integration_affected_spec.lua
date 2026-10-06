-- TESTS/testing/integration_affected_spec.lua -- `--changed`, `--since <rev>` and `--affected` through the real command
-- line on a throwaway git repository: only the specs a change can reach run, a selection is a PARTIAL run (never a
-- sentinel), what cannot be placed selects everything with the reason named, git failing selects everything, a
-- revision git must not see is refused, and nothing changed is not a green run.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

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

  local cli = require("testing.cli")
  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-affspec"
  vim.fn.mkdir(tmp, "p")

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param root string
  ---@param ... string
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
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return vim.trim(res.stdout or "")
  end

  ---Two modules, `proj.a` and `proj.b` (b requires a), a spec for each and one that only loads `proj.b`
  ---... and a pure one that loads nothing.
  ---@return string root
  local function repo()
    local root = tmp .. "/r"
    vim.fn.delete(root, "rf")
    write(root .. "/lua/proj/a.lua", "return { n = 1 }\n")
    write(root .. "/lua/proj/b.lua", "local a = require('proj.a')\nreturn { n = a.n + 1 }\n")
    write(root .. "/lua/proj/c.lua", "return { n = 3 }\n")
    write(
      root .. "/TESTS/a_spec.lua",
      "return function(H)\n  H.ok(require('proj.a').n == 1, 'a')\nend\n"
    )
    write(
      root .. "/TESTS/b_spec.lua",
      "return function(H)\n  H.ok(require('proj.b').n == 2, 'b')\nend\n"
    )
    write(
      root .. "/TESTS/c_spec.lua",
      "return function(H)\n  H.ok(require('proj.c').n == 3, 'c')\nend\n"
    )
    write(root .. "/TESTS/pure_spec.lua", "return function(H)\n  H.ok(true, 'pure')\nend\n")
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    write(root .. "/README.md", "hello\n")
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  ---@param root string
  ---@param argv string[]
  ---@param getenv? fun(name: string): string|nil
  local function run(root, argv, getenv)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      affected = { getenv = getenv or function() end, provider = false },
    }
    local args = { root }
    vim.list_extend(args, argv)
    local code = cli.main(args, sv)
    for _, m in ipairs({ "proj.a", "proj.b", "proj.c" }) do
      package.loaded[m] = nil
    end
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  ---Which spec files a run printed (`ok    TESTS/x_spec.lua`).
  ---@param text string
  ---@return string[]
  local function ran(text)
    local list = {}
    for rel in text:gmatch("\n?ok%s+TESTS/([%w_]+_spec%.lua)") do
      list[#list + 1] = rel
    end
    table.sort(list)
    return list
  end

  local root = repo()

  -- ---------------------------------------------------------------- nothing changed
  local none = run(root, { "--changed" })
  eq(none.code, 0, "nothing changed: exit 0\n" .. none.err)
  has(
    none.out,
    "no spec file is affected by the changes (--changed): nothing ran",
    "and it says nothing ran"
  )
  has(none.out, "not a green run (no sentinel)", "and that this is not a green run")
  lacks(none.out, "TESTING_OK", "no sentinel")

  -- ---------------------------------------------------------------- a changed module: its dependents, partial run
  write(root .. "/lua/proj/a.lua", "return { n = 1, touched = true }\n")
  local r = run(root, { "--changed" })
  eq(r.code, 0, "--changed after a change of proj.a: green\n" .. r.err .. r.out)
  eq(
    ran(r.out),
    { "a_spec.lua", "b_spec.lua" },
    "only the spec of proj.a and the one of its dependent proj.b run"
  )
  has(r.err, "affected: --changed selects 2 of 4 spec file(s)", "stderr names the selection")
  has(
    r.out,
    "partial run: 2 of 4 spec files (--changed; no sentinel)",
    "a selection is a partial run"
  )
  lacks(r.out, "TESTING_OK", "so there is no sentinel, even when it is green")

  -- the same through --since and --affected (a clean tree: the commit before HEAD does not exist yet)
  local since = run(root, { "--since", "HEAD" })
  eq(ran(since.out), { "a_spec.lua", "b_spec.lua" }, "--since HEAD is the same selection")
  has(since.out, "(--since HEAD; no sentinel)", "and the partial run line names it")

  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "touch a")
  write(root .. "/lua/proj/c.lua", "return { n = 3, touched = true }\n")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "touch c")
  local aff = run(root, { "--affected" })
  eq(aff.code, 0, "--affected: green\n" .. aff.err)
  eq(ran(aff.out), { "c_spec.lua" }, "--affected is the last commit: only the spec of proj.c")
  local aff_rev = run(root, { "--affected=HEAD~2" })
  eq(
    ran(aff_rev.out),
    { "a_spec.lua", "b_spec.lua", "c_spec.lua" },
    "--affected=<rev> reaches back further"
  )

  -- ---------------------------------------------------------------- untracked files count
  write(root .. "/TESTS/new_spec.lua", "return function(H)\n  H.ok(true, 'new')\nend\n")
  local fresh = run(root, { "--changed" })
  eq(ran(fresh.out), { "new_spec.lua" }, "an untracked spec is a changed spec")
  vim.fn.delete(root .. "/TESTS/new_spec.lua")

  -- ---------------------------------------------------------------- what cannot be placed selects everything
  write(root .. "/stylua.toml", "column_width = 100\n")
  local readme = run(root, { "--changed" })
  eq(readme.code, 0, "an unplaced change: green\n" .. readme.err)
  eq(
    ran(readme.out),
    { "a_spec.lua", "b_spec.lua", "c_spec.lua", "pure_spec.lua" },
    "a changed tool configuration cannot be placed: every spec runs"
  )
  has(readme.err, "selects EVERY spec file", "and the note says so")
  has(readme.err, "stylua.toml", "and names the file")
  vim.fn.delete(root .. "/stylua.toml")
  -- a document can be placed: nobody here names the README, so no spec is affected (said, not green)
  write(root .. "/README.md", "changed\n")
  local doc = run(root, { "--changed" })
  eq(doc.code, 0, "a document nobody names: nothing to run\n" .. doc.err)
  has(doc.out, "nothing ran", "and it says nothing ran")
  ok(not doc.out:find("TESTING_OK", 1, true), "and prints no sentinel: this is not a green run")
  git(root, "checkout", "-q", "--", "README.md")

  -- ---------------------------------------------------------------- git cannot tell: everything, with the reason
  local bad_rev = run(root, { "--since", "no-such-revision" })
  eq(
    bad_rev.code,
    0,
    "an unknown revision: the run is not refused, it is complete\n" .. bad_rev.err
  )
  eq(#ran(bad_rev.out), 4, "an unknown revision selects every spec")
  has(bad_rev.err, "git cannot tell what changed", "and says why")
  has(bad_rev.out, "TESTING_OK", "a full selection is a complete run: the sentinel is allowed")

  -- ---------------------------------------------------------------- a revision git must not see is refused
  for _, rev in ipairs({ "a b", "HEAD..main", "x;y" }) do
    local refused = run(root, { "--since", rev })
    eq(refused.code, 2, ("--since %q is refused"):format(rev))
    lacks(refused.out, "TESTING_OK", "and nothing ran")
  end
  local both = run(root, { "--changed", "--since", "HEAD" })
  eq(both.code, 2, "--changed and --since exclude each other")

  -- ---------------------------------------------------------------- CI: an explicit selection runs, with a warning
  write(root .. "/lua/proj/a.lua", "return { n = 1, again = true }\n")
  local in_ci = run(root, { "--changed" }, function(name)
    return name == "CI" and "true" or nil
  end)
  eq(ran(in_ci.out), { "a_spec.lua", "b_spec.lua" }, "an explicit --changed in CI still selects")
  has(
    in_ci.err,
    "prefer the full run there",
    "but warns that the full run is the one to prefer in CI"
  )

  -- ---------------------------------------------------------------- the listing shows the selection
  local listed = run(root, { "--changed", "--list" })
  eq(listed.code, 0, "--changed --list\n" .. listed.err)
  has(listed.out, "2 case(s) in 2 of 4 spec file(s) would run", "--list shows the selection")

  vim.fn.delete(tmp, "rf")
end
