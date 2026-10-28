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
  local real_notify, real_system = vim.notify, editor.system
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
  local function restore()
    vim.notify, editor.system = real_notify, real_system
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
    local again, why = editor.run({ root = root })
    eq(again, false, "run: a second run in the same project is refused")
    has(why, "already running", "run: ... and says why")
    ok(
      vim.wait(2000, function()
        local b = vim.fn.bufnr("testing-ci://proj")
        return b ~= -1 and #vim.api.nvim_buf_get_lines(b, 0, -1, false) >= 2
      end),
      "run: the output arrives in the live buffer"
    )
    local buf = vim.fn.bufnr("testing-ci://proj")
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

    -- a process that cannot start
    editor.system = function()
      error("no such program")
    end
    local bad, bad_why = editor.run({ root = root })
    eq(bad, false, "no process: refused")
    has(bad_why, "no such program", "no process: with the reason")
    eq(editor.state[root].running, false, "no process: not stuck in running")
  end)
  restore()
  if not passed then
    error(err, 0)
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
  local real = editor.list(root)
  ok(real ~= nil, "editor.list: asks a child")
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
      local buf = vim.fn.bufnr("testing-ci://proj")
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
