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
      refused({ id = "a", title = "T", steps = { { settle = 0 } } }, "positive integer", "settle 0")
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
      has(tostring(err), "still false after 100 ms", "a wait that never holds")
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
