-- TESTS/testing/dialect_sniff_spec.lua -- dialect detection by signature sniffing: every dialect,
-- the unknown outcomes (reported with a reason, never guessed), overrides, comments and strings that
-- must not count as evidence; and the comment/string scanner underneath.

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
  local sniff = require("testing.discover.sniff")
  local lua_text = require("testing.discover.lua_text")

  -- ------------------------------------------------------------------ lua_text.code_only
  local src = table.concat({
    "local a = 'x' -- trailing comment",
    '--[[ block "comment" ]] local b = "describe(\\"q\\")"',
    "--[==[ long\ncomment ]==] local c = [[long\nstring]]",
    "return a",
  }, "\n")
  local code = lua_text.code_only(src)
  eq(#code, #src, "the scanned text keeps its length (offsets stay valid)")
  eq(select(2, code:gsub("\n", "\n")), select(2, src:gsub("\n", "\n")), "and its line structure")
  eq(code:find("trailing", 1, true), nil, "line comments are blanked")
  eq(code:find("block", 1, true), nil, "block comments are blanked")
  eq(code:find("long", 1, true), nil, "long comments and long strings are blanked")
  eq(code:find("describe", 1, true), nil, "string contents are blanked")
  has(code, "local a = '", "the delimiters of a string stay")
  has(code, "return a", "code stays")
  local unclosed = lua_text.code_only("local s = 'never closed\nreturn 1")
  has(unclosed, "return 1", "an unclosed string ends at the line end, the next line is code")
  eq(
    lua_text.strip_comments("x = 1 -- gone\ny = '-- kept'"),
    "x = 1  \ny = '-- kept'",
    "strip_comments keeps strings"
  )

  -- ------------------------------------------------------------------ the dialects
  local CASES = {
    -- label, text, dialect
    {
      "a: lib.nvim helpers",
      'return function(H)\n  local p = H.tmpfile(".x")\n  H.eq(#H.read_lines(p), 0, "m")\nend\n',
      "a",
    },
    {
      "a: with_patched",
      "return function(H)\n  H.with_patched(t, 'k', 1, function() end)\nend\n",
      "a",
    },
    {
      "a: only eq/ok (identical in a, b, c)",
      'return function(H)\n  H.eq(1, 1, "x")\n  H.ok(true, "y")\nend\n',
      "a",
    },
    { "a: another parameter name", 'return function(h)\n  h.eq(1, 1, "x")\nend\n', "a" },
    { "b: scratch(ft)", 'return function(H)\n  H.scratch("lua")\n  H.eq(1, 1, "x")\nend\n', "b" },
    { "b: tmproot", 'return function(H)\n  local r = H.tmproot("x")\n  H.ok(r, "x")\nend\n', "b" },
    { "b: tmpdir()", 'return function(H)\n  local d = H.tmpdir()\n  H.ok(d, "x")\nend\n', "b" },
    {
      "b: canonical and write_file",
      'return function(H)\n  H.write_file(H.canonical("x"), {})\nend\n',
      "b",
    },
    { "c: falsy", 'return function(H)\n  H.falsy(nil, "x")\nend\n', "c" },
    { "c: contains", 'return function(H)\n  H.contains("abc", "b", "x")\nend\n', "c" },
    { "c: scratch(lines, ft)", 'return function(H)\n  H.scratch({ "a" }, "lua")\nend\n', "c" },
    { "c: tmpdir(fn)", 'return function(H)\n  H.tmpdir(function(d) H.ok(d, "x") end)\nend\n', "c" },
    { "c: write", 'return function(H)\n  H.write("p", "c")\nend\n', "c" },
    {
      "d: M.run with require harness",
      'local t = require("harness")\nlocal M = {}\nfunction M.run()\n  t.ok("x", true)\nend\nreturn M\n',
      "d",
    },
    {
      "d: single quotes and run = function",
      "local t = require('harness')\nlocal M = {}\nM.run = function() end\nreturn M\n",
      "d",
    },
    {
      "busted: describe/it",
      'describe("x", function()\n  it("y", function() end)\nend)\n',
      "busted",
    },
    {
      "busted: a nested return function(msg) is not a harness spec",
      'local function make()\n  return function(msg) return msg end\nend\ndescribe("x", function()\n  it("y", function() end)\nend)\n',
      "busted",
    },
    { "busted: indented it only", '  it("y", function() end)\n', "busted" },
    { "busted: context", 'context("x", function() end)\n', "busted" },
  }
  for _, row in ipairs(CASES) do
    local verdict = sniff.sniff(row[2])
    eq(verdict.dialect, row[3], row[1])
    eq(verdict.source, "sniff", row[1] .. ": source is sniff")
    ok(#verdict.evidence > 0, row[1] .. ": the evidence is reported")
  end

  -- ------------------------------------------------------------------ unknown is reported, never guessed
  local unknown = sniff.sniff("local x = 1\nreturn x\n")
  eq(unknown.dialect, "unknown", "nothing matches: unknown")
  has(unknown.reason, "no known signature", "with the reason")

  unknown = sniff.sniff('return function(H)\n  H.match("a", "a", "x")\nend\n')
  eq(unknown.dialect, "unknown", "a helper no fixed harness has: unknown")
  eq(unknown.foreign_keys, { "match" }, "the foreign keys are listed")
  eq(unknown.h_style, true, "and flagged as an H-style spec (a project harness can run it)")
  has(unknown.reason, "H.match", "the reason names the key")

  unknown = sniff.sniff('return function(H)\n  H.tmpfile()\n  H.falsy(1, "x")\nend\n')
  eq(unknown.dialect, "unknown", "helpers of a and c mixed: unknown")
  has(unknown.reason, "mixed", "the reason says mixed")
  eq(unknown.h_style, true, "mixed helpers are H-style too")

  unknown = sniff.sniff('return function(H)\n  H.tmpdir()\n  H.contains("a", "a", "x")\nend\n')
  eq(unknown.dialect, "unknown", "helpers of b and c mixed: unknown")

  unknown =
    sniff.sniff('describe("x", function() end)\nreturn function(H)\n  H.eq(1, 1, "x")\nend\n')
  eq(unknown.dialect, "unknown", "describe AND a top-level return function(H): unknown")
  has(unknown.reason, "cannot tell busted", "with the reason")

  unknown = sniff.sniff('local t = require("harness")\nreturn {}\n')
  eq(unknown.dialect, "unknown", "a harness require without run(): unknown")
  has(unknown.reason, "run", "the reason names run")

  -- ------------------------------------------------------------------ comments and strings are no evidence
  eq(
    sniff.sniff('-- describe("x", function() end)\nlocal x = "it(\\"y\\")"\nreturn x\n').dialect,
    "unknown",
    "a commented-out describe and a string that mentions it( are not busted"
  )
  eq(
    sniff.sniff(
      'return function(H)\n  -- H.falsy(1, "x")\n  local s = "H.contains"\n  H.eq(1, 1, "x")\nend\n'
    ).dialect,
    "a",
    "helpers named in a comment or a string do not make the file dialect c"
  )
  eq(
    sniff.sniff('--[[\nreturn function(H) end\n]]\ndescribe("x", function() end)\n').dialect,
    "busted",
    "a commented-out harness entry point does not conflict with busted"
  )

  -- ------------------------------------------------------------------ overrides
  local over = sniff.resolve('return function(H)\n  H.eq(1, 1, "x")\nend\n', "c")
  eq(over.dialect, "c", "an override wins")
  eq(over.source, "override", "and says it is one")
  has(over.evidence[1], "sniffed: a", "the report keeps what sniffing would have said")
  over = sniff.resolve('return function(H)\n  H.eq(1, 1, "x")\nend\n', "h")
  eq(over.dialect, "h", "h is a valid override")
  over = sniff.resolve('return function(H)\n  H.eq(1, 1, "x")\nend\n', "nonsense")
  eq(over.dialect, "a", "a name that is no dialect is ignored here (discover reports it)")
  eq(over.source, "sniff", "and the answer comes from sniffing")
  eq(sniff.is_dialect("busted"), true, "is_dialect: busted")
  eq(sniff.is_dialect("auto"), false, "is_dialect: auto is not a dialect")
  eq(sniff.is_dialect(nil), false, "is_dialect: nil")

  -- ------------------------------------------------------------------ the real fixtures
  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local FIXTURES = {
    { "a_fail.fixture.lua", "a" },
    { "b_fail.fixture.lua", "b" },
    { "c_fail.fixture.lua", "c" },
    { "d/d_fail.fixture.lua", "d" },
    { "busted_mixed.fixture.lua", "busted" },
    { "busted_hooks.fixture.lua", "busted" },
    { "busted_unsupported.fixture.lua", "busted" },
    { "busted_globals.fixture.lua", "busted" },
  }
  for _, row in ipairs(FIXTURES) do
    local text = table.concat(vim.fn.readfile(here .. "/fixtures/" .. row[1]), "\n")
    eq(sniff.sniff(text).dialect, row[2], "fixture " .. row[1])
  end
  local h_text = table.concat(vim.fn.readfile(here .. "/fixtures/h/h_fail.fixture.lua"), "\n")
  eq(
    sniff.sniff(h_text).dialect,
    "unknown",
    "fixture h_fail: its helpers belong to a project harness"
  )
  eq(sniff.sniff(h_text).h_style, true, "and it says so")
  -- ------------------------------------------------------------------ call forms, scripts, escapes (round 2)
  local function d_of(text)
    return sniff.sniff(text)
  end
  local function spec(body)
    return "return function(H)\n" .. body .. "\nend\n"
  end

  -- scratch/tmpdir: the form of the call decides, a b/c key never falls to `a`
  eq(d_of(spec('H.scratch("lua")')).dialect, "b", "scratch(ft) is dialect b")
  eq(d_of(spec("H.scratch({ 'x' })")).dialect, "c", "scratch(lines) is dialect c")
  eq(d_of(spec("H.scratch({ 'x' }, 'lua')")).dialect, "c", "scratch(lines, ft) is dialect c")
  eq(
    d_of(spec("H.scratch()")).dialect,
    "b",
    "scratch() tells nothing: both shims accept it, b is taken"
  )
  eq(d_of(spec("H.scratch(lines)")).dialect, "b", "scratch(variable) tells nothing either")
  eq(d_of(spec("H.tmpdir()")).dialect, "b", "tmpdir() is dialect b")
  eq(d_of(spec("H.tmpdir(function(dir) end)")).dialect, "c", "tmpdir(fn) is dialect c")
  eq(
    d_of(spec('H.scratch("lua")\n  H.tmpdir(function(dir) end)')).dialect,
    "unknown",
    "scratch(ft) with tmpdir(fn) mixes b and c"
  )
  local project_form = d_of(spec('H.scratch("lua", { "a" })'))
  eq(
    project_form.dialect,
    "unknown",
    "scratch(ft, lines) is the project's own form: no shim has it"
  )
  eq(project_form.h_style, true, "a project harness may run it")
  eq(project_form.forms, { "scratch(ft, lines)" }, "and the form is named")
  has(project_form.reason, "none of the fixed harness shims", "with the reason")
  eq(
    d_of(spec("H.scratch(nil, { 'a' })")).dialect,
    "unknown",
    "scratch(nil, lines) is the project form"
  )
  eq(
    d_of(spec("H.scratch(ft, lines)")).dialect,
    "unknown",
    "scratch(var, var) is ambiguous: unknown"
  )
  eq(
    d_of(spec('H.scratch("lua")\n  H.scratch("lua", { "a" })')).dialect,
    "unknown",
    "one project-form call makes the whole file unknown"
  )
  eq(
    d_of(spec('H.tmpfile(".x")\n  H.scratch("lua")')).dialect,
    "unknown",
    "a-only helpers with scratch: mixed, never `a`"
  )
  -- a call with nested parentheses and a comma inside a string
  eq(
    d_of(spec('H.scratch(vim.split("a,b", ","))')).dialect,
    "b",
    "commas inside nested calls and strings are not argument separators"
  )

  -- the harness parameter handed on or indexed: the key list is incomplete
  eq(d_of(spec("H.eq(1, 1, 'x')")).escapes, false, "only H.<key> uses: nothing escapes")
  eq(d_of(spec("helper(H)")).escapes, true, "H passed on escapes")
  eq(d_of(spec("local f = H[name]")).escapes, true, "H indexed dynamically escapes")
  eq(d_of(spec("local alias = H\n  alias.eq(1, 1)")).escapes, true, "an alias of H escapes")
  eq(d_of(spec("local eq = H.eq\n  eq(1, 1)")).escapes, false, "an alias of a key does not")

  -- script: no framework, but the file ends the process itself
  local script = d_of("local passed = 0\nprint('ok')\nos.exit(passed == 0 and 1 or 0)\n")
  eq(script.dialect, "script", "os.exit at the top level: a self-running script")
  has(script.evidence[1], "self-running script", "with its evidence")
  eq(d_of("print('x')\nvim.cmd('cquit 1')\n").dialect, "script", "a cquit command is the same")
  eq(
    d_of("-- os.exit(1)\nlocal s = 'os.exit(1)'\nreturn s\n").dialect,
    "unknown",
    "in a comment or a string it is no evidence"
  )
  eq(d_of("local x = 1\nreturn x\n").dialect, "unknown", "no evidence at all stays unknown")
  eq(
    d_of('describe("x", function() os.exit(1) end)\n').dialect,
    "busted",
    "busted wins over a script"
  )
  eq(
    d_of(spec("os.exit(1)")).dialect,
    "a",
    "a harness spec that happens to exit is still a harness spec"
  )
  eq(sniff.is_dialect("script"), true, "script is a dialect name")
  eq(sniff.resolve("local x = 1\n", "script").dialect, "script", "an override can name it")
  eq(sniff.resolve("local x = 1\n", "h").dialect, "h", "and h")

  -- lua_text.strings
  local strs = lua_text.strings("a = 'one' -- 'no'\nb = [[two]] c = \"th\\\"ree\" --[[ 'no' ]]")
  eq(
    vim.tbl_map(function(s)
      return s.content
    end, strs),
    { "one", "two", 'th\\"ree' },
    "strings(): quoted and long strings, comments skipped, escapes left raw"
  )
end
