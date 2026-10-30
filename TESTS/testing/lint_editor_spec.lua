-- TESTS/testing/lint_editor_spec.lua -- `:Testing lint` in the editor (testing.lint.editor): a testing-lint/1 document
-- becomes quickfix items and diagnostics (one namespace per check, cleared for a checked file without findings, left
-- alone for a check that did not run), the verdict, the argv of the child, a run whose child is a stub (quickfix
-- "testing lint"), the check on save (installed by `lint.on_save`, debounced, a newer save stops the older run and its
-- result is dropped, silent where there is nothing to lint), the order of runs (an older run never overwrites the
-- diagnostics of a newer one), a capped list clears nothing, --fix refuses unsaved buffers, and the validation of the
-- `lint` setup option.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields, duplicate-set-field

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 800) .. ")"
    )
  end

  local editor = require("testing.lint.editor")
  local config = require("testing.config")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-lint-editor"
  vim.fn.mkdir(tmp .. "/lua", "p")
  -- a project root (the check on save finds it upwards from the file)
  local marker = assert(io.open(tmp .. "/.testing.lua", "wb"))
  marker:write("return {}")
  marker:close()
  for _, name in ipairs({ "a", "b", "c", "d" }) do
    local f = assert(io.open(tmp .. "/lua/" .. name .. ".lua", "wb"))
    f:write("return {}\n")
    f:close()
  end

  local NIL = vim.NIL
  local function doc()
    return {
      schema = "testing-lint/1",
      root = tmp,
      scope = { mode = "changed", files = { "lua/a.lua", "lua/b.lua", "lua/c.lua" } },
      fix = false,
      verdict = "infra",
      exit = 3,
      deciding = "luals",
      problems = {},
      checks = {
        {
          name = "luacheck",
          preset = "luacheck",
          state = "red",
          exit = 1,
          ext = { "lua" },
          files = { "lua/a.lua", "lua/b.lua", "lua/c.lua" },
          findings = {
            {
              file = "lua/a.lua",
              line = 3,
              col = 7,
              message = "(W211) unused variable 'x'",
              check = "luacheck",
            },
            {
              file = "lua/b.lua",
              line = 1,
              col = 1,
              message = "(E011) expected expression",
              check = "luacheck",
            },
          },
          findings_total = 2,
          fixed = {},
          no_fix = false,
          missing = false,
          nothing = false,
          reason = NIL,
          errors = {},
        },
        {
          name = "stylua",
          preset = "stylua",
          state = "green",
          exit = 0,
          ext = { "lua" },
          files = { "lua/a.lua", "lua/c.lua" },
          findings = {},
          findings_total = 0,
          fixed = { "lua/c.lua" },
          no_fix = false,
          missing = false,
          nothing = false,
          reason = NIL,
          errors = {},
        },
        {
          name = "luals",
          preset = "luals",
          state = "skipped",
          exit = NIL,
          ext = { "lua" },
          files = { "lua/a.lua" },
          findings = {},
          findings_total = 0,
          fixed = {},
          no_fix = false,
          missing = true,
          nothing = false,
          reason = "step luals needs lua-language-server, which was not found (searched: lua-language-server on PATH)",
          errors = {},
        },
      },
    }
  end

  -- quickfix items: one per finding, the file resolved below the root, the check in the text
  do
    local items = editor.items(doc())
    eq(#items, 2, "items: one per finding")
    eq(items[1].filename, tmp .. "/lua/a.lua", "items: the file below the root")
    eq({ items[1].lnum, items[1].col }, { 3, 7 }, "items: line and column")
    eq(items[1].text, "[luacheck] (W211) unused variable 'x'", "items: the check and the message")
    eq(items[1].type, "W", "items: a warning")
    eq(items[2].type, "E", "items: an error code is an error")
    eq(editor.items({ schema = "other" }), {}, "items: not a lint document")
  end

  -- diagnostics per check: a check that did not run is left out
  do
    local per = editor.diagnostics(doc())
    eq(#per, 2, "diagnostics: luacheck and stylua, not the skipped luals")
    eq(per[1].namespace, "testing.lint.luacheck", "diagnostics: one namespace per check")
    eq(per[2].namespace, "testing.lint.stylua", "diagnostics: ... the second check's")
    local only_red = doc()
    only_red.checks[1].findings = {}
    eq(
      #editor.diagnostics(only_red),
      1,
      "diagnostics: a red check without a finding says nothing about any file"
    )
  end

  -- apply: loaded buffers get their findings, a checked file without findings is cleared, others are left alone
  local bufs = {}
  for _, name in ipairs({ "a", "b", "c", "d" }) do
    local buf = vim.fn.bufadd(tmp .. "/lua/" .. name .. ".lua")
    vim.fn.bufload(buf)
    bufs[name] = buf
  end
  local ns_luacheck = vim.api.nvim_create_namespace("testing.lint.luacheck")
  local ns_stylua = vim.api.nvim_create_namespace("testing.lint.stylua")
  local stale =
    { { lnum = 0, col = 0, message = "stale", severity = vim.diagnostic.severity.WARN } }
  do
    vim.diagnostic.set(ns_luacheck, bufs.c, stale)
    vim.diagnostic.set(ns_luacheck, bufs.d, stale)
    vim.diagnostic.set(ns_stylua, bufs.c, stale)
    local set = editor.apply(doc())
    eq(set, 2, "apply: two buffers got findings")
    local a = vim.diagnostic.get(bufs.a, { namespace = ns_luacheck })
    eq(#a, 1, "apply: a.lua has the luacheck finding")
    eq({ a[1].lnum, a[1].col }, { 2, 6 }, "apply: 0-based line and column")
    eq(a[1].source, "luacheck", "apply: the source is the check")
    eq(a[1].severity, vim.diagnostic.severity.WARN, "apply: a warning")
    local b = vim.diagnostic.get(bufs.b, { namespace = ns_luacheck })
    eq(b[1].severity, vim.diagnostic.severity.ERROR, "apply: an error")
    eq(
      #vim.diagnostic.get(bufs.c, { namespace = ns_luacheck }),
      0,
      "apply: a checked file without findings is cleared"
    )
    eq(
      #vim.diagnostic.get(bufs.c, { namespace = ns_stylua }),
      0,
      "apply: ... in the namespace of each check"
    )
    eq(
      #vim.diagnostic.get(bufs.d, { namespace = ns_luacheck }),
      1,
      "apply: a file that was not checked keeps what it had"
    )
    -- --all: every file below the root with an extension of the check counts as checked
    local all = doc()
    all.checks[1].files = NIL
    all.checks[1].findings, all.checks[1].findings_total = {}, 0
    all.checks[1].state = "green"
    editor.apply(all)
    eq(
      #vim.diagnostic.get(bufs.d, { namespace = ns_luacheck }),
      0,
      "apply: with --all every file of the check is cleared"
    )
  end

  -- the verdict
  do
    local v = editor.verdict(doc(), 3)
    eq(v.level, "error", "verdict: exit 3 is an error")
    has(v.message, "lint INFRA luals", "verdict: the verdict line")
    has(v.message, "lua-language-server", "verdict: the missing tool is named")
    has(v.message, "stylua fixed: lua/c.lua", "verdict: what the fix changed")
    eq(#v.items, 2, "verdict: the quickfix items")
    local none = editor.verdict(nil, 2, "testing lint: unknown check x")
    eq(none.level, "error", "verdict: no document")
    has(none.message, "unknown check x", "verdict: ... with stderr")
    local red = doc()
    red.exit, red.verdict, red.deciding = 1, "red", "luacheck"
    red.checks[3] = nil
    local rv = editor.verdict(red, 1)
    eq(rv.level, "warn", "verdict: findings are a warning")
    has(rv.message, "lint RED luacheck (2 findings)", "verdict: the red line")
  end

  -- the argv of the child
  do
    local argv = editor.argv({
      root = tmp,
      checks = { "stylua" },
      scope = "file",
      files = { tmp .. "/lua/a.lua" },
      fix = true,
      on_save = true,
    })
    local joined = table.concat(argv, " ")
    has(joined, "lint --json stylua --file=" .. tmp .. "/lua/a.lua --fix --on-save", "argv")
    has(joined, "--root=" .. tmp, "argv: the root")
    local two = editor.argv({ root = tmp, scope = "file", files = { "lua/x,y.lua", "lua/z.lua" } })
    ok(vim.tbl_contains(two, "--file=lua/x,y.lua"), "argv: one --file per file (a comma stays)")
    ok(vim.tbl_contains(two, "--file=lua/z.lua"), "argv: ... the second file")
  end

  -- the order of runs: a run that started earlier never replaces what a later run set
  do
    for _, buf in pairs(bufs) do
      vim.diagnostic.reset(nil, buf)
    end
    local red = doc()
    local green = doc()
    green.checks[1].state, green.checks[1].findings, green.checks[1].findings_total = "green", {}, 0
    editor.apply(green, 1000)
    editor.apply(red, 999)
    eq(
      #vim.diagnostic.get(bufs.a, { namespace = ns_luacheck }),
      0,
      "order: the older run's findings do not replace the newer result"
    )
    editor.apply(red, 1001)
    eq(
      #vim.diagnostic.get(bufs.a, { namespace = ns_luacheck }),
      1,
      "order: a newer run's findings do"
    )
    -- a capped list: a checked file without a listed finding may have been cut off, it keeps what it had
    vim.diagnostic.set(ns_luacheck, bufs.c, stale)
    local capped = doc()
    capped.checks[1].findings_total = 500
    editor.apply(capped, 1002)
    eq(
      #vim.diagnostic.get(bufs.c, { namespace = ns_luacheck }),
      1,
      "capped: nothing is cleared when findings were cut"
    )
    for _, buf in pairs(bufs) do
      vim.diagnostic.reset(nil, buf)
    end
    -- the runs below count from the editor's own sequence
    editor.applied = {}
  end

  -- a run with a stub child: diagnostics, the quickfix list titled "testing lint", the verdict notified
  local real_system, real_notify, real_debounce = editor.system, vim.notify, editor.DEBOUNCE_MS
  local notes = {}
  local finished, failure = pcall(function()
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    for _, buf in pairs(bufs) do
      vim.diagnostic.reset(nil, buf)
    end
    vim.fn.setqflist({}, "r")
    local red = doc()
    red.exit, red.verdict, red.deciding = 1, "red", "luacheck"
    editor.system = function(_, _, on_exit)
      on_exit({ code = 1, stdout = vim.json.encode(red) .. "\n", stderr = "" })
      return { kill = function() end }
    end
    local done = false
    ok(
      editor.run({
        root = tmp,
        on_done = function()
          done = true
        end,
      }),
      "run: started"
    )
    vim.wait(2000, function()
      return done
    end, 10)
    eq(vim.fn.getqflist({ title = 1 }).title, "testing lint", "run: the quickfix list")
    eq(vim.fn.getqflist({ size = 1 }).size, 2, "run: the findings in it")
    eq(#vim.diagnostic.get(bufs.a, { namespace = ns_luacheck }), 1, "run: the diagnostics were set")
    has(table.concat(notes, "\n"), "lint RED luacheck", "run: the verdict was notified")
    vim.cmd("silent! cclose")
    vim.fn.setqflist({}, "r")

    -- quiet (on save): diagnostics only, no quickfix list, no message for findings
    notes = {}
    done = false
    editor.run({
      root = tmp,
      quiet = true,
      on_done = function()
        done = true
      end,
    })
    vim.wait(2000, function()
      return done
    end, 10)
    eq(vim.fn.getqflist({ size = 1 }).size, 0, "quiet: no quickfix list")
    eq(#notes, 0, "quiet: no message")

    -- quiet: "nothing to lint here" (exit 2) says nothing; a check that could not run (exit 3) is told
    local function quiet_run(code, stdout)
      editor.system = function(_, _, on_exit)
        on_exit({ code = code, stdout = stdout, stderr = "testing lint: something" })
        return { kill = function() end }
      end
      local over = false
      editor.run({
        root = tmp,
        quiet = true,
        on_done = function()
          over = true
        end,
      })
      vim.wait(2000, function()
        return over
      end, 10)
    end
    notes = {}
    quiet_run(2, "")
    eq(#notes, 0, "quiet: exit 2 is silent")
    quiet_run(3, vim.json.encode(doc()))
    eq(#notes, 1, "quiet: a missing tool is told")
    has(notes[1], "lua-language-server", "quiet: ... and named")
    notes = {}

    -- --fix refuses a scope with unsaved changes (the fix rewrites the file on disk)
    local calls = 0
    editor.system = function()
      calls = calls + 1
      return { kill = function() end }
    end
    vim.api.nvim_buf_set_lines(bufs.a, 0, -1, false, { "return 1" })
    local refused, why = editor.run({
      root = tmp,
      fix = true,
      scope = "file",
      files = { tmp .. "/lua/a.lua" },
    })
    eq(refused, nil, "fix: refused with an unsaved buffer in scope")
    has(why, "save first", "fix: ... said so")
    eq(editor.run({ root = tmp, fix = true }), nil, "fix: also for the whole root")
    eq(calls, 0, "fix: no child started")
    ok(
      editor.run({ root = tmp, fix = true, scope = "file", files = { tmp .. "/lua/c.lua" } }),
      "fix: a saved file in scope runs"
    )
    eq(calls, 1, "fix: ... in a child")
    vim.bo[bufs.a].modified = false

    -- runs end in another order than they started: the later-started result stays
    local delivered = {}
    editor.system = function(_, _, on_exit)
      delivered[#delivered + 1] = on_exit
      return { kill = function() end }
    end
    local ends = 0
    local function counted()
      ends = ends + 1
    end
    local red_doc = doc()
    red_doc.exit = 1
    local green_doc = doc()
    green_doc.exit = 0
    green_doc.checks[1].state, green_doc.checks[1].findings = "green", {}
    green_doc.checks[1].findings_total = 0
    editor.run({ root = tmp, quiet = true, on_done = counted })
    editor.run({ root = tmp, quiet = true, on_done = counted })
    delivered[2]({ code = 0, stdout = vim.json.encode(green_doc), stderr = "" })
    delivered[1]({ code = 1, stdout = vim.json.encode(red_doc), stderr = "" })
    vim.wait(2000, function()
      return ends == 2
    end, 10)
    eq(
      #vim.diagnostic.get(bufs.a, { namespace = ns_luacheck }),
      0,
      "runs: an older run that ends last does not overwrite the newer result"
    )

    -- on save outside a project: no child at all
    eq(editor.lintable(tmp, tmp .. "/lua/a.lua"), true, "lintable: a file of the project")
    eq(editor.lintable(tmp, tmp .. "-elsewhere/x.lua"), false, "lintable: a file outside the root")
    eq(
      editor.lintable(tmp .. "/lua", tmp .. "/lua/a.lua"),
      false,
      "lintable: a root that is no project"
    )

    -- the check on save: installed by setup, debounced, a newer save stops the older run
    eq(config.validate({ lint = { on_save = true } }).lint, { on_save = true }, "config: valid")
    local _, problems = config.validate({ lint = { on_save = "yes" } })
    has(table.concat(problems, ";"), "'lint'", "config: on_save must be a boolean")
    _, problems = config.validate({ lint = { on_sav = true } })
    has(table.concat(problems, ";"), "'lint'", "config: an unknown key")
    eq(config.get().lint, { on_save = false }, "config: off by default")

    editor.setup({ on_save = true })
    local acs = vim.api.nvim_get_autocmds({ group = editor.AUGROUP, event = "BufWritePost" })
    eq(#acs, 1, "on save: one autocmd")
    eq(acs[1].pattern, "*.lua", "on save: for the files a check reads")
    editor.DEBOUNCE_MS = 150
    local started, killed, exits = {}, 0, {}
    editor.system = function(argv, _, on_exit)
      started[#started + 1] = argv
      exits[#exits + 1] = on_exit
      return {
        kill = function()
          killed = killed + 1
        end,
      }
    end
    editor.on_save(bufs.a)
    editor.on_save(bufs.a)
    vim.wait(30, function()
      return #started > 0
    end, 5)
    eq(#started, 0, "on save: nothing starts before the quiet time")
    vim.wait(1000, function()
      return #started > 0
    end, 10)
    vim.wait(60, function()
      return false
    end, 10)
    eq(#started, 1, "on save: two saves in a row start one check")
    local joined = table.concat(started[1], " ")
    has(joined, "--file=" .. tmp .. "/lua/a.lua", "on save: the written file")
    has(joined, "--on-save", "on save: only the checks that may run on save")
    editor.on_save(bufs.a)
    vim.wait(1000, function()
      return #started > 1
    end, 10)
    eq(#started, 2, "on save: a later save starts again")
    eq(killed, 1, "on save: ... and stops the older run")
    -- the stopped run still ends: its result is dropped
    local stale_red = doc()
    stale_red.exit = 1
    exits[1]({ code = 1, stdout = vim.json.encode(stale_red), stderr = "" })
    vim.wait(100, function()
      return false
    end, 10)
    eq(
      #vim.diagnostic.get(bufs.a, { namespace = ns_luacheck }),
      0,
      "on save: the result of a superseded run is dropped"
    )
    -- a file outside any project starts nothing
    local outsider = vim.fn.bufadd(tmp .. "-elsewhere/x.lua")
    editor.on_save(outsider)
    vim.wait(400, function()
      return false
    end, 10)
    eq(#started, 2, "on save: a file outside a project starts no child")
    pcall(vim.api.nvim_buf_delete, outsider, { force = true })
    editor.setup({ on_save = false })
    eq(
      pcall(vim.api.nvim_get_autocmds, { group = editor.AUGROUP }),
      false,
      "on save: off removes the group"
    )
    eq(next(editor.pending), nil, "on save: nothing pending after off")
  end)
  editor.system, vim.notify, editor.DEBOUNCE_MS = real_system, real_notify, real_debounce
  pcall(editor.setup, { on_save = false })
  vim.cmd("silent! cclose")
  vim.fn.setqflist({}, "r")
  for _, buf in pairs(bufs) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  vim.fn.delete(tmp, "rf")
  ok(finished, "lint editor: " .. tostring(failure))
end
