---@module 'testing.args'
---@brief Argument parser of the command line: `testing [run|init|list|doctor] [<root>] [options]`.
---@description
--- Pure: reads only the list it is given (the caller passes `_G.arg`, which `nvim -l` fills with
--- everything after the script), never executes or `eval`s any of it, never touches the editor or
--- the filesystem (SEC-34/35: no `-c` strings with user text, nothing is interpreted as code).
---
--- Grammar (GNU style):
---   * subcommand: the FIRST argument, when it is exactly `run`, `init`, `list` or `doctor`
---     (default `run`). Any other first argument is the project root as before; a directory that is
---     called `list` is spelled `./list` or `--root list`.
---   * long options take their value as `--name value` or `--name=value`; the value of the
---     space form is the next argument verbatim, except that it must not start with `--`
---     (spell `--name=--x` for that). An empty value is an error.
---   * `--` ends the options; the rest are positionals.
---   * short options: `-h`, `-x` (no clustering).
---   * repeatable options accumulate (`--rtp a --rtp b`); a repeated scalar option is last-wins.
---   * positionals: the first is the project root (unless `--root` is given), the rest are `paths`.
---   * everything unknown is a usage error (the caller maps it to exit code 2 and prints `USAGE`).
---
--- The parser only parses and validates; what a flag does is wired by the caller (`testing.cli`).
--- `Args.given` records which options the user passed (canonical names), so the caller can refuse
--- an option it does not implement yet instead of silently ignoring it.

local M = {}

---@type string[]
M.SUBCOMMANDS = { "run", "init", "list", "doctor" }

---Reporter names `--reporter` accepts; the reporter implementation extends this list.
---@type string[]
M.REPORTERS = { "term", "github", "junit", "json" }

---@class Testing.Args
---@field command "run"|"init"|"list"|"doctor"
---@field help boolean `-h`/`--help`
---@field root? string Project root (`--root` or the first positional).
---@field paths string[] Positionals after the root.
---@field config? string `--config <file>`
---@field json? string `--json <file>`
---@field junit? string `--junit <file>`
---@field github boolean `--github`
---@field reporter? string `--reporter <name>` (one of `REPORTERS`)
---@field filter string[] `--filter <text>`: literal substring of the case name (SEC-30), repeatable
---@field file string[] `--file <text>`/`--only <text>`: substring of the spec FILE NAME, repeatable
---@field tags string[] `--tags a,b`
---@field exclude_tags string[] `--exclude-tags a,b`
---@field lf boolean `--lf`: last failed
---@field ff boolean `--ff`: failed first
---@field maxfail? integer `-x` (1) or `--maxfail N`
---@field shuffle boolean `--shuffle`
---@field seed? integer `--seed N` (needs `--shuffle`)
---@field durations? integer `--durations N`
---@field list boolean `--list`/`--dry-run` (and the `list` subcommand)
---@field strict boolean `--strict`
---@field rtp string[] `--rtp <dir>`, repeatable
---@field case_timeout_ms? integer `--case-timeout <ms>`
---@field file_timeout_ms? integer `--file-timeout <ms>`
---@field sentinel? string `--sentinel <name>` (transitional: last line of a green run)
---@field isolated? "none"|"file"|"case"|"soft" `--isolated none|file|case|soft`: a child editor per spec file / per case, or this editor with a restore between files
---@field guard string[] `--guard <name>=<mode>`, repeatable (validated by `check_guard`)
---@field allow_fs string[] `--allow-fs <path>`, repeatable
---@field allow_spawn string[] `--allow-spawn <exe>`, repeatable
---@field allow_network string[] `--allow-network <host>`, repeatable
---@field pool_size? integer `--pool-size <n>`
---@field pool_reuse? boolean `--pool-reuse` (true) / `--no-pool-reuse` (false); nil = the config decides
---@field determinism? boolean `--no-determinism` (false); nil = the config decides
---@field trace? boolean `--no-trace` (false); nil = the config decides
---@field jobs? integer `--jobs <n>`: children running at once (isolated runs)
---@field host? "c"|"l" `--host c|l`: how a child starts (`c` = plenary-like `-c`, `l` = `nvim -l`)
---@field env_allow string[] `--env-allow <name>`, repeatable: environment names a child may inherit
---@field first_run boolean `--first-run`: do not disable lib.nvim's first-run float (default false)
---@field timings boolean false after `--no-timings`
---@field given table<string, boolean> Canonical names (`json`, `maxfail`, ...) of the options the user passed.

