---@module 'testing.guard.config'
---@brief Defaults, merge and validation of the guard configuration (pure; no editor access).
---@description
--- `normalize(cfg)` deep-merges a user table over `DEFAULTS` and reports every problem it finds in
--- one list (a typo in a guard name or a mode must not silently switch a safety net off).
---
--- A guard section is either a table or a bare mode string (`fs = "off"`). Modes:
---   * `off`   the guard is not installed at all (no patch, no overhead);
---   * `warn`  findings are reported with severity `warn` (the run stays green);
---   * `error` findings are reported with severity `error` (the case fails);
---   * `info`  (state categories only) listed, never failing, never promoted.
--- `strict = true` promotes every `warn` to `error` (the later `--strict` flag).

local M = {}

---Install order (a guard that observes errors comes first, the snapshot guards last).
---@type string[]
M.ORDER = { "scheduled_error", "prompt", "deprecation", "process_net", "fs", "state", "clock" }

M.MODES = { off = true, warn = true, error = true }

---@type table
M.DEFAULTS = {
  strict = false,
  -- `vim.wait(settle_ms)` before the checks, so pending `vim.schedule` callbacks have run.
  settle_ms = 0,
  max_findings = 500,
  -- Soft isolation (state guard): `false`, `true` (all restorable categories) or a list of them.
  restore = false,
  ledger = { max_entries = 200, max_text = 300 },
  guards = {
    fs = {
      mode = "error",
      -- Raise instead of only observing (default: observe, the spec's write still happens).
      block = false,
      -- Extra directories (prefix match on resolved paths) and Lua patterns (on the resolved
      -- path, forward slashes) a spec may write to: sessions, cmdlog, calibration files, ...
      allow = {},
      allow_patterns = {},
      -- Roots of the before/after snapshot; default: the cwd and the repo root (plus the stdpath
      -- directories with `watch_stdpath`). `watch_extra` adds to the default.
      watch = nil,
      watch_extra = {},
      -- Also walk the real stdpath config/data/state/cache trees (off: a developer machine's trees
      -- are huge, the walk costs seconds per file and is cut at `max_files`).
      watch_stdpath = false,
      -- Snapshot: directory names and patterns (on the file name) that are never looked at.
      ignore = { ".git", ".deps", "node_modules", ".testing" },
      ignore_patterns = { "%.log$", "%.swp$", "%.shada$" },
      snapshot = true,
      max_files = 5000,
      max_depth = 12,
    },
    state = {
      mode = "error",
      -- Per category: `error` | `warn` | `info` | `off`.
      categories = {
        autocmds = "error",
        usercmds = "error",
        keymaps = "error",
        buffers = "error",
        windows = "error",
        tabs = "error",
        cwd = "error",
        rtp = "error",
        options = "warn",
        vars = "warn",
        env = "warn",
        highlights = "warn",
        lua_globals = "warn",
        preload = "warn",
        channels = "warn",
        modules = "info",
      },
      -- Autocmd groups the guard itself or the harness owns, and the editor's own lazily created
      -- ones (`nvim.diagnostic.buf_wipeout`, ...; prefix match).
      ignore_groups = { "testing.guard", "testing_guard", "nvim." },
      -- `g:loaded_<name>_provider` is the editor's own flag that a provider ran its autoload once.
      ignore_vars = {
        "loaded_clipboard_provider",
        "loaded_node_provider",
        "loaded_perl_provider",
        "loaded_python_provider",
        "loaded_python3_provider",
        "loaded_ruby_provider",
      },
      ignore_options = {},
      ignore_env = {},
      ignore_globals = {},
      ignore_highlights = {},
      -- User command names and keymap left-hand sides (prefix match) a plugin's `setup()` leaves on purpose.
      ignore_usercmds = {},
      ignore_keymaps = {},
      -- At most this many named findings per category and case; the rest is summarized.
      max_per_category = 20,
      max_buffers_scanned = 50,
    },
    scheduled_error = {
      mode = "error",
      -- Lua patterns on the message: a spec that provokes an error on purpose lists it here.
      allow_patterns = {},
      -- Severity of `vim.notify(msg, ERROR)` calls during a case: `info` (listed only) by default,
      -- because plugins report expected user errors that way.
      notify = "info",
    },
    prompt = {
      mode = "error",
      -- A blocking `getchar()` / `getcharstr()` with no key typed ahead waits this long (ms, the event
      -- loop runs) for the spec to feed one, e.g. from a timer; then it is refused. 0: refuse at once.
      getchar_wait_ms = 300,
    },
    deprecation = { mode = "warn" },
    process_net = {
      mode = "error",
      -- Executables (basename, `.exe` ignored) and hosts a case may use without a tag. Still logged.
      allow_exec = {},
      allow_hosts = {},
    },
    clock = { mode = "off", seed = nil },
  },
}

---@param t any
---@return boolean
local function is_list(t)
  return type(t) == "table" and vim.islist(t)
end

---@param over any
---@param base table
---@return table
local function merge(base, over)
  return vim.tbl_deep_extend("force", base, over)
end

---Merge `cfg` over the defaults and validate it.
---@param cfg? table
---@return table cfg
---@return string[] problems
function M.normalize(cfg)
  local problems = {}
  cfg = cfg or {}
  if type(cfg) ~= "table" then
    return vim.deepcopy(M.DEFAULTS), { "config must be a table" }
  end
  local over = vim.deepcopy(cfg)
  -- bare mode strings -> { mode = ... }
  local gs = over.guards
  if gs ~= nil and type(gs) ~= "table" then
    problems[#problems + 1] = "guards must be a table"
    over.guards = nil
  elseif gs then
    for name, sec in pairs(gs) do
      if M.DEFAULTS.guards[name] == nil then
        problems[#problems + 1] = ("guards.%s: unknown guard (known: %s)"):format(
          tostring(name),
          table.concat(M.ORDER, ", ")
        )
        gs[name] = nil
      elseif type(sec) == "string" then
        gs[name] = { mode = sec }
      elseif sec == false then
        gs[name] = { mode = "off" }
      elseif type(sec) ~= "table" then
        problems[#problems + 1] = ("guards.%s: must be a table or a mode string"):format(name)
        gs[name] = nil
      end
    end
  end
  local out = merge(M.DEFAULTS, over)
  for _, name in ipairs(M.ORDER) do
    local sec = out.guards[name]
    if not M.MODES[sec.mode] then
      problems[#problems + 1] = ("guards.%s.mode: %q is not one of off|warn|error"):format(
        name,
        tostring(sec.mode)
      )
      sec.mode = M.DEFAULTS.guards[name].mode
    end
    for _, key in ipairs({
      "allow",
      "allow_patterns",
      "allow_exec",
      "allow_hosts",
      "ignore",
      "ignore_patterns",
      "ignore_groups",
      "ignore_vars",
      "ignore_options",
      "ignore_env",
      "ignore_globals",
      "ignore_highlights",
      "ignore_usercmds",
      "ignore_keymaps",
    }) do
      if
        sec[key] ~= nil
        and not is_list(sec[key])
        and not (type(sec[key]) == "table" and next(sec[key]) == nil)
      then
        problems[#problems + 1] = ("guards.%s.%s: must be a list of strings"):format(name, key)
        sec[key] = {}
      end
    end
  end
  local cats = out.guards.state.categories
  for cat, mode in pairs(cats) do
    if M.DEFAULTS.guards.state.categories[cat] == nil then
      problems[#problems + 1] = ("guards.state.categories.%s: unknown category"):format(cat)
      cats[cat] = nil
    elseif mode ~= "error" and mode ~= "warn" and mode ~= "info" and mode ~= "off" then
      problems[#problems + 1] = ("guards.state.categories.%s: %q is not one of error|warn|info|off"):format(
        cat,
        tostring(mode)
      )
      cats[cat] = M.DEFAULTS.guards.state.categories[cat]
    end
  end
  local nmode = out.guards.scheduled_error.notify
  if nmode ~= "error" and nmode ~= "warn" and nmode ~= "info" and nmode ~= "off" then
    problems[#problems + 1] = "guards.scheduled_error.notify: must be error|warn|info|off"
    out.guards.scheduled_error.notify = "info"
  end
  if type(out.settle_ms) ~= "number" or out.settle_ms < 0 then
    problems[#problems + 1] = "settle_ms must be a number >= 0"
    out.settle_ms = 0
  end
  if out.restore ~= false and out.restore ~= true and not is_list(out.restore) then
    problems[#problems + 1] = "restore must be false, true or a list of category names"
    out.restore = false
  end
  return out, problems
end

return M
