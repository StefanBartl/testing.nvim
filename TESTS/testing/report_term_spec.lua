-- TESTS/testing/report_term_spec.lua -- testing.report.term: file lines, failure details, diff,
-- diff bound, width, colour decision, durations, seed, summary, hostile text, determinism.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has_line(lines, needle, msg)
    for _, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return ok(true, msg)
      end
    end
    return ok(
      false,
      ("%s: no line contains %q in:\n%s"):format(msg, needle, table.concat(lines, "\n"))
    )
  end
  local function has_no_line(lines, needle, msg)
    for _, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return ok(false, ("%s: line %q contains %q"):format(msg, l, needle))
      end
    end
    return ok(true, msg)
  end
  local function index_of(lines, needle)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return i
      end
    end
    return nil
  end

  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local term = require("testing.report.term")
  local width = require("lib.lua.strings.width")
  local result = require("testing.core.result")

  local lines = term.render(F.mixed())

  -- transitional file lines -----------------------------------------------------------------------
  eq(lines[1], "ok    TESTS/a_spec.lua", "a green file prints in the transitional shape")
  has_line(lines, "FAIL  TESTS/b_spec.lua", "a failing file prints FAIL")
  has_line(lines, "FAIL  TESTS/c_spec.lua", "an erroring file prints FAIL")
  has_line(lines, "skip  TESTS/d_spec.lua", "a file with only skipped cases is not ok")
  has_no_line(lines, "ok    TESTS/d_spec.lua", "skip is never green")
  has_line(lines, "FAIL  TESTS/f_spec.lua", "xpass fails its file")
  has_line(lines, "FAIL  TESTS/g_spec.lua", "timeout and crash fail their file")
  has_line(lines, "5 spec(s) failed", "failed files are counted")

  -- failure details -------------------------------------------------------------------------------
  has_line(lines, "TESTS/b_spec.lua:12  values differ", "failed assertion with file:line")
  has_line(lines, "expected:", "one-line expected label")
  has_line(lines, "actual:", "one-line actual label")
  has_line(lines, "error: boom", "error message")
  has_line(lines, "c_spec.lua:2: in main chunk", "traceback is shown")
  has_line(lines, "skipped: needs network", "skip reason")
  has_line(lines, "unexpectedly passed", "xpass explained")
  has_line(lines, "timeout: case exceeded 5000 ms", "timeout explained")
  has_line(lines, "crash: child exited with code 139", "crash explained")
  has_line(lines, "fail  group::multi:8", "multi-case file names its failing case")
  has_no_line(lines, "group::green", "a passing case of a multi-case file is not listed")

  -- diff --------------------------------------------------------------------------------------------
  has_line(lines, "diff (- expected, + actual):", "multi-line values get a diff")
  has_line(lines, "- four", "diff shows the expected line removed")
  has_line(lines, "+ FOUR", "diff shows the actual line added")
  has_line(lines, "  three", "diff shows context")
  has_line(lines, "@@ 1 unchanged line(s)", "diff folds far unchanged lines")

  -- diff against a fixed expectation (exact text)
  local dl = term.diff_lines("a\nb\nc\nd\ne\nf\ng\nh", "a\nb\nc\nX\ne\nf\ng\nh", {}, function(_, s)
    return s
  end)
  eq(dl, {
    "  @@ 1 unchanged line(s)",
    "  b",
    "  c",
    "- d",
    "+ X",
    "  e",
    "  f",
    "  @@ 2 unchanged line(s)",
  }, "diff text with context 2")

  -- diff bound (SEC-32) -------------------------------------------------------------------------------
  local big_a, big_b = {}, {}
  for i = 1, 400 do
    big_a[i] = "a" .. i
    big_b[i] = "b" .. i
  end
  local t0 = vim.uv.hrtime()
  local nodiff, note = term.diff_lines(
    table.concat(big_a, "\n"),
    table.concat(big_b, "\n"),
    { diff_max_cells = 40000 },
    function(_, s)
      return s
    end
  )
  local ms = (vim.uv.hrtime() - t0) / 1e6
  ok(nodiff == nil, "400 x 400 changed lines exceed 40000 cells: no diff")
  ok(note and note:find("exceed the limit of 40000", 1, true), "the note names the limit")
  ok(ms < 500, "refusing is cheap, not a DP run (" .. ms .. " ms)")
  -- equal head and tail are trimmed before the bound applies
  local long_a, long_b = {}, {}
  for i = 1, 5000 do
    long_a[i] = "line " .. i
    long_b[i] = "line " .. i
  end
  long_b[2500] = "CHANGED"
  local trimmed = term.diff_lines(
    table.concat(long_a, "\n"),
    table.concat(long_b, "\n"),
    {},
    function(_, s)
      return s
    end
  )
  ok(trimmed ~= nil, "5000 lines with one change still diff (head/tail trimmed)")
  has_line(trimmed or {}, "- line 2500", "trimmed diff shows the change")
  has_line(trimmed or {}, "+ CHANGED", "trimmed diff shows the replacement")

  local bigr = result.new({ id = "2026-10-05T10:00:00Z-0004" })
  F.add(bigr, {
    file = "TESTS/big_spec.lua",
    name = "huge",
    assertions = {
      {
        ok = false,
        kind = "eq",
        msg = "huge values",
        expected = table.concat(big_a, "\n"),
        actual = table.concat(big_b, "\n"),
      },
    },
  })
  local biglines = term.render(bigr, { max_value_lines = 3, diff_max_cells = 100 })
  has_line(
    biglines,
    "diff skipped: 400 x 400 changed lines exceed the limit of 100 cells",
    "render degrades"
  )
  has_line(biglines, "expected:", "plain expected after the degrade")
  has_line(biglines, "... 397 more line(s)", "plain print is bounded too")
  ok(#biglines < 40, "degraded output stays small (" .. #biglines .. " lines)")

  -- width ---------------------------------------------------------------------------------------------
  local wide = result.new({ id = "2026-10-05T10:00:00Z-0005" })
  F.add(wide, {
    file = "TESTS/" .. ("日本語"):rep(30) .. "_spec.lua",
    name = "wide",
    assertions = {
      {
        ok = false,
        kind = "eq",
        msg = ("メッセージ😀"):rep(20),
        expected = ("x"):rep(300),
        actual = ("x"):rep(150) .. "y" .. ("x"):rep(149),
      },
    },
  })
  local wlines = term.render(wide, { width = 60 })
  for _, l in ipairs(wlines) do
    ok(
      width.display_width(l) <= 60,
      ("line fits 60 columns (%d): %s"):format(width.display_width(l), l)
    )
  end
  has_line(wlines, "...", "truncation is visible")
  has_line(wlines, "first difference at byte 151", "long one-line values name the first difference")

  -- hostile text ---------------------------------------------------------------------------------------
  local hostile = term.render(F.hostile())
  for _, l in ipairs(hostile) do
    ok(not l:find("\27", 1, true), "no raw ESC in plain output: " .. vim.inspect(l))
    ok(not l:find("[%z\1-\8\11-\31\127]"), "no control character in a line: " .. vim.inspect(l))
    ok(not l:find("\226\128\174", 1, true), "bidi override is escaped")
    ok(not l:find("\n", 1, true), "no line holds a newline")
    ok(not l:find("^::"), "no line starts like a workflow command")
  end
  has_line(hostile, "\\x1B", "ESC is made visible")
  has_line(hostile, "\\x00", "NUL is made visible")
  has_line(hostile, "\\u{202E}", "bidi override is made visible")
  has_line(hostile, "\239\191\189", "invalid UTF-8 became U+FFFD")
  has_line(
    hostile,
    "::error title=owned::pwned",
    "a workflow command in a message stays inert text"
  )
  ok(
    vim.fn.strdisplaywidth(table.concat(hostile, "\n")) >= 0,
    "output is valid UTF-8 for the editor"
  )

  -- colour ----------------------------------------------------------------------------------------------
  for _, l in ipairs(lines) do
    ok(not l:find("\27", 1, true), "colour is off by default")
  end
  local colored = term.render(F.mixed(), { color = true })
  has_line(colored, "\27[31mFAIL\27[0m", "FAIL is red when colour is on")
  has_line(colored, "\27[32mok\27[0m", "ok is green when colour is on")
  has_line(colored, "\27[33mskip\27[0m", "skip is yellow, never green")
  local hostile_color = table.concat(term.render(F.hostile(), { color = true }), "\n")
  local without_sgr = hostile_color:gsub("\27%[%d+m", "")
  ok(not without_sgr:find("\27", 1, true), "only the reporter's own SGR sequences carry an ESC")
  eq(term.use_color({ color = true, env = { NO_COLOR = "1" } }), true, "explicit colour wins")
  eq(term.use_color({ color = false, is_tty = true }), false, "explicit no-colour wins")
  eq(term.use_color({ is_tty = true, env = {} }), true, "TTY colours")
  eq(term.use_color({ is_tty = false, env = {} }), false, "a pipe does not")
  eq(
    term.use_color({ is_tty = true, env = { NO_COLOR = "1" } }),
    false,
    "NO_COLOR disables on a TTY"
  )
  eq(term.use_color({ is_tty = false, env = { FORCE_COLOR = "1" } }), true, "FORCE_COLOR forces")
  eq(
    term.use_color({ is_tty = false, env = { FORCE_COLOR = "0" } }),
    false,
    "FORCE_COLOR=0 does not"
  )
  eq(
    term.use_color({ is_tty = true, env = { NO_COLOR = "" } }),
    true,
    "an empty NO_COLOR is ignored"
  )
  eq(
    term.use_color({ is_tty = false, env = { NO_COLOR = "1", FORCE_COLOR = "1" } }),
    false,
    "NO_COLOR beats FORCE_COLOR"
  )

  -- durations ---------------------------------------------------------------------------------------------
  local dur = term.render(F.mixed(), { durations = 3 })
  has_line(dur, "slowest 3:", "durations header")
  local g, m, e =
    index_of(dur, "g_spec.lua::hangs"),
    index_of(dur, "e_spec.lua::group::multi"),
    index_of(dur, "b_spec.lua::compares")
  ok(g and m and e and g < m and m < e, "slowest first: 5000 ms, 300 ms, 40 ms")
  ok(not index_of(dur, "a_spec.lua::adds"), "only N entries are listed")
  has_no_line(lines, "slowest", "no durations block unless asked")

  -- seed and summary -----------------------------------------------------------------------------------------
  has_line(
    lines,
    "seed: 4242  (reproduce: --shuffle --seed 4242)",
    "seed line with a reproduction hint on failure"
  )
  local green = term.render(F.green())
  has_no_line(green, "seed:", "no seed line without a seed")
  has_no_line(green, "spec(s) failed", "a green run has no failure line")
  eq(green[#green], "summary: 2 pass (2 case(s)) in 0.00 s", "green summary")
  has_line(
    lines,
    "summary: 2 pass, 2 fail, 1 error, 1 skip, 1 xfail, 1 xpass, 1 timeout, 1 crash (10 case(s)) in 1.50 s",
    "mixed summary counts every status"
  )
  local seeded = F.green()
  seeded.run.seed = 7
  has_line(term.render(seeded), "seed: 7", "seed is printed")
  has_no_line(term.render(seeded), "reproduce", "no reproduce hint when green")

  -- empty and determinism ----------------------------------------------------------------------------------
  local empty = term.render(result.new({ id = "2026-10-05T10:00:00Z-0006" }))
  eq(empty[#empty], "summary: 0 pass (0 case(s)) in 0.00 s", "an empty run renders")
  eq(term.render(F.mixed()), term.render(F.mixed()), "rendering is deterministic")
  eq(term.render(F.hostile()), term.render(F.hostile()), "hostile rendering is deterministic")
end