---@class Testing.Args.Option
---@field name string Canonical name (no dashes, underscores): the key in `Args.given`.
---@field long? string Long spelling without the dashes.
---@field short? string Short spelling without the dash.
---@field kind "flag"|"value"|"list"|"csv"|"int"
---@field field string Field of `Testing.Args` that receives the value.
---@field const? any Value a `flag` stores (default true).
---@field arg? string Placeholder for the usage text.
---@field min? integer Lower bound of an `int`.
---@field check? fun(v: string): string|nil Returns a problem text for an invalid value.
---@field help string

---The option table drives both the parser and the usage text.
---@type Testing.Args.Option[]
local OPTIONS = {
  { name = "help", long = "help", short = "h", kind = "flag", field = "help", help = "this text" },
  {
    name = "root",
    long = "root",
    kind = "value",
    field = "root",
    arg = "<dir>",
    help = "project root (default: the first positional)",
  },
  {
    name = "config",
    long = "config",
    kind = "value",
    field = "config",
    arg = "<file>",
    help = "configuration file inside the root (default: <root>/.testing.lua)",
  },
  {
    name = "json",
    long = "json",
    kind = "value",
    field = "json",
    arg = "<file>",
    help = "write the Result-IR (schema_version 1) to <file>",
  },
  {
    name = "junit",
    long = "junit",
    kind = "value",
    field = "junit",
    arg = "<file>",
    help = "write a JUnit XML report to <file>",
  },
  {
    name = "github",
    long = "github",
    kind = "flag",
    field = "github",
    help = "emit GitHub Actions annotations and the step summary",
  },
  {
    name = "reporter",
    long = "reporter",
    kind = "value",
    field = "reporter",
    arg = "<name>",
    help = "terminal reporter",
    check = function(v)
      for _, r in ipairs(M.REPORTERS) do
        if r == v then
          return nil
        end
      end
      return ("unknown reporter '%s' (one of: %s)"):format(v, table.concat(M.REPORTERS, ", "))
    end,
  },
  {
    name = "filter",
    long = "filter",
    kind = "list",
    field = "filter",
    arg = "<text>",
    help = "only cases whose name contains <text> (literal, not a pattern); repeatable",
  },
  {
    name = "file",
    long = "file",
    kind = "list",
    field = "file",
    arg = "<text>",
    help = "only spec files whose FILE NAME contains <text>; repeatable",
  },
  {
    name = "file",
    long = "only",
    kind = "list",
    field = "file",
    arg = "<text>",
    help = "alias of --file",
  },
  {
    name = "tags",
    long = "tags",
    kind = "csv",
    field = "tags",
    arg = "<a,b>",
    help = "only cases with one of these tags; repeatable",
  },
  {
    name = "exclude_tags",
    long = "exclude-tags",
    kind = "csv",
    field = "exclude_tags",
    arg = "<a,b>",
    help = "skip cases with one of these tags; repeatable",
  },
  { name = "lf", long = "lf", kind = "flag", field = "lf", help = "only what failed last time" },
  { name = "ff", long = "ff", kind = "flag", field = "ff", help = "what failed last time first" },
  {
    name = "maxfail",
    short = "x",
    kind = "flag",
    field = "maxfail",
    const = 1,
    help = "stop after the first failure (= --maxfail 1)",
  },
  {
    name = "maxfail",
    long = "maxfail",
    kind = "int",
    field = "maxfail",
    arg = "<n>",
    min = 1,
    help = "stop after <n> failures",
  },
  {
    name = "shuffle",
    long = "shuffle",
    kind = "flag",
    field = "shuffle",
    help = "run in random order (the seed is reported)",
  },
  {
    name = "seed",
    long = "seed",
    kind = "int",
    field = "seed",
    arg = "<n>",
    min = 0,
    help = "seed of --shuffle",
  },
  {
    name = "durations",
    long = "durations",
    kind = "int",
    field = "durations",
    arg = "<n>",
    min = 0,
    help = "name the <n> slowest cases (0 = all)",
  },
  {
    name = "list",
    long = "list",
    kind = "flag",
    field = "list",
    help = "list what would run, run nothing",
  },
  { name = "list", long = "dry-run", kind = "flag", field = "list", help = "alias of --list" },
  {
    name = "strict",
    long = "strict",
    kind = "flag",
    field = "strict",
    help = "warnings (deprecations, ...) fail the run",
  },
  {
    name = "rtp",
    long = "rtp",
    kind = "list",
    field = "rtp",
    arg = "<dir>",
    help = "add <dir> to the runtimepath; repeatable",
  },
  {
    name = "case_timeout",
    long = "case-timeout",
    kind = "int",
    field = "case_timeout_ms",
    arg = "<ms>",
    min = 1,
    help = "hard timeout of one case",
  },
  {
    name = "file_timeout",
    long = "file-timeout",
    kind = "int",
    field = "file_timeout_ms",
    arg = "<ms>",
    min = 1,
    help = "hard timeout of one spec file",
  },
  {
    name = "sentinel",
    long = "sentinel",
    kind = "value",
    field = "sentinel",
    arg = "<name>",
    help = "last line of a fully green run (default: taken from <root>/TESTS/run.lua)",
  },
  {
    name = "isolated",
    long = "isolated",
    kind = "value",
    field = "isolated",
    arg = "<none|file|case|soft>",
    help = "file: a child editor per spec file (default for busted files); case: a child per CASE (busted; slow, exact); soft: this editor, state restored between files",
    check = function(v)
      if v == "none" or v == "file" or v == "case" or v == "soft" then
        return nil
      end
      return ("--isolated must be 'none', 'file', 'case' or 'soft', got '%s'"):format(v)
    end,
  },
  {
    name = "guard",
    long = "guard",
    kind = "list",
    field = "guard",
    arg = "<name>=<mode>",
    help = "set a guard (fs, state, scheduled_error, prompt, deprecation, process_net: off|warn|error; clock: on|off); repeatable",
    check = function(v)
      return M.check_guard(v)
    end,
  },
  {
    name = "allow_fs",
    long = "allow-fs",
    kind = "list",
    field = "allow_fs",
    arg = "<path>",
    help = "the fs guard lets writes below <path> through; repeatable",
    check = function(v)
      return M.check_allow("--allow-fs", v)
    end,
  },
  {
    name = "allow_spawn",
    long = "allow-spawn",
    kind = "list",
    field = "allow_spawn",
    arg = "<exe>",
    help = "the process guard lets <exe> be started; repeatable",
    check = function(v)
      return M.check_allow("--allow-spawn", v)
    end,
  },
  {
    name = "allow_network",
    long = "allow-network",
    kind = "list",
    field = "allow_network",
    arg = "<host>",
    help = "the network guard lets connections to <host> through; repeatable",
    check = function(v)
      return M.check_allow("--allow-network", v)
    end,
  },
  {
    name = "pool_size",
    long = "pool-size",
    kind = "int",
    field = "pool_size",
    arg = "<n>",
    min = 0,
    help = "children the warm pool keeps (0 = --jobs)",
  },
  {
    name = "pool_reuse",
    long = "pool-reuse",
    kind = "flag",
    field = "pool_reuse",
    const = true,
    help = "reset and reuse a child between files instead of respawning it",
  },
  {
    name = "pool_reuse",
    long = "no-pool-reuse",
    kind = "flag",
    field = "pool_reuse",
    const = false,
    help = "respawn a child for every file (the default)",
  },
  {
    name = "determinism",
    long = "no-determinism",
    kind = "flag",
    field = "determinism",
    const = false,
    help = "children keep the parent's LANG/LC_ALL/TZ instead of fixed ones",
  },
  {
    name = "trace",
    long = "no-trace",
    kind = "flag",
    field = "trace",
    const = false,
    help = "no trace artifact for a child that times out or crashes",
  },
  {
    name = "jobs",
    long = "jobs",
    kind = "int",
    field = "jobs",
    arg = "<n>",
    min = 1,
    help = "child editors running at once (isolated runs; default 1)",
  },
  {
    name = "host",
    long = "host",
    kind = "value",
    field = "host",
    arg = "<c|l>",
    help = "how a child starts: c = like plenary's host (default), l = nvim -l",
    check = function(v)
      if v == "c" or v == "l" then
        return nil
      end
      return ("--host must be 'c' or 'l', got '%s'"):format(v)
    end,
  },
  {
    name = "env_allow",
    long = "env-allow",
    kind = "list",
    field = "env_allow",
    arg = "<name>",
    help = "environment variable (or PREFIX*) a child may inherit; repeatable",
    check = function(v)
      local ok, why = require("testing.child.env").check_entry(v)
      if ok then
        return nil
      end
      return ("--env-allow '%s': %s"):format(v, why)
    end,
  },
  {
    name = "first_run",
    long = "first-run",
    kind = "flag",
    field = "first_run",
    const = true,
    help = "keep lib.nvim's one-time first-run float enabled (a suite that tests it, such as lib.nvim's own)",
  },
  {
    name = "timings",
    long = "no-timings",
    kind = "flag",
    field = "timings",
    const = false,
    help = "do not print the timing line",
  },
}

