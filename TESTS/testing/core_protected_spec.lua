-- TESTS/testing/core_protected_spec.lua -- the pcall rule (testing.core.protected) at its edges: which chunks count as
-- the runner, the cost of the stack search, the load-time captures, a case that starts inside the runner, and the
-- hand-over of the spec file in dialects a, b and c. The rule itself is pinned in core_assert_spec.lua.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local assert_mod = require("testing.core.assert")
  local dialect = require("testing.dialect")
  local project = require("testing.dialect.harness_project")
  local protected = require("testing.core.protected")

  local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
  local spec_chunk = debug.getinfo(1, "S").source

  ---@param path string
  ---@param mark string
  ---@return integer
  local function line_of(path, mark)
    for i, line in ipairs(vim.fn.readfile(path)) do
      if line:find("MARK:" .. mark, 1, true) then
        return i
      end
    end
    error("mark not found: " .. mark)
  end
  local function new_ctx()
    local t = -5
    return assert_mod.new({
      clock = function()
        t = t + 5
        return t
      end,
    })
  end
  local function run(ctx, body)
    return ctx.run_case({ file = "TESTS/x_spec.lua", name = "case" }, body)
  end
  local function plugin(code, chunk)
    return assert(load(code, chunk))
  end
  -- non-tail recursion: every level keeps its frame
  local function descend(depth, fn)
    if depth == 0 then
      return fn()
    end
    local r = descend(depth - 1, fn)
    return r
  end

  -- -------------------------------------------------------
  -- the runner as a DIRECTORY
  -- -------------------------------------------------------
  local runner_file = debug.getinfo(protected.inside, "S").source:sub(2):gsub("\\", "/")
  local runner_dir =
    assert(runner_file:match("^(.*/lua/testing/)core/protected%.lua$"), "runner directory")
  local runner_text = table.concat(vim.fn.readfile(runner_file), "\n")
  -- a second instance of the module, loaded under another chunk name: the name decides what "the runner" is
  local function instance(chunk)
    return assert(load(runner_text, chunk))()
  end
  -- is a pcall called from `chunk` passed over (taken for the runner's), so that the spec's pcall further out answers?
  local function passed_over(inst, chunk)
    local emit = plugin("local cb = ...; local ok = pcall(cb); return ok", chunk)
    local entry = inst.entry(spec_chunk)
    local answered
    pcall(function()
      emit(function()
        answered = inst.inside(entry)
      end)
    end)
    return answered
  end
  local parent = assert(runner_dir:match("^(.*/lua/)testing/$"), "lua directory")
  for _, row in ipairs({
    { "@" .. runner_dir .. "run/x.lua", true, "a chunk below the runner" },
    { "@" .. parent .. "testing_extra/x.lua", false, "a directory that only starts like it" },
    { "@" .. parent .. "other/x.lua", false, "a sibling directory" },
    { "@/mnt/copy" .. runner_dir .. "x.lua", false, "the runner's path in the middle of another" },
  }) do
    eq(passed_over(protected, row[1]), row[2], "real instance: " .. row[3])
  end
  local windows = instance("@C:\\dev\\plug\\lua\\testing\\core\\protected.lua")
  for _, row in ipairs({
    { "@C:\\dev\\plug\\lua\\testing\\run\\x.lua", true, "a chunk below the runner" },
    { "@C:\\dev\\plug\\lua\\testing_extra\\x.lua", false, "a directory that only starts like it" },
    { "@D:/other/lua/testing/emit.lua", false, "a plugin with a lua/testing/ elsewhere" },
  }) do
    eq(passed_over(windows, row[1]), row[2], "backslash instance: " .. row[3])
  end
  local relative = instance("@lua/testing/core/protected.lua")
  for _, row in ipairs({
    { "@lua/testing/run/x.lua", true, "a chunk below the runner" },
    {
      "@/home/dev/plugins/foo/lua/testing/emit.lua",
      false,
      "a plugin with a lua/testing/ elsewhere",
    },
  }) do
    eq(passed_over(relative, row[1]), row[2], "relative instance: " .. row[3])
  end
  local unknown = instance("=protected")
  for _, row in ipairs({
    { "@/home/dev/plugins/foo/lua/testing/emit.lua", true, "a lua/testing/ below any root" },
    { "@lua/testing/run/x.lua", true, "a lua/testing/ at the start of a relative path" },
    { "@/home/dev/plugins/foo/lua/other/emit.lua", false, "a path without it" },
  }) do
    eq(passed_over(unknown, row[1]), row[2], "unnamed instance: " .. row[3])
  end
  -- the text of a chunk loaded without a name is its chunk name: never a path, never the runner, and not copied
  -- and scanned on every protected call (a protected call in it is not attributable and records)
  do
    local padding = ("-- padding of a generated chunk\n"):rep(300)
    eq(#padding > 4096, true, "the generated chunk is longer than any path")
    eq(
      passed_over(protected, padding .. "local cb = ...; local ok = pcall(cb); return ok"),
      false,
      "a long unnamed chunk"
    )
  end

  -- -------------------------------------------------------
  -- a case that starts inside the runner (kernel use, no spec path)
  -- -------------------------------------------------------
  do
    local sink = {}
    local lone_body = plugin(
      [[
      local sink = ...
      return function(c)
        sink.ok = pcall(function()
          c.eq(1, 2, "inside the runner")
        end)
      end
    ]],
      "@" .. runner_dir .. "run/lone.lua"
    )(sink)
    local lone_case = run(new_ctx(), lone_body)
    eq(sink.ok, true, "the runner's pcall swallows nothing: no raise without a spec to ask")
    eq(lone_case.status, "fail", "the failed check is recorded")
    eq(#lone_case.assertions, 1, "as the one assertion of the case")
  end
  do
    local spec_fn = plugin(
      [[
      local c = ...
      local ok = pcall(function() c.eq(1, 2, "asked") end)
      c.ok(not ok, "answered")
    ]],
      "@/home/dev/proj/TESTS/lower_spec.lua"
    )
    local start = plugin(
      "local spec = ...; return function(c) spec(c) end",
      "@" .. runner_dir .. "run/start.lua"
    )(spec_fn)
    eq(run(new_ctx(), start).status, "pass", "a runner frame below the spec's code is not the spec")
  end

  -- a C frame (the `pcall` that starts the spec) between the runner and the spec is not the spec either
  do
    local spec_fn = plugin(
      [[
      local c = ...
      local ok = pcall(function() c.eq(1, 2, "asked") end)
      c.ok(not ok, "answered")
    ]],
      "@/home/dev/proj/TESTS/lower_spec.lua"
    )
    local start = plugin(
      "local spec = ...; return function(c) pcall(spec, c) end",
      "@" .. runner_dir .. "run/start.lua"
    )(spec_fn)
    eq(
      run(new_ctx(), start).status,
      "pass",
      "the runner's pcall below the spec's code is not the spec"
    )
  end

  -- the spec's code is looked for at or above the entry point, never in the code that called the function that
  -- entered: here that is a chunk of another file, and the question is asked in the file that entered
  do
    local out = {}
    local inner = plugin(
      [[
      local protected, out = ...
      return function()
        local entry = protected.entry()
        pcall(function() out.answered = protected.inside(entry) end)
      end
    ]],
      "@/home/dev/proj/TESTS/inner_spec.lua"
    )(protected, out)
    local outer = plugin(
      "local inner = ...; return function() inner(); return 1 end",
      "@/home/dev/proj/TESTS/outer_spec.lua"
    )(inner)
    outer()
    eq(
      out.answered,
      true,
      "the pcall of the file that entered is the spec's, the file that called it is not"
    )
  end

  -- -------------------------------------------------------
  -- which chunks are the harness: the setup (project.new) over chunks that are named, not loaded from disk
  -- -------------------------------------------------------
  do
    local function helper(chunk)
      return plugin("return function() end", chunk)()
    end
    ---@param file string
    ---@param chunks string[]
    ---@return table<string, true>
    local function transparent_for(file, chunks)
      local harness = {}
      for i, chunk in ipairs(chunks) do
        harness["f" .. i] = helper(chunk)
      end
      local _, state = project.new(assert_mod.new(), harness, {}, { file = file })
      return state.transparent
    end
    local set = transparent_for("/proj/TESTS/harness.lua", {
      "@/elsewhere/lib.lua",
      "@/proj/TESTS/support/guard.lua",
      "@/proj/TESTS/lua/code.lua",
      "@/proj/TESTS/plugin/code.lua",
      "@/proj/TESTS/after/code.lua",
      "@/proj/TESTS/ftplugin/code.lua",
      "@/proj/TESTS/autoload/code.lua",
      "@/proj/TESTS/src/code.lua",
      "@/proj/TESTS_other/guard.lua",
      "@/proj/TESTS/../OTHER/guard.lua",
    })
    ok(
      set["@/proj/TESTS/harness.lua"] == true,
      "the harness file is the harness although none of H came from it"
    )
    ok(
      set["@/proj/TESTS/support/guard.lua"] == true,
      "a support file below the harness directory is the harness"
    )
    for _, dir in ipairs({ "lua", "plugin", "after", "ftplugin", "autoload", "src" }) do
      ok(
        set["@/proj/TESTS/" .. dir .. "/code.lua"] == nil,
        dir .. "/ below the harness directory is the code under test"
      )
    end
    ok(set["@/elsewhere/lib.lua"] == nil, "a file elsewhere is not the harness")
    ok(
      set["@/proj/TESTS_other/guard.lua"] == nil,
      "a directory that only starts like the harness directory is not"
    )
    ok(
      set["@/proj/TESTS/../OTHER/guard.lua"] == nil,
      "and neither is a path that leaves it through .."
    )
    -- a configured relative path of the harness: the directory is the working directory
    local relative_set = transparent_for("harness.lua", { "@sub/guard.lua", "@lua/code.lua" })
    ok(
      relative_set["@sub/guard.lua"] == true,
      "a relative harness file: the files below the working directory count"
    )
    ok(relative_set["@lua/code.lua"] == nil, "except the code under test")
  end

  -- -------------------------------------------------------
  -- the cost of the stack size: a few walks, not one per level
  -- -------------------------------------------------------
  do
    local real_getinfo = debug.getinfo
    local walks = 0
    local function count_walks()
      local info = real_getinfo(2, "f")
      if info and info.func == real_getinfo then
        walks = walks + 1
      end
    end
    local deep_size
    descend(600, function()
      debug.sethook(count_walks, "c")
      deep_size = protected.stack_size()
      debug.sethook()
    end)
    ok(deep_size > 600, "stack_size() counts the 600 frames of the probe")
    ok(walks <= 40, "stack_size() walked " .. walks .. " times on a stack of " .. deep_size)
  end

  -- -------------------------------------------------------
  -- debug.getinfo and coroutine.running are taken when the modules load
  -- -------------------------------------------------------
  -- a spec that stubs them (to test its own location capture or a coroutine helper) must neither hang the rule nor
  -- the location search of its own assertions; the stub gives up after a limit, so a regression is a red case
  do
    local real_getinfo, real_running = debug.getinfo, coroutine.running
    local calls = 0
    local fake_thread = coroutine.create(function() end)
    local asked
    local stub_ok, stub_case = pcall(function()
      return run(new_ctx(), function(c)
        -- stubbed after the case was entered: the rule and the location search must still see the real ones
        rawset(debug, "getinfo", function()
          calls = calls + 1
          if calls > 10000 then
            error("debug.getinfo called in a loop", 0)
          end
          return { source = "@stub.lua", short_src = "stub.lua", currentline = 1, what = "Lua" }
        end)
        rawset(coroutine, "running", function()
          return fake_thread, false
        end)
        asked = pcall(function()
          c.eq(1, 2, "asked")
        end)
        c.eq(1, 2, "recorded")
        rawset(debug, "getinfo", real_getinfo)
        rawset(coroutine, "running", real_running)
      end)
    end)
    rawset(debug, "getinfo", real_getinfo)
    rawset(coroutine, "running", real_running)
    eq(stub_ok, true, "the case ran with the stubs in place")
    ok(
      calls < 100,
      "neither the rule nor the location search call a stubbed debug.getinfo in a loop ("
        .. calls
        .. " calls)"
    )
    eq(asked, false, "the question is answered with the stubs in place")
    eq(stub_case and #stub_case.assertions, 1, "and the other check is recorded")
    eq(
      stub_case
        and stub_case.assertions[1]
        and (stub_case.assertions[1].file or ""):find("core_protected_spec.lua", 1, true) ~= nil,
      true,
      "with the real call site"
    )
  end

  -- -------------------------------------------------------
  -- a harness file without a directory part (a configured relative path)
  -- -------------------------------------------------------
  do
    local bare = { eq = plugin("return function() end", "@harness.lua")() }
    local bare_ok, bare_state = pcall(function()
      local _, state = project.new(assert_mod.new(), bare, {}, { file = "harness.lua" })
      return state
    end)
    eq(bare_ok, true, "a harness file without a directory does not break the setup")
    ok(bare_ok and bare_state.transparent["@harness.lua"] == true, "its own chunk is the harness")
  end

  -- -------------------------------------------------------
  -- an assertion that delegates to another assertion: the failure belongs to the outer one
  -- -------------------------------------------------------
  do
    local nested_dir = here .. "/fixtures/h_nested"
    local cases = dialect.run_file("h", assert_mod.new(), {
      path = nested_dir .. "/pair.fixture.lua",
      rel = "TESTS/pair_spec.lua",
      harness = nested_dir .. "/harness.lua",
    })
    local case = cases[1]
    eq(case.error, nil, "the file ran to its end")
    eq(#case.assertions, 2, "the delegating assertion and the check after it")
    local first = case.assertions[1]
    eq(first.ok, false, "the delegating assertion failed")
    eq(first.kind, "pair", "as the outer assertion")
    eq(first.line, line_of(nested_dir .. "/pair.fixture.lua", "n1"), "at the spec's line")
    eq(case.assertions[2].ok, true, "the check after it holds")
  end

  -- -------------------------------------------------------
  -- dialects a, b and c hand the spec file over: the spec's own pcall is recognised
  -- -------------------------------------------------------
  for _, name in ipairs({ "a", "b", "c" }) do
    local cases = dialect.run_file(name, assert_mod.new(), {
      path = here .. "/fixtures/ask.fixture.lua",
      rel = "TESTS/ask_spec.lua",
    })
    eq(cases[1].error, nil, "dialect " .. name .. ": the file ran to its end")
    eq(cases[1].status, "pass", "dialect " .. name .. ": the question the spec asks is answered")
  end
end
