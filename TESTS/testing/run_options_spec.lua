-- TESTS/testing/run_options_spec.lua -- the isolation options, read from ONE place: flags win over
-- .testing.lua, absent keys fall back to safe defaults, the per-dialect default of `isolated`, the host
-- of a script, the runtimepath of a child.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local options = require("testing.run.options")
  local args_mod = require("testing.args")

  -- nothing configured: safe defaults
  local d = options.of({})
  eq(d.isolated, "auto", "isolated: unset means auto (per dialect)")
  eq(d.jobs, 1, "jobs: 1")
  eq(d.host, "c", "host: c")
  eq(d.host_given, false, "host was not given")
  eq(d.filetype, true, "filetype: on")
  eq(d.assertions, "error", "assertions: error")
  eq(d.env_allow, {}, "env_allow: empty")

  -- the config keys
  local c = options.of({
    project = {
      isolated = "file",
      jobs = 4,
      host = "l",
      filetype = false,
      assertions = "warn",
      env_allow = { "A", "B*" },
    },
  })
  eq(c.isolated, "file", "config isolated")
  eq(c.jobs, 4, "config jobs")
  eq(c.host, "l", "config host")
  eq(c.filetype, false, "config filetype")
  eq(c.assertions, "warn", "config assertions")
  eq(c.env_allow, { "A", "B*" }, "config env_allow")

  -- flags win, env_allow accumulates
  local args = assert(args_mod.parse({
    "root",
    "--isolated",
    "none",
    "--jobs",
    "8",
    "--host",
    "c",
    "--env-allow",
    "C",
  }))
  local f = options.of({
    args = args,
    project = { isolated = "file", jobs = 4, host = "l", env_allow = { "A" } },
  })
  eq(f.isolated, "none", "--isolated wins over the config")
  eq(f.jobs, 8, "--jobs wins over the config")
  eq(f.host, "c", "--host wins over the config")
  eq(f.host_given, true, "and is remembered as given")
  eq(f.env_allow, { "A", "C" }, "config and flag env_allow are added up")

  -- garbage does not get through
  local g =
    options.of({ project = { isolated = "maybe", jobs = 0, host = "x", assertions = "zzz" } })
  eq(g.isolated, "auto", "an invalid isolated is ignored")
  eq(g.jobs, 1, "jobs < 1 becomes 1")
  eq(g.host, "c", "an invalid host becomes c")
  eq(g.assertions, "error", "an invalid assertions becomes error")
  eq(options.of({ project = { jobs = 2.7 } }).jobs, 2, "jobs is an integer")

  -- the per-dialect default
  local unset = options.of({})
  eq(
    options.isolation_of(unset, { dialect = "busted" }),
    "file",
    "busted: one editor per file, like plenary"
  )
  for _, dialect in ipairs({ "a", "b", "c", "d", "h" }) do
    eq(options.isolation_of(unset, { dialect = dialect }), "none", dialect .. ": in this editor")
  end
  eq(options.isolation_of(unset, { dialect = "script" }), "file", "script: always a child")
  local all = options.of({ project = { isolated = "file" } })
  eq(
    options.isolation_of(all, { dialect = "a" }),
    "file",
    "isolated = file applies to every dialect"
  )
  local none = options.of({ project = { isolated = "none" } })
  eq(
    options.isolation_of(none, { dialect = "busted" }),
    "none",
    "isolated = none: busted in this editor"
  )
  eq(
    options.isolation_of(none, { dialect = "script" }),
    "file",
    "isolated = none cannot run a script in-process"
  )

  eq(
    options.any_isolated(unset, { { dialect = "a" }, { dialect = "h" } }),
    false,
    "no child needed"
  )
  eq(
    options.any_isolated(unset, { { dialect = "a" }, { dialect = "busted" } }),
    true,
    "one busted file needs one"
  )
  eq(options.any_isolated(none, { { dialect = "a" } }), false, "none: no child")
  eq(options.any_isolated(none, { { dialect = "script" } }), true, "a script needs one")

  -- a script was written for nvim -l unless --host says otherwise
  eq(options.host_of(unset, { dialect = "script" }), "l", "script: host l by default")
  eq(options.host_of(unset, { dialect = "a" }), "c", "others: the configured host")
  local forced = options.of({ args = { host = "c" } })
  eq(options.host_of(forced, { dialect = "script" }), "c", "--host c is honoured for a script too")
  local cfg_l = options.of({ project = { host = "l" } })
  eq(options.host_of(cfg_l, { dialect = "a" }), "l", "config host l")

  -- the runtimepath of a child: this checkout first, lib.nvim, the dependencies, the root, --rtp
  local deps = require("testing.deps")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-rtp"
  local extra = root .. "/extra"
  vim.fn.mkdir(extra, "p")
  local prepend, append, env = options.child_rtp({
    root = root,
    project = { deps = {} },
    args = { rtp = { extra } },
  })
  eq(prepend, { deps.self_dir() }, "this checkout is prepended")
  local lib = assert(deps.resolve("lib.nvim", deps.self_dir()))
  eq(env.LIB_NVIM_DIR, lib.dir, "the child gets $LIB_NVIM_DIR (an editor a spec starts needs it)")
  eq(env.TESTING_NVIM_DIR, deps.self_dir(), "and $TESTING_NVIM_DIR (a project's minit asks for it)")
  -- a resolved dependency of the project is passed on as well
  local sib = vim.fs.normalize(vim.fn.tempname()) .. "-sib"
  vim.fn.mkdir(sib .. "/lua", "p")
  vim.uv.os_setenv("SIBLING_NVIM_DIR", sib)
  local _, _, env2 =
    options.child_rtp({ root = root, project = { deps = { "sibling.nvim" } }, args = {} })
  vim.uv.os_unsetenv("SIBLING_NVIM_DIR")
  vim.fn.delete(sib, "rf")
  eq(env2.SIBLING_NVIM_DIR, sib, "a dependency of the project: its $<NAME>_DIR is passed on")
  eq(append[1], lib.dir, "lib.nvim comes first in the appended list")
  local function index_of(dir)
    for i, entry in ipairs(append) do
      if vim.fs.normalize(entry) == vim.fs.normalize(dir) then
        return i
      end
    end
  end
  eq(index_of(root), 2, "then the project root")
  eq(index_of(extra), 3, "then the --rtp directories")
  local site = vim.fs.normalize(vim.fn.stdpath("data") .. "/site")
  if vim.fn.isdirectory(site) == 1 then
    eq(index_of(site), 4, "and last the real stdpath('data')/site (installed parsers, read-only)")
  else
    eq(#append, 3, "no site directory on this machine: nothing more")
  end
  vim.fn.delete(root, "rf")
end
