-- TESTS/testing/migrate_wave2_spec.lua -- what the second migration wave taught the tool:
--   * a dependency without a `ci-verified` branch is checked out from `main` (and the plan says so);
--     an unanswerable question keeps `ci-verified` and says so; the answer is a seam, never the network,
--   * an existing TESTS/minimal_init.lua is replaced by the gate (four places, fatal on a missing
--     dependency) and what it set up besides the runtimepath is carried over,
--   * CI: names that said plenary are neutral, LIB_NVIM_PATH goes, inserted checkouts are separated
--     by a blank line,
--   * the env override name of a dependency comes from its repository name (a plan note).

---@diagnostic disable: missing-fields, param-type-mismatch, need-check-nil

-- @cache-allow spawn
-- (`vim.system` is replaced by a stub: no process starts)
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
  local legacy_init = require("testing.migrate.legacy_init")
  local branches = require("testing.migrate.branches")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
  local function op_by_path(plan, path)
    for _, op in ipairs(plan.ops) do
      if op.path == path then
        return op
      end
    end
  end
  local function notes_of(plan)
    return table.concat(plan.notes, "\n")
  end

  -- ---------------------------------------------------------------- fixtures

  local fleet_dir = tmp .. "/fleet"
  write(fleet_dir .. "/lib.nvim/lua/lib/nvim/notify/init.lua", "return {}\n")
  -- a dependency that has only `main` (like color_my_ascii.nvim)
  write(fleet_dir .. "/color_my_ascii.nvim/lua/color_my_ascii/core.lua", "return {}\n")

  -- shaped like the init file of dap.nvim before its migration
  local OLD_MINIT = [=[
-- Minimal init for running the plenary.nvim test suite headlessly:
--   nvim --headless --noplugin -u TESTS/minimal_init.lua \
--     -c "PlenaryBustedDirectory TESTS/wkddap { minimal_init = 'TESTS/minimal_init.lua' }"
--
-- plenary.nvim and lib.nvim are resolved via env vars rather than a
-- hardcoded path.

vim.opt.rtp:prepend(vim.fn.getcwd())

local function prepend_env(var)
  local path = os.getenv(var)
  if path and path ~= "" then
    vim.opt.rtp:prepend(path)
  end
end

prepend_env("PLENARY_PATH")
prepend_env("LIB_NVIM_PATH")

vim.cmd("runtime plugin/plenary.vim")

-- Swap and shada stay off for the whole suite, including plenary's child
-- processes that reuse this file: stale swap files fail suites with E326.
vim.o.swapfile = false
vim.o.shadafile = "NONE"
]=]

  local OLD_SH = [=[
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim -n --clean --headless -u TESTS/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua', sequential = true }"
]=]

  local OLD_CI = [=[
name: CI

on:
  push:

jobs:
  test:
    name: plenary tests (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    timeout-minutes: 15
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v5
        with:
          path: wave.nvim

      - uses: actions/checkout@v5
        with:
          repository: nvim-lua/plenary.nvim
          path: plenary.nvim

      - uses: actions/checkout@v5
        with:
          repository: StefanBartl/lib.nvim
          path: lib.nvim
          ref: ci-verified

      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true

      - name: Run plenary test suite
        working-directory: wave.nvim
        env:
          PLENARY_PATH: ${{ github.workspace }}/plenary.nvim
          LIB_NVIM_PATH: ${{ github.workspace }}/lib.nvim
          COLOR_MY_ASCII_DIR: ${{ github.workspace }}/cma
        run: |
          nvim -n -i NONE --headless --noplugin -u TESTS/minimal_init.lua \
            -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua' }"
]=]

  local function mk_repo(name)
    local root = fleet_dir .. "/" .. name
    local mod = name:gsub("%.nvim$", "")
    write(
      root .. "/lua/" .. mod .. "/init.lua",
      'local n = require("lib.nvim.notify")\nlocal c = require("color_my_ascii.core")\nreturn {}\n'
    )
    write(
      root .. "/TESTS/a_spec.lua",
      'describe("a", function()\n  it("b", function()\n    assert.is_true(true)\n  end)\nend)\n'
    )
    write(root .. "/TESTS/minimal_init.lua", OLD_MINIT)
    write(root .. "/scripts/test.sh", OLD_SH)
    write(root .. "/.github/workflows/ci.yml", OLD_CI)
    return root
  end

  local repo = mk_repo("wave.nvim")

  -- ---------------------------------------------------------------- ci-verified existence

  local asked = {}
  local function stub(answers)
    return function(owner, name)
      asked[#asked + 1] = owner .. "/" .. name
      local a = answers[name]
      if a == nil then
        return true
      end
      if a == "unknown" then
        return nil, "could not resolve host"
      end
      return a
    end
  end

  local plan = migrate.run(repo, {
    fleet_root = fleet_dir,
    branch_exists = stub({ ["color_my_ascii.nvim"] = false }),
  })
  eq(plan.error, nil, "the fixture repository plans")
  local ci_op = assert(op_by_path(plan, ".github/workflows/ci.yml"))
  local ci_text = ci_op.after
  has(
    ci_text,
    'repository: "StefanBartl/color_my_ascii.nvim"\n          path: color_my_ascii.nvim\n          ref: main',
    "a dependency without ci-verified is checked out from main"
  )
  has(
    ci_text,
    "color_my_ascii.nvim has no ci-verified branch: checked out from main",
    "the step carries a comment that says why"
  )
  has(
    ci_text,
    "path: testing.nvim\n          ref: ci-verified",
    "testing.nvim (which has the branch) keeps ci-verified"
  )
  has(
    notes_of(plan),
    "dependency color_my_ascii.nvim has no ci-verified branch: pinned to main",
    "the plan says so"
  )
  ok(vim.tbl_contains(asked, "StefanBartl/color_my_ascii.nvim"), "the seam was asked, not the net")
  local ref_count = select(2, ci_text:gsub('repository: "StefanBartl/color_my_ascii.nvim"', ""))
  eq(ref_count, 1, "and the step exists once")
  lacks(
    table.concat(plan.risks, "\n"),
    "confirm that branch exists",
    "an answered question leaves no risk to confirm"
  )

  -- unknown (no network): ci-verified stays, the plan says it could not check
  local plan_unknown = migrate.run(repo, {
    fleet_root = fleet_dir,
    branch_exists = stub({ ["color_my_ascii.nvim"] = "unknown" }),
  })
  local unknown_ci = assert(op_by_path(plan_unknown, ".github/workflows/ci.yml")).after
  has(
    unknown_ci,
    'repository: "StefanBartl/color_my_ascii.nvim"\n          path: color_my_ascii.nvim\n          ref: ci-verified',
    "an unanswerable question keeps ci-verified"
  )
  has(
    notes_of(plan_unknown),
    "could not check whether color_my_ascii.nvim has a ci-verified branch",
    "and says that it could not check"
  )
  has(
    table.concat(plan_unknown.risks, "\n"),
    "confirm that branch exists in color_my_ascii.nvim",
    "a dependency whose branch is unknown is a risk to confirm"
  )

  -- the real probe, with `vim.system` replaced: exit 0 = exists, 2 = missing, anything else (or a
  -- raise) = unknown; never an error, and the command is the ls-remote with --exit-code
  local real_system = vim.system
  local last_argv
  local function fake(code, stderr)
    vim.system = function(argv)
      last_argv = argv
      return {
        wait = function()
          return { code = code, stdout = "", stderr = stderr or "" }
        end,
      }
    end
  end
  branches.reset()
  fake(0)
  eq({ branches.exists("o", "a.nvim") }, { true }, "ls-remote exit 0: the branch exists")
  eq(
    last_argv,
    {
      "git",
      "ls-remote",
      "--exit-code",
      "--heads",
      "https://github.com/o/a.nvim",
      "refs/heads/ci-verified",
    },
    "asked through an argv list, with the full ref (a short pattern also finds release/ci-verified)"
  )
  fake(2)
  eq({ branches.exists("o", "b.nvim") }, { false }, "exit 2: it does not")
  fake(128, "fatal: unable to access")
  local e3, w3 = branches.exists("o", "c.nvim")
  eq(e3, nil, "any other exit: unknown")
  has(w3, "unable to access", "with the reason")
  vim.system = function()
    error("git is not installed")
  end
  local e4, w4 = branches.exists("o", "d.nvim")
  eq(e4, nil, "a raising vim.system is unknown, not an error")
  has(w4, "git is not installed", "with the reason")
  vim.system = real_system
  branches.reset()

  -- a question that ran into the timeout ends the asking: the editor waits for each of them, and a network that
  -- drops packets would cost the full timeout per dependency (nil: killed with its pipes held open by a child of it)
  for _, silent in ipairs({ { code = 124, stdout = "", stderr = "" }, false }) do
    local git_runs = 0
    vim.system = function()
      git_runs = git_runs + 1
      return {
        wait = function()
          return silent or nil
        end,
      }
    end
    local t1, why1 = branches.exists("o", "slow.nvim")
    eq(t1, nil, "a timeout is unknown")
    has(why1, "did not answer within", "and says so")
    local t2, why2 = branches.exists("o", "other.nvim")
    eq(t2, nil, "the next question is not asked")
    has(why2, "not asking again", "and says why")
    eq(git_runs, 1, "git ran once")
    branches.reset()
  end
  fake(0)
  eq({ branches.exists("o", "after.nvim") }, { true }, "reset: asked again")
  vim.system = real_system
  branches.reset()

  -- The timeout ends the asking for ONE run: `:Testing migrate` runs in an editor that stays open for hours, and a
  -- run without network (every dependency unknown, the first one a timeout) must not silence the runs after it,
  -- not even for the dependency that was asked about and gave no answer. An answer that says "there / not there"
  -- stays for the process.
  do
    local git_runs = 0
    local silent = true
    vim.system = function()
      git_runs = git_runs + 1
      return {
        wait = function()
          if silent then
            return nil
          end
          return { code = 2, stdout = "", stderr = "" }
        end,
      }
    end
    local first = migrate.run(repo, { fleet_root = fleet_dir, branch_exists = branches.exists })
    eq(first.error, nil, "the run without network plans")
    has(notes_of(first), "could not check whether", "its notes say that the check was not possible")
    local before = git_runs
    ok(before >= 1, "git was asked in the first run")
    silent = false
    local second = migrate.run(repo, { fleet_root = fleet_dir, branch_exists = branches.exists })
    ok(git_runs > before, "the next run asks again")
    lacks(notes_of(second), "not asking again", "and is not told that the asking has stopped")
    lacks(notes_of(second), "did not answer within", "nor that the last run got no answer")
    has(
      notes_of(second),
      "has no ci-verified branch: pinned to main",
      "the answer of the second run is the one that counts"
    )
    -- a definite answer stays for the process: the third run does not ask again
    local asked_once = git_runs
    migrate.run(repo, { fleet_root = fleet_dir, branch_exists = branches.exists })
    eq(git_runs, asked_once, "answers of 'there' and 'not there' are kept")
    vim.system = real_system
    branches.reset()
  end

  -- ---------------------------------------------------------------- CI edits

  has(ci_text, "    name: tests (${{ matrix.os }})", "the job name no longer says plenary")
  has(ci_text, "      - name: Run the specs", "nor the run step name")
  lacks(ci_text:lower(), "plenary", "nothing in the workflow mentions plenary")
  lacks(ci_text, "LIB_NVIM_PATH", "the superfluous LIB_NVIM_PATH is gone")
  has(ci_text, "COLOR_MY_ASCII_DIR:", "an env entry of another name stays")
  has(
    ci_text,
    "          path: testing.nvim\n          ref: ci-verified\n\n      # color_my_ascii.nvim has no",
    "inserted checkout steps are separated by a blank line"
  )
  has(ci_op.reason, "LIB_NVIM_PATH is removed", "the reason names the removal")

  -- ---------------------------------------------------------------- the gate replaces TESTS/minimal_init.lua

  local minit = assert(op_by_path(plan, "TESTS/minimal_init.lua"))
  eq(minit.action, "modify", "the existing file is replaced")
  for _, dep in ipairs({ "testing.nvim", "lib.nvim", "color_my_ascii.nvim" }) do
    has(minit.after, '"' .. dep .. '"', "DEPS lists " .. dep)
  end
  has(minit.after, "os.exit(1)", "a missing dependency is fatal")
  has(minit.after, "4. ", "all four places are named when it fails")
  has(minit.after, "stdpath('data')/lazy/%s", "the lazy place is searched")
  lacks(minit.after, "prepend_env", "the environment lookup of the old file is gone")
  lacks(minit.after, "LIB_NVIM_PATH", "with its variable")
  lacks(minit.after:lower(), "plenary", "and the old runner")
  lacks(minit.after, "Minimal init for running", "the old header comment is gone")
  has(minit.after, "vim.o.swapfile = false", "swapfile stays off")
  has(minit.after, 'vim.o.shadafile = "NONE"', "shada stays off")
  has(minit.after, "-- Carried over from TESTS/minimal_init.lua", "carried lines are marked")
  ok(loadstring(minit.after) ~= nil, "the new file compiles")
  -- the file is a gate: a missing dependency exits 1 and names the four places
  local gate_dir = tmp .. "/gate"
  write(gate_dir .. "/TESTS/minimal_init.lua", minit.after)
  local res = vim
    .system({
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      gate_dir .. "/TESTS/minimal_init.lua",
      "-c",
      "qa!",
    }, { text = true, timeout = 30000, env = { NVIM_APPNAME = "wave2-gate-test" } })
    :wait()
  eq(res.code, 1, "the gate exits 1 when a dependency is missing")
  has(res.stderr, "dependency 'testing.nvim' not found", "and names the dependency")

  -- applied twice, nothing is left to do (the gate is recognised)
  write(repo .. "/TESTS/minimal_init.lua", minit.after)
  local again = migrate.run(repo, {
    fleet_root = fleet_dir,
    branch_exists = stub({}),
  })
  eq(
    op_by_path(again, "TESTS/minimal_init.lua"),
    nil,
    "a file that is the gate already is not touched"
  )
  write(repo .. "/TESTS/minimal_init.lua", OLD_MINIT)

  -- the split itself: the environment lookup is dropped, the state is kept
  local blocks = legacy_init.split(OLD_MINIT)
  local kept = {}
  for _, b in ipairs(blocks) do
    if b.kind == "carry" then
      kept[#kept + 1] = table.concat(b.lines, "\n")
    end
  end
  local kept_text = table.concat(kept, "\n")
  has(kept_text, "vim.o.swapfile = false", "split keeps the state")
  lacks(kept_text, "prepend_env", "split drops the env lookup")

  -- ---------------------------------------------------------------- env override names

  local notes = notes_of(plan)
  has(
    notes,
    "color_my_ascii.nvim -> $COLOR_MY_ASCII_NVIM_DIR",
    "the override name comes from the repo name"
  )
  has(notes, "lib.nvim -> $LIB_NVIM_DIR", "for every dependency")
  has(
    notes,
    "COLOR_MY_ASCII_DIR in .github/workflows/ci.yml (now $COLOR_MY_ASCII_NVIM_DIR)",
    "and the old spelling that is still in use is pointed out"
  )

  vim.fn.delete(tmp, "rf")
end
