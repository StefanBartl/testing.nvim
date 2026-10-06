-- TESTS/testing/discover_spec.lua -- spec discovery on temp projects: no depth limit, legacy places and
-- specs under lua/ reported as findings (data, no exception), symlinks reported and never followed,
-- dialects sniffed or overridden, the project runner's order and sentinel kept.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply (their original harness did)
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  -- dialect A has no `has`: a plain substring check on top of H.ok (a tail call keeps the call site)
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(haystack):sub(1, 200) .. ")"
    )
  end
  local discover = require("testing.discover")

  local A_SPEC = 'return function(H)\n  H.eq(1, 1, "x")\nend\n'
  local B_SPEC = 'return function(H)\n  H.scratch("lua")\n  H.eq(1, 1, "x")\nend\n'
  local BUSTED = 'describe("x", function()\n  it("y", function() end)\nend)\n'

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  ---@return string root
  local function project()
    local root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    return root
  end
  ---@param result Testing.Discover.Result
  ---@return string[]
  local function rels(result)
    return vim.tbl_map(function(f)
      return f.rel
    end, result.files)
  end
  ---@param result Testing.Discover.Result
  ---@param kind string
  ---@return Testing.Discover.Finding[]
  local function findings(result, kind)
    return vim.tbl_filter(function(f)
      return f.kind == kind
    end, result.findings)
  end

  local roots = {}

  -- ------------------------------------------------------------------ roots, depth, order, dialects
  local root = project()
  roots[#roots + 1] = root
  write(root .. "/TESTS/b_spec.lua", B_SPEC)
  write(root .. "/TESTS/a_spec.lua", A_SPEC)
  write(root .. "/TESTS/sub/deep/er/er/z_spec.lua", BUSTED)
  write(root .. "/TESTS/helper.lua", "return {}\n")
  write(root .. "/TESTS/notes.md", "# not a spec\n")
  write(root .. "/TESTS/not_a_spec.lua.bak", A_SPEC)
  local found = discover.discover(root)
  eq(
    rels(found),
    { "TESTS/a_spec.lua", "TESTS/b_spec.lua", "TESTS/sub/deep/er/er/z_spec.lua" },
    "specs at any depth (the depth-3 hole of M0 is closed), sorted by relative path, only *_spec.lua"
  )
  eq(
    vim.tbl_map(function(f)
      return f.dialect
    end, found.files),
    { "a", "b", "busted" },
    "the dialect of each file is sniffed"
  )
  eq(#found.findings, 0, "a clean project has no findings")
  eq(found.files[1].origin, "root", "files under TESTS/ are `root` files")
  eq(found.files[1].source, "sniff", "sniffed")
  eq(found.files[1].path, root .. "/TESTS/a_spec.lua", "absolute forward-slash path")
  eq(found.root, root, "the root is echoed")
  eq(rels(discover.discover(root)), rels(found), "discovery is deterministic")

  -- roots given twice, with ./ and a trailing slash: one directory, every file once
  found = discover.discover(root, { roots = { "TESTS", "./TESTS/", "TESTS" } })
  eq(#found.files, 3, "the same directory named three ways is walked once")

  -- ------------------------------------------------------------------ no TESTS, no specs
  local empty = project()
  roots[#roots + 1] = empty
  found = discover.discover(empty)
  eq(#found.files, 0, "an empty project has no files")
  eq(#findings(found, "no_root"), 1, "a missing TESTS/ is a finding")
  eq(
    #findings(found, "no_specs"),
    1,
    "and so is a project without any spec: it must not look green"
  )
  eq(findings(found, "no_specs")[1].severity, "error", "the second one is an error")
  vim.fn.mkdir(empty .. "/TESTS", "p")
  found = discover.discover(empty)
  eq(#findings(found, "no_root"), 0, "TESTS/ exists now")
  eq(#findings(found, "no_specs"), 1, "but it holds no spec")
  found = discover.discover(vim.fs.normalize(vim.fn.tempname()) .. "/does/not/exist")
  eq(#found.files, 0, "a root that does not exist does not raise")
  eq(#findings(found, "no_specs"), 1, "it is reported")

  -- ------------------------------------------------------------------ legacy places and lua/ (NEW-48)
  local legacy = project()
  roots[#roots + 1] = legacy
  write(legacy .. "/TESTS/main_spec.lua", A_SPEC)
  write(legacy .. "/docs/TESTS/old_spec.lua", A_SPEC)
  write(legacy .. "/scripts/ci/script_spec.lua", A_SPEC)
  write(legacy .. "/test/t_spec.lua", A_SPEC)
  write(legacy .. "/scripts/build.lua", "return {}\n")
  write(legacy .. "/lua/plug/shipped_spec.lua", BUSTED)
  write(legacy .. "/lua/plug/data_spec.lua", "return { rows = {} }\n")
  found = discover.discover(legacy)
  eq(rels(found), {
    "TESTS/main_spec.lua",
    "docs/TESTS/old_spec.lua",
    "scripts/ci/script_spec.lua",
    "test/t_spec.lua",
  }, "legacy places are searched and their specs listed")
  eq(found.files[2].origin, "legacy", "and marked as legacy")
  local leg = findings(found, "legacy_location")
  eq(
    #leg,
    3,
    "one NEW-48 finding per legacy place that holds specs (scripts/ without a spec would be none)"
  )
  eq(
    vim.tbl_map(function(f)
      return f.path
    end, leg),
    { "docs/TESTS", "test", "scripts" },
    "naming the place"
  )
  eq(leg[1].rule, "NEW-48", "the rule")
  eq(leg[1].severity, "warn", "a warning, not an error")
  has(leg[1].message, "belong in TESTS/", "and what to do")
  local under = findings(found, "spec_under_lua")
  eq(#under, 2, "both *_spec.lua files below lua/ are reported")
  local by_path = {}
  for _, f in ipairs(under) do
    by_path[f.path] = f
  end
  eq(
    by_path["lua/plug/shipped_spec.lua"].severity,
    "warn",
    "a busted spec below lua/ is a NEW-48 warning"
  )
  eq(
    by_path["lua/plug/data_spec.lua"].severity,
    "info",
    "a file that is only named like a spec is info"
  )
  eq(by_path["lua/plug/shipped_spec.lua"].rule, "NEW-48", "NEW-48")
  ok(
    not vim.tbl_contains(rels(found), "lua/plug/shipped_spec.lua"),
    "specs below lua/ are reported, not run"
  )

  found = discover.discover(legacy, { include_legacy = false })
  eq(rels(found), { "TESTS/main_spec.lua" }, "include_legacy = false lists only the roots")
  eq(#findings(found, "legacy_location"), 3, "and still reports the legacy places")
  found = discover.discover(legacy, { scan_lua_dir = false })
  eq(#findings(found, "spec_under_lua"), 0, "scan_lua_dir = false skips lua/")

  -- a project whose only specs sit in `tests/`: the file system decides whether that is TESTS/ or not
  local only_legacy = project()
  roots[#roots + 1] = only_legacy
  write(only_legacy .. "/tests/q_spec.lua", A_SPEC)
  found = discover.discover(only_legacy)
  if vim.fn.isdirectory(only_legacy .. "/TESTS") == 1 then
    -- a case-insensitive file system: `tests` IS `TESTS`, one directory, nothing legacy about it
    eq(
      rels(found),
      { "TESTS/q_spec.lua" },
      "case-insensitive file system: tests/ is the TESTS/ root"
    )
    eq(#findings(found, "legacy_location"), 0, "no legacy finding for the same directory")
    eq(#findings(found, "no_root"), 0, "and the root exists")
  else
    eq(rels(found), { "tests/q_spec.lua" }, "specs in tests/ are found")
    eq(#findings(found, "legacy_location"), 1, "and reported")
    eq(#findings(found, "no_root"), 1, "TESTS/ itself is missing, which is also said")
  end

  -- ------------------------------------------------------------------ unknown dialects and overrides
  local mixed = project()
  roots[#roots + 1] = mixed
  write(mixed .. "/TESTS/known_spec.lua", A_SPEC)
  write(mixed .. "/TESTS/mystery_spec.lua", "local x = 1\nreturn x\n")
  found = discover.discover(mixed)
  eq(
    rels(found),
    { "TESTS/known_spec.lua", "TESTS/mystery_spec.lua" },
    "an unknown file is still listed"
  )
  eq(found.files[2].dialect, "unknown", "as unknown")
  has(found.files[2].reason, "no known signature", "with the reason")
  local unk = findings(found, "unknown_dialect")
  eq(#unk, 1, "and reported, never guessed")
  eq(unk[1].severity, "error", "as an error")
  eq(unk[1].path, "TESTS/mystery_spec.lua", "naming the file")

  found = discover.discover(mixed, { dialect = "busted" })
  eq(found.files[1].dialect, "busted", "a string override applies to every file")
  eq(found.files[1].source, "override", "and says so")
  eq(#findings(found, "unknown_dialect"), 0, "an overridden file is not unknown")
  found =
    discover.discover(mixed, { dialect = { ["TESTS/mystery_spec.lua"] = "c", ["*"] = "auto" } })
  eq(found.files[1].dialect, "a", "a table override: '*' = auto sniffs the rest")
  eq(found.files[2].dialect, "c", "a table override names a file by its literal relative path")
  found = discover.discover(mixed, { dialect = { ["*"] = "b" } })
  eq(found.files[1].dialect, "b", "'*' covers every file without its own entry")
  found = discover.discover(mixed, { dialect = "auto" })
  eq(found.files[1].dialect, "a", "auto sniffs")
  found = discover.discover(mixed, { dialect = "testing" })
  eq(found.files[1].dialect, "testing", "testing (the native dialect) is a valid override")
  found = discover.discover(mixed, { dialect = "klingon" })
  eq(found.files[1].dialect, "a", "an invalid override falls back to sniffing")
  local bad = findings(found, "bad_override")
  eq(#bad, 2, "and is reported once per file")
  has(bad[1].message, "klingon", "naming the value")

  -- ------------------------------------------------------------------ project harness (dialect h)
  local proj = project()
  roots[#roots + 1] = proj
  write(
    proj .. "/TESTS/harness.lua",
    "return { eq = function() end, ok = function() end, match = function() end }\n"
  )
  write(proj .. "/TESTS/p1_spec.lua", 'return function(H)\n  H.match("a", "a", "x")\nend\n')
  write(proj .. "/TESTS/p2_spec.lua", 'return function(H)\n  H.match("a", "a", "x")\nend\n')
  write(proj .. "/TESTS/p3_spec.lua", A_SPEC)
  found = discover.discover(proj)
  eq(
    vim.tbl_map(function(f)
      return f.dialect
    end, found.files),
    { "h", "h", "a" },
    "helpers of the project's own harness: dialect h; plain specs stay a"
  )
  eq(found.files[1].harness, proj .. "/TESTS/harness.lua", "the harness is named")
  eq(#findings(found, "project_harness"), 1, "one info finding per harness, not per file")
  eq(findings(found, "project_harness")[1].severity, "info", "an info")
  eq(#findings(found, "unknown_dialect"), 0, "such files are not unknown")
  found = discover.discover(proj, { dialect = "h" })
  eq(found.files[3].harness, proj .. "/TESTS/harness.lua", "an `h` override finds the harness too")
  -- the same file without any harness.lua above it stays unknown
  local no_harness = project()
  roots[#roots + 1] = no_harness
  write(no_harness .. "/TESTS/p1_spec.lua", 'return function(H)\n  H.match("a", "a", "x")\nend\n')
  found = discover.discover(no_harness)
  eq(found.files[1].dialect, "unknown", "without a harness.lua the foreign helper is unknown")
  eq(found.files[1].harness, nil, "and no harness is named")

  -- ------------------------------------------------------------------ the project's own runner
  local runner = project()
  roots[#roots + 1] = runner
  write(
    runner .. "/TESTS/run.lua",
    table.concat({
      "-- local old = { 'commented_spec.lua' }",
      "local specs = {",
      '  "c_spec.lua",',
      '  "a_spec.lua", -- trailing comment "x_spec.lua"',
      '  "ghost_spec.lua",',
      '  "c_spec.lua",',
      "}",
      "local more = { 'e_spec', 'd_spec' }",
      'io.stdout:write("\\nRUNNER_TESTS_OK (", #specs, ")\\n")',
    }, "\n")
  )
  for _, name in ipairs({ "a", "b", "c", "d", "e" }) do
    write(runner .. "/TESTS/" .. name .. "_spec.lua", A_SPEC)
  end
  found = discover.discover(runner)
  eq(
    found.runner.listed,
    { "c_spec.lua", "a_spec.lua", "ghost_spec.lua", "e_spec.lua", "d_spec.lua" },
    "the runner's list: comments removed, duplicates once, both spellings, in its order"
  )
  eq(found.runner.sentinel, "RUNNER_TESTS_OK", "its sentinel")
  eq(rels(found), {
    "TESTS/a_spec.lua",
    "TESTS/b_spec.lua",
    "TESTS/c_spec.lua",
    "TESTS/d_spec.lua",
    "TESTS/e_spec.lua",
  }, "discovery itself stays sorted")
  local ordered, notes = discover.order(found)
  eq(
    vim.tbl_map(function(f)
      return f.rel
    end, ordered),
    {
      "TESTS/c_spec.lua",
      "TESTS/a_spec.lua",
      "TESTS/ghost_spec.lua",
      "TESTS/e_spec.lua",
      "TESTS/d_spec.lua",
      "TESTS/b_spec.lua",
    },
    "order(): the runner's list first, then the unlisted specs alphabetically"
  )
  ok(ordered[3].missing, "a listed spec that is not on disk stays in the list as `missing`")
  eq(ordered[3].dialect, "unknown", "with no dialect")
  has(ordered[3].reason, "not on disk", "and a reason")
  has(
    table.concat(notes, "\n"),
    "listed in TESTS/run.lua but not on disk: ghost_spec.lua",
    "a note for it"
  )
  has(
    table.concat(notes, "\n"),
    "on disk but not in TESTS/run.lua (run last): TESTS/b_spec.lua",
    "and one for the unlisted"
  )
  local plain_ordered, plain_notes = discover.order(discover.discover(root))
  eq(#plain_ordered, 3, "no runner list: order() keeps the discovery order")
  eq(#plain_notes, 0, "and has nothing to say")
  eq(
    discover.runner_hints(vim.fs.normalize(vim.fn.tempname())).listed,
    {},
    "no TESTS/run.lua: no hints"
  )

  -- ------------------------------------------------------------------ symlinks (ERR-34)
  local link_root = project()
  roots[#roots + 1] = link_root
  local outside = project()
  roots[#roots + 1] = outside
  write(link_root .. "/TESTS/real_spec.lua", A_SPEC)
  write(outside .. "/hidden_spec.lua", A_SPEC)
  write(outside .. "/target_spec.lua", A_SPEC)
  local uv = vim.uv or vim.loop
  local made_dir, err_dir = uv.fs_symlink(outside, link_root .. "/TESTS/linked", { dir = true })
  local made_file, err_file =
    uv.fs_symlink(outside .. "/target_spec.lua", link_root .. "/TESTS/link_spec.lua")
  local made_broken, err_broken =
    uv.fs_symlink(outside .. "/nope_spec.lua", link_root .. "/TESTS/broken_spec.lua")
  -- not skipped when symlinks cannot be made: the spec fails and says what the environment lacks
  ok(
    made_dir and made_file and made_broken,
    ("this environment must be able to create symlinks (Windows: Developer Mode or an elevated shell): %s %s %s"):format(
      tostring(err_dir),
      tostring(err_file),
      tostring(err_broken)
    )
  )
  found = discover.discover(link_root)
  eq(
    rels(found),
    { "TESTS/link_spec.lua", "TESTS/real_spec.lua" },
    "a symlinked directory is not entered, a symlinked file is listed, a broken link is not"
  )
  local link_file = found.files[1]
  eq(link_file.symlink, true, "the symlinked file is marked")
  local sd = findings(found, "symlink_dir")
  eq(#sd, 1, "the symlinked directory is reported")
  eq(sd[1].path, "TESTS/linked", "by path")
  eq(sd[1].rule, "ERR-34", "under ERR-34")
  has(sd[1].message, "not entered", "saying it was not entered")
  eq(#findings(found, "symlink_file"), 1, "the symlinked file is reported")
  eq(#findings(found, "broken_symlink"), 1, "the broken link is reported")
  eq(findings(found, "broken_symlink")[1].severity, "error", "as an error")

  -- ------------------------------------------------------------------ spec_pattern (filetree-style names)
  local ft = project()
  roots[#roots + 1] = ft
  write(ft .. "/TESTS/units.lua", "print('ok')\nos.exit(0)\n")
  write(ft .. "/TESTS/smoke.lua", "print('ok')\nos.exit(0)\n")
  write(ft .. "/TESTS/harness.lua", "return {}\n")
  write(ft .. "/TESTS/run.lua", "print('run')\n")
  write(ft .. "/TESTS/minimal_init.lua", "return {}\n")
  write(ft .. "/TESTS/sub/menu.lua", "print('ok')\nos.exit(0)\n")
  write(ft .. "/TESTS/real_spec.lua", A_SPEC)
  found = discover.discover(ft)
  eq(rels(found), { "TESTS/real_spec.lua" }, "default pattern: only *_spec.lua")
  found = discover.discover(ft, { spec_pattern = { "^TESTS/[%w_]+%.lua$" } })
  eq(
    rels(found),
    { "TESTS/real_spec.lua", "TESTS/smoke.lua", "TESTS/units.lua" },
    "a pattern lists scripts without the suffix, never harness.lua / run.lua / minimal_init.lua, nothing below sub/"
  )
  eq(
    vim.tbl_map(function(f)
      return f.dialect
    end, found.files),
    { "a", "script", "script" },
    "the scripts are classified `script`, the spec stays a"
  )
  -- run.lua / harness.lua only lose their spec status directly in a spec root: filetree.nvim has a
  -- real spec TESTS/refs/run.lua
  write(ft .. "/TESTS/refs/run.lua", "print('ok')\nos.exit(0)\n")
  found = discover.discover(ft, { spec_pattern = { "^TESTS/refs/" } })
  eq(
    rels(found),
    { "TESTS/refs/run.lua" },
    "a run.lua below a spec root is a spec when a pattern names it"
  )
  found = discover.discover(ft, { spec_pattern = { "run%.lua$" } })
  eq(rels(found), { "TESTS/refs/run.lua" }, "TESTS/run.lua (the old runner) stays out")
  found = discover.discover(ft, { spec_pattern = { "^TESTS/sub/" } })
  eq(
    rels(found),
    { "TESTS/sub/menu.lua" },
    "patterns match the relative path, so a directory works"
  )
  found = discover.discover(ft, { spec_pattern = { "[" } })
  eq(#found.files, 0, "a pattern that is no valid Lua pattern matches nothing and does not raise")
  found = discover.discover(ft, { spec_pattern = { "units%.lua$", "_spec%.lua$" } })
  eq(rels(found), { "TESTS/real_spec.lua", "TESTS/units.lua" }, "several patterns: any matches")
  found = discover.discover(ft, { spec_pattern = {} })
  eq(rels(found), { "TESTS/real_spec.lua" }, "an empty list falls back to the default")
  -- legacy places keep the suffix, so scripts/ with a broad pattern does not list every script
  write(ft .. "/scripts/build.lua", "return {}\n")
  found = discover.discover(ft, { spec_pattern = { "%.lua$" } })
  ok(
    not vim.tbl_contains(rels(found), "scripts/build.lua"),
    "a legacy place is searched for *_spec.lua only"
  )

  -- the same spec under two spellings of its directory (a case-insensitive file system: `tests/` is
  -- `TESTS/`; a root `TESTS/sub` below the legacy `tests/`) is ONE spec, not two (sandbox.nvim ran 2 x 964
  -- cases on Windows with the roots its old plenary call named)
  local dup = project()
  roots[#roots + 1] = dup
  write(dup .. "/TESTS/sub/x_spec.lua", A_SPEC)
  found = discover.discover(dup, { roots = { "TESTS/sub" }, legacy = { "tests", "TESTS" } })
  eq(rels(found), { "TESTS/sub/x_spec.lua" }, "one spec under any spelling of its directory")

  -- ------------------------------------------------------------------ dialect table with globs
  local gl = project()
  roots[#roots + 1] = gl
  for _, rel in ipairs({
    "TESTS/a_spec.lua",
    "TESTS/hover/x_spec.lua",
    "TESTS/hover/deep/y_spec.lua",
    "TESTS/hover/z.lua",
    "TESTS/other/w_spec.lua",
  }) do
    write(gl .. "/" .. rel, A_SPEC)
  end
  local function dialects(result)
    local out = {}
    for _, f in ipairs(result.files) do
      out[f.rel] = f.dialect
    end
    return out
  end
  found = discover.discover(gl, {
    dialect = {
      ["TESTS/hover/**"] = "busted",
      ["TESTS/hover/deep/*_spec.lua"] = "c",
      ["TESTS/a_spec.lua"] = "b",
      ["*"] = "d",
    },
  })
  eq(dialects(found), {
    ["TESTS/a_spec.lua"] = "b",
    ["TESTS/hover/x_spec.lua"] = "busted",
    ["TESTS/hover/deep/y_spec.lua"] = "c",
    ["TESTS/other/w_spec.lua"] = "d",
  }, "literal path > the glob with the most literal characters > ** glob > *")
  found = discover.discover(gl, { dialect = { ["TESTS/*/x_spec.lua"] = "h", ["*"] = "auto" } })
  eq(
    dialects(found)["TESTS/hover/x_spec.lua"],
    "h",
    "* stays within one segment and matches hover/"
  )
  eq(dialects(found)["TESTS/hover/deep/y_spec.lua"], "a", "but not across a second one")
  found = discover.discover(gl, { dialect = { ["TESTS/hov?r/*"] = "busted" } })
  eq(dialects(found)["TESTS/hover/x_spec.lua"], "busted", "? is one character")
  eq(dialects(found)["TESTS/other/w_spec.lua"], "a", "files without a matching key are sniffed")
  -- the matcher itself: whole-string, `*` stays in a segment, `**` crosses, `?` is one non-slash character
  local gm = discover.glob_match
  eq(gm("a.b/*.lua", "a.b/x.lua"), true, "the dot is literal and * matches a name")
  eq(gm("a.b/*.lua", "aXb/x.lua"), false, "the dot is not a wildcard")
  eq(gm("a.b/*.lua", "a.b/d/x.lua"), false, "* does not cross a slash")
  eq(gm("**", "any/thing/at/all.lua"), true, "** is anything")
  eq(gm("TESTS/**/x_spec.lua", "TESTS/a/b/x_spec.lua"), true, "** crosses segments")
  eq(gm("TESTS/*/x_spec.lua", "TESTS/a/b/x_spec.lua"), false, "* does not")
  eq(gm("TESTS/hov?r/*", "TESTS/hov/x"), false, "? is exactly one character")
  eq(gm("TESTS/hov?r/*", "TESTS/hov//x"), false, "and never a slash")
  eq(gm("a*", "a"), true, "* may be empty")
  eq(gm("a*b", "acb/b"), false, "the whole string must match")
  eq(gm("100%*", "100%x"), true, "Lua magic characters are literal")
  -- SEC-30/32: a hostile key must not make the matcher backtrack (the Lua-pattern translation of this
  -- key did not return within a minute); the matcher returns at once
  local hostile = string.rep("**a", 12) .. "**b"
  local t0 = vim.uv.hrtime()
  eq(gm(hostile, string.rep("a", 40)), false, "a key of repeated ** does not match")
  eq(gm(hostile, string.rep("a", 40) .. "b"), true, "and matches when it should")
  local took = (vim.uv.hrtime() - t0) / 1e6
  ok(took < 500, "the hostile glob is matched in " .. math.floor(took) .. " ms (< 500)")
  local viaconfig = discover.discover(gl, { dialect = { [hostile] = "busted", ["*"] = "a" } })
  eq(
    dialects(viaconfig)["TESTS/a_spec.lua"],
    "a",
    "discovery with the hostile key returns and falls back to *"
  )
  found = discover.discover(gl, { dialect = "script" })
  eq(dialects(found)["TESTS/a_spec.lua"], "script", "script is a valid override")

  -- ------------------------------------------------------------------ project harness choice (dialect h)
  -- the fixture harnesses carry what the real ones of the fleet carry
  local STRICT = table.concat({
    "local H = {}",
    "function H.eq(a, b, msg)",
    '  if a ~= b then error("FAIL " .. msg, 2) end',
    "end",
    "function H.ok(v, msg)",
    '  if not v then error("FAIL " .. msg, 2) end',
    "end",
    "function H.scratch(ft)",
    "  return 1",
    "end",
    "function H.write_file(path, lines)",
    "end",
    "return H",
  }, "\n")
  local function with_harness(text, specs)
    local dir = project()
    roots[#roots + 1] = dir
    write(dir .. "/TESTS/harness.lua", text)
    for name, body in pairs(specs) do
      write(dir .. "/TESTS/" .. name, body)
    end
    return dir
  end
  local ph = with_harness(STRICT, {
    ["only_eq_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "x")\n  H.ok(true, "y")\nend\n',
    ["scratch_spec.lua"] = 'return function(H)\n  H.scratch("lua")\n  H.eq(1, 1, "x")\nend\n',
  })
  found = discover.discover(ph)
  eq(
    dialects(found),
    { ["TESTS/only_eq_spec.lua"] = "a", ["TESTS/scratch_spec.lua"] = "b" },
    "a harness with the shims' signatures and a strict eq: the shims run the files"
  )
  eq(#findings(found, "project_harness"), 0, "and nothing is reported")
  has(
    table.concat(found.files[2].evidence, "\n"),
    "equivalent to the dialect-b shim",
    "the evidence says why"
  )

  local DEEP = STRICT:gsub("if a ~= b then", "if not vim.deep_equal(a, b) then")
  ph = with_harness(DEEP, {
    ["only_eq_spec.lua"] = 'return function(H)\n  H.eq({}, {}, "x")\nend\n',
    ["only_ok_spec.lua"] = 'return function(H)\n  H.ok(true, "x")\nend\n',
  })
  found = discover.discover(ph)
  eq(
    dialects(found),
    { ["TESTS/only_eq_spec.lua"] = "h", ["TESTS/only_ok_spec.lua"] = "a" },
    "a deep eq: a file that uses eq runs on the project's harness, one that only uses ok does not need to"
  )
  eq(found.files[1].sniffed, "a", "what the sniffer said is kept")
  eq(found.files[1].harness, ph .. "/TESTS/harness.lua", "and the harness is named")
  eq(#findings(found, "project_harness"), 1, "one finding per harness")
  has(findings(found, "project_harness")[1].message, "deep comparison", "naming the reason")

  local OTHER_SIGNATURE =
    STRICT:gsub("function H.write_file%(path, lines%)", "function H.write_file(path, content)")
  ph = with_harness(OTHER_SIGNATURE, {
    ["w_spec.lua"] = 'return function(H)\n  H.write_file("p", { "a" })\n  H.eq(1, 1, "x")\nend\n',
  })
  found = discover.discover(ph)
  eq(
    found.files[1].dialect,
    "h",
    "write_file(path, content) is not the shim's write_file(path, lines): h"
  )
  has(findings(found, "project_harness")[1].message, "write_file", "and the helper is named")

  ph = with_harness(STRICT, {
    ["esc_spec.lua"] = 'return function(H)\n  local function helper(h) h.eq(1, 1, "x") end\n  helper(H)\nend\n',
  })
  found = discover.discover(ph)
  eq(found.files[1].dialect, "h", "an H that is handed on cannot be proven: h")

  ph = with_harness(STRICT, {
    ["tmpfile_spec.lua"] = 'return function(H)\n  H.eq(H.tmpfile(".x") ~= nil, true, "x")\nend\n',
  })
  found = discover.discover(ph)
  eq(
    found.files[1].dialect,
    "a",
    "a helper the project harness lacks but the shim has: the shim keeps the file"
  )
  has(
    table.concat(found.files[1].evidence, "\n"),
    "defines no `tmpfile`",
    "and the evidence says so"
  )

  -- an explicit dialect is never second-guessed
  ph = with_harness(DEEP, {
    ["only_eq_spec.lua"] = 'return function(H)\n  H.eq({}, {}, "x")\nend\n',
  })
  found = discover.discover(ph, { dialect = "a" })
  eq(found.files[1].dialect, "a", "an override to a stays a")
  eq(found.files[1].source, "override", "and says so")
  found = discover.discover(ph, { dialect = "h" })
  eq(found.files[1].dialect, "h", "an override to h is h")
  eq(found.files[1].harness, ph .. "/TESTS/harness.lua", "with the harness found")

  -- a harness whose functions cannot be read from its text has no `eq` to compare: the shim keeps the file
  ph = with_harness("return { eq = function() end, ok = function() end }\n", {
    ["x_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "x")\nend\n',
  })
  found = discover.discover(ph)
  eq(found.files[1].dialect, "a", "an unparsable harness: the shim keeps the file")

  -- ------------------------------------------------------------------ sentinel of the project's runner
  ---@param code string
  ---@return string|nil
  local function sentinel(code)
    return discover.find_sentinel(require("testing.discover.lua_text").strip_comments(code))
  end
  eq(sentinel('print("\\nLIB_TESTS_OK")'), "LIB_TESTS_OK", "double quotes with a leading newline")
  eq(sentinel("print('\\nCOLOR_MY_ASCII_TESTS_OK')"), "COLOR_MY_ASCII_TESTS_OK", "single quotes")
  eq(sentinel('  print("EMOJIS_TESTS_OK")'), "EMOJIS_TESTS_OK", "print without a newline")
  eq(
    sentinel('say(("\\nTASKS_TESTS_OK (%d spec(s))"):format(ran))'),
    "TASKS_TESTS_OK",
    "say() with a suffix"
  )
  eq(
    sentinel('io.stdout:write("\\nRUNNER_TESTS_OK (", n, ")\\n")'),
    "RUNNER_TESTS_OK",
    "io.stdout:write"
  )
  eq(sentinel("print([[\nLONG_OK\n]])"), "LONG_OK", "a long string")
  eq(sentinel('print("DONE_OK")'), "DONE_OK", "a short XXX_OK token")
  eq(sentinel('print("TESTS_OK")'), "TESTS_OK", "TESTS_OK alone")
  eq(sentinel('print("OK")'), nil, "OK alone is no sentinel")
  eq(sentinel('print("not_OK") print("Mixed_OK")'), nil, "lower-case words are no sentinel")
  eq(
    sentinel("-- print('OLD_TESTS_OK')\nprint('NEW_TESTS_OK')"),
    "NEW_TESTS_OK",
    "a commented sentinel is ignored"
  )
  eq(
    sentinel('local ok = "FIRST_OK"\nprint("\\nREAL_TESTS_OK")\nlocal x = "LATER_OK"'),
    "REAL_TESTS_OK",
    "a token on a printing line wins over other tokens"
  )
  eq(
    sentinel('local OK_TOKEN = "ONLY_OK"\nreturn OK_TOKEN'),
    "ONLY_OK",
    "without a printing line the last token is taken"
  )
  eq(sentinel("print('FAILED_NOT')"), nil, "no token, no sentinel")
  eq(sentinel('print("A_OK_B")'), nil, "the token must end at _OK")
  local sr = project()
  roots[#roots + 1] = sr
  write(sr .. "/TESTS/run.lua", "print('\\nSINGLE_TESTS_OK')\n")
  write(sr .. "/TESTS/x_spec.lua", A_SPEC)
  eq(
    discover.discover(sr).runner.sentinel,
    "SINGLE_TESTS_OK",
    "runner_hints finds the single-quoted form"
  )

  for _, dir in ipairs(roots) do
    vim.fn.delete(dir, "rf")
  end
end
