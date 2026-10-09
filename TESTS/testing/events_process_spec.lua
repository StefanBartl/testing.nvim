-- TESTS/testing/events_process_spec.lua -- `--events` with REAL editors (`scripts/testing.lua` as a process), the way
-- a supervisor uses it: the stream on stdout, a run that is cut short, and two runs of one project at the same
-- time (the supervisor's run next to a manual one).
--
-- What only a process can show: stdout is the stream and nothing else (the reporter went to stderr), the exit
-- guard writes `run_done` with `aborted = true` when the editor is quit during a run, and two full runs that share
-- one state directory both finish with a complete stream.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local json = require("lib.nvim.json")

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local repo = vim.fs.dirname(vim.fs.dirname(dir))
  local libfile = package.searchpath("lib.nvim.json", package.path)
    or vim.api.nvim_get_runtime_file("lua/lib/nvim/json/init.lua", false)[1]
  ok(libfile ~= nil, "lib.nvim is findable")
  local lib_root = (libfile or ""):gsub("\\", "/"):gsub("/lua/lib/nvim/json/init%.lua$", "")

  local tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")

  ---@param name string
  ---@param specs table<string, string[]> File name -> lines.
  ---@return string root
  local function project(name, specs)
    local root = tmp .. "/" .. name
    vim.fn.mkdir(root .. "/TESTS", "p")
    for file, lines in pairs(specs) do
      vim.fn.writefile(lines, root .. "/TESTS/" .. file)
    end
    return root
  end

  local PASS = { "return function(H)", '  H.ok(true, "x")', "end" }

  ---Start `scripts/testing.lua run <root> ...` as a process of its own.
  ---@param root string
  ---@param extra string[]
  ---@param state string Shared `XDG_STATE_HOME`.
  ---@return vim.SystemObj
  local function start(root, extra, state)
    local cmd = {
      vim.v.progpath,
      "-n",
      "-i",
      "NONE",
      "--headless",
      "-u",
      "NONE",
      "-l",
      repo .. "/scripts/testing.lua",
      "run",
      root,
      "--no-cache",
    }
    vim.list_extend(cmd, extra)
    return vim.system(cmd, {
      text = true,
      env = { LIB_NVIM_DIR = lib_root, XDG_STATE_HOME = state, TESTING_REPORTER = "term" },
    })
  end

  ---@param text string
  ---@return table[]
  local function decode_lines(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do
      local obj, err = json.decode(line)
      ok(
        obj ~= nil,
        "a line of the stream is JSON: " .. tostring(err) .. " in " .. line:sub(1, 120)
      )
      out[#out + 1] = obj
    end
    return out
  end

  -- `--events -`: stdout is the stream and nothing else; the reporter is on stderr; the exit code is the run's
  do
    local root = project("stdout", { ["a_spec.lua"] = PASS })
    local res = start(root, { "--events", "-" }, tmp .. "/state-stdout"):wait(90000)
    eq(res.code, 0, "the run is green: " .. tostring(res.stderr))
    local objs = decode_lines(res.stdout)
    eq(objs[1] and objs[1].event, "run_start", "stdout starts with run_start")
    eq(objs[#objs] and objs[#objs].event, "run_done", "and ends with run_done")
    local cases = 0
    for _, o in ipairs(objs) do
      ok(o.v == 1 and o.run == 1, "every line is version 1, run 1")
      if o.event == "case" then
        cases = cases + 1
      end
    end
    eq(cases, 1, "one case")
    ok(res.stderr:find("a_spec.lua", 1, true) ~= nil, "the reporter's text went to stderr")
    ok(not res.stdout:find("PARTIAL", 1, true), "and none of it is on stdout")
  end

  -- the editor is quit while the spec runs: exit 3, and the stream says so
  do
    local root =
      project("abort", { ["quit_spec.lua"] = { "return function(H)", '  vim.cmd("qa!")', "end" } })
    local stream = tmp .. "/abort.ndjson"
    local res = start(root, { "--events", stream }, tmp .. "/state-abort"):wait(90000)
    eq(res.code, 3, "the run did not complete: infrastructure exit code " .. tostring(res.stderr))
    ok(res.stderr:find("run did not complete", 1, true) ~= nil, "stderr says so")
    local objs = decode_lines(table.concat(vim.fn.readfile(stream), "\n"))
    eq(objs[1].event, "run_start", "the stream began")
    local last = objs[#objs]
    eq(last.event, "run_done", "and was ended")
    eq(last.aborted, true, "as aborted")
    eq(last.exit_code, 3, "with the exit code of the process")
    eq(last.verdict, nil, "without a verdict")
  end

  -- the supervisor's run next to a manual one: same project, same state directory, both finish, both streams whole
  do
    local root = project("parallel", {
      ["a_spec.lua"] = PASS,
      ["b_spec.lua"] = PASS,
      ["c_spec.lua"] = PASS,
    })
    local state = tmp .. "/state-parallel"
    local s1, s2 = tmp .. "/p1.ndjson", tmp .. "/p2.ndjson"
    local p1 = start(root, { "--events", s1 }, state)
    local p2 = start(root, { "--events", s2 }, state)
    local r1, r2 = p1:wait(90000), p2:wait(90000)
    eq(r1.code, 0, "run 1 is green: " .. tostring(r1.stderr))
    eq(r2.code, 0, "run 2 is green: " .. tostring(r2.stderr))
    for _, path in ipairs({ s1, s2 }) do
      local objs = decode_lines(table.concat(vim.fn.readfile(path), "\n"))
      eq(objs[1].event, "run_start", path .. ": starts")
      eq(objs[#objs].event, "run_done", path .. ": ends")
      eq(objs[#objs].verdict, "green", path .. ": green")
      local cases = 0
      for _, o in ipairs(objs) do
        if o.event == "case" then
          cases = cases + 1
        end
      end
      eq(cases, 3, path .. ": a case per spec, none lost to the other run")
    end
    -- the history both runs wrote is still readable: no half line, no lost file
    local hist = require("testing.history").load(root, { state_dir = state })
    ok(hist ~= nil, "the history of the shared state directory loads")
  end

  vim.fn.delete(tmp, "rf")
end
