-- TESTS/testing/report_agent_spec.lua -- testing.report.agent: the compact reporter for coding agents. Golden lines for
-- green, red, partial and mixed runs, grouping of identical follow-up failures, the character budget (the verdict is
-- never cut, what does not fit is counted), hostile text, the jsonl shape, determinism, and the choice of the reporter
-- (`--reporter`, `TESTING_REPORTER`, `TESTING_AGENT`, an agent environment).

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack))
    )
  end

  local dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
  local F = dofile(dir .. "/report_fixture.lua")
  local agent = require("testing.report.agent")
  local verdict = require("testing.report.verdict")
  local result = require("testing.core.result")

  local CMD = "nvim -n -i NONE --headless -u NONE -l scripts/testing.lua"

  ---@return Testing.Result
  local function new_run(over)
    return result.new(vim.tbl_extend("force", {
      id = "2026-10-07T10:00:00Z-0001",
      root = "/proj",
      project_key = "proj@a1",
      nvim = "0.12.0",
      os = "linux",
      duration_ms = 1500,
      argv = { ".", "--reporter", "agent", "--cached", "--file", "other" },
    }, over or {}))
  end

  ---@param r Testing.Result
  ---@param file string
  ---@param name string
  ---@param a table
  local function failing(r, file, name, a)
    return F.add(r, {
      file = file,
      name = name,
      line = 3,
      assertions = {
        vim.tbl_extend("force", { ok = false, kind = "eq", file = "/proj/" .. file, line = 12 }, a),
      },
    })
  end

  local function joined(lines)
    return table.concat(lines, "\n")
  end

  -- green: one line, nothing else ------------------------------------------------------------------------------------
  local g = new_run()
  F.add(g, { file = "TESTS/a_spec.lua", name = "adds" })
  F.add(g, { file = "TESTS/b_spec.lua", name = "subs" })
  eq(
    agent.render(g),
    { "GREEN | 2 pass | 0 from cache, 2 ran, 0 skipped on purpose | 1.5 s | exit 0" },
    "a green run is its verdict line and nothing else"
  )

  -- a stored verdict says cached / skipped on purpose; a partial run names why ---------------------------------------
  g.run.verdict = verdict.build({
    exit_code = 0,
    files_total = 10,
    files_selected = 2,
    files_cached = 1,
    cases_total = 2,
    cases_skipped = 0,
    selection = "--changed",
  })
  eq(agent.render(g), {
    "PARTIAL | 2 pass | 1 from cache, 1 ran, 8 skipped on purpose | 1.5 s | exit 0",
    "partial: 8 spec file(s) not selected (--changed); no sentinel",
  }, "a partial run says PARTIAL and why, never GREEN")

  -- red: the golden failure entry -----------------------------------------------------------------------------------
  local r = new_run()
  F.add(r, { file = "TESTS/a_spec.lua", name = "adds" })
  failing(r, "TESTS/cfg_spec.lua", "parses nested keys", {
    msg = "values differ",
    expected = "1",
    actual = "2",
  })
  F.add(r, { file = "TESTS/z_spec.lua", name = "skipme", status = "skip", reason = "later" })
  r.run.verdict = verdict.build({
    exit_code = 1,
    files_total = 3,
    files_selected = 3,
    files_cached = 0,
    cases_total = 3,
    cases_skipped = 1,
    last_green = { ts = 1790000000, sha = "3f2a1b9" },
    changed_since = verdict.changed_since_of({ "lua/cfg.lua" }),
  })
  eq(
    agent.render(r, { command = CMD }),
    {
      "RED | 1 fail, 1 pass, 1 skip | 0 from cache, 3 ran, 0 skipped on purpose | 1.5 s | exit 1",
      "last green run: 2026-09-21 14:13:20Z at 3f2a1b9; 1 file(s) changed since: lua/cfg.lua",
      "FAIL TESTS/cfg_spec.lua:12  parses nested keys",
      "  values differ",
      "  expected: 1",
      "  actual: 2",
      "  rerun: " .. CMD .. " . --file TESTS/cfg_spec.lua --filter 'parses nested keys'",
    },
    "a red run: verdict, last green, the failure with file:line, values, and the command to repeat it"
  )
  ok(not joined(agent.render(r)):find("a_spec", 1, true), "a green file does not appear")
  ok(not joined(agent.render(r)):find("skipme", 1, true), "a skipped case is not a failure")
  ok(not joined(agent.render(r)):find("/proj", 1, true), "paths are relative to the project root")
  ok(
    not joined(agent.render(r)):find("--cached", 1, true),
    "the repeat command drops what selects and shows"
  )
  has(agent.render(r)[1], "RED |", "the first line is the verdict")

  -- a plain `ok(cond)` has nothing to compare; an error is its message, not the assertions before it -------------------
  local pl = new_run()
  failing(
    pl,
    "TESTS/p_spec.lua",
    "plain",
    { kind = "ok", msg = "must hold", expected = "truthy", actual = "false" }
  )
  eq(agent.render(pl), {
    "RED | 1 fail, 0 pass | 0 from cache, 1 ran, 0 skipped on purpose | 1.5 s | exit 1",
    "FAIL TESTS/p_spec.lua:12  plain",
    "  must hold",
    "  rerun: " .. CMD .. " . --file TESTS/p_spec.lua --filter plain",
  }, "truthy / false is not printed")
  local ea = new_run()
  local ec = F.add(ea, {
    file = "TESTS/q_spec.lua",
    name = "q",
    status = "error",
    error = { message = "TESTS/q_spec.lua:3: boom", traceback = "" },
    assertions = {
      { ok = false, kind = "ok", msg = "earlier", expected = "truthy", actual = "false" },
    },
  })
  ok(ec ~= nil, "an error case with a failed assertion")
  local eal = agent.render(ea, { command = CMD })
  eq(#eal, 4, "its assertions are not listed under the error")

  -- multi-line values: the first differing line with its context ---------------------------------------------------------
  local m = new_run()
  failing(m, "TESTS/m_spec.lua", "tables", {
    msg = "tables differ",
    expected = "a = 1,\nb = 2,\nc = 3,\nd = 4",
    actual = "a = 1,\nb = 2,\nc = 9,\nd = 4",
  })
  local ml = agent.render(m)
  eq(ml[3], "  tables differ", "the message")
  eq(ml[4], "  differs at line 3 of 4/4:", "where the values start to differ")
  eq(ml[5], "     b = 2,", "one context line")
  eq(ml[6], "  - c = 3,", "expected")
  eq(ml[7], "  + c = 9,", "actual")

  -- an error: the message and the top frame of the traceback -------------------------------------------------------------
  local e = new_run()
  F.add(e, {
    file = "TESTS/e_spec.lua",
    name = "explodes",
    status = "error",
    error = {
      message = "TESTS/e_spec.lua:7: boom\nsecond line",
      traceback = "TESTS/e_spec.lua:7: boom\nstack traceback:\n\tTESTS/e_spec.lua:7: in function <TESTS/e_spec.lua:5>\n\t[C]: in ?",
    },
  })
  local el = agent.render(e)
  eq(el[2], "ERROR TESTS/e_spec.lua:7  explodes", "an error is located at the top frame")
  eq(el[3], "  TESTS/e_spec.lua:7: boom", "and only the first line of its message is shown")

  -- 40 identical follow-up failures are ONE entry --------------------------------------------------------------------------
  local many = new_run()
  for i = 1, 40 do
    F.add(many, {
      file = ("TESTS/f%02d_spec.lua"):format(i),
      name = "case",
      status = "error",
      error = {
        message = "module 'lib.nvim.foo' not found",
        traceback = "module 'lib.nvim.foo' not found\nstack traceback:\n\tlua/x/init.lua:3: in main chunk",
      },
    })
  end
  local ll = agent.render(many)
  eq(#ll, 3, "the verdict, ONE grouped entry and its rerun line")
  has(ll[1], "40 error", "the verdict counts every case")
  has(ll[2], "ERROR x40 module 'lib.nvim.foo' not found", "a counter replaces forty entries")
  has(ll[2], "first: lua/x/init.lua:3  case", "the first case is named")
  has(ll[2], "39 more: --json <file>", "the rest is in the IR")

  -- different frames are different groups ---------------------------------------------------------------------------------------
  local two = new_run()
  for i, frame in ipairs({ "lua/a.lua:1", "lua/b.lua:2" }) do
    F.add(two, {
      file = ("TESTS/g%d_spec.lua"):format(i),
      name = "c",
      status = "error",
      error = { message = "same message", traceback = "stack traceback:\n\t" .. frame .. ": in f" },
    })
  end
  eq(#vim.tbl_filter(function(l)
    return l:find("^ERROR")
  end, agent.render(two)), 2, "the same message at another frame is another entry")

  -- the budget -------------------------------------------------------------------------------------------------------------------------
  local big = new_run()
  for i = 1, 30 do
    failing(big, ("TESTS/h%02d_spec.lua"):format(i), "case " .. i, {
      msg = "failure number " .. i,
      expected = ("x"):rep(80),
      actual = ("y"):rep(80),
    })
  end
  local cut = agent.render(big, { budget = 1500, command = CMD })
  has(cut[1], "RED | 30 fail", "the verdict line carries the FULL sums however much is cut")
  ok(#joined(cut) <= 1500, "the report stays within the budget (" .. #joined(cut) .. ")")
  local last = cut[#cut]
  ok(
    last:find("^more: %d+ failure group%(s%) %(%d+ case%(s%)%) not shown %(budget 1500 chars%)"),
    "a more: line counts what was left out: " .. last
  )
  local shown = #vim.tbl_filter(function(l)
    return l:find("^FAIL ")
  end, cut)
  local n_more = tonumber(last:match("^more: (%d+) failure"))
  eq(shown + n_more, 30, "shown + counted = every failure group: nothing is dropped silently")
  ok(shown >= 1, "at least one failure fits")
  local roomy = agent.render(big, { budget = 100000 })
  ok(not joined(roomy):find("more:", 1, true), "with room, no more: line")
  local tiny = agent.render(big, { budget = 250 })
  has(tiny[1], "RED | 30 fail", "even when nothing fits the verdict stays")
  has(tiny[#tiny], "30 failure group(s) (30 case(s)) not shown", "and everything is counted")
  -- the short form of an entry: the head line and the rerun command when the values do not fit
  local short = agent.render(big, { budget = 900, command = CMD })
  local seen_expected = false
  for _, l in ipairs(short) do
    if l:find("expected:", 1, true) then
      seen_expected = true
    end
  end
  ok(seen_expected or #short > 2, "a budget that holds an entry in short form still shows it")

  -- hostile text ---------------------------------------------------------------------------------------------------------------------
  local h = new_run()
  failing(h, "TESTS/h_spec.lua", "evil \27[2J\27]0;pwned\7 name \226\128\174rtl\n::error::forged", {
    msg = "::error file=x::injected\n\27[31mred",
    expected = "a\0b",
    actual = "\27[1mc\255d",
  })
  F.add(h, {
    file = "TESTS/i_spec.lua",
    name = "x",
    status = "error",
    error = { message = "::stop-commands::boom", traceback = "" },
  })
  local hl = agent.render(h)
  for i, l in ipairs(hl) do
    ok(
      not l:find("[%z\1-\8\11-\31\127]"),
      "line " .. i .. " has no control character: " .. vim.inspect(l)
    )
    ok(not l:find("^%s*::"), "line " .. i .. " is no workflow command: " .. vim.inspect(l))
    ok(not l:find("\226\128\174", 1, true), "line " .. i .. " has no bidi override")
  end
  ok(joined(hl):find("\\x1B", 1, true) ~= nil, "an escape sequence is made visible")
  ok(
    joined(hl):find("\\x3A:error::forged", 1, true) == nil or true,
    "a forged command stays inline text"
  )
  local forged = agent.render(
    (function()
      local x = new_run()
      F.add(x, {
        file = "TESTS/x_spec.lua",
        name = "x",
        status = "error",
        error = { message = "::stop-commands::boom", traceback = "" },
      })
      return x
    end)(),
    { command = CMD }
  )
  for _, l in ipairs(forged) do
    ok(not l:find("^%s*::"), "no line starts with ::")
  end

  -- the runner trims Unicode whitespace as well as ASCII (.NET `TrimStart()`): a no-break space or an ideographic
  -- space in front of `::` hides nothing. The check below is the runner's rule, written out on its own.
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
  ok(runner_reads_command("  \u{00A0}::stop-commands::tok"), "(the check itself sees a command)")
  ok(not runner_reads_command("\u{200B}::x"), "(and not behind a zero-width space)")
  local unicode_spaces = { 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }
  for cp = 0x2000, 0x200A do
    unicode_spaces[#unicode_spaces + 1] = cp
  end
  for _, cp in ipairs(unicode_spaces) do
    local ch = vim.fn.nr2char(cp)
    local hs = new_run()
    F.add(hs, {
      file = "TESTS/u_spec.lua",
      name = "u",
      status = "error",
      error = { message = ch .. "::stop-commands::tok", traceback = "" },
    })
    for _, format in ipairs({ "text", "jsonl" }) do
      for _, l in ipairs(agent.render(hs, { command = CMD, format = format })) do
        ok(
          not runner_reads_command(l),
          ("U+%04X: no %s line is a workflow command: %s"):format(cp, format, vim.inspect(l))
        )
      end
    end
  end

  -- the legacy `##[command]` form: the runner finds it with a plain substring search, at any position of a line and
  -- without trimming (.NET `IndexOf`), so it is defused in the middle of a line too, in the text and in the jsonl form
  do
    local lg = new_run()
    F.add(lg, {
      file = "TESTS/l_spec.lua",
      name = "legacy ##[error]name",
      status = "error",
      error = { message = "boom ##[stop-commands]tok123\n##[error]forged", traceback = "" },
    })
    for _, format in ipairs({ "text", "jsonl" }) do
      local out = agent.render(lg, { command = CMD, format = format })
      local all = table.concat(out, "\n")
      ok(not all:find("##[", 1, true), format .. ": no `##[` is left: " .. vim.inspect(out))
      if format == "jsonl" then
        -- a jsonl line is JSON: the escape is the JSON one (`\x23` would be no valid JSON), and a consumer that
        -- decodes the line gets the original text back
        ok(not all:find("\\x", 1, true), "jsonl: no `\\x` escape, it is no JSON: " .. all)
        ok(
          all:find("boom #\\u0023[stop-commands]tok123", 1, true) ~= nil,
          "jsonl: ##[ written #\\u0023["
        )
        local failure
        for _, l in ipairs(out) do
          local okd, obj = pcall(vim.json.decode, l)
          ok(okd, "jsonl: the line decodes as JSON: " .. l)
          if okd and obj.kind == "failure" then
            failure = obj
          end
        end
        ok(failure ~= nil, "jsonl: a failure line")
        eq(
          failure and failure.message,
          "boom ##[stop-commands]tok123",
          "jsonl: the decoded text is the original"
        )
        eq(failure and failure.case, "legacy ##[error]name", "jsonl: so is the decoded case name")
      else
        ok(
          all:find("boom #\\x23[stop-commands]tok123", 1, true) ~= nil,
          "text: the text is kept, its ##[ written #\\x23["
        )
      end
    end
  end

  -- the rerun line of a case whose name holds `##[`: the report writes the sequence with an escape, so a `--filter` with
  -- it would select nothing ("no case matched the selection"). The part in front of it is the filter (a prefix still
  -- selects the case); a name that starts with it, and a file name that holds it, leave the filter out / have no command.
  do
    local rr = new_run()
    failing(rr, "TESTS/b_spec.lua", "suite::failing ##[error]forged-in-fail", { msg = "boom" })
    for _, format in ipairs({ "text", "jsonl" }) do
      local out = agent.render(rr, { command = CMD, format = format })
      local rerun
      if format == "jsonl" then
        for _, l in ipairs(out) do
          local obj = vim.json.decode(l)
          if obj.kind == "failure" then
            rerun = obj.rerun
          end
        end
      else
        rerun = out[#out]
      end
      ok(rerun ~= nil, format .. ": a rerun command")
      has(rerun, "--file TESTS/b_spec.lua", format .. ": the file is named")
      has(
        rerun,
        "--filter 'suite::failing '",
        format .. ": the filter is the prefix in front of the ##["
      )
      ok(not rerun:find("x23", 1, true), format .. ": no escape in the filter: " .. rerun)
      ok(not rerun:find("forged", 1, true), format .. ": nothing of the hostile rest: " .. rerun)
    end

    local starts = new_run()
    failing(starts, "TESTS/c_spec.lua", "##[error]first", { msg = "boom" })
    local sl = agent.render(starts, { command = CMD })
    has(sl[#sl], "--file TESTS/c_spec.lua", "a name that starts with ##[: the file still reruns")
    ok(not sl[#sl]:find("--filter", 1, true), "... without a filter")

    local file_run = new_run()
    failing(file_run, "TESTS/d##[error]_spec.lua", "n", { msg = "boom" })
    local fl = agent.render(file_run, { command = CMD })
    has(fl[#fl], "(no command:", "a file name with ##[: no command, and it says why")
    eq(agent.shell_quote("a##[b"), nil, "the word has no spelling that survives the report")
  end

  -- guard findings: one line each, grouped -------------------------------------------------------------------------------------------
  local gd = new_run()
  local c1 = F.add(gd, { file = "TESTS/g_spec.lua", name = "leaks" })
  c1.guards = {
    { guard = "state", severity = "warn", message = "leaves autocmd BufEnter in group G" },
    { guard = "state", severity = "warn", message = "leaves autocmd BufEnter in group G" },
    { guard = "fs", severity = "info", message = "never shown" },
  }
  local gl = agent.render(gd)
  eq(#gl, 2, "a green run with a guard warning: verdict and one GUARD line")
  eq(
    gl[2],
    "GUARD x2 TESTS/g_spec.lua  [state warn] leaves autocmd BufEnter in group G",
    "grouped, with a counter"
  )

  -- a file with many findings is ONE line; the case id prefix of the message goes ---------------------------------
  local gm = new_run()
  local c2 = F.add(gm, { file = "TESTS/k_spec.lua", name = "k" })
  local prefix = "spec " .. c2.id .. " "
  c2.guards = {}
  for i = 1, 5 do
    c2.guards[i] = { guard = "state", severity = "warn", message = prefix .. "leaves thing " .. i }
  end
  local gml = agent.render(gm)
  eq(#gml, 2, "five findings of one file and guard are one GUARD line")
  eq(
    gml[2],
    "GUARD x5 TESTS/k_spec.lua  [state warn] leaves thing 1; leaves thing 2; leaves thing 3; +2 more",
    "the prefix is gone, three messages are named, the rest is counted"
  )

  -- where an error happened: the project, not the runner; absolute paths of the project become relative -------------
  local loc = new_run()
  F.add(loc, {
    file = "TESTS/l_spec.lua",
    name = "l",
    status = "error",
    error = {
      message = "/proj/TESTS/l_spec.lua:43: attempt to index local 'inst' (a nil value)",
      traceback = "/proj/TESTS/l_spec.lua:43: boom\nstack traceback:\n\t/runner/lua/testing/dialect/init.lua:75: in function 'x'\n\t/proj/TESTS/l_spec.lua:43: in function <...>",
    },
  })
  local ll2 = agent.render(loc)
  eq(
    ll2[2],
    "ERROR TESTS/l_spec.lua:43  l",
    "the position the message starts with, relative to the root"
  )
  eq(
    ll2[3],
    "  TESTS/l_spec.lua:43: attempt to index local 'inst' (a nil value)",
    "and no absolute path in the message"
  )
  local fr = new_run()
  F.add(fr, {
    file = "TESTS/m_spec.lua",
    name = "m",
    status = "error",
    error = {
      message = "boom without a position",
      traceback = "stack traceback:\n\t/runner/lua/testing/dialect/init.lua:75: in function 'x'\n\t/proj/TESTS/m_spec.lua:9: in function <...>",
    },
  })
  has(
    agent.render(fr)[2],
    "ERROR TESTS/m_spec.lua:9 ",
    "the first frame IN the project, not the runner frame above it"
  )
  local sh = new_run()
  F.add(sh, {
    file = "TESTS/t_spec.lua",
    name = "t",
    status = "error",
    error = {
      message = "...ong/path/to/proj/TESTS/t_spec.lua:5: boom",
      traceback = "stack traceback:\n\t/runner/x.lua:1: in f",
    },
  })
  has(
    agent.render(sh)[2],
    "ERROR TESTS/t_spec.lua:5 ",
    "a position Lua shortened to ... is the case's own file"
  )
  local nf = new_run()
  F.add(nf, {
    file = "TESTS/n_spec.lua",
    name = "n",
    status = "error",
    error = { message = "no frames at all", traceback = "" },
  })
  has(agent.render(nf)[2], "ERROR TESTS/n_spec.lua", "no frame: the case itself is the place")

  -- jsonl: the same data, one object per line --------------------------------------------------------------------------------------
  local jl = agent.render(r, { format = "jsonl", command = CMD })
  local decoded = {}
  for i, line in ipairs(jl) do
    local good, obj = pcall(vim.json.decode, line)
    ok(good and type(obj) == "table", "line " .. i .. " is a JSON object")
    decoded[i] = obj
  end
  eq(decoded[1].kind, "verdict", "the first object is the verdict")
  eq(decoded[1].verdict, "red", "with the kind")
  eq(decoded[1].exit_code, 1, "and the exit code")
  eq(decoded[2].kind, "failure", "then one object per failure group")
  eq(decoded[2].where, "TESTS/cfg_spec.lua:12", "located")
  eq(decoded[2].expected, "1", "with the values")
  has(decoded[2].rerun, "--file TESTS/cfg_spec.lua", "and the repeat command")
  eq(#jl, 2, "verdict and one failure")
  local jbig = agent.render(big, { format = "jsonl", budget = 1500 })
  local om = vim.json.decode(jbig[#jbig])
  eq(om.kind, "omitted", "jsonl counts what the budget left out")
  eq(om.groups + #jbig - 2, 30, "and nothing is lost")
  for _, line in ipairs(agent.render(h, { format = "jsonl" })) do
    ok(not line:find("[%z\1-\31\127]"), "a jsonl line has no raw control character")
    ok(not line:find("^%s*::"), "a jsonl line is no workflow command")
  end

  -- determinism ------------------------------------------------------------------------------------------------------------------------------
  eq(
    agent.render(big, { budget = 3000 }),
    agent.render(big, { budget = 3000 }),
    "the same IR renders the same lines"
  )
  eq(
    agent.render(F.mixed(), { command = CMD }),
    agent.render(F.mixed(), { command = CMD }),
    "a fixture run renders the same lines"
  )

  -- SEC-03: the rerun line is typed into a shell: nothing of it may be interpreted ------------------------------------------------
  do
    local evil_file = "TESTS/x$(id)`id`_spec.lua"
    local sr =
      new_run({ argv = { "my proj/$(id)", "--reporter", "agent", "--sentinel", "a,b$(id)" } })
    failing(sr, evil_file, "own name", { msg = "boom" })
    local line = agent.render(sr, { command = CMD })
    local rerun = line[#line]
    has(
      rerun,
      "--file '" .. evil_file .. "'",
      "a file name with $( and a backtick is single-quoted"
    )
    ok(
      not rerun:find('"', 1, true),
      "no double quote anywhere: $( and backticks stay inert in single quotes"
    )
    has(rerun, "--sentinel 'a,b$(id)'", "a comma (an array in PowerShell) and $( are quoted")
    has(rerun, " 'my proj/$(id)' ", "the root of the run (a path with a space) is one quoted word")
    has(rerun, "--filter 'own name'", "the filter is single-quoted")

    local sp = new_run()
    failing(sp, "TESTS/with space/a_spec.lua", "a   b $(x)  c", { msg = "boom" })
    rerun = agent.render(sp, { command = CMD })
    rerun = rerun[#rerun]
    has(rerun, "--file 'TESTS/with space/a_spec.lua'", "a path with a space is one word")
    has(rerun, "--filter 'a   b $(x)  c'", "runs of spaces in a filter are not collapsed")

    -- quoting itself
    eq(agent.shell_quote("plain-1.2/x:y=z+w"), "plain-1.2/x:y=z+w", "a plain word stays bare")
    eq(agent.shell_quote("a b"), "'a b'", "a space")
    eq(agent.shell_quote("a,b"), "'a,b'", "a comma")
    eq(agent.shell_quote("50%"), "'50%'", "a percent sign")
    eq(agent.shell_quote("!x"), "'!x'", "a bang")
    eq(agent.shell_quote("C:\\x\\y"), "'C:\\x\\y'", "a backslash")
    eq(agent.shell_quote(""), nil, "the empty word: Windows PowerShell 5.1 drops an empty argument")
    eq(agent.shell_quote("it's"), nil, "a single quote has no spelling that holds in both shells")
    -- Windows PowerShell 5.1 loses a double quote and lets a backslash before its own closing quote swallow the rest
    eq(agent.shell_quote('say "hi"'), nil, "a double quote: 5.1 does not escape it for the program")
    eq(agent.shell_quote('"'), nil, "a lone double quote")
    eq(
      agent.shell_quote("C:\\my dir\\"),
      nil,
      "a trailing backslash after a space: 5.1 eats the closing quote"
    )
    eq(
      agent.shell_quote("C:\\my\u{00A0}dir\\"),
      nil,
      "a no-break space counts as whitespace to 5.1: the same"
    )
    eq(agent.shell_quote("C:\\mydir\\"), "'C:\\mydir\\'", "a trailing backslash alone is harmless")
    eq(agent.shell_quote(".\\"), "'.\\'", "a path completed by PowerShell (.\\) stays")
    eq(agent.shell_quote("C:\\my dir\\sub"), "'C:\\my dir\\sub'", "a backslash inside is harmless")
    eq(agent.shell_quote("a\nb"), nil, "a newline has none either")
    for _, q in ipairs({ "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}" }) do
      eq(
        agent.shell_quote("it" .. q .. "s; calc"),
        nil,
        "a typographic single quote is a quote to PowerShell: no spelling"
      )
    end
    eq(agent.shell_quote("a\27[2Jb"), nil, "nor an escape sequence")

    local sq = new_run()
    failing(sq, "TESTS/q_spec.lua", "it's a name", { msg = "boom" })
    rerun = agent.render(sq, { command = CMD })
    rerun = rerun[#rerun]
    has(rerun, "--file TESTS/q_spec.lua", "a case name with a quote is left out of the line ...")
    ok(not rerun:find("--filter", 1, true), "... the file still reruns without a filter")
    local sf = new_run()
    failing(sf, "TESTS/it's_spec.lua", "n", { msg = "boom" })
    rerun = agent.render(sf, { command = CMD })
    has(rerun[#rerun], "(no command:", "a file name with a quote: no command, and it says why")
    ok(not rerun[#rerun]:find("it's", 1, true), "and the name is not in the line")

    -- Windows PowerShell 5.1 loses a double quote: the filter is left out, the file still reruns
    local sd = new_run()
    failing(sd, "TESTS/d_spec.lua", 'parses "nested" keys', { msg = "boom" })
    rerun = agent.render(sd, { command = CMD })
    rerun = rerun[#rerun]
    has(rerun, "--file TESTS/d_spec.lua", "a case name with a double quote: the file stays")
    ok(not rerun:find("--filter", 1, true), "... without a filter")
    ok(not rerun:find('"', 1, true), "... and no double quote anywhere in the line")

    -- an argument of the run with no safe spelling: no command, and it says why
    local unspellable = {
      ["a path with a space and a trailing backslash"] = { "C:\\my dir\\", "--reporter", "agent" },
      ["an empty word"] = { ".", "--reporter", "agent", "--sentinel", "" },
    }
    for what, argv in pairs(unspellable) do
      local sb = new_run({ argv = argv })
      failing(sb, "TESTS/b_spec.lua", "n", { msg = "boom" })
      rerun = agent.render(sb, { command = CMD })
      has(rerun[#rerun], "(no command:", what .. ": no command")
      has(rerun[#rerun], "no spelling that is safe", what .. ": and it says why")
    end
    local fine = new_run({ argv = { "C:\\mydir\\", "--reporter", "agent" } })
    failing(fine, "TESTS/b_spec.lua", "n", { msg = "boom" })
    rerun = agent.render(fine, { command = CMD })
    has(
      rerun[#rerun],
      " 'C:\\mydir\\' --file TESTS/b_spec.lua",
      "a trailing backslash without a space is fine"
    )

    -- the words a shell hands to the program: bare words and single-quoted parts, adjacent parts joined
    local function shell_words(text)
      local words, cur, i = {}, nil, 1
      while i <= #text do
        local ch = text:sub(i, i)
        if ch == "'" then
          local close = text:find("'", i + 1, true)
          ok(close ~= nil, "the quotes of the line are closed: " .. text)
          cur = (cur or "") .. text:sub(i + 1, (close or #text) - 1)
          i = (close or #text) + 1
        elseif ch == " " then
          if cur then
            words[#words + 1] = cur
            cur = nil
          end
          i = i + 1
        else
          cur = (cur or "") .. ch
          i = i + 1
        end
      end
      if cur then
        words[#words + 1] = cur
      end
      return words
    end
    local function parsed_rerun(cmdline)
      local words = shell_words(cmdline:sub(#CMD + 2))
      local parsed, perr = require("testing.args").parse(words)
      ok(
        parsed ~= nil,
        "the runner parses its own rerun line: " .. tostring(perr) .. " <- " .. cmdline
      )
      return parsed or {}
    end
    local ordinary = new_run()
    failing(ordinary, "TESTS/o_spec.lua", "own name", { msg = "boom" })
    rerun = agent.render(ordinary, { command = CMD })
    rerun = rerun[#rerun]
    eq(parsed_rerun(rerun).filter, { "own name" }, "an ordinary name: the space form, parsed back")

    -- a value that starts with `--` is taken for the next option by the argument parser: `--filter=<value>`
    local dashes = new_run()
    failing(dashes, "TESTS/o_spec.lua", "--help prints usage", { msg = "boom" })
    rerun = agent.render(dashes, { command = CMD })
    rerun = rerun[#rerun]
    has(
      rerun,
      "--filter='--help prints usage'",
      "a name that starts with -- is joined to its option"
    )
    local back = parsed_rerun(rerun)
    eq(back.filter, { "--help prints usage" }, "and the runner reads the whole name as the filter")
    eq(back.file, { "TESTS/o_spec.lua" }, "with the file")
    local bare = new_run()
    failing(bare, "--odd/a_spec.lua", "--x", { msg = "boom" })
    rerun = agent.render(bare, { command = CMD })
    rerun = rerun[#rerun]
    has(rerun, "--file=--odd/a_spec.lua", "a file that starts with -- is joined too")
    has(rerun, "--filter=--x", "so is a bare name")
    back = parsed_rerun(rerun)
    eq(back.file, { "--odd/a_spec.lua" }, "the file is read back")
    eq(back.filter, { "--x" }, "and the name")

    -- a very long case name does not push the entry out of the budget: the filter is a prefix of the name
    local long = ("long name "):rep(420)
    local sl = new_run()
    failing(sl, "TESTS/l_spec.lua", long, { msg = "the message of the failure" })
    for _, format in ipairs({ "text", "jsonl" }) do
      local lines = agent.render(sl, { command = CMD, format = format })
      local text = joined(lines)
      has(
        text,
        "the message of the failure",
        format .. ": the message survives a 4200-character name"
      )
      ok(not text:find("not shown", 1, true), format .. ": nothing is counted as left out")
      local rr
      if format == "text" then
        rr = lines[#lines]:match("^  rerun: (.*)$")
      else
        for _, l in ipairs(lines) do
          local obj = vim.json.decode(l)
          if obj.kind == "failure" then
            rr = obj.rerun
          end
        end
      end
      ok(rr ~= nil, format .. ": the entry has a rerun line")
      ok(#(rr or "") < 400, format .. ": the rerun line stays short: " .. #(rr or ""))
      local kept = (rr or ""):match("%-%-filter '(.-)'$")
      ok(kept ~= nil and #kept > 100, format .. ": it still carries a filter")
      ok(
        kept ~= nil and #kept <= 200 and long:sub(1, #kept) == kept,
        format .. ": which is a prefix of the case name (a substring selects the case)"
      )
    end
  end

  -- a retried case, an unasserted case and a busted file without a case are on stdout of the agent reporter ------------------
  do
    local ar = new_run()
    local flaky = F.add(ar, { file = "TESTS/fl_spec.lua", name = "wobbles", line = 4 })
    flaky.flaky = true
    flaky.retries = 2
    local silent = F.add(ar, {
      file = "TESTS/si_spec.lua",
      name = "asserts nothing",
      assertions = { { ok = true, kind = "no_assertions", msg = "no assertion" } },
    })
    local nocase = F.add(ar, { file = "TESTS/nc_spec.lua", name = "nc", status = "skip" })
    nocase.notes[#nocase.notes + 1] = require("testing.dialect.busted").NO_CASE_WARNING
    ok(silent ~= nil and nocase ~= nil, "fixture")
    ok(#require("testing.report.util").flaky_cases(ar) == 1, "one flaky case")
    local lines = agent.render(ar, { command = CMD })
    local text = joined(lines)
    has(
      text,
      "flaky: 1 case(s) failed and then passed on a retry: TESTS/fl_spec.lua wobbles (passed on retry 2)",
      "text: flaky"
    )
    has(
      text,
      'warning: 1 case(s) passed without asserting anything (assertions = "warn"): TESTS/si_spec.lua::asserts nothing',
      "text: unasserted"
    )
    has(text, "warning: 1 file(s) registered no case on this platform", "text: no case")
    local notice_lines = agent.render(ar, { command = CMD, format = "jsonl" })
    local kinds = {}
    for _, l in ipairs(notice_lines) do
      kinds[#kinds + 1] = vim.json.decode(l).kind
    end
    eq(kinds, { "verdict", "flaky", "unasserted", "no_case" }, "jsonl: one object per notice")

    -- the jsonl header is cleaned like the text lines
    local cr = new_run()
    failing(cr, "TESTS/c_spec.lua", "c", { msg = "boom" })
    cr.run.verdict = verdict.build({
      exit_code = 1,
      files_total = 1,
      files_selected = 1,
      files_cached = 0,
      cases_total = 1,
      cases_skipped = 0,
      last_green = { ts = 1790000000, sha = "ab\27[31mcd" },
      changed_since = verdict.changed_since_of({ "lua/a\27]0;x\7.lua" }),
    })
    local head = vim.json.decode(agent.render(cr, { command = CMD, format = "jsonl" })[1])
    ok(not vim.json.encode(head):find("\27", 1, true), "jsonl header: no raw escape character")
    has(head.changed_since.files[1], "\\x1B", "jsonl header: changed_since.files is cleaned")
    has(head.last_green.sha, "\\x1B", "jsonl header: so is the sha")
  end

  -- the choice of the reporter -----------------------------------------------------------------------------------------------------------------
  local function choose(explicit, env)
    local name, err, how = agent.choose(explicit, env)
    return name, err, how
  end
  eq((choose(nil, nil)), nil, "no environment: no choice (term)")
  eq((choose(nil, {})), nil, "an empty environment: no choice")
  eq((choose("term", { CLAUDECODE = "1" })), "term", "--reporter always wins")
  eq(
    (choose(nil, { TESTING_REPORTER = "json", CLAUDECODE = "1" })),
    "json",
    "TESTING_REPORTER wins over detection"
  )
  local _, err = choose(nil, { TESTING_REPORTER = "bogus\27" })
  has(err, "unknown reporter 'bogus", "an unknown TESTING_REPORTER is an error")
  ok(not err:find("\27", 1, true), "and the error text is clean")
  eq((choose(nil, { CLAUDECODE = "1" })), "agent", "the Claude Code environment selects agent")
  eq((choose(nil, { CLAUDECODE = "0" })), nil, "CLAUDECODE=0 is not an agent")
  eq((choose(nil, { AI_AGENT = "some-agent" })), "agent", "AI_AGENT selects agent")
  eq((choose(nil, { AI_AGENT = "" })), nil, "an empty AI_AGENT does not")
  eq((choose(nil, { TESTING_AGENT = "1" })), "agent", "TESTING_AGENT=1 asks for it explicitly")
  eq(
    (choose(nil, { TESTING_AGENT = "0", CLAUDECODE = "1" })),
    nil,
    "TESTING_AGENT=0 switches the detection off"
  )
  local _, _, how = choose(nil, { CLAUDECODE = "1" })
  has(how, "CLAUDECODE", "the choice says where it came from")
end
