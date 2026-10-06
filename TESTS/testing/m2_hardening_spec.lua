---@diagnostic disable: need-check-nil, undefined-field, missing-fields, redundant-parameter, duplicate-set-field, assign-type-mismatch
-- TESTS/testing/m2_hardening_spec.lua -- the review of milestone M2, in-process parts: a guard layer that cannot
-- be built is rolled back, the in-process driver always undoes its own layer, the report paths that
-- print what a spec printed escape it, the IR keeps the stack of a finding, an old lib.nvim is named, and the
-- terminal summary points at the rest. (The warm-pool parts live in pool_hardening_spec.lua.)

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
      msg .. " (got " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. needle:gsub("%c", "?") .. " in " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local guard = require("testing.guard")
  local guards = require("testing.run.guards")
  local inproc = require("testing.run.inproc")
  local select_mod = require("testing.run.select")
  local result = require("testing.core.result")

  -- ===================================================================
  -- 1. a guard that cannot be installed rolls back the ones before it (no handle, no way to undo them)
  do
    local orig_open, orig_system = io.open, vim.system
    local live_before = guard.live_count()
    local real_state = package.loaded["testing.guard.state"]
    package.loaded["testing.guard.state"] = {
      new = function()
        error("boom-state", 0)
      end,
    }
    local installed, err = pcall(guard.install, { guards = { clock = "off" } })
    package.loaded["testing.guard.state"] = real_state
    eq(installed, false, "install raises when one guard cannot be built")
    has(err, "installing the 'state' guard failed", "the message names the guard")
    has(err, "boom-state", "and the cause")
    ok(
      io.open == orig_open,
      "io.open is the original again (the fs guard that came before was rolled back)"
    )
    ok(vim.system == orig_system, "vim.system is the original again (process_net was rolled back)")
    eq(guard.live_count(), live_before, "no installed layer is left behind")
  end

  -- 2. the registry of installed layers
  do
    local before = guard.live_count()
    local h = guard.install({ guards = { fs = "off", state = "off", process_net = "off" } })
    eq(guard.live_count(), before + 1, "an installed layer is counted")
    h:uninstall()
    eq(guard.live_count(), before, "an uninstalled one is not")
    h:uninstall() -- idempotent
    eq(guard.live_count(), before, "and uninstalling twice changes nothing")
  end

  -- ===================================================================
  -- 3. the in-process driver undoes its own layer on EVERY path (a pool member lives on)
  local root = S.new_root()
  local a_file = S.project(
    root,
    { ["TESTS/a_spec.lua"] = 'return function(H) H.ok(true, "x") end\n' },
    { "TESTS/a_spec.lua" }
  )[1]
  do
    local log = { calls = {} }
    local handle = {}
    function handle:begin_case() end
    function handle:end_case()
      return { findings = {}, effects = {} }
    end
    function handle:collect()
      return { notes = {} }
    end
    function handle:uninstall()
      log.calls[#log.calls + 1] = "uninstall"
      return {}
    end
    local fake = {
      install = function()
        return handle
      end,
    }
    local real_guard = package.loaded["testing.guard"]
    local real_tags = select_mod.file_header_tags
    package.loaded["testing.guard"] = fake
    -- `record(case)` runs outside any pcall: a bug in it must still end with the layer uninstalled
    select_mod.file_header_tags = function()
      error("kaboom-in-record", 0)
    end
    local ran, err = pcall(inproc.run, { root = root, files = { a_file }, guard_cfg = {} })
    select_mod.file_header_tags = real_tags
    package.loaded["testing.guard"] = real_guard
    eq(ran, false, "the driver raises (a bug in the report path)")
    has(tostring(err), "kaboom-in-record", "with the original error")
    eq(log.calls, { "uninstall" }, "and the guard layer it installed was uninstalled anyway")
  end

  -- 4. a layer that could not be installed is on the cases, not only in a note nobody reads
  do
    local fake = {
      install = function()
        error("no api here", 0)
      end,
    }
    local real_guard = package.loaded["testing.guard"]
    package.loaded["testing.guard"] = fake
    local rep = inproc.run({ root = root, files = { a_file }, guard_cfg = {} })
    package.loaded["testing.guard"] = real_guard
    local notes = table.concat(rep.result.cases[1].notes, "\n")
    has(
      notes,
      "guards: the guard layer failed to install: no api here",
      "the case says why it is unguarded"
    )
  end

  -- ===================================================================
  -- 5. what a spec printed is escaped before it reaches the terminal and the CI log
  do
    local cli = require("testing.cli")
    local state_dir = vim.fs.normalize(vim.fn.tempname())
    local proot = S.new_root()
    S.write(
      proot .. "/.testing.lua",
      'return { dialect = "a", minit = false, isolated = "file" }\n'
    )
    S.write(proot .. "/TESTS/a_spec.lua", 'return function(H) H.ok(true, "x") end\n')
    local real_inproc = require("testing.run.inproc")
    local spy = {
      run = function(opts)
        opts.on_output(
          "TESTS/a_spec.lua",
          "\27[31mred\27[0m \27]8;;http://evil.example\7link\27]8;;\7\n"
            .. "::error file=x::forged annotation\n"
            .. "\t::stop-commands::token\n"
            .. "carriage\rreturn \u{202E}bidi\n"
            .. "plain line"
        )
        return real_inproc.run({
          root = opts.root,
          files = opts.files,
          argv = opts.argv,
          selector = opts.selector,
          timeouts = opts.timeouts,
        })
      end,
    }
    local out, err = {}, {}
    local code = cli.main({ proot, "--isolated", "file" }, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
      isolated = spy,
    })
    local text = table.concat(err, "\n")
    eq(code, 0, "the run is green: " .. text)
    has(text, "output of TESTS/a_spec.lua:", "the child output is printed")
    has(text, "plain line", "a plain line stays as it is")
    lacks(text, "\27", "no ESC byte reaches the terminal")
    lacks(text, "\7", "no BEL byte reaches the terminal")
    lacks(text, "\r", "no bare carriage return reaches the terminal")
    lacks(text, "\u{202E}", "no bidi override reaches the terminal")
    has(text, "\\x1B[31mred", "the escape sequence is visible instead")
    has(
      text,
      "\\x1B]8;;http://evil.example\\x07link",
      "an OSC 8 hyperlink is visible text, not a link"
    )
    lacks(text, "\n  ::error", "a workflow command at the start of a line is defused")
    has(text, "  \\x3A:error file=x::forged annotation", "and says what it was")
    has(
      text,
      "  \\x09::stop-commands::token",
      "a tab is shown as \\x09, so nothing after it is at the start of a line"
    )
    S.cleanup()
  end

  -- ===================================================================
  -- 6. the IR keeps the stack of a finding (a deprecation without a call site is not actionable)
  do
    local case = result.new_case({ file = "TESTS/a_spec.lua", name = "x" })
    case.status = "pass"
    local left = guards.attach({ case }, {
      {
        guard = "deprecation",
        severity = "warn",
        id = "deprecation.used",
        message = "spec x uses a deprecated API: vim.highlight",
        stack = "stack traceback:\n\tlua/plugin/hl.lua:4: in function 'setup'",
      },
    })
    eq(#left, 0, "the finding is attached")
    eq(
      case.guards[1].stack,
      "stack traceback:\n\tlua/plugin/hl.lua:4: in function 'setup'",
      "with its stack"
    )
    -- ... and on the way from the guard layer through the session of the runner
    local handle = {}
    function handle:begin_case() end
    function handle:end_case()
      return {
        findings = {
          {
            guard = "deprecation",
            severity = "warn",
            id = "deprecation.used",
            message = "spec uses a deprecated API",
            stack = "stack traceback:\n\tcall site",
          },
        },
        effects = {},
      }
    end
    function handle:uninstall()
      return {}
    end
    local session = guards.install({}, {
      install = function()
        return handle
      end,
    })
    local rep = inproc.run({ root = root, files = { a_file }, guard_session = session })
    eq(
      rep.result.cases[1].guards[1].stack,
      "stack traceback:\n\tcall site",
      "through the session: the stack arrives in the IR"
    )
    local long = result.new_case({ file = "TESTS/b_spec.lua", name = "y" })
    long.status = "pass"
    result.add_guard_finding(
      long,
      { guard = "x", severity = "info", message = "m", stack = ("s"):rep(5000) }
    )
    eq(#long.guards[1].stack, 2000, "a stack is bounded")
    case.assertions[1] = { ok = true, kind = "eq" }
    local with_bad =
      result.new({ root = "/p", project_key = "k", nvim = "0.12", os = "x", arch = "y" })
    result.add_case(with_bad, case)
    result.finalize(with_bad)
    local valid = result.validate(with_bad)
    eq(valid, true, "an IR with a stack validates")
    case.guards[1].stack = 7 --[[@as any]]
    local invalid, problems = result.validate(with_bad)
    eq(invalid, false, "a stack that is not a string does not")
    has(table.concat(problems, "\n"), ".stack: must be a string", "and the problem is named")
  end

  -- ===================================================================
  -- 7. a lib.nvim that is too old is named (it used to end in "attempt to call method 'with'")
  do
    local isolated = require("testing.run.isolated")
    eq(isolated.lib_problem(), nil, "the lib.nvim of this run has what the driver needs")
    local problem = isolated.lib_problem({ Semaphore = { new = function() end } })
    has(problem, "lib.nvim is too old", "a copy without Semaphore:with is called too old")
    has(problem, ".deps/lib.nvim", "and the places that can hold a stale copy are named")
    has(
      isolated.lib_problem({}) or "",
      "lib.nvim is too old",
      "no Semaphore at all is too old as well"
    )
    local ran, err = pcall(isolated.run, { root = root, files = { a_file }, lib_async = {} })
    eq(ran, false, "the driver refuses to start")
    has(tostring(err), "lib.nvim is too old", "and says why instead of crashing on a nil method")
  end

  -- ===================================================================
  -- 8. the terminal summary: the culprit is not cut at the screen width, and the rest is pointed at
  do
    local term = require("testing.report.term")
    local F = dofile(dir .. "/report_fixture.lua")
    local res = F.mixed()
    local target = res.cases[1]
    for i = 1, 45 do
      result.add_guard_finding(target, {
        guard = "state",
        severity = "warn",
        id = "state.autocmd",
        message = ("spec s%d leaves autocmd BufEnter in group G%d %s"):format(
          i,
          i,
          i == 1 and ("x"):rep(150) .. " TAIL-MARKER" or ""
        ),
      })
    end
    local lines = term.render(res)
    local text = table.concat(lines, "\n")
    has(text, "TAIL-MARKER", "a long finding message is not cut at the width of the screen")
    has(
      text,
      "... and 5 more (all of them, with their stacks: --json <file>)",
      "the rest is pointed at"
    )
  end

  S.cleanup()
end
