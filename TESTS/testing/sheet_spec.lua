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

    -- ===================================================================
    -- 4. the state written into the tasks (testing.sheet.tasks), through a stand-in engine
    do
      local tasks = require("testing.sheet.tasks")
      local body = "Summary.\n\n## Kontext\n\nWhy.\n\n## Notizen\n\n- a note"
      local block = tasks.render_block({
        {
          root = root .. "/p4",
          rel = "TESTS/sheets/one.sheet.lua",
          sheet = assert(sheet.validate({
            id = "one",
            title = "One",
            task = "a/one",
            steps = { { keys = "x" } },
            judge = { "looks ok" },
            manual = { "press it" },
          })),
          case = { status = "pass" },
          snapshots = { "TESTS/__snapshots__/sheets/one.sheet/s.80x24.snap" },
        },
      })
      has(block, tasks.BEGIN, "the block has its begin marker")
      has(
        block,
        "- **One** (`one`, `p4/TESTS/sheets/one.sheet.lua`): automated part green, waiting for your judgement",
        "the state"
      )
      has(block, "    - [ ] looks ok", "judge criteria are checkboxes")
      has(block, "    - [ ] press it", "manual steps too")
      has(
        block,
        "Look at: `p4/TESTS/__snapshots__/sheets/one.sheet/s.80x24.snap`",
        "and the snapshots"
      )
      local placed = tasks.apply(body, block)
      ok(
        placed:find(tasks.END .. "\n\n## Notizen", 1, true) ~= nil,
        "the block goes in front of the notes"
      )
      has(placed, "## Kontext\n\nWhy.\n\n" .. tasks.BEGIN, "after the other sections")
      local again = tasks.apply(placed, block:gsub("looks ok", "changed"))
      local _, n_blocks = again:gsub(vim.pesc(tasks.BEGIN), "")
      eq(n_blocks, 1, "a second write replaces the block, it does not add one")
      has(again, "- [ ] changed", "with the new text")
      has(
        tasks.apply("No notes here.", block),
        "No notes here.\n\n" .. tasks.BEGIN,
        "without notes: at the end"
      )
      eq(
        tasks.ticked("- [x] looks ok\n  - [X] other\n- [ ] open"),
        { ["looks ok"] = true, other = true },
        "ticked boxes"
      )
      eq(
        tasks.ticked("- [x] looks ok   "),
        { ["looks ok"] = true },
        "trailing blanks do not lose the tick"
      )

      -- markers: only a line of its own outside code counts; a broken pair is never written over (review 18e4837)
      local orphan = "Prose.\n" .. tasks.BEGIN .. "\nKeep me 1\nKeep me 2\n\n## Notizen\n- n"
      local o_new, o_err = tasks.apply(orphan, block)
      ok(
        o_new == nil and tostring(o_err):find("markers", 1, true) ~= nil,
        "a begin without its end is refused"
      )
      local reversed = "A\n" .. tasks.END .. "\nB\n" .. tasks.BEGIN .. "\nC"
      ok(tasks.apply(reversed, block) == nil, "an end in front of the begin is refused")
      local quoted = "The markers `"
        .. tasks.BEGIN
        .. "` and `"
        .. tasks.END
        .. "` are named here.\n\n## Notizen\n- n"
      local q_new = assert(tasks.apply(quoted, block))
      has(q_new, "are named here.", "markers quoted in prose are text and stay")
      has(q_new, tasks.END .. "\n\n## Notizen", "and the block goes in front of the notes")
      local fenced_body = "intro\n```\n## Notizen\n```\nmore\n\n## Notizen\n- n"
      local f_new = assert(tasks.apply(fenced_body, block))
      has(
        f_new,
        "```\n## Notizen\n```\nmore\n\n" .. tasks.BEGIN,
        "a heading inside a code fence is not the notes"
      )
      local spaced = assert(tasks.apply("x\n\n## Notizen  \n- n", block))
      has(spaced, tasks.END .. "\n\n## Notizen  ", "a notes heading with trailing blanks is found")
      local in_code = "x\n```\n" .. tasks.BEGIN .. "\n```\n\n## Notizen"
      has(
        assert(tasks.apply(in_code, block)),
        "```\n" .. tasks.BEGIN .. "\n```",
        "a marker inside code is text"
      )

      -- batches: at most 100 operations and about 200 KiB per request
      local many = {}
      for k = 1, 101 do
        many[k] = { op = "set_body", id = "a/t" .. k, body = "x" }
      end
      local groups = tasks._batches(many)
      eq({ #groups, #groups[1], #groups[2] }, { 2, 100, 1 }, "101 operations go out as 100 and 1")
      local big = {}
      for k = 1, 3 do
        big[k] = { op = "set_body", id = "a/b" .. k, body = ("y"):rep(95000) }
      end
      local bgroups = tasks._batches(big)
      eq(#bgroups, 2, "three 95 KB bodies go out in two requests")
      for _, g in ipairs(bgroups) do
        local chunk = {}
        for _, k in ipairs(g) do
          chunk[#chunk + 1] = big[k]
        end
        ok(#vim.json.encode({ ops = chunk }) < 256 * 1024, "each request stays below 256 KiB")
      end

      -- sync through a stand-in for `tasks call`
      write(
        "p4/TESTS/sheets/one.sheet.lua",
        'return { id = "one", title = "One", task = "a/one", steps = { { keys = "x" } }, judge = { "looks ok" } }'
      )
      write(
        "p4/TESTS/sheets/two.sheet.lua",
        'return { id = "two", title = "Two", task = "a/gone", steps = { { keys = "x" } } }'
      )
      write(
        "p4/TESTS/sheets/three.sheet.lua",
        'return { id = "three", title = "Three", steps = { { keys = "x" } } }'
      )
      local root4 = root .. "/p4"
      local cases4 =
        { ["sheet:one"] = { name = "sheet:one", status = "pass", file = "TESTS/s_spec.lua" } }
      local calls, current = {}, body
      local function engine(answer_ops)
        return function(method, params)
          calls[#calls + 1] = { method = method, params = params }
          if method == "bodies" then
            return {
              kind = "tasks.bodies",
              items = { { id = "a/one", etag = "sha256:1", body = current } },
            }
          end
          return answer_ops(params)
        end
      end
      local accept = function(params)
        current = params.ops[1].body
        return { kind = "tasks.result", results = { { n = 1, ok = true, outcome = "changed" } } }
      end
      local entries = report.collect({ root4 }, { cases = cases4 })
      local results = assert(tasks.sync(entries, { call = engine(accept), multi = false }))
      local by = {}
      for _, r in ipairs(results) do
        by[r.id] = r.outcome
      end
      eq(
        by,
        { ["a/one"] = "changed", ["a/gone"] = "missing" },
        "one task changed, one is not open; a sheet without task is left out"
      )
      eq(calls[1].params.ids, { "a/gone", "a/one" }, "one bodies call for all tasks")
      local op = calls[2].params.ops[1]
      eq(
        { op.op, op.id, op.if_match },
        { "set_body", "a/one", "sha256:1" },
        "one set_body with the etag that was read"
      )
      has(op.body, "- [ ] looks ok", "the block is in the body written")
      ok(
        vim.iter(entries):any(function(e)
          return e.task_missing
        end),
        "the entry of the missing task is marked"
      )

      -- a ticked criterion stays ticked, and the same state is unchanged
      current = current:gsub("%- %[ %] looks ok", "- [x] looks ok")
      calls = {}
      local again_results = assert(
        tasks.sync(
          report.collect({ root4 }, { cases = cases4 }),
          { call = engine(accept), multi = false }
        )
      )
      eq(again_results[2].outcome, "unchanged", "nothing new: unchanged, and the tick is kept")
      eq(#calls, 1, "no ops call when nothing changed")

      -- a dry run writes nothing; a refused write is a failure with the reason
      current = body
      calls = {}
      local dry = assert(
        tasks.sync(
          report.collect({ root4 }, { cases = cases4 }),
          { call = engine(accept), dry_run = true }
        )
      )
      eq(dry[2].outcome, "would_change", "a dry run says what would change")
      eq(#calls, 1, "and sends no ops")
      local refuse = function()
        return {
          kind = "tasks.result",
          results = { { n = 1, ok = false, error = { code = "conflict", message = "stale" } } },
        }
      end
      local refused_r =
        assert(tasks.sync(report.collect({ root4 }, { cases = cases4 }), { call = engine(refuse) }))
      eq(
        { refused_r[2].outcome, refused_r[2].message },
        { "failed", "conflict: stale" },
        "a conflict is a failure with its reason"
      )
      local nobody = function()
        return nil, "engine down"
      end
      ok(
        tasks.sync(entries, { call = nobody }) == nil,
        "an engine that cannot be reached is an error of the whole sync"
      )

      -- a CRLF body: no carriage return goes back (set_body refuses it)
      current = body:gsub("\n", "\r\n")
      calls = {}
      assert(tasks.sync(report.collect({ root4 }, { cases = cases4 }), { call = engine(accept) }))
      ok(
        not calls[2].params.ops[1].body:find("\r", 1, true),
        "a CRLF body is written with line feeds"
      )

      -- broken markers in a task: reported, nothing written
      current = "Text\n" .. tasks.BEGIN .. "\nkeep\n\n## Notizen"
      calls = {}
      local broken =
        assert(tasks.sync(report.collect({ root4 }, { cases = cases4 }), { call = engine(accept) }))
      eq(broken[2].outcome, "failed", "a task with broken markers is a failure")
      eq(#calls, 1, "and is not written")

      -- the bodies page ends at 2 MiB: the ids that did not come back are asked again
      local paged = {}
      for k = 1, 4 do
        paged[k] = {
          root = root4,
          rel = "TESTS/sheets/p" .. k .. ".sheet.lua",
          sheet = assert(
            sheet.validate({
              id = "p" .. k,
              title = "P",
              task = "a/p" .. k,
              steps = { { keys = "x" } },
            })
          ),
          case = { status = "pass", file = "x" },
          snapshots = {},
        }
      end
      local asked = {}
      local pager = function(method, params)
        if method == "bodies" then
          asked[#asked + 1] = #params.ids
          local got = {}
          for k = 1, math.min(2, #params.ids) do
            got[k] = { id = params.ids[k], etag = "e", body = "b" }
          end
          return { kind = "tasks.bodies", items = got, next_offset = #params.ids > 2 and 2 or nil }
        end
        local rs = {}
        for k = 1, #params.ops do
          rs[k] = { n = k, ok = true, outcome = "changed" }
        end
        return { kind = "tasks.result", results = rs }
      end
      local pr = assert(tasks.sync(paged, { call = pager }))
      eq(asked, { 4, 2 }, "a second bodies call for the ids the first page did not reach")
      eq(
        vim.tbl_map(function(r)
          return r.outcome
        end, pr),
        { "changed", "changed", "changed", "changed" },
        "all four written, none missing"
      )
      local stuck = function(method)
        if method == "bodies" then
          return { kind = "tasks.bodies", items = {}, next_offset = 0 }
        end
      end
      local sr = assert(tasks.sync(paged, { call = stuck }))
      eq(sr[1].outcome, "truncated", "a page that brings nothing: not read, not 'missing'")
      ok(not paged[1].task_missing, "and not marked as missing")

      -- the CLI entry
      local outs4, errs4 = {}, {}
      local sv4 = {
        out = function(s)
          outs4[#outs4 + 1] = s
        end,
        err = function(s)
          errs4[#errs4 + 1] = s
        end,
      }
      eq(
        report.main({ "report", root4, "--dry-run" }, sv4),
        2,
        "--dry-run without --tasks is bad usage"
      )
      eq(
        report.main({ "report", root4, "--tasks", root, "--tasks-cli", root .. "/nope.lua" }, sv4),
        3,
        "a CLI that is not there"
      )
      local ir4 = write(
        "ir4.json",
        vim.json.encode({
          cases = {
            {
              id = "x::sheet:one",
              file = "TESTS/s_spec.lua",
              name = "sheet:one",
              status = "pass",
              duration_ms = 1,
              assertions = { { ok = true } },
            },
          },
        })
      )
      current = body
      outs4 = {}
      eq(
        report.main(
          { "report", root4, "--from", ir4, "--tasks", root },
          sv4,
          { call = engine(accept) }
        ),
        0,
        "--tasks with an engine"
      )
      local joined = table.concat(outs4, "\n")
      has(joined, "testing sheets: task a/one changed", "each task is reported")
      has(
        joined,
        "testing sheets: task a/gone missing: not an open task of the vault",
        "a missing task too"
      )
      has(joined, "task `a/gone` is not an open task of the vault", "and the list says so")
      current = body
      eq(
        report.main(
          { "report", root4, "--from", ir4, "--tasks", root },
          sv4,
          { call = engine(refuse) }
        ),
        1,
        "a refused write is exit 1"
      )
      ok(
        tasks.locate(root, { cli = root .. "/nope.lua" }) == nil,
        "locate refuses a CLI that is not there"
      )
      -- found beside the vault like a dependency (the real layout: tasks-vault next to tasks.nvim)
      write("side/tasks.nvim/lua/tasks_nvim/init.lua", "return {}")
      write("side/tasks.nvim/scripts/tasks.lua", "-- cli")
      vim.fn.mkdir(root .. "/side/tasks-vault", "p")
      local found = tasks.locate(root .. "/side/tasks-vault", {
        getenv = function()
          return nil
        end,
      })
      eq(
        found,
        root .. "/side/tasks.nvim/scripts/tasks.lua",
        "the engine beside the vault is found"
      )
    end
  end, debug.traceback)

  S.cleanup()
  vim.fn.delete(root, "rf")
  ok(body_ok, "sheet spec body: " .. tostring(body_err))
end
