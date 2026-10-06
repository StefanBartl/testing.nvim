-- TESTS/testing/child_env_spec.lua -- the environment of a child editor: an allowlist, never a copy.
-- Secrets and pointers to the parent editor are dropped, the project can extend the list (but never
-- with the whole environment or with NVIM*), the sandbox variables point into one directory.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local env = require("testing.child.env")

  local parent = {
    PATH = "/usr/bin",
    Path = nil,
    HOME = "/home/x",
    LANG = "de_AT.UTF-8",
    LC_TIME = "C",
    GITHUB_TOKEN = "ghp_secret",
    OPENAI_API_KEY = "sk-secret",
    AWS_SECRET_ACCESS_KEY = "aws",
    NVIM = "/tmp/nvim.sock",
    NVIM_LISTEN_ADDRESS = "/tmp/nvim.sock2",
    NVIM_APPNAME = "mine",
    LUA_PATH = "x",
    LUA_CPATH = "y",
    MY_FLAG = "1",
    SystemRoot = "C:\\Windows",
    TEMP = "C:\\real\\temp",
  }

  -- default: only the allowlist (+ LC_*) survives, whatever the case of the name
  local r = env.sanitize(parent)
  eq(r.env.PATH, "/usr/bin", "PATH is kept")
  eq(r.env.HOME, "/home/x", "HOME is kept")
  eq(r.env.LANG, "de_AT.UTF-8", "LANG is kept")
  eq(r.env.LC_TIME, "C", "LC_* is kept")
  eq(r.env.SystemRoot, "C:\\Windows", "SystemRoot is kept in its own spelling")
  eq(r.env.GITHUB_TOKEN, nil, "GITHUB_TOKEN is dropped")
  eq(r.env.OPENAI_API_KEY, nil, "*_API_KEY is dropped")
  eq(r.env.AWS_SECRET_ACCESS_KEY, nil, "cloud credentials are dropped")
  eq(r.env.NVIM, nil, "$NVIM is dropped")
  eq(r.env.NVIM_LISTEN_ADDRESS, nil, "$NVIM_LISTEN_ADDRESS is dropped")
  eq(r.env.NVIM_APPNAME, nil, "NVIM_APPNAME is dropped")
  eq(r.env.LUA_PATH, nil, "what is not on the list is dropped")
  eq(r.env.MY_FLAG, nil, "an unknown variable is dropped")
  ok(vim.tbl_contains(r.dropped, "GITHUB_TOKEN"), "the dropped names are reported")
  ok(not vim.tbl_contains(r.dropped, "PATH"), "kept names are not reported as dropped")

  -- the sanitizer returns a new table
  r.env.PATH = "changed"
  eq(parent.PATH, "/usr/bin", "the parent table is not modified")

  -- matching is case-insensitive (Windows spells Path / PATH either way)
  local ci = env.sanitize({ Path = "p", home = "h", github_token = "t" })
  eq(ci.env.Path, "p", "Path matches PATH")
  eq(ci.env.home, "h", "home matches HOME")
  eq(ci.env.github_token, nil, "a lower-case secret is dropped as well")

  -- the project extends the list: exact names and PREFIX*
  local ext = env.sanitize(parent, { allow = { "MY_FLAG", "LUA_*" } })
  eq(ext.env.MY_FLAG, "1", "env_allow: an exact name")
  eq(ext.env.LUA_PATH, "x", "env_allow: a prefix pattern")
  eq(ext.env.LUA_CPATH, "y", "env_allow: the prefix matches every name")
  eq(ext.env.GITHUB_TOKEN, nil, "env_allow does not open the rest")

  -- ... but never the leak this exists to prevent
  local bad = env.sanitize(parent, { allow = { "*", "NVIM", "NVIM_*", "nvim_listen_address" } })
  eq(bad.env.NVIM, nil, "env_allow cannot pass $NVIM")
  eq(bad.env.NVIM_LISTEN_ADDRESS, nil, "env_allow cannot pass $NVIM_LISTEN_ADDRESS")
  eq(bad.env.GITHUB_TOKEN, nil, "a bare * is refused: the token stays out")
  local a1, why1 = env.check_entry("*")
  eq(a1, false, "check_entry refuses a bare *")
  ok((why1 or ""):find("whole environment", 1, true) ~= nil, "and says why")
  eq((env.check_entry("NVIM_X")), false, "check_entry refuses NVIM*")
  eq((env.check_entry("")), false, "check_entry refuses an empty name")
  eq((env.check_entry("A B")), false, "check_entry refuses a name with a space")
  eq((env.check_entry("MY_VAR")), true, "check_entry accepts a plain name")
  eq((env.check_entry("LUA_*")), true, "check_entry accepts a prefix")
  eq((env.check_entry(5)), false, "check_entry refuses a non-string")

  -- is_denied
  eq(env.is_denied("NVIM"), true, "NVIM is denied")
  eq(env.is_denied("nvim_log_file"), true, "any case")
  eq(env.is_denied("NVR"), false, "NVR is a different thing")

  -- sandbox: every directory is below the base, every variable names one
  local dirs, vars = env.sandbox_env("C:\\tmp\\box")
  for name, dir in pairs(dirs) do
    ok(dir:find("C:/tmp/box/", 1, true) == 1, name .. " lies below the sandbox base")
  end
  eq(vars.XDG_DATA_HOME, dirs.data, "XDG_DATA_HOME -> data")
  eq(vars.XDG_STATE_HOME, dirs.state, "XDG_STATE_HOME -> state")
  eq(vars.XDG_CACHE_HOME, dirs.cache, "XDG_CACHE_HOME -> cache")
  eq(vars.XDG_CONFIG_HOME, dirs.config, "XDG_CONFIG_HOME -> config")
  eq(vars.XDG_RUNTIME_DIR, dirs.run, "XDG_RUNTIME_DIR -> run")
  eq(vars.TEMP, dirs.tmp, "TEMP -> tmp")
  eq(vars.TMP, dirs.tmp, "TMP -> tmp")
  eq(vars.TMPDIR, dirs.tmp, "TMPDIR -> tmp")
  local distinct = {}
  for _, d in pairs(dirs) do
    distinct[d] = true
  end
  eq(vim.tbl_count(distinct), vim.tbl_count(dirs), "the directories are distinct")
end
