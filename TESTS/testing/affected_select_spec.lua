-- TESTS/testing/affected_select_spec.lua -- the affected selection (`testing.affected.select`) on the fixture
-- project: a changed spec selects itself, a changed module selects what reaches it (and its parents),
-- a computed require is followed, a file nobody can place selects ALL, a stale or incomplete graph selects
-- ALL, CI never defaults to a partial run, and the documentation.nvim contract is consumed defensively.

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
  local affected = require("testing.affected")
  local scan = require("testing.affected.scan")

  local root = S.project({
    ["TESTS/proj/mention_spec.lua"] = 'return function(H) H.ok(io.open(H.root .. "/lua/proj/c.lua"), "mention") end\n',
    ["lua/proj/dyn.lua"] = "local n = ...\nreturn require(n)\n",
    ["TESTS/proj/dyn_spec.lua"] = 'local d = require("proj.dyn")\nreturn function(H) H.ok(d, "dyn") end\n',
  })
  -- the specs the project has, in discovery order
  local specs = {}
  for _, p in ipairs(vim.fn.glob(root .. "/TESTS/proj/*_spec.lua", false, true)) do
    specs[#specs + 1] = vim.fs.normalize(p):sub(#vim.fs.normalize(root) + 2)
  end
  table.sort(specs)
  ok(#specs == 17, "the fixture has its specs")
  local function P(name)
    return "TESTS/proj/" .. name .. "_spec.lua"
  end
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local no_ci = function()
    return nil
  end
  ---@param changed string[]
  ---@param over? table
  local function sel(changed, over)
    return affected.select(vim.tbl_extend("force", {
      root = root,
      specs = specs,
      changed = changed,
      provider = false,
      getenv = no_ci,
      cache_dir = cdir,
    }, over or {}))
  end
  ---@param files string[]
  ---@return table<string, true>
  local function set(files)
    local s = {}
    for _, f in ipairs(files) do
      s[f] = true
    end
    return s
  end
  ---@param r table
  ---@param names string[] spec short names
  ---@param msg string
  local function selected(r, names, msg)
    local want = {}
    for _, n in ipairs(names) do
      want[#want + 1] = P(n)
    end
    table.sort(want)
    eq(vim.deepcopy(r.files), want, msg)
    eq(r.all, false, msg .. ": not everything")
  end

  -- ---------------------------------------------------------------- scanner
  local info = scan.analyze([[
    -- require("commented.out")
    local a = require("a.b")
    local c = require 'c.d'
    local ok = pcall(require, "e.f")
    local g = require("h." .. name)
    local s = "require('in.string')"
    local z = require(computed)
  ]])
  eq(
    info.requires,
    { "a.b", "c.d", "e.f", "in.string" },
    "requires: calls, pcall form, a string passed to :lua"
  )
  eq(info.prefixes, { "h." }, "a computed name keeps its literal head")
  eq(info.dynamic, true, "an unresolvable require is dynamic")
  eq(scan.module_of("lua/a/b.lua"), "a.b", "module of a file")
  eq(scan.module_of("lua/a/init.lua"), "a", "module of an init file")
  eq(scan.module_of("plugin/a.lua"), nil, "not a module")
  local m = scan.analyze(
    'local t = os.time()\nvim.system({"x"})\nos.getenv("A")\nlocal q = vim.env.B\n'
  ).markers
  eq({ m.time, m.spawn, m.env }, { true, true, { "A", "B" } }, "markers")
  eq(
    scan.analyze('local s = "os.time() vim.system"\n').markers.time,
    false,
    "a marker inside a string is none"
  )

  -- ---------------------------------------------------------------- a changed spec
  local r = sel({ P("c") })
  selected(r, { "c" }, "a changed spec selects itself")
  eq(r.source, "heuristic", "source")
  has(r.reason[P("c")], "spec file changed", "reason")
  eq(r.unknown, {}, "nothing unknown")

  -- ---------------------------------------------------------------- a changed module
  r = sel({ "lua/proj/b.lua" })
  selected(
    r,
    { "a", "dyn", "init", "proc" },
    "b: what reaches it, its parent module, a computed require and the process starter"
  )
  has(r.reason[P("a")], "proj.b", "the reason names the module")
  has(r.reason[P("a")], "proj.a", "and the way there")
  has(r.reason[P("init")], "parent module", "a spec of the parent")
  has(r.reason[P("proc")], "process", "a spec that starts a process runs whenever a module changed")

  r = sel({ "lua/proj/sub/x.lua" })
  selected(r, { "dyn", "init", "lazy", "proc" }, "a module below a computed require")
  has(r.reason[P("lazy")], "proj.lazy", "reached through the module with the computed require")

  r = sel({ "lua/proj/c.lua" })
  selected(
    r,
    { "c", "init", "mention", "proc", "dyn" },
    "c: its spec, parent, a spec naming the file, a computed require"
  )
  has(r.reason[P("mention")], "names the changed file", "a path literal")
  has(r.reason[P("dyn")], "computed require", "a computed require depends on everything")

  r = sel({ "lua/proj/a.lua", "lua/proj/c.lua" })
  ok(set(r.files)[P("a")] and set(r.files)[P("c")], "two changes: both")

  -- a deleted module is still a dependency of the specs that name it
  vim.fn.delete(root .. "/lua/proj/b.lua")
  r = sel({ "lua/proj/b.lua" })
  ok(set(r.files)[P("a")], "a deleted module selects what required it")
  S.write(root .. "/lua/proj/b.lua", "return { v = 1 }\n")

  -- ---------------------------------------------------------------- ignored, support files, deleted specs
  r = sel({ ".github/workflows/ci.yml" })
  eq(r.files, {}, "an ignored file selects nothing")
  eq(r.all, false, "and is no reason to run everything")
  r = sel({})
  eq(r.files, {}, "no change, no spec")
  eq(r.source, "none", "source none")
  r = sel({ "TESTS/proj/gone_spec.lua" })
  eq({ r.files, r.all, r.unknown }, { {}, false, {} }, "a deleted spec has nothing to run")
  r = sel({ "TESTS/proj/helper.lua" })
  eq(
    vim.deepcopy(r.files),
    vim.deepcopy(specs),
    "a support file selects every spec below its directory"
  )
  eq(r.all, false, "which is not the `all` fallback")
  has(r.reason[P("a")], "support file", "reason")
  r = sel({ "TESTS/harness.lua" })
  eq(vim.deepcopy(r.files), vim.deepcopy(specs), "the harness: the nearest directory with specs")
  r = sel({ "TESTS/proj/fixtures/data.json" })
  eq(vim.deepcopy(r.files), vim.deepcopy(specs), "a fixture file")

  -- ---------------------------------------------------------------- unknown selects ALL
  for _, f in ipairs({ "plugin/proj.lua", "stylua.toml" }) do
    r = sel({ f })
    eq(r.all, true, f .. " cannot be placed: everything runs")
    eq(vim.deepcopy(r.files), vim.deepcopy(specs), f .. ": every spec")
    eq(r.unknown, { f }, f .. ": named")
    has(r.all_reason, f, f .. ": the reason names it")
    has(r.reason[P("c")], "all:", f .. ": every spec says why")
  end
  r = sel({ ".testing.lua" })
  eq(r.all, true, "the project configuration changed")
  has(r.all_reason, "configuration", "named")
  r = sel({ P("c"), "plugin/proj.lua" })
  eq(r.all, true, "one unknown file among known ones")
  eq(r.unknown, { "plugin/proj.lua" }, "only it is unknown")

  -- a document is not unknown: it reaches the specs that name it, and the ones that list directories
  r = sel({ "README.md" })
  eq(r.all, false, "a README is placeable")
  eq(vim.deepcopy(r.files), { P("reads") }, "the spec that opens it by name, nothing else")
  has(r.reason[P("reads")], "names the changed file", "and says why")
  r = sel({ "docs/x.md" })
  eq(r.all, false, "a page of docs/ is placeable")
  eq(vim.deepcopy(r.files), {}, "nobody names it: no spec is affected")

  -- ---------------------------------------------------------------- git: failures and hostile output
  local function fake_git(answers)
    return function(argv)
      local sub = argv[2]
      local a = answers[sub] or { code = 0, stdout = "", stderr = "" }
      return a
    end
  end
  r = affected.select({
    root = root,
    specs = specs,
    provider = false,
    getenv = no_ci,
    run = fake_git({
      ["rev-parse"] = { code = 128, stdout = "", stderr = "fatal: not a git repository" },
    }),
  })
  eq(r.all, true, "git failing selects everything")
  has(r.all_reason, "git", "and says so")
  r = affected.select({
    root = root,
    specs = specs,
    provider = false,
    getenv = no_ci,
    run = fake_git({ diff = { code = 0, stdout = "../evil.lua\0lua/proj/b.lua\0", stderr = "" } }),
  })
  eq(r.all, true, "a path that climbs out of the root is not trusted")
  has(r.all_reason, "cannot be trusted", "named")
  r = affected.select({
    root = root,
    specs = specs,
    provider = false,
    getenv = no_ci,
    run = fake_git({
      diff = { code = 0, stdout = "lua/proj/b.lua\0", stderr = "" },
      ["ls-files"] = { code = 0, stdout = P("c") .. "\0", stderr = "" },
    }),
  })
  selected(
    r,
    { "a", "c", "dyn", "init", "proc" },
    "tracked changes and untracked files are both changes"
  )

  -- ---------------------------------------------------------------- CI
  eq(affected.in_ci(no_ci), false, "no CI")
  for _, name in ipairs({ "CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "TF_BUILD" }) do
    eq(
      affected.in_ci(function(n)
        return n == name and "true" or nil
      end),
      true,
      name .. " is CI"
    )
  end
  eq(
    affected.in_ci(function(n)
      return n == "CI" and "false" or nil
    end),
    false,
    "CI=false"
  )
  eq(
    affected.in_ci(function(n)
      return n == "CI" and "0" or nil
    end),
    false,
    "CI=0"
  )
  eq(
    affected.in_ci(function(n)
      return n == "CI" and "" or nil
    end),
    false,
    "CI empty"
  )
  local in_ci = function(n)
    return n == "GITHUB_ACTIONS" and "true" or nil
  end
  r = sel({ P("c") }, { getenv = in_ci, implicit = true })
  eq(r.all, true, "implicit affected in CI runs everything")
  has(r.all_reason, "never the default", "named")
  eq(r.ci, true, "ci flag")
  r = sel({ P("c") }, { getenv = in_ci })
  eq(r.all, false, "explicit affected in CI runs")
  eq(vim.deepcopy(r.files), { P("c") }, "the selection")
  ok(#r.warnings > 0 and r.warnings[1]:find("CI", 1, true) ~= nil, "but warns")
  r = sel({ P("c") }, { implicit = true })
  eq(r.all, false, "implicit outside CI is fine")

  -- ---------------------------------------------------------------- the documentation.nvim contract
  -- (the shape is the one `documentation.testing.affected_specs` answers: tables, not names; a contract spec
  -- against the real provider is in `affected_contract_spec.lua`)
  local calls = {}
  local function provider(answer, err)
    return function(args)
      calls[#calls + 1] = args
      return answer, err
    end
  end
  local good = {
    version = 1,
    specs = { P("c") },
    modules = {
      {
        id = "proj.b",
        module = "proj.b",
        path = "lua/proj/b.lua",
        role = "changed",
        specs = { P("c") },
      },
    },
    unplaced_specs = {},
    ignored = {},
    complete = true,
    graph = {
      generated_at = "2026-10-06T10:00:00Z",
      commit = "abc1234",
      stale = false,
      gaps = {},
    },
  }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(good), roots = { "TESTS" } })
  eq(r.source, "graph", "the graph answered")
  selected(
    r,
    { "a", "c", "dyn", "init", "proc" },
    "what the heuristic reaches plus what the graph names: the graph only adds"
  )
  eq(
    r.reason[P("c")],
    "reaches a changed module (documentation graph)",
    "named for the graph's spec"
  )
  eq(calls[1].root, root, "the provider gets the root")
  eq(calls[1].changed, { "lua/proj/b.lua" }, "and the changed module files")
  eq(calls[1].spec_roots, { "TESTS" }, "and the spec roots of the project")
  eq(r.graph.commit, "abc1234", "the graph metadata is passed on")

  -- a graph that names less than the heuristic reaches does not narrow the selection
  local narrow = vim.deepcopy(good)
  narrow.specs, narrow.modules[1].specs = {}, {}
  r = sel({ "lua/proj/b.lua" }, { provider = provider(narrow) })
  selected(r, { "a", "dyn", "init", "proc" }, "an empty graph answer does not remove anything")

  -- the specs the graph cannot place are run too
  local unplaced = vim.deepcopy(good)
  unplaced.specs = {}
  unplaced.unplaced_specs = { P("pure") }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(unplaced) })
  ok(set(r.files)[P("pure")], "an unplaced spec is selected")
  has(r.reason[P("pure")], "cannot place", "with the reason")

  local stale = vim.deepcopy(good)
  stale.graph.stale = true
  r = sel({ "lua/proj/b.lua" }, { provider = provider(stale) })
  eq(r.all, true, "a stale graph selects everything")
  has(r.all_reason, "stale", "named")
  has(r.all_reason, "abc1234", "with the commit it was built at")

  local incomplete = vim.deepcopy(good)
  incomplete.complete = false
  incomplete.graph.gaps = {
    { kind = "test_support_changed", path = "TESTS/x.lua", message = "m" },
    { kind = "changed_not_in_graph", path = "lua/new.lua" },
  }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(incomplete) })
  eq(r.all, true, "an answer that says it is not complete selects everything")
  has(r.all_reason, "incomplete", "named")
  has(r.all_reason, "changed_not_in_graph, test_support_changed", "with the kinds of the gaps")

  local partial = vim.deepcopy(good)
  partial.modules = {
    { id = "proj.other", module = "proj.other", path = "lua/proj/other.lua", role = "changed" },
  }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(partial) })
  eq(r.all, true, "a changed file the graph does not know selects everything")
  eq(r.unknown, { "lua/proj/b.lua" }, "named")
  has(r.all_reason, "incomplete", "reason")

  local gap = vim.deepcopy(good)
  gap.specs, gap.modules, gap.graph.gaps =
    {}, {}, {
      {
        kind = "changed_module_without_spec",
        path = "lua/proj/b.lua",
        module = "proj.b",
        message = "no spec requires it",
      },
    }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(gap) })
  eq(r.all, false, "a module without specs is a known gap, not an unknown file")
  selected(r, { "a", "dyn", "init", "proc" }, "what the heuristic reaches")

  local ignored = vim.deepcopy(good)
  ignored.modules, ignored.specs = {}, {}
  ignored.ignored = { "lua/proj/b.lua" }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(ignored) })
  eq(r.all, false, "an ignored file is placed")

  local ghost = vim.deepcopy(good)
  ghost.specs = { "TESTS/proj/ghost_spec.lua" }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(ghost) })
  eq(r.all, true, "a graph that names a spec that does not exist is out of date")
  has(r.all_reason, "ghost_spec", "named")
  local ghost2 = vim.deepcopy(good)
  ghost2.unplaced_specs = { "TESTS/proj/ghost_spec.lua" }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(ghost2) })
  eq(r.all, true, "the same for an unplaced spec")

  -- a spec that exists on disk but that the project does not run is named, not selected
  local foreign = vim.deepcopy(good)
  foreign.specs = { "README.md" }
  r = sel({ "lua/proj/b.lua" }, { provider = provider(foreign) })
  eq(r.all, false, "a file the project does not run as a spec cannot be selected")
  has(r.warnings[1], "does not run", "and is reported")

  r = sel({ "lua/proj/b.lua" }, { provider = provider(nil, "boom") })
  eq(r.all, false, "no answer: the heuristic")
  eq(r.source, "heuristic", "source")
  selected(r, { "a", "dyn", "init", "proc" }, "same as without a graph")
  has(r.warnings[1], "boom", "the warning carries the reason")
  r = sel({ "lua/proj/b.lua" }, {
    provider = function()
      error("kaboom")
    end,
  })
  eq(r.source, "heuristic", "a provider that throws")
  has(r.warnings[1], "kaboom", "is reported")
  local function with(over)
    return vim.tbl_extend("force", vim.deepcopy(good), over)
  end
  local no_complete = vim.deepcopy(good)
  no_complete.complete = nil
  for _, shape in ipairs({
    with({ specs = "x" }),
    with({ graph = "no" }),
    with({ graph = { stale = "no" } }),
    with({ specs = { 5 } }),
    no_complete,
    with({ modules = { "proj.b" } }), -- the names of an older contract
    with({ unplaced_specs = "x" }),
    with({ graph = { stale = false, gaps = { "proj.b" } } }),
    "a string",
  }) do
    r = sel({ "lua/proj/b.lua" }, { provider = provider(shape) })
    eq(
      r.source,
      "heuristic",
      "a malformed answer is not trusted: " .. vim.inspect(shape):sub(1, 30)
    )
    has(r.warnings[1], "unknown shape", "and reported")
  end
  -- a change without a module does not ask the graph
  calls = {}
  sel({ P("c") }, { provider = provider(good) })
  eq(#calls, 0, "a spec-only change needs no graph")

  -- ---------------------------------------------------------------- freshness (testing doctor)
  eq(affected.graph_freshness(root).status, "missing", "no module_map.json")

  require("testing.cache").reset()
  S.remove(root)
  S.remove(cdir)
end
