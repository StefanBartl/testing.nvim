-- TESTS/testing/run_isolated_spec.lua -- how the parent turns what a child left behind into the cases
-- of its file (pure `classify`: exit code 139, signals, torn / invalid fragments, kills by deadline),
-- and the wiring of the isolated driver into `testing run` (flags, config, exit codes, the minit, no
-- child for `--list`). A few end-to-end runs go through `cli.main` with real children.

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
  local isolated = require("testing.run.isolated")
  local result = require("testing.core.result")
  local child = require("testing.child")

  -- ===================================================================
  -- classify: pure
  local REL = "TESTS/a_spec.lua"
  local function ok_case(name)
    local c = result.new_case({ file = REL, name = name })
    c.assertions[1] = { ok = true, kind = "eq" }
    return c
  end
  local function frag(cases, done)
    return { cases = cases, done = done, bad_lines = 0, missing = #cases == 0 and done == nil }
  end
  local function classify(over)
    return isolated.classify(vim.tbl_extend("force", {
      rel = REL,
      kind = "cases",
      frag = frag({ ok_case("x") }, { k = "done" }),
      code = 0,
      signal = 0,
      out = "",
      stdout = "",
      err = "",
      wall_ms = 5,
      file_ms = 1000,
      case_ms = 500,
      grace_ms = 200,
      describe_exit = "exit code 0",
    }, over or {}))
  end

  local cases = classify({})
  eq(#cases, 1, "a finished child: its own cases, nothing added")
  eq(cases[1].status, "pass", "and their status")

  -- exit code 139 / signals / NTSTATUS without a done record: crash, with the stderr tail
  for _, code in ipairs({ 139, 134, 3221225477, 1, 3 }) do
    local cs = classify({
      frag = frag({}, nil),
      code = code,
      describe_exit = "exit code " .. code,
      err = "line one\nthe last words",
    })
    eq(#cs, 1, "exit " .. code .. ": one case")
    eq(cs[1].status, "crash", "exit " .. code .. ": crash")
    eq(cs[1].file, REL, "exit " .. code .. ": for that file")
    eq(cs[1].id, REL .. "::a_spec.lua", "exit " .. code .. ": the file case id")
    has(cs[1].error.message, "exit code " .. code, "exit " .. code .. ": names the code")
    has(cs[1].error.message, "the last words", "exit " .. code .. ": and the stderr tail")
  end
  local sig =
    classify({ frag = frag({}, nil), code = 0, signal = 11, describe_exit = "signal 11 (SIGSEGV)" })
  eq(sig[1].status, "crash", "a signal is a crash, whatever the code says")

  -- exit 0 without a done record: the editor was quit by the spec / stdin ended
  local early = classify({ frag = frag({}, nil), code = 0 })
  eq(early[1].status, "crash", "exit 0 without finishing is a crash, never green")
  has(early[1].error.message, "before the file was finished", "and says why")

  -- a non-zero exit AFTER the done record keeps the cases and adds a crash case
  local late = classify({ code = 139, describe_exit = "exit code 139" })
  eq(#late, 2, "cases and the crash case")
  eq(late[1].status, "pass", "the finished case is kept")
  eq(late[2].status, "crash", "the exit is not forgotten")
  ok(late[1].id ~= late[2].id, "with a distinct id")

  -- partial cases survive a crash (busted: the cases before the crash)
  local partial = classify({
    frag = frag({ ok_case("one"), ok_case("two") }, nil),
    code = 139,
    describe_exit = "exit code 139",
  })
  eq(#partial, 3, "two finished cases and the crash")
  eq(
    { partial[1].status, partial[2].status, partial[3].status },
    { "pass", "pass", "crash" },
    "in order"
  )

  -- streamed (progress) cases are what a killed child leaves; a finished child's final records win
  local streamed = { ok_case("early one"), ok_case("early two") }
  local killed_stream = classify({
    frag = { cases = {}, progress = streamed, done = nil, bad_lines = 0, missing = false },
    code = 1,
    reason = "stall",
  })
  eq(#killed_stream, 3, "a killed child: its streamed cases and the timeout")
  eq(killed_stream[1].id, REL .. "::early one", "the streamed cases come first")
  local finished_stream = classify({
    frag = {
      cases = { ok_case("final") },
      progress = streamed,
      done = { k = "done" },
      bad_lines = 0,
      missing = false,
    },
  })
  eq(#finished_stream, 1, "a finished child: only its final records")
  eq(finished_stream[1].id, REL .. "::final", "not the streamed ones")
  local finished_empty = classify({
    frag = {
      cases = {},
      progress = streamed,
      done = { k = "done" },
      bad_lines = 0,
      missing = false,
    },
  })
  eq(#finished_empty, 0, "a finished child with no final case does not resurrect streamed ones")

  -- killed by the pool
  local file_kill = classify({ frag = frag({ ok_case("one") }, nil), code = 1, reason = "file" })
  eq(#file_kill, 2, "a file timeout: the finished cases and one more")
  eq(file_kill[2].status, "timeout", "which is a timeout")
  has(file_kill[2].error.message, "file exceeded 1000 ms", "naming the limit")
  has(file_kill[2].error.message, "process tree was killed", "and the kill")
  local stall = classify({ frag = frag({}, nil), code = 1, reason = "stall" })
  eq(stall[1].status, "timeout", "a stuck case is a timeout")
  has(stall[1].error.message, "a case exceeded 500 ms", "naming the case limit")

  -- an invalid fragment is refused as a whole
  local forged = ok_case("forged")
  forged.file = "TESTS/someone_else_spec.lua"
  local bad = classify({ frag = frag({ forged }, { k = "done" }) })
  eq(#bad, 1, "a fragment that speaks for another file is dropped")
  eq(bad[1].status, "error", "and reported as an error")
  has(bad[1].error.message, "invalid result", "with the reason")

  -- scripts: the verdict comes from testing.dialect.script (exit code + printed failures)
  local function script(over)
    return classify(vim.tbl_extend("force", {
      kind = "script",
      frag = frag({}, nil),
      describe_exit = "exit code 0",
    }, over or {}))
  end
  eq(script({ stdout = "[ok] x\n" })[1].status, "pass", "script: exit 0, no failure line: pass")
  eq(
    script({ stdout = "[FAIL] x\n" })[1].status,
    "fail",
    "script: a [FAIL] line is red even with exit 0"
  )
  eq(script({ code = 1, describe_exit = "exit code 1" })[1].status, "fail", "script: exit 1 is red")
  eq(
    script({ code = 139, describe_exit = "exit code 139" })[1].status,
    "crash",
    "script: 139 is a crash"
  )
  eq(
    script({ code = 3221225477 })[1].status,
    "crash",
    "script: an NTSTATUS access violation is a crash"
  )
  eq(script({ code = 1, signal = 11 })[1].status, "crash", "script: a signal is a crash")
  eq(
    script({ code = 1, reason = "file" })[1].status,
    "timeout",
    "script: killed on the deadline is a timeout"
  )
  eq(
    script({ code = 1, err = "E5113: Error while calling lua chunk: boom" })[1].status,
    "error",
    "script: an uncaught Lua error is an error"
  )

  -- ===================================================================
  -- wiring: flags and config reach the isolated driver; --list and `none` spawn nothing
  local cli = require("testing.cli")
  local real_inproc = require("testing.run.inproc")
  local state_dir = vim.fs.normalize(vim.fn.tempname())

  ---@param argv string[]
  ---@param seams? table
  local function go(argv, seams)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      color = false,
    }
    for k, v in pairs(seams or {}) do
      sv[k] = v
    end
    local code = cli.main(argv, sv)
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local function project(files, config)
    local root = S.new_root()
    S.write(root .. "/.testing.lua", config or 'return { dialect = "a", minit = false }\n')
    for rel, text in pairs(files) do
      S.write(root .. "/" .. rel, text)
    end
    return root
  end

  local PASS = 'return function(H) H.eq(1, 1, "ok") end\n'
  ---@type table|nil
  local captured
  local spy = {
    run = function(opts)
      captured = opts
      -- run in-process what the driver would have run in children: the wiring is what is tested
      return real_inproc.run({
        root = opts.root,
        files = opts.files,
        argv = opts.argv,
        selector = opts.selector,
        timeouts = opts.timeouts,
      })
    end,
  }

  local root = project(
    { ["TESTS/a_spec.lua"] = PASS },
    'return { dialect = "a", minit = false, jobs = 3, host = "l", filetype = false, assertions = "warn", isolated = "file" }\n'
  )
  local r = go({ root, "--env-allow", "MY_X" }, { isolated = spy })
  eq(r.code, 0, "the spy run is green: " .. r.out .. r.err)
  ok(captured ~= nil, "isolated = file in the config sends the run to the isolated driver")
  local first = assert(captured)
  eq(first.options.jobs, 3, "config jobs reaches the driver")
  eq(first.options.host, "l", "config host reaches the driver")
  eq(first.options.filetype, false, "config filetype reaches the driver")
  eq(first.options.assertions, "warn", "config assertions reaches the driver")
  eq(first.options.isolated, "file", "config isolated reaches the driver")
  eq(first.options.env_allow, { "MY_X" }, "--env-allow reaches the driver")
  eq(first.minit, nil, "minit = false: no minit for the children")
  ok(
    vim.tbl_contains(first.rtp_prepend, require("testing.deps").self_dir()),
    "this checkout is prepended"
  )
  eq(
    first.selector_spec,
    { filter = {}, tags = {}, exclude_tags = {} },
    "the selection is handed on as data"
  )
  ok(type(first.on_output) == "function", "and the output hook")

  captured = nil
  go({ root, "--isolated", "none", "--jobs", "5", "--host", "c" }, { isolated = spy })
  eq(captured, nil, "--isolated none beats the config: no child for an a-dialect file")

  captured = nil
  go(
    { root, "--isolated", "file", "--jobs", "5", "--host", "c", "--filter", "ok", "--tags", "t1" },
    { isolated = spy }
  )
  local cap = assert(captured, "the isolated driver was called")
  eq(cap.options.jobs, 5, "--jobs beats the config")
  eq(cap.options.host, "c", "--host beats the config")
  eq(cap.selector_spec.filter, { "ok" }, "--filter is handed on")
  eq(cap.selector_spec.tags, { "t1" }, "--tags is handed on")

  -- auto: an a-dialect file stays in this editor, a busted file goes to a child
  local root_auto =
    project({ ["TESTS/a_spec.lua"] = PASS }, 'return { dialect = "a", minit = false }\n')
  captured = nil
  go({ root_auto }, { isolated = spy })
  eq(captured, nil, "auto: dialect a runs in this editor")
  local root_busted = project({
    ["TESTS/b_spec.lua"] = 'describe("x", function() it("y", function() assert.is_true(true) end) end)\n',
  }, 'return { dialect = "busted", minit = false }\n')
  captured = nil
  go({ root_busted }, { isolated = spy })
  ok(
    captured ~= nil,
    "auto: a busted file goes to the isolated driver (plenary ran one editor per file)"
  )

  -- --list never starts a child
  local boom = {
    run = function()
      error("--list must not run anything")
    end,
  }
  local listed = go({ root, "--list" }, { isolated = boom })
  eq(listed.code, 0, "--list works with isolation configured")
  has(listed.out, "TESTS/a_spec.lua", "and lists the file")

  -- doctor shows the effective isolation settings
  local doc = go({ "doctor", root, "--jobs", "7", "--env-allow", "MY_X" })
  has(
    doc.out,
    "child editors: isolated=file jobs=7 host=l filetype=false disable_first_run=true env_allow=MY_X",
    "doctor names the effective child settings"
  )

  -- usage errors
  eq(go({ root, "--jobs", "0" }).code, 2, "--jobs 0 is a usage error")
  eq(go({ root, "--isolated", "maybe" }).code, 2, "--isolated maybe is a usage error")
  eq(go({ root, "--host", "x" }).code, 2, "--host x is a usage error")
  eq(go({ root, "--env-allow", "*" }).code, 2, "--env-allow * is a usage error")
  eq(go({ root, "--env-allow", "NVIM_X" }).code, 2, "--env-allow NVIM_X is a usage error")

  -- ===================================================================
  -- end to end through cli.main with real children
  local e2e = project({
    ["TESTS/1_ok_spec.lua"] = PASS,
    ["TESTS/2_red_spec.lua"] = 'return function(H) H.eq(1, 2, "red") end\n',
    ["TESTS/3_crash_spec.lua"] = 'return function(H)\n  H.eq(1, 1, "x")\n  require("ffi").cast("int*", 0)[0] = 1\nend\n',
  }, 'return { dialect = "a", minit = false, timeouts = { file_ms = 20000 } }\n')
  local red = go({ e2e, "--isolated", "file", "--jobs", "2" })
  eq(
    red.code,
    1,
    "end to end: red and crashed files make exit code 1, not 3: " .. red.out .. red.err
  )
  has(red.out, "1 crash", "the summary counts the crash")
  has(red.out, "TESTS/1_ok_spec.lua", "and lists the green file too")
  ok(not red.out:find("TESTING_OK", 1, true), "no sentinel for a red run")

  local green_root = project({ ["TESTS/1_ok_spec.lua"] = PASS, ["TESTS/2_ok_spec.lua"] = PASS })
  local green = go({ green_root, "--isolated", "file", "--jobs", "2" })
  eq(green.code, 0, "end to end: all green is exit code 0: " .. green.out .. green.err)
  has(green.out, "TESTING_OK", "and prints the sentinel")
  local oks = 0
  for _, line in ipairs(vim.split(green.out, "\n", { plain = true })) do
    if line:find("^ok%s+TESTS/") then
      oks = oks + 1
    end
  end
  eq(oks, 2, "both files reported ok")

  -- the minit runs in the child (as plenary's -u minimal_init would have)
  local minit_root = project({
    ["TESTS/minimal_init.lua"] = 'vim.g.minit_ran_in = (vim.v.argv[8] == "-c") and "child" or "parent"\n',
    ["TESTS/1_spec.lua"] = 'return function(H) H.eq(vim.g.minit_ran_in, "child", "minit ran in the child") end\n',
  }, 'return { dialect = "a", minit = "TESTS/minimal_init.lua" }\n')
  local minit_run = go({ minit_root, "--isolated", "file" })
  vim.g.minit_ran_in = nil -- the in-process part of the run executed the minit here too
  eq(
    minit_run.code,
    0,
    "the project's minit runs in the child before the spec: " .. minit_run.out .. minit_run.err
  )

  -- assertions = "warn" reaches the dialect inside the child
  local warn_root = project({
    ["TESTS/1_spec.lua"] = "return function(H) end\n",
  }, 'return { dialect = "a", minit = false, assertions = "warn" }\n')
  local warn_run = go({ warn_root, "--isolated", "file" })
  eq(
    warn_run.code,
    0,
    "assertions = warn: a spec without assertions passes in a child: "
      .. warn_run.out
      .. warn_run.err
  )
  local strict_root = project({ ["TESTS/1_spec.lua"] = "return function(H) end\n" })
  eq(
    go({ strict_root, "--isolated", "file" }).code,
    1,
    "assertions = error (default): it fails in a child"
  )

  -- a selection that matches nothing in a child: usage error 2, as in-process
  local none_run = go({ green_root, "--isolated", "file", "--filter", "no-such-case" })
  eq(none_run.code, 2, "nothing matched: exit code 2")

  -- the child output is shown, in file order, on the error stream
  local talk = project({
    ["TESTS/1_spec.lua"] = 'return function(H)\n  print("hello from child one")\n  H.eq(1, 1, "x")\nend\n',
    ["TESTS/2_spec.lua"] = 'return function(H)\n  print("hello from child two")\n  H.eq(1, 1, "x")\nend\n',
  })
  local talked = go({ talk, "--isolated", "file", "--jobs", "2" })
  local p1, p2 =
    talked.err:find("hello from child one", 1, true),
    talked.err:find("hello from child two", 1, true)
  ok(
    p1 ~= nil and p2 ~= nil and p1 < p2,
    "the output of each child is printed, in file order: " .. talked.err
  )

  S.cleanup()
  child.kill_all()
end