---Guards that `--guard <name>=<mode>` names (underscores or dashes).
---@type string[]
M.GUARD_NAMES =
  { "fs", "state", "scheduled_error", "prompt", "deprecation", "process_net", "clock" }

---@param v string
---@return string|nil problem
function M.check_guard(v)
  local name, mode = v:match("^([%w_%-]+)=([%w]+)$")
  if not name then
    return ("--guard '%s': expected <name>=<mode>, e.g. fs=error"):format(v)
  end
  name = name:gsub("%-", "_")
  if not vim.tbl_contains(M.GUARD_NAMES, name) then
    return ("--guard: unknown guard '%s' (one of: %s)"):format(
      name,
      table.concat(M.GUARD_NAMES, ", ")
    )
  end
  if name == "clock" then
    if mode ~= "on" and mode ~= "off" then
      return ("--guard clock: the mode is 'on' or 'off', got '%s'"):format(mode)
    end
  elseif mode ~= "off" and mode ~= "warn" and mode ~= "error" then
    return ("--guard %s: the mode is 'off', 'warn' or 'error', got '%s'"):format(name, mode)
  end
  return nil
end

---@param flag string
---@param v string
---@return string|nil problem
function M.check_allow(flag, v)
  if #v > 400 or v:find("%c") then
    return ("%s: not a valid value (too long or control characters)"):format(flag)
  end
  return nil
