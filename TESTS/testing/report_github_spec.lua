-- TESTS/testing/report_github_spec.lua -- testing.report.github: workflow-command escaping
-- (injection), annotations, the annotation cap, the Markdown step summary and its safe append.

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
  local gh = require("testing.report.github")

  -- escaping ----------------------------------------------------------------------------------------
  eq(gh.escape_data("100%"), "100%25", "data: percent")
  eq(gh.escape_data("a\r\nb"), "a%0D%0Ab", "data: CR and LF")
  eq(gh.escape_data("a:b,c"), "a:b,c", "data keeps ':' and ','")
  eq(gh.escape_property("a:b,c"), "a%3Ab%2Cc", "property: colon and comma")
  eq(gh.escape_property("%0A"), "%250A", "property: an existing %0A does not turn into a newline")
  eq(gh.escape_data("x\27[31my"), "x\\x1B[31my", "data: ESC is neutralized")
  eq(gh.escape_data(42), "42", "data: non-strings")
  eq(
    gh.command("error", { file = "a,b.lua", line = 3, title = "t:1" }, "m\nn"),
    "::error file=a%2Cb.lua,line=3,title=t%3A1::m%0An",
    "full command"
  )
  eq(gh.command("warning", {}, "plain"), "::warning::plain", "command without properties")
  eq(
    gh.command("error", { file = "f", line = 0 }, "x"),
    "::error file=f::x",
    "a line below 1 is dropped"
  )

  -- the injection: nothing from the code under test can start a second command -------------------------
  local lines = gh.render(F.hostile())
  ok(#lines == 3, "one annotation per failed assertion and per erroring case, got " .. #lines)
  for _, l in ipairs(lines) do
    ok(l:find("^::error "), "every line is exactly one error command: " .. l)
    ok(not l:find("[\r\n]"), "no raw newline in a command")
    ok(not l:find("\27", 1, true), "no raw ESC")
    local body = l:match("^::error [^:]*::(.*)$") or ""
    ok(
      not body:find("::", 1, true) or body:find("%0A", 1, true),
      "'::' in a message follows an escaped newline"
    )
  end
  local all = table.concat(lines, "\n")
  ok(not all:find("\n::error title=owned", 1, true), "the injected command never starts a line")
  ok(all:find("file=TESTS/x%2Cy%3Az_spec.lua", 1, true), "file property is escaped")
  ok(all:find("%250A", 1, true), "a literal %0A in a name stays a literal (escaped percent)")
  ok(all:find("line=8", 1, true), "assertion line is used")
  ok(all:find("line=7", 1, true), "case line is the fallback")

  -- annotations of the mixed run -------------------------------------------------------------------------
  local mixed = gh.render(F.mixed(), { max_annotations = 50 })
  eq(#mixed, 6, "fail, multi, error, xpass, timeout and crash are annotated")
  local joined = table.concat(mixed, "\n")
  ok(
    joined:find(
      "::error file=TESTS/b_spec.lua,line=12,title=TESTS/b_spec.lua%3A%3Acompares::values differ%0Aexpected: 1%0Aactual: 2",
      1,
      true
    ),
    "failed assertion annotation"
  )
  ok(joined:find("title=TESTS/c_spec.lua%3A%3Aexplodes::error: boom", 1, true), "error annotation")
  ok(joined:find("unexpectedly passed", 1, true), "xpass annotation")
  ok(joined:find("timeout: case exceeded 5000 ms", 1, true), "timeout annotation")
  ok(not joined:find("d_spec", 1, true), "skips are not annotated by default")
  ok(not joined:find("a_spec", 1, true), "green cases are not annotated")
  local with_skips = gh.render(F.mixed(), { max_annotations = 50, annotate_skips = true })
  ok(
    table.concat(with_skips, "\n"):find("::warning file=TESTS/d_spec.lua", 1, true),
    "skip warning on request"
  )

  -- cap -----------------------------------------------------------------------------------------------------
  local capped = gh.render(F.mixed(), { max_annotations = 2 })
  eq(#capped, 3, "two annotations plus the overflow warning")
  ok(
    capped[3]:find("^::warning title=testing::4 more annotation%(s%) not shown %(limit 2%)$"),
    "overflow warning: " .. capped[3]
  )
  eq(#gh.render(F.green()), 0, "a green run emits nothing")

  -- markdown ---------------------------------------------------------------------------------------------------
  eq(gh.md_escape("a|b"), "a\\|b", "md: pipe")
  eq(gh.md_escape("<script>&"), "&lt;script&gt;&amp;", "md: HTML")
  eq(gh.md_escape("a\nb"), "a b", "md: newline")
  eq(gh.md_escape("`x` *y* _z_ [w]"), "\\`x\\` \\*y\\* \\_z\\_ \\[w\\]", "md: punctuation")
  local md = gh.summary_markdown(F.mixed())
  eq(md[1], "## testing.nvim: FAILED", "heading names the verdict")
  eq(gh.summary_markdown(F.green())[1], "## testing.nvim: passed", "green heading")
  local mdtext = table.concat(md, "\n")
  ok(mdtext:find("| TESTS/b\\_spec.lua | FAIL (1) | 1 | 0.040 |", 1, true), "file row")
  ok(
    mdtext:find("| TESTS/d\\_spec.lua | skip | 1 | 0.000 |", 1, true),
    "an all-skipped file is not ok"
  )
  ok(mdtext:find("Seed: `4242`", 1, true), "seed line")
  local hostile_md = table.concat(gh.summary_markdown(F.hostile()), "\n")
  ok(not hostile_md:find("<b>", 1, true), "no raw HTML from a name")
  ok(not hostile_md:find("\27", 1, true), "no ESC")

  -- write_summary: appends, never replaces; path rules ----------------------------------------------------
  local path = vim.fn.tempname() .. "-summary.md"
  local fh = assert(io.open(path, "wb"))
  fh:write("earlier step\n")
  fh:close()
  local wrote, werr = gh.write_summary(F.green(), { env = { GITHUB_STEP_SUMMARY = path } })
  ok(wrote == true, "write_summary succeeds: " .. tostring(werr))
  local content = table.concat(vim.fn.readfile(path, "b"), "\n")
  ok(content:find("^earlier step"), "earlier content is kept (append)")
  ok(content:find("## testing.nvim: passed", 1, true), "summary appended")
  gh.write_summary(F.green(), { summary_path = path })
  local twice = table.concat(vim.fn.readfile(path, "b"), "\n")
  local _, n = twice:gsub("## testing.nvim: passed", "")
  eq(n, 2, "a second write appends again")
  vim.fn.delete(path)

  local no, nerr = gh.write_summary(F.green(), { env = {} })
  ok(no == false and (nerr or ""):find("not set", 1, true), "no variable: false plus a reason")
  local bad, berr = gh.write_summary(F.green(), { summary_path = "a\0b" })
  ok(bad == false and (berr or ""):find("not a valid path", 1, true), "NUL in the path is refused")
  eq({ gh.finish(F.green(), { env = {} }) }, {}, "finish without a variable is not applicable")
  eq(
    { gh.finish(F.green(), { summary = false, env = { GITHUB_STEP_SUMMARY = "x" } }) },
    {},
    "finish disabled"
  )

  -- size cap
  local small = vim.fn.tempname() .. "-cap.md"
  gh.write_summary(F.mixed(), { summary_path = small, summary_max_bytes = 200 })
  local capped_text = table.concat(vim.fn.readfile(small, "b"), "\n")
  ok(#capped_text < 400, "the summary is capped (" .. #capped_text .. " bytes)")
  ok(capped_text:find("summary truncated", 1, true), "the cap is announced")
  vim.fn.delete(small)

  -- determinism ---------------------------------------------------------------------------------------------------
  eq(gh.render(F.hostile()), gh.render(F.hostile()), "annotations are deterministic")
  eq(gh.summary_markdown(F.mixed()), gh.summary_markdown(F.mixed()), "summary is deterministic")
end
