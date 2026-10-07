-- TESTS/testing/affected_cross_spec.lua -- the consumers of a change (`--consumers`, `affected.consumers`):
-- documentation.nvim answers `cross_repo`, this runner reads it, says what it means, and NEVER lets it
-- change what runs in this project. The recording (fixtures/affected/documentation_answer_cross_repo.json)
-- is a real answer of `documentation.testing.affected_specs` of documentation.nvim for a change of lib.nvim
-- with `consumers` = the directory of the checkouts (module map of lib.nvim stale at that moment, one measured
-- consumer, three not measured). To record again: call `affected_specs({ root = ..., changed = ...,
-- consumers = ... })` and write the table with `vim.json.encode`.

-- @cache-allow outside
-- ("../" is the value of a `consumers` option checked against a temp tree the spec writes, nothing is read from the real parent directory)
return function(H)
  local ok = H.ok
  local eq = H.eq
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local affected = require("testing.affected")
  local cached = require("testing.run.cached")
  local args_mod = require("testing.args")
  local project_cfg = require("testing.config.project")

  local recorded =
    vim.json.decode(S.read(dir .. "/fixtures/affected/documentation_answer_cross_repo.json"))

  -- ---- a project that has the changed module and a few specs -----------------------------------------
  local root = S.project({
    ["lua/lib/lua/numeral/roman.lua"] = "return {}\n",
    ["lua/lib/lua/numeral/init.lua"] = 'return { roman = require("lib.lua.numeral.roman") }\n',
    ["TESTS/lua_helpers_spec.lua"] = "return function(H) H.ok(true, 'x') end\n",
    ["TESTS/own_spec.lua"] = "return function(H) H.ok(true, 'own') end\n",
  })
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local specs = { "TESTS/lua_helpers_spec.lua", "TESTS/own_spec.lua" }
  local seen_args
  ---@param answer table
  ---@param consumers? string
  local function select_with(answer, consumers)
    seen_args = nil
    return affected.select({
      root = root,
      specs = specs,
      changed = { "lua/lib/lua/numeral/roman.lua" },
      consumers = consumers,
      getenv = function() end,
      cache_dir = cdir,
      roots = { "TESTS" },
      provider = function(a)
        seen_args = a
        return (vim.deepcopy(answer))
      end,
    })
  end

  -- a complete answer, to see the selection narrow while the consumers are listed
  local function complete_answer()
    local a = vim.deepcopy(recorded)
    a.complete = true
    a.graph.stale = false
    a.graph.gaps = {}
    a.specs = { "TESTS/lua_helpers_spec.lua" }
    a.unplaced_specs = {}
    a.modules = {
      {
        id = "lua/lib/lua/numeral/roman.lua",
        module = "lib.lua.numeral.roman",
        path = "lua/lib/lua/numeral/roman.lua",
        role = "changed",
        specs = { "TESTS/lua_helpers_spec.lua" },
      },
      {
        id = "lua/lib/lua/numeral",
        module = "lib.lua.numeral",
        path = "lua/lib/lua/numeral",
        role = "dependent",
        specs = { "TESTS/lua_helpers_spec.lua" },
      },
    }
    return a
  end

  -- ---- the recording is a valid answer and its cross_repo is readable -----------------------------------
  ok(affected.check_answer(recorded) ~= nil, "the recorded answer is a valid answer")
  local clean, why = affected.clean_cross(recorded)
  ok(clean ~= nil, "the recorded cross_repo is readable: " .. tostring(why))
  eq(#clean, 4, "four consumers in the recording")
  eq(clean[1].repo, "cascade.nvim", "the measured one")
  eq(clean[1].measured, true, "measured")
  eq(clean[1].stale, true, "its own map is stale")
  eq(#clean[1].specs, 19, "its specs")
  eq(clean[2].measured, false, "an unmeasured one")
  eq(clean[2].reason, "no committed module map", "and why")
  eq(#clean[2].specs, 0, "it names no spec: the whole suite is the answer")

  -- ---- consumers are asked for and returned, and the selection is the same without them ------------------
  local answer = complete_answer()
  local plain = select_with(answer, nil)
  eq(seen_args.consumers, nil, "without --consumers the provider is not given the option")
  eq(plain.cross_repo, {}, "without --consumers: no consumer")
  eq(affected.cross_lines(plain), {}, "without --consumers: nothing to say")
  eq(plain.files, { "TESTS/lua_helpers_spec.lua" }, "the selection of this project (graph)")

  local with = select_with(answer, "/the/checkouts")
  eq(seen_args.consumers, "/the/checkouts", "the provider is given the directory the caller named")
  eq(with.files, plain.files, "with --consumers: the same files")
  eq(with.reason, plain.reason, "with --consumers: the same reasons")
  eq(with.all, plain.all, "with --consumers: the same verdict about everything")
  eq(with.source, plain.source, "with --consumers: the same source")
  eq(#with.cross_repo, 4, "with --consumers: the consumers of the answer")
  eq(
    with.cross_repo[1].specs[1],
    "TESTS/bindings_spec.lua",
    "the specs of the consumer are relative to ITS root"
  )
  eq(with.warnings, plain.warnings, "and no new warning")
  local lines = table.concat(affected.cross_lines(with), "\n")
  ok(
    lines:find("cascade.nvim: 19 spec(s) reach the change", 1, true),
    "the measured consumer is listed"
  )
  ok(lines:find("its own module map is stale", 1, true), "a stale map of the consumer is said")
  ok(
    lines:find("13 spec(s) it cannot place (run them too)", 1, true) == nil,
    "(that was lib.nvim's, not here)"
  )
  ok(
    lines:find(
      "gitsuite.nvim: not measured (no committed module map): run the full suite of this repository",
      1,
      true
    ),
    "an unmeasured consumer says why and names the full suite"
  )
  ok(
    lines:find("a consumer that is not below /the/checkouts is invisible here", 1, true),
    "an unknown consumer is invisible, and the line says so"
  )
  ok(lines:find("not measured is not unaffected", 1, true), "not measured is not unaffected")

  do
    -- asked, and nobody is affected: the line says exactly that (and not "not asked")
    local quiet = complete_answer()
    quiet.cross_repo = {}
    local said = table.concat(affected.cross_lines(select_with(quiet, "/the/checkouts")), "\n")
    ok(
      said:find("no consumer below the directory is affected", 1, true) ~= nil,
      "asked, nobody affected"
    )
    ok(said:find("not asked", 1, true) == nil, "and it was asked")
  end

  -- a stale graph of THIS project still returns the consumers (it selects everything, the hint stands)
  local stale = select_with(recorded, "/the/checkouts")
  eq(stale.all, true, "the recording has a stale graph: everything runs here")
  eq(#stale.cross_repo, 4, "and the consumers are still listed")

  -- ---- a spec of a consumer never selects or narrows anything here ------------------------------------
  local hostile_specs = complete_answer()
  hostile_specs.cross_repo = { { repo = "x", measured = true, specs = { "TESTS/own_spec.lua" } } }
  local r = select_with(hostile_specs, "/c")
  eq(
    r.files,
    { "TESTS/lua_helpers_spec.lua" },
    "a consumer spec with the name of an own spec selects nothing here"
  )

  -- ---- an answer without cross_repo (an older documentation.nvim) --------------------------------------
  local old = complete_answer()
  old.cross_repo = nil
  r = select_with(old, "/c")
  eq(r.cross_repo, {}, "no field: no consumer")
  eq(r.files, plain.files, "no field: the same selection")
  ok(
    table.concat(r.warnings, "\n"):find("answered without cross_repo", 1, true) ~= nil,
    "no field: the person is told that nothing was measured"
  )
  r = select_with(old, nil)
  eq(r.warnings, {}, "no field and no --consumers: nothing to say (behaviour as before)")

  -- ---- hostile values: the consumers are dropped and said, the selection stays ---------------------------
  local control = "x\27[31m"
  local hostile = {
    ["a repo with a slash"] = { { repo = "a/b", measured = false, reason = "x" } },
    ["a repo with a control character"] = { { repo = control, measured = false, reason = "x" } },
    ["a repo that is not a string"] = { { repo = 5, measured = false, reason = "x" } },
    ["measured is not a boolean"] = { { repo = "a", measured = "yes", specs = {} } },
    ["not measured without a reason"] = { { repo = "a", measured = false } },
    ["a reason with a control character"] = { { repo = "a", measured = false, reason = control } },
    ["an absolute spec path"] = { { repo = "a", measured = true, specs = { "/etc/passwd" } } },
    ["a drive path"] = { { repo = "a", measured = true, specs = { "C:/x_spec.lua" } } },
    ["a spec path that leaves the checkout"] = {
      { repo = "a", measured = true, specs = { "../x_spec.lua" } },
    },
    ["a spec path with a backslash"] = {
      { repo = "a", measured = true, specs = { "TESTS\\x_spec.lua" } },
    },
    ["a spec with a control character"] = {
      { repo = "a", measured = true, specs = { "TESTS/\n_spec.lua" } },
    },
    ["specs that are no list"] = { { repo = "a", measured = true, specs = "TESTS/x_spec.lua" } },
    ["specs with a hole"] = { { repo = "a", measured = true, specs = { [1] = "a", [3] = "b" } } },
    ["a spec that is a table"] = { { repo = "a", measured = true, specs = { {} } } },
    ["a name that is far too long"] = {
      { repo = "a", measured = true, specs = { string.rep("x", 5000) } },
    },
    ["modules that are no strings"] = {
      { repo = "a", measured = true, specs = {}, modules = { 1 } },
    },
    ["a consumer that is a string"] = { "a" },
    ["a list that is a map"] = { a = { repo = "a", measured = false, reason = "x" } },
    ["cross_repo that is a string"] = "all of them",
  }
  local names = vim.tbl_keys(hostile)
  table.sort(names)
  for _, label in ipairs(names) do
    local a = complete_answer()
    a.cross_repo = hostile[label]
    r = select_with(a, "/c")
    eq(r.cross_repo, {}, label .. ": nothing of it is kept")
    eq(r.files, plain.files, label .. ": the selection stays")
    ok(
      table.concat(r.warnings, "\n"):find("cross-repo: the answer cannot be used", 1, true) ~= nil,
      label .. ": and it says that no consumer was measured"
    )
  end
  do
    local a = complete_answer()
    local many = {}
    for i = 1, affected.MAX_CONSUMERS + 1 do
      many[i] = { repo = "r" .. i, measured = false, reason = "x" }
    end
    a.cross_repo = many
    r = select_with(a, "/c")
    eq(r.cross_repo, {}, "more consumers than the bound: nothing kept")
    a = complete_answer()
    a.version = 2
    a.cross_repo = { { repo = "a", measured = false, reason = "x" } }
    r = select_with(a, "/c")
    eq(r.cross_repo, {}, "a contract version that is not 1: the consumers are not read")
    ok(
      table.concat(r.warnings, "\n"):find("only 1 is understood", 1, true) ~= nil,
      "and the version is named"
    )
    a = complete_answer()
    a.cross_repo = {
      {
        repo = "a",
        measured = true,
        specs = { "TESTS/ok_spec.lua" },
        unplaced_specs = {},
        modules = { "m" },
      },
    }
    r = select_with(a, "/c")
    eq(#r.cross_repo, 1, "a clean consumer is kept")
  end

  -- the provider cannot be reached: the consumers are said to be unmeasured, nothing else changes
  do
    local res = affected.select({
      root = root,
      specs = specs,
      changed = { "lua/lib/lua/numeral/roman.lua" },
      consumers = "/c",
      getenv = function() end,
      cache_dir = cdir,
      roots = { "TESTS" },
      provider = function()
        return nil, "no module map"
      end,
    })
    eq(res.cross_repo, {}, "no answer: no consumer")
    ok(
      table
        .concat(res.warnings, "\n")
        :find("cross-repo: no consumer was measured (documentation.nvim gave no answer", 1, true)
        ~= nil,
      "no answer: said"
    )
    local lines_no_answer = table.concat(affected.cross_lines(res), "\n")
    ok(
      lines_no_answer:find("invisible", 1, true) ~= nil,
      "no answer: the invisibility is still said"
    )
  end

  -- no module changed: no consumer is affected, and the line says why
  do
    local res = affected.select({
      root = root,
      specs = specs,
      changed = { "TESTS/own_spec.lua" },
      consumers = "/c",
      getenv = function() end,
      cache_dir = cdir,
      roots = { "TESTS" },
      provider = function()
        error("must not be asked")
      end,
    })
    eq(res.files, { "TESTS/own_spec.lua" }, "only a spec changed")
    ok(
      table
        .concat(affected.cross_lines(res), "\n")
        :find("no module of this project changed", 1, true) ~= nil,
      "a change without a module reaches no consumer"
    )
  end

  -- the selection ended before the provider was asked (git cannot tell what changed)
  do
    local res = affected.select({
      root = root,
      specs = specs,
      mode = "since",
      since = "no-such-revision",
      consumers = "/c",
      getenv = function() end,
      cache_dir = cdir,
      roots = { "TESTS" },
      run = function()
        return { code = 128, stdout = "", stderr = "fatal: bad revision" }
      end,
      provider = function()
        error("must not be asked")
      end,
    })
    eq(res.all, true, "git failed: everything runs")
    ok(
      table.concat(affected.cross_lines(res), "\n"):find("not asked", 1, true) ~= nil,
      "git failed: the consumers were not asked, and it says so"
    )
  end

  -- ---- where the directory comes from -------------------------------------------------------------------
  do
    local function plan(arg_value, cfg_value)
      return {
        root = root,
        args = { consumers = arg_value },
        project = { affected = { consumers = cfg_value } },
      }
    end
    eq(
      cached.consumers_dir(plan(nil, nil)),
      nil,
      "nobody named a directory: none (this runner does not know $REPOS_DIR)"
    )
    local abs = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(abs, "p")
    eq(
      cached.consumers_dir(plan(abs, nil)),
      (vim.uv.fs_realpath(abs):gsub("\\", "/")),
      "an absolute --consumers"
    )
    eq(
      cached.consumers_dir(plan(abs, "ignored")),
      (vim.uv.fs_realpath(abs):gsub("\\", "/")),
      "--consumers wins over the file"
    )
    vim.fn.mkdir(root .. "/sibling", "p")
    eq(
      cached.consumers_dir(plan(nil, "sibling")),
      (vim.uv.fs_realpath(root .. "/sibling"):gsub("\\", "/")),
      "the key of .testing.lua is relative to the project root"
    )
    eq(
      cached.consumers_dir(plan(nil, "../" .. vim.fs.basename(root) .. "/sibling")),
      (vim.uv.fs_realpath(root .. "/sibling"):gsub("\\", "/")),
      "and may leave the project (the checkouts are its neighbours)"
    )
    vim.fn.delete(abs, "rf")
  end

  -- ---- the flags and the key ---------------------------------------------------------------------------
  do
    local a, problem = args_mod.parse({ ".", "--changed", "--consumers", "../x" })
    ok(a ~= nil, "--consumers with --changed: " .. tostring(problem))
    eq(a and a.consumers, "../x", "the value")
    a = args_mod.parse({ ".", "--since", "HEAD~1", "--consumers=/c", "--list" })
    eq(a and a.consumers, "/c", "--consumers=<dir> with --since and --list")
    a, problem = args_mod.parse({ ".", "--consumers", "../x" })
    ok(
      a == nil and problem:find("needs --changed, --since or --affected", 1, true) ~= nil,
      "alone it asks nothing"
    )
    a, problem = args_mod.parse({ ".", "--consumers" })
    ok(a == nil and problem:find("needs a value", 1, true) ~= nil, "it needs a value")

    local cfg, probs = project_cfg.validate({ affected = { consumers = "../" } })
    eq(probs, {}, "the key is accepted")
    eq(cfg.affected.consumers, "../", "and kept")
    local c5, probs5 = project_cfg.validate({ affected = { consumers = 5 } })
    eq(#probs5, 1, "a number is refused")
    eq(c5.affected, {}, "and not kept")
    ok(probs5[1]:find("affected.consumers", 1, true) ~= nil, "naming the key")
    local _, probs_nl = project_cfg.validate({ affected = { consumers = "a\nb" } })
    eq(#probs_nl, 1, "a control character is refused")
    local dflt = project_cfg.validate(nil)
    eq(dflt.affected, {}, "default: no directory")
  end

  require("testing.cache").reset()
  S.remove(root)
  S.remove(cdir)
end
