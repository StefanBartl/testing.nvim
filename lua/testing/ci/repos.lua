---@module 'testing.ci.repos'
---@brief `testing ci --repos ...`: the pipeline of several repositories, one after the other, `verify` first.
---@description
--- ```
--- testing ci --repos=<a,b> | --repos-root=<dir> | --repos-file=<list>   which repositories
---            [--repos-include=<names>] [--repos-exclude=<names>] [--refresh]
---            [--force] [--jobs=<n>] [--profile=<name>] [--keep-going] [--reuse] [--state-dir=<dir>]
--- ```
---
--- Each repository is a child process of its own (`testing ci verify`, then `testing ci` when the state is not already
--- proven): the pipelines of different repositories never share a Neovim, a global or a working directory. Output is
--- streamed line by line, each line prefixed with the repository's name. At the end one row per repository; the exit
--- code is the worst single result (0 green or proven, 1 red, 2 a usage or pipeline error, 3 infrastructure).
---
--- Which repositories: an explicit list (`--repos`, `--repos-file`) or every directory directly below a root
--- (`--repos-root`, repeatable; the `ci.repos.roots` setting of the editor) whose `.testing.lua` has a `ci` section.
--- That detection is textual (the file is not executed here) and cached in the state directory; `--refresh` rebuilds it.

local M = {}

M.EXIT_OK, M.EXIT_RED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

M.SCHEMA = "testing-ci-repos/1"

M.USAGE = table.concat({
  "usage: testing ci --repos=<a,b> | --repos-root=<dir> | --repos-file=<list> [options]",
  "  --repos=<a,b>           repository directories (comma separated; relative to the current directory)",
  "  --repos-root=<dir>      every directory below <dir> whose .testing.lua has a ci section (repeatable)",
  "  --repos-file=<list>     one repository directory per line (blank lines and # comments are ignored)",
  "  --repos-include=<names> of the found ones only these (by directory name)",
  "  --repos-exclude=<names> leave these out (by directory name)",
  "  --refresh               rebuild the cached detection of --repos-root",
  "  --force                 run even a repository whose state is already proven (skip `ci verify`)",
  "  --jobs=<n>              repositories at the same time (default 1)",
  "  --profile=<name>        the profile of every repository (default: its ci.default)",
  "  --keep-going            run every step of a repository even after a red one",
  "  --reuse                 skip a suite whose stamp still verifies",
  "  --state-dir=<dir>       the state directory of the children and of the cache",
}, "\n")

---@class Testing.Ci.Repos.Args
---@field repos string[]
---@field roots string[]
---@field file? string
---@field include string[]
---@field exclude string[]
---@field refresh boolean
---@field force boolean
---@field jobs integer
---@field profile? string
---@field keep_going boolean
---@field reuse boolean
---@field state_dir? string
---@field help boolean

local VALUED = {
  repos = true,
  ["repos-root"] = true,
  ["repos-file"] = true,
  ["repos-include"] = true,
  ["repos-exclude"] = true,
  jobs = true,
  profile = true,
  ["state-dir"] = true,
}

---@param text string
---@return string[]
local function csv(text)
  return vim.split(text, ",", { plain = true, trimempty = true })
end

---Does an argument list ask for the multi-repository run?
---@param argv string[]
---@return boolean
function M.wanted(argv)
  for _, a in ipairs(argv) do
    if a == "--" then
      return false
    end
    if a:match("^%-%-repos") then
      return true
    end
  end
  return false
end

