-- TESTS/testing/report_util_spec.lua -- testing.report.util: cleaning of hostile text, byte caps,
-- line splitting, status classes.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local util = require("testing.report.util")

  -- clean ----------------------------------------------------------------------------------------
  eq(util.clean("plain ascii"), "plain ascii", "clean leaves printable ASCII alone")
  eq(util.clean("日本語 😀 é"), "日本語 😀 é", "clean leaves valid UTF-8 alone")
  eq(util.clean("a\27[31mb"), "a\\x1B[31mb", "clean makes ESC visible")
  eq(util.clean("a\0b"), "a\\x00b", "clean makes NUL visible")
  eq(util.clean("a\tb\nc"), "a\\x09b\\x0Ac", "clean escapes TAB/LF without keep")
  eq(
    util.clean("a\tb\nc", { keep = { [9] = true, [10] = true } }),
    "a\tb\nc",
    "clean keeps what keep lists"
  )
  eq(util.clean("x\127y"), "x\\x7Fy", "clean escapes DEL")
  eq(util.clean("bad \255 byte"), "bad \239\191\189 byte", "invalid byte becomes U+FFFD")
  eq(util.clean("over \192\175 long"), "over \239\191\189\239\191\189 long", "overlong sequence")
  eq(
    util.clean("sur \237\160\128 rogate"),
    "sur \239\191\189\239\191\189\239\191\189 rogate",
    "surrogate"
  )
  eq(util.clean("cut \226\130"), "cut \239\191\189\239\191\189", "truncated sequence at the end")
  eq(util.clean("c1 \194\155[2J"), "c1 \194\155[2J", "C1 is passed by default")
  eq(util.clean("c1 \194\155[2J", { c1 = true }), "c1 \\u{009B}[2J", "C1 CSI escaped with c1")
  eq(util.clean("a\226\128\174b"), "a\226\128\174b", "bidi override passed by default")
  eq(
    util.clean("a\226\128\174b", { bidi = true }),
    "a\\u{202E}b",
    "bidi override escaped with bidi"
  )
  eq(util.clean("nc \239\191\190"), "nc \\u{FFFE}", "U+FFFE is never emitted raw")
  ---@diagnostic disable-next-line: param-type-mismatch
  eq(util.clean(42), "42", "non-strings are stringified")

  -- cap ------------------------------------------------------------------------------------------
  local s, cut = util.cap("abcdef", 10)
  eq({ s, cut }, { "abcdef", false }, "cap under the limit")
  s, cut = util.cap("abcdef", 3)
  eq({ s, cut }, { "abc", true }, "cap over the limit")
  s, cut = util.cap("a日本", 2) -- "日" is 3 bytes: starts at byte 2
  eq({ s, cut }, { "a", true }, "cap never splits a character")
  s, cut = util.cap("a日本", 4)
  eq({ s, cut }, { "a日", true }, "cap lands on a boundary")

  -- split_lines ----------------------------------------------------------------------------------
  eq(util.split_lines("a\nb"), { "a", "b" }, "split LF")
  eq(util.split_lines("a\r\nb\rc"), { "a", "b", "c" }, "split CRLF and CR")
  eq(util.split_lines("a\n"), { "a" }, "a trailing newline is not a line")
  eq(util.split_lines(""), { "" }, "empty is one empty line")
  eq(util.split_lines("a\n\nb"), { "a", "", "b" }, "empty middle line kept")

  -- whitespace and the workflow-command guard ----------------------------------------------------
  -- the runner of GitHub Actions trims a line with .NET `TrimStart()` (every `char.IsWhiteSpace`) before it looks for `::`
  local spaces =
    { 9, 10, 11, 12, 13, 32, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }
  for cp = 0x2000, 0x200A do
    spaces[#spaces + 1] = cp
  end
  for _, cp in ipairs(spaces) do
    local ch = vim.fn.nr2char(cp)
    eq(util.space_len(ch .. "x", 1), #ch, ("space_len knows U+%04X"):format(cp))
    ok(util.has_space("a" .. ch .. "b"), ("has_space knows U+%04X"):format(cp))
    local line = "  " .. ch .. "::stop-commands::tok"
    eq(
      util.defuse_command(line),
      "  " .. ch .. "\\x3A:stop-commands::tok",
      ("a command behind U+%04X is defused"):format(cp)
    )
  end
  -- what is no whitespace stays what it is: the zero-width space, the BOM, the line above 0x3000, a letter
  for _, cp in ipairs({ 0x200B, 0x200C, 0xFEFF, 0x180E, 0x3001, 0xE9, 0x00A1 }) do
    local ch = vim.fn.nr2char(cp)
    eq(util.space_len(ch, 1), nil, ("U+%04X is no whitespace"):format(cp))
    eq(
      util.defuse_command(ch .. "::x"),
      ch .. "::x",
      ("U+%04X in front of :: is not trimmed by the runner"):format(cp)
    )
  end
  eq(util.defuse_command("::error::x"), "\\x3A:error::x", "a command at the start of the line")
  eq(util.defuse_command("   ::error::x"), "   \\x3A:error::x", "after ASCII indentation, kept")
  eq(util.defuse_command("a ::error::x"), "a ::error::x", "a `::` in the middle is no command")
  eq(util.defuse_command(": :error"), ": :error", "one colon, a space, one colon is none")
  eq(util.defuse_command("   "), "   ", "only whitespace")
  eq(util.defuse_command(""), "", "the empty line")
  eq(util.defuse_command("\\x3A:error"), "\\x3A:error", "an already defused line is left alone")
  -- the legacy `##[command]` form: the runner searches the whole line for `##[` (.NET `IndexOf`, no trim, no
  -- position), so it is defused anywhere, behind a colour sequence or a prefix too
  eq(
    util.defuse_command("##[error]x"),
    "#\\x23[error]x",
    "a legacy command at the start of the line"
  )
  eq(
    util.defuse_command("boom ##[stop-commands]tok ##[error]forged"),
    "boom #\\x23[stop-commands]tok #\\x23[error]forged",
    "a legacy command in the middle, every one of them"
  )
  eq(
    util.defuse_command("\27[31m##[warning]x\27[0m"),
    "\27[31m#\\x23[warning]x\27[0m",
    "a legacy command behind a colour sequence (the runner does not trim ESC)"
  )
  eq(
    util.defuse_command("###[error]x"),
    "##\\x23[error]x",
    "a third `#` in front does not hide the command"
  )
  eq(util.defuse_command("####[x]"), "###\\x23[x]", "and neither do more")
  eq(util.defuse_command("##[##[x]"), "#\\x23[#\\x23[x]", "adjacent commands")
  eq(
    util.defuse_command("# #[x] ##x [y] #[z]"),
    "# #[x] ##x [y] #[z]",
    "no `##[` in it, nothing to do"
  )
  eq(
    util.defuse_command('{"message":"a ##[error]x","n":1}', true),
    '{"message":"a #\\u0023[error]x","n":1}',
    "a JSON line gets the JSON escape, so it stays valid JSON"
  )
  eq(
    vim.json.decode(util.defuse_command('{"message":"a ##[error]x"}', true)).message,
    "a ##[error]x",
    "and decodes to the original text"
  )
  eq(
    util.defuse_command("  ::x", true),
    "  \\u003A:x",
    "the leading `::` of a JSON text is written \\u003A:"
  )
  eq(
    util.defuse_command("#\\x23[error]x"),
    "#\\x23[error]x",
    "an already defused legacy line is left alone"
  )
  eq(
    util.defuse_command("  ::error::##[error]x"),
    "  \\x3A:error::#\\x23[error]x",
    "both forms in one line"
  )
  for _, l in ipairs({
    "##[a]",
    "x##[a]##[b]",
    "###[a]",
    "#####[a]",
    "##[##[a]",
    "\27[1m##[a]",
    "::##[a]",
  }) do
    local once = util.defuse_command(l)
    ok(not once:find("##[", 1, true), ("no `##[` is left in %s"):format(vim.inspect(once)))
    eq(
      util.defuse_command(once),
      once,
      ("a second pass changes nothing in %s"):format(vim.inspect(l))
    )
  end
  eq(util.has_space("plain-word"), false, "no whitespace")
  eq(util.has_space("a\226\128\139b"), false, "a zero-width space is none")

  -- classes --------------------------------------------------------------------------------------
  eq(util.class_of("pass"), "ok", "pass is ok")
  eq(util.class_of("xfail"), "ok", "xfail is ok")
  eq(util.class_of("skip"), "skip", "skip is never green")
  for _, st in ipairs({ "fail", "error", "xpass", "timeout", "crash" }) do
    eq(util.class_of(st), "bad", st .. " is bad")
  end
  eq(util.class_of("martian"), "bad", "an unknown status never reads as green")

  -- misc -----------------------------------------------------------------------------------------
  ---@diagnostic disable-next-line: missing-fields
  eq(util.short_name({ id = "f.lua::a::b", file = "f.lua" }), "a::b", "short_name strips the file")
  ---@diagnostic disable-next-line: missing-fields
  eq(util.short_name({ id = "other", file = "f.lua" }), "other", "short_name without prefix")
  eq(util.seconds(1500), "1.500", "seconds from ms")
  eq(util.seconds(nil), "0.000", "seconds from nil")
  eq(util.seconds(2), "0.002", "seconds keeps ms resolution")
end
