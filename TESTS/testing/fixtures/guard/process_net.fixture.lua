-- Scenarios of the process / network guard (RED: blocked and logged, GREEN: tag / config / dynamic
-- allows, windows, redaction). Run by TESTS/testing/guard_process_net_spec.lua in a real child editor.

local B = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/boot.lua")
local uv = vim.uv
local exe = vim.v.progpath

local function only_pn(extra, top)
  ---@type table<string, any>
  local g = { process_net = vim.tbl_extend("force", { mode = "error" }, extra or {}) }
  for _, name in ipairs({ "fs", "state", "scheduled_error", "prompt", "deprecation", "clock" }) do
    g[name] = "off"
  end
  return vim.tbl_extend("force", { guards = g }, top or {})
end

---Run `fn`, report whether it raised the guard's error.
---@param fn fun()
---@return string "blocked" | "ok" | "other:<msg>"
local function attempt(fn)
  local ok, err = pcall(fn)
  if ok then
    return "ok"
  end
  if tostring(err):find("testing.guard", 1, true) then
    return "blocked"
  end
  return "other:" .. tostring(err):match("^[^\n]*")
end

local function exercise_spawn()
  local r = {}
  r.vim_system = attempt(function()
    vim.system({ exe, "--version" })
  end)
  r.jobstart = attempt(function()
    vim.fn.jobstart({ exe, "--version" })
  end)
  r.fn_system = attempt(function()
    vim.fn.system({ exe, "--version" })
  end)
  r.fn_systemlist = attempt(function()
    vim.fn.systemlist({ exe, "--version" })
  end)
  r.io_popen = attempt(function()
    io.popen('"' .. exe .. '" --version')
  end)
  r.os_execute = attempt(function()
    os.execute('"' .. exe .. '" --version')
  end)
  r.uv_spawn = attempt(function()
    uv.spawn(exe, { args = { "--version" } }, function() end)
  end)
  return r
end

local function exercise_network()
  local r = {}
  r.tcp_connect = attempt(function()
    local tcp = assert(uv.new_tcp())
    tcp:connect("127.0.0.1", 9, function() end)
    tcp:close()
  end)
  r.getaddrinfo = attempt(function()
    uv.getaddrinfo("example.invalid", nil, nil, function() end)
  end)
  r.udp_send = attempt(function()
    local udp = assert(uv.new_udp())
    udp:send("x", "127.0.0.1", 9, function() end)
    udp:close()
  end)
  r.sockconnect = attempt(function()
    vim.fn.sockconnect("tcp", "127.0.0.1:9")
  end)
  if vim.net and vim.net.request then
    r.net_request = attempt(function()
      vim.net.request("https://user:pw@example.invalid/path?token=abc123&q=1", {}, function() end)
    end)
  end
  return r
end

B.case("red_spawn_blocked", {
  cfg = only_pn(),
  body = exercise_spawn,
})

B.case("red_network_blocked", {
  cfg = only_pn(),
  body = exercise_network,
})

B.case("red_secrets_redacted", {
  cfg = only_pn(),
  body = function()
    return {
      a = attempt(function()
        vim.system({
          exe,
          "--token",
          "sk-abcdefghijklmnopqrstuvwx",
          "--password=hunter2",
          "plain arg",
        })
      end),
      b = attempt(function()
        vim.system({
          "curl",
          "-H",
          "Authorization: Bearer ghp_abcdefghijklmnopqrstuvwxyz0123",
          "https://user:pw@h.example/x?api_key=zzz",
        })
      end),
    }
  end,
})

B.case("red_warn_mode_lets_it_through", {
  cfg = only_pn({ mode = "warn" }),
  body = function()
    local r = vim.system({ exe, "--version" }):wait()
    return { code = r.code }
  end,
})

B.case("green_tag_spawn", {
  cfg = only_pn(),
  ctx = { id = "fx::tag", file = "fx.lua", tags = { "spawn" } },
  body = function()
    local r = vim.system({ exe, "--version" }):wait()
    return {
      code = r.code,
      net = attempt(function()
        uv.getaddrinfo("example.invalid", nil, nil, function() end)
      end),
    }
  end,
})

B.case("green_tag_in_name", {
  cfg = only_pn(),
  ctx = { id = "fx::name", file = "fx.lua", name = "runs the tool @spawn" },
  body = function()
    local r = vim.system({ exe, "--version" }):wait()
    return { code = r.code }
  end,
})

B.case("green_tag_network", {
  cfg = only_pn(),
  ctx = { id = "fx::net", file = "fx.lua", tags = { "@network" } },
  body = function()
    return exercise_network()
  end,
})

B.case("green_config_allow_exec", {
  cfg = only_pn({ allow_exec = { "NVIM" } }),
  body = function()
    local r = vim.system({ exe, "--version" }):wait()
    return {
      code = r.code,
      other = attempt(function()
        vim.system({ "git", "--version" })
      end),
    }
  end,
})

B.case("green_config_allow_exec_shell_quotes", {
  cfg = only_pn({ allow_exec = { "NVIM" } }),
  body = function()
    ---@param line string
    ---@return string
    local function popen(line)
      return attempt(function()
        local f = assert(io.popen(line))
        f:close()
      end)
    end
    return {
      -- the quoting `cmd /c` wants around a line whose program is quoted: the outer pair is no part of the command
      outer_pair = popen('""' .. exe .. '" "--version" 2>&1"'),
      -- the program is still judged by its name: an unlisted one is blocked in this spelling, too
      other = popen('""git" "--version" 2>&1"'),
    }
  end,
})

B.case("green_config_allow_host", {
  cfg = only_pn({ allow_hosts = { "127.0.0.1" } }),
  body = function()
    return {
      local_ok = attempt(function()
        local tcp = assert(uv.new_tcp())
        tcp:connect("127.0.0.1", 9, function() end)
        tcp:close()
      end),
      remote = attempt(function()
        uv.getaddrinfo("example.invalid", nil, nil, function() end)
      end),
    }
  end,
})

B.case("green_dynamic_allow", {
  cfg = only_pn(),
  body = function(h)
    h:allow("spawn", "nvim")
    local r = vim.system({ exe, "--version" }):wait()
    return { code = r.code }
  end,
})

B.case("green_suspended_and_outside_the_window", {
  cfg = only_pn(),
  body = function(h)
    local code
    h:suspended(function()
      code = vim.system({ exe, "--version" }):wait().code
    end)
    return { code = code }
  end,
  after = function()
    -- the case is closed: the runner's own spawns are not blocked and not logged
    return { outside = vim.system({ exe, "--version" }):wait().code }
  end,
})

B.case("green_no_spawn", {
  cfg = only_pn(),
  body = function()
    return { sum = 1 + 1 }
  end,
})

B.finish()