---@param argv string[]
---@return Testing.Ci.Repos.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Repos.Args
  local args = {
    repos = {},
    roots = {},
    include = {},
    exclude = {},
    refresh = false,
    force = false,
    jobs = 1,
    keep_going = false,
    reuse = false,
    help = false,
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif
      (key == "refresh" or key == "force" or key == "keep-going" or key == "reuse")
      and value == nil
    then
      args[key == "keep-going" and "keep_going" or key] = true
    elseif key and VALUED[key] then
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "repos" then
        vim.list_extend(args.repos, csv(value))
      elseif key == "repos-root" then
        args.roots[#args.roots + 1] = value
      elseif key == "repos-file" then
        args.file = value
      elseif key == "repos-include" then
        vim.list_extend(args.include, csv(value))
      elseif key == "repos-exclude" then
        vim.list_extend(args.exclude, csv(value))
      elseif key == "jobs" then
        local n = tonumber(value)
        if not n or n < 1 or n > 16 or n ~= math.floor(n) then
          return nil, "--jobs must be a whole number from 1 to 16"
        end
        args.jobs = n
      elseif key == "state-dir" then
        args.state_dir = value
      else
        args[key] = value
      end
    else
      return nil, ("unknown argument %s"):format(a)
    end
    i = i + 1
  end
  return args
end

---@param dir string
---@return string
local function norm(dir)
  -- normalize first: it expands `$VAR` and `~`, which `:p` would take for file names
  return (vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")):gsub("/+$", ""))
end

---Split Lua source into words, strings and single punctuation characters; comments (line and block) are dropped and
---strings are kept whole, so a `--` or a `ci =` inside a string is neither a comment nor a key.
---@param text string
---@return { [1]: "id"|"str"|"p", [2]: string }[]
local function tokens(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif text:sub(i, i + 1) == "--" then
      local eq = text:match("^%-%-%[(=*)%[", i)
      if eq then
        local _, e = text:find("]" .. eq .. "]", i, true)
        i = (e or n) + 1
      else
        i = (text:find("\n", i, true) or n) + 1
      end
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = { "str", text:sub(i + 1, j - 1) }
      i = j + 1
    elseif text:match("^%[=*%[", i) then
      local eq = text:match("^%[(=*)%[", i)
      local _, e = text:find("]" .. eq .. "]", i, true)
      out[#out + 1] = { "str", "" }
      i = (e or n) + 1
    elseif c:match("[%a_]") then
      local word = text:match("^[%w_]+", i)
      out[#out + 1] = { "id", word }
      i = i + #word
    else
      out[#out + 1] = { "p", c }
      i = i + 1
    end
  end
  return out
end

---Does the `.testing.lua` of a directory have a `ci` section, a key `ci` directly in its top-level table? Textual: the
---file is not executed here (comments, strings and deeper tables do not count).
---@param dir string
---@return boolean
function M.has_ci(dir)
  local f = io.open(dir .. "/.testing.lua", "rb")
  if not f then
    return false
  end
  local text = f:read("*a")
  f:close()
  local toks = tokens(text)
  local function is(k, kind, value)
    local t = toks[k]
    return t ~= nil and t[1] == kind and (value == nil or t[2] == value)
  end
  local function key_start(k)
    return is(k, "p", "{") or is(k, "p", ",") or is(k, "p", ";")
  end
  local function assigns(k)
    return is(k, "p", "=") and not is(k + 1, "p", "=")
  end
  local depth = 0
  for k, t in ipairs(toks) do
    if t[1] == "p" and t[2] == "{" then
      depth = depth + 1
    elseif t[1] == "p" and t[2] == "}" then
      depth = depth - 1
    elseif depth == 1 and t[2] == "ci" then
      if t[1] == "id" and key_start(k - 1) and assigns(k + 1) then
        return true
      end
      if
        t[1] == "str"
        and is(k - 1, "p", "[")
        and key_start(k - 2)
        and is(k + 1, "p", "]")
        and assigns(k + 2)
      then
        return true
      end
    end
  end
  return false
end

---The directories below a root that have a `ci` section.
---@param root string
---@return string[]
local function scan(root)
  local out = {}
  local handle = vim.uv.fs_scandir(root)
  while handle do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    local dir = root .. "/" .. name
    if
      name:sub(1, 1) ~= "."
      and (kind == "directory" or vim.fn.isdirectory(dir) == 1)
      and M.has_ci(dir)
    then
      out[#out + 1] = dir
    end
  end
  table.sort(out)
  return out
end

---The detection of a root, cached in `cache_file` (`refresh` rebuilds it; a cached directory that is gone or lost
---its section is dropped, a new one is found by `--refresh`).
---@param root string
---@param cache_file string
---@param refresh boolean
---@return string[]
function M.detect(root, cache_file, refresh)
  local cache = {}
  local f = io.open(cache_file, "rb")
  if f then
    local okd, doc = pcall(vim.json.decode, f:read("*a"))
    f:close()
    cache = okd and type(doc) == "table" and type(doc.roots) == "table" and doc.roots or {}
  end
  local found = cache[root]
  if refresh or type(found) ~= "table" then
    found = scan(root)
    cache[root] = found
    pcall(
      require("lib.nvim.fs.write.atomic"),
      cache_file,
      vim.json.encode({ schema = "testing-ci-repos-cache/1", roots = cache }),
      { mkdirp = true }
    )
    return found
  end
  local out = {}
  for _, dir in ipairs(found) do
    if M.has_ci(dir) then
      out[#out + 1] = dir
    end
  end
  return out
end

---The repositories of a run, in order, without duplicates.
---@param args Testing.Ci.Repos.Args
---@param cache_file string
---@return string[]|nil repos
---@return string|nil problem
function M.resolve(args, cache_file)
  local list, seen = {}, {}
  local function add(dir)
    dir = norm(dir)
    if not seen[dir] then
      seen[dir] = true
      list[#list + 1] = dir
    end
  end
  for _, dir in ipairs(args.repos) do
    add(dir)
  end
  if args.file then
    local f = io.open(args.file, "rb")
    if not f then
      return nil, ("cannot read %s"):format(args.file)
    end
    for line in f:lines() do
      line = vim.trim((line:gsub("#.*$", "")))
      if line ~= "" then
        add(line)
      end
    end
    f:close()
  end
  local matched = {}
  for _, root in ipairs(args.roots) do
    root = norm(root)
    if vim.fn.isdirectory(root) ~= 1 then
      return nil, ("--repos-root %s is not a directory"):format(root)
    end
    for _, dir in ipairs(M.detect(root, cache_file, args.refresh)) do
      local name = vim.fs.basename(dir)
      if #args.include == 0 or vim.tbl_contains(args.include, name) then
        add(dir)
        matched[name] = true
      end
    end
  end
  -- an included name that no root has is still asked for: it fails loudly instead of being skipped silently
  for _, name in ipairs(args.include) do
    if not matched[name] and #args.roots > 0 then
      add(norm(args.roots[1]) .. "/" .. name)
    end
  end
  local out = {}
  for _, dir in ipairs(list) do
    if not vim.tbl_contains(args.exclude, vim.fs.basename(dir)) then
      out[#out + 1] = dir
    end
  end
  if #out == 0 then
    return nil, "no repository: name some with --repos, --repos-file or --repos-root"
  end
  return out
end

---@param code integer
---@return string
local function state_of(code)
  return code == 0 and "green" or code == 1 and "red" or code == 2 and "error" or "infra"
end

---The argument list of a child that runs `testing ci <args...>` for one repository.
---@param dir string
---@param args string[]
---@return string[]
function M.child_argv(dir, args)
  local argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    require("testing.bindings.child").driver(),
    "ci",
  }
  vim.list_extend(argv, args)
  argv[#argv + 1] = "--root=" .. dir
  return argv
end

---Replaced by a spec: `vim.system`.
---@type function
M.system = vim.system

---@param args Testing.Ci.Repos.Args
---@param extra string[]
---@return string[]
local function common(args, extra)
  local out = vim.list_extend({}, extra)
  if args.profile then
    out[#out + 1] = "--profile=" .. args.profile
  end
  if args.state_dir then
    out[#out + 1] = "--state-dir=" .. args.state_dir
  end
  return out
end

---`testing ci --repos ...`.
---@param argv string[]
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local state_dir = args.state_dir or sv.state_dir or vim.fn.stdpath("state")
  local repos, why = M.resolve(args, state_dir .. "/testing-ci-repos.json")
  if not repos then
    sv.err("testing ci: " .. tostring(why))
    return M.EXIT_USAGE
  end

  local width = 0
  for _, dir in ipairs(repos) do
    width = math.max(width, #vim.fs.basename(dir))
  end
  ---@type { dir: string, name: string, verify?: string, state?: string, code: integer, ms: integer }[]
  local results = {}
  for i, dir in ipairs(repos) do
    results[i] = { dir = dir, name = vim.fs.basename(dir), code = 0, ms = 0 }
  end

  ---Run one child, streaming its lines with the repository's name in front; calls `cb(code)` when it ended.
  ---@param r table
  ---@param child_args string[]
  ---@param cb fun(code: integer)
  local function spawn(r, child_args, cb)
    local partial = { out = "", err = "" }
    local prefix = ("%-" .. width .. "s | "):format(r.name)
    local function feed(stream)
      return function(_, data)
        if not data or data == "" then
          return
        end
        vim.schedule(function()
          local lines = vim.split(partial[stream] .. data, "\n", { plain = true })
          partial[stream] = table.remove(lines)
          for _, line in ipairs(lines) do
            sv.out(prefix .. (line:gsub("\r+$", "")))
          end
        end)
      end
    end
    local ok, started = pcall(M.system, M.child_argv(r.dir, child_args), {
      text = true,
      timeout = 1800000,
      stdout = feed("out"),
      stderr = feed("err"),
    }, function(res)
      vim.schedule(function()
        for _, stream in ipairs({ "out", "err" }) do
          if partial[stream] ~= "" then
            sv.out(prefix .. partial[stream])
            partial[stream] = ""
          end
        end
        -- a child killed by a signal (OOM kill, SIGTERM) reports code 0 with a signal: that is not a result
        cb((res.signal or 0) ~= 0 and M.EXIT_INFRA or res.code or M.EXIT_INFRA)
      end)
    end)
    if not ok or not started then
      sv.err(("testing ci: cannot start a process for %s: %s"):format(r.name, tostring(started)))
      cb(M.EXIT_INFRA)
    end
  end

  local finished, next_index, active = 0, 1, 0
  local pump
  local function done(r, t0)
    r.ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
    finished = finished + 1
    active = active - 1
    pump()
  end
  local function start(r)
    local t0 = vim.uv.hrtime()
    local function run()
      local run_args = common(args, { "--no-agent" })
      if args.keep_going then
        run_args[#run_args + 1] = "--keep-going"
      end
      if args.reuse then
        run_args[#run_args + 1] = "--reuse"
      end
      spawn(r, run_args, function(code)
        r.code, r.state = code, state_of(code)
        done(r, t0)
      end)
    end
    if args.force then
      r.verify = "forced"
      run()
      return
    end
    spawn(r, common(args, { "verify" }), function(code)
      if code == 0 then
        r.verify, r.state, r.code = "proven", "skipped", 0
        done(r, t0)
      else
        r.verify = "not proven"
        run()
      end
    end)
  end
  pump = function()
    while active < args.jobs and next_index <= #results do
      local r = results[next_index]
      next_index = next_index + 1
      active = active + 1
      start(r)
    end
  end
  pump()
  vim.wait(24 * 3600 * 1000, function()
    return finished == #results
  end, 20)

  -- the table, and the exit code: the worst single result
  sv.out("")
  sv.out(("%-" .. width .. "s  %-11s %-8s %s"):format("repo", "verify", "result", "time"))
  local exit, green, proven = M.EXIT_OK, 0, 0
  for _, r in ipairs(results) do
    exit = math.max(exit, r.code)
    green = green + (r.code == 0 and 1 or 0)
    proven = proven + (r.state == "skipped" and 1 or 0)
    sv.out(
      ("%-" .. width .. "s  %-11s %-8s %.1f s"):format(
        r.name,
        r.verify or "-",
        r.state or "?",
        r.ms / 1000
      )
    )
  end
  local verdict = exit == 0 and "GREEN" or exit == 1 and "RED" or exit == 2 and "ERROR" or "INFRA"
  sv.out(("ci repos: %s %d/%d (%d proven, not run)"):format(verdict, green, #results, proven))
  if exit == 0 then
    sv.out(require("testing.ci").SENTINEL)
  end
  return exit
end

return M
