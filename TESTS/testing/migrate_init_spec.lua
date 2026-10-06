-- TESTS/testing/migrate_init_spec.lua -- what the migration learned from the first three repositories:
--   * the created Lua files follow the stylua.toml of the target repository (or the plan says why not),
--   * the generated files never name the old runner,
--   * `scripts/minimal_init.lua` (the old runner's init) is carried over, deleted and its references moved,
--   * prose that still talks about the old runner is listed with line numbers (specs: only counted),
--   * `assertions` / `timeouts` are hints, never written without a measurement,
--   * the error message of the generated scripts/test.sh uses one path separator style.

---@diagnostic disable: missing-fields, param-type-mismatch, need-check-nil, assign-type-mismatch

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 900) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local migrate = require("testing.migrate")
  local format = require("testing.migrate.format")
  local legacy_init = require("testing.migrate.legacy_init")
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
      .system({ "git", "-c", "user.email=t@t", "-c", "user.name=t", ... }, { cwd = root, text = true })
      :wait()
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. " failed: " .. tostring(res.stderr))
  end
  local function op_by_path(plan, path)
    for _, op in ipairs(plan.ops) do
      if op.path == path then
        return op
      end
    end
  end

  -- ---------------------------------------------------------------- fixtures

  local fleet_dir = tmp .. "/fleet"
  write(fleet_dir .. "/lib.nvim/lua/lib/nvim/notify/init.lua", "return {}\n")

  -- shaped like the init script of ui.nvim: header, a dependency lookup with a blank line inside the function,
  -- the lookups, the suite's own state (swap/shada, a fake clipboard)
  local OLD_INIT = [=[
-- scripts/minimal_init.lua -- headless test bootstrap for ui2.nvim.
--
-- Run from the repo root:
--   nvim --clean --headless -u scripts/minimal_init.lua \
--     -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'scripts/minimal_init.lua', sequential = true }"
vim.opt.rtp:append(vim.fn.getcwd())

--- lib.nvim is a hard runtime dependency. plenary.nvim is the busted-compatible
--- test harness the specs are written against.
---@param env_var string
---@param deps_name string
---@param marker string
local function add_dep(env_var, deps_name, marker)
  if pcall(require, marker) then
    return
  end

  local env_val = vim.env[env_var]
  if env_val and env_val ~= "" then
    vim.opt.rtp:append(env_val)
  end
  io.stderr:write(("scripts/minimal_init.lua: %s not found.\n"):format(deps_name))
  os.exit(1)
end

add_dep("LIB_NVIM_DIR", "lib.nvim", "lib.nvim.notify")
add_dep("PLENARY_DIR", "plenary.nvim", "plenary")

-- Swap and shada stay off for the whole suite, including plenary's child
-- processes that reuse this file: stale swap files fail suites with E326.
vim.o.swapfile = false
vim.o.shadafile = "NONE"

--- A fake, in-memory `+`/`*` clipboard provider for the whole suite.
local fake_clipboard = { ["+"] = {}, ["*"] = {} }
vim.g.clipboard = {
  name = "fake-test-clipboard",
  copy = {
    ["+"] = function(lines)
      fake_clipboard["+"] = lines
    end,
  },
  paste = {
    ["+"] = function()
      return fake_clipboard["+"]
    end,
  },
}
]=]

  local OLD_SH = [=[
#!/usr/bin/env bash
# Runs the busted/plenary spec suite headlessly. Wraps scripts/minimal_init.lua.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nvim -n --clean --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS/ { minimal_init = 'scripts/minimal_init.lua', sequential = true }"
]=]

  local OLD_CI = [=[
name: CI

on:
  push:

jobs:
  tests:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      # lib.nvim is found by scripts/minimal_init.lua in .deps/
      - uses: actions/checkout@v4
        with:
          repository: StefanBartl/lib.nvim
          path: .deps/lib.nvim
      - uses: actions/checkout@v4
        with:
          repository: nvim-lua/plenary.nvim
          path: .deps/plenary.nvim
      - run: nvim --headless -u scripts/minimal_init.lua -c "PlenaryBustedDirectory TESTS/"
]=]

  local SPEC = [=[
-- the old runner (plenary) reported this case as green
describe("ui2", function()
  it("works", function()
    assert.is_true(require("ui2") ~= nil)
  end)
end)
]=]

  ---@param name string
  ---@param opts? { init?: string, width?: integer, tabs?: boolean }
  local function make_repo(name, opts)
    opts = opts or {}
    local root = fleet_dir .. "/" .. name
    local plug = name:gsub("%.nvim$", "")
    write(
      root .. "/lua/" .. plug .. "/init.lua",
      'local n = require("lib.nvim.notify")\nreturn { n }\n'
    )
    write(root .. "/TESTS/" .. plug .. "_spec.lua", (SPEC:gsub("ui2", plug)))
    write(root .. "/scripts/test.sh", OLD_SH)
    write(root .. "/.github/workflows/ci.yml", OLD_CI)
    if opts.init ~= false then
      write(root .. "/scripts/minimal_init.lua", opts.init or OLD_INIT)
    end
    if opts.width then
      write(
        root .. "/stylua.toml",
        ('column_width = %d\nline_endings = "Unix"\nindent_type = "%s"\nindent_width = 2\n'):format(
          opts.width,
          opts.tabs and "Tabs" or "Spaces"
        )
      )
    end
    write(
      root .. "/README.md",
      "# "
        .. name
        .. "\n\n## Tests\n\nRun `scripts/test.sh`. It needs plenary.nvim and lib.nvim.\nSee scripts/minimal_init.lua.\n"
    )
    write(root .. "/TESTS/README.md", "# Tests\n\nWritten against plenary.nvim's busted harness.\n")
    write(
      root .. "/.luacheckrc",
      'std = "luajit"\n-- TESTS/ uses plenary globals (describe/it).\nfiles["TESTS/"] = { std = "+busted" }\n'
    )
    return root
  end

  local function plan_of(root)
    return migrate.run(root, { fleet_root = fleet_dir })
  end

  local function created_lua(plan)
    local out = {}
    for _, op in ipairs(plan.ops) do
      if op.action == "create" and op.path:match("%.lua$") then
        out[op.path] = op.after
      end
    end
    return out
  end

  -- ---------------------------------------------------------------- legacy_init.split

  local blocks = legacy_init.split(OLD_INIT)
  local kinds = {}
  for _, b in ipairs(blocks) do
    kinds[#kinds + 1] = b.kind
  end
  eq(
    kinds,
    { "drop", "drop", "drop", "carry", "carry" },
    "header + rtp, add_dep (one block, its inner blank line included), the lookups, the old runner's: dropped; swap/shada and clipboard: carried"
  )
  has(blocks[2].reason, "dependency lookup", "a dropped block says why")
  local carried = legacy_init.section(blocks, "scripts/minimal_init.lua")
  has(carried, "vim.o.swapfile = false", "swapfile is carried")
  has(carried, 'vim.o.shadafile = "NONE"', "shada is carried")
  has(carried, "fake-test-clipboard", "the fake clipboard is carried")
  has(carried, "the old runner's child", "a comment that named the old runner is reworded")
  ok(not carried:lower():find("plenary", 1, true), "nothing carried names the old runner")
  lacks(carried, "add_dep", "the old lookup is not carried")

  -- ---------------------------------------------------------------- the plan of a ui.nvim-like repository

  local root = make_repo("ui2.nvim", { width = 100 })
  local plan = plan_of(root)
  local minit = op_by_path(plan, "TESTS/minimal_init.lua")
  ok(minit ~= nil and minit.action == "create", "TESTS/minimal_init.lua is created")
  has(
    minit.after,
    "Carried over from scripts/minimal_init.lua",
    "the carried state is a visible, commented block"
  )
  has(minit.after, "vim.o.swapfile = false", "swapfile is kept")
  has(minit.after, "fake-test-clipboard", "the fake clipboard is kept")
  ok(
    minit.after:find("vim.o.swapfile", 1, true)
      < minit.after:find("return { root = root, deps = found }", 1, true),
    "the carried block runs before the file returns"
  )
  ok(loadstring(minit.after) ~= nil, "and the file compiles")
  ok(
    minit.diff:find("+++ b/TESTS/minimal_init.lua", 1, true) ~= nil,
    "the new file is shown as a diff"
  )

  local del = op_by_path(plan, "scripts/minimal_init.lua")
  ok(del ~= nil and del.action == "delete", "the old init script is deleted in the plan")
  eq(del.after, nil, "a deletion has no new text")
  has(del.diff, "+++ /dev/null", "its diff goes to /dev/null")
  has(del.diff, "-add_dep(", "the diff shows the removed dependency lookup")
  ok(
    #del.removed == #(require("testing.migrate.text").lines(OLD_INIT)),
    "every removed line is listed"
  )
  has(del.reason, "carried over", "the reason says what happened to the content")

  local ci_op = op_by_path(plan, ".github/workflows/ci.yml")
  ok(ci_op ~= nil, "the workflow is edited")
  lacks(ci_op.after, "scripts/minimal_init.lua", "the workflow does not name the deleted file")
  has(ci_op.after, "TESTS/minimal_init.lua", "it names the new one")

  -- never names the old runner
  for path, after in pairs({
    [".testing.lua"] = op_by_path(plan, ".testing.lua").after,
    ["TESTS/minimal_init.lua"] = minit.after,
    ["scripts/test.sh"] = op_by_path(plan, "scripts/test.sh").after,
  }) do
    ok(
      not after:lower():find("plenary", 1, true),
      path .. " does not mention plenary (case-insensitive)"
    )
  end

  -- hints for the prose, never edits
  local notes = table.concat(plan.notes, "\n")
  has(notes, "cleanup hint, README.md", "the README is named")
  has(notes, "5: Run `scripts/test.sh`. It needs plenary.nvim", "with its line number and text")
  has(
    notes,
    "6: See scripts/minimal_init.lua.",
    "a reference to the deleted init script is listed too"
  )
  has(notes, "cleanup hint, TESTS/README.md", "the tests README is named")
  has(notes, "3: Written against plenary.nvim", "line 3 of it")
  has(notes, "cleanup hint, .luacheckrc", ".luacheckrc is named")
  has(notes, "2: -- TESTS/ uses plenary globals", "its comment line")
  has(notes, "1 line(s) in spec files mention plenary", "a spec comment is only counted")
  has(notes, "ui2_spec.lua:1", "with its position")
  ok(op_by_path(plan, "TESTS/ui2_spec.lua") == nil, "a spec is never in the plan")
  for _, op in ipairs(plan.ops) do
    ok(
      op.path ~= "README.md" and op.path ~= "TESTS/README.md" and op.path ~= ".luacheckrc",
      "prose is not edited"
    )
  end

  -- no measurement: hints only
  has(notes, "`assertions` is not set", "assertions is a hint")
  lacks(op_by_path(plan, ".testing.lua").after, "assertions", "no assertions line")
  lacks(op_by_path(plan, ".testing.lua").after, "timeouts", "no timeouts line")
  lacks(op_by_path(plan, ".testing.lua").after, "plenary", ".testing.lua names no old runner")

  -- ---------------------------------------------------------------- apply, then the plan is empty

  git(root, "init", "-q")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "init")
  local res = migrate.apply(plan, { apply = true })
  eq(res.errors, {}, "apply works")
  eq(res.deleted, { "scripts/minimal_init.lua" }, "the old init script is deleted")
  ok(vim.uv.fs_stat(root .. "/scripts/minimal_init.lua") == nil, "and gone from the disk")
  ok(vim.uv.fs_stat(root .. "/TESTS/minimal_init.lua") ~= nil, "the new one is on the disk")
  eq(plan_of(root).empty, true, "the plan of the migrated repository is empty")

  -- a stale plan is refused: the file changed since
  local root2 = make_repo("stale2.nvim")
  local stale = plan_of(root2)
  git(root2, "init", "-q")
  git(root2, "add", "-A")
  git(root2, "commit", "-q", "-m", "init")
  write(root2 .. "/scripts/minimal_init.lua", OLD_INIT .. "-- later\n")
  git(root2, "add", "-A")
  git(root2, "commit", "-q", "-m", "later")
  local refused = migrate.apply(stale, { apply = true })
  ok(#refused.errors > 0, "a deletion of a changed file is refused")
  ok(vim.uv.fs_stat(root2 .. "/scripts/minimal_init.lua") ~= nil, "and the file is still there")
  ok(vim.uv.fs_stat(root2 .. "/.testing.lua") == nil, "nothing was written")

  -- the new init really sets the carried state up (a child nvim, the dependencies from beside the repo)
  local testing_dir = vim.fs.dirname(
    vim.fs.dirname(vim.fs.dirname(vim.api.nvim_get_runtime_file("lua/testing/init.lua", false)[1]))
  )
  local child = vim
    .system({
      "nvim",
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      root .. "/TESTS/minimal_init.lua",
      "-c",
      "lua io.stdout:write(tostring(vim.o.swapfile), ' ', tostring(vim.g.clipboard.name), '\\n')",
      "-c",
      "qa!",
    }, { text = true, env = { TESTING_NVIM_DIR = testing_dir }, timeout = 30000 })
    :wait()
  ok(child.code == 0, "the generated init loads: " .. tostring(child.stderr))
  has(
    child.stdout,
    "false fake-test-clipboard",
    "swapfile is off and the fake clipboard is installed"
  )

  -- ---------------------------------------------------------------- an init that is not the old runner's stays

  local root3 = make_repo("plain3.nvim", { init = "vim.o.number = true\n" })
  write(
    root3 .. "/.github/workflows/ci.yml",
    (OLD_CI:gsub("scripts/minimal_init%.lua", "TESTS/minimal_init.lua"))
  )
  write(
    root3 .. "/scripts/test.sh",
    (OLD_SH:gsub("scripts/minimal_init%.lua", "TESTS/minimal_init.lua"))
  )
  local plan3 = plan_of(root3)
  ok(
    op_by_path(plan3, "scripts/minimal_init.lua") == nil,
    "an init nobody starts and that says nothing about the old runner stays"
  )
  has(table.concat(plan3.notes, "\n"), "it stays as it is", "and the plan says so")

  -- both files: merge by hand, nothing deleted
  local root4 = make_repo("both4.nvim")
  write(root4 .. "/TESTS/minimal_init.lua", "vim.opt.rtp:append(vim.fn.getcwd())\n")
  local plan4 = plan_of(root4)
  ok(op_by_path(plan4, "scripts/minimal_init.lua") == nil, "with both files nothing is deleted")
  has(table.concat(plan4.notes, "\n"), "both exist", "the plan asks for a merge by hand")

  -- a carried local that the template uses itself is a risk
  local clash = OLD_INIT .. "\nlocal root = vim.fn.getcwd()\n"
  local root5 = make_repo("clash5.nvim", { init = clash })
  has(
    table.concat(plan_of(root5).risks, "\n"),
    "defines a local `root`",
    "a shadowing local is reported"
  )

  -- ---------------------------------------------------------------- stylua: the call

  local calls = {}
  local function fake_stylua(code, out)
    return {
      exe = "stylua",
      run = function(argv, stdin, cwd)
        calls[#calls + 1] = { argv = argv, stdin = stdin, cwd = cwd }
        return { code = code, stdout = out and (out .. stdin) or nil, stderr = "boom" }
      end,
    }
  end
  local root6 = make_repo("fmt6.nvim", { width = 130 })
  local plan6 =
    migrate.run(root6, { fleet_root = fleet_dir, format = fake_stylua(0, "-- formatted\n") })
  eq(#calls, 2, "stylua runs on each created Lua file (.testing.lua, TESTS/minimal_init.lua)")
  for _, c in ipairs(calls) do
    eq(c.cwd, root6, "in the repository")
    eq(c.argv[1], "stylua", "the executable")
    eq(c.argv[2], "--config-path", "with the configuration of the repository")
    eq(c.argv[3], root6 .. "/stylua.toml", "namely its stylua.toml")
    eq(c.argv[4], "--stdin-filepath", "the file name decides ignore rules")
    eq(c.argv[6], "-", "the text comes on stdin")
  end
  ok(
    op_by_path(plan6, "TESTS/minimal_init.lua").after:sub(1, 13) == "-- formatted\n",
    "the formatted text is the plan's text"
  )
  ok(
    op_by_path(plan6, "scripts/test.sh").after:sub(1, 13) ~= "-- formatted\n",
    "a shell script is not given to stylua"
  )
  ok(
    op_by_path(plan6, ".github/workflows/ci.yml").after:sub(1, 13) ~= "-- formatted\n",
    "nor a workflow"
  )

  -- stylua failing keeps the template text and says so
  calls = {}
  local plan7 = migrate.run(root6, { fleet_root = fleet_dir, format = fake_stylua(2, nil) })
  ok(op_by_path(plan7, "TESTS/minimal_init.lua") ~= nil, "a failing stylua does not stop the plan")
  has(
    table.concat(plan7.notes, "\n"),
    "stylua could not format TESTS/minimal_init.lua",
    "and the note says what failed"
  )

  -- stylua missing: a note, not a failure
  local plan8 = migrate.run(root6, { fleet_root = fleet_dir, format = { exe = false } })
  local notes8 = table.concat(plan8.notes, "\n")
  has(notes8, "stylua is not on PATH: TESTS/minimal_init.lua", "a missing stylua is a hint")
  has(notes8, "column_width 130", "that names the width of the repository")
  has(notes8, "stylua is not on PATH: .testing.lua", "for each file")
  ok(op_by_path(plan8, "TESTS/minimal_init.lua") ~= nil, "the plan is complete without stylua")

  -- without a stylua.toml nothing is formatted and nothing is said
  calls = {}
  local root9 = make_repo("nocfg9.nvim")
  local plan9 =
    migrate.run(root9, { fleet_root = fleet_dir, format = fake_stylua(0, "-- formatted\n") })
  eq(#calls, 0, "no stylua.toml: stylua is not called")
  lacks(table.concat(plan9.notes, "\n"), "stylua", "and no hint about it")
  eq(format.config_of(root9), nil, "no configuration")

  -- ---------------------------------------------------------------- stylua: the real thing (when installed)

  if vim.fn.executable("stylua") == 1 then
    local outputs = {}
    for _, cfg in ipairs({
      { name = "w100", width = 100 },
      { name = "w130", width = 130 },
      { name = "tabs", width = 100, tabs = true },
    }) do
      local r = make_repo("real_" .. cfg.name .. ".nvim", { width = cfg.width, tabs = cfg.tabs })
      local p = plan_of(r)
      local files = created_lua(p)
      ok(
        files["TESTS/minimal_init.lua"] ~= nil and files[".testing.lua"] ~= nil,
        cfg.name .. ": both Lua files are created"
      )
      local check = tmp .. "/check_" .. cfg.name
      vim.fn.mkdir(check, "p")
      write(check .. "/stylua.toml", slurp(r .. "/stylua.toml"))
      for path, after in pairs(files) do
        write(check .. "/" .. path, after)
      end
      local res_check = vim
        .system(
          { "stylua", "--check", "--config-path", check .. "/stylua.toml", "." },
          { cwd = check, text = true }
        )
        :wait()
      ok(
        res_check.code == 0,
        cfg.name
          .. ": the created files pass `stylua --check` with the repository's stylua.toml: "
          .. tostring(res_check.stdout)
          .. tostring(res_check.stderr)
      )
      outputs[cfg.name] = files["TESTS/minimal_init.lua"]
    end
    ok(
      outputs.w100 ~= outputs.w130,
      "the width of the repository decides the layout (100 and 130 differ)"
    )
    ok(
      outputs.w100 ~= outputs.tabs and outputs.tabs:find("\n\t", 1, true) ~= nil,
      "tabs for a repository that indents with tabs"
    )
  end

  -- ---------------------------------------------------------------- scripts/test.sh: one separator style

  local bash = vim.fn.exepath("bash")
  local usable = bash ~= ""
    and not bash:lower():find("system32", 1, true)
    and not bash:lower():find("windowsapps", 1, true)
  if usable then
    local proj = tmp .. "/shproj"
    write(proj .. "/scripts/test.sh", op_by_path(plan, "scripts/test.sh").after)
    local run = vim
      .system({ bash, proj .. "/scripts/test.sh" }, {
        cwd = proj,
        text = true,
        env = {
          LOCALAPPDATA = "C:\\Users\\nobody\\AppData\\Local",
          TESTING_NVIM_DIR = "C:\\no\\such\\testing.nvim",
          NVIM_APPNAME = "nvim",
        },
        timeout = 30000,
      })
      :wait()
    eq(run.code, 1, "a missing dependency exits with 1")
    has(run.stderr, "dependency 'testing.nvim' not found", "and names it")
    has(run.stderr, "1. $TESTING_NVIM_DIR", "the first place")
    has(run.stderr, "4. stdpath('data')/lazy/testing.nvim", "the fourth place")
    lacks(run.stderr, "\\", "no backslash in the printed paths (one separator style)")
    has(run.stderr, "C:/no/such/testing.nvim", "the override is shown with forward slashes")
  end

  vim.fn.delete(tmp, "rf")
end
