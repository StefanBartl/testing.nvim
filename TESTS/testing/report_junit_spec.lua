-- TESTS/testing/report_junit_spec.lua -- testing.report.junit: well-formed XML for any input
-- (checked by an independent minimal parser), element mapping, counters, CDATA splitting, caps.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local junit = require("testing.report.junit")
  local result = require("testing.core.result")

  ---@param r Testing.Result
  ---@param opts? table
  ---@return Testing.Fixture.XmlNode root
  ---@return string text
  local function parsed(r, opts)
    local text = table.concat(junit.render(r, opts), "\n")
    local root, err = F.parse_xml(text)
    ok(root ~= nil, "the document is well-formed XML: " .. tostring(err))
    return root, text
  end

  ---@param node Testing.Fixture.XmlNode
  ---@param name string
  ---@return Testing.Fixture.XmlNode[]
  local function kids_named(node, name)
    local out = {}
    for _, k in ipairs(node.kids) do
      if k.name == name then
        out[#out + 1] = k
      end
    end
    return out
  end

  ---@param root Testing.Fixture.XmlNode
  ---@param needle string
  ---@return Testing.Fixture.XmlNode
  local function testcase(root, needle)
    for _, suite in ipairs(root.kids) do
      for _, tc in ipairs(kids_named(suite, "testcase")) do
        if tc.attrs.name:find(needle, 1, true) then
          return tc
        end
      end
    end
    error("no testcase named " .. needle, 2)
  end

  -- the checker itself must be able to fail ---------------------------------------------------------
  ok(F.parse_xml("<a>\1</a>") == nil, "checker: control character")
  ok(F.parse_xml("<a>x</b>") == nil, "checker: mismatched tag")
  ok(F.parse_xml('<a x="&bogus;"/>') == nil, "checker: unknown reference")
  ok(F.parse_xml("<a>]]></a>") == nil, "checker: ]]> in text")
  ok(F.parse_xml("<a>a & b</a>") == nil, "checker: bare ampersand")
  ok(F.parse_xml('<a x="1" x="2"/>') == nil, "checker: duplicate attribute")
  ok(F.parse_xml('<a x="a<b"/>') == nil, "checker: raw < in attribute")
  ok(F.parse_xml("<a>\255</a>") == nil, "checker: invalid UTF-8")
  ok(F.parse_xml("<a/><b/>") == nil, "checker: two roots")
  ok(F.parse_xml("<a><![CDATA[x</a>") == nil, "checker: open CDATA")
  ok(F.parse_xml('<a x="a\nb"/>') == nil, "checker: raw newline in attribute")
  ok(F.parse_xml('<a x="&lt;">&amp;<![CDATA[<>]]></a>') ~= nil, "checker accepts a good document")

  -- escaping primitives ------------------------------------------------------------------------------------
  eq(junit.attr([[a"b'<&>]]), "a&quot;b&apos;&lt;&amp;&gt;", "attr escapes the five characters")
  eq(junit.attr("a\nb\tc"), "a\\x0Ab\\x09c", "attr: no raw whitespace controls")
  eq(junit.text("a<b&c>d"), "a&lt;b&amp;c&gt;d", "text escapes")
  eq(junit.cdata("x]]>y"), "<![CDATA[x]]]]><![CDATA[>y]]>", "cdata splits ]]>")
  eq(junit.cdata("]]>]]>"), "<![CDATA[]]]]><![CDATA[>]]]]><![CDATA[>]]>", "cdata splits every ]]>")
  eq(junit.cdata("a\rb"), "<![CDATA[a\\rb]]>", "cdata: CR is made visible")

  -- structure and mapping ------------------------------------------------------------------------------------
  local root = parsed(F.mixed())
  eq(root.name, "testsuites", "root element")
  eq(
    {
      root.attrs.tests,
      root.attrs.failures,
      root.attrs.errors,
      root.attrs.skipped,
      root.attrs.time,
    },
    { "10", "3", "3", "2", "5.365" },
    "root counters: failures = fail+xpass, errors = error+timeout+crash, skipped = skip+xfail"
  )
  local suites = kids_named(root, "testsuite")
  eq(#suites, 7, "one testsuite per spec file")
  eq(suites[1].attrs.name, "TESTS/a_spec.lua", "suites keep the IR order")
  eq(
    { suites[5].attrs.name, suites[5].attrs.tests, suites[5].attrs.failures },
    { "TESTS/e_spec.lua", "2", "1" },
    "a two-case file"
  )
  eq(
    { suites[7].attrs.errors, suites[7].attrs.time },
    { "2", "5.009" },
    "timeout and crash are errors; time is seconds"
  )
  local sum = 0
  for _, s in ipairs(suites) do
    sum = sum + tonumber(s.attrs.tests)
  end
  eq(sum, tonumber(root.attrs.tests), "suite counters add up to the root")

  local pass = testcase(root, "adds")
  eq(
    { pass.attrs.classname, pass.attrs.line, pass.attrs.time },
    { "TESTS/a_spec.lua", "3", "0.005" },
    "testcase attributes"
  )
  eq(#pass.kids, 0, "a green case has no child element")
  local fail = testcase(root, "compares")
  eq(fail.kids[1].name, "failure", "fail -> failure")
  eq(fail.kids[1].attrs.message, "values differ", "failure message")
  eq(fail.kids[1].attrs.type, "eq", "failure type is the assertion kind")
  ok(
    fail.kids[1].text:find("TESTS/b_spec.lua:12  values differ", 1, true),
    "failure body names file:line"
  )
  ok(
    fail.kids[1].text:find("expected: 1", 1, true) and fail.kids[1].text:find("actual: 2", 1, true),
    "failure body has expected/actual"
  )
  local err = testcase(root, "explodes")
  eq(
    { err.kids[1].name, err.kids[1].attrs.message, err.kids[1].attrs.type },
    { "error", "boom", "error" },
    "error element"
  )
  ok(err.kids[1].text:find("stack traceback:", 1, true), "error body has the traceback")
  local skip = testcase(root, "needs net")
  eq(
    { skip.kids[1].name, skip.kids[1].attrs.message },
    { "skipped", "needs network" },
    "skip -> skipped with reason"
  )
  local xfail = testcase(root, "known bug")
  eq(
    { xfail.kids[1].name, xfail.kids[1].attrs.message },
    { "skipped", "expected failure" },
    "xfail -> skipped"
  )
  local xpass = testcase(root, "fixed bug")
  eq({ xpass.kids[1].name, xpass.kids[1].attrs.type }, { "failure", "xpass" }, "xpass -> failure")
  local timeout = testcase(root, "hangs")
  eq(
    { timeout.kids[1].name, timeout.kids[1].attrs.type },
    { "error", "timeout" },
    "timeout -> error"
  )
  eq(testcase(root, "dies").kids[1].attrs.type, "crash", "crash -> error type crash")
  eq(testcase(root, "multi").attrs.name, "group::multi", "describe path is part of the name")

  local props = kids_named(suites[1], "properties")[1]
  local pv = {}
  for _, p in ipairs(props.kids) do
    pv[p.attrs.name] = p.attrs.value
  end
  eq(pv, { nvim = "0.12.0", os = "linux", seed = "4242" }, "run properties")
  local noseed = kids_named(parsed(F.green()).kids[1], "properties")[1]
  eq(#noseed.kids, 2, "no seed property without a seed")

  -- hostile input ------------------------------------------------------------------------------------------------
  local hroot, htext = parsed(F.hostile())
  local hcase = testcase(hroot, "quotes")
  ok(hcase ~= nil, "hostile case found")
  ok(
    hcase.attrs.name:find(F.HOSTILE.name, 1, true),
    "quotes, <, &, ]]>, %0A, CJK and emoji survive the round trip"
  )
  ok(hcase.attrs.name:find("\\x0A", 1, true), "a newline in a name is visible, not raw")
  local body = hcase.kids[1].text
  ok(body:find("::error title=owned::pwned", 1, true), "the text is kept (as text)")
  local ebody = testcase(hroot, "red")
  ok(ebody.kids[1].text:find(F.HOSTILE.name, 1, true), "a ]]> in a body survives the CDATA split")
  ok(not htext:find("\27", 1, true), "no raw ESC in the document")
  ok(htext:find("\\x1B", 1, true), "ESC is visible")
  ok(htext:find("\239\191\189", 1, true), "invalid UTF-8 became U+FFFD")
  ok(not htext:find("\226\128\174", 1, true), "bidi override is escaped")

  -- every byte value, in every field
  local all_bytes = {}
  for b = 0, 255 do
    all_bytes[#all_bytes + 1] = string.char(b)
  end
  local every = table.concat(all_bytes) .. "\239\191\190\239\191\191\237\160\128\244\144\128\128"
  local r = result.new({ id = "2026-10-05T10:00:00Z-0007", nvim = every, os = every })
  F.add(r, {
    file = "TESTS/" .. every .. ".lua",
    describe = { every },
    name = every,
    reason = every,
    status = "skip",
  })
  F.add(r, {
    file = "TESTS/" .. every .. ".lua",
    name = every .. "2",
    assertions = {
      { ok = false, kind = every, msg = every, expected = every, actual = every, diff = every },
    },
    status = "fail",
  })
  F.add(r, {
    file = "TESTS/" .. every .. ".lua",
    name = every .. "3",
    status = "error",
    error = { message = every, traceback = every },
  })
  r.run.seed = nil
  result.finalize(r)
  local every_root = parsed(r)
  eq(#every_root.kids, 1, "all-bytes document parses: one suite")
  eq(every_root.attrs.tests, "3", "all-bytes document counters")

  -- caps (SEC-32) --------------------------------------------------------------------------------------------------
  local big = result.new({ id = "2026-10-05T10:00:00Z-0008" })
  F.add(big, {
    file = "TESTS/big_spec.lua",
    name = "big",
    assertions = {
      {
        ok = false,
        kind = "eq",
        msg = "m",
        expected = ("日"):rep(50000),
        actual = ("x"):rep(200000),
      },
    },
  })
  local _, big_text = parsed(big, { max_body_bytes = 1000 })
  ok(#big_text < 3500, "the document stays small (" .. #big_text .. " bytes)")
  ok(big_text:find("truncated", 1, true), "truncation is announced")
  local _, default_text = parsed(big)
  ok(#default_text < 40000, "default cap bounds the document (" .. #default_text .. " bytes)")

  -- empty, suite name, determinism ------------------------------------------------------------------------------------
  local empty = parsed(result.new({ id = "2026-10-05T10:00:00Z-0009" }))
  eq({ empty.attrs.tests, #empty.kids }, { "0", 0 }, "an empty run is a valid empty document")
  eq(parsed(F.green(), { suite_name = 'my "suite"' }).attrs.name, 'my "suite"', "suite_name option")
  eq(junit.render(F.mixed()), junit.render(F.mixed()), "rendering is deterministic")
  eq(junit.render(F.hostile()), junit.render(F.hostile()), "hostile rendering is deterministic")
  local one = table.concat(junit.render(F.mixed()), "\n")
  ok(
    not one:find("timestamp", 1, true) and not one:find("hostname", 1, true),
    "no clock, no host in the output"
  )
  ok(not one:find("\r", 1, true), "no CR in the output")
end
