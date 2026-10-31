-- TESTS/testing/sheet_spec.lua -- test sheets (testing.sheet): loading as data (empty environment),
-- the shape check with the field named, running steps in a REAL child (keys, wait, expect, screen per
-- size; the first failed step ends a size), and the report (testing.sheet.report): buckets, the
-- Markdown, a sheet that does not load, the CLI entry.
-- @cache-allow time
-- (the clock only bounds how long a wait step may take; it decides nothing else)
---@diagnostic disable: missing-fields
-- (the report tests build entries, cases and states with only the fields under test)

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
      msg .. " (got " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end
  local sheet = require("testing.sheet")
  local report = require("testing.sheet.report")
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/child/support.lua")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-sheets"
  vim.fn.mkdir(root .. "/TESTS/sheets", "p")

  local function write(rel, text)
    local p = root .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb"))
    f:write(text)
    f:close()
    return p
  end
  local function refused(tbl, needle, msg)
    local s, err = sheet.validate(tbl)
    ok(
      s == nil and tostring(err):find(needle, 1, true) ~= nil,
      msg .. " (got " .. tostring(err) .. ")"
    )
  end

  local body_ok, body_err = xpcall(function()
    -- ===================================================================
    -- 1. shape
    do
      local s = assert(sheet.validate({ id = "a.b", title = "T", steps = { { keys = "x" } } }))
      eq(
        { s.engine, s.sizes, s.judge, s.manual },
        { "rpc", { { rows = 24, cols = 80 } }, {}, {} },
        "defaults"
      )
      refused({ title = "T", steps = { { keys = "x" } } }, "id", "id is required")
      refused({ id = "a/b", title = "T", steps = { { keys = "x" } } }, "id", "id with a slash")
      refused({ id = "a", steps = { { keys = "x" } } }, "title", "title is required")
      refused(
        { id = "a", title = "T", steps = { { keys = "x" } }, colour = 1 },
        "unknown field colour",
        "an unknown field is named"
      )
      refused(
        { id = "a", title = "T", engine = "vnc", steps = { { keys = "x" } } },
        "engine",
        "an unknown engine"
      )
      refused({ id = "a", title = "T" }, "needs steps", "an rpc sheet without steps")
      refused(
        { id = "a", title = "T", steps = { { keys = "x", lua = "y" } } },
        "two actions",
        "two actions in one step"
      )
      refused(
        { id = "a", title = "T", steps = { { note = "n" } } },
        "no action",
        "a step without an action"
      )
      refused(
        { id = "a", title = "T", steps = { { settle = 0 } } },
        "milliseconds must be a whole number",
        "settle 0"
      )
      refused(
        { id = "a", title = "T", steps = { { keys = "x", timeout = 5 } } },
        "timeout belongs",
        "timeout outside wait"
      )
      refused(
        { id = "a", title = "T", steps = { { keys = "x", masks = {} } } },
        "belong to a screen",
        "masks outside screen"
      )
      refused(
        { id = "a", title = "T", steps = { { screen = "a b" } } },
        "steps[1].screen",
        "a bad snapshot name"
      )
      refused(
        { id = "a", title = "T", steps = { { keyz = "x" } } },
        "steps[1]: unknown field keyz",
        "an unknown step field"
      )
      refused(
        { id = "a", title = "T", steps = { { keys = "x" } }, sizes = { { rows = 0, cols = 80 } } },
        "sizes[1]",
        "a bad size"
      )
      refused(
        { id = "a", title = "T", engine = "manual" },
        "manual steps",
        "a manual sheet without manual steps"
      )
      refused(
        { id = "a", title = "T", engine = "manual", manual = { "x" }, steps = { { keys = "x" } } },
        "no steps",
        "a manual sheet with steps"
      )
      refused(
        { id = "a", title = "T", steps = { { keys = "x" } }, judge = { "" } },
        "judge[1]",
        "an empty judge entry"
      )
      -- a list with a hole: `#` and the key count agree, ipairs sees nothing (review 2026-10-31)
      refused(
        { id = "a", title = "T", steps = { nil, { bogus = 1 }, x = 1 } },
        "steps must be a list",
        "steps with a hole"
      )
      refused({
        id = "a",
        title = "T",
        steps = { { keys = "x" } },
        sizes = { nil, { rows = 1, cols = 1 }, y = 1 },
      }, "sizes must be", "sizes with a hole")
      -- upper bounds: an endless wait is a mistake
      refused(
        { id = "a", title = "T", steps = { { wait = "x", timeout = 1 / 0 } } },
        "milliseconds",
        "timeout = inf"
      )
      refused(
        { id = "a", title = "T", steps = { { settle = 1 / 0 } } },
        "milliseconds",
        "settle = inf"
      )
      refused({
        id = "a",
        title = "T",
        steps = { { keys = "x" } },
        sizes = { { rows = 1e12, cols = 80 } },
      }, "sizes[1]", "a billion rows")
      refused(
        { id = "a", title = "T", steps = { { lua = "x", ignore_errmsg = true } } },
        "ignore_errmsg belongs",
        "ignore_errmsg outside keys"
      )
    end

    -- loading is data only: the file sees no globals
    do
      local p = write(
        "TESTS/sheets/data.sheet.lua",
        'return { id = "d", title = "D", engine = "manual", manual = { "look" } }'
      )
      local s = assert(sheet.load(p))
      eq({ s.id, s.engine, s.path }, { "d", "manual", p }, "a sheet loads")
      local evil = write("TESTS/sheets/evil.sheet.lua", "os.exit(1) return {}")
      local es, eerr = sheet.load(evil)
      ok(
        es == nil and tostring(eerr):find("os", 1, true) ~= nil,
        "a sheet cannot call os (empty environment): " .. tostring(eerr)
      )
      local _, n_path = tostring(eerr):gsub(vim.pesc(vim.fs.basename(evil)), "")
      eq(n_path, 1, "the path is named once in a load error, not twice")
      local bad = write("TESTS/sheets/bad.sheet.lua", "return { id = ")
      ok(sheet.load(bad) == nil, "a syntax error is refused")
      eq(#sheet.files(root .. "/TESTS/sheets"), 3, "files finds *.sheet.lua")
      eq(sheet.spec_name(s), "sheet:d", "the case name")
      local m = sheet.run(s)
      eq({ m.ok, m.status }, { true, "manual" }, "a manual sheet runs nothing")
    end

    -- ===================================================================
    -- 2. run in a real child
    do
      local good = assert(sheet.validate({
        id = "demo",
        title = "demo",
        minit = S.minit,
        sizes = { { rows = 24, cols = 80 }, { rows = 12, cols = 40 } },
        steps = {
          { lua = "vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'two' })" },
          { keys = "jdd", note = "delete line two" },
          { wait = "vim.api.nvim_buf_line_count(0) == 1", timeout = 3000 },
          { expect = "vim.api.nvim_get_current_line() == 'one'", note = "line one stays" },
          { screen = "buf", masks = { { row = 24 }, { row = 12 } } },
        },
      }))
      good.path = root .. "/TESTS/sheets/demo.sheet.lua"
      local res = sheet.run(good, { root = root, ci = false, update = false })
      eq({ res.ok, res.status, res.failures }, { true, "pass", {} }, "all steps pass in both sizes")
      eq(#res.snapshots, 2, "one screen step per size")
      ok(
        vim.uv.fs_stat(root .. "/TESTS/__snapshots__/sheets/demo.sheet/buf.80x24.snap") ~= nil,
        "snapshot named with the size (80x24)"
      )
      ok(
        vim.uv.fs_stat(root .. "/TESTS/__snapshots__/sheets/demo.sheet/buf.40x12.snap") ~= nil,
        "and 40x12"
      )
      eq(
        sheet.run(good, { root = root, ci = true, update = false }).status,
        "pass",
        "the second run matches, also on CI"
      )

      local bad = vim.deepcopy(good)
      bad.sizes = { { rows = 24, cols = 80 } }
      bad.steps[4] = { expect = "vim.api.nvim_get_current_line() == 'two'", note = "wrong line" }
      bad.steps[6] = { keys = "never" }
      -- expect runs it once: the verdict goes to the harness, the result comes back
      local got
      local _, br = sheet.expect(function(v, msg)
        got = { v, msg }
      end, bad, { root = root, ci = false, update = false })
      eq(got[1], false, "expect hands false to the harness")
      ---@cast br Testing.Sheet.Result
      eq({ br.ok, br.status }, { false, "fail" }, "a false expectation fails")
      eq(#br.failures, 1, "the first failed step ends the size")
      has(br.failures[1], "80x24 step 4, wrong line", "the failure names size, step and note")
      has(br.failures[1], "got false", "and what the child said")
      eq(#br.snapshots, 0, "no step after the failure ran")

      local slow = vim.deepcopy(good)
      slow.sizes = { { rows = 24, cols = 80 } }
      slow.steps = { { keys = ":NoSuchCommandHere<CR>" }, { wait = "false", timeout = 100 } }
      has(
        sheet.run(slow, { root = root }).failures[1],
        "the keys caused an error: E492",
        "keys that raise an error message fail the step (feed itself does not raise)"
      )
      slow.steps = { { wait = "false", timeout = 100 } }
      -- two sizes, two failures: they must still be one line
      slow.sizes = { { rows = 24, cols = 80 }, { rows = 12, cols = 40 } }
      local t0 = vim.uv.hrtime()
      local raised, err = pcall(sheet.check, slow, { root = root })
      local took_ms = (vim.uv.hrtime() - t0) / 1e6
      -- (a poll inside vim.wait's condition once kept the 100 ms wait going for 40 s)
      ok(
        took_ms < 10000,
        ("a 100 ms wait keeps its deadline (took %d ms with the child)"):format(took_ms)
      )
      ok(
        not raised and tostring(err):find("test sheet demo failed", 1, true) ~= nil,
        "check raises with the failures"
      )
      has(
        tostring(err),
        "failed: 80x24 step 1, wait false",
        "the first failure is on the first line"
      )
      ok(
        not tostring(err):find("\n", 1, true),
        "one line: the state and the report keep only the first"
      )
      has(tostring(err), "; 40x12 step 1, wait false", "the second failure follows on that line")
      has(tostring(err), "still false after 100 ms", "a wait that never holds")

      -- a multi-line step and a multi-line reason: every step and its reason stay on the first line
      local long = vim.deepcopy(slow)
      long.sizes = { { rows = 24, cols = 80 } }
      long.steps = {
        {
          wait = "false\n or false\n or (1 == 2 and 'a long expression that goes on and on' == 'x')",
          timeout = 100,
        },
      }
      local _, long_err = pcall(sheet.check, long, { root = root })
      local first_line = tostring(long_err):match("^[^\n]*")
      has(
        first_line,
        "still false after 100 ms",
        "the reason of a multi-line step is on the first line"
      )
      has(first_line, "...", "a long step is cut")
      local fake = { id = "f", title = "F", steps = {} }
      local multi = {
        ok = false,
        failures = {
          "80x24 step 2, screen x: differs:\n  - a\n  + b",
          "40x12 step 1, wait y: still false",
        },
      }
      -- the cut is by character: half a multi-byte character would be invalid UTF-8 (JUnit XML)
      local cut = sheet._describe({ wait = ("x"):rep(55) .. "漢字漢字漢字" })
      eq(
        cut,
        "wait " .. ("x"):rep(55) .. "漢字...",
        "cut after the 57th character, never inside one"
      )
      eq(
        sheet._describe({ keys = "a", note = "two\nlines" }),
        "two lines (keys a)",
        "a multi-line note is one line too"
      )
      local ft = sheet._failed_text(fake, multi)
      eq(
        ft:match("^[^\n]*"),
        "test sheet f failed: 80x24 step 2, screen x: differs:; 40x12 step 1, wait y: still false",
        "both failures on the first line"
      )
      has(ft, "\n  - a\n  + b", "the diff follows below")

      -- ignore_errmsg: a mapping that runs `silent! cmd` on purpose still sets v:errmsg
      local quiet = vim.deepcopy(slow)
      quiet.sizes = { { rows = 24, cols = 80 } }
      quiet.steps = { { keys = ":silent! NoSuchCommandHere<CR>", ignore_errmsg = true } }
      eq(sheet.run(quiet, { root = root }).failures, {}, "ignore_errmsg lets such keys pass")

      -- a spawn that raises, and where the minit points: through a stand-in spawn
      local rpc = require("testing.rpc")
      local orig_spawn = rpc.spawn
      local seen_minit
      local stand_ok, stand_err = pcall(function()
        rpc.spawn = function()
          error("boom from spawn")
        end
        local verdict
        local _, raised_res = sheet.expect(function(v)
          verdict = v
        end, quiet, { root = root })
        eq(verdict, false, "a spawn that raises still hands a verdict to the harness")
        has(raised_res.failures[1], "the child did not start", "and is a failure of that size")
        has(raised_res.failures[1], "boom from spawn", "with the reason")
        rpc.spawn = function(o)
          seen_minit = o.minit
          return nil, "not started"
        end
        local unc = vim.deepcopy(quiet)
        unc.minit = "\\\\server\\share\\init.lua"
        sheet.run(unc, { root = root })
        eq(seen_minit, "\\\\server\\share\\init.lua", "a UNC minit with backslashes is absolute")
      end)
      rpc.spawn = orig_spawn
      ok(stand_ok, "stand-in spawn checks: " .. tostring(stand_err))
      local lr, lerr = pcall(sheet.check, root .. "/TESTS/sheets/bad.sheet.lua")
      ok(
        not lr and tostring(lerr):find("test sheet:", 1, true) ~= nil,
        "check of a sheet that does not load raises"
      )
    end

    -- ===================================================================
    -- 3. report
    do
      local entries = report.collect({ root }, { states = { [root] = { cases = {}, files = {} } } })
      eq(#entries, 3, "every sheet file is an entry")
      local by = {}
      for _, e in ipairs(entries) do
        by[e.rel] = e
      end
      eq(report.bucket(by["TESTS/sheets/data.sheet.lua"]), "manual", "a manual sheet")
      eq(report.bucket(by["TESTS/sheets/bad.sheet.lua"]), "red", "a sheet that does not load")
      ok(by["TESTS/sheets/evil.sheet.lua"].error ~= nil, "its reason is kept")

      local function sh(extra)
        return assert(
          sheet.validate(
            vim.tbl_extend(
              "force",
              { id = "x", title = "X", steps = { { keys = "a" } } },
              extra or {}
            )
          )
        )
      end
      local pass = { status = "pass", file = "TESTS/sheets_spec.lua", duration_ms = 12 }
      eq(report.bucket({ sheet = sh(), snapshots = {} }), "red", "never ran")
      eq(
        report.bucket({ sheet = sh(), case = { status = "fail" }, snapshots = {} }),
        "red",
        "red case"
      )
      eq(
        report.bucket({ sheet = sh(), case = pass, stale = "changed", snapshots = {} }),
        "red",
        "stale result"
      )
      eq(
        report.bucket({ sheet = sh(), case = pass, snapshots = {} }),
        "automated",
        "green, nothing left"
      )
      eq(
        report.bucket({ sheet = sh({ judge = { "reads well" } }), case = pass, snapshots = {} }),
        "inbox",
        "green with judge"
      )
      eq(
        report.bucket({ sheet = sh({ manual = { "press" } }), case = pass, snapshots = {} }),
        "manual",
        "green with manual steps"
      )

      local md = report.render({
        {
          root = root,
          rel = "TESTS/sheets/a.sheet.lua",
          sheet = sh({ id = "a", title = "Alpha", task = "ui.nvim/t", judge = { "reads well" } }),
          case = pass,
          snapshots = { "TESTS/__snapshots__/sheets/a.sheet/f.80x24.snap" },
        },
        {
          root = root,
          rel = "TESTS/sheets/b.sheet.lua",
          sheet = sh({ id = "b", title = "Beta" }),
          case = { status = "fail", message = "boom" },
          snapshots = {},
        },
        {
          root = root,
          rel = "TESTS/sheets/c.sheet.lua",
          sheet = sh({ id = "c", title = "Gamma" }),
          case = pass,
          snapshots = {},
        },
      }, { date = "2026-10-31" })
      has(
        md,
        "on 2026-10-31 from 3 sheet(s): 1 red or not run, 1 to review, 0 manual, 1 automated",
        "the summary line"
      )
      has(
        md,
        "## Review inbox (1)\n\n- [ ] **Alpha** (`a`, task `ui.nvim/t`)",
        "inbox entry with task"
      )
      has(md, "    - [ ] reads well", "the judge criteria are checkboxes")
      has(
        md,
        "look at: `TESTS/__snapshots__/sheets/a.sheet/f.80x24.snap`",
        "and the snapshot to look at"
      )
      has(md, "- `fail`: boom", "a red entry says why")
      has(md, "## Manual (0)\n\n(none)", "an empty section says so")
      has(md, "## Automated (1)", "the automated section")
      -- two projects: entries and snapshot paths name their project
      local two = report.render({
        {
          root = root .. "/projA",
          rel = "TESTS/sheets/a.sheet.lua",
          sheet = sh({ id = "a", title = "Alpha", judge = { "ok" } }),
          case = pass,
          snapshots = { "TESTS/__snapshots__/sheets/a.sheet/f.80x24.snap" },
        },
        {
          root = root .. "/projB",
          rel = "TESTS/sheets/b.sheet.lua",
          sheet = sh({ id = "b", title = "B" }),
          case = pass,
          snapshots = {},
        },
      })
      has(two, "`projA/TESTS/sheets/a.sheet.lua`", "the entry names its project")
      has(
        two,
        "look at: `projA/TESTS/__snapshots__/sheets/a.sheet/f.80x24.snap`",
        "and so do its snapshots"
      )

      local outs, errs = {}, {}
      local sv = {
        out = function(s)
          outs[#outs + 1] = s
        end,
        err = function(s)
          errs[#errs + 1] = s
        end,
      }
      eq(report.main({ "nope" }, sv), 2, "an unknown subcommand is bad usage")
      eq(report.main({ "report", "--bogus" }, sv), 2, "an unknown option is bad usage")
      -- --from: the result of a run that did not write the editor's state (scripts/test.sh)
      local root2 = root .. "/p2"
      write(
        "p2/TESTS/sheets/auto.sheet.lua",
        'return { id = "auto", title = "Auto", steps = { { keys = "x" } } }'
      )
      write(
        "p2/TESTS/sheets/red.sheet.lua",
        'return { id = "red", title = "Red", steps = { { keys = "x" } } }'
      )
      local ir = write(
        "ir.json",
        vim.json.encode({
          schema_version = 1,
          cases = {
            {
              id = "TESTS/s_spec.lua::sheet:auto",
              file = "TESTS/s_spec.lua",
              name = "sheet:auto",
              status = "pass",
              duration_ms = 5,
              assertions = { { ok = true } },
            },
            {
              id = "TESTS/s_spec.lua::sheet:red",
              file = "TESTS/s_spec.lua",
              name = "sheet:red",
              status = "fail",
              duration_ms = 5,
              assertions = { { ok = false, msg = "boom\nsecond line" } },
            },
          },
        })
      )
      local cases = assert(report.cases_from_ir(ir))
      eq(
        { cases["sheet:auto"].status, cases["sheet:red"].message },
        { "pass", "boom" },
        "IR cases by name, first line of the first failure"
      )
      local from_entries = report.collect({ root2 }, { cases = cases })
      eq(
        vim.tbl_map(report.bucket, from_entries),
        { "automated", "red" },
        "the IR decides the buckets"
      )
      ok(report.cases_from_ir(root .. "/nope.json") == nil, "an unreadable IR is refused")
      write("notir.json", "[1, 2]")
      ok(report.cases_from_ir(root .. "/notir.json") == nil, "JSON without cases is refused")
      eq(
        report.main({ "report", root2, "--from", root .. "/nope.json" }, sv),
        2,
        "--from an unreadable file is bad usage"
      )
      local out2 = root .. "/out/from.md"
      eq(
        report.main({ "report", root2, "--from", ir, "--out", out2 }, sv),
        0,
        "--from writes the list"
      )
      local f2 = assert(io.open(out2, "rb"))
      local from_md = f2:read("*a")
      f2:close()
      has(from_md, "## Automated (1)", "the IR's green case is automated")
      has(from_md, "- `fail`: boom", "and its red case says why")

      -- a sheet written after the run makes the result stale (the state watches only the spec file)
      local root3 = root .. "/p3"
      write("p3/TESTS/s_spec.lua", "-- spec")
      write(
        "p3/TESTS/sheets/z.sheet.lua",
        'return { id = "z", title = "Z", steps = { { keys = "x" } } }'
      )
      local state = require("testing.state")
      local rec = assert(state.stat(root3, "TESTS/s_spec.lua"))
      local function st_with(ts)
        rec.ts = ts
        return {
          root = root3,
          files = { ["TESTS/s_spec.lua"] = rec },
          cases = {
            { name = "sheet:z", status = "pass", file = "TESTS/s_spec.lua", duration_ms = 1 },
          },
        }
      end
      local old = report.collect({ root3 }, { states = { [root3] = st_with(1) } })[1]
      has(old.stale, "z.sheet.lua changed since the run", "a sheet newer than the run is stale")
      eq(report.bucket(old), "red", "and not green")
      local fresh = report.collect({ root3 }, { states = { [root3] = st_with(4102444000) } })[1]
      eq(
        { fresh.stale, report.bucket(fresh) },
        { nil, "automated" },
        "a run after the sheet is current"
      )

      -- text from a sheet stays on its line and inside its code span
      local tricky = report.render({
        {
          root = root,
          rel = "TESTS/sheets/t.sheet.lua",
          sheet = sh({ id = "t", title = "T `x`\n# H", task = "a`b", judge = { "a\n- [x] fake" } }),
          case = pass,
          snapshots = {},
        },
      })
      ok(not tricky:find("\n# H", 1, true), "a newline in a title starts no heading")
      ok(
        not tricky:find("\n- [x] fake", 1, true),
        "a newline in a criterion starts no checked item"
      )
      has(tricky, "task `a'b`", "a backtick cannot end the code span")

      local out_file = root .. "/out/list.md"
      eq(report.main({ "report", root, "--out", out_file }, sv), 0, "report writes the file")
      local f = assert(io.open(out_file, "rb"))
      local written = f:read("*a")
      f:close()
      has(written, "## Red, stale or not run", "the written list")
    end
  end, debug.traceback)

  S.cleanup()
  vim.fn.delete(root, "rf")
  ok(body_ok, "sheet spec body: " .. tostring(body_err))
end
