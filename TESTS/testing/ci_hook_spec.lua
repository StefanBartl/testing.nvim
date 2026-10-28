-- TESTS/testing/ci_hook_spec.lua -- `testing ci hook install|remove`: the pre-push hook in a temporary repository
-- (install, again, remove; a foreign hook is never touched; the hook of `:MyPlugins ci` is replaced), the script's text,
-- and the hook run for real with bash: a proven state passes without a run, an unproven one runs the profile, a red
-- profile blocks the push.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local hook = require("testing.ci.hook")
  local cli = require("testing.cli")

  do
    local a = hook.parse({ "install", "--run=quick", "--verify=full" })
    eq({ a.action, a.run, a.verify }, { "install", "quick", "full" }, "args: install with profiles")
    eq(hook.parse({ "install" }).run, "fast", "args: the default profile to run is fast")
    local none, why = hook.parse({ "install", "--run=a b" })
    eq(none, nil, "args: a profile with a blank")
    has(why, "not a profile name", "args: ... is named")
    none, why = hook.parse({})
    eq(none, nil, "args: no action")
    has(why, "install or remove", "args: ... is named")
    none = hook.parse({ "remove", "--frobnicate" })
    eq(none, nil, "args: an unknown argument")
  end

  local text = hook.text({ run = "fast", verify = "full", driver_dir = "/opt/testing.nvim" })
  has(text, hook.MARK, "text: carries the mark")
  has(text, "testing_ci verify --profile=full && exit 0", "text: asks verify first")
  has(text, "--profile=fast --reuse", "text: runs the profile only when needed")
  has(
    text,
    '"$root/.deps/testing.nvim" "$root/../testing.nvim" "/opt/testing.nvim"',
    "text: finds testing.nvim"
  )
  lacks(text, "\\", "text: no backslash (Git Bash and Linux sh alike)")
  lacks(
    hook.text({ run = "fast", driver_dir = "/x" }),
    "verify --profile",
    "text: verify defaults to ci.default"
  )

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-hook"
  vim.fn.mkdir(tmp, "p")
  local nvim = vim.v.progpath

  local function write(path, body)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(body)
    f:close()
  end
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end
  local function nv(script, ...)
    local parts =
      { ("%q"):format(nvim), '"--headless"', '"-u"', '"NONE"', '"-i"', '"NONE"', '"-l"' }
    parts[#parts + 1] = ("%q"):format(script)
    for _, a in ipairs({ ... }) do
      parts[#parts + 1] = ("%q"):format(a)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  ---@param name string
  ---@param ci_lua string
  ---@param files? table<string, string>
  local function project(name, ci_lua, files)
    local root = tmp .. "/" .. name
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = " .. ci_lua .. " }\n"
    )
    for rel, body in pairs(files or {}) do
      write(root .. "/" .. rel, body)
    end
    git(root, "init", "-q")
    git(root, "symbolic-ref", "HEAD", "refs/heads/main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  local function run(...)
    local out, err = {}, {}
    local code = cli.main({ "ci", "hook", ... }, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
    })
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  local ECHO = "io.stdout:write('echo ok\\n')\n"
  local FAILS = "os.exit(3)\n"
  local CFG = "{ profiles = { fast = { 'echo' }, full = { 'echo' } }, default = 'full', steps = { echo = { run = "
    .. nv("lua/proj/echo.lua")
    .. " } } }"

  -- install, install again, remove
  do
    local root = project("install", CFG, { ["lua/proj/echo.lua"] = ECHO })
    local path = root .. "/.git/hooks/pre-push"
    local res = run("install", "--root=" .. root)
    eq(res.code, 0, "install: exit 0 (" .. res.err .. ")")
    has(res.out, "pre-push hook installed", "install: said so")
    has(read(path), hook.MARK, "install: the hook is there")
    if not vim.uv.os_uname().sysname:find("Windows", 1, true) then
      local st = vim.uv.fs_stat(path)
      ok(st and bit.band(st.mode, tonumber("100", 8)) ~= 0, "install: executable")
    end
    local first = read(path)
    eq(run("install", "--root=" .. root).code, 0, "install again: exit 0")
    eq(read(path), first, "install again: the same hook")
    res = run("remove", "--root=" .. root)
    eq(res.code, 0, "remove: exit 0")
    eq(read(path), nil, "remove: the hook is gone")
    res = run("remove", "--root=" .. root)
    eq(res.code, 0, "remove again: nothing to do is not an error")
    has(res.out, "no pre-push hook", "remove again: said so")
  end

  -- a hook of somebody else is never touched; the hook of :MyPlugins ci is replaced
  do
    local root = project("foreign", CFG, { ["lua/proj/echo.lua"] = ECHO })
    local path = root .. "/.git/hooks/pre-push"
    write(path, "#!/bin/sh\necho mine\n")
    local res = run("install", "--root=" .. root)
    eq(res.code, 1, "foreign: install is refused")
    has(res.err, "not ours", "foreign: said so")
    eq(read(path), "#!/bin/sh\necho mine\n", "foreign: left alone")
    eq(run("remove", "--root=" .. root).code, 1, "foreign: remove is refused")
    eq(read(path), "#!/bin/sh\necho mine\n", "foreign: still there after remove")

    write(
      path,
      "#!/bin/sh\n"
        .. hook.LEGACY_MARK
        .. " (git push --no-verify skips it)\nbash scripts/ci.sh --fast\n"
    )
    res = run("install", "--root=" .. root)
    eq(res.code, 0, "legacy: install replaces the MyPlugins hook (" .. res.err .. ")")
    has(res.out, "replacing the one of :MyPlugins ci", "legacy: said so")
    has(read(path), hook.MARK, "legacy: now ours")
    lacks(read(path), "scripts/ci.sh", "legacy: the old command is gone")
    -- a foreign hook that merely mentions a mark is still foreign
    write(path, "#!/bin/sh\n# see " .. hook.MARK .. " and " .. hook.LEGACY_MARK .. "\necho mine\n")
    eq(
      run("install", "--root=" .. root).code,
      1,
      "a mark inside a comment does not make a hook ours"
    )
    eq(run("remove", "--root=" .. root).code, 1, "... nor may remove take it away")
    write(path, "#!/bin/sh\n" .. hook.LEGACY_MARK .. "\n")
    eq(run("remove", "--root=" .. root).code, 0, "legacy: remove takes the MyPlugins hook away too")
  end

  -- usage errors
  do
    local root = project("usage", CFG, { ["lua/proj/echo.lua"] = ECHO })
    local res = run("install", "--run=nope", "--root=" .. root)
    eq(res.code, 2, "an unknown profile: exit 2")
    has(res.err, "unknown profile nope", "an unknown profile: named")
    eq(read(root .. "/.git/hooks/pre-push"), nil, "an unknown profile: nothing written")
    eq(run("install", "--root=" .. tmp).code, 2, "not a git checkout: exit 2")
    local bare = tmp .. "/noci"
    write(bare .. "/.testing.lua", "return { plugin = 'proj' }\n")
    git(bare, "init", "-q")
    res = run("install", "--root=" .. bare)
    eq(res.code, 2, "no ci section: exit 2")
    has(res.err, "no `ci` section", "no ci section: named")
  end

  -- the hook run for real: a proven state passes without a run, an unproven one runs the profile, red blocks
  if vim.fn.executable("bash") == 1 then
    local env = {
      XDG_STATE_HOME = tmp .. "/xdg-state",
      XDG_DATA_HOME = tmp .. "/xdg-data",
      XDG_CACHE_HOME = tmp .. "/xdg-cache",
      XDG_CONFIG_HOME = tmp .. "/xdg-config",
      TESTING_NVIM_DIR = "",
    }
    local function sh(root, argv)
      local res = vim.system(argv, { cwd = root, text = true, env = env }):wait(120000)
      return { code = res.code, out = (res.stdout or "") .. (res.stderr or "") }
    end
    local driver = hook._plugin_root() .. "/scripts/testing.lua"

    local root = project("real", CFG, { ["lua/proj/echo.lua"] = ECHO })
    eq(run("install", "--root=" .. root).code, 0, "real: installed")
    local hook_path = root .. "/.git/hooks/pre-push"

    local res = sh(root, { "bash", hook_path })
    eq(res.code, 0, "real: an unproven state runs the profile, green: exit 0 (" .. res.out .. ")")
    has(res.out, "not proven, running testing ci --profile=fast", "real: ran the profile")

    -- a complete run of the default profile is the proof: the hook then passes at once
    res = sh(
      root,
      { nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l", driver, "ci", "--root=" .. root }
    )
    eq(res.code, 0, "real: the full run is green (" .. res.out .. ")")
    res = sh(root, { "bash", hook_path })
    eq(res.code, 0, "real: a proven state passes (" .. res.out .. ")")
    lacks(res.out, "not proven", "real: ... without a run")

    -- a red profile blocks the push
    write(root .. "/lua/proj/echo.lua", FAILS)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "break")
    res = sh(root, { "bash", hook_path })
    eq(res.code, 1, "real: a red profile blocks the push (" .. res.out .. ")")
    has(res.out, "push blocked", "real: ... and says so")
  end

  vim.fn.delete(tmp, "rf")
end
