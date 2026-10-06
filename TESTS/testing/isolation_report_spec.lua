-- TESTS/testing/isolation_report_spec.lua -- guard findings in the IR (`case.guards`: builders, validator, encoding,
-- redaction) and in the three reporters: the terminal shows warnings and failures, JUnit carries a warning as
-- `system-out` of a green testcase, GitHub annotates it, and hostile text never gets through.

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
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (got " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end
  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local result = require("testing.core.result")
  local inproc = require("testing.run.inproc")
  local term = require("testing.report.term")
  local junit = require("testing.report.junit")
  local github = require("testing.report.github")

  local function new_case(name, file)
    local c = result.new_case({ file = file or "TESTS/a_spec.lua", name = name })
    c.assertions[1] = { ok = true, kind = "eq" }
    return result.finish_case(c)
  end
  local function wrap(...)
    local r = result.new({ id = "2026-10-06T10:00:00Z-0001", nvim = "0.12.0", os = "linux" })
    for _, c in ipairs({ ... }) do
      result.add_case(r, c)
    end
    return result.finalize(r)
  end
  local function valid(r, opts)
    return result.validate(r, opts or { allow_abs_paths = true })
  end

  -- ================================================================== builders
  local c = new_case("one")
  eq(c.guards, nil, "a fresh case has no `guards` key (an IR without findings is unchanged)")
  eq(
    result.add_guard_finding(c, { guard = "fs", severity = "warn", message = "m" }),
    true,
    "recorded"
  )
  eq(c.guards, { { guard = "fs", severity = "warn", message = "m" } }, "the shape")
  eq(c.status, "pass", "a warning keeps the case green")
  eq(
    result.add_guard_finding(c, { guard = "fs", severity = "warn", message = "m" }),
    false,
    "a duplicate is not recorded"
  )
  eq(
    result.add_guard_finding(c, { guard = "fs", severity = "warn", message = "m", id = "fs.write" }),
    true,
    "a duplicate with another id is a different finding"
  )
  result.add_guard_finding(c, { guard = "state", severity = "info", message = "i" })
  eq(c.status, "pass", "info keeps it green too")
  eq(#c.assertions, 1, "and adds no assertion")
  result.add_guard_finding(
    c,
    { guard = "prompt", severity = "error", message = "asked", id = "prompt.blocked" }
  )
  eq(c.status, "fail", "an error finding fails a passing case")
  eq(
    c.assertions[2],
    { ok = false, kind = "guard", msg = "guard prompt: asked" },
    "with a failed `guard` assertion"
  )
  result.add_guard_finding(c, { guard = "fs", severity = "error", message = "second" })
  eq(c.status, "fail", "still failed")
  local errored = new_case("err")
  errored.status = "error"
  errored.error = { message = "boom", traceback = "boom" }
  result.add_guard_finding(errored, { guard = "prompt", severity = "error", message = "asked" })
  eq(errored.status, "error", "an error case keeps its own status")
  eq(#errored.assertions, 1, "and gets no extra assertion")
  local odd = new_case("odd")
  result.add_guard_finding(odd, { severity = "loud", message = 7 } --[[@as any]])
  eq(
    odd.guards[1],
    { guard = "guard", severity = "warn", message = "7" },
    "garbage is normalised, never raised"
  )
  -- the cap
  local capped = new_case("capped")
  for i = 1, result.MAX_GUARD_FINDINGS + 5 do
    result.add_guard_finding(capped, { guard = "fs", severity = "warn", message = "m" .. i })
  end
  eq(#capped.guards, result.MAX_GUARD_FINDINGS, "a runaway guard is capped")
  eq(result.GUARD_SEVERITIES, { "info", "warn", "error" }, "the severities")

  -- effects
  local e = new_case("effects")
  result.merge_effects(
    e,
    { spawned = { "a", "b", "a", 3 }, network = { "h" }, other = { "x" } } --[[@as any]]
  )
  eq(
    e.effects,
    { spawned = { "a", "b" }, network = { "h" }, fs_outside_tmp = {} },
    "deduplicated, strings only, known lists only"
  )
  result.merge_effects(e, { spawned = { "b", "c" } })
  eq(e.effects.spawned, { "a", "b", "c" }, "merging keeps order")
  result.merge_effects(e, nil)
  ---@type any
  local junk = "nope"
  result.merge_effects(e, junk)
  eq(e.effects.spawned, { "a", "b", "c" }, "garbage is ignored")
  local many = {}
  for i = 1, result.MAX_EFFECTS + 50 do
    many[i] = "e" .. i
  end
  result.merge_effects(e, { network = many })
  eq(#e.effects.network, result.MAX_EFFECTS, "the lists are bounded")

  -- ================================================================== the validator
  ok(valid(wrap(c)), "a case with findings is valid")
  local function problems_of(mutate)
    local case = new_case("v")
    mutate(case)
    local ok_, problems = valid(wrap(case))
    eq(ok_, false, "invalid")
    return table.concat(problems, "\n")
  end
  has(
    problems_of(function(x)
      x.guards = "no"
    end),
    "guards: must be a list",
    "guards must be a list"
  )
  has(
    problems_of(function(x)
      x.guards = { "no" }
    end),
    "guards[1]: must be a table",
    "an entry must be a table"
  )
  has(
    problems_of(function(x)
      x.guards = { { severity = "warn", message = "m", guard = "" } }
    end),
    "guard: must be a non-empty string",
    "an empty guard name"
  )
  has(
    problems_of(function(x)
      x.guards = { { severity = "fatal", message = "m", guard = "fs" } }
    end),
    "info|warn|error",
    "an unknown severity"
  )
  has(
    problems_of(function(x)
      x.guards = { { severity = "warn", message = 5, guard = "fs" } }
    end),
    "message: must be a string",
    "a message must be a string"
  )
  has(
    problems_of(function(x)
      x.guards = { { severity = "warn", message = "m", guard = "fs", id = 5 } }
    end),
    "id: must be a string",
    "an id must be a string"
  )
  has(
    problems_of(function(x)
      x.guards = { { severity = "error", message = "m", guard = "fs" } }
    end),
    "a guard error on a case with status 'pass'",
    "an error finding on a passing case is a contradiction"
  )
  ok(valid(wrap(new_case("no guards"))), "and a case without the key is still valid")

  -- ================================================================== encoding, redaction, scrubbing
  local leak = new_case("leak")
  result.add_guard_finding(leak, {
    guard = "fs",
    severity = "warn",
    message = "wrote C:\\Users\\bartl\\x.txt and E:/repos/demo/out.txt as secretuser",
  })
  local res = wrap(leak)
  local text = assert(result.encode(res, {
    roots = { repo = "E:/repos/demo" },
    case_insensitive = true,
    redact = { env_names = {}, words = { { text = "secretuser", ph = "<USER>" } } },
  }))
  local back = vim.json.decode(text)
  local msg = back.cases[1].guards[1].message
  has(msg, "<REPO>/out.txt", "the repo root becomes a placeholder in a finding")
  has(msg, "<HOME>", "a user home path is redacted")
  has(msg, "<USER>", "a named word is redacted")
  lacks(msg, "secretuser", "and is gone")
  lacks(msg, "bartl", "with the home path's user")
  local flagged = {}
  local ok_, _ = result.validate(
    vim.json.decode(vim.json.encode(res)),
    { forbid = { "secretuser" }, forbid_free_text_only = true, leak_warnings = flagged }
  )
  eq(ok_, true, "a leak is a warning, not an invalid IR")
  ok(#flagged >= 1, "but it is found in a finding's text (free text)")
  has(flagged[1], "guards", "and the path says where")

  -- the runner's own scrub (doubled backslashes of an inspected path)
  -- a root outside the user's home (a temp dir lies below it, and the home redaction would win)
  local root = "E:/repos/demo"
  local scrubbed = new_case("scrub")
  local doubled = root:gsub("/", "\\"):gsub("\\", "\\\\")
  result.add_guard_finding(
    scrubbed,
    { guard = "fs", severity = "warn", message = "wrote " .. doubled .. "\\\\x" }
  )
  local sres = wrap(scrubbed)
  inproc.scrub_texts(sres, root)
  lacks(sres.cases[1].guards[1].message, doubled, "scrub_texts reaches the findings")
  local ir, json, err = inproc.sanitize(wrap(new_case("s1")), root)
  ok(ir ~= nil and json ~= nil and err == nil, "sanitize works on an IR without findings")
  local _
  local sc = new_case("s2")
  result.add_guard_finding(
    sc,
    { guard = "state", severity = "warn", message = "leaks " .. root .. "/x", id = "state.autocmd" }
  )
  result.add_guard_finding(sc, { guard = "prompt", severity = "error", message = "asked" })
  ir, _, err = inproc.sanitize(wrap(sc), root)
  ok(ir ~= nil, "sanitize keeps an IR with findings valid: " .. tostring(err))
  local sanitized = assert(assert(ir).cases[1].guards)
  eq(#sanitized, 2, "and the findings")
  eq(sanitized[1].id, "state.autocmd", "with their ids")
  has(sanitized[1].message, "<REPO>/x", "and the path of the root as a placeholder")

  -- ================================================================== the terminal
  local warn_case = new_case("green but warned", "TESTS/w_spec.lua")
  result.add_guard_finding(warn_case, {
    guard = "state",
    severity = "warn",
    message = "TESTS/w_spec.lua leaves autocmd BufEnter in group `G`",
  })
  result.add_guard_finding(
    warn_case,
    { guard = "state", severity = "info", message = "loads module m" }
  )
  local red_case = new_case("red", "TESTS/r_spec.lua")
  result.add_guard_finding(
    red_case,
    { guard = "prompt", severity = "error", message = "TESTS/r_spec.lua asked a question" }
  )
  local run = wrap(warn_case, red_case, new_case("clean", "TESTS/c_spec.lua"))
  local lines = term.render(run, { color = false })
  local out = table.concat(lines, "\n")
  has(
    out,
    "guard findings: 1 warning(s), 1 failure(s) (+1 info, see the IR)",
    "the header counts, info is only mentioned"
  )
  has(out, "warn  [state] TESTS/w_spec.lua leaves autocmd BufEnter in group `G`", "a warning line")
  has(out, "error [prompt] TESTS/r_spec.lua asked a question", "a failure line")
  lacks(out, "loads module m", "an info finding is not listed in the terminal")
  has(
    out,
    "guard prompt: TESTS/r_spec.lua asked a question",
    "the failed case shows its guard assertion too"
  ) -- the assertion text carries the finding
  lacks(
    table.concat(term.render(F.green(), { color = false }), "\n"),
    "guard findings",
    "a run without findings prints no block"
  )
  local only_info = new_case("info only")
  result.add_guard_finding(
    only_info,
    { guard = "state", severity = "info", message = "loads module m" }
  )
  lacks(
    table.concat(term.render(wrap(only_info), { color = false }), "\n"),
    "guard findings",
    "only info: no block"
  )
  local colored = table.concat(term.render(run, { color = true }), "\n")
  has(colored, "\27[33mwarn  [state] \27[0m", "a warning is yellow")
  has(colored, "\27[31merror [prompt] \27[0m", "a failure is red")

  -- hostile text
  local hostile = new_case("hostile", "TESTS/h_spec.lua")
  result.add_guard_finding(hostile, {
    guard = "fs",
    severity = "warn",
    message = F.HOSTILE.escape .. "\n::error title=owned::pwned" .. F.HOSTILE.bidi,
  })
  local hl = wrap(hostile)
  local hterm = table.concat(term.render(hl, { color = false }), "\n")
  lacks(hterm, "\27", "the terminal: no escape sequence gets through")
  lacks(hterm, "\226\128\174", "no bidi override")
  for _, l in ipairs(term.render(hl, { color = false })) do
    lacks(l, "\n", "no embedded newline in a line")
  end

  -- ================================================================== JUnit
  local jr = wrap(warn_case, red_case, new_case("clean", "TESTS/c_spec.lua"))
  local jtext = table.concat(junit.render(jr), "\n")
  local root_node, perr = F.parse_xml(jtext)
  ok(root_node ~= nil, "well-formed XML: " .. tostring(perr))
  has(
    jtext,
    "<system-out><![CDATA[guard [state warn] TESTS/w_spec.lua leaves autocmd BufEnter in group `G`]]></system-out>",
    "a warning on a green case is its system-out"
  )
  lacks(jtext, "loads module m", "info is not in the XML")
  local suites = {}
  for _, s in ipairs(root_node.kids) do
    suites[s.attrs.name] = s
  end
  local wcase = suites["TESTS/w_spec.lua"].kids[#suites["TESTS/w_spec.lua"].kids]
  eq(wcase.name, "testcase", "the testcase")
  eq(wcase.kids[1].name, "system-out", "carries the system-out")
  eq(suites["TESTS/w_spec.lua"].attrs.failures, "0", "and is not counted as a failure")
  local rcase = suites["TESTS/r_spec.lua"].kids[#suites["TESTS/r_spec.lua"].kids]
  eq(rcase.kids[1].name, "failure", "an error finding failed the case: a failure element")
  eq(rcase.kids[2].name, "system-out", "followed by the finding")
  eq(suites["TESTS/r_spec.lua"].attrs.failures, "1", "counted")
  local jh = table.concat(junit.render(hl), "\n")
  ok(F.parse_xml(jh) ~= nil, "hostile text in a finding still gives well-formed XML")
  lacks(
    table.concat(junit.render(wrap(new_case("clean"))), "\n"),
    "system-out",
    "no finding, no system-out"
  )

  -- ================================================================== GitHub
  local glines = github.render(run)
  local gtext = table.concat(glines, "\n")
  has(
    gtext,
    "::warning file=TESTS/w_spec.lua,title=TESTS/w_spec.lua%3A%3Agreen but warned [state]::TESTS/w_spec.lua leaves autocmd",
    "a warning annotation on the case's file"
  )
  ok(not gtext:find("loads module m", 1, true), "info is not annotated")
  has(
    gtext,
    "::error file=TESTS/r_spec.lua",
    "the failed case has its error annotation (from its guard assertion)"
  )
  local err_count = select(2, gtext:gsub("::error ", ""))
  eq(err_count, 1, "and the error finding is not annotated a second time")
  local summary = table.concat(github.summary_markdown(run), "\n")
  has(summary, "### Guard findings", "the step summary has a section")
  has(summary, "warn [state]", "with the warning")
  has(summary, "FAIL [prompt]", "and the failure")
  lacks(summary, "loads module m", "but not the info")
  lacks(
    table.concat(github.summary_markdown(F.green()), "\n"),
    "Guard findings",
    "no section without findings"
  )
  local ghost = table.concat(github.render(hl), "\n")
  for l in (ghost .. "\n"):gmatch("(.-)\n") do
    ok(
      l == "" or l:sub(1, 2) == "::",
      "a hostile finding cannot start a second workflow command: " .. l:sub(1, 60)
    )
  end
end
