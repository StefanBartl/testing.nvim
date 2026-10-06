-- TESTS/testing/child_argv_spec.lua -- what a child editor is started with, inspected without running
-- one: an argv LIST (never a shell string), the project root as the working directory, a constant
-- command line (no user text in it), the allowlisted environment plus the sandbox, the job file.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local child = require("testing.child")

  local parent_env = {
    PATH = "/bin",
    HOME = "/home/x",
    GITHUB_TOKEN = "secret",
    NVIM = "/tmp/sock",
    TEMP = "C:\\real\\temp",
    XDG_DATA_HOME = "/real/data",
  }
  local root = "E:/some root/with space/proj"
  local base = vim.fs.normalize(vim.fn.tempname()) .. "-argv"
  local function plan(over)
    return child.build(vim.tbl_extend("force", {
      entry = { path = root .. "/TESTS/a_spec.lua", rel = "TESTS/a_spec.lua", dialect = "a" },
      root = root,
      parent_env = parent_env,
      base = base,
      nvim = "nvim-under-test",
    }, over or {}))
  end

  -- host c (default): constant -c command, the boot file travels in the environment
  local p = plan()
  eq(p.host, "c", "the default host is c")
  eq(type(p.argv), "table", "argv is a list, not a shell string")
  eq(
    vim.list_slice(p.argv, 1, 8),
    { "nvim-under-test", "-n", "-i", "NONE", "--headless", "-u", "NORC", "-c" },
    "the editor flags"
  )
  eq(p.argv[9], child.HOST_C_COMMAND, "the -c command is the constant one")
  eq(#p.argv, 9, "nothing else is on the command line")
  for _, a in ipairs(p.argv) do
    ok(not a:find(root, 1, true), "no project path is part of the command line")
    ok(not a:find("a_spec", 1, true), "no spec name is part of the command line")
  end
  ok(p.argv[9]:find("TESTING_CHILD_BOOT", 1, true) ~= nil, "the command names the boot variable")
  ok(
    p.env.TESTING_CHILD_BOOT:find("boot.lua", 1, true) ~= nil,
    "$TESTING_CHILD_BOOT is the boot file"
  )
  ok(vim.uv.fs_stat(p.env.TESTING_CHILD_BOOT) ~= nil, "and the boot file exists")

  -- the driver's own variables (the resolved dependencies) reach the child, even NVIM_* ones it sets itself
  local pe =
    plan({ extra_env = { LIB_NVIM_DIR = "E:/deps/lib.nvim", NVIM_TREESITTER_DIR = "E:/deps/ts" } })
  eq(pe.env.LIB_NVIM_DIR:gsub("\\", "/"), "E:/deps/lib.nvim", "extra_env: $LIB_NVIM_DIR is set")
  eq(
    pe.env.NVIM_TREESITTER_DIR:gsub("\\", "/"),
    "E:/deps/ts",
    "extra_env: the driver may set NVIM_*_DIR"
  )
  eq(p.env.LIB_NVIM_DIR, nil, "and only when it was asked for")

  -- the working directory is the project root (SEC-02)
  eq(p.cwd:gsub("\\", "/"), root, "cwd is the project root")

  -- host l: nvim -l <boot>
  local pl = plan({ host = "l" })
  eq(pl.argv[8], "-l", "host l uses -l")
  ok(pl.argv[9]:find("boot.lua", 1, true) ~= nil, "and the boot file as the script")
  eq(pl.env.TESTING_CHILD_BOOT, nil, "host l needs no boot variable")
  eq(#pl.argv, 9, "host l: nothing else on the command line")
  local ok_bad = pcall(child.build, {
    entry = {},
    root = root,
    ---@diagnostic disable-next-line: assign-type-mismatch
    host = "x",
    parent_env = {},
  })
  eq(ok_bad, false, "an unknown host is refused")

  -- environment: allowlist + sandbox + job
  eq(p.env.PATH, "/bin", "PATH is inherited")
  eq(p.env.HOME, "/home/x", "HOME is inherited")
  eq(p.env.GITHUB_TOKEN, nil, "secrets are not")
  eq(p.env.NVIM, nil, "$NVIM is not")
  ok(vim.tbl_contains(p.dropped_env, "GITHUB_TOKEN"), "dropped names are reported")
  ok(p.env.TESTING_CHILD_JOB:find("job.json", 1, true) ~= nil, "$TESTING_CHILD_JOB names the job")
  local function norm(s)
    return (s:gsub("\\", "/"))
  end
  for _, name in ipairs({
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_RUNTIME_DIR",
    "TEMP",
    "TMP",
    "TMPDIR",
  }) do
    ok(
      norm(p.env[name]):find(norm(p.sandbox), 1, true) == 1,
      name .. " points into the sandbox, got " .. tostring(p.env[name])
    )
  end
  ok(norm(p.env.TEMP) ~= "C:/real/temp", "the real TEMP is replaced")
  ok(norm(p.env.XDG_DATA_HOME) ~= "/real/data", "a real XDG_DATA_HOME is replaced")
  ok(norm(p.sandbox):find(norm(base), 1, true) == 1, "the sandbox lies below the base")

  -- a spelling of the sandbox variable in another case does not survive next to ours
  local mixed = plan({ parent_env = { Temp = "C:\\real", Path = "p" } })
  local temps = 0
  for k in pairs(mixed.env) do
    if k:upper() == "TEMP" then
      temps = temps + 1
    end
  end
  eq(temps, 1, "exactly one TEMP in the child's environment")

  -- env_allow reaches the sanitizer
  local ext = plan({ parent_env = { MY_VAR = "v", PATH = "p" }, env_allow = { "MY_VAR" } })
  eq(ext.env.MY_VAR, "v", "env_allow passes a named variable on")

  -- every child gets its own sandbox
  local p2 = plan()
  ok(p.sandbox ~= p2.sandbox, "two plans, two sandboxes")

  -- the job: serializable, carries the facts the child needs, no function
  local job = plan({
    kind = "script",
    rtp_prepend = { "/a" },
    rtp = { "/b", "/c" },
    filetype = false,
    minit = "/m/init.lua",
    assertions = "warn",
    selector = { filter = { "x" } },
    lf_ids = { "id1" },
    timeouts = { file_ms = 5, case_ms = 2 },
    seed = 7,
    script_args = { "--x" },
  }).job
  eq(job.kind, "script", "job.kind")
  eq(job.root, root, "job.root")
  eq(job.entry.rel, "TESTS/a_spec.lua", "job.entry")
  eq(job.rtp_prepend, { "/a" }, "job.rtp_prepend")
  eq(job.rtp, { "/b", "/c" }, "job.rtp")
  eq(job.filetype, false, "job.filetype")
  eq(job.minit, "/m/init.lua", "job.minit")
  eq(job.assertions, "warn", "job.assertions")
  eq(job.lf_ids, { "id1" }, "job.lf_ids")
  eq(job.timeouts, { file_ms = 5, case_ms = 2 }, "job.timeouts")
  eq(job.seed, 7, "job.seed")
  eq(plan().job.filetype, true, "filetype defaults to on")
  eq(plan().job.kind, "cases", "kind defaults to cases")
  local text, err = require("lib.nvim.json").encode(job)
  ok(text ~= nil, "the job encodes as JSON: " .. tostring(err))

  -- prepare creates the sandbox and writes the job; cleanup removes it, and only a sandbox
  local pr = plan()
  local pok, perr = child.prepare(pr)
  ok(pok, "prepare: " .. tostring(perr))
  for name, d in pairs(pr.dirs) do
    ok(vim.fn.isdirectory(d) == 1, name .. " directory exists")
  end
  local written = S.slurp(pr.job_file)
  ok(written ~= nil, "the job file is written")
  eq(vim.json.decode(written).entry.rel, "TESTS/a_spec.lua", "and it is the job")
  eq(child.cleanup(pr), true, "cleanup removes the sandbox")
  eq(vim.fn.isdirectory(pr.sandbox), 0, "the sandbox is gone")
  local foreign = { sandbox = base .. "/not-a-sandbox" }
  vim.fn.mkdir(foreign.sandbox, "p")
  eq(child.cleanup(foreign), false, "cleanup refuses a directory that is not a child sandbox")
  eq(vim.fn.isdirectory(foreign.sandbox), 1, "and leaves it alone")
  vim.fn.delete(base, "rf")

  -- describe_exit
  local d139 = child.describe_exit({ code = 139, signal = 0 })
  ok(d139:find("exit code 139", 1, true) ~= nil, "the exit code is always named")
  if vim.fn.has("win32") == 1 then
    ok(d139:find("signal", 1, true) == nil, "on Windows 139 is a plain exit code, not a signal")
  else
    ok(d139:find("128 + signal 11", 1, true) ~= nil, "on POSIX 139 is named as 128 + SIGSEGV")
  end
  ok(
    child.describe_exit({ code = 3221225477, signal = 0 }):find("0xC0000005", 1, true) ~= nil,
    "an NTSTATUS exit code is named"
  )
  ok(
    child.describe_exit({ code = 0, signal = 11 }):find("SIGSEGV", 1, true) ~= nil,
    "a signal is named"
  )
end
