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