end

---@type table<string, Testing.Args.Option>
local BY_LONG, BY_SHORT = {}, {}
for _, o in ipairs(OPTIONS) do
  if o.long then
    BY_LONG[o.long] = o
  end
  if o.short then
    BY_SHORT[o.short] = o
  end
end

---Usage text, built from the option table so that it cannot drift from the parser.
---@return string
function M.usage()
  local lines = {
    "usage: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua [run|init|list|doctor] [<root>] [options]",
    "       nvim -n -i NONE --headless -u NONE -l scripts/testing.lua migrate [dry-run|apply] [<path>] [--json|--markdown] [--check] [--fleet-root=<dir>]",
    "",
    "  run      run the spec files of <root> (default)",
    "  list     list what would run (= run --list)",
    "  doctor   print the resolved configuration and the dependency report",
    "  init     scaffold .testing.lua, TESTS/minimal_init.lua, scripts/test.sh, a CI job",
    "  migrate  plan (or write) the move of a repository from plenary / busted / its own runner to testing.nvim",
    "",
    "  <root>   project root; further positionals are paths below it",
  }
  for _, o in ipairs(OPTIONS) do
    local spelled = {}
    if o.short then
      spelled[#spelled + 1] = "-" .. o.short
    end
    if o.long then
      spelled[#spelled + 1] = "--" .. o.long
    end
    local left = table.concat(spelled, ", ") .. (o.arg and (" " .. o.arg) or "")
    lines[#lines + 1] = ("  %-24s %s"):format(left, o.help)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "exit: 0 green, 1 failures, 2 usage/config error, 3 infrastructure error"
  return table.concat(lines, "\n")
end

---@return Testing.Args
local function new_args()
  return {
    command = "run",
    help = false,
    paths = {},
    github = false,
    filter = {},
    file = {},
    tags = {},
    exclude_tags = {},
    lf = false,
    ff = false,
    shuffle = false,
    list = false,
    strict = false,
    rtp = {},
    env_allow = {},
    guard = {},
    allow_fs = {},
    allow_spawn = {},
    allow_network = {},
    first_run = false,
    timings = true,
    given = {},
  }
end

---Parse a non-negative decimal integer, nothing else (no hex, no exponent, no sign).
---@param v string
---@return integer|nil
local function parse_uint(v)
  if v:match("^%d+$") and #v <= 15 then
    return tonumber(v)
  end
  return nil
end

---Apply one option with its (already extracted) value; returns a problem text or nil.
---@param args Testing.Args
---@param o Testing.Args.Option
---@param spelled string The spelling the user typed, for messages.
---@param value string|nil
---@return string|nil
local function apply(args, o, spelled, value)
  if o.kind == "flag" then
    if value ~= nil then
      return ("option %s takes no value"):format(spelled)
    end
    if o.const == nil then
      args[o.field] = true
    else
      args[o.field] = o.const
    end
  else
    if value == nil or value == "" then
      return ("option %s needs a value"):format(spelled)
    end
    if o.check then
      local why = o.check(value)
      if why then
        return why
      end
    end
    if o.kind == "value" then
      args[o.field] = value
    elseif o.kind == "list" then
      local list = args[o.field]
      list[#list + 1] = value
    elseif o.kind == "csv" then
      local list = args[o.field]
      for item in value:gmatch("[^,]+") do
        item = vim.trim(item)
        if item ~= "" then
          if not item:match("^[%w_.:%-]+$") then
            return ("option %s: invalid tag '%s' (letters, digits and _ . : - only)"):format(
              spelled,
              item
            )
          end
          list[#list + 1] = item
        end
      end
    elseif o.kind == "int" then
      local n = parse_uint(value)
      if n == nil or n < (o.min or 0) then
        return ("option %s needs an integer >= %d, got '%s'"):format(spelled, o.min or 0, value)
      end
      args[o.field] = n
    end
  end
  args.given[o.name] = true
  return nil
end

---Parse the arguments. Returns nil and a message on a usage error.
---@param argv string[]
---@return Testing.Args|nil
---@return string|nil problem
function M.parse(argv)
  local args = new_args()
  local i, n = 1, #argv
  local positionals = {}

  if n >= 1 then
    for _, name in ipairs(M.SUBCOMMANDS) do
      if argv[1] == name then
        args.command = name --[[@as "run"|"init"|"list"|"doctor"]]
        i = 2
        break
      end
    end
  end

  local options_done = false
  while i <= n do
    local a = tostring(argv[i])
    if options_done or a == "-" or a:sub(1, 1) ~= "-" then
      positionals[#positionals + 1] = a
    elseif a == "--" then
      options_done = true
    elseif a:sub(1, 2) == "--" then
      local name, inline = a:match("^%-%-([^=]+)=(.*)$")
      if not name then
        name = a:sub(3)
      end
      local o = BY_LONG[name]
      if not o then
        return nil, ("unknown option %s"):format(a)
      end
      local value = inline
      if value == nil and o.kind ~= "flag" then
        local nxt = argv[i + 1]
        if nxt ~= nil and tostring(nxt):sub(1, 2) ~= "--" then
          value = tostring(nxt)
          i = i + 1
        end
      end
      local problem = apply(args, o, "--" .. name, value)
      if problem then
        return nil, problem
      end
    else
      local o = BY_SHORT[a:sub(2)]
      if not o then
        return nil, ("unknown option %s"):format(a)
      end
      local problem = apply(args, o, a, nil)
      if problem then
        return nil, problem
      end
    end
    i = i + 1
  end

  if args.help then
    return args, nil
  end

  if args.root == nil then
    args.root = table.remove(positionals, 1)
  end
  args.paths = positionals

  if args.lf and args.ff then
    return nil, "--lf and --ff exclude each other"
  end
  if args.seed ~= nil and not args.shuffle then
    return nil, "--seed needs --shuffle"
  end
  if args.command == "list" then
    args.list = true
  end
  return args, nil
end

return M
