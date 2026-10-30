-- TESTS/testing/scaffold_update_spec.lua -- `testing init --update` (testing.scaffold.update): scripts/test.sh and
-- TESTS/minimal_init.lua brought to the current templates, keeping the repository's own parts (dependencies, the
-- --sentinel of the run line, a deliberate missing NVIM_APPNAME, what minimal_init sets up after the runtimepath),
-- listing what would be lost, never executing .testing.lua; the CLI's preview, --check and --write.

---@diagnostic disable: need-check-nil, param-type-mismatch

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      ("%s: %q found in %q"):format(msg, needle, tostring(haystack):sub(1, 1500))
    )
  end

  local scaffold = require("testing.scaffold")
  local update = require("testing.scaffold.update")
  local base = vim.fs.normalize(vim.fn.tempname())
  local NOFMT = { format = { exe = false } }

  local function slurp(path)
    local fh = assert(io.open(path, "rb"))
    local s = fh:read("a")
    fh:close()
    return s
  end
  local function put(path, s)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local fh = assert(io.open(path, "wb"))
    fh:write(s)
    fh:close()
  end
  ---A freshly scaffolded project.
  local function project(name)
    local root = base .. "/" .. name
    vim.fn.mkdir(root .. "/lua/" .. name:gsub("%.nvim$", ""), "p")
    eq(scaffold.init(root).errors, {}, name .. ": scaffold")
    return root
  end
  local function file(plan, rel)
    for _, f in ipairs(plan.files) do
      if f.rel == rel then
        return f
      end
    end
  end

  -- ---------------------------------------------------------------- a fresh setup is up to date
  local fresh = project("fresh.nvim")
  local p = update.plan(fresh, NOFMT)
  eq(p.errors, {}, "fresh: no errors")
  eq(p.plugin, "fresh", "fresh: the plugin")
  eq(p.deps, { "lib.nvim" }, "fresh: the dependencies from scripts/test.sh")
  eq(file(p, "scripts/test.sh").changed, false, "fresh: scripts/test.sh is up to date")
  eq(file(p, "TESTS/minimal_init.lua").changed, false, "fresh: minimal_init is up to date")

  -- ---------------------------------------------------------------- an older test.sh: kept parts and lost lines
  local old = project("old.nvim")
  local sh_path = old .. "/scripts/test.sh"
  local sh = slurp(sh_path)
  sh = sh:gsub("DEPS=%(([^)]*)%)", "DEPS=(%1 'ui.nvim')", 1)
  sh =
    sh:gsub("\nexport NVIM_APPNAME=[^\n]*", '\nexport NVIM_APPNAME="${NVIM_APPNAME:-old-tests}"', 1)
  sh = sh:gsub(' run %. "%$@"', " run . --sentinel 'OLD_TESTS_OK' \"$@\"", 1)
  sh = sh:gsub("\nset %-euo pipefail\n", "\nset -euo pipefail\nOPTIONAL_DEPS=('snacks.nvim')\n", 1)
  put(sh_path, sh)
  p = update.plan(old, NOFMT)
  local f = file(p, "scripts/test.sh")
  eq(f.changed, true, "old: scripts/test.sh is out of date")
  has(
    f.after,
    "DEPS=('testing.nvim' 'lib.nvim' 'ui.nvim')",
    "old: the dependencies of the old file are kept"
  )
  has(
    f.after,
    "run . --sentinel 'OLD_TESTS_OK' \"$@\"",
    "old: the --sentinel of the run line is kept"
  )
  has(f.after, 'export NVIM_APPNAME="old-tests"', "old: the throwaway app name is the template's")
  eq(
    f.dropped,
    { "OPTIONAL_DEPS=('snacks.nvim')" },
    "old: the repository's own line is listed as lost"
  )
  has(
    table.concat(f.kept, "\n"),
    "1 line(s) of an older template version replaced",
    "old: the old export is counted"
  )
  has(f.diff, "-OPTIONAL_DEPS=('snacks.nvim')", "old: and the diff shows it")
  has(
    table.concat(update.lines(p, { diff = true }), "\n"),
    "only in the old file (1 code line(s)",
    "old: the report"
  )

  -- ---------------------------------------------------------------- a deliberate missing NVIM_APPNAME stays missing
  local noapp = project("noapp.nvim")
  sh = slurp(noapp .. "/scripts/test.sh")
  local own_comment =
    "# NVIM_APPNAME is deliberately not set: the stdpath specs compare with a shim without it."
  sh = sh:gsub("\n#[^\n]*\n#[^\n]*\nexport NVIM_APPNAME=[^\n]*", "\n" .. own_comment, 1)
  lacks(sh, "export NVIM_APPNAME=", "noapp: the fixture has no export")
  put(noapp .. "/scripts/test.sh", sh)
  f = file(update.plan(noapp, NOFMT), "scripts/test.sh")
  lacks(f.after, "export NVIM_APPNAME=", "noapp: no export is added")
  has(f.after, own_comment, "noapp: the file's own reason stays")
  eq(f.changed, false, "noapp: otherwise it is the template")

  -- ---------------------------------------------------------------- minimal_init: what is set up after the runtimepath
  local extra = project("extra.nvim")
  local minit_path = extra .. "/TESTS/minimal_init.lua"
  local tail = "return { root = root, deps = found }"
  local minit = slurp(minit_path):gsub(vim.pesc(tail), "vim.o.swapfile = false\n\n" .. tail, 1)
  put(minit_path, minit)
  f = file(update.plan(extra, NOFMT), "TESTS/minimal_init.lua")
  eq(f.changed, false, "extra: a gate with its own settings after the runtimepath is up to date")
  -- an older gate (one template line missing) keeps them when it is brought up to date
  put(minit_path, (minit:gsub("\nlocal MARKERS", "\n-- old\nlocal MARKERS", 1)))
  f = file(update.plan(extra, NOFMT), "TESTS/minimal_init.lua")
  eq(f.changed, true, "extra: an older gate is out of date")
  has(f.after, "vim.o.swapfile = false", "extra: its own settings are kept")
  ok(loadstring(f.after) ~= nil, "extra: the result compiles")

  -- a minimal_init that is not the gate is replaced by it, with what it set up carried over
  local legacy = project("legacy.nvim")
  put(
    legacy .. "/TESTS/minimal_init.lua",
    "vim.opt.rtp:prepend(vim.fn.getcwd())\nvim.g.legacy_marker = 1\n"
  )
  f = file(update.plan(legacy, NOFMT), "TESTS/minimal_init.lua")
  has(f.after, "local MARKERS", "legacy: it becomes the gate")
  has(f.after, "vim.g.legacy_marker = 1", "legacy: what it set up is carried over")
  has(table.concat(f.kept, "\n"), "1 block(s) carried over", "legacy: and the plan says so")

  -- ---------------------------------------------------------------- what must never be hidden or lost without a word
  -- a block of the repository's own with a verb of its own is listed, not counted as an older template line
  local own = project("own.nvim")
  sh = slurp(own .. "/scripts/test.sh")
  local own_block =
    'if [ "${1:-}" = "slow" ]; then\n  shift\n  nvim -n -i NONE --headless -u NONE -l "$DRIVER" run . --tags=slow "$@"\n  exit $?\nfi\n'
  sh = sh:gsub(
    "\n# `scripts/test.sh conformance`",
    "\n" .. own_block .. "# `scripts/test.sh conformance`",
    1
  )
  put(own .. "/scripts/test.sh", sh)
  f = file(update.plan(own, NOFMT), "scripts/test.sh")
  has(table.concat(f.dropped, "\n"), 'if [ "${1:-}" = "slow" ]; then', "own: its verb is listed")
  has(table.concat(f.dropped, "\n"), "run . --tags=slow", "own: its run line is listed")
  eq(f.code_changed, true, "own: a code difference")

  -- a DEPS line in double quotes is read; one this cannot read is a risk and the next source is used
  local dq = project("dq.nvim")
  sh = slurp(dq .. "/scripts/test.sh"):gsub(
    "DEPS=%([^)]*%)",
    'DEPS=("testing.nvim" "lib.nvim" "ui.nvim")',
    1
  )
  put(dq .. "/scripts/test.sh", sh)
  eq(update.plan(dq, NOFMT).deps, { "lib.nvim", "ui.nvim" }, "dq: double-quoted names")
  put(dq .. "/scripts/test.sh", (sh:gsub("DEPS=%([^)]*%)", 'DEPS=("testing.nvim" "$EXTRA")', 1)))
  p = update.plan(dq, NOFMT)
  eq(p.deps, { "lib.nvim" }, "dq: an unreadable word falls back to .testing.lua")
  has(
    table.concat(file(p, "scripts/test.sh").risks, "\n"),
    'cannot read: "$EXTRA"',
    "dq: and says so"
  )

  -- a comment only in the old file is shown, and it is not code drift (`--check` stays green for it)
  local cmt = project("cmt.nvim")
  minit = slurp(cmt .. "/TESTS/minimal_init.lua")
  put(
    cmt .. "/TESTS/minimal_init.lua",
    "-- ui.nvim is not needed here: hard dependencies only\n" .. minit
  )
  f = file(update.plan(cmt, NOFMT), "TESTS/minimal_init.lua")
  eq({ f.changed, f.code_changed }, { true, false }, "cmt: changed, but not in code")
  eq(
    f.dropped_comments,
    { "-- ui.nvim is not needed here: hard dependencies only" },
    "cmt: the comment is listed"
  )
  has(
    table.concat(update.lines(update.plan(cmt, NOFMT)), "\n"),
    "(comments only)",
    "cmt: the report says so"
  )

  -- an export of the file's own (indented, inside an if) counts as setting NVIM_APPNAME
  local cond = project("cond.nvim")
  sh = slurp(cond .. "/scripts/test.sh"):gsub(
    "\nexport NVIM_APPNAME=[^\n]*",
    '\nif [[ -z "${KEEP_APP:-}" ]]; then\n  export NVIM_APPNAME="cond-tests"\nfi',
    1
  )
  put(cond .. "/scripts/test.sh", sh)
  f = file(update.plan(cond, NOFMT), "scripts/test.sh")
  has(f.after, 'export NVIM_APPNAME="cond-tests"', "cond: the template's export stays")
  lacks(
    table.concat(f.kept, "\n"),
    "no NVIM_APPNAME export",
    "cond: no claim that the file did not set one"
  )

  -- the runtimepath loop on one line (a formatter's collapse) still marks where the file's own settings start
  local one = project("one.nvim")
  minit = slurp(one .. "/TESTS/minimal_init.lua")
    :gsub(
      "for _, name in ipairs%(DEPS%) do\n%s*vim%.opt%.rtp:append%(found%[name%]%)\nend",
      "for _, name in ipairs(DEPS) do vim.opt.rtp:append(found[name]) end",
      1
    )
    :gsub(
      vim.pesc("return { root = root, deps = found }"),
      "vim.o.swapfile = false\n\nreturn { root = root, deps = found }",
      1
    )
  has(minit, "do vim.opt.rtp:append(found[name]) end", "one: the fixture has the collapsed loop")
  put(one .. "/TESTS/minimal_init.lua", minit)
  has(
    file(update.plan(one, NOFMT), "TESTS/minimal_init.lua").after,
    "vim.o.swapfile = false",
    "one: its settings are kept"
  )

  -- --write holds back a file with a risk, and one with uncommitted changes; --force writes them
  put(dq .. "/scripts/test.sh", sh:gsub("cond", "dq"))
  local risky = update.plan(dq, NOFMT)
  file(risky, "scripts/test.sh").risks = { "a risk" }
  local w, e, held = update.apply(risky, { git = function() end })
  eq({ w, e, held[1] and held[1].rel }, { {}, {}, "scripts/test.sh" }, "hold: a file with a risk")
  has(
    table.concat(update.lines(risky, { written = w, held = held }), "\n"),
    "@@ ",
    "hold: its diff is shown"
  )
  held = select(
    3,
    update.apply(update.plan(dq, NOFMT), {
      git = function(_, rel)
        return rel == "scripts/test.sh" and " M scripts/test.sh" or nil
      end,
    })
  )
  eq(
    held[1] and held[1].why:match("uncommitted"),
    "uncommitted",
    "hold: a file with uncommitted changes"
  )
  w = update.apply(update.plan(dq, NOFMT), {
    force = true,
    git = function()
      return " M x"
    end,
  })
  eq(w, { "scripts/test.sh" }, "hold: --force writes it")

  -- ---------------------------------------------------------------- .testing.lua is read as text, never executed
  local trap = project("trap.nvim")
  local marker = trap .. "/EXECUTED"
  put(
    trap .. "/.testing.lua",
    ('local fh = io.open(%q, \'w\') if fh then fh:close() end\nreturn {\n  plugin = "trap",\n  deps = { "lib.nvim" },\n}\n'):format(
      marker
    )
  )
  vim.fn.delete(trap .. "/scripts/test.sh")
  p = update.plan(trap, NOFMT)
  eq(vim.uv.fs_stat(marker), nil, "trap: .testing.lua was not executed")
  eq({ p.plugin, p.deps }, { "trap", { "lib.nvim" } }, "trap: plugin and deps read from its text")
  eq(file(p, "scripts/test.sh").before, nil, "trap: a missing scripts/test.sh is planned as new")

  -- ---------------------------------------------------------------- apply, then everything is up to date
  -- the dependencies of the old scripts/test.sh (ui.nvim added above) reach minimal_init as well
  local written, errors = update.apply(update.plan(old, NOFMT))
  eq(
    { written, errors },
    { { "scripts/test.sh", "TESTS/minimal_init.lua" }, {} },
    "apply: writes the changed files"
  )
  has(
    slurp(old .. "/TESTS/minimal_init.lua"),
    '"ui.nvim"',
    "apply: minimal_init looks for ui.nvim too"
  )
  eq(
    update.apply(update.plan(fresh, NOFMT)),
    {},
    "apply: a project that is up to date is not written"
  )
  for _, g in ipairs(update.plan(old, NOFMT).files) do
    eq(g.changed, false, "apply: afterwards up to date: " .. g.rel)
  end

  -- ---------------------------------------------------------------- the CLI
  local cli = require("testing.cli")
  local function run(argv)
    local out, err = {}, {}
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  put(sh_path, sh:gsub("noapp", "old"))
  local r = run({ "init", old, "--update", "--check" })
  eq(r.code, 1, "cli --check: a file out of date is exit 1\n" .. r.out .. r.err)
  lacks(r.out, "@@ ", "cli --check: no diff")
  r = run({ "init", old, "--update" })
  eq(r.code, 0, "cli preview: exit 0")
  has(r.out, "@@ ", "cli preview: the diff")
  has(r.out, "testing init --update --write", "cli preview: says how to write")
  r = run({ "init", old, "--update", "--write" })
  eq(r.code, 0, "cli --write: exit 0\n" .. r.err)
  has(r.out, "updated", "cli --write: says what it wrote")
  eq(run({ "init", old, "--update", "--check" }).code, 0, "cli --check after --write: exit 0")
  eq(run({ "init", old, "--write" }).code, 2, "cli: --write without --update is bad usage")
  eq(run({ "init", old, "--update", "--force" }).code, 2, "cli: --update with --force is bad usage")
  local made = base .. "/made.nvim"
  vim.fn.mkdir(made .. "/lua/made", "p")
  r = run({ "init", made })
  eq(r.code, 0, "cli init: exit 0\n" .. r.err)
  has(r.out, "created: .testing.lua", "cli init: creates the setup")
  has(run({ "init", made }).out, "skipped: .testing.lua", "cli init again: keeps what exists")

  vim.fn.delete(base, "rf")
end
