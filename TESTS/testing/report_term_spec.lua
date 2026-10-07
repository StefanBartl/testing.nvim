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

  -- the rule of the runner of GitHub Actions, written out on its own (not through `util.space_len`): it trims
  -- the line with .NET `TrimStart()` (ASCII and Unicode whitespace) and then looks for `::`
  local runner_space = { [0xA0] = true, [0x1680] = true, [0x2028] = true, [0x2029] = true }
  runner_space[0x202F], runner_space[0x205F], runner_space[0x3000] = true, true, true
  for cp = 0x2000, 0x200A do
    runner_space[cp] = true
  end
  local function runner_reads_command(l)
    local chars = vim.fn.split(l, "\\zs")
    local i = 1
    while chars[i] and (chars[i] == " " or runner_space[vim.fn.char2nr(chars[i])]) do
      i = i + 1
    end
    return chars[i] == ":" and chars[i + 1] == ":"
  end
  local function none_is_command(lines, msg)
    for _, l in ipairs(lines) do
      ok(not runner_reads_command(l), ("%s: the runner would run %s"):format(msg, vim.inspect(l)))
    end
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
    -- (every detail line is indented, so `^::` would never match: the runner trims before it looks)
    ok(not runner_reads_command(l), "no line is read as a workflow command: " .. vim.inspect(l))
  end
  has_line(hostile, "\\x1B", "ESC is made visible")
  has_line(hostile, "\\x00", "NUL is made visible")
  has_line(hostile, "\\u{202E}", "bidi override is made visible")
  has_line(hostile, "\239\191\189", "invalid UTF-8 became U+FFFD")
  has_line(
    hostile,
    "\\x3A:error title=owned::pwned",
    "a workflow command in a message stays inert text, its leading :: written \\x3A:"
  )
  ok(
    vim.fn.strdisplaywidth(table.concat(hostile, "\n")) >= 0,
    "output is valid UTF-8 for the editor"
  )

  -- workflow commands: this reporter indents every detail line, and the runner of GitHub Actions trims a line before it
  -- looks for `::`, so every text that can start a line is defused: a message, an error, a traceback, a diff context
  -- line, a plain expected value, a skip reason, a process command line, a guard message ---------------------------
  ok(
    runner_reads_command("        ::warning::second"),
    "(the check itself sees an indented command)"
  )
  ok(runner_reads_command("\u{3000}::stop-commands::tok"), "(and one behind an ideographic space)")
  ok(not runner_reads_command("        \\x3A:warning::second"), "(and not the defused form)")
  ok(not runner_reads_command("a ::x"), "(and not a `::` in the middle)")
  do
    local r = result.new({ id = "2026-10-07T10:00:00Z-0010", nvim = "0.12.0", os = "linux" })
    F.add(r, {
      file = "TESTS/m_spec.lua",
      name = "message",
      assertions = {
        {
          ok = false,
          kind = "ok",
          msg = "head\n::warning::second\n\u{3000}::stop-commands::tok",
          diff = "-x\n::error::in-diff-field",
        },
      },
    })
    F.add(r, {
      file = "TESTS/n_spec.lua",
      name = "error text",
      status = "error",
      error = {
        message = "boom\r\n::error::from-error",
        traceback = "stack traceback:\n::error::in-trace\n\u{00A0}::notice::deeper",
      },
    })
    F.add(r, {
      file = "TESTS/o_spec.lua",
      name = "diff",
      assertions = {
        {
          ok = false,
          kind = "eq",
          msg = "differs",
          expected = "a\n::error::same-line-in-diff\nb\nc",
          actual = "a\n::error::same-line-in-diff\nb\nX",
        },
      },
    })
    F.add(r, {
      file = "TESTS/p_spec.lua",
      name = "plain value",
      assertions = {
        { ok = false, kind = "eq", msg = "plain", expected = "x\n::error::expected-line" },
      },
    })
    F.add(r, {
      file = "TESTS/q_spec.lua",
      name = "skipped",
      status = "skip",
      reason = "why\n::notice::skip-reason",
    })
    F.add(r, {
      file = "TESTS/s_spec.lua",
      name = "hangs",
      status = "timeout",
      error = { message = "t\n::error::in-timeout", traceback = "" },
    })
    local spawner = F.add(r, { file = "TESTS/t_spec.lua", name = "spawns" })
    spawner.effects.spawned = { "::stop-commands::tok -x (x2)" }
    spawner.guards = {
      { guard = "state", severity = "warn", message = "leaks\n::warning::guard-line" },
    }
    for _, color in ipairs({ false, true }) do
      local out = term.render(r, { color = color })
      local what = color and "colour on" or "colour off"
      none_is_command(out, what)
      for _, needle in ipairs({
        "\\x3A:warning::second",
        "\\x3A:stop-commands::tok",
        "\\x3A:error::in-diff-field",
        "\\x3A:error::from-error",
        "\\x3A:error::in-trace",
        "\\x3A:notice::deeper",
        "\\x3A:error::same-line-in-diff",
        "\\x3A:error::expected-line",
        "\\x3A:notice::skip-reason",
        "\\x3A:error::in-timeout",
        "\\x3A:stop-commands::tok -x",
      }) do
        has_line(out, needle, what .. ": the text is kept, its leading :: written \\x3A:")
      end
    end
    -- the pass keeps the indentation and touches nothing else
    local plain = term.render(r)
    eq(
      plain[index_of(plain, "from-error")],
      "      \\x3A:error::from-error",
      "the indentation of the line stays"
    )
    has_no_line(term.render(r), "x3A:x3A", "a line is defused once")
  end
  -- the same behind every whitespace character the runner trims (a no-break space, U+2000 to U+200A, U+3000, ...)
  do
    local spaces = { 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }
    for cp = 0x2000, 0x200A do
      spaces[#spaces + 1] = cp
    end
    for _, cp in ipairs(spaces) do
      local ch = vim.fn.nr2char(cp)
      local r = result.new({ id = "2026-10-07T10:00:00Z-0011", nvim = "0.12.0", os = "linux" })
      F.add(r, {
        file = "TESTS/u_spec.lua",
        name = "u",
        assertions = {
          {
            ok = false,
            kind = "eq",
            msg = ch .. "::stop-commands::tok",
            expected = ch .. "::error::x",
            actual = "y",
          },
        },
      })
      F.add(r, {
        file = "TESTS/v_spec.lua",
        name = "v",
        status = "error",
        error = { message = ch .. "::stop-commands::tok", traceback = "" },
      })
      for _, l in ipairs(term.render(r)) do
        ok(
          not runner_reads_command(l),
          ("U+%04X: the runner would run %s"):format(cp, vim.inspect(l))
        )
      end
    end
  end

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

  -- the effects ledger: one line per distinct process / connection with its call and case counts --------
  do
    local r = result.new({ id = "2026-10-05T10:00:00Z-0007" })
    F.add(r, { file = "TESTS/a_spec.lua", name = "one", ms = 1 })
    F.add(r, { file = "TESTS/b_spec.lua", name = "two", ms = 1 })
    for _, c in ipairs(r.cases) do
      c.effects = { spawned = {}, network = {}, fs_outside_tmp = {} }
    end
    r.cases[1].effects.spawned = { "git status (x3)", "nvim --version [blocked]" }
    r.cases[2].effects.spawned = { "git status (x2)" }
    r.cases[2].effects.network = { "example.com" }
    local out = term.render(r)
    has_line(
      out,
      "processes started: 6 call(s), 2 distinct",
      "the spawn block counts calls and distinct entries"
    )
    has_line(out, "git status  x5 in 2 case(s)", "an entry seen in two cases is summed")
    has_line(out, "nvim --version  x1 in 1 case(s) [blocked]", "a blocked entry says so")
    has_line(out, "network connections: 1 call(s), 1 distinct", "the network block")
    local quiet = result.new({ id = "2026-10-05T10:00:00Z-0008" })
    F.add(quiet, { file = "TESTS/a_spec.lua", name = "one", ms = 1 })
    has_no_line(term.render(quiet), "processes started", "no effects, no block")
  end

  -- empty and determinism ----------------------------------------------------------------------------------
  local empty = term.render(result.new({ id = "2026-10-05T10:00:00Z-0006" }))
  eq(empty[#empty], "summary: 0 pass (0 case(s)) in 0.00 s", "an empty run renders")
  eq(term.render(F.mixed()), term.render(F.mixed()), "rendering is deterministic")
  eq(term.render(F.hostile()), term.render(F.hostile()), "hostile rendering is deterministic")
end
