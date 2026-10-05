-- TESTS/testing/usrcmds_spec.lua -- `:Testing`: completion (live, closed sets), the argv of the child
-- process, the verdict shown for each exit code, the failure list, init through the command, and
-- that docs/BINDINGS.md names every subcommand.

return function(H)
  local ok = H.ok
  -- dialect A's `eq` is strict `==`; these specs compare tables deeply
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. ")"
    )
  end
  local function sorted(list)
    local copy = vim.deepcopy(list)
    table.sort(copy)
    return copy
  end

  local usrcmds = require("testing.bindings.usrcmds")
  local child = require("testing.bindings.child")
  local args_mod = require("testing.args")

  ok(usrcmds.register(), ":Testing registers")
  ok(usrcmds.register(), "and a second register is harmless")
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  local function mkproj(name)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root .. "/TESTS/sub", "p")
    vim.fn.writefile({ "return function() end" }, root .. "/TESTS/a_spec.lua")
    vim.fn.writefile({ "return function() end" }, root .. "/TESTS/sub/b_spec.lua")
    vim.fn.writefile({ "x" }, root .. "/TESTS/helper.lua")
    return root
  end

  -- ---------------------------------------------------------------- completion (UI-22/23/26)

  local subcommands = { "config", "doctor", "file", "health", "init", "last", "list", "run" }
  eq(sorted(complete("Testing ")), subcommands, "every subcommand is offered")
  eq(complete("Testing r"), { "run" }, "a prefix narrows the subcommands")
  eq(complete("Testing l"), { "last", "list" }, "a prefix narrows to the matching ones")
  eq(complete("Testing zzz"), {}, "nothing matches an unknown prefix")

  eq(
    sorted(complete("Testing run --")),
    { "--config", "--file", "--filter", "--reporter", "--rtp" },
    "run offers its flags"
  )
  eq(
    sorted(complete("Testing list --")),
    { "--config", "--file", "--filter", "--reporter", "--rtp" },
    "list offers its flags"
  )
  eq(sorted(complete("Testing init --")), { "--force", "--plugin" }, "init offers its flags")
  eq(complete("Testing file --"), { "--rtp" }, "file offers its flag")
  eq(complete("Testing run --re"), { "--reporter" }, "a flag prefix narrows")

  local reporters = {}
  for _, name in ipairs(args_mod.REPORTERS) do
    reporters[#reporters + 1] = "--reporter=" .. name
  end
  eq(sorted(complete("Testing run --reporter=")), sorted(reporters), "the reporters are offered")
  eq(complete("Testing run --reporter=ju"), { "--reporter=junit" }, "a reporter prefix narrows")
  -- live: a reporter that is registered after :Testing was defined is offered at once
  table.insert(args_mod.REPORTERS, "zzz-live")
  local live = complete("Testing run --reporter=zzz")
  table.remove(args_mod.REPORTERS)
  eq(live, { "--reporter=zzz-live" }, "the reporter list is read at the keypress, not frozen")
  eq(complete("Testing run --reporter=zzz"), {}, "and it is gone again when the list is")

  -- the closed set is validated, not only completed
  local rtype = require("lib.nvim.bindings.usercmd.composer.argtypes").get(usrcmds.TYPE_REPORTER)
  eq((rtype.validate("term")), true, "a known reporter validates")
  eq((rtype.validate("bogus")), false, "an unknown reporter is refused")

  -- spec files: live from the file system
  local proj = mkproj("completion")
  eq(
    usrcmds.spec_files(proj),
    { "TESTS/a_spec.lua", "TESTS/sub/b_spec.lua" },
    "spec_files lists the *_spec.lua files below TESTS, relative"
  )
  eq(usrcmds.spec_files(tmp .. "/none"), {}, "no TESTS: no spec")
  local stype = require("lib.nvim.bindings.usercmd.composer.argtypes").get(usrcmds.TYPE_SPEC)
  local cands = stype.complete("")
  ok(type(cands) == "table", "the spec completion returns a list")
  for _, c in ipairs(cands) do
    ok(c:match("_spec%.lua$") ~= nil, "a spec candidate is a spec file: " .. c)
  end
  eq(stype.complete("zzz-no-such-spec-file"), {}, "the spec completion filters by what was typed")

  -- ---------------------------------------------------------------- root and current spec

  eq(usrcmds.resolve_root(proj), proj, "an explicit root is used")
  eq(
    usrcmds.resolve_root(nil, proj .. "/TESTS/sub/b_spec.lua"),
    proj,
    "the root is found from a file"
  )
  eq(usrcmds.resolve_root(nil, proj .. "/TESTS/sub"), proj, "the root is found from a directory")

  local root1, rel1 = usrcmds.current_spec(proj .. "/TESTS/sub/b_spec.lua")
  eq(root1, proj, "current_spec: the root")
  eq(rel1, "TESTS/sub/b_spec.lua", "current_spec: the path relative to the root")
  local root2, _, err2 = usrcmds.current_spec(proj .. "/TESTS/helper.lua")
  eq(root2, nil, "a file that is not a spec is refused")
  has(err2, "not a spec file", "and the reason is given")

  -- ---------------------------------------------------------------- argv (SEC-01/02)

  local driver = child.driver()
  ok(vim.uv.fs_stat(driver) ~= nil, "the driver script exists: " .. driver)
  local argv = child.build_argv("run", {
    root = proj,
    json = tmp .. "/ir.json",
    flags = {
      file = { "a b", "--evil", "x;y" },
      filter = { "$(touch pwned)" },
      reporter = "term",
      rtp = { "d1" },
      config = "c.lua",
    },
  })
  eq(argv, {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    driver,
    "run",
    proj,
    "--file=a b",
    "--file=--evil",
    "--file=x;y",
    "--filter=$(touch pwned)",
    "--reporter=term",
    "--rtp=d1",
    "--config=c.lua",
    "--json=" .. tmp .. "/ir.json",
  }, "the argv is a list, every value its own element in the --name=value form")
  for _, a in ipairs(argv) do
    ok(type(a) == "string", "an argv element is a string")
  end
  local list_argv = child.build_argv("list", { root = proj, json = "ignored.json" })
  eq(list_argv[10], "list", "the list subcommand")
  ok(not vim.tbl_contains(list_argv, "--json=ignored.json"), "list writes no IR")
  eq(child.build_argv("doctor", { root = proj })[10], "doctor", "the doctor subcommand")
  local _, err_sub = child.build_argv("rm -rf", { root = proj })
  has(err_sub, "unknown subcommand", "an unknown subcommand is refused")
  local _, err_root = child.build_argv("run", {})
  has(err_root, "no project root", "no root is refused")

  -- the child driver accepts exactly what was built: nothing is left over as an unknown option
  local parsed, perr = args_mod.parse(vim.list_slice(argv, 10))
  ok(parsed ~= nil, "testing.args parses the built flags: " .. tostring(perr))
  eq(
    parsed.file,
    { "a b", "--evil", "x;y" },
    "values arrive intact, also one that looks like a flag"
  )
  eq(parsed.root, proj, "the root arrives")

  -- ---------------------------------------------------------------- start with a fake system

  local captured
  local function fake_system(argv_, sopts, on_exit)
    captured = { argv = argv_, opts = sopts, on_exit = on_exit }
    return {}
  end
  local function wait_for(cond, what)
    ok(vim.wait(5000, cond, 10), "timed out: " .. what)
  end

  local function ir_with(cases, summary)
    return {
      schema_version = 1,
      run = { id = "x", root = "<REPO>", argv = {} },
      cases = cases,
      summary = vim.tbl_extend(
        "force",
        { pass = 0, fail = 0, error = 0, skip = 0, xfail = 0, xpass = 0, timeout = 0, crash = 0 },
        summary or {}
      ),
    }
  end

  local verdict
  local started, serr = child.start("run", { root = proj, system = fake_system }, function(v)
    verdict = v
  end)
  eq(started, true, "start reports that the process was started: " .. tostring(serr))
  eq(captured.opts.cwd, proj, "the child runs in the project root")
  eq(captured.opts.text, true, "output is text")
  ok(type(captured.opts.timeout) == "number", "the child has a hard timeout")
  local json_arg
  for _, a in ipairs(captured.argv) do
    json_arg = json_arg or a:match("^%-%-json=(.+)$")
  end
  ok(json_arg ~= nil, "run asks the driver for the IR")
  -- the driver "writes" an IR with one failed case and exits 1
  local failing = ir_with({
    {
      id = "TESTS/x_spec.lua::a::b",
      file = "TESTS/x_spec.lua",
      line = 7,
      status = "fail",
      assertions = {
        { ok = true, kind = "ok" },
        { ok = false, kind = "eq", msg = "boom", file = "<REPO>/TESTS/x_spec.lua", line = 9 },
      },
    },
    { id = "TESTS/x_spec.lua::a::c", file = "TESTS/x_spec.lua", status = "pass", assertions = {} },
    {
      id = "TESTS/y_spec.lua::err",
      file = "TESTS/y_spec.lua",
      status = "error",
      assertions = {},
      error = { message = "attempt to index nil", traceback = "tb" },
    },
  }, { pass = 1, fail = 1, error = 1 })
  vim.fn.writefile({ vim.json.encode(failing) }, json_arg)
  captured.on_exit({ code = 1, stdout = "", stderr = "" })
  wait_for(function()
    return verdict ~= nil
  end, "the verdict of a failed run")
  eq(verdict.level, "error", "exit 1 is an error")
  has(verdict.message, "2 failed", "the failures are counted")
  has(verdict.message, "1 passed", "and the passes")
  eq(#verdict.items, 2, "every failed case is a quickfix item")
  eq(verdict.items[1].filename, proj .. "/TESTS/x_spec.lua", "<REPO> is the root")
  eq(verdict.items[1].lnum, 9, "the failing assertion's line wins over the case's")
  has(verdict.items[1].text, "boom", "the message is in the item")
  has(verdict.items[1].text, "[fail]", "and the status")
  eq(verdict.items[2].filename, proj .. "/TESTS/y_spec.lua", "a relative file is below the root")
  eq(verdict.items[2].lnum, 1, "no line: line 1")
  has(verdict.items[2].text, "attempt to index nil", "the error message is the reason")
  eq(vim.uv.fs_stat(json_arg), nil, "the temporary IR is removed afterwards")

  local broke, berr = child.start("run", {
    root = proj,
    system = function()
      error("spawn failed")
    end,
  }, function()
    error("must not be called")
  end)
  eq(broke, false, "a process that cannot be started is reported")
  has(berr, "spawn failed", "with the reason")
  eq((child.start("bogus", { root = proj })), false, "an unknown subcommand does not start")

  -- ---------------------------------------------------------------- the verdict per exit code

  local ir_path = tmp .. "/green.json"
  vim.fn.writefile({ vim.json.encode(ir_with({}, { pass = 3, skip = 1 })) }, ir_path)
  local green = child.interpret(
    "run",
    { code = 0, stdout = "", stderr = "" },
    { root = proj, json = ir_path }
  )
  eq(green.level, "info", "exit 0 is info")
  has(green.message, "3 passed", "the passes are counted")
  eq(green.items, {}, "no failure items")

  local no_ir = child.interpret(
    "run",
    { code = 1, stdout = "", stderr = "x" },
    { root = proj, json = tmp .. "/none.json" }
  )
  eq(no_ir.level, "error", "exit 1 without a readable IR is an error")
  has(no_ir.message, "could not be read", "and says that the file is missing")
  lacks(no_ir.message, "0 failed", "and never claims zero failures")
  vim.fn.writefile({ "not json" }, tmp .. "/bad.json")
  local bad_ir = child.interpret(
    "run",
    { code = 1, stdout = "", stderr = "" },
    { root = proj, json = tmp .. "/bad.json" }
  )
  eq(bad_ir.level, "error", "exit 1 with a corrupt IR is an error")

  for _, code in ipairs({ 2, 3, 4, -1 }) do
    local v = child.interpret(
      "run",
      { code = code, stdout = "", stderr = "no lib\nline2" },
      { root = proj, json = ir_path }
    )
    eq(v.level, "error", "exit " .. code .. " is never info, even if an old IR is there")
    has(v.message, "no verdict", "exit " .. code .. " says that there is no verdict")
    has(v.message, "no lib", "exit " .. code .. " shows stderr")
  end
  local killed = child.interpret(
    "run",
    { code = 124, signal = 15, stdout = "", stderr = "" },
    { root = proj, json = ir_path }
  )
  eq(killed.level, "error", "a killed child is an error")
  has(killed.message, "signal 15", "and says why")

  local listed = child.interpret(
    "list",
    { code = 0, stdout = "TESTS/a_spec.lua\n2 of 2\n", stderr = "" },
    { root = proj }
  )
  eq(listed.level, "info", "list succeeds")
  eq(listed.lines, { "TESTS/a_spec.lua", "2 of 2" }, "the output goes to a viewer")
  local doctor_fail = child.interpret(
    "doctor",
    { code = 3, stdout = "", stderr = "missing lib" },
    { root = proj }
  )
  eq(doctor_fail.level, "error", "a failed doctor is an error")
  has(doctor_fail.message, "missing lib", "with the reason")

  -- ---------------------------------------------------------------- the commands

  local messages = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = tostring(msg), level = level }
  end
  local function all_messages()
    local t = {}
    for _, m in ipairs(messages) do
      t[#t + 1] = m.msg
    end
    return table.concat(t, "\n")
  end
  local function with_notify(fn)
    messages = {}
    local passed, err = pcall(fn)
    if not passed then
      -- the failures reach the quickfix list (UI-36), the summary the notification
      with_notify(function()
        vim.fn.setqflist({}, "r")
        child.show({ level = "error", message = "2 failed", items = verdict.items }, "testing run")
        local qf = vim.fn.getqflist()
        eq(#qf, 2, "every failed case is in the quickfix list")
        eq(vim.fn.getqflist({ title = 1 }).title, "testing: failures", "the list has a title")
        eq(qf[1].lnum, 9, "the entry points at the failing line")
        has(all_messages(), "2 failed", "the summary is notified")
        eq(messages[1].level, vim.log.levels.ERROR, "as an error")
        vim.cmd("silent! cclose")
        vim.fn.setqflist({}, "r")
      end)

      vim.notify = real_notify
      error(err, 0)
    end
  end

  with_notify(function()
    usrcmds.last_run = nil
    vim.cmd("Testing last")
    has(all_messages(), "no earlier run", ":Testing last without a run says so")
  end)

  -- :Testing file on an unnamed buffer
  with_notify(function()
    vim.cmd("enew")
    vim.cmd("Testing file")
    has(all_messages(), "no file", ":Testing file in an unnamed buffer says so")
    vim.cmd("bwipeout!")
  end)

  -- :Testing last repeats exactly the stored run (through the seam)
  with_notify(function()
    usrcmds.last_run =
      { sub = "run", opts = { root = proj, system = fake_system, flags = { file = { "a" } } } }
    captured = nil
    vim.cmd("Testing last")
    ok(captured ~= nil, ":Testing last starts the stored run")
    eq(captured.opts.cwd, proj, "in the same root")
    ok(vim.tbl_contains(captured.argv, "--file=a"), "with the same flags")
  end)

  -- :Testing init through the command line
  local target = tmp .. "/initme"
  vim.fn.mkdir(target .. "/lua/initme", "p")
  with_notify(function()
    vim.cmd("Testing init " .. vim.fn.fnameescape(target))
    has(all_messages(), "created:", ":Testing init reports what it created")
    ok(vim.uv.fs_stat(target .. "/scripts/test.sh") ~= nil, "scripts/test.sh exists")
    ok(vim.uv.fs_stat(target .. "/.testing.lua") ~= nil, ".testing.lua exists")
    eq(
      vim.fn.readfile(target .. "/.testing.lua")[7],
      '  plugin = "initme",',
      "the plugin name was detected"
    )
  end)
  with_notify(function()
    vim.fn.writefile({ "-- mine" }, target .. "/.testing.lua")
    vim.cmd("Testing init " .. vim.fn.fnameescape(target))
    has(all_messages(), "kept", "a second :Testing init keeps the files")
    eq(vim.fn.readfile(target .. "/.testing.lua"), { "-- mine" }, "and does not overwrite")
    messages = {}
    vim.cmd("Testing init " .. vim.fn.fnameescape(target) .. " --force")
    has(all_messages(), "replaced", "--force replaces")
    lacks(
      vim.fn.readfile(target .. "/.testing.lua")[1],
      "-- mine",
      "the file is the template again"
    )
  end)
  with_notify(function()
    vim.cmd("Testing init " .. vim.fn.fnameescape(target) .. ' --plugin=a"b')
    -- already exists: only reports; the point is that a hostile value does not raise
    ok(#messages > 0, "a hostile --plugin value is handled")
  end)

  vim.notify = real_notify

  -- ---------------------------------------------------------------- docs

  local doc = require("lib.nvim.fs.read")(require("testing.deps").self_dir() .. "/docs/BINDINGS.md")
  ok(doc ~= nil, "docs/BINDINGS.md is readable")
  for _, route in ipairs(usrcmds.routes()) do
    has(doc, ":Testing " .. route.path[1], "docs/BINDINGS.md documents :Testing " .. route.path[1])
  end

  vim.fn.delete(tmp, "rf")
end
