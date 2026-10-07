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
  ---@return string
  local function slurp(path)
    local f = assert(io.open(path, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  -- ------------------------------------------------------------------ shell: argv only (SEC-01/02/34/35)
  -- A shell string is a way to turn a test name or a path into a command. The module that WATCHES for such
  -- calls (the process guard) names them; nothing else may make one.
  --
  -- The lint works on a token stream of the whole file (comments dropped, every string one token), not on
  -- single lines: a call whose argument is on the next line, a long string `[[...]]`, a string call
  -- `f"..."` and an alias (`local run = vim.fn.system`) are all seen.

  ---@class D8Token
  ---@field k "name"|"str"|"p"
  ---@field v string
  ---@field line integer

  ---Split Lua source into names, strings and punctuation (numbers count as punctuation).
  ---@param text string
  ---@return D8Token[]
  local function lex(text)
    local toks, i, line, n = {}, 1, 1, #text
    local function count(chunk)
      local _, c = chunk:gsub("\n", "")
      line = line + c
    end
    while i <= n do
      local c = text:sub(i, i)
      if c == "\n" then
        line = line + 1
        i = i + 1
      elseif c:match("%s") then
        i = i + 1
      elseif text:sub(i, i + 1) == "--" then
        local eqs = text:match("^%-%-%[(=*)%[", i)
        if eqs then
          local _, e = text:find("]" .. eqs .. "]", i, true)
          e = e or n
          count(text:sub(i, e))
          i = e + 1
        else
          i = text:find("\n", i, true) or (n + 1)
        end
      elseif c == "[" and text:match("^%[=*%[", i) then
        local eqs = text:match("^%[(=*)%[", i)
        local open_len = #eqs + 2
        local s, e = text:find("]" .. eqs .. "]", i + open_len, true)
        s, e = s or (n + 1), e or n
        toks[#toks + 1] = { k = "str", v = text:sub(i + open_len, s - 1), line = line }
        count(text:sub(i, e))
        i = e + 1
      elseif c == '"' or c == "'" then
        local j, buf = i + 1, {}
        while j <= n do
          local d = text:sub(j, j)
          if d == "\\" then
            buf[#buf + 1] = text:sub(j + 1, j + 1)
            j = j + 2
          elseif d == c or d == "\n" then
            break
          else
            buf[#buf + 1] = d
            j = j + 1
          end
        end
        toks[#toks + 1] = { k = "str", v = table.concat(buf), line = line }
        i = j + 1
      elseif c:match("[%a_]") then
        local name = text:match("^[%w_]+", i)
        toks[#toks + 1] = { k = "name", v = name, line = line }
        i = i + #name
      elseif c:match("%d") then
        local num = text:match("^%d[%w%.]*", i)
        toks[#toks + 1] = { k = "p", v = num, line = line }
        i = i + #num
      else
        local op = text:match("^%.%.%.", i) or text:match("^%.%.", i) or c
        toks[#toks + 1] = { k = "p", v = op, line = line }
        i = i + #op
      end
    end
    return toks
  end

  -- Functions that take a shell string when they are not given an argv table.
  local SPAWNERS = {
    ["vim.fn.system"] = true,
    ["vim.fn.systemlist"] = true,
    ["vim.fn.jobstart"] = true,
    ["vim.fn.termopen"] = true,
  }
  -- Functions that always run a shell string.
  local ALWAYS_SHELL = {
    ["os.execute"] = "os.execute runs a shell string",
    ["io.popen"] = "io.popen runs a shell string",
  }
  -- Functions that run an Ex command: a command that starts with `!` (or `terminal`) runs a shell.
  local EX_RUNNERS = {
    ["vim.cmd"] = true,
    ["vim.api.nvim_command"] = true,
    ["vim.fn.execute"] = true,
  }
  local EX_MODIFIERS = {}
  for word in
    ([[silent silent! unsilent verbose noautocmd keepjumps keepmarks keeppatterns keepalt lockmarks
    sandbox confirm browse hide topleft botright aboveleft belowright leftabove rightbelow vertical
    tab noswapfile]]):gmatch("%S+")
  do
    EX_MODIFIERS[word] = true
  end

  ---Does the Ex command text run a shell (`:!cmd`, `:r !cmd`, `:terminal`), after leading modifiers?
  ---@param cmd string
  ---@return string|nil why
  local function ex_runs_shell(cmd)
    local rest = cmd:gsub("^[%s:]+", "")
    while true do
      local word, after = rest:match("^(%S+)%s*(.*)$")
      if word and EX_MODIFIERS[word] then
        rest = after:gsub("^[%s:]+", "")
      else
        break
      end
    end
    if rest:sub(1, 1) == "!" then
      return "`:!` runs a shell command"
    end
    local word = rest:match("^%a+")
    if word and #word >= 2 and ("terminal"):sub(1, #word) == word then
      return "`:terminal` runs a shell command"
    end
    if rest:match("^r%a*%s*!") or rest:match("^[%d,%.%$%%]*w%a*%s*!") then
      return "`:read !` / `:write !` runs a shell command"
    end
    return nil
  end

  ---@class D8Finding
  ---@field line integer
  ---@field callee string
  ---@field form string "string"|"expr"|"alias"|"shell"|"ex"|"socket": what the allowlist keys on
  ---@field head string First token of the first argument
  ---@field why string

  ---Lint one source text: every call or reference that can run a shell string or open a listening socket.
  ---@param text string
  ---@return D8Finding[]
  local function lint(text)
    local toks, found = lex(text), {}
    local i = 1
    while i <= #toks do
      local t = toks[i]
      local prev = toks[i - 1]
      if t.k == "str" and (t.v == "--listen" or t.v:find("^%-%-listen=")) then
        found[#found + 1] = {
          line = t.line,
          callee = "--listen",
          form = "socket",
          head = t.v,
          why = "a listening socket is reachable by other local users",
        }
      end
      if t.k == "name" and not (prev and (prev.v == "." or prev.v == ":")) then
        -- the dotted chain `a.b.c` starting here
        local parts, j = { t.v }, i + 1
        while toks[j] and toks[j].v == "." and toks[j + 1] and toks[j + 1].k == "name" do
          parts[#parts + 1] = toks[j + 1].v
          j = j + 2
        end
        local callee = table.concat(parts, ".")
        if SPAWNERS[callee] or ALWAYS_SHELL[callee] or EX_RUNNERS[callee] then
          local nxt = toks[j]
          local first -- the first argument token
          local called = true
          if nxt and nxt.k == "p" and nxt.v == "(" then
            first = toks[j + 1]
            if first and first.k == "p" and first.v == ")" then
              first = nil
            end
          elseif nxt and (nxt.k == "str" or (nxt.k == "p" and nxt.v == "{")) then
            first = nxt
          else
            called = false
          end
          local at = { line = t.line, callee = callee, head = first and first.v or "" }
          if ALWAYS_SHELL[callee] then
            at.form, at.why = "shell", ALWAYS_SHELL[callee]
            found[#found + 1] = at
          elseif SPAWNERS[callee] then
            if not called then
              at.form = "alias"
              at.why = callee .. " is referenced without a call: an alias hides a shell string"
              found[#found + 1] = at
            elseif not (first and first.k == "p" and first.v == "{") then
              at.form = (first and first.k == "str") and "string" or "expr"
              at.why = at.form == "string" and (callee .. " with a string is a shell command")
                or (callee .. " without a literal argv table cannot be told from a shell string")
              found[#found + 1] = at
            end
          elseif called and first and first.k == "str" then
            local why = ex_runs_shell(first.v)
            if why then
              at.form, at.head, at.why = "ex", first.v:sub(1, 20), why
              found[#found + 1] = at
            end
          end
        end
        i = j - 1
      end
      i = i + 1
    end
    return found
  end

  -- Spawns that are not a literal argv table but are fine: the argument is an argv list built elsewhere.
  -- Key: `<relative path> <callee> <first token>`. Every entry has to be used (a stale one fails the spec).
  local ALLOWED_FORMS = {}
  local ALLOWED = {
    ["lua/testing/guard/process_net.lua"] = true, -- wraps those very functions to judge them
  }
  local scanned, offenders, used = 0, {}, {}
  for _, path in ipairs(H.glob(root .. "/lua/**/*.lua")) do
    path = path:gsub("\\", "/")
    local rel = path:sub(#root:gsub("\\", "/") + 2)
    if not ALLOWED[rel] then
      scanned = scanned + 1
      for _, hit in ipairs(lint(slurp(path))) do
        local key = ("%s %s %s"):format(rel, hit.callee, hit.head)
        if ALLOWED_FORMS[key] then
          used[key] = true
        else
          offenders[#offenders + 1] = ("%s:%d %s [%s]"):format(rel, hit.line, hit.why, key)
        end
      end
    end
  end
  ok(scanned > 100, "the scan looked at the whole runner (" .. scanned .. " files)")
  eq(offenders, {}, "no shell string, no unclear spawn form and no listening socket in the runner")
  for key in pairs(ALLOWED_FORMS) do
    ok(used[key], "the allowlist entry is still needed: " .. key)
  end

  -- ------------------------------------------------------------ the lint is not blind: a positive and a
  -- negative example per call form, on one line and over several
  local function forms(src)
    local out = {}
    for _, hit in ipairs(lint(src)) do
      out[#out + 1] = hit.callee .. ":" .. hit.form
    end
    return out
  end
  local positives = {
    { "local x = io.popen('ls')", { "io.popen:shell" } },
    { "os.execute(\n  cmd\n)", { "os.execute:shell" } },
    { 'vim.fn.system("git status")', { "vim.fn.system:string" } },
    { "vim.fn.system(\n  cmdline\n)", { "vim.fn.system:expr" } },
    { "vim.fn.system(cmd, input)", { "vim.fn.system:expr" } },
    { "vim.fn.systemlist [[git log]]", { "vim.fn.systemlist:string" } },
    { 'vim.fn.systemlist"git"', { "vim.fn.systemlist:string" } },
    { "vim.fn.jobstart(\n  'git status',\n  {}\n)", { "vim.fn.jobstart:string" } },
    { "vim.fn.jobstart(argv, { cwd = d })", { "vim.fn.jobstart:expr" } },
    { 'vim.fn.termopen("sh")', { "vim.fn.termopen:string" } },
    { "vim.fn.termopen(cmd)", { "vim.fn.termopen:expr" } },
    { "local run = vim.fn.system", { "vim.fn.system:alias" } },
    { "run(vim.fn.jobstart, 1)", { "vim.fn.jobstart:alias" } },
    { "vim.cmd([[!rm -rf x]])", { "vim.cmd:ex" } },
    { "vim.cmd([[\n  !make\n]])", { "vim.cmd:ex" } },
    { "vim.cmd('silent !make')", { "vim.cmd:ex" } },
    { "vim.cmd('silent! keepalt !make')", { "vim.cmd:ex" } },
    { 'vim.cmd("r !date")', { "vim.cmd:ex" } },
    { 'vim.cmd("terminal")', { "vim.cmd:ex" } },
    { 'vim.cmd("term sh")', { "vim.cmd:ex" } },
    { 'vim.api.nvim_command("!ls")', { "vim.api.nvim_command:ex" } },
    { 'vim.fn.execute("!ls")', { "vim.fn.execute:ex" } },
    { 'local a = { "--listen", addr }', { "--listen:socket" } },
  }
  for _, case in ipairs(positives) do
    eq(forms(case[1]), case[2], "found: " .. case[1]:gsub("\n", " "))
  end
  local negatives = {
    "vim.system({ 'git' })",
    "vim.fn.system({ 'git', 'status' })",
    "vim.fn.system(\n  { 'git', 'status' }\n)",
    "vim.fn.systemlist({ 'git' }, input)",
    "vim.fn.jobstart({ 'nvim', '--headless' }, {})",
    "vim.fn.termopen({ 'sh' })",
    "vim.cmd('edit foo')",
    "vim.cmd('silent! edit foo!')",
    "vim.cmd([[normal! gg]])",
    "vim.cmd.edit(path)",
    "vim.cmd('terms')",
    'vim.fn.execute("abbreviate")',
    "-- io.popen('ls') in a comment",
    "--[[ vim.fn.system('x') in a block comment ]]",
    "--[==[\n vim.fn.system('x')\n]==]",
    'local s = "mentions vim.fn.system and io.popen in a string"',
    "local s = [[os.execute(1)]]",
    "my.vim.fn.system('x')",
    "obj:io.popen('x')",
    "local fn = vim.fn.fnamemodify(p, ':p')",
    'local s = "--listening"',
  }
  for _, src in ipairs(negatives) do
    eq(forms(src), {}, "not flagged: " .. src:gsub("\n", " "))
  end
  -- lines are counted over comments and long strings
  eq(lint("--[[\n\n]]\nlocal a = [[\n\n]]\nos.execute(1)")[1].line, 7, "the line of a finding")

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
