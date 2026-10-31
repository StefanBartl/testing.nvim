-- TESTS/testing/conformance_sheets_spec.lua -- K16: every test sheet loads and names a task of the vault (open or
-- finished). The engine of tasks.nvim is replaced by a fake `call`; no child editor, no vault on disk.

---@diagnostic disable: need-check-nil -- the case body is the guard: a nil raises and fails the case
return function(H)
  local ok = H.ok
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/conformance/support.lua")
  local conformance = require("testing.conformance")

  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      ("%s: %q not in %s"):format(msg, needle, tostring(haystack):sub(1, 400))
    )
  end

  local function probe()
    return nil, "no child editor in this spec"
  end

  ---A sheet file of the manual engine (nothing to run) that names `task`.
  local function sheet(root, name, task)
    S.write(
      root .. "/TESTS/sheets/" .. name .. ".sheet.lua",
      ('return { id = %q, title = %q,%s engine = "manual", manual = { "look" } }\n'):format(
        name,
        name,
        task and (" task = %q,"):format(task) or ""
      )
    )
  end

  ---A fake engine: `open` ids answer `task`, `done[area]` lists the finished ids (pages of `page` items), an area
  ---not in `done` is unknown. `fail[method]` makes that method answer an error that is not `not_found`.
  local function engine(open, done, page, fail)
    local calls = {}
    local function call(method, params)
      calls[#calls + 1] = method
        .. " "
        .. (params.id or params.area or "")
        .. " "
        .. (params.offset or "")
      if fail and fail[method] then
        return nil, "tasks.nvim call " .. method .. ": io: disk on fire", "io"
      end
      if method == "task" then
        if open[params.id] then
          return { kind = "tasks.task", task = { id = params.id } }
        end
        return nil, "tasks.nvim call task: not_found: no such task", "not_found"
      elseif method == "finished" then
        local ids = done[params.area]
        if not ids then
          return nil, "tasks.nvim call finished: not_found: unknown area", "not_found"
        end
        local items = {}
        for i = (params.offset or 0) + 1, math.min((params.offset or 0) + page, #ids) do
          items[#items + 1] = { id = ids[i] }
        end
        return { kind = "tasks.finished", total = #ids, items = items }
      end
      error("unexpected method " .. method)
    end
    return call, calls
  end

  local function run(root, tasks, gate)
    return conformance.run(
      root,
      { only = { "K16" }, probe = probe, settings = {}, tasks = tasks, gate = gate }
    )
  end

  S.run(function()
    -- ===================================================================
    -- 1. the catalog knows K16
    ok(require("testing.conformance.catalog").ids().K16 == true, "K16 is a check id")
    eq(require("testing.conformance.catalog").get("K16").id, "K16", "get finds K16")

    -- ===================================================================
    -- 2. no sheets: n/a, and the engine is never asked
    local bare = S.new_repo()
    local call0, calls0 = engine({}, {}, 10)
    local r0 = S.check(run(bare, { call = call0 }), "K16")
    eq(r0.status, "n/a", "no sheets: n/a")
    has(r0.reason, "no test sheets", "the reason")
    eq(#calls0, 0, "no sheets: the vault is not asked")

    -- ===================================================================
    -- 3. open, finished (on the second page), unknown, unknown area, no task, does not load
    local repo = S.new_repo()
    sheet(repo, "open", "a/open-task")
    sheet(repo, "open-twice", "a/open-task")
    sheet(repo, "done", "a/done-task")
    sheet(repo, "gone", "a/gone-task")
    sheet(repo, "elsewhere", "nowhere/x")
    sheet(repo, "loose", nil)
    S.write(repo .. "/TESTS/sheets/broken.sheet.lua", "return { id = \n")
    S.write(repo .. "/TESTS/sheets/not-a-sheet.lua", "return 1\n")
    local call, calls = engine(
      { ["a/open-task"] = true },
      { a = { "a/other-1", "a/other-2", "a/done-task" } },
      2
    )
    local report = run(repo, { call = call })
    local r = S.check(report, "K16")
    eq(r.status, "fail", "a missing task fails the check")
    local by = {}
    for _, f in ipairs(r.findings) do
      by[f.file] = f
    end
    eq(by["TESTS/sheets/open.sheet.lua"], nil, "an open task is fine")
    eq(by["TESTS/sheets/open-twice.sheet.lua"], nil, "a second sheet of the same task too")
    eq(
      by["TESTS/sheets/done.sheet.lua"],
      nil,
      "a finished task (second page of the Backlog) is fine"
    )
    eq(by["TESTS/sheets/not-a-sheet.lua"], nil, "a file that is not *.sheet.lua is not a sheet")
    eq(by["TESTS/sheets/gone.sheet.lua"].level, "error", "an unknown task is an error")
    has(by["TESTS/sheets/gone.sheet.lua"].message, "a/gone-task", "the finding names the task")
    eq(
      by["TESTS/sheets/elsewhere.sheet.lua"].level,
      "error",
      "a task of an unknown area is an error"
    )
    eq(by["TESTS/sheets/loose.sheet.lua"].level, "warn", "a sheet without task is a warning")
    eq(by["TESTS/sheets/broken.sheet.lua"].level, "error", "a sheet that does not load is an error")
    has(by["TESTS/sheets/broken.sheet.lua"].message, "does not load", "and says so")
    eq(#r.findings, 4, "exactly the four findings")
    eq(calls, {
      "task a/done-task ",
      "finished a 0",
      "finished a 2",
      "task a/gone-task ",
      "task a/open-task ",
      "task nowhere/x ",
      "finished nowhere 0",
    }, "each task asked once, each area's Backlog read once, page by page")
    eq(conformance.exit_code(report), 0, "report mode: exit 0")
    eq(conformance.exit_code(run(repo, { call = call }, true)), 1, "--gate: exit 1")

    -- ===================================================================
    -- 4. the engine fails: an error (infrastructure), not a missing task
    local call_f = engine({}, {}, 10, { task = true })
    local rf = S.check(run(repo, { call = call_f }), "K16")
    eq(rf.status, "error", "an engine that fails is an error")
    has(rf.reason, "disk on fire", "with its message")
    for _, f in ipairs(rf.findings) do
      ok(
        not f.message:find("neither an open task", 1, true),
        "no task reads as missing: " .. f.message
      )
    end
    local call_b = engine({}, { a = {} }, 10, { finished = true })
    local rb = S.check(run(repo, { call = call_b }), "K16")
    eq(rb.status, "error", "a Backlog that cannot be read is an error")
    for _, f in ipairs(rb.findings) do
      ok(not f.message:find("neither an open task", 1, true), "not a missing task: " .. f.message)
    end

    -- ===================================================================
    -- 5. no vault: the lookup is skipped (n/a), never a failure; a broken sheet still is one
    local function noenv()
      return nil
    end
    local clean = S.new_repo()
    sheet(clean, "open", "a/open-task")
    local rn = S.check(run(clean, { getenv = noenv }), "K16")
    eq(rn.status, "n/a", "no vault: n/a")
    has(rn.reason, "no vault", "the reason names the missing vault")
    local rv = S.check(run(clean, { vault = clean .. "/no-such-dir", getenv = noenv }), "K16")
    eq(rv.status, "n/a", "a vault that is not a directory: n/a")
    local rbroken = S.check(run(repo, { getenv = noenv }), "K16")
    eq(rbroken.status, "fail", "no vault, but a sheet that does not load: still a failure")
    local notes = table.concat(rbroken.notes, "\n")
    has(notes, "not looked up", "the note says the tasks were not looked up")
  end)
end
