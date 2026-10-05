-- TESTS/testing/scaffold_spec.lua -- `testing init`: the generated files, their invariants (NEW-39/40/45/49),
-- no overwrite, force, hostile names (SEC-42/46) and a real run of what was generated.

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end

  local scaffold = require("testing.scaffold")
  local render = require("testing.scaffold.render")
  local read = require("lib.nvim.fs.read")
  local is_windows = vim.fn.has("win32") == 1

  local tmp = vim.fs.normalize(vim.fn.tempname())
  local function mkproj(dirname, lua_dirs)
    local root = tmp .. "/" .. dirname
    vim.fn.mkdir(root, "p")
    for _, d in ipairs(lua_dirs or {}) do
      vim.fn.mkdir(root .. "/" .. d, "p")
    end
    return root
  end
  local function slurp(path)
    local text = read(path)
    ok(text ~= nil, "cannot read " .. path)
    return text
  end
  local function list_files(root)
    local out = {}
    for _, f in
      ipairs(vim.fs.find(function()
        return true
      end, { path = root, type = "file", limit = 1000 }))
    do
      out[#out + 1] = f:sub(#root + 2)
    end
    table.sort(out)
    return out
  end

  -- ---------------------------------------------------------------- sanitize (SEC-42)

  eq(scaffold.sanitize_plugin("myplug"), "myplug", "a plain name is kept")
  eq(scaffold.sanitize_plugin("my plug"), "my_plug", "a space becomes an underscore")
  eq(scaffold.sanitize_plugin("\27[31mred\27[0m"), "red", "color sequences are removed first")
  eq(scaffold.sanitize_plugin("\27]0;title\7name"), "name", "an OSC sequence is removed first")
  eq(scaffold.sanitize_plugin(".."), nil, "dots only: nothing usable")
  eq(scaffold.sanitize_plugin("../../etc"), "etc", "a traversal keeps no separator")
  eq(scaffold.sanitize_plugin(""), nil, "empty: nothing usable")
  eq(scaffold.sanitize_plugin(42), nil, "not a string: nothing usable")
  eq(#scaffold.sanitize_plugin(("a"):rep(500)) <= 64, true, "the length is bounded")
  for _, hostile in ipairs({
    'x"; rm -rf /; "',
    "a\nb\rc",
    "$(touch pwned)",
    "`id`",
    "a'b",
    "a\\",
    "é\0x",
    "x]]; os.execute('boom') --",
  }) do
    local s = scaffold.sanitize_plugin(hostile)
    ok(
      s == nil or (s:match("^[%w_%-]+$") ~= nil and #s <= 64),
      "hostile name " .. vim.inspect(hostile) .. " is reduced to [%w_-], got " .. vim.inspect(s)
    )
  end

  -- ---------------------------------------------------------------- render (SEC-46)

  -- every quoting must read back as the same text in the language it is for
  for _, v in ipairs({
    "plain",
    "a\\",
    'a"b',
    'a\\"b',
    "line\nbreak",
    "cr\r\n",
    "tab\t",
    "\\n",
    "]]",
  }) do
    local chunk = load("return " .. render.lua_quote(v))
    ok(chunk ~= nil, "lua_quote(" .. vim.inspect(v) .. ") is a valid literal")
    eq(chunk(), v, "lua_quote round-trips " .. vim.inspect(v))
  end
  eq(render.sh_quote("a'b"), [['a'\''b']], "sh_quote closes, escapes and reopens the quote")
  eq(render.sh_quote("$(x)"), "'$(x)'", "sh_quote does not expand")
  eq(render.yaml_quote('a"b\\'), '"a\\"b\\\\"', "yaml_quote escapes the backslash and the quote")

  eq(
    render.render("x=@@A|lua@@", { A = "q\\" }),
    'x="q\\\\"',
    "a trailing backslash cannot close the quote"
  )
  eq(render.render("@@L|lua@@", { L = { "a", "b" } }), '{ "a", "b" }', "a list as a Lua table")
  eq(render.render("@@L|lua@@", { L = {} }), "{}", "an empty list as a Lua table")
  eq(render.render("@@L|sh@@", { L = { "a b", "c" } }), "'a b' 'c'", "a list as shell words")
  eq(
    render.render("@@A|raw@@", { A = "@@B@@" }),
    "@@B@@",
    "a value is not scanned for placeholders again"
  )
  eq(render.render("a\r\nb", {}), "a\nb", "CRLF in a template becomes LF")
  eq(render.render("@@A@@", { A = "ok-1_2.3/x" }), "ok-1_2.3/x", "a bare word may hold [%w._/-]")
  for _, bad in ipairs({ 'a"b', "a b", "a;b", "a$b", "a\nb", "a'b", ("x"):rep(500) }) do
    local out, err = render.render("@@A@@", { A = bad })
    eq(out, nil, "a bare placeholder refuses " .. vim.inspect(bad):sub(1, 20))
    has(err, "placeholder A", "the refusal names the placeholder")
  end
  local missing, merr = render.render("@@NOPE@@", {})
  eq(missing, nil, "an unknown placeholder is an error, never shipped")
  has(merr, "NOPE", "the error names it")
  eq((render.render("@@A|bogus@@", { A = "x" })), nil, "an unknown mode is an error")
  eq((render.render("@@A|lua@@", { A = "x\0y" })), nil, "NUL is refused")
  eq((render.render("@@A|yaml@@", { A = { "x" } })), nil, "yaml takes a string only")

  -- ---------------------------------------------------------------- detection

  eq(
    scaffold.detect_plugin(mkproj("one.nvim", { "lua/one" })),
    "one",
    "the only lua/<name> directory"
  )
  eq(
    scaffold.detect_plugin(mkproj("two.nvim", { "lua/zzz", "lua/two" })),
    "two",
    "the one that matches the repository name"
  )
  eq(
    scaffold.detect_plugin(mkproj("three.nvim", { "lua/aaa", "lua/bbb" })),
    "three",
    "ambiguous: the repository name"
  )
  eq(scaffold.detect_plugin(mkproj("bare-repo")), "bare-repo", "no lua/: the directory name")
  eq(
    scaffold.detect_plugin(mkproj("x.nvim", { "lua/.hidden" })),
    "x",
    "a hidden directory is not a module"
  )

  -- ---------------------------------------------------------------- init: files and invariants

  local root = mkproj("myplug.nvim", { "lua/myplug" })
  local result = scaffold.init(root)
  eq(result.errors, {}, "init has no errors")
  eq(result.skipped, {}, "nothing existed yet")
  eq(result.replaced, {}, "nothing was replaced")
  eq(result.plugin, "myplug", "the plugin name was detected")
  local expected = {
    ".github/workflows/ci.yml",
    ".gitattributes",
    ".luacheckrc",
    ".testing.lua",
    "TESTS/minimal_init.lua",
    "TESTS/myplug/load_spec.lua",
    "scripts/test.sh",
    "stylua.toml",
  }
  local created = vim.deepcopy(result.created)
  table.sort(created)
  table.sort(expected)
  eq(created, expected, "the files that were created")
  eq(list_files(root), expected, "and no other file exists")

  local texts = {}
  for _, rel in ipairs(expected) do
    texts[rel] = slurp(root .. "/" .. rel)
    lacks(texts[rel], "@@", rel .. " has no placeholder left")
    lacks(texts[rel], "\r", rel .. " is LF only")
  end

  -- NEW-40: loud, exit 1, all four places, in the runner and in the minimal init
  local sh = texts["scripts/test.sh"]
  has(sh, "#!/usr/bin/env bash", "test.sh has a shebang")
  has(sh, "set -euo pipefail", "test.sh stops at the first error")
  has(sh, "exit 1", "test.sh fails with exit code 1")
  has(sh, "nvim is not on PATH", "test.sh names a missing nvim")
  for _, place in ipairs({
    "1. \\$$envname",
    "2. .deps/$name",
    "3. ../$name",
    "4. stdpath('data')/lazy/$name",
  }) do
    has(sh, place, "test.sh names the place " .. place)
  end
  has(sh, "DEPS=('testing.nvim' 'lib.nvim')", "test.sh resolves the runner and the dependencies")
  has(sh, 'run . "$@"', "test.sh hands every argument to the driver")
  has(sh, "myplug-tests", "the run gets a throwaway NVIM_APPNAME")
  local minit = texts["TESTS/minimal_init.lua"]
  has(minit, "os.exit(1)", "minimal_init fails with exit code 1")
  has(
    minit,
    'local DEPS = { "testing.nvim", "lib.nvim" }',
    "minimal_init resolves the runner and the dependencies"
  )
  for _, place in ipairs({ '"$" .. env_name(name)', "../%s", ".deps/%s", "stdpath('data')/lazy/%s" }) do
    has(minit, place, "minimal_init names the place " .. place)
  end

  -- NEW-39/45/49
  has(texts["stylua.toml"], 'line_endings = "Unix"', "stylua.toml matches .gitattributes")
  has(texts[".gitattributes"], "eol=lf", ".gitattributes pins LF")
  has(texts[".luacheckrc"], "busted", ".luacheckrc declares the busted std")

  -- CI: 3 OS, timeout, IR artifact on failure, both checkouts from ci-verified
  local ci = texts[".github/workflows/ci.yml"]
  for _, needle in ipairs({
    "timeout-minutes:",
    "ubuntu-latest",
    "windows-latest",
    "macos-latest",
    "fail-fast: false",
    "actions/upload-artifact",
    "if: failure()",
    "testing-ir.json",
    "scripts/test.sh --json",
    'repository: "StefanBartl/testing.nvim"',
    "path: .deps/testing.nvim",
    'repository: "StefanBartl/lib.nvim"',
    "path: .deps/lib.nvim",
    "set -o pipefail",
  }) do
    has(ci, needle, "ci.yml has " .. needle)
  end
  local _, n_verified = ci:gsub("ref: ci%-verified", "")
  eq(n_verified, 2, "both dependencies are checked out from ci-verified")

  -- the generated Lua is Lua
  for _, rel in ipairs({
    ".testing.lua",
    "TESTS/minimal_init.lua",
    "TESTS/myplug/load_spec.lua",
    ".luacheckrc",
  }) do
    local chunk, cerr = loadfile(root .. "/" .. rel)
    ok(chunk ~= nil, rel .. " is valid Lua: " .. tostring(cerr))
  end
  -- ... and the project config validates against the schema of testing.config.project
  local loaded = require("testing.config.project").load(root)
  eq(loaded.error, nil, ".testing.lua loads")
  eq(loaded.problems, {}, ".testing.lua has no warning")
  eq(loaded.config.plugin, "myplug", ".testing.lua names the plugin")
  eq(loaded.config.deps, { "lib.nvim" }, ".testing.lua names the dependency")
  if not is_windows then
    local stat = vim.uv.fs_stat(root .. "/scripts/test.sh")
    ok(bit.band(stat.mode, tonumber("100", 8)) ~= 0, "scripts/test.sh is executable")
  end

  -- ---------------------------------------------------------------- no overwrite, force

  vim.fn.writefile({ "-- mine" }, root .. "/.testing.lua")
  local again = scaffold.init(root)
  eq(again.errors, {}, "a second init has no errors")
  eq(again.created, {}, "a second init creates nothing")
  eq(again.replaced, {}, "a second init replaces nothing")
  local skipped = vim.deepcopy(again.skipped)
  table.sort(skipped)
  eq(skipped, expected, "every existing file is reported as skipped")
  eq(slurp(root .. "/.testing.lua"), "-- mine\n", "the user's file is untouched")

  local forced = scaffold.init(root, { force = true })
  eq(forced.errors, {}, "force has no errors")
  eq(forced.skipped, {}, "force skips nothing")
  eq(#forced.replaced, #expected, "force replaces every file")
  eq(slurp(root .. "/.testing.lua"), texts[".testing.lua"], "force restores the template")

  -- a directory where a file belongs: an error for that file, the others are still written
  local blocked = mkproj("blocked.nvim", { "lua/blocked", ".testing.lua" })
  local b = scaffold.init(blocked, { force = true })
  eq(#b.errors, 1, "one error")
  has(b.errors[1], ".testing.lua", "the error names the path")
  eq(#b.created, #expected - 1, "the other files were created")

  -- ---------------------------------------------------------------- hostile input

  local function assert_confined(proj, res, label)
    for _, rel in ipairs(res.created) do
      ok(
        not rel:find("..", 1, true) and rel:sub(1, 1) ~= "/",
        label .. ": created path stays inside: " .. rel
      )
    end
    for _, f in ipairs(list_files(proj)) do
      ok(not f:find("..", 1, true), label .. ": nothing escaped")
    end
  end

  local evil = 'x"\n]]; os.execute("boom") --'
  local p1 = mkproj("evil1.nvim")
  local r1 = scaffold.init(p1, { plugin = evil })
  eq(r1.errors, {}, "a hostile plugin name is sanitized, not refused")
  ok(r1.plugin:match("^[%w_%-]+$") ~= nil, "the used name is plain: " .. r1.plugin)
  assert_confined(p1, r1, "evil name")
  for _, rel in ipairs(r1.created) do
    if rel:match("%.lua$") then
      local chunk, cerr = loadfile(p1 .. "/" .. rel)
      ok(chunk ~= nil, "evil name: " .. rel .. " is still valid Lua: " .. tostring(cerr))
    end
  end
  local cfg = require("testing.config.project").load(p1)
  eq(cfg.error, nil, "evil name: .testing.lua loads")
  eq(cfg.problems, {}, "evil name: .testing.lua validates")
  lacks(slurp(p1 .. "/.testing.lua"), "os.execute", "the payload is not in the config")
  lacks(slurp(p1 .. "/scripts/test.sh"), "os.execute", "the payload is not in the shell script")

  local p2 = mkproj("evil2.nvim")
  local r2 = scaffold.init(p2, { plugin = "../../escape" })
  eq(r2.errors, {}, "a traversal in the name is sanitized")
  assert_confined(p2, r2, "traversal")
  eq(vim.uv.fs_stat(tmp .. "/escape"), nil, "nothing was written next to the project")

  local p3 = mkproj("evil3.nvim")
  local r3 = scaffold.init(p3, { plugin = "..." })
  eq(#r3.errors, 1, "a name without a usable character is an error")
  eq(list_files(p3), {}, "and nothing was created")

  local p4 = mkproj("evil4.nvim")
  for _, bad in ipairs({ { 'x"; echo' }, { "a/b" }, { ".." }, { "" }, "lib.nvim" }) do
    local r = scaffold.init(p4, { deps = bad })
    eq(#r.errors, 1, "invalid deps " .. vim.inspect(bad) .. " is an error")
    eq(list_files(p4), {}, "invalid deps " .. vim.inspect(bad) .. ": nothing was created")
  end
  local ro = scaffold.init(p4, { owner = 'a"b' })
  eq(#ro.errors, 1, "an invalid owner is an error")
  eq(list_files(p4), {}, "an invalid owner: nothing was created")

  -- a hostile directory name (legal on every platform's file system) as the derived name
  local p5 = mkproj("a b;x$y'z")
  local r5 = scaffold.init(p5)
  eq(r5.errors, {}, "a hostile directory name derives a sanitized name")
  ok(r5.plugin:match("^[%w_%-]+$") ~= nil, "the derived name is plain: " .. tostring(r5.plugin))
  has(
    slurp(p5 .. "/scripts/test.sh"),
    r5.plugin .. "-tests",
    "the name reached the script as a plain word"
  )

  -- more dependencies and another owner
  local p6 = mkproj("deps.nvim", { "lua/deps" })
  local r6 = scaffold.init(p6, {
    deps = { "lib.nvim", "runtime-analysis.nvim", "lib.nvim", "testing.nvim" },
    owner = "someone",
  })
  eq(r6.errors, {}, "several dependencies")
  has(
    slurp(p6 .. "/scripts/test.sh"),
    "DEPS=('testing.nvim' 'lib.nvim' 'runtime-analysis.nvim')",
    "deduplicated, runner first"
  )
  has(
    slurp(p6 .. "/.github/workflows/ci.yml"),
    'repository: "someone/runtime-analysis.nvim"',
    "the owner is used"
  )
  eq(
    require("testing.config.project").load(p6).config.deps,
    { "lib.nvim", "runtime-analysis.nvim" },
    "the config lists the dependencies without the runner"
  )

  -- never raises
  eq(#scaffold.init(nil).errors, 1, "no root: an error, no raise")
  eq(#scaffold.init(tmp .. "/does-not-exist").errors, 1, "a missing root: an error, no raise")
  eq(
    #scaffold.init(tmp .. "/myplug.nvim/.testing.lua").errors,
    1,
    "a file as root: an error, no raise"
  )

  -- ---------------------------------------------------------------- the generated minimal_init, run for real

  local function run(argv, cwd, env)
    local full_env = vim.tbl_extend("force", {
      NVIM_APPNAME = "testing-scaffold-spec", -- its stdpath('data') holds no checkout
      LIB_NVIM_DIR = "",
      TESTING_NVIM_DIR = "",
    }, env or {})
    return vim.system(argv, { cwd = cwd, env = full_env, text = true, timeout = 60000 }):wait()
  end
  local nvim = vim.v.progpath
  local res = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root
  )
  eq(res.code, 1, "minimal_init without dependencies exits 1")
  for _, place in ipairs({
    "$TESTING_NVIM_DIR",
    ".deps/testing.nvim",
    "../testing.nvim",
    "stdpath('data')/lazy/testing.nvim",
    "$LIB_NVIM_DIR",
    ".deps/lib.nvim",
    "../lib.nvim",
    "stdpath('data')/lazy/lib.nvim",
  }) do
    has(res.stderr, place, "minimal_init names " .. place)
  end

  local fake = tmp .. "/fake"
  vim.fn.mkdir(fake .. "/lib/lua/lib/nvim", "p")
  vim.fn.mkdir(fake .. "/tst/lua/testing", "p")
  local res_ok = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root,
    { LIB_NVIM_DIR = fake .. "/lib", TESTING_NVIM_DIR = fake .. "/tst" }
  )
  eq(res_ok.code, 0, "minimal_init with every dependency exits 0: " .. tostring(res_ok.stderr))
  local res_bad = run(
    { nvim, "-n", "-i", "NONE", "--headless", "-u", root .. "/TESTS/minimal_init.lua", "+qa" },
    root,
    { LIB_NVIM_DIR = fake .. "/nope", TESTING_NVIM_DIR = fake .. "/tst" }
  )
  eq(res_bad.code, 1, "an override that is set but wrong is never skipped")
  has(res_bad.stderr, "$LIB_NVIM_DIR", "and it is named")

  -- ---------------------------------------------------------------- the generated test.sh, run for real

  local bash
  if is_windows then
    -- PATH's bash may be WSL's, which cannot run this; the one that ships with git is the one CI uses.
    local git = vim.fn.exepath("git")
    local candidate = git ~= ""
        and vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(git))) .. "/bin/bash.exe"
      or ""
    bash = vim.uv.fs_stat(candidate) and candidate or vim.fn.exepath("bash")
  else
    bash = vim.fn.exepath("bash")
  end
  ok(bash ~= "", "bash is available (scripts/test.sh needs it, here and in CI)")
  local path_sep = is_windows and ";" or ":"
  local env_path = { PATH = vim.fs.dirname(nvim) .. path_sep .. (vim.env.PATH or "") }

  local run_proj = mkproj("runme.nvim", { "lua/runme" })
  vim.fn.writefile({ "return {}" }, run_proj .. "/lua/runme/init.lua")
  eq(scaffold.init(run_proj).errors, {}, "init for the real run")

  local missing_res = run({ bash, "scripts/test.sh" }, run_proj, env_path)
  eq(missing_res.code, 1, "test.sh without the runner exits 1, not 0 and not a hang")
  for _, place in ipairs({
    "$TESTING_NVIM_DIR",
    ".deps/testing.nvim",
    "../testing.nvim",
    "stdpath('data')/lazy/testing.nvim",
  }) do
    has(missing_res.stderr, place, "test.sh names " .. place)
  end

  local self_dir = require("testing.deps").self_dir()
  local lib = require("testing.deps").resolve("lib.nvim", self_dir)
  ok(lib ~= nil, "lib.nvim resolves for the real run")
  local deps_env =
    vim.tbl_extend("force", env_path, { TESTING_NVIM_DIR = self_dir, LIB_NVIM_DIR = lib.dir })
  local green = run({ bash, "scripts/test.sh" }, run_proj, deps_env)
  eq(
    green.code,
    0,
    "the generated setup runs green: " .. tostring(green.stdout) .. tostring(green.stderr)
  )
  has(green.stdout, "load_spec.lua", "and it ran the generated spec")

  -- the generated spec can fail: break the module and the verdict changes
  vim.fn.writefile({ 'error("module is broken")' }, run_proj .. "/lua/runme/init.lua")
  local red = run({ bash, "scripts/test.sh" }, run_proj, deps_env)
  eq(red.code, 1, "a broken module makes the generated setup exit 1")
  lacks(red.stdout, "TESTING_OK", "and no green sentinel is printed")

  vim.fn.delete(tmp, "rf")
end
