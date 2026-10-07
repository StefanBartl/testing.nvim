-- TESTS/testing/security_d8_spec.lua -- the cross-cutting security controls of the runner (SEC-01/02/10/34/35/41):
-- the runner itself must never reach for a shell string or open a listening socket, and a child editor built
-- from a hostile parent environment carries none of it. Each control has a case that triggers it; the
-- per-feature specs (child_env, guard_process_net, report_junit, cache_key, ...) cover the rest.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end

  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local root = vim.fs.dirname(vim.fs.dirname(dir))

  ---@param path string
  ---@return string[]
  local function code_lines(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    local out = {}
    local n = 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
      n = n + 1
      local stripped = vim.trim(line)
      if stripped:sub(1, 2) ~= "--" then
        out[#out + 1] = { n = n, text = line }
      end
    end
    return out
  end

  -- ------------------------------------------------------------------ shell: argv only (SEC-01/02/34/35)
  -- A shell string is a way to turn a test name or a path into a command. The module that WATCHES for such
  -- calls (the process guard) names them; nothing else may make one.
  local FORBIDDEN = {
    { "os%.execute%s*%(", "os.execute runs a shell string" },
    { "io%.popen%s*%(", "io.popen runs a shell string" },
    { "vim%.fn%.system%s*%(%s*[\"'%[]", "vim.fn.system with a string is a shell command" },
    { "vim%.fn%.systemlist%s*%(%s*[\"'%[]", "vim.fn.systemlist with a string is a shell command" },
    { "vim%.fn%.jobstart%s*%(%s*[\"'%[]", "vim.fn.jobstart with a string is a shell command" },
    { "vim%.cmd%s*%(%s*[\"']!", "`:!` runs a shell command" },
    { '"%-%-listen"', "a listening socket is reachable by other local users" },
  }
  local ALLOWED = {
    ["lua/testing/guard/process_net.lua"] = true, -- wraps those very functions to judge them
  }
  local scanned, offenders = 0, {}
  for _, path in ipairs(vim.fn.globpath(root .. "/lua", "**/*.lua", false, true)) do
    path = path:gsub("\\", "/")
    local rel = path:sub(#root:gsub("\\", "/") + 2)
    if not ALLOWED[rel] then
      scanned = scanned + 1
      for _, line in ipairs(code_lines(path)) do
        for _, rule in ipairs(FORBIDDEN) do
          if line.text:find(rule[1]) then
            offenders[#offenders + 1] = ("%s:%d %s"):format(rel, line.n, rule[2])
          end
        end
      end
    end
  end
  ok(scanned > 100, "the scan looked at the whole runner (" .. scanned .. " files)")
  eq(offenders, {}, "no shell string and no listening socket in the runner")

  -- the lint is not blind: a line it must find
  local probe = "local x = io.popen('ls')"
  ok(probe:find(FORBIDDEN[2][1]) ~= nil, "the io.popen rule matches what it is written for")
  ok(
    ('vim.fn.system("git status")'):find(FORBIDDEN[3][1]) ~= nil,
    "the system rule matches a string"
  )
  ok(not ("vim.system({ 'git' })"):find(FORBIDDEN[3][1]), "and not an argv call")

  -- ------------------------------------------------------------------ editor, secrets, user data: the child
  local child = require("testing.child")
  local hostile = {
    PATH = "/usr/bin",
    HOME = "/home/real",
    NVIM = "/tmp/parent.sock",
    NVIM_LISTEN_ADDRESS = "/tmp/parent.sock",
    NVIM_APPNAME = "mine",
    GITHUB_TOKEN = "ghp_x",
    ANTHROPIC_API_KEY = "sk-ant-x",
    OPENAI_API_KEY = "sk-x",
    GEMINI_API_KEY = "g-x",
    MY_SERVICE_SECRET = "s",
    TEMP = "/real/tmp",
    TMPDIR = "/real/tmp",
    XDG_DATA_HOME = "/real/data",
  }
  for _, host in ipairs({ "c", "l" }) do
    local plan = child.build({
      root = root,
      files = {},
      host = host,
      parent_env = hostile,
      base = vim.fn.tempname(),
    })
    local joined = table.concat(plan.argv, " ")
    ok(not joined:find("--listen", 1, true), "host " .. host .. ": the child listens on nothing")
    for name in pairs(plan.env) do
      ok(
        name:upper():sub(1, 4) ~= "NVIM",
        "host " .. host .. ": no NVIM* variable (" .. name .. ")"
      )
    end
    for _, secret in ipairs({
      "GITHUB_TOKEN",
      "ANTHROPIC_API_KEY",
      "OPENAI_API_KEY",
      "GEMINI_API_KEY",
      "MY_SERVICE_SECRET",
    }) do
      eq(plan.env[secret], nil, "host " .. host .. ": " .. secret .. " does not reach the child")
    end
    for _, secret in ipairs({ "ghp_x", "sk-ant-x", "sk-x", "g-x" }) do
      ok(not joined:find(secret, 1, true), "host " .. host .. ": no secret on the command line")
    end
    -- the project cannot ask for the parent editor's pointers back
    local asked = child.build({
      root = root,
      files = {},
      host = host,
      parent_env = hostile,
      env_allow = { "NVIM", "NVIM_LISTEN_ADDRESS" },
      base = vim.fn.tempname(),
    })
    for name in pairs(asked.env) do
      ok(
        name:upper():sub(1, 4) ~= "NVIM",
        "host " .. host .. ": env_allow cannot bring back " .. name
      )
    end
    eq(plan.env.HOME, "/home/real", "host " .. host .. ": HOME stays real (git needs it)")
    for _, key in ipairs({ "XDG_DATA_HOME", "TEMP", "TMPDIR" }) do
      ok(
        plan.env[key] ~= nil and plan.env[key] ~= hostile[key],
        "host " .. host .. ": " .. key .. " is redirected into the run directory"
      )
      ok(
        tostring(plan.env[key]):gsub("\\", "/"):find(plan.sandbox:gsub("\\", "/"), 1, true) ~= nil,
        "host " .. host .. ": " .. key .. " lies below the sandbox"
      )
    end
  end
end
