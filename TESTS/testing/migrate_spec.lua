-- TESTS/testing/migrate_spec.lua -- the migration tooling: analysis of fixture repositories (a plenary
-- repo, a repo with its own harness, a repo of self-running scripts), the plan as data, idempotence,
-- the refusal to touch a dirty repository, hostile names and the dependency mapping.

---@diagnostic disable: missing-fields, param-type-mismatch, need-check-nil, assign-type-mismatch

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local migrate = require("testing.migrate")
  local ci = require("testing.migrate.ci")
  local fleet = require("testing.migrate.fleet")
  local text = require("testing.migrate.text")
  local read = require("lib.nvim.fs.read")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
  end
  local function slurp(path)
    local t = read(path)
    ok(t ~= nil, "cannot read " .. path)
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({ "git", "-c", "user.email=t@t", "-c", "user.name=t", ... }, {
        cwd = root,
        text = true,
      })
      :wait()
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(res.stderr))
  end
  local function gitify(root)
    git(root, "init", "-q")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
  end
  local function files_of(root)
    local out = {}
    for _, f in
      ipairs(vim.fs.find(function()
        return true
      end, { path = root, type = "file", limit = 2000 }))
    do
      if not f:find("/.git/", 1, true) then
        out[#out + 1] = f:sub(#root + 2)
      end
    end
    table.sort(out)
    return out
  end
  local function op_by_path(plan, path)
    for _, op in ipairs(plan.ops) do
      if op.path == path then
        return op
      end
    end
  end
  local function paths_of(plan)
    local out = {}
    for _, op in ipairs(plan.ops) do
      out[#out + 1] = op.path
    end
    return out
  end

  -- ---------------------------------------------------------------- fixtures

  local fleet_dir = tmp .. "/fleet"
  write(fleet_dir .. "/lib.nvim/lua/lib/nvim/notify/init.lua", "return {}\n")
  write(fleet_dir .. "/ui.nvim/lua/ui/kit/init.lua", "return {}\n")
  write(fleet_dir .. "/diff.nvim/lua/diff/view/init.lua", "return {}\n")
  -- two repositories that both provide `shared.mod`: nobody can choose between them
  write(fleet_dir .. "/amb_a.nvim/lua/shared/mod.lua", "return {}\n")
  write(fleet_dir .. "/amb_b.nvim/lua/shared/mod.lua", "return {}\n")
  -- a telescope extension directory must not make `require("telescope.pickers")` a fleet module
  write(fleet_dir .. "/ext.nvim/lua/telescope/_extensions/ext.lua", "return {}\n")

  local PLENARY_MINIT = [=[
-- Minimal init for the plenary.nvim test suite:
--   nvim --headless -u TESTS/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua' }"
vim.opt.rtp:append(vim.fn.getcwd())

local function add_dep(env, name, marker)
  if pcall(require, marker) then return end
  vim.opt.rtp:append(vim.fn.getcwd() .. "/.deps/" .. name)
end

add_dep("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify")
add_dep("PLENARY_DIR", "plenary.nvim", "plenary")
vim.cmd("runtime plugin/plenary.vim")
local plenary = vim.env.PLENARY_PATH
vim.o.swapfile = false
]=]

  local PLENARY_SH = [=[
#!/usr/bin/env bash
# Runs the plenary/busted spec suite headlessly.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim -n --clean --headless -u TESTS/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua', sequential = true }"
]=]

  local PLENARY_CI = [=[
name: CI

on:
  push:

jobs:
  tests:
    name: tests (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    timeout-minutes: 15
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v5
      - uses: actions/checkout@v5
        with:
          repository: StefanBartl/lib.nvim
          path: .deps/lib.nvim
          ref: ci-verified
      # plenary is the busted-compatible harness
      - uses: actions/checkout@v5
        with:
          repository: nvim-lua/plenary.nvim
          path: .deps/plenary.nvim
      - name: Run
        env:
          PLENARY_PATH: .deps/plenary.nvim
        run: |
          set -e
          nvim -n --headless -u TESTS/minimal_init.lua \
            -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua', sequential = true }"
]=]

  ---A plenary repository. `opts.needs_plenary`: a spec requires plenary.async at its top level.
  local function mk_plenary(name, opts)
    opts = opts or {}
    local mod = name:gsub("%.nvim$", "")
    local root = fleet_dir .. "/" .. name
    write(
      root .. "/lua/" .. mod .. "/init.lua",
      [=[
local notify = require("lib.nvim.notify")
local ok_ui = pcall(require, "ui.kit")
local M = {}
function M.pick()
  return require("telescope.pickers")
end
return M
]=]
    )
    local spec = [=[
describe("foo", function()
  it("works", function()
    assert.is_true(true)
  end)
end)
-- require("hover.core") in a comment is nothing
local s = 'require("diff.view")'
]=]
    if opts.needs_plenary then
      spec = 'local async = require("plenary.async")\n' .. spec
    end
    write(root .. "/TESTS/foo_spec.lua", spec)
    write(root .. "/TESTS/minimal_init.lua", PLENARY_MINIT)
    write(root .. "/scripts/test.sh", PLENARY_SH)
    write(root .. "/.github/workflows/ci.yml", PLENARY_CI)
    return root
  end

  local HARNESS_CI = [=[
name: CI
jobs:
  tests:
    runs-on: ${{ matrix.os }}
    timeout-minutes: 3
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest]
    steps:
      - uses: actions/checkout@v5
      - uses: actions/checkout@v5
        with:
          repository: StefanBartl/lib.nvim
          path: .deps/lib.nvim
          ref: ci-verified
      - run: nvim -n -i NONE --headless -u NONE -c "set rtp+=." -l TESTS/run.lua
]=]

  local function mk_harness(name)
    local root = fleet_dir .. "/" .. name
    local mod = name:gsub("%.nvim$", "")
    write(root .. "/lua/" .. mod .. "/init.lua", 'return require("lib.nvim.notify")\n')
    write(
      root .. "/TESTS/harness.lua",
      [=[
local H = {}
function H.eq(a, b, msg)
  if a ~= b then error("FAIL " .. msg, 2) end
end
return H
]=]
    )
    write(root .. "/TESTS/run.lua", "print('\\nHN_TESTS_OK')\n")
    write(root .. "/TESTS/x_spec.lua", 'return function(H)\n  H.eq(1, 1, "x")\nend\n')
    write(root .. "/.github/workflows/ci.yml", HARNESS_CI)
    return root
  end

  local SCRIPT_CI = [=[
name: CI
jobs:
  tests:
    runs-on: ubuntu-latest
    timeout-minutes: 2
    steps:
      - uses: actions/checkout@v5
      - run: |
          set -e
          nvim -n --headless -u NONE -l TESTS/self_spec.lua
          nvim -n --headless -u NONE -l TESTS/smoke.lua
          nvim -n --headless -u NONE -l TESTS/refs/run.lua
          nvim -n --headless -u NONE -l TESTS/quiet_spec.lua
]=]

  local function mk_script(name)
    local root = fleet_dir .. "/" .. name
    local mod = name:gsub("%.nvim$", "")
    write(root .. "/lua/" .. mod .. "/init.lua", "return {}\n")
    write(
      root .. "/TESTS/self_spec.lua",
      'local failed = 0\nlocal function check(n, c) if not c then failed = failed + 1 print("[FAIL] " .. n) end end\ncheck("one", 1 == 1)\nif failed > 0 then os.exit(1) end\n'
    )
    write(root .. "/TESTS/smoke.lua", 'print("smoke")\n')
    -- named like a spec, but nothing in it says "script": only the old runner's `-l` does
    write(root .. "/TESTS/quiet_spec.lua", 'print("quiet")\n')
    write(root .. "/TESTS/refs/run.lua", 'print("refs")\n')
    write(root .. "/.github/workflows/ci.yml", SCRIPT_CI)
    return root
  end

  -- ---------------------------------------------------------------- text helpers

  local lines, shape = text.lines("a\r\nb\r\nc")
  eq(lines, { "a", "b", "c" }, "text.lines splits CRLF text")
  eq(text.join(lines, shape), "a\r\nb\r\nc", "and joins it again byte for byte (no final newline)")
  lines, shape = text.lines("x\ny\n")
  eq(text.join(lines, shape), "x\ny\n", "a final newline survives the round trip")
  eq(text.lines(""), {}, "empty text has no lines")
  eq(text.show("a\27[31mb\0c\127"), "a\\x1B[31mb\\x00c\\x7F", "control characters become visible")
  eq(text.show("tab\there"), "tab\there", "a tab is kept")
  eq(text.show(("x"):rep(500), 10), ("x"):rep(10) .. "...", "long text is cut")
  eq(text.show("\194\155[31m"), "\\u009B[31m", "a C1 control (UTF-8) is made visible")
  eq(text.is_safe_rel("TESTS/a_spec.lua"), true, "a relative path is safe")
  for _, bad in ipairs({ "../x", "a/../b", "/abs", "C:/x", "a\0b", "", "\\x" }) do
    eq(text.is_safe_rel(bad), false, "unsafe path refused: " .. vim.inspect(bad))
  end
  local diff = text.unified("a\nb\n", "a\nc\n", "f.txt")
  has(diff, "--- a/f.txt\n+++ b/f.txt\n", "unified diff headers")
  has(diff, "-b\n+c\n", "unified diff body")
  has(
    text.unified(nil, "x\n", "n.txt"),
    "--- /dev/null\n",
    "a created file diffs against /dev/null"
  )
  eq(text.unified("same\n", "same\n", "s"), "", "equal texts have no diff")
  eq(
    text.removed_lines("a\nb\nb\nc\n", "a\nb\nc\n"),
    { "b" },
    "removed_lines counts duplicates as a multiset"
  )

  -- ---------------------------------------------------------------- require scan

  local function mods(src)
    local out = {}
    for _, r in ipairs(fleet.requires_of(src)) do
      out[#out + 1] = r.module .. (r.soft and "?" or "") .. (r.top and "" or "~")
    end
    return out
  end
  eq(mods('local a = require("x.y")'), { "x.y" }, "a top-level require is a hard load-time one")
  eq(mods("local a = require 'x'"), { "x" }, "the call without parentheses")
  eq(mods('local ok = pcall(require, "x")'), { "x?" }, "pcall(require, ...) is optional")
  eq(
    mods('local ok, m = pcall(function()\n  return require("x")\nend)'),
    { "x?~" },
    "inside a pcall block"
  )
  eq(mods('function f()\n  return require("x")\nend'), { "x~" }, "inside a function it is lazy")
  eq(
    mods('-- require("x")\nlocal s = "require(\\"y\\")"'),
    {},
    "comments and strings are not requires"
  )
  eq(mods("local s = [[\nrequire('z')\n]]"), {}, "a long string is not a require either")
  eq(mods("obj.require('x')\nobj:require('y')"), {}, "a method called require is somebody else's")

  local idx = fleet.index(fleet_dir)
  eq(fleet.resolve("vim.lsp", idx, tmp).kind, "builtin", "vim.* needs no plugin")
  eq(
    fleet.resolve("lib.nvim.notify", idx, tmp),
    { kind = "fleet", repo = "lib.nvim" },
    "a fleet module"
  )
  eq(
    fleet.resolve("ui.kit", idx, tmp),
    { kind = "fleet", repo = "ui.nvim" },
    "another fleet module"
  )
  eq(
    fleet.resolve("telescope.pickers", idx, tmp),
    { kind = "external", repo = "telescope.nvim" },
    "a telescope extension directory does not make telescope a fleet module"
  )
  eq(fleet.resolve("telescope", idx, tmp).kind, "external", "also the bare name")
  eq(
    fleet.resolve("shared.mod", idx, tmp),
    { kind = "ambiguous", candidates = { "amb_a.nvim", "amb_b.nvim" } },
    "two providers: ambiguous, nothing is chosen"
  )
  eq(fleet.resolve("nothing.here", idx, tmp).kind, "unknown", "nobody provides it")
  eq(
    fleet.resolve("luassert", idx, tmp).kind,
    "builtin",
    "luassert is provided by testing.nvim's dialect"
  )

  -- ---------------------------------------------------------------- ci: classify

  local kinds = {
    ['nvim --headless -u TESTS/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ {}"'] = "legacy",
    ['LIB_NVIM_PATH=.deps/lib.nvim nvim -n --headless -c "luafile TESTS/run.lua" -c "qa!"'] = "legacy",
    ['exec > >(tee -a "$RUNNER_TEMP/x.log") 2>&1 nvim -l TESTS/run.lua'] = "legacy",
    ["busted TESTS/lua"] = "legacy",
    ["bash scripts/test.sh"] = "testsh",
    ["scripts/test.sh --file x"] = "testsh",
    ["./scripts/test.sh"] = "testsh",
    ["nvim --headless -c \"lua dofile('scripts/ci/unit_tests.lua')\""] = "manual",
    ["nvim --headless -l scripts/gen_map.lua"] = "other",
    ["luarocks install luacheck"] = "other",
    ["echo hello"] = "other",
  }
  for cmd, kind in pairs(kinds) do
    eq(ci.classify(cmd), kind, "classify " .. cmd)
  end
  eq(
    ci.classify("nvim -n -i NONE --headless -u NONE -l TESTS/run.lua"),
    "legacy",
    "classify -l TESTS/run.lua"
  )

  -- ---------------------------------------------------------------- analysis: plenary repository

  local pl = mk_plenary("pl.nvim")
  local report = migrate.analyze(pl, { fleet_root = fleet_dir })
  eq(report.error, nil, "the fixture can be analysed")
  eq(report.specs.total, 1, "one spec file")
  eq(report.specs.by_dialect, { busted = 1 }, "describe/it is the busted dialect")
  eq(report.harness.file, nil, "no harness of its own")
  eq(
    report.test_sh,
    { exists = true, migrated = false, plenary = true },
    "scripts/test.sh starts plenary"
  )
  eq(report.dot_testing, false, "no .testing.lua yet")
  eq(#report.minimal_init.plenary_lines, 5, "five lines of the minimal_init mention plenary")
  eq(
    vim.tbl_map(function(l)
      return l.kind
    end, report.minimal_init.plenary_lines),
    { "comment", "comment", "code", "code", "code" },
    "code and comment lines are told apart"
  )
  eq(report.runner.plenary_dirs, { "TESTS" }, "the old runner was pointed at TESTS/")
  eq(
    report.plenary,
    { beyond_runner = {}, needed = false, keep_ci = false },
    "plenary is only the runner"
  )
  eq(report.policy.isolated, "file", "busted specs ran one nvim per file under plenary")
  eq(report.policy.host, "c", "with the plenary-like host")
  eq(report.policy.assertions, "warn", "empty cases pass under plenary: warn")
  local wf = report.ci.workflows[1]
  eq(wf.rel, ".github/workflows/ci.yml", "the workflow is found")
  eq(wf.jobs[1].id, "tests", "with its job")
  eq(wf.jobs[1].timeout, "15", "and the timeout")
  eq(wf.jobs[1].matrix_os, true, "and the os matrix")
  eq(wf.jobs[1].plenary_checkout, true, "and the plenary checkout")

  -- dependency mapping
  local dep_names = vim.tbl_map(function(d)
    return d.name
  end, report.deps.list)
  eq(dep_names, { "lib.nvim" }, "only the hard top-level fleet require is a dependency")
  eq(report.deps.list[1].kind, "fleet", "it is a fleet repository")
  local optional = vim.tbl_map(function(d)
    return d.name
  end, report.deps.optional)
  eq(optional, { "telescope.nvim", "ui.nvim" }, "pcall and lazy requires are optional")
  eq(
    vim.tbl_filter(function(d)
      return d.name == "diff.nvim"
    end, report.deps.optional),
    {},
    "a require in a string or comment is no dependency"
  )

  -- ---------------------------------------------------------------- plan: plenary repository

  local plan = migrate.plan(report)
  eq(plan.empty, false, "a plenary repository has work to do")
  eq(
    paths_of(plan),
    { ".testing.lua", "scripts/test.sh", "TESTS/minimal_init.lua", ".github/workflows/ci.yml" },
    "the operations: config, runner script, CI, minimal_init"
  )
  local cfg_text = op_by_path(plan, ".testing.lua").after
  local chunk = assert(loadstring(cfg_text, "=.testing.lua"))
  local cfg = chunk()
  eq(cfg.plugin, "pl", "plugin from lua/<name>")
  eq(cfg.deps, { "lib.nvim" }, "dependencies")
  eq(cfg.isolated, "file", "isolation")
  eq(cfg.host, "c", "host")
  eq(cfg.assertions, nil, "no assertion policy is set: a run decides, the plan only hints")
  eq(cfg.timeouts, nil, "no case limit is set: a run decides, the plan only hints")
  local hint_text = table.concat(plan.notes, "\n")
  has(hint_text, "`assertions` is not set", "the assertion policy is a hint")
  has(hint_text, "`timeouts` is not set", "the case limit is a hint")
  eq(cfg.dialect, "auto", "busted specs are sniffed")
  local validated, problems = require("testing.config.project").validate(cfg)
  eq(problems, {}, "the generated .testing.lua passes the config validator")
  eq(validated.isolated, "file", "and means what it says")

  local sh = op_by_path(plan, "scripts/test.sh")
  eq(sh.action, "modify", "the plenary script is replaced")
  eq(sh.exec, true, "and stays executable")
  has(sh.after, "DEPS=('testing.nvim' 'lib.nvim')", "it resolves the runner and the dependency")
  lacks(sh.after, "Plenary", "no plenary left in it")
  has(
    sh.diff,
    "-exec nvim -n --clean --headless -u TESTS/minimal_init.lua",
    "the diff shows the old command"
  )
  ok(
    vim.tbl_contains(sh.removed, "set -euo pipefail") == false,
    "unchanged lines are not 'removed'"
  )
  ok(
    vim.tbl_contains(
      sh.removed,
      [[exec nvim -n --clean --headless -u TESTS/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'TESTS/minimal_init.lua', sequential = true }"]]
    ),
    "the removed lines are listed"
  )

  local minit = op_by_path(plan, "TESTS/minimal_init.lua")
  eq(minit.action, "modify", "the existing minimal_init is edited, not replaced")
  eq(
    minit.removed,
    { 'add_dep("PLENARY_DIR", "plenary.nvim", "plenary")', 'vim.cmd("runtime plugin/plenary.vim")' },
    "only self-contained plenary calls are removed"
  )
  has(minit.after, "local function add_dep", "everything else is kept")
  has(minit.after, "local plenary = vim.env.PLENARY_PATH", "a statement that is not a call stays")
  has(
    minit.after,
    "-- Minimal init for the plenary.nvim test suite",
    "comments stay (reworded by hand)"
  )
  ok(loadstring(minit.after) ~= nil, "the edited minimal_init still compiles")
  ok(
    vim.iter(plan.notes):any(function(n)
      return n:find("keeps", 1, true) and n:find("line 13", 1, true)
    end),
    "the line that stays is reported with its line number"
  )

  local wfop = op_by_path(plan, ".github/workflows/ci.yml")
  local new_ci = wfop.after
  has(
    new_ci,
    'bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"',
    "CI calls the new runner"
  )
  lacks(new_ci, "PlenaryBustedDirectory", "the plenary command is gone")
  lacks(new_ci, "repository: nvim-lua/plenary.nvim", "and the plenary checkout")
  lacks(new_ci, "PLENARY_PATH", "and its environment")
  lacks(new_ci, "\n        env:\n", "the emptied env block goes with it")
  has(new_ci, "      - name: Run\n        shell: bash\n", "a Windows job gets bash for the step")
  has(new_ci, 'repository: "StefanBartl/testing.nvim"', "testing.nvim is checked out")
  has(
    new_ci,
    "path: .deps/testing.nvim\n          ref: ci-verified",
    "from ci-verified into .deps/"
  )
  has(new_ci, "name: testing-ir-${{ matrix.os }}", "the IR is uploaded as an artifact")
  has(new_ci, "timeout-minutes: 15", "timeouts are untouched")
  has(new_ci, "os: [ubuntu-latest, windows-latest]", "the matrix is untouched")
  has(new_ci, "name: tests (${{ matrix.os }})", "job names are untouched")
  has(new_ci, "          set -e\n", "other lines of the run block stay")
  lacks(wfop.diff, "-    timeout-minutes", "the diff does not touch the timeout")
  has(
    wfop.diff,
    "-          repository: nvim-lua/plenary.nvim",
    "the diff shows the removed plenary checkout"
  )
  has(wfop.diff, '+          repository: "StefanBartl/testing.nvim"', "and the added one")
  has(wfop.reason, "plenary.nvim checkout step is removed", "the reason names the edits")
  -- the comment above the removed checkout is removed with its step
  lacks(new_ci, "busted-compatible harness", "a step's own comment goes with it")

  -- render and json
  local md = migrate.render(plan)
  has(md, "# testing migrate: pl.nvim", "markdown heading")
  has(md, "```diff", "diffs are fenced in markdown")
  has(md, "Dry run: nothing has been written.", "the plan says it is a dry run")
  local term = migrate.render(plan, { format = "text" })
  lacks(term, "```", "terminal text has no fences")
  has(term, "TESTING MIGRATE: PL.NVIM", "terminal heading")
  local json = assert(migrate.to_json(plan))
  local decoded = vim.json.decode(json)
  eq(decoded.name, "pl.nvim", "the JSON form decodes")
  eq(#decoded.ops, 4, "with all operations")
  eq(decoded.ops[1].before, nil, "the text that was read is not in the JSON")
  ok(decoded.ops[1].after ~= nil, "a created file keeps its text")
  eq(decoded.ops[2].after, nil, "a modified file is described by its diff")
  ok(decoded.ops[2].diff:find("@@", 1, true) ~= nil, "which is in the JSON")
  eq(assert(migrate.to_json(plan)), json, "the same plan is the same bytes")

  -- ---------------------------------------------------------------- idempotence, apply, refusals

  -- a dry run writes nothing
  local before_files = files_of(pl)
  local dry = migrate.apply(plan)
  ok(
    #dry.errors == 1 and dry.errors[1]:find("dry run", 1, true),
    "apply without the flag is a dry run"
  )
  eq(files_of(pl), before_files, "and writes nothing")

  -- no git repository: cannot tell whether it is clean
  local nogit = migrate.apply(plan, { apply = true })
  ok(#nogit.errors > 0 and nogit.errors[1]:find("uncommitted changes", 1, true), "no git: refused")
  eq(files_of(pl), before_files, "nothing written without a clean-tree check")

  gitify(pl)
  -- the plan was made before the commit; the files are the same bytes, so it still applies
  -- a dirty tree is refused, tracked or untracked
  write(pl .. "/untracked.txt", "x")
  local dirty_res = migrate.apply(plan, { apply = true })
  ok(
    #dirty_res.errors == 1 and dirty_res.errors[1]:find("uncommitted changes", 1, true),
    "untracked file: refused"
  )
  has(dirty_res.errors[1], "untracked.txt", "the refusal names the file")
  eq(#dirty_res.applied, 0, "nothing applied")
  vim.fn.delete(pl .. "/untracked.txt")
  write(pl .. "/TESTS/foo_spec.lua", slurp(pl .. "/TESTS/foo_spec.lua") .. "-- edit\n")
  local tracked = migrate.apply(plan, { apply = true })
  ok(
    #tracked.errors == 1 and tracked.errors[1]:find("uncommitted changes", 1, true),
    "tracked edit: refused"
  )
  git(pl, "checkout", "--", "TESTS/foo_spec.lua")

  -- a plan that is stale (a file changed after it was made) is refused as a whole
  local stale_text = slurp(pl .. "/scripts/test.sh")
  write(pl .. "/scripts/test.sh", stale_text .. "# later\n")
  git(pl, "add", "-A")
  git(pl, "commit", "-q", "-m", "later")
  local stale = migrate.apply(plan, { apply = true })
  ok(
    #stale.errors == 1 and stale.errors[1]:find("changed since the plan", 1, true),
    "stale plan: refused"
  )
  eq(slurp(pl .. "/scripts/test.sh"), stale_text .. "# later\n", "nothing was written")
  ok(vim.uv.fs_stat(pl .. "/.testing.lua") == nil, "not even the files that could have been")

  -- a fresh plan applies; the second plan is empty
  local report2 = migrate.analyze(pl, { fleet_root = fleet_dir })
  local plan2 = migrate.plan(report2)
  local applied = migrate.apply(plan2, { apply = true })
  eq(applied.errors, {}, "a plan of the committed tree applies")
  eq(applied.applied, paths_of(plan2), "every operation was written, in plan order")
  local plan3, report3 = migrate.run(pl, { fleet_root = fleet_dir })
  eq(plan3.empty, true, "the second plan is empty (idempotent)")
  eq(plan3.ops, {}, "no operation at all")
  eq(report3.test_sh.migrated, true, "scripts/test.sh is recognised as migrated")
  eq(report3.dot_testing, true, ".testing.lua is recognised")
  local code_empty, out_empty = migrate.main({ pl, "--fleet-root", fleet_dir })
  eq(code_empty, 0, "main on a migrated repository exits 0")
  has(out_empty, "Nothing to do", "and says so")
  local again = migrate.apply(plan3, { apply = true })
  eq({ #again.applied, #again.errors }, { 0, 0 }, "applying an empty plan is a quiet no-op")
  -- what was written
  ok(
    bit.band(vim.uv.fs_stat(pl .. "/scripts/test.sh").mode, tonumber("100", 8)) ~= 0
      or vim.fn.has("win32") == 1,
    "test.sh is executable"
  )
  has(
    slurp(pl .. "/.github/workflows/ci.yml"),
    "scripts/test.sh --json",
    "the workflow on disk is the edited one"
  )
  eq(slurp(pl .. "/TESTS/foo_spec.lua"):sub(1, 9), "describe(", "the specs are untouched")
  local ran_tests =
    vim.system({ "git", "status", "--porcelain" }, { cwd = pl, text = true }):wait().stdout
  has(ran_tests, "scripts/test.sh", "git sees the migration as ordinary modifications")
  lacks(ran_tests, "foo_spec", "and no spec among them")

  -- a symlinked target is not followed (symlinks need a privilege on Windows: other platforms only)
  if vim.fn.has("win32") == 0 then
    local sl = mk_plenary("sl.nvim")
    vim.uv.fs_unlink(sl .. "/scripts/test.sh")
    vim.uv.fs_symlink(tmp .. "/outside.sh", sl .. "/scripts/test.sh")
    gitify(sl)
    local slplan = migrate.run(sl, { fleet_root = fleet_dir })
    local op = op_by_path(slplan, "scripts/test.sh")
    if op then
      local slres = migrate.apply(slplan, { apply = true })
      ok(#slres.errors > 0, "a symlink in the way is refused")
      ok(vim.uv.fs_stat(tmp .. "/outside.sh") == nil, "nothing was written through it")
    end
  end

  -- a plan with a path that leaves the repository is refused
  local evil = {
    root = pl,
    empty = false,
    ops = { { path = "../evil.txt", action = "create", after = "x", diff = "", removed = {} } },
  }
  local evil_res = migrate.apply(evil, {
    apply = true,
    is_dirty = function()
      return false
    end,
  })
  ok(
    #evil_res.errors == 1 and evil_res.errors[1]:find("unsafe path", 1, true),
    "a traversal path is refused"
  )
  eq(vim.uv.fs_stat(tmp .. "/evil.txt"), nil, "and nothing is written outside")
  local abs_res = migrate.apply({
    root = pl,
    empty = false,
    ops = {
      { path = tmp .. "/evil.txt", action = "create", after = "x", diff = "", removed = {} },
    },
  }, {
    apply = true,
    is_dirty = function()
      return false
    end,
  })
  ok(#abs_res.errors == 1, "an absolute path is refused")
  eq(
    migrate.apply({ root = pl, error = "boom", ops = {} }, { apply = true }).errors[1],
    "the plan has an error: boom",
    "a plan with an error"
  )
  ok(
    migrate
      .apply({ root = pl, skipped = "not ours", ops = {} }, { apply = true }).errors[1]
      :find("not a migration target", 1, true),
    "a skipped plan"
  )
  ok(#migrate.apply("nope", { apply = true }).errors == 1, "not a plan at all")

  -- ---------------------------------------------------------------- plenary stays when something needs it

  local keep = mk_plenary("keep.nvim", { needs_plenary = true })
  local keep_plan, keep_report = migrate.run(keep, { fleet_root = fleet_dir })
  eq(keep_report.plenary.needed, true, "a hard require of plenary.async is a need")
  eq(keep_report.plenary.keep_ci, true, "so the CI keeps its checkout")
  ok(
    vim.iter(keep_report.deps.list):any(function(d)
      return d.name == "plenary.nvim"
        and d.kind == "external"
        and d.note == "external, not in fleet"
    end),
    "plenary.nvim is a dependency recorded as external, not in fleet"
  )
  local keep_ci = op_by_path(keep_plan, ".github/workflows/ci.yml").after
  has(keep_ci, "repository: nvim-lua/plenary.nvim", "the plenary checkout stays")
  has(keep_ci, "PLENARY_PATH", "and its environment")
  eq(op_by_path(keep_plan, "TESTS/minimal_init.lua"), nil, "minimal_init keeps its plenary lines")
  local keep_cfg = assert(loadstring(op_by_path(keep_plan, ".testing.lua").after))()
  ok(vim.tbl_contains(keep_cfg.deps, "plenary.nvim"), "plenary.nvim is in deps")

  -- ---------------------------------------------------------------- repository with its own harness

  local hn = mk_harness("hn.nvim")
  local hn_plan, hn_report = migrate.run(hn, { fleet_root = fleet_dir })
  eq(hn_report.harness.file, "TESTS/harness.lua", "the project's own harness is found")
  eq(hn_report.harness.run_lua, true, "and its TESTS/run.lua")
  eq(
    hn_report.harness.sentinel,
    "HN_TESTS_OK",
    "the sentinel is read in its single-quoted spelling"
  )
  eq(hn_report.harness.fail_convention, true, "the harness raises FAIL errors")
  eq(hn_report.harness.collects_failures, false, "so it does not collect failures itself")
  local hn_cfg = assert(loadstring(op_by_path(hn_plan, ".testing.lua").after))()
  eq(hn_cfg.dialect, "h", "return function(H) specs run on the project's harness")
  eq(hn_cfg.isolated, "none", "in one process")
  eq(hn_cfg.host, nil, "no host key without isolation")
  local hn_sh = op_by_path(hn_plan, "scripts/test.sh")
  eq(hn_sh.action, "create", "no script existed: created")
  has(
    hn_sh.after,
    "run . --sentinel 'HN_TESTS_OK' \"$@\"",
    "the sentinel of the old runner is kept"
  )
  local hn_ci = op_by_path(hn_plan, ".github/workflows/ci.yml").after
  has(
    hn_ci,
    '      - shell: bash\n        run: bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"\n',
    "an inline `- run:` keeps its place and gains the shell"
  )
  has(hn_ci, "timeout-minutes: 3", "the timeout is untouched")
  eq(
    op_by_path(hn_plan, "TESTS/minimal_init.lua").action,
    "create",
    "a missing minimal_init is created"
  )
  ok(
    vim.iter(hn_plan.notes):any(function(n)
      return n:find("TESTS/run.lua (the old runner) stays", 1, true)
    end),
    "the old runner is kept until the verdicts match"
  )
  -- a harness that collects failures itself is a stated risk
  write(
    hn .. "/TESTS/harness.lua",
    "local H = { failures = {} }\nfunction H.check(n, f) if not pcall(f) then H.failures[#H.failures + 1] = n end end\nreturn H\n"
  )
  local hc_report = migrate.analyze(hn, { fleet_root = fleet_dir })
  eq(hc_report.harness.collects_failures, true, "collecting harness detected")
  ok(
    vim.iter(hc_report.risks):any(function(r)
      return r:find("collects failures itself", 1, true)
    end),
    "and reported as a risk"
  )

  -- ---------------------------------------------------------------- self-running scripts

  local sc = mk_script("sc.nvim")
  local sc_plan, sc_report = migrate.run(sc, { fleet_root = fleet_dir })
  eq(
    sc_report.runner.scripts_no_suffix,
    { "TESTS/smoke.lua", "TESTS/refs/run.lua" },
    "scripts without the _spec suffix, a run.lua below TESTS/ among them (only TESTS/run.lua is the old runner)"
  )
  eq(sc_report.runner.unmappable, {}, "nothing is left that no pattern can name")
  local sc_cfg = assert(loadstring(op_by_path(sc_plan, ".testing.lua").after))()
  eq(
    sc_cfg.dialect,
    { ["*"] = "script", ["TESTS/self_spec.lua"] = "auto" },
    "three of the four are scripts only the old runner's -l says so about; the one the sniffer knows stays on auto"
  )
  eq(sc_cfg.host, "l", "started with nvim -l like the old runner")
  eq(
    sc_cfg.spec_pattern,
    { "_spec%.lua$", "^TESTS/smoke%.lua$", "^TESTS/refs/run%.lua$" },
    "the scripts are named by anchored patterns (the whole relative path)"
  )
  local sc_valid, sc_problems = require("testing.config.project").validate(sc_cfg)
  eq(sc_problems, {}, "the script configuration validates")
  eq(sc_valid.dialect["*"], "script", "and means script")
  local sc_ci = op_by_path(sc_plan, ".github/workflows/ci.yml").after
  has(sc_ci, "          set -e\n", "the set -e line stays")
  lacks(
    sc_ci,
    "-l TESTS/refs/run.lua",
    "the call of TESTS/refs/run.lua is replaced like the others"
  )
  lacks(sc_ci, "-l TESTS/self_spec.lua", "the others are replaced")
  lacks(sc_ci, "-l TESTS/smoke.lua", "all of them")
  eq(select(2, sc_ci:gsub("bash scripts/test.sh", "")), 1, "by ONE call")
  ok(not vim.iter(sc_plan.notes):any(function(n)
    return n:find("TESTS/refs/run.lua", 1, true) and n:find("by hand", 1, true)
  end), "no call is left as manual work")
  ok(not sc_ci:find("shell: bash", 1, true), "a Linux-only job does not get a shell line")

  -- ---------------------------------------------------------------- two runners in one repository (mdview.nvim)

  local two = fleet_dir .. "/two.nvim"
  write(two .. "/lua/two/init.lua", "return {}\n")
  write(
    two .. "/TESTS/lua/a_spec.lua",
    'describe("a", function() it("b", function() assert.is_true(true) end) end)\n'
  )
  write(
    two .. "/TESTS/nvim/b_spec.lua",
    'describe("c", function() it("d", function() assert.is_true(true) end) end)\n'
  )
  write(two .. "/TESTS/nvim/harness.lua", "-- its own describe/it runner\n")
  write(
    two .. "/.github/workflows/ci.yml",
    [=[
jobs:
  lua:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: busted TESTS/lua
  nvim:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: nvim -n --headless -u NONE -c "luafile TESTS/nvim/harness.lua" -c "qa!"
]=]
  )
  local two_plan, two_report = migrate.run(two, { fleet_root = fleet_dir })
  eq(
    two_report.runner.unmappable,
    {},
    "a setup script with specs beside it is their runner, not a test"
  )
  eq(two_report.runner.runner_dirs, { "TESTS/nvim" }, "its directory is a spec root")
  local two_cfg = assert(loadstring(op_by_path(two_plan, ".testing.lua").after))()
  eq(
    two_cfg.roots,
    { "TESTS/lua", "TESTS/nvim" },
    "both directories stay roots: no spec silently stops running"
  )
  local two_ci = op_by_path(two_plan, ".github/workflows/ci.yml").after
  lacks(two_ci, "busted TESTS/lua", "the busted call is replaced")
  lacks(two_ci, "harness.lua", "and so is the harness call")
  eq(select(2, two_ci:gsub("bash scripts/test.sh", "")), 2, "one call in each job")

  -- ---------------------------------------------------------------- ambiguity and unknown modules

  write(
    fleet_dir .. "/am.nvim/lua/am/init.lua",
    'local m = require("shared.mod")\nlocal n = require("zzz.unknown")\nreturn m\n'
  )
  write(
    fleet_dir .. "/am.nvim/TESTS/a_spec.lua",
    'describe("a", function() it("b", function() assert.is_true(true) end) end)\n'
  )
  local am_report = migrate.analyze(fleet_dir .. "/am.nvim", { fleet_root = fleet_dir })
  ok(
    vim.iter(am_report.risks):any(function(r)
      return r:find("provided by several fleet repositories", 1, true)
        and r:find("amb_a.nvim, amb_b.nvim", 1, true)
    end),
    "an ambiguous module is a risk that names the candidates"
  )
  eq(am_report.deps.unresolved, { zzz = 1 }, "an unknown module is counted, not guessed")
  eq(
    vim.tbl_map(function(d)
      return d.name
    end, am_report.deps.list),
    {},
    "and neither becomes a dependency"
  )

  -- ---------------------------------------------------------------- hostile names

  local ho = mk_harness("ho.nvim")
  write(ho .. "/TESTS/y_spec.lua", 'return function(H)\n  H.eq(2, 2, "y")\nend\n')
  local hostile = "a'b; $(touch pwned) `id` & x %s"
  write(
    ho .. "/TESTS/" .. hostile .. "_spec.lua",
    "describe('x', function() it('y', function() assert.is_true(true) end) end)\n"
  )
  local ho_report = migrate.analyze(ho, { fleet_root = fleet_dir })
  local hostile_rel = "TESTS/" .. hostile .. "_spec.lua"
  ok(
    vim.iter(ho_report.specs.files):any(function(f)
      return f.rel == hostile_rel and f.dialect == "busted"
    end),
    "a hostile file name is analysed like any other"
  )
  local ho_plan = migrate.plan(ho_report)
  local ho_cfg = assert(loadstring(op_by_path(ho_plan, ".testing.lua").after))()
  eq(type(ho_cfg.dialect), "table", "one busted file among harness files: a dialect table")
  eq(
    ho_cfg.dialect[hostile_rel],
    "auto",
    "the hostile name survives as a quoted key, byte for byte (its dialect is left to the sniffer)"
  )
  eq(ho_cfg.dialect["*"], "h", "the rest runs on the harness")
  local ho_valid, ho_problems = require("testing.config.project").validate(ho_cfg)
  eq(ho_problems, {}, "the config with the hostile key validates")
  ok(ho_valid ~= nil, "validate returns a config")
  lacks(
    op_by_path(ho_plan, "scripts/test.sh").after,
    "touch pwned",
    "the name never reaches the shell script"
  )
  lacks(op_by_path(ho_plan, ".github/workflows/ci.yml").after, "touch pwned", "nor the workflow")

  -- a name that cannot be written into the config is refused with a risk, not written unsafely
  local manual = vim.deepcopy(ho_report)
  -- (three files on the harness against two that stay on `auto`, so "*" is "h")
  manual.specs.files[#manual.specs.files + 1] = { rel = "TESTS/z_spec.lua", dialect = "a" }
  manual.specs.files[#manual.specs.files + 1] = { rel = "../escape_spec.lua", dialect = "busted" }
  local mp = migrate.plan(manual)
  local mp_cfg = assert(loadstring(op_by_path(mp, ".testing.lua").after))()
  eq(mp_cfg.dialect["../escape_spec.lua"], nil, "an unsafe path is not named in the config")
  ok(
    vim.iter(mp.risks):any(function(r)
      return r:find("cannot be named in .testing.lua", 1, true)
    end),
    "it is a risk"
  )

  -- display: nothing from the repository reaches the terminal raw
  local esc_plan = {
    root = "/x\27[2J",
    name = "n\27]0;title\7",
    ops = {
      {
        path = "a\27[31m.lua",
        action = "modify",
        kind = "ci",
        after = "",
        diff = "--- a/x\n+++ b/x\n@@\n-\27[31mred\n+ok\n",
        removed = { "\27[1mbold" },
        reason = "r\27[0m",
      },
    },
    notes = { "note \27[7m" },
    risks = { "risk \194\155" },
    empty = false,
  }
  for _, fmt in ipairs({ "markdown", "text" }) do
    local out = migrate.render(esc_plan, { format = fmt })
    lacks(out, "\27", fmt .. ": no escape character in the output")
    lacks(out, "\194\155", fmt .. ": no C1 control in the output")
    has(out, "\\x1B[31m", fmt .. ": the escape is made visible")
  end

  -- ---------------------------------------------------------------- CRLF workflow

  local crlf = mk_plenary("crlf.nvim")
  write(crlf .. "/.github/workflows/ci.yml", (PLENARY_CI:gsub("\n", "\r\n")))
  local crlf_plan = migrate.run(crlf, { fleet_root = fleet_dir })
  local crlf_ci = op_by_path(crlf_plan, ".github/workflows/ci.yml").after
  ok(not crlf_ci:find("[^\r]\n"), "a CRLF workflow stays CRLF: no bare LF anywhere")
  has(
    crlf_ci,
    'bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"\r\n',
    "with the new line in CRLF"
  )

  -- ---------------------------------------------------------------- not a target

  local third = mk_plenary("third.nvim")
  write(
    third .. "/.git/config",
    '[remote "origin"]\n\turl = https://github.com/nvim-lua/plenary.nvim\n'
  )
  local third_plan = migrate.run(third, { fleet_root = fleet_dir })
  ok(third_plan.skipped ~= nil, "a clone of somebody else's repository is skipped")
  eq(third_plan.ops, {}, "with no operation")
  local third_md = migrate.render(third_plan)
  has(third_md, "Skipped:", "and the report says why")
  local missing = migrate.run(tmp .. "/does-not-exist", { fleet_root = fleet_dir })
  eq(missing.error, "not a directory", "a missing directory is an error, not a crash")
  has(migrate.render(missing), "Cannot analyse", "which is rendered")

  -- ---------------------------------------------------------------- main (what the CLI and the command call)

  local c1, o1 = migrate.main({ "--bogus" })
  eq(c1, 2, "an unknown option is a usage error")
  has(o1, "unknown option", "with the message")
  has(o1, "usage: testing migrate", "and the usage")
  eq((migrate.main({ "a", "b" })), 2, "two paths are a usage error")
  eq((migrate.main({ "apply", "--check" })), 2, "apply and --check exclude each other")
  eq((migrate.main({ tmp .. "/nowhere" })), 3, "an unreadable root exits 3")
  local fresh = mk_plenary("fresh.nvim")
  local c2, o2 = migrate.main({ fresh, "--fleet-root=" .. fleet_dir })
  eq(c2, 0, "a dry run exits 0")
  has(o2, "operation(s) planned", "and shows the plan")
  eq(
    (migrate.main({ "dry-run", fresh, "--check", "--fleet-root", fleet_dir })),
    1,
    "--check exits 1 while there is work"
  )
  local c3, o3 = migrate.main({ fresh, "--json", "--fleet-root", fleet_dir })
  eq(c3, 0, "--json exits 0")
  eq(vim.json.decode(o3).name, "fresh.nvim", "and prints the JSON plan")
  local c4, o4 = migrate.main({ "apply", fresh, "--fleet-root", fleet_dir })
  eq(c4, 2, "apply without git is refused (exit 2)")
  has(o4, "refused:", "with the reason")
  gitify(fresh)
  local c5, o5 = migrate.main({ "apply", fresh, "--fleet-root", fleet_dir })
  eq(c5, 0, "apply in a clean repository succeeds")
  has(o5, "written: .testing.lua", "and lists what it wrote")
  eq(
    (migrate.main({ fresh, "--check", "--fleet-root", fleet_dir })),
    0,
    "--check exits 0 once migrated"
  )

  -- ---------------------------------------------------------------- ci.edit on its own

  local scaffold = require("testing.scaffold")
  local function ctx_of(extra)
    return vim.tbl_extend("force", {
      drop_plenary = true,
      fleet_deps = { "lib.nvim" },
      is_self = false,
      dep_step = function(name, prefix)
        return scaffold.dep_step(name, "StefanBartl", prefix)
      end,
      artifact_step = function(suffix)
        local t = assert(scaffold.render_template("ci_artifact_step.yml.tpl", { SUFFIX = suffix }))
        return (t:gsub("\n+$", ""))
      end,
    }, extra or {})
  end

  -- one folded step per script (replacer.nvim): the first becomes the call, the rest go
  local FOLDED = [=[
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/checkout@v5
        with:
          repository: StefanBartl/lib.nvim
          path: lib.nvim
          ref: ci-verified
      - name: one
        run: >-
          exec > >(tee -a "$RUNNER_TEMP/test-output.log") 2>&1
          nvim -n -i NONE --headless -u NONE
          -c "luafile TESTS/one.lua" -c "qa"

      - name: two
        run: >-
          exec > >(tee -a "$RUNNER_TEMP/test-output.log") 2>&1
          nvim -n -i NONE --headless -u NONE
          -c "luafile TESTS/two.lua" -c "qa"
      - name: keep
        run: echo done
]=]
  local folded = ci.edit(FOLDED, ctx_of())
  ok(folded.text ~= nil, "a folded workflow is edited")
  has(
    folded.text,
    '          exec > >(tee -a "$RUNNER_TEMP/test-output.log") 2>&1 bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json"\n',
    "a folded call keeps its tee prefix (the log the job uploads)"
  )
  lacks(folded.text, "TESTS/one.lua", "the first script is covered")
  lacks(folded.text, "TESTS/two.lua", "and the second")
  lacks(folded.text, "- name: two", "the step that only started the old runner is removed")
  has(folded.text, "- name: keep\n        run: echo done\n", "an unrelated step stays")
  has(
    folded.text,
    "path: testing.nvim\n",
    "a new checkout follows the layout of the existing one (a sibling)"
  )
  lacks(folded.text, "path: .deps/testing.nvim", "not .deps/")
  eq(folded.added_deps, {}, "lib.nvim is already checked out: not added again")

  -- the same text again: nothing to do
  local again_ci = ci.edit(folded.text, ctx_of())
  eq(again_ci.text, nil, "an edited workflow is not edited twice")
  eq(again_ci.changes, {}, "no change is even planned")

  -- scripts/test.sh already called: only --json is added, once
  local TESTSH = [=[
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - run: |
          scripts/test.sh --file x
]=]
  local tsh = ci.edit(TESTSH, ctx_of({ is_self = true, fleet_deps = {} }))
  has(
    tsh.text,
    'scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json" --file x',
    "--json goes right behind the script"
  )
  lacks(tsh.text, "repository:", "testing.nvim itself needs no checkout of itself")
  eq(
    ci.edit(tsh.text, ctx_of({ is_self = true, fleet_deps = {} })).text,
    nil,
    "and the result is stable"
  )

  -- an environment with other variables keeps them
  local ENV = [=[
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: run
        env:
          KEEP: "1"
          PLENARY_PATH: x
        run: nvim -l TESTS/run.lua
]=]
  local env = ci.edit(ENV, ctx_of())
  has(
    env.text,
    '        env:\n          KEEP: "1"\n        run: bash scripts/test.sh',
    "only the PLENARY line goes"
  )
  lacks(env.text, "PLENARY_PATH", "the plenary variable is gone")

  -- a script that wraps the old runner is reported, not edited
  local WRAPPED = [=[
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: scripts/ci.sh tests
]=]
  local wrapped = ci.edit(
    WRAPPED,
    ctx_of({
      read_script = function(rel)
        return rel == "scripts/ci.sh" and "#!/bin/sh\nnvim -n --headless -l TESTS/run.lua\n" or nil
      end,
    })
  )
  eq(wrapped.text, nil, "a wrapper is not edited")
  eq(wrapped.wrapped, true, "but recognised")
  ok(
    wrapped.notes[1] ~= nil and wrapped.notes[1]:find("scripts/ci.sh", 1, true) ~= nil,
    "and named as manual work"
  )

  -- a workflow without jobs
  local nojobs = ci.edit("name: x\non: push\n", ctx_of())
  eq(nojobs.text, nil, "no jobs: nothing is edited")
  has(nojobs.notes[1], "could not be read", "and the reason is given")
  eq(
    ci.checkout_prefix(ci.parse(FOLDED), ci.parse(FOLDED).jobs[1]),
    "",
    "the layout of existing checkouts is read"
  )
  eq(
    ci.checkout_prefix(ci.parse(PLENARY_CI), ci.parse(PLENARY_CI).jobs[1]),
    ".deps/",
    ".deps/ in the common case"
  )
  ok(ci.wraps_old_runner("nvim -n -l TESTS/run.lua\n"), "wraps_old_runner: a call")
  ok(not ci.wraps_old_runner("# nvim -n -l TESTS/run.lua\n"), "a comment is not a call")

  -- ---------------------------------------------------------------- what the specs need from outside
  -- (V2 of the fleet measurement: REPOS_DIR / MAGICK_* never reached the child editors, ui.nvim was proposed
  -- as a dependency of a repository whose specs run WITHOUT it, one lsp case needs 21 s)
  local analyze = require("testing.migrate.analyze")
  local allow, secrets = analyze.env_needs(table.concat({
    'local root = vim.env.REPOS_DIR or ""',
    'local home = os.getenv("MY_TOOL_HOME")',
    'local key = vim.fn.getenv("MY_API_KEY")',
    "local tok = vim.env.GITHUB_TOKEN",
    'vim.env.SET_BY_SPEC = "x"; local again = vim.env.SET_BY_SPEC',
    "local p = vim.env.PATH; local n = vim.env.NVIM_LISTEN_ADDRESS; local c = vim.env.LC_ALL",
    'vim.system({ "magick", "-version" })',
  }, "\n"))
  eq(
    allow,
    { "MAGICK_*", "MY_TOOL_HOME", "REPOS_DIR" },
    "env_needs: names the specs read, ImageMagick too"
  )
  eq(
    secrets,
    { "GITHUB_TOKEN", "MY_API_KEY" },
    "credential-like names are reported, never proposed"
  )
  eq(
    (
      analyze.env_needs(
        "local a, b, c = vim.env.TEMP, vim.env.LIB_NVIM_DIR, vim.env.XDG_DATA_HOME\n",
        { LIB_NVIM_DIR = true }
      )
    ),
    {},
    "what the driver sets itself (temp, XDG, the dependency directories) is not proposed"
  )
  eq(
    (analyze.env_needs("local x = 1\n")),
    {},
    "nothing to propose when the specs read no environment"
  )
  ok(
    analyze.asserts_absence(
      'it("applies directly when ui.nvim is absent", function() end)',
      "ui.nvim"
    ),
    "asserts_absence: a title that says the plugin is absent"
  )
  ok(
    not analyze.asserts_absence('local ui = require("ui.kit") -- ui.nvim is needed', "ui.nvim"),
    "and not a plain mention"
  )
  ok(
    not analyze.asserts_absence("-- diff.nvim is absent\n", "ui.nvim"),
    "nor an absence of another plugin"
  )

  -- a name that only a COMMENT of the CI mentions is no checkout and so no dependency (my.nvim: "# Modelled
  -- on ui.nvim's, deliberately"), while a real checkout step of another plugin is
  local cm = tmp .. "/cm.nvim"
  write(
    cm .. "/lua/cm/init.lua",
    'local a = pcall(require, "ui.kit")\nlocal b = pcall(require, "diff.view")\nreturn { a, b }\n'
  )
  write(
    cm .. "/TESTS/cm_spec.lua",
    'describe("cm", function()\n  it("works", function()\n    assert.is_true(true)\n  end)\nend)\n'
  )
  write(
    cm .. "/.github/workflows/ci.yml",
    table.concat({
      "# Modelled on ui.nvim's, deliberately.",
      "name: ci",
      "on: [push]",
      "jobs:",
      "  test:",
      "    runs-on: ubuntu-latest",
      "    steps:",
      "      - uses: actions/checkout@v4",
      "      - uses: actions/checkout@v4 # the diff plugin",
      "        with:",
      "          repository: StefanBartl/diff.nvim",
      "          path: .deps/diff.nvim",
      "",
    }, "\n")
  )
  local cm_report = migrate.analyze(cm, { fleet_root = fleet_dir })
  local cm_deps = {}
  for _, d in ipairs(cm_report.deps.list) do
    cm_deps[#cm_deps + 1] = d.name
  end
  eq(cm_deps, { "diff.nvim" }, "a dependency named only in a comment is not declared")

  -- ... but what the minimal init the CI starts (`-u scripts/minimal_init.lua`) puts on the runtimepath IN
  -- CODE is (data.nvim: add_optional_dep("DIFF_DIR", "diff.nvim", ...) while its CI says it in a comment)
  local dm = tmp .. "/dm.nvim"
  write(dm .. "/lua/dm/init.lua", 'local b = pcall(require, "diff.view")\nreturn { b }\n')
  write(
    dm .. "/TESTS/dm_spec.lua",
    'describe("dm", function()\n  it("works", function()\n    assert.is_true(true)\n  end)\nend)\n'
  )
  write(
    dm .. "/scripts/minimal_init.lua",
    '-- diff.nvim is optional\nadd_optional_dep("DIFF_DIR", "diff.nvim", "diff.view")\n'
  )
  write(
    dm .. "/.github/workflows/ci.yml",
    table.concat({
      "name: ci",
      "on: [push]",
      "jobs:",
      "  test:",
      "    runs-on: ubuntu-latest",
      "    steps:",
      "      - uses: actions/checkout@v4",
      "      # diff.nvim is optional here",
      '      - run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS/"',
      "",
    }, "\n")
  )
  local dm_report = migrate.analyze(dm, { fleet_root = fleet_dir })
  local dm_deps = {}
  for _, d in ipairs(dm_report.deps.list) do
    dm_deps[#dm_deps + 1] = d.name
  end
  eq(
    dm_deps,
    { "diff.nvim" },
    "the minimal init of the CI is read: its code names the optional dependency"
  )

  local ev = tmp .. "/ev.nvim"
  write(ev .. "/lua/ev/init.lua", "return {}\n")
  write(
    ev .. "/TESTS/ev_spec.lua",
    'describe("ev", function()\n  it("reads the repos dir", function()\n    assert.is_true(vim.env.REPOS_DIR == nil or true)\n  end)\nend)\n'
  )
  local ev_plan = migrate.run(ev, { fleet_root = fleet_dir })
  local ev_conf = op_by_path(ev_plan, ".testing.lua")
  ok(ev_conf ~= nil, "the config of the repository is planned")
  has(
    ev_conf.after,
    'env_allow = { "REPOS_DIR" }',
    "env_allow is proposed from what the specs read"
  )
  lacks(ev_conf.after, "timeouts", "no case limit is written without a measurement")
  lacks(ev_conf.after, "assertions", "no assertion policy is written without a measurement")
  has(ev_conf.after, 'isolated = "file"', "plenary-style specs get a process per file")

  vim.fn.delete(tmp, "rf")
end
