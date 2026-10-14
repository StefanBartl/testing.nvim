---@module 'testing.child.env'
---@brief The environment of a child editor: an ALLOWLIST, never a copy of the parent's environment.
---@description
--- A spec runs with whatever environment the process has. When the process is the user's editor or a
--- CI step, that environment carries secrets (`GITHUB_TOKEN`, `*_API_KEY`, cloud credentials) and
--- pointers to the parent editor (`$NVIM`, `$NVIM_LISTEN_ADDRESS`: a spec that calls `nvim --remote`
--- or `vim.fn.serverstart` would talk to the editor that runs the tests). A child therefore starts
--- from NOTHING and receives only:
---
---   * the names in `M.ALLOW` (system and locale basics: `PATH`, `HOME`/`USERPROFILE`, `SystemRoot`,
---     `LANG`, `TERM`, `CI`, ...) and every `LC_*`;
---   * the names the project asks for (`.testing.lua` key `env_allow`, `--env-allow NAME`); an entry
---     may end in `*` to name a prefix (`LUA_*`). A bare `*` and everything starting with `NVIM` are
---     refused: they are the leak this module exists to prevent;
---   * what the driver sets itself (`TESTING_CHILD_JOB`, the XDG directories and the temp
---     directories of the sandbox).
---
--- Matching is case-insensitive (Windows treats `Path` and `PATH` as one variable).
---
--- Determinism: unless the caller opts out (`deterministic = false`) `LANG`/`LC_ALL=C.UTF-8` and
--- `TZ=UTC` are SET in the child (`apply_determinism`), whatever the parent has.
---
--- Residual write places, by design NOT redirected: `HOME`/`USERPROFILE`, `APPDATA`/`LOCALAPPDATA`.
--- Tools that a spec runs (git) need the user's identity; the places Neovim itself writes to
--- (`stdpath` data/state/cache/config/run) and the temp directories ARE redirected (`sandbox_env`).
---
--- Pure: takes the parent environment as a table, returns a new table; touches no editor state.

local M = {}

---Variables a child may inherit without being asked.
---@type string[]
M.ALLOW = {
  -- executables and shell
  "PATH",
  "PATHEXT",
  "SHELL",
  "COMSPEC",
  -- identity and home (git needs them; see the module header)
  "HOME",
  "USERPROFILE",
  "HOMEDRIVE",
  "HOMEPATH",
  "USER",
  "USERNAME",
  "LOGNAME",
  "USERDOMAIN",
  "COMPUTERNAME",
  "APPDATA",
  "LOCALAPPDATA",
  "ALLUSERSPROFILE",
  "PUBLIC",
  -- Windows system
  "SYSTEMROOT",
  "SYSTEMDRIVE",
  "WINDIR",
  "OS",
  "PROCESSOR_ARCHITECTURE",
  "PROCESSOR_ARCHITEW6432",
  "NUMBER_OF_PROCESSORS",
  "PROGRAMFILES",
  "PROGRAMFILES(X86)",
  "PROGRAMW6432",
  "PROGRAMDATA",
  "COMMONPROGRAMFILES",
  "COMMONPROGRAMFILES(X86)",
  "COMMONPROGRAMW6432",
  -- locale, terminal, time
  "LANG",
  "LANGUAGE",
  "LC_ALL",
  "TZ",
  "TERM",
  "COLORTERM",
  "NO_COLOR",
  "FORCE_COLOR",
  "CLICOLOR_FORCE",
  -- the editor's own runtime (a non-standard install)
  "VIM",
  "VIMRUNTIME",
  -- specs that behave differently on CI read these; neither is a secret
  "CI",
  "GITHUB_ACTIONS",
  -- display (a spec that opens a GUI helper)
  "DISPLAY",
  "WAYLAND_DISPLAY",
}

---Prefixes allowed as a whole (`LC_*`).
---@type string[]
M.ALLOW_PREFIX = { "LC_" }

---Never passed on, whatever the project asks for: they point at the editor that runs the tests.
---@param name string
---@return boolean
function M.is_denied(name)
  return name:upper():sub(1, 4) == "NVIM"
end

---@type table<string, true>
local ALLOW_SET = {}
for _, n in ipairs(M.ALLOW) do
  ALLOW_SET[n] = true
end

