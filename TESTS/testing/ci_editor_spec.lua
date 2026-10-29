-- TESTS/testing/ci_editor_spec.lua -- `:Testing ci` from the editor: the child's argument list, the quickfix items, the
-- verdict and the statusline text (pure), a run through a fake process (live buffer, quickfix only on red, one run at a
-- time), `testing ci list`, and one real run in a child.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local buffers_before = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    buffers_before[b] = true
  end
  local editor = require("testing.ci.editor")
  local cli = require("testing.cli")

  -- ---------------------------------------------------------------- pure parts

  do
    local argv = editor.run_argv({
      root = "/r",
      json = "/tmp/x.json",
      profile = "fast",
      steps = { "a", "b" },
      keep_going = true,
      reuse = true,
    })
    eq(argv[1], vim.v.progpath, "argv: this Neovim")
    eq(vim.list_slice(argv, #argv - 7), {
      "ci",
      "--no-agent",
      "--json=/tmp/x.json",
      "--profile=fast",
      "--step=a,b",
      "--keep-going",
      "--reuse",
      "--root=/r",
    }, "argv: the pipeline options, the root last")
    local plain = editor.run_argv({ root = "/r", json = "/j" })
    eq(
      vim.list_slice(plain, #plain - 3),
      { "ci", "--no-agent", "--json=/j", "--root=/r" },
      "argv: no profile, the default"
    )
  end

  local RED = {
    schema = "testing-ci/1",
    profile = "full",
    verdict = "red",
    first_red = "luacheck",
    deciding = "luacheck",
    commit = "abcdef0123456789",
    tree = "T1",
    steps = {
      { name = "stylua", state = "green", findings = {} },
      {
        name = "luacheck",
        state = "red",
        findings = {
          { file = "lua/a.lua", line = 3, col = 7, text = "(W211) unused variable 'x'" },
          { file = "lua/b.lua", line = vim.NIL, col = vim.NIL, text = "(W111) global" },
        },
      },
      {
        name = "suite",
        state = "red",
        findings = {},
        reason = "the suite wrote no result",
        errors = { "last line" },
      },
      { name = "conformance", state = "skipped", findings = {}, reason = "an earlier step failed" },
    },
  }

  do
    local items = editor.items(RED, "/r")
    eq(#items, 3, "items: two findings and one text-only item; green and skipped steps add none")
    eq(items[1].filename, "/r/lua/a.lua", "items: the file is below the root")
    eq({ items[1].lnum, items[1].col }, { 3, 7 }, "items: line and column")
    has(items[1].text, "[luacheck] (W211)", "items: the step is named")
    eq({ items[2].lnum, items[2].col }, { 1, 1 }, "items: a missing line is line 1")
    eq(items[3].filename, nil, "items: a red step without findings has no file")
    has(items[3].text, "the suite wrote no result", "items: ... but its reason")

    local odd = editor.items({
      steps = {
        {
          name = "suite",
          state = "red",
          findings = {
            { file = "?", line = vim.NIL, col = vim.NIL, text = "no file" },
            { file = "\\\\srv\\share\\a.lua", line = 2, col = 1, text = "unc" },
            { file = "C:/x/a.lua", line = 2, col = 1, text = "drive" },
          },
        },
      },
    }, "/r")
    eq(odd[1].filename, nil, "items: the placeholder file `?` is a text-only item")
    eq(odd[2].filename, "\\\\srv\\share\\a.lua", "items: a UNC path stays as it is")
    eq(odd[3].filename, "C:/x/a.lua", "items: a drive path stays as it is")
    ok(
      editor.view_name("/a/app") ~= editor.view_name("/b/app"),
      "view: two checkouts of one name do not share a buffer"
    )
    has(editor.view_name("/a/app"), "testing-ci://app-", "view: named after the directory")

    local v = editor.verdict(RED, 1, "/r")
    eq(v.level, "error", "verdict: red is an error")
    has(v.message, "luacheck failed, 3 in the quickfix list", "verdict: names the deciding step")
    eq(#v.items, 3, "verdict: carries the items")
    v = editor.verdict(
      { schema = "testing-ci/1", profile = "full", verdict = "green", steps = { {}, {} } },
      0,
      "/r"
    )
    eq({ v.level, #v.items }, { "info", 0 }, "verdict: green is info, no items")
    v = editor.verdict({
      schema = "testing-ci/1",
      profile = "fast",
      verdict = "green-partial",
      partial_why = "--step",
      steps = {},
    }, 0, "/r")
    eq(v.level, "warn", "verdict: partial is a warning")
    v = editor.verdict(nil, 3, "/r", "boom")
    eq(v.level, "error", "verdict: no document is an error")
    has(v.message, "boom", "verdict: with the child's stderr")
    v = editor.verdict(
      { schema = "testing-ci/1", verdict = "infra", problems = { "tool missing" }, steps = {} },
      3,
      "/r"
    )
    has(v.message, "tool missing", "verdict: infra names the problem")
  end

  do
    eq(editor.status_text(nil), "", "status: nothing known")
    eq(editor.status_text({}), "", "status: no document")
    eq(editor.status_text({ running = true, profile = "full" }), "ci: … full", "status: running")
    eq(
      editor.status_text({
        doc = {
          schema = "testing-ci/1",
          verdict = "green",
          profile = "full",
          commit = "abcdef0123",
          tree = "T1",
        },
        tree = "T1",
      }),
      "ci: ✓ full @abcdef0",
      "status: green with the commit"
    )
    eq(
      editor.status_text({ doc = RED, tree = "T1" }),
      "ci: ✗ luacheck",
      "status: red names the step"
    )
    eq(
      editor.status_text({ doc = RED, tree = "T2" }),
      "ci: ✗ luacheck stale",
      "status: another tree is stale"
    )
    eq(
      editor.status_text({
        doc = { schema = "testing-ci/1", verdict = "green-partial", profile = "fast" },
      }),
      "ci: ~ fast",
      "status: partial"
    )
    eq(
      editor.status_text({ doc = { schema = "testing-ci/1", verdict = "infra" } }),
      "ci: ! infra",
      "status: infrastructure"
    )
    eq(
      editor.status_text({ doc = { schema = "other" } }),
      "",
      "status: a foreign document says nothing"
    )
  end

  -- ------------------------------------------------------------ a fake process

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-editor"
  vim.fn.mkdir(tmp .. "/proj", "p")
  local root = tmp .. "/proj"

  local messages = {}
  local real_notify, real_system, real_progress = vim.notify, editor.system, editor.progress
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = tostring(msg), level = level }
  end
  local function said()
    local t = {}
    for _, m in ipairs(messages) do
      t[#t + 1] = m.msg
    end
    return table.concat(t, "\n")
  end
  ---Every progress handle a run creates: `{ title, updates = { fields... }, finished?, cancelled? }`.
  local handles = {}
  local function fake_progress(opts)
    local h = { title = opts.title, updates = {} }
    handles[#handles + 1] = h
    return {
      update = function(_, fields)
        h.updates[#h.updates + 1] = vim.deepcopy(fields)
      end,
      finish = function(_, text)
        h.finished = text or true
      end,
      cancel = function(_, text)
        h.cancelled = text or true
      end,
    }
  end
  editor.progress = fake_progress
  local function restore()
    vim.notify, editor.system, editor.progress = real_notify, real_system, real_progress
  end

  local passed, err = pcall(function()
    ---A process that streams `chunks`, then ends with `doc` (written where `--json=` says) and `code`.
    ---@return function system, table seen
    local function fake(chunks, doc, code)
      local seen = {}
      return function(argv, opts, on_exit)
        seen.argv, seen.opts, seen.finish =
          argv, opts, function()
            local path
            for _, a in ipairs(argv) do
              path = a:match("^%-%-json=(.*)$") or path
            end
            if doc and path then
              local f = assert(io.open(path, "wb"))
              f:write(vim.json.encode(doc))
              f:close()
            end
            on_exit({ code = code, stdout = "", stderr = "" })
          end
        for _, c in ipairs(chunks) do
          opts.stdout(nil, c)
        end
        return {}
      end,
        seen
    end

    vim.fn.setqflist({}, "r")
    local system, seen = fake({ "== stylua\n-- stylua: gr", "een (0.1 s)\n== luacheck\n" }, RED, 1)
    editor.system = system
    local done
    local started = editor.run({
      root = root,
      profile = "full",
      on_done = function(v)
        done = v
      end,
    })
    eq(started, true, "run: starts")
    eq(seen.opts.cwd, root, "run: in the project root")
    local shown_root
    local real_show = editor.show_view
    editor.show_view = function(r)
      shown_root = r
      return real_show(r)
    end
    local again, why = editor.run({ root = root })
    editor.show_view = real_show
    eq(again, false, "run: a second run in the same project is refused")
    has(why, "already running", "run: ... and says why")
    eq(shown_root, root, "run: ... and shows the output of the run that is going")
    eq(editor.show_view(root), true, "show_view: the buffer of a project that ran")
    eq(editor.show_view(root .. "/never-ran"), false, "show_view: a project without a buffer")
    -- with a UI attached the cursor goes to the output, and a second call goes back to the same window
    local real_uis = vim.api.nvim_list_uis
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    local show_buf = vim.fn.bufnr(editor.view_name(root))
    local first_win = vim.api.nvim_get_current_win()
    local wins_before = #vim.api.nvim_list_wins()
    editor.show_buffer(show_buf)
    local view_win = vim.api.nvim_get_current_win()
    eq(vim.api.nvim_win_get_buf(view_win), show_buf, "show_buffer: the cursor is in the split")
    eq(#vim.api.nvim_list_wins(), wins_before + 1, "show_buffer: one split opened")
    vim.api.nvim_set_current_win(first_win)
    editor.show_buffer(show_buf)
    eq(
      vim.api.nvim_get_current_win(),
      view_win,
      "show_buffer: a visible buffer is entered, not split again"
    )
    eq(#vim.api.nvim_list_wins(), wins_before + 1, "show_buffer: no second split")
    vim.api.nvim_list_uis = real_uis
    vim.api.nvim_win_close(view_win, true)

    -- a quiet suite: what the specs print stays out of the buffer, the events give the progress
    do
      local keep, raw = editor.quiet_step("suite")
      local shown = {}
      for _, line in ipairs({
        "== stylua: stylua --check .",
        "-- stylua: green (0.1 s)",
        "== suite",
        "io.write in two parts",
        "checkhealth: 100% checking testing",
        "-- suite: red (3 s)",
        "== luacheck",
      }) do
        if keep(line) then
          shown[#shown + 1] = line
        end
      end
      eq(shown, {
        "== stylua: stylua --check .",
        "-- stylua: green (0.1 s)",
        "== suite",
        "-- suite: red (3 s)",
        "== luacheck",
      }, "quiet_step: the lines between the header and the next header are kept aside")
      eq(
        raw(),
        { "io.write in two parts", "checkhealth: 100% checking testing" },
        "quiet_step: the lines kept aside"
      )
      local keep2, raw2 = editor.quiet_step("suite")
      keep2("== suite")
      for i = 1, editor.RAW_LINES + 10 do
        keep2("noise " .. i)
      end
      eq(#raw2(), editor.RAW_LINES, "quiet_step: only the last lines are kept")
      eq(raw2()[#raw2()], "noise " .. (editor.RAW_LINES + 10), "quiet_step: the newest ones")

      local argv = editor.run_argv({ root = root, json = "j.json", events = "e.ndjson" })
      ok(
        vim.tbl_contains(argv, "--suite-events=e.ndjson"),
        "run_argv: the suite's events go to the file"
      )
      ok(
        not vim.tbl_contains(argv, "--"),
        "run_argv: no suite option after `--` (it would make the run partial)"
      )
      local plain = editor.run_argv({ root = root, json = "j.json" })
      for _, x in ipairs(plain) do
        ok(not x:find("suite-events", 1, true), "run_argv: no events file without one asked for")
      end
      -- --root stays before a `--` of the caller's: what follows it belongs to the suite
      local with_dashes = editor.child_argv(root, { "ci", "--", "--filter", "x" })
      local root_at, dashes_at
      for i, x in ipairs(with_dashes) do
        root_at = x:find("^%-%-root=") and i or root_at
        dashes_at = x == "--" and i or dashes_at
      end
      ok(root_at and dashes_at and root_at < dashes_at, "child_argv: --root comes before `--`")

      -- the text of the status line: what runs, for how long, and how far the suite is
      eq(
        editor.live_text({ elapsed = 5, files_done = 0 }),
        "   ... starting (0:05)",
        "live_text: before the first step"
      )
      eq(
        editor.live_text({ step = "luacheck", elapsed = 75, files_done = 0 }),
        "   ... luacheck is running (1:15)",
        "live_text: a step"
      )
      eq(
        editor.live_text({
          step = "suite",
          elapsed = 90,
          files_total = 187,
          files_done = 12,
          current = "TESTS/a_spec.lua",
        }),
        "   ... suite: 12 of 187 spec files done, now TESTS/a_spec.lua (1:30)",
        "live_text: the suite with its events"
      )
      eq(
        editor.live_text({ step = "suite", elapsed = 3, files_done = 0 }),
        "   ... suite is running (0:03)",
        "live_text: the suite before its first event"
      )

      -- the status line is the last line of the buffer: `append` writes above it, nil removes it
      local sbuf = editor.open_view(root .. "/status-view")
      sbuf.append({ "one" })
      sbuf.status("   ... working")
      sbuf.append({ "two" })
      sbuf.status("   ... still working")
      eq(
        vim.api.nvim_buf_get_lines(sbuf.buf, 0, -1, false),
        { "one", "two", "   ... still working" },
        "status: last line, new lines above it, replaced in place"
      )
      sbuf.status(nil)
      eq(vim.api.nvim_buf_get_lines(sbuf.buf, 0, -1, false), { "one", "two" }, "status: removed")
      sbuf.status("   ... first")
      local empty = editor.open_view(root .. "/status-empty")
      empty.status("   ... only")
      eq(
        vim.api.nvim_buf_get_lines(empty.buf, 0, -1, false),
        { "   ... only" },
        "status: in an empty buffer"
      )
      empty.append({ "line" })
      eq(
        vim.api.nvim_buf_get_lines(empty.buf, 0, -1, false),
        { "line", "   ... only" },
        "status: a first line goes above it"
      )

      -- the feeder: a long line is cut, `keep` hides, `on_line` still sees everything
      local lines_seen, on_line_seen = {}, {}
      local feed, flush = editor.feeder({
        append = function(lines)
          vim.list_extend(lines_seen, lines)
        end,
      }, function(line)
        on_line_seen[#on_line_seen + 1] = line
      end, function(line)
        return line ~= "hide"
      end)
      feed("out")(nil, "hide\n" .. ("x"):rep(editor.MAX_LINE + 20) .. "\nshown")
      vim.wait(500, function()
        return #on_line_seen >= 2
      end)
      flush()
      vim.wait(500, function()
        return #on_line_seen >= 3
      end)
      eq(#on_line_seen, 3, "feeder: on_line sees every line, also the hidden one")
      eq(#lines_seen, 2, "feeder: the hidden line is not appended")
      ok(#lines_seen[1] < editor.MAX_LINE + 60, "feeder: a long line is cut")
      has(lines_seen[1], "more characters", "feeder: ... and says so")
      eq(lines_seen[2], "shown", "feeder: the rest is shown as before")

      -- tail_events: the bytes written so far go through the reader, a half line waits for its end
      local path = vim.fn.tempname() .. ".ndjson"
      local got = {}
      local stop = editor.tail_events(path, function(ev)
        got[#got + 1] = ev.event
      end)
      local f = assert(io.open(path, "wb"))
      f:write(
        '{"v":1,"event":"run_start","ts":1,"run":1,"files_total":2,"files_selected":2,"files":["a","b"]}\n'
      )
      f:write('{"v":1,"event":"file_end","ts":1,"run":1,"file":"a","cases":1,"failed":0')
      f:flush()
      ok(
        vim.wait(2000, function()
          return #got >= 1
        end),
        "tail_events: the first event arrives while the file is open"
      )
      f:write(',"duration_ms":3}\n')
      f:close()
      stop()
      eq(got, { "run_start", "file_end" }, "tail_events: a line split in two writes is one event")
      os.remove(path)
    end

    -- a run with a suite step: the child gets an events file, its noise stays out, the progress counts files
    do
      local qroot = vim.fn.tempname() .. "-quiet"
      vim.fn.mkdir(qroot, "p")
      local real_plan = editor.step_plan
      editor.step_plan = function()
        return { "stylua", "suite" }
      end
      local qargv
      editor.system = function(argv, opts, on_exit)
        qargv = argv
        local events
        for i, a in ipairs(argv) do
          events = a:match("^%-%-suite%-events=(.*)$") or events
        end
        local ef = assert(io.open(events, "wb"))
        ef:write(
          '{"v":1,"event":"run_start","ts":1,"run":1,"files_total":2,"files_selected":2,"files":["a","b"]}\n'
        )
        ef:write(
          '{"v":1,"event":"file_end","ts":1,"run":1,"file":"a","cases":1,"failed":0,"duration_ms":3}\n'
        )
        ef:write('{"v":1,"event":"run_done","ts":2,"run":1,"exit_code":1,"verdict":"red"}\n')
        ef:close()
        opts.stdout(
          nil,
          "== stylua: stylua --check .\n-- stylua: green (0.1 s)\n== suite\nspec noise\n-- suite: red (0.5 s)\n== conformance\n-- conformance: green (0.1 s)\n"
        )
        vim.defer_fn(function()
          on_exit({ code = 1, stdout = "", stderr = "" })
        end, 600)
        return {}
      end
      local h_before = #handles
      local finished_q = false
      local started_q = editor.run({
        root = qroot,
        profile = "full",
        on_done = function()
          finished_q = true
        end,
      })
      editor.step_plan = real_plan
      eq(started_q, true, "quiet run: starts")
      ok(
        vim.iter(qargv):any(function(x)
          return x:find("--suite-events=", 1, true) == 1
        end),
        "quiet run: the child is asked for events (" .. table.concat(qargv, " ") .. ")"
      )
      ok(
        vim.wait(3000, function()
          return finished_q
        end),
        "quiet run: ends"
      )
      local qbuf = vim.fn.bufnr(editor.view_name(qroot))
      local qtext = table.concat(vim.api.nvim_buf_get_lines(qbuf, 0, -1, false), "\n")
      local header_at = qtext:find("-- the last 1 line(s) the suite printed:", 1, true)
      local noise_at = qtext:find("spec noise", 1, true)
      ok(
        header_at and noise_at and noise_at > header_at,
        "quiet run: the specs' own output is kept aside and shown last, because the run is red"
      )
      has(qtext, "== suite", "quiet run: the suite header is")
      has(qtext, "1 spec file(s), 1 case(s)", "quiet run: the events say how much the suite did")
      local suite_at = qtext:find("-- suite: red", 1, true)
      local count_at = qtext:find("1 spec file(s)", 1, true)
      ok(
        suite_at and count_at and count_at > suite_at,
        "quiet run: ... right after the verdict line of the suite"
      )
      local qlines = vim.api.nvim_buf_get_lines(qbuf, 0, -1, false)
      local verdict_row
      for i, l in ipairs(qlines) do
        verdict_row = l:find("-- suite: red", 1, true) and i or verdict_row
      end
      eq(
        verdict_row and qlines[verdict_row + 1],
        "   1 spec file(s), 1 case(s)",
        "quiet run: the count line is the very next line, also when more output came in the same chunk"
      )
      local seen_text = false
      for _, u in ipairs(handles[h_before + 1] and handles[h_before + 1].updates or {}) do
        seen_text = seen_text or (u.text == "suite 1/2")
      end
      ok(seen_text, "quiet run: the progress says `suite 1/2`")
      -- the later cases count the handles from the first one
      table.remove(handles, h_before + 1)
    end

    -- a suite that ran no files of its own (reused from its stamp) gets no count line
    do
      local rroot = vim.fn.tempname() .. "-reused"
      vim.fn.mkdir(rroot, "p")
      local real_plan = editor.step_plan
      editor.step_plan = function()
        return { "suite" }
      end
      editor.system = function(_, opts, on_exit)
        opts.stdout(
          nil,
          "== suite\n-- suite: green (0.0 s, reused: its stamp verifies)\nci: GREEN full 1/1\n"
        )
        vim.defer_fn(function()
          on_exit({ code = 0, stdout = "", stderr = "" })
        end, 300)
        return {}
      end
      local done_r = false
      local h_r = #handles
      editor.run({
        root = rroot,
        on_done = function()
          done_r = true
        end,
      })
      editor.step_plan = real_plan
      ok(
        vim.wait(3000, function()
          return done_r
        end),
        "reused run: ends"
      )
      local rtext = table.concat(
        vim.api.nvim_buf_get_lines(vim.fn.bufnr(editor.view_name(rroot)), 0, -1, false),
        "\n"
      )
      ok(not rtext:find("spec file(s)", 1, true), "reused run: no count line: " .. rtext)
      has(rtext, "ci: GREEN", "reused run: the verdict is there")
      table.remove(handles, h_r + 1)
    end

    -- a skipped suite step hides nothing: what follows it is the next step or the verdict
    do
      local keep_s = editor.quiet_step("suite")
      local shown_s = {}
      for _, l in ipairs({
        "== stylua: stylua --check .",
        "-- stylua: red (0.1 s)",
        "== suite (skipped: an earlier step failed)",
        "  stylua         red         0.1 s",
        "ci: RED stylua (exit 1)",
      }) do
        if keep_s(l) then
          shown_s[#shown_s + 1] = l
        end
      end
      eq(#shown_s, 5, "quiet_step: a skipped suite hides nothing: " .. vim.inspect(shown_s))
    end

    -- a status tick that was already queued when the run ended does not bring the line back
    do
      local calls = {}
      local real_new_timer = vim.uv.new_timer
      local captured
      vim.uv.new_timer = function()
        return {
          start = function(_, _, _, cb)
            captured = cb
          end,
          stop = function() end,
          close = function() end,
        }
      end
      local stop_status = editor.live_status({
        status = function(text)
          calls[#calls + 1] = text == nil and "<removed>" or text
        end,
      }, { files_done = 0 })
      vim.uv.new_timer = real_new_timer
      stop_status()
      captured()
      vim.wait(100)
      eq(calls, { "<removed>" }, "live_status: nothing after the stop: " .. vim.inspect(calls))
    end
    ok(
      vim.wait(2000, function()
        local b = vim.fn.bufnr(editor.view_name(root))
        return b ~= -1 and #vim.api.nvim_buf_get_lines(b, 0, -1, false) >= 2
      end),
      "run: the output arrives in the live buffer"
    )
    local buf = vim.fn.bufnr(editor.view_name(root))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(lines[1], "== stylua", "view: first line")
    eq(lines[2], "-- stylua: green (0.1 s)", "view: a line split between two chunks is whole")
    eq(vim.fn.getqflist({ size = 1 }).size, 0, "quickfix: nothing before the end")
    eq(editor.state[root].running, true, "state: running")
    eq(editor.status_text(editor.state[root]), "ci: … full", "status: running while it goes")

    seen.finish()
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "run: finishes"
    )
    eq(done.level, "error", "run: a red result is an error")
    eq(vim.fn.getqflist({ size = 1 }).size, 3, "quickfix: the findings of the red steps")
    eq(vim.fn.getqflist({ title = 1 }).title, "testing ci: findings", "quickfix: titled")
    has(said(), "luacheck failed", "run: the verdict is notified")
    eq(editor.state[root].running, false, "state: not running any more")
    local h = handles[#handles]
    eq(h.title, "testing ci", "progress: one indicator per run")
    eq(h.updates, {
      { text = "stylua", current = 1 },
      { text = "luacheck", current = 2 },
    }, "progress: one step per `== <step>` line (no total before `ci list` was asked)")
    eq(h.finished, "failed", "progress: finished with the outcome")
    vim.cmd("silent! cclose")
    vim.fn.setqflist({}, "r")

    -- green: no quickfix list, an info message
    messages = {}
    local green = {
      schema = "testing-ci/1",
      profile = "full",
      verdict = "green",
      steps = { { name = "a", state = "green" } },
    }
    system, seen = fake({ "ci: GREEN full 1/1\n" }, green, 0)
    editor.system = system
    done = nil
    eq(
      editor.run({
        root = root,
        on_done = function(v)
          done = v
        end,
      }),
      true,
      "green: starts"
    )
    seen.finish()
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "green: finishes"
    )
    eq(done.level, "info", "green: info")
    eq(vim.fn.getqflist({ size = 1 }).size, 0, "green: the quickfix list stays empty")
    has(said(), "all 1 steps green", "green: notified")

    -- a child that wrote no document
    messages = {}
    system, seen = fake({}, nil, 3)
    editor.system = system
    done = nil
    editor.run({
      root = root,
      on_done = function(v)
        done = v
      end,
    })
    seen.finish()
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "no document: finishes"
    )
    eq(done.level, "error", "no document: an error")
    eq(editor.state[root].running, false, "no document: not stuck in running")

    -- streams: an unfinished stdout line is not glued to stderr; a carriage return keeps the last segment; the end
    -- flushes what is left
    system, seen = fake({}, nil, 0)
    editor.system = system
    done = nil
    editor.run({
      root = root,
      on_done = function(v)
        done = v
      end,
    })
    seen.opts.stdout(nil, "abc")
    seen.opts.stderr(nil, "warn\n")
    seen.opts.stdout(nil, "def\np1\rp2\r\nlast")
    seen.finish()
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "streams: finishes"
    )
    local got = vim.api.nvim_buf_get_lines(vim.fn.bufnr(editor.view_name(root)), 0, -1, false)
    eq(
      got,
      { "warn", "abcdef", "p2", "last" },
      "streams: per stream, whole lines, progress rewritten, the rest flushed"
    )

    -- progress: a step counts once, and with a known plan only a planned step (a step's own output may start
    -- with `== `); --step=a,a is one step
    system, seen = fake({ "== a: tool\n== build\n== a\n" }, nil, 0)
    editor.system = system
    done = nil
    editor.run({
      root = root,
      steps = { "a", "a" },
      on_done = function(v)
        done = v
      end,
    })
    seen.finish()
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "plan: finishes"
    )
    eq(
      handles[#handles].updates,
      { { text = "a", current = 1, total = 1 } },
      "plan: one update, out of the distinct steps asked for"
    )

    -- the plan of a profile comes from `ci list` only while .testing.lua is unchanged since
    local proot = tmp .. "/planned"
    vim.fn.mkdir(proot, "p")
    vim.fn.writefile({ "return {}" }, proot .. "/.testing.lua")
    editor.system = function(_, _, cb)
      cb({
        code = 0,
        stdout = vim.json.encode({
          default = "full",
          profiles = { full = { "x", "y" } },
          steps = {},
        }),
        stderr = "",
      })
      return {}
    end
    eq(editor.step_plan(proot), nil, "plan: nothing before `ci list` was asked")
    editor.list(proot)
    ok(
      vim.wait(2000, function()
        return editor.step_plan(proot) ~= nil
      end),
      "plan: known once `ci list` answered"
    )
    eq(editor.step_plan(proot), { "x", "y" }, "plan: the steps of the default profile")
    eq(editor.step_plan(proot, "other"), nil, "plan: an unknown profile has none")
    local st = vim.uv.fs_stat(proot .. "/.testing.lua")
    vim.uv.fs_utime(proot .. "/.testing.lua", st.atime.sec, st.mtime.sec + 5)
    eq(editor.step_plan(proot), nil, "plan: a changed .testing.lua makes the cached list stale")

    -- the statusline asks again after a while, and never starts more than the refresh
    local calls = 0
    editor.system = function(argv, opts, cb)
      calls = calls + 1
      cb({ code = 0, stdout = "TREE" .. calls .. "\n", stderr = "" })
      return {}
    end
    editor.state[root] = nil
    eq(editor.statusline(root), "", "statusline: unknown project, nothing yet")
    ok(
      vim.wait(2000, function()
        return editor.state[root] and editor.state[root].tree == "TREE1"
      end),
      "statusline: the first call refreshes in the background"
    )
    editor.state[root].doc = RED
    editor.state[root].doc.tree = "TREE1"
    eq(editor.statusline(root), "ci: ✗ luacheck", "statusline: the cached result")
    eq(calls, 1, "statusline: within the interval nothing is started")
    editor.state[root].at = os.time() - editor.REFRESH_AFTER - 1
    editor.statusline(root)
    ok(
      vim.wait(2000, function()
        return calls == 2 and editor.state[root].tree == "TREE2"
      end),
      "statusline: after the interval it asks git again"
    )
    editor.state[root].doc = RED
    eq(
      editor.statusline(root),
      "ci: ✗ luacheck stale",
      "statusline: the tree moved, the result is stale"
    )
    editor.state[root].running = true
    editor.state[root].at = os.time() - 100
    editor.statusline(root)
    eq(calls, 2, "statusline: no refresh while a run goes")
    editor.state[root].running = false

    -- :Testing ci verify | hook through a child (fake): the first line is the message, a non-zero exit warns
    messages = {}
    local captured
    editor.system = function(argv, opts, cb)
      captured = argv
      cb({
        code = 1,
        stdout = "ci verify: changed (profile full)\n  run again: echo\n",
        stderr = "",
      })
      return {}
    end
    require("testing.bindings.usrcmds").ci_capture(
      { args = {}, flags = { profile = "full", ["allow-dirty"] = true, root = root } },
      { "verify" },
      { value = { "profile" }, bool = { "allow-dirty" } },
      "verify"
    )
    ok(
      vim.wait(2000, function()
        return #messages > 0
      end),
      "capture: the answer is notified"
    )
    has(said(), "ci verify: changed", "capture: the first line")
    eq(messages[1].level, vim.log.levels.WARN, "capture: a non-zero exit is a warning")
    local joined = table.concat(captured, " ")
    has(joined, "ci verify --allow-dirty --profile=full", "capture: the subcommand and its options")
    has(joined, "--root=" .. root, "capture: for the project")
    vim.cmd("silent! bwipeout!")

    -- a process that cannot start
    editor.system = function()
      error("no such program")
    end
    local bad, bad_why = editor.run({ root = root })
    eq(bad, false, "no process: refused")
    has(bad_why, "no such program", "no process: with the reason")
    eq(editor.state[root].running, false, "no process: not stuck in running")
    eq(handles[#handles].cancelled, true, "no process: the progress indicator is cancelled")
  end)
  restore()
  if not passed then
    error(err, 0)
  end

  -- ------------------------------------------------------- the settings and `:Testing ci repos`

  do
    local config = require("testing.config")
    local valid, problems =
      config.validate({ ci = { repos = { roots = { "$REPOS_DIR" }, include = { "a" } } } })
    eq(problems, {}, "config: ci.repos is a valid option")
    eq(valid.ci.repos.roots, { "$REPOS_DIR" }, "config: ... and kept")
    problems = select(2, config.validate({ ci = { repos = { roots = "x" } } }))
    eq(#problems, 1, "config: roots must be a list")
    problems = select(2, config.validate({ ci = { repos = { exclude = { 1 } } } }))
    eq(#problems, 1, "config: the names are strings")
    problems = select(2, config.validate({ ci = "x" }))
    eq(#problems, 1, "config: ci is a table")
    eq(
      config.get().ci.repos,
      { roots = {}, include = {}, exclude = {} },
      "config: the defaults list nothing"
    )

    local cfg = { repos = { roots = { "/r1", "/r2" }, include = { "a", "b" }, exclude = { "c" } } }
    eq(
      editor.repos_args(cfg, { force = true, jobs = "2", profile = "fast", ["keep-going"] = true }),
      {
        "--repos-root=/r1",
        "--repos-root=/r2",
        "--repos-include=a,b",
        "--repos-exclude=c",
        "--force",
        "--keep-going",
        "--jobs=2",
        "--profile=fast",
      },
      "repos_args: the settings and the flags"
    )
    eq(
      editor.repos_args(
        { repos = { roots = { "/r1" }, include = {}, exclude = {} } },
        { ["repos-root"] = "/other" }
      ),
      { "--repos-root=/other" },
      "repos_args: --repos-root replaces the settings"
    )
  end

  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = tostring(msg), level = level }
  end
  editor.progress = fake_progress
  local passed_repos, err_repos = pcall(function()
    -- pure: the state lines of the child, the table, the quickfix items and the verdict of a document
    eq(
      editor.repos_event("ci repos: [1/3] #2 run my repo"),
      { finished = 1, total = 3, index = 2, event = "run", name = "my repo" },
      "repos_event: a state line (a name may have blanks)"
    )
    eq(
      editor.repos_event("a.nvim | ci repos: [1/3] #1 run x"),
      nil,
      "repos_event: a child's line is not one"
    )
    eq(
      editor.repos_event("ci repos: GREEN 1/1 (0 proven, not run)"),
      nil,
      "repos_event: nor the verdict"
    )
    eq(
      editor.repos_table(
        { { name = "a.nvim", state = "green", verify = "not proven", ms = 1500 } },
        1,
        3
      ),
      {
        "ci repos  1/3 done",
        "repo    state    verify      time",
        "a.nvim  green    not proven  1.5 s",
        "(2 not started yet)",
        "",
      },
      "repos_table: the rows seen, then what is still to come"
    )
    local DOC = {
      schema = "testing-ci-repos/1",
      verdict = "red",
      exit = 1,
      repos = {
        { name = "a", dir = "/r/a", state = "skipped", verify = "proven", code = 0, ms = 10 },
        {
          name = "b",
          dir = "/r/b",
          state = "red",
          verify = "not proven",
          code = 1,
          ms = 20,
          doc = RED,
        },
        { name = "c", dir = "/r/c", state = "infra", code = 3, ms = 5, doc = vim.NIL },
      },
    }
    local items = editor.repos_items(DOC)
    eq(#items, 4, "repos_items: the findings of b (3) and a text item for c without a document")
    eq(items[1].filename, "/r/b/lua/a.lua", "repos_items: a file relative to its repository")
    has(items[1].text, "b [luacheck]", "repos_items: the repository's name in front")
    eq(items[4].text, "c: infra (exit 3)", "repos_items: no document, the state and the exit code")
    local v = editor.repos_verdict(DOC, 1)
    eq(v.level, "error", "repos_verdict: red is an error")
    has(
      v.message,
      "b (red), c (infra), 4 in the quickfix list",
      "repos_verdict: which ones, how many items"
    )
    v = editor.repos_verdict(
      { schema = "testing-ci-repos/1", verdict = "green", repos = { DOC.repos[1] } },
      0
    )
    eq(v, {
      level = "info",
      message = "ci repos: all 1 green or proven (1 proven, not run)",
      items = {},
    }, "repos_verdict: green")
    eq(editor.repos_verdict(nil, 2).level, "error", "repos_verdict: no document and a failure")

    local argv_seen, opts_seen, on_exit_raw
    local finish
    editor.system = function(argv, opts, on_exit)
      argv_seen, opts_seen, on_exit_raw = argv, opts, on_exit
      opts.stdout(nil, "== repo | line\nci repos: GREEN 1/1")
      finish = function(code)
        on_exit({ code = code, stdout = "", stderr = "" })
      end
      return {}
    end
    messages = {}
    local done
    local started = editor.run_repos({
      args = { "--repos-root=/r" },
      cwd = root,
      on_done = function(code)
        done = code
      end,
    })
    eq(started, true, "run_repos: starts")
    local again, why = editor.run_repos({ args = {}, cwd = root })
    eq(again, false, "run_repos: one at a time")
    has(why, "already going", "run_repos: ... says why")
    eq(
      argv_seen[#argv_seen],
      "--repos-root=/r",
      "run_repos: no --root (it works on the repositories it is told about)"
    )
    eq(argv_seen[#argv_seen - 2], "ci", "run_repos: the ci subcommand")
    ok(
      argv_seen[#argv_seen - 1]:match("^%-%-json=.+%.testing%-ci%-repos%.json$") ~= nil,
      "run_repos: asks for the document (" .. tostring(argv_seen[#argv_seen - 1]) .. ")"
    )
    finish(1)
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "run_repos: finishes"
    )
    has(said(), "ci repos: exit 1", "run_repos: a non-zero exit is notified as a failure")
    local lines = vim.api.nvim_buf_get_lines(vim.fn.bufnr(editor.view_name("/repos")), 0, -1, false)
    eq(
      lines,
      { "== repo | line", "ci repos: GREEN 1/1" },
      "run_repos: the output is in the view, the last line flushed"
    )
    eq(editor.state["*repos*"].running, false, "run_repos: not stuck in running")
    eq(opts_seen.timeout, nil, "run_repos: no timeout for the whole multi-repository run")
    -- killed by a signal: code 0 with a signal is a failure, not green
    messages = {}
    done = nil
    editor.run_repos({
      args = {},
      cwd = root,
      on_done = function(code)
        done = code
      end,
    })
    on_exit_raw({ code = 0, signal = 9, stdout = "", stderr = "" })
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "run_repos: a signal exit finishes"
    )
    eq(done, 3, "run_repos: a signal exit is infrastructure (3)")
    has(said(), "ci repos: exit 3", "run_repos: ... and notified as a failure")
    messages = {}
    editor.run_repos({ args = {}, cwd = root })
    finish(0)
    ok(
      vim.wait(2000, function()
        return said():find("all green or proven", 1, true) ~= nil
      end),
      "run_repos: green is notified"
    )

    -- live: the state lines fill the table at the top, the progress follows; the document gives the final table,
    -- the verdict and the quickfix list
    vim.fn.setqflist({}, "r")
    messages = {}
    done = nil
    editor.system = function(argv, opts, on_exit)
      opts_seen = opts
      finish = function(code)
        local path
        for _, a in ipairs(argv) do
          path = a:match("^%-%-json=(.*)$") or path
        end
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode(DOC))
        f:close()
        on_exit({ code = code, stdout = "", stderr = "" })
      end
      return {}
    end
    editor.run_repos({
      args = {},
      cwd = root,
      on_done = function(code)
        done = code
      end,
    })
    local h = handles[#handles]
    eq(h.title, "testing ci repos", "live: a progress indicator of its own")
    opts_seen.stdout(
      nil,
      "ci repos: [0/3] #1 verify a\na | ci verify: proven\nci repos: [1/3] #1 proven a\n"
    )
    opts_seen.stdout(nil, "ci repos: [1/3] #2 verify b\n")
    local buf = vim.fn.bufnr(editor.view_name("/repos"))
    ok(
      vim.wait(2000, function()
        return #h.updates == 3
      end),
      "live: one progress update per state line"
    )
    eq(
      h.updates[3],
      { text = "verify b", current = 1, total = 3 },
      "live: the progress text and count"
    )
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
      "ci repos  1/3 done",
      "repo  state    verify      time",
      "a     proven   -           -",
      "b     verify   -           -",
      "(1 not started yet)",
      "",
      "ci repos: [0/3] #1 verify a",
      "a | ci verify: proven",
      "ci repos: [1/3] #1 proven a",
      "ci repos: [1/3] #2 verify b",
    }, "live: the table on top, the output below")
    -- a second repository with the same directory name (another root) is a row of its own
    opts_seen.stdout(nil, "ci repos: [1/3] #3 verify a\n")
    ok(
      vim.wait(2000, function()
        return #h.updates == 4
      end),
      "live: the state line of the second a"
    )
    eq(vim.api.nvim_buf_get_lines(buf, 0, 6, false), {
      "ci repos  1/3 done",
      "repo  state    verify      time",
      "a     proven   -           -",
      "b     verify   -           -",
      "a     verify   -           -",
      "",
    }, "live: same name, two rows, none left to start")
    finish(1)
    ok(
      vim.wait(2000, function()
        return done ~= nil
      end),
      "live: finishes"
    )
    local final = vim.api.nvim_buf_get_lines(buf, 0, 6, false)
    eq(final, {
      "ci repos  3/3 done",
      "repo  state    verify      time",
      "a     proven   proven      0.0 s",
      "b     red      not proven  0.0 s",
      "c     infra    -           0.0 s",
      "",
    }, "live: the final table from the document")
    eq(h.finished, "failed", "live: the progress ends with the outcome")
    has(said(), "b (red), c (infra)", "live: the verdict names the repositories")
    eq(vim.fn.getqflist({ size = 1 }).size, 4, "live: the quickfix list of all repositories")
    eq(vim.fn.getqflist({ title = 1 }).title, "testing ci repos: findings", "live: titled")
    vim.cmd("silent! cclose")
    vim.fn.setqflist({}, "r")

    -- a process that cannot start: refused, not stuck, the progress indicator cancelled
    editor.system = function()
      error("no such program")
    end
    local bad, bad_why = editor.run_repos({ args = {}, cwd = root })
    eq(bad, false, "run_repos: no process, refused")
    has(bad_why, "no such program", "run_repos: ... with the reason")
    eq(editor.state["*repos*"].running, false, "run_repos: no process, not stuck in running")
    eq(
      { handles[#handles].title, handles[#handles].cancelled },
      { "testing ci repos", true },
      "run_repos: no process, the progress indicator is cancelled"
    )
  end)
  restore()
  if not passed_repos then
    error(err_repos, 0)
  end

  -- ------------------------------------------------------- list and a real run

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local nvim = vim.v.progpath
  local echo = root .. "/lua/proj/echo.lua"
  write(echo, "io.stdout:write('echo ok\\n')\n")
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = { profiles = { fast = { 'echo' }, full = { 'echo', 'again' } }, default = 'full', steps = { echo = { run = { "
      .. ("%q"):format(nvim)
      .. ", '--headless', '-u', 'NONE', '-i', 'NONE', '-l', "
      .. ("%q"):format(echo)
      .. " } }, again = { run = { "
      .. ("%q"):format(nvim)
      .. ", '--headless', '-u', 'NONE', '-i', 'NONE', '-l', "
      .. ("%q"):format(echo)
      .. " } } } } }\n"
  )
  local list_out = {}
  local code = cli.main({ "ci", "list", "--json", "--root=" .. root }, {
    out = function(s)
      list_out[#list_out + 1] = s
    end,
    err = function() end,
  })
  eq(code, 0, "ci list: exit 0")
  local listed = vim.json.decode(table.concat(list_out, "\n"))
  eq(listed.default, "full", "ci list: the default profile")
  eq(listed.profiles.fast, { "echo" }, "ci list: the steps of a profile")
  eq(listed.steps, { "again", "echo" }, "ci list: all steps, sorted")
  local text_out = {}
  cli.main({ "ci", "list", "--root=" .. root }, {
    out = function(s)
      text_out[#text_out + 1] = s
    end,
    err = function() end,
  })
  has(table.concat(text_out, "\n"), "full (default): echo, again", "ci list: text form")
  local err_out = {}
  eq(
    cli.main({ "ci", "list", "--root=" .. tmp }, {
      out = function() end,
      err = function(s)
        err_out[#err_out + 1] = s
      end,
    }),
    2,
    "ci list: no project is exit 2"
  )

  -- through a real child (the completion path)
  local t0 = vim.uv.hrtime()
  local first = editor.list(root)
  ok((vim.uv.hrtime() - t0) / 1e6 < 200, "editor.list: a miss does not wait for the child")
  eq(first, nil, "editor.list: nothing known yet")
  local real
  ok(
    vim.wait(30000, function()
      real = editor.list(root)
      return real ~= nil
    end),
    "editor.list: the next ask has the answer"
  )
  eq(real and real.steps, { "again", "echo" }, "editor.list: the steps")
  eq(editor.list(tmp), nil, "editor.list: nil without .testing.lua")

  -- one real run, end to end (its own state directory: the child writes a document there)
  do
    local state = tmp .. "/state"
    editor.system = function(argv, opts, on_exit)
      opts.env = {
        XDG_STATE_HOME = state,
        XDG_DATA_HOME = state .. "/data",
        XDG_CACHE_HOME = state .. "/cache",
      }
      return real_system(argv, opts, on_exit)
    end
    messages = {}
    vim.notify = function(msg, level)
      messages[#messages + 1] = { msg = tostring(msg), level = level }
    end
    local done
    local started = editor.run({
      root = root,
      profile = "fast",
      on_done = function(v)
        done = v
      end,
    })
    local pcall_ok, werr = pcall(function()
      eq(started, true, "real run: starts")
      ok(
        vim.wait(60000, function()
          return done ~= nil
        end),
        "real run: finishes"
      )
      eq(done and done.level, "info", "real run: green")
      has(said(), "all 1 steps green", "real run: notified")
      local buf = vim.fn.bufnr(editor.view_name(root))
      local out = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      has(out, "== echo", "real run: the live buffer shows the step")
      has(out, "TESTING_CI_OK", "real run: ... and the sentinel")
    end)
    restore()
    if not pcall_ok then
      error(werr, 0)
    end
  end

  vim.cmd("silent! cclose")
  vim.cmd("silent! only")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not buffers_before[b] then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.fn.delete(tmp, "rf")
end
