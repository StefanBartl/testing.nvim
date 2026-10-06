-- TESTS/testing/run_guards_spec.lua -- the runner's seam to the guard layer (`testing.run.guards`) and where the
-- in-process driver opens and closes the guard window: one window per file for the one-case dialects, one per
-- `it` for busted (at the selector call, with the case's id), findings and effects land on the right case, a
-- finding of severity `error` makes the run red, and without a guard layer the cases say effects were not measured.

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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local guards = require("testing.run.guards")
  local inproc = require("testing.run.inproc")
  local result = require("testing.core.result")

  ---A fake guard layer that records every call, and answers `end_case` from a script.
  ---@param script? fun(case_ctx: table, n: integer): table|nil  What `end_case` returns for the n-th window.
  local function fake(script)
    local log = { calls = {} }
    local windows = 0
    local handle = {}
    function handle:begin_case(ctx, opts)
      windows = windows + 1
      log.calls[#log.calls + 1] =
        { "begin", ctx and ctx.id, ctx and ctx.file, opts and opts.heavy or false }
      log.ctx = ctx
    end
    function handle:end_case()
      log.calls[#log.calls + 1] = { "end" }
      return (script and script(log.ctx, windows)) or { findings = {}, effects = {} }
    end
    function handle:collect()
      return { notes = { "a note of the guard layer" } }
    end
    function handle:uninstall()
      log.calls[#log.calls + 1] = { "uninstall" }
      return {}
    end
    local module = {
      install = function(cfg)
        log.cfg = cfg
        return handle
      end,
    }
    return module, log
  end

  -- ================================================================== install
  local session = guards.install(nil)
  eq(session.active, false, "no configuration, no guards")
  session = guards.install({}, {})
  eq(session.active, false, "a module without `install` is no guard layer")
  eq(session.error, nil, "and no error")
  session = guards.install({}, {
    install = function()
      error("kaboom")
    end,
  })
  eq(session.active, false, "an install that raises is inactive")
  has(session.error, "failed to install", "and says so")
  has(session.error, "kaboom", "with the reason")
  local mod, log = fake()
  session = guards.install({ marker = 1 }, mod)
  eq(session.active, true, "a working layer is active")
  eq(log.cfg, { marker = 1 }, "it got the configuration")

  -- the real layer of this checkout is found, with the adapter's configuration
  eq(guards.available(), true, "testing.guard is part of this checkout")

  -- ================================================================== the window
  session:open({ id = "a", file = "f" }, { heavy = true })
  session:open({ id = "b", file = "f" })
  eq(#log.calls, 1, "a second open while a window is open does nothing")
  eq(log.calls[1], { "begin", "a", "f", true }, "the first open: id, file, heavy")
  local findings, effects = session:close()
  eq({ #findings, effects ~= nil }, { 0, true }, "close returns what end_case returned")
  eq({ session:close() }, { {}, nil }, "closing without a window returns nothing")
  eq(#log.calls, 2, "and does not call the layer")

  -- findings of the layer become IR findings: a count, the id, the case
  mod = fake(function()
    return {
      findings = {
        {
          id = "state.autocmd",
          guard = "state",
          severity = "warn",
          message = "leaks X",
          case = "c1",
          count = 3,
        },
        { guard = "prompt", severity = "error", message = "asked", count = 1 },
        "not a table",
      },
      effects = { spawned = { "git status" }, network = {}, fs_outside_tmp = {} },
    }
  end)
  session = guards.install({}, mod)
  session:open({ id = "c1", file = "f" })
  findings, effects = session:close()
  eq(#findings, 2, "a malformed finding is dropped")
  eq(findings[1], {
    guard = "state",
    severity = "warn",
    message = "leaks X (x3)",
    id = "state.autocmd",
    case = "c1",
  }, "count, id and case are kept")
  eq(findings[2].message, "asked", "a count of 1 adds nothing")
  eq(assert(effects).spawned, { "git status" }, "effects pass through")

  -- a layer that raises in begin/end never takes the run down
  local bad = guards.install({}, {
    install = function()
      return {
        begin_case = function()
          error("begin exploded")
        end,
        end_case = function()
          error("end exploded")
        end,
      }
    end,
  })
  bad:open({ file = "f" })
  eq(bad.is_open, false, "a begin that raised opened no window")
  has(bad.error, "begin exploded", "and the reason is kept")
  local good = guards.install({}, {
    install = function()
      return {
        begin_case = function() end,
        end_case = function()
          error("end exploded")
        end,
      }
    end,
  })
  good:open({ file = "f" })
  eq({ good:close() }, { {}, nil }, "an end that raised returns nothing")
  has(good.error, "end exploded", "and keeps the reason")

  -- uninstall: notes of the layer, patches that could not be undone, idempotent
  mod, log = fake()
  session = guards.install({}, mod)
  session:open({ file = "f" })
  session:uninstall()
  session:uninstall()
  eq(session.is_open, false, "uninstall closes an open window")
  eq(session.notes, { "a note of the guard layer" }, "the layer's own notes are collected")
  local count = 0
  for _, c in ipairs(log.calls) do
    if c[1] == "uninstall" then
      count = count + 1
    end
  end
  eq(count, 1, "and the layer is uninstalled once")
  local stuck = guards.install({}, {
    install = function()
      return {
        uninstall = function()
          return { "vim.system" }
        end,
      }
    end,
  })
  stuck:uninstall()
  has(
    table.concat(stuck.notes, "\n"),
    "could not be undone: vim.system",
    "a patch that stayed is named"
  )

  -- ================================================================== attach
  local function new_case(name, status)
    local c = result.new_case({ file = "TESTS/x_spec.lua", name = name })
    c.assertions[1] = { ok = true, kind = "eq" }
    result.finish_case(c)
    if status then
      c.status = status
    end
    return c
  end
  local c1, c2 = new_case("one"), new_case("two")
  local left = guards.attach({ c1, c2 }, {
    { guard = "fs", severity = "warn", message = "wrote outside" },
    { guard = "prompt", severity = "error", message = "asked", case = c1.id },
    { guard = "state", severity = "info", message = "loads module m" },
    { guard = "fs", severity = "warn", message = "wrote outside" },
  }, { spawned = { "git log" }, network = { "example.org" } })
  eq(left, {}, "everything found a case")
  eq(c1.status, "fail", "an error finding fails the case it names")
  eq(c1.guards[1].severity, "error", "and is recorded")
  local gassert
  for _, a in ipairs(c1.assertions) do
    if a.kind == "guard" then
      gassert = a
    end
  end
  ok(gassert and gassert.ok == false, "as a failed `guard` assertion")
  has(gassert.msg, "guard prompt: asked", "that names the guard and the finding")
  eq(c2.status, "pass", "a warning does not fail")
  eq(#c2.guards, 2, "a repeated finding is recorded once (warn + info)")
  eq(c2.guards[1].severity, "warn", "the warning")
  eq(c2.guards[2].severity, "info", "and the info (never failing)")
  eq(c2.effects.spawned, { "git log" }, "flat effects land on the last case")
  eq(c2.effects.network, { "example.org" }, "all three lists")
  eq(c1.effects.spawned, {}, "and not on the first")
  for _, c in ipairs({ c1, c2 }) do
    local res = result.new({})
    result.add_case(res, c)
    result.finalize(res)
    local valid, problems = result.validate(res, { allow_abs_paths = true })
    eq({ valid, problems }, { true, {} }, "the case with findings is a valid IR: " .. c.id)
  end
  local m1, m2 = new_case("m1"), new_case("m2")
  guards.attach(
    { m1, m2 },
    {},
    { [m1.id] = { spawned = { "a" } }, [m2.id] = { spawned = { "b" } } }
  )
  eq({ m1.effects.spawned, m2.effects.spawned }, { { "a" }, { "b" } }, "effects by case id")
  local left2 = guards.attach({}, { { guard = "fs", severity = "warn", message = "x" } }, nil)
  eq(#left2, 1, "no case: the finding is handed back, not lost")

  -- a failing case stays what it is (no second verdict), but the finding is there
  local f1 = new_case("failed", "error")
  guards.attach({ f1 }, { { guard = "prompt", severity = "error", message = "asked" } })
  eq(f1.status, "error", "an `error` case stays an error")
  eq(#f1.guards, 1, "and carries the finding")

  -- ================================================================== the in-process driver
  local root = S.new_root()
  local a_file = S.project(root, {
    ["TESTS/a_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "a")\nend\n',
  }, { "TESTS/a_spec.lua" })[1]
  local busted_file = S.project(root, {
    ["TESTS/b_spec.lua"] = 'describe("d", function()\n  it("one @spawn", function() assert.is_true(true) end)\n  it("two", function() assert.is_true(true) end)\nend)\n',
  }, { "TESTS/b_spec.lua" }, "busted")[1]

  -- one-case dialect: ONE window, with the file's case id, heavy
  mod, log = fake(function()
    return {
      findings = { { guard = "fs", severity = "warn", message = "wrote outside" } },
      effects = { spawned = { "git" }, network = {}, fs_outside_tmp = {} },
    }
  end)
  local rep =
    inproc.run({ root = root, files = { a_file }, guard_session = guards.install({}, mod) })
  eq(
    log.calls[1],
    { "begin", "TESTS/a_spec.lua::a_spec.lua", "TESTS/a_spec.lua", true },
    "dialect a: the window opens with the file case id, heavy"
  )
  eq(log.calls[2], { "end" }, "and closes when the case is reported")
  eq(#log.calls, 2, "nothing else (the caller owns uninstall)")
  local case = rep.result.cases[1]
  eq(case.guards[1].message, "wrote outside", "the finding is on the case")
  eq(case.effects.spawned, { "git" }, "and so are the effects")
  ok(
    not table.concat(case.notes, "\n"):find("effects: not collected", 1, true),
    "an active layer: no `not collected` note"
  )

  -- busted: one window per `it`, at the selector call, with the id
  mod, log = fake()
  rep =
    inproc.run({ root = root, files = { busted_file }, guard_session = guards.install({}, mod) })
  eq(#rep.result.cases, 2, "two cases")
  eq(
    log.calls,
    {
      { "begin", "TESTS/b_spec.lua::d::one @spawn", "TESTS/b_spec.lua", true },
      { "end" },
      { "begin", "TESTS/b_spec.lua::d::two", "TESTS/b_spec.lua", false },
      { "end" },
    },
    "busted: a window per case, with its id (so `@spawn` in a title reaches the layer), heavy only the first time"
  )

  -- a selection that skips a case opens no window for it
  local select_mod = require("testing.run.select")
  mod, log = fake()
  inproc.run({
    root = root,
    files = { busted_file },
    guard_session = guards.install({}, mod),
    selector = select_mod.new({ filter = { "two" } }),
  })
  eq(#log.calls, 2, "--filter two: one window")
  eq(log.calls[1][2], "TESTS/b_spec.lua::d::two", "for the selected case")

  -- an error finding turns the run red, and the report says so
  mod = fake(function(ctx)
    if ctx.id and ctx.id:find("two", 1, true) then
      return {
        findings = {
          {
            guard = "scheduled_error",
            severity = "error",
            message = "E5108 in a timer",
            id = "scheduled.error",
          },
        },
      }
    end
    return { findings = {} }
  end)
  rep =
    inproc.run({ root = root, files = { busted_file }, guard_session = guards.install({}, mod) })
  eq(rep.exit_code, 1, "a guard error is a red run")
  eq(rep.failed, 1, "one failed case")
  eq(
    { rep.result.cases[1].status, rep.result.cases[2].status },
    { "pass", "fail" },
    "the case that triggered it"
  )
  eq(rep.result.cases[2].guards[1].id, "scheduled.error", "with the id of the finding")
  eq(rep.result.cases[1].guards, nil, "the other case has none")

  -- own install by configuration (`guard_cfg`), uninstalled at the end, notes go to the report
  mod, log = fake()
  local real_require = package.loaded["testing.guard"]
  package.loaded["testing.guard"] = mod
  local own = inproc.run({
    root = root,
    files = { a_file },
    guard_cfg = { marker = 2 } --[[@as any]],
  })
  package.loaded["testing.guard"] = real_require
  eq(log.cfg, { marker = 2 }, "guard_cfg: installed with that configuration")
  eq(log.calls[#log.calls], { "uninstall" }, "and uninstalled at the end of the run")
  eq(own.notes, { "a note of the guard layer" }, "the layer's notes come back in the report")
  eq(own.exit_code, 0, "green")

  -- without a guard layer in the run: the honest note, no guards
  local plain = inproc.run({ root = root, files = { a_file } })
  has(
    table.concat(plain.result.cases[1].notes, "\n"),
    "effects: not collected",
    "no layer: the cases say effects were not measured"
  )
  eq(plain.result.cases[1].guards, nil, "and have no findings")

  -- findings of a file that has no case to carry them are handed back, not dropped
  local leaky = S.project(root, {
    ["TESTS/leaky_spec.lua"] = 'describe("d", function()\n  rawset(_G, "iso_unattached", 1)\n  it("never selected", function() assert.is_true(true) end)\nend)\n',
  }, { "TESTS/leaky_spec.lua" }, "busted")[1]
  local isolation = require("testing.isolation")
  local none = inproc.run({
    root = root,
    files = { leaky },
    soft = isolation.new({ severity = "warn" }),
    selector = select_mod.new({ filter = { "no such case anywhere" } }),
  })
  eq(#none.result.cases, 0, "nothing selected, nothing ran")
  eq(rawget(_G, "iso_unattached"), nil, "the describe body's global was restored")
  eq(#none.unattached, 1, "but its leak has no case to sit on")
  has(
    none.unattached[1].message,
    "TESTS/leaky_spec.lua: TESTS/leaky_spec.lua leaves global `iso_unattached`",
    "it is handed back, with the file named"
  )

  S.cleanup()
end