---Is `name` acceptable as an `env_allow` entry? (`LUA_*`, `MY_TOKEN_FOR_SPECS`.)
---@param entry any
---@return boolean ok
---@return string|nil why
function M.check_entry(entry)
  if type(entry) ~= "string" or entry == "" then
    return false, "not a non-empty string"
  end
  if entry == "*" then
    return false, "a bare '*' would pass the whole environment on"
  end
  if not entry:match("^[%w_%(%)%.%-]+%*?$") then
    return false, "letters, digits and _ ( ) . - only, optionally ending in '*'"
  end
  if M.is_denied(entry) then
    return false, "names starting with NVIM point at the parent editor and are never passed on"
  end
  return true, nil
end

---@class Testing.Child.EnvResult
---@field env table<string, string> The environment to start the child with.
---@field dropped string[] Names of the parent's environment that were NOT passed on (sorted).

---Build the child's base environment.
---@param parent table<string, string> The parent's environment (`vim.fn.environ()`).
---@param opts? { allow?: string[] } `allow`: extra names / `PREFIX*` patterns from the project.
---@return Testing.Child.EnvResult
function M.sanitize(parent, opts)
  opts = opts or {}
  local extra_exact, extra_prefix = {}, {}
  for _, entry in ipairs(opts.allow or {}) do
    if M.check_entry(entry) then
      if entry:sub(-1) == "*" then
        extra_prefix[#extra_prefix + 1] = entry:sub(1, -2):upper()
      else
        extra_exact[entry:upper()] = true
      end
    end
  end
  local env, dropped = {}, {}
  local names = vim.tbl_keys(parent)
  table.sort(names)
  for _, name in ipairs(names) do
    local up = name:upper()
    local ok = false
    if not M.is_denied(name) then
      ok = ALLOW_SET[up] == true or extra_exact[up] == true
      if not ok then
        for _, p in ipairs(M.ALLOW_PREFIX) do
          if up:sub(1, #p) == p then
            ok = true
          end
        end
      end
      if not ok then
        for _, p in ipairs(extra_prefix) do
          if up:sub(1, #p) == p then
            ok = true
          end
        end
      end
    end
    if ok and type(parent[name]) == "string" then
      env[name] = parent[name]
    else
      dropped[#dropped + 1] = name
    end
  end
  return { env = env, dropped = dropped }
end

---Determinism variables a child gets instead of the parent's locale and time zone: a spec that
---formats a date, sorts, or compares a message must not depend on the machine it runs on (`de_AT`
---on the author's workstation, `UTC` + `C.UTF-8` on CI). The parent's `LANG`, `LANGUAGE`, `LC_*` and
---`TZ` are NOT passed on; these three are SET. Opt out with `deterministic = false` (a spec that
---needs the machine's own locale).
---@type table<string, string>
M.DETERMINISTIC = { LANG = "C.UTF-8", LC_ALL = "C.UTF-8", TZ = "UTC" }

---Replace the locale and time zone variables of `env` (in place) by `M.DETERMINISTIC`. Names are
---matched case-insensitively (`Tz` on Windows); `LANGUAGE` and every other `LC_*` are removed:
---`LC_ALL` would win over them anyway, and a stray `LANGUAGE=de` still changes gettext messages.
---@param env table<string, string>
---@return table<string, string> env The same table.
function M.apply_determinism(env)
  for name in pairs(env) do
    local up = name:upper()
    if up == "LANG" or up == "LANGUAGE" or up == "TZ" or up:sub(1, 3) == "LC_" then
      env[name] = nil
    end
  end
  for name, value in pairs(M.DETERMINISTIC) do
    env[name] = value
  end
  return env
end

---The directories of a child's sandbox, below `base`, and the environment variables that point
---Neovim (and tools that honour the XDG variables) and the temp lookups at them.
---@param base string Absolute directory that belongs to this child (it is created by the caller).
---@return table<string, string> dirs name -> absolute path (`config`, `data`, `state`, `cache`, `run`, `tmp`)
---@return table<string, string> env variables to set
function M.sandbox_env(base)
  base = base:gsub("\\", "/"):gsub("/+$", "")
  local dirs = {
    config = base .. "/config",
    data = base .. "/data",
    state = base .. "/state",
    cache = base .. "/cache",
    run = base .. "/run",
    tmp = base .. "/tmp",
  }
  local env = {
    XDG_CONFIG_HOME = dirs.config,
    XDG_DATA_HOME = dirs.data,
    XDG_STATE_HOME = dirs.state,
    XDG_CACHE_HOME = dirs.cache,
    XDG_RUNTIME_DIR = dirs.run,
    TEMP = dirs.tmp,
    TMP = dirs.tmp,
    TMPDIR = dirs.tmp,
  }
  return dirs, env
end

return M
