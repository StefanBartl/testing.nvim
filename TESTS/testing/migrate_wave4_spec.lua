-- TESTS/testing/migrate_wave4_spec.lua -- what the fourth migration wave taught the tool:
--   * plenary in `deps` (telescope.nvim does not load without it) and the plan removing the plenary
--     checkout of the CI contradicted each other: the checkout stays when plenary is a dependency,
--   * a workflow comment that says a plugin is deliberately NOT checked out keeps it out of `deps`
--     and out of the checkout steps the plan adds (images.nvim: ui.nvim, gopath.nvim).

---@diagnostic disable: missing-fields, param-type-mismatch, need-check-nil

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
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end
  local migrate = require("testing.migrate")
  local analyze = require("testing.migrate.analyze")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local fleet_dir = tmp .. "/fleet"

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
  write(fleet_dir .. "/lib.nvim/lua/lib/nvim/notify/init.lua", "return {}\n")
  write(fleet_dir .. "/ui.nvim/lua/ui/kit/init.lua", "return {}\n")

  local SPEC = 'describe("x", function()\n  it("y", function() assert.is_true(true) end)\nend)\n'

  ---@param name string
  ---@param lua_text string
  ---@param ci string
  ---@return string root
  local function mk(name, lua_text, ci)
    local root = fleet_dir .. "/" .. name
    write(root .. "/lua/" .. name:gsub("%.nvim$", "") .. "/init.lua", lua_text)
    write(root .. "/TESTS/a_spec.lua", SPEC)
    write(root .. "/.github/workflows/ci.yml", ci)
    return root
  end

  local CI_HEAD = [=[
name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v5
]=]
  local CI_PLENARY = [=[
      - name: Checkout plenary.nvim
        uses: actions/checkout@v5
        with:
          repository: nvim-lua/plenary.nvim
          path: plenary.nvim
      - name: Checkout telescope.nvim
        uses: actions/checkout@v5
        with:
          repository: nvim-telescope/telescope.nvim
          path: telescope.nvim
      - run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS"
]=]

  -- ---------------------------------------------------------------- plenary: deps and CI agree

  local r1 = mk(
    "tele.nvim",
    'local t = require("telescope")\nlocal n = require("lib.nvim.notify")\nreturn { t, n }\n',
    CI_HEAD .. CI_PLENARY
  )
  local rep1 = migrate.analyze(r1, { fleet_root = fleet_dir })
  local names1 = {}
  for _, d in ipairs(rep1.deps.list) do
    names1[#names1 + 1] = d.name
  end
  ok(
    vim.tbl_contains(names1, "plenary.nvim"),
    "plenary is a dependency (telescope needs it): " .. vim.inspect(names1)
  )
  eq(rep1.plenary.keep_ci, true, "and then its CI checkout is kept")
  local plan1 = migrate.plan(rep1)
  local ci_after
  for _, op in ipairs(plan1.ops) do
    if op.path == ".github/workflows/ci.yml" then
      ci_after = op.after
    end
  end
  ok(ci_after ~= nil, "the CI is rewritten (the runner call)")
  has(ci_after, "nvim-lua/plenary.nvim", "the plenary checkout step is still there")
  has(
    table.concat(rep1.risks, "\n"),
    "the CI keeps its plenary checkout",
    "and the report says why"
  )

  -- without plenary in `deps` the checkout still goes (the old behavior)
  local r2 = mk("plain.nvim", 'return require("lib.nvim.notify")\n', CI_HEAD .. CI_PLENARY)
  local rep2 = migrate.analyze(r2, { fleet_root = fleet_dir })
  eq(rep2.plenary.keep_ci, false, "a repository that does not need plenary drops its checkout")

  -- ---------------------------------------------------------------- a workflow comment keeps a plugin away

  eq(
    analyze.kept_away(
      "# ui.nvim is deliberately NOT checked out: a spec needs it unreachable\n",
      "ui.nvim"
    ),
    true,
    "kept_away: 'deliberately NOT checked out'"
  )
  eq(
    analyze.kept_away("# gopath.nvim stays off the runtimepath\n", "gopath.nvim"),
    true,
    "kept_away: stays off"
  )
  eq(
    analyze.kept_away("# ui.nvim is checked out for the menu specs\n", "ui.nvim"),
    false,
    "kept_away: a plain mention is not enough"
  )
  eq(
    analyze.kept_away("      - run: echo ui.nvim is not checked out\n", "ui.nvim"),
    false,
    "kept_away: only a comment counts"
  )
  eq(
    analyze.kept_away("# ui.nvim is deliberately NOT checked out\n", "gopath.nvim"),
    false,
    "kept_away: another plugin's comment"
  )
  for _, c in ipairs({
    { "# my-ui.nvim is not checked out", "ui.nvim", "a longer name that ends like this one" },
    { "# ui.nvim.old is not checked out", "ui.nvim", "a name that continues with a suffix" },
    { "# not checked out: ui.nvim", "ui.nvim", "the phrase stands BEFORE the name" },
    { "# ui.nvim is not kept off", "ui.nvim", "the phrase is negated after the name" },
    { "# ui.nvim is no longer kept off", "ui.nvim", "the statement is a thing of the past" },
    { "# ui.nvim and lib.nvim are not checked out", "ui.nvim", "two plugins on one line (first)" },
    {
      "# ui.nvim and lib.nvim are not checked out",
      "lib.nvim",
      "two plugins on one line (second)",
    },
    { "# lib.nvim is checked out. ui.nvim is used", "lib.nvim", "another sentence says nothing" },
  }) do
    eq(analyze.kept_away(c[1] .. "\n", c[2]), false, "kept_away: " .. c[3])
  end
  eq(
    analyze.kept_away("# lib.nvim is needed. ui.nvim is kept off the runtimepath.\n", "ui.nvim"),
    false,
    "kept_away: a phrase of the next sentence is not about the name (a second name on the line closes nothing)"
  )
  eq(
    analyze.kept_away("# the menu specs: ui.nvim stays off, on purpose\n", "ui.nvim"),
    true,
    "kept_away: a clear statement after the name still works"
  )
  -- `never` / `unless` AFTER the phrase qualify it, they do not turn it around: the old CI still kept the plugin away
  eq(
    analyze.kept_away(
      "# ui.nvim is deliberately not checked out: the plugin must work without it and never hard-require it\n",
      "ui.nvim"
    ),
    true,
    "kept_away: 'never' after the phrase does not flip it"
  )
  eq(
    analyze.kept_away("# ui.nvim is kept off the runtimepath unless a spec adds it\n", "ui.nvim"),
    true,
    "kept_away: 'unless' after the phrase does not flip it"
  )
  -- ... and BEFORE the phrase they do
  for _, c in ipairs({
    { "# ui.nvim is never kept off the runtimepath", "never before the phrase" },
    { "# ui.nvim is never deliberately absent", "never before another phrase" },
    {
      "# ui.nvim is checked out unless the matrix says not checked out",
      "unless before the phrase",
    },
  }) do
    eq(analyze.kept_away(c[1] .. "\n", "ui.nvim"), false, "kept_away: " .. c[2])
  end

  local r3 = mk(
    "away.nvim",
    'local u = require("ui.kit")\nlocal n = require("lib.nvim.notify")\nreturn { u, n }\n',
    CI_HEAD
      .. "      # ui.nvim is deliberately NOT checked out: a spec needs `ui.kit` unreachable.\n"
      .. "      - run: bash scripts/test.sh\n"
  )
  local rep3 = migrate.analyze(r3, { fleet_root = fleet_dir })
  local in_list = {}
  for _, d in ipairs(rep3.deps.list) do
    in_list[d.name] = true
  end
  eq(in_list["ui.nvim"], nil, "ui.nvim is not proposed as a dependency")
  eq(in_list["lib.nvim"], true, "lib.nvim still is")
  local in_optional = false
  for _, d in ipairs(rep3.deps.optional) do
    in_optional = in_optional or d.name == "ui.nvim"
  end
  ok(in_optional, "it is listed as optional")
  local plan3 = migrate.plan(rep3)
  for _, op in ipairs(plan3.ops) do
    if op.path == ".github/workflows/ci.yml" and op.after then
      lacks(
        op.after,
        "ui.nvim\n          path: .deps/ui.nvim",
        "no checkout step for ui.nvim is added"
      )
    end
    if op.path == ".testing.lua" and op.after then
      lacks(op.after, '"ui.nvim"', ".testing.lua does not list ui.nvim")
    end
  end

  -- ---------------------------------------------------------------- the output file the old call wrote

  local r5 = mk(
    "readback.nvim",
    'return require("lib.nvim.notify")\n',
    CI_HEAD
      .. "      - name: Tests\n"
      .. "        run: |\n"
      .. "          set +e\n"
      .. "          nvim -n -i NONE --headless -u NONE \\\n"
      .. '            -c "luafile TESTS/run.lua" \\\n'
      .. '            -c "qa!" > out.log 2>&1\n'
      .. "          cat out.log\n"
      .. "          grep -q READBACK_TESTS_OK out.log\n"
      .. "          grep -q SOMETHING_ELSE out.log\n"
  )
  write(r5 .. "/TESTS/run.lua", 'print("READBACK_TESTS_OK")\n')
  local plan5 = migrate.run(r5, { fleet_root = fleet_dir })
  local ci5
  for _, op in ipairs(plan5.ops) do
    if op.path == ".github/workflows/ci.yml" then
      ci5 = op.after
    end
  end
  ok(ci5 ~= nil, "the workflow is rewritten")
  has(ci5, "scripts/test.sh", "the runner call is replaced")
  lacks(ci5, "cat out.log", "the read-back of the old output file is removed")
  lacks(
    ci5,
    "grep -q READBACK_TESTS_OK",
    "the sentinel grep goes: scripts/test.sh passes --sentinel"
  )
  has(
    ci5,
    "grep -q SOMETHING_ELSE out.log",
    "a grep for something else stays: the plan cannot vouch for it"
  )

  -- an inverted grep asks the opposite question: it is neither removed nor "covered" by the sentinel check
  for i, inverted in ipairs({
    "grep -qv READBACK_TESTS_OK out.log",
    "grep -q -v READBACK_TESTS_OK out.log",
    "! grep -q READBACK_TESTS_OK out.log",
  }) do
    local rv = mk(
      "inverted" .. i .. ".nvim",
      'return require("lib.nvim.notify")\n',
      CI_HEAD
        .. "      - name: Tests\n"
        .. "        run: |\n"
        .. "          nvim -n -i NONE --headless -u NONE \\\n"
        .. '            -c "luafile TESTS/run.lua" \\\n'
        .. '            -c "qa!" > out.log 2>&1\n'
        .. "          "
        .. inverted
        .. "\n"
    )
    write(rv .. "/TESTS/run.lua", 'print("READBACK_TESTS_OK")\n')
    local planv = migrate.run(rv, { fleet_root = fleet_dir })
    local civ
    for _, op in ipairs(planv.ops) do
      if op.path == ".github/workflows/ci.yml" then
        civ = op.after
      end
    end
    ok(civ ~= nil, "the workflow is rewritten: " .. inverted)
    has(civ, inverted, "the inverted check stays: " .. inverted)
    has(table.concat(planv.notes, "\n"), "still reads out.log", "and is reported: " .. inverted)
  end

  -- ---------------------------------------------------------------- spec scripts started from a -c command

  do
    local root = fleet_dir .. "/gop.nvim"
    write(root .. "/lua/gop/init.lua", 'return require("lib.nvim.notify")\n')
    write(
      root .. "/scripts/ci/harness.lua",
      [==[
local H = {}
H.failures = {}
function H.check(name, fn)
  local ok, err = pcall(fn)
  if not ok then H.failures[#H.failures + 1] = name .. ": " .. tostring(err) end
end
function H.tmpdir() return vim.fn.tempname() end
return H
]==]
    )
    write(
      root .. "/scripts/ci/specs/a_spec.lua",
      [==[
---@param H table
return function(H)
  H.check("a", function() H.tmpdir() end)
end
]==]
    )
    write(
      root .. "/.github/workflows/ci.yml",
      CI_HEAD
        .. "      - name: Headless\n"
        .. "        run: |\n"
        .. "          nvim -n -i NONE --headless --noplugin -u NONE \\\n"
        .. '            --cmd "set runtimepath+=${{ github.workspace }}/deps/lib.nvim" \\\n'
        .. "            -c \"lua dofile('scripts/ci/headless_tests.lua')\"\n"
    )
    write(root .. "/scripts/ci/headless_tests.lua", 'print("headless")\n')
    local rep = migrate.analyze(root, { fleet_root = fleet_dir })
    ok(rep.harness.path ~= nil, "scripts/ci/harness.lua counts as the project's own harness")
    has(rep.harness.path, "scripts/ci/harness.lua", "and is named")
    eq(rep.policy.isolated, "file", "specs started from a -c command: one editor per file")
    eq(rep.policy.host, "c", "and host c (vim_did_enter == 0, not `nvim -l`)")
    local plan = migrate.plan(rep)
    local ci_text
    for _, op in ipairs(plan.ops) do
      if op.path == ".github/workflows/ci.yml" then
        ci_text = op.after
      end
    end
    ok(ci_text ~= nil, "the workflow is rewritten")
    has(ci_text, "scripts/test.sh", "the dofile call is mapped to the runner")
    lacks(ci_text, "headless_tests.lua", "and gone")
    has(
      table.concat(plan.notes, "\n"),
      "--file headless_tests",
      "the note says how to narrow the call"
    )
  end

  -- ---------------------------------------------------------------- <DEP>_PATH of the run step

  write(fleet_dir .. "/hover.nvim/lua/hover/init.lua", "return {}\n")
  local r4 = mk(
    "envp.nvim",
    'local h = require("hover")\nlocal n = require("lib.nvim.notify")\nreturn { h, n }\n',
    CI_HEAD
      .. "      - name: Run\n"
      .. "        env:\n"
      .. "          HOVER_NVIM_PATH: ${{ github.workspace }}/../hover.nvim\n"
      .. '          OTHER_FLAG: "1"\n'
      .. '        run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS"\n'
  )
  local plan4 = migrate.run(r4, { fleet_root = fleet_dir })
  local ci4
  for _, op in ipairs(plan4.ops) do
    if op.path == ".github/workflows/ci.yml" then
      ci4 = op.after
    end
  end
  ok(ci4 ~= nil, "the workflow is rewritten")
  has(ci4, "HOVER_NVIM_DIR:", "HOVER_NVIM_PATH is renamed to the name testing.deps reads")
  lacks(ci4, "HOVER_NVIM_PATH", "the old name is gone")
  has(ci4, 'OTHER_FLAG: "1"', "an unrelated variable stays")

  -- <DEP>_DIR set already: no second key (invalid YAML), the old one stays and the plan says so
  local r6 = mk(
    "envdup.nvim",
    'local h = require("hover")\nlocal n = require("lib.nvim.notify")\nreturn { h, n }\n',
    CI_HEAD
      .. "      - name: Run\n"
      .. "        env:\n"
      .. "          HOVER_NVIM_PATH: ${{ github.workspace }}/../hover.nvim\n"
      .. "          HOVER_NVIM_DIR: ${{ github.workspace }}/../hover.nvim\n"
      .. '        run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS"\n'
  )
  local plan6 = migrate.run(r6, { fleet_root = fleet_dir })
  local ci6
  for _, op in ipairs(plan6.ops) do
    if op.path == ".github/workflows/ci.yml" then
      ci6 = op.after
    end
  end
  ok(ci6 ~= nil, "the workflow is rewritten (dup)")
  local _, n_dir = ci6:gsub("HOVER_NVIM_DIR:", "")
  eq(n_dir, 1, "HOVER_NVIM_DIR appears once: no duplicate key")
  has(ci6, "HOVER_NVIM_PATH:", "the old key stays")
  has(
    table.concat(plan6.notes, "\n"),
    "HOVER_NVIM_PATH and HOVER_NVIM_DIR are both set",
    "and the plan says so"
  )

  -- another reader of <DEP>_PATH (a script of the repository): not renamed, reported
  local r7 = mk(
    "envread.nvim",
    'local h = require("hover")\nlocal n = require("lib.nvim.notify")\nreturn { h, n }\n',
    CI_HEAD
      .. "      - name: Run\n"
      .. "        env:\n"
      .. "          HOVER_NVIM_PATH: ${{ github.workspace }}/../hover.nvim\n"
      .. '        run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS"\n'
  )
  write(r7 .. "/scripts/helper.sh", 'echo "$HOVER_NVIM_PATH"\n')
  local plan7 = migrate.run(r7, { fleet_root = fleet_dir })
  local ci7
  for _, op in ipairs(plan7.ops) do
    if op.path == ".github/workflows/ci.yml" then
      ci7 = op.after
    end
  end
  ok(ci7 ~= nil, "the workflow is rewritten (reader)")
  has(ci7, "HOVER_NVIM_PATH:", "a variable another file reads is not renamed")
  lacks(ci7, "HOVER_NVIM_DIR:", "and no second spelling appears")
  has(table.concat(plan7.notes, "\n"), "scripts/helper.sh", "the reader is named in the notes")

  -- the same key SET in another job is no reader: the rename of one step breaks nothing there
  local ENV_STEP = "        env:\n"
    .. "          HOVER_NVIM_PATH: ${{ github.workspace }}/../hover.nvim\n"
  local OLD_RUN =
    '        run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS"\n'
  ---@param name string
  ---@param ci string
  ---@return string|nil after The workflow of the plan.
  ---@return string notes
  local function plan_ci(name, ci)
    local root = mk(
      name,
      'local h = require("hover")\nlocal n = require("lib.nvim.notify")\nreturn { h, n }\n',
      ci
    )
    local plan = migrate.run(root, { fleet_root = fleet_dir })
    for _, op in ipairs(plan.ops) do
      if op.path == ".github/workflows/ci.yml" then
        return op.after, table.concat(plan.notes, "\n")
      end
    end
    return nil, table.concat(plan.notes, "\n")
  end
  local TWO_JOBS_HEAD = "name: CI\non: [push]\njobs:\n"
    .. "  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v5\n"
    .. "      - name: Lint\n"
    .. ENV_STEP
    .. "        run: echo lint\n"
    .. "  test:\n    runs-on: ubuntu-latest\n    timeout-minutes: 15\n    steps:\n      - uses: actions/checkout@v5\n"
  local ci8, notes8 =
    plan_ci("envjobs.nvim", TWO_JOBS_HEAD .. "      - name: Run\n" .. ENV_STEP .. OLD_RUN)
  ok(ci8 ~= nil, "the workflow is rewritten (two jobs)")
  has(
    ci8,
    "HOVER_NVIM_DIR:",
    "the key of the run step is renamed although another job sets the old name"
  )
  lacks(
    notes8,
    "also read by the workflow",
    "and the assignment of the other job is not named as a reader"
  )
  local _, n_old8 = ci8:gsub("HOVER_NVIM_PATH:", "")
  eq(n_old8, 1, "the other job keeps its own line untouched")

  -- two jobs that both run the old runner: both are renamed, neither one reads the other
  local TWO_RUNNERS = "name: CI\non: [push]\njobs:\n"
    .. "  a:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v5\n"
    .. "      - name: Run\n"
    .. ENV_STEP
    .. OLD_RUN
    .. "  b:\n    runs-on: macos-latest\n    steps:\n      - uses: actions/checkout@v5\n"
    .. "      - name: Run\n"
    .. ENV_STEP
    .. OLD_RUN
  local ci9, notes9 = plan_ci("envrunners.nvim", TWO_RUNNERS)
  ok(ci9 ~= nil, "the workflow is rewritten (two runner jobs)")
  lacks(ci9, "HOVER_NVIM_PATH", "both old names are gone")
  local _, n_new9 = ci9:gsub("HOVER_NVIM_DIR:", "")
  eq(n_new9, 2, "both keys are renamed")
  lacks(notes9, "also read by", "no note about readers")

  -- a REAL reader in the workflow (a later step of the job) still keeps the name
  local ci10, notes10 = plan_ci(
    "envreader.nvim",
    CI_HEAD
      .. "      - name: Run\n"
      .. ENV_STEP
      .. OLD_RUN
      .. '      - run: echo "$HOVER_NVIM_PATH"\n'
  )
  ok(ci10 ~= nil, "the workflow is rewritten (workflow reader)")
  has(ci10, "HOVER_NVIM_PATH:", "a later step that reads the variable keeps the name")
  lacks(ci10, "HOVER_NVIM_DIR:", "and no second spelling appears")
  has(notes10, "also read by the workflow", "the note names the workflow as the reader")
  -- a value that names the variable again is a read too
  local ci11, notes11 = plan_ci(
    "envself.nvim",
    TWO_JOBS_HEAD:gsub(
      "HOVER_NVIM_PATH: ${{ github.workspace }}/../hover.nvim",
      "HOVER_NVIM_PATH: ${{ env.HOVER_NVIM_PATH }}/x",
      1
    )
      .. "      - name: Run\n"
      .. ENV_STEP
      .. OLD_RUN
  )
  ok(ci11 ~= nil, "the workflow is rewritten (self reference)")
  has(notes11, "also read by the workflow", "a value that reads the name is a reader")

  vim.fn.delete(tmp, "rf")
end
