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

  ---A fake engine: `order` answers the `open` ids, `done[area]` lists the finished ids (pages of `page` items), an
  ---area not in `done` is unknown, `bad[area]` is an area the engine rejects (`invalid_argument`). `fail[method]`
  ---makes that method answer an error that is neither, naming a machine path.
  local function engine(open, done, page, fail, bad)
    local calls = {}
    local function call(method, params)
      calls[#calls + 1] = method .. " " .. (params.area or "") .. " " .. (params.offset or "")
      if fail and fail[method] then
        return nil,
          "tasks.nvim call " .. method .. ": io: disk on fire in C:/secret/tasks-vault/x.md\nstack",
          "io"
      end
      if method == "order" then
        local ids = vim.tbl_keys(open)
        table.sort(ids)
        return { kind = "tasks.order", total = #ids, ids = ids }
      elseif method == "finished" then
        if bad and bad[params.area] then
          return nil, "tasks.nvim call finished: invalid_argument: bad area", "invalid_argument"
        end
        local ids = done[params.area]
        if not ids then
          return nil, "tasks.nvim call finished: not_found: unknown area", "not_found"
        end
        local offset = params.offset or 0
        local items = {}
        for i = offset + 1, math.min(offset + page, #ids) do
          items[#items + 1] = { id = ids[i] }
        end
        local doc = { kind = "tasks.finished", total = #ids, items = items }
        if offset + page < #ids then
          doc.next_offset = offset + page
        end
        return doc
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

  local function no_missing(r, msg)
    for _, f in ipairs(r.findings) do
      ok(not f.message:find("neither an open task", 1, true), msg .. ": " .. f.message)
    end
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
    -- 3. open, finished (second page), unknown, unknown area, rejected id, no task, does not load, loops
    local repo = S.new_repo()
    sheet(repo, "open", "a/open-task")
    sheet(repo, "open-twice", "a/open-task")
    sheet(repo, "done", "a/done-task")
    sheet(repo, "gone", "a/gone-task")
    sheet(repo, "elsewhere", "nowhere/x")
    sheet(repo, "rejected", "../Try_It")
    sheet(repo, "loose", nil)
    sheet(repo, "deep/a/b/c/too-deep", "a/gone-too")
    S.write(repo .. "/TESTS/sheets/broken.sheet.lua", "return { id = \n")
    S.write(repo .. "/TESTS/sheets/loops.sheet.lua", "while true do end\n")
    S.write(repo .. "/TESTS/sheets/not-a-sheet.lua", "return 1\n")
    local call, calls = engine(
      { ["a/open-task"] = true, ["b/other"] = true },
      { a = { "a/other-1", "a/other-2", "a/done-task" } },
      2,
      nil,
      { [".."] = true }
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
    eq(
      by["TESTS/sheets/deep/a/b/c/too-deep.sheet.lua"],
      nil,
      "a sheet deeper than testing.sheet.files looks is not one"
    )
    eq(by["TESTS/sheets/gone.sheet.lua"].level, "error", "an unknown task is an error")
    has(by["TESTS/sheets/gone.sheet.lua"].message, "a/gone-task", "the finding names the task")
    eq(
      by["TESTS/sheets/elsewhere.sheet.lua"].level,
      "error",
      "a task of an unknown area is an error"
    )
    eq(
      by["TESTS/sheets/rejected.sheet.lua"].level,
      "error",
      "an id the engine rejects is a finding of its sheet, not an engine failure"
    )
    eq(by["TESTS/sheets/loose.sheet.lua"].level, "warn", "a sheet without task is a warning")
    eq(by["TESTS/sheets/broken.sheet.lua"].level, "error", "a sheet that does not load is an error")
    has(by["TESTS/sheets/broken.sheet.lua"].message, "does not load", "and says so")
    has(
      by["TESTS/sheets/loops.sheet.lua"].message,
      "takes too long",
      "a sheet that loops ends under the instruction limit"
    )
    eq(#r.findings, 6, "exactly the six findings")
    eq(calls, {
      "order  ",
      "finished .. 0",
      "finished a 0",
      "finished a 2",
      "finished nowhere 0",
    }, "the open ids in one call, each area's Backlog once, page by page")
    eq(conformance.exit_code(report), 0, "report mode: exit 0")
    eq(conformance.exit_code(run(repo, { call = call }, true)), 1, "--gate: exit 1")

    -- ===================================================================
    -- 4. the engine fails: an error (infrastructure), not a missing task; it is asked no more, the reason shows
    -- no path of this machine and no second line
    local call_f, calls_f = engine({}, {}, 10, { order = true })
    local rf = S.check(run(repo, { call = call_f }), "K16")
    eq(rf.status, "error", "an engine that fails is an error")
    has(rf.reason, "disk on fire", "with its message")
    ok(not rf.reason:find("stack", 1, true), "only the first line: " .. rf.reason)
    no_missing(rf, "no task reads as missing")
    eq(#calls_f, 1, "after a failure the engine is asked no more")
    local call_b, calls_b = engine({}, { a = {} }, 10, { finished = true })
    local rb = S.check(run(repo, { call = call_b }), "K16")
    eq(rb.status, "error", "a Backlog that cannot be read is an error")
    no_missing(rb, "not a missing task")
    eq(#calls_b, 2, "the first failing Backlog stops the lookup")

    -- the vault and the engine's checkout are replaced in the reason
    local hide_root = vim.fs.normalize(vim.fn.tempname()) .. "-k16"
    local vault = hide_root .. "/tasks-vault"
    vim.fn.mkdir(vault, "p")
    S.write(
      hide_root .. "/tasks.nvim/scripts/tasks.lua",
      ("io.stdout:write(%q)"):format(vim.json.encode({
        kind = "tasks.error",
        code = "io",
        message = "broken " .. vault .. "/a.md",
      }) .. "\n")
    )
    S.write(hide_root .. "/tasks.nvim/lua/tasks_nvim/init.lua", "return {}\n")
    local rh = S.check(
      run(repo, {
        vault = vault,
        getenv = function()
          return nil
        end,
      }),
      "K16"
    )
    eq(rh.status, "error", "a real caller's error document is an error")
    local tasks_mod = require("testing.sheet.tasks")
    local _, _, code =
      tasks_mod.caller(hide_root .. "/tasks.nvim/scripts/tasks.lua", vault)("order", {})
    eq(code, "io", "the caller hands back the engine's error code")
    has(rh.reason, "<VAULT>/a.md", "the vault path is replaced")
    ok(not rh.reason:find(hide_root, 1, true), "no path of this machine: " .. rh.reason)
    vim.fn.delete(hide_root, "rf")

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
    ok(not rn.reason:find(vim.fs.dirname(clean), 1, true), "and no path: " .. rn.reason)
    local rv = S.check(run(clean, { vault = clean .. "/no-such-dir", getenv = noenv }), "K16")
    eq(rv.status, "n/a", "a vault that is not a directory: n/a")
    local rbroken = S.check(run(repo, { getenv = noenv }), "K16")
    eq(rbroken.status, "fail", "no vault, but a sheet that does not load: still a failure")
    local notes = table.concat(rbroken.notes, "\n")
    has(notes, "not looked up", "the note says the tasks were not looked up")
  end)
end
