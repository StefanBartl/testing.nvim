---@module 'testing.run.inproc'
---@brief Minimal in-process driver (M0): runs dialect-A spec files in the current Neovim, one case each.
---@description
--- Walks a spec list in order, loads every file exactly like lib.nvim's `TESTS/run.lua` does
--- (`dofile(file)` returns `function(H)`, which is then called with the harness), but inside
--- `a.run_case`, so that
---
---   * every failed `H.eq` / `H.ok` is recorded and the file runs on (P1);
---   * a raise of the spec itself (or of `dofile`) ends that file as an `error` case with a
---     traceback, and the run continues with the next file;
---   * every file gets a duration measured with `vim.uv.hrtime`.
---
--- Mapping (honest, dialect A has no test cases): ONE CASE = ONE SPEC FILE. The case id is
--- `<file relative to the root>::<file name>`; its assertions are the `H.eq`/`H.ok` calls of the
--- file. State is shared between files, as in the old runner (one Neovim, one `package.loaded`).
---
--- Verdict per file, comparable to the old runner: `ok` iff the case status is `pass` (a file that
--- raised, or whose recorded assertions include a failure, is `FAIL`). A file that made no
--- assertion at all follows the kernel rule (`fail`, P4) and is reported as such, never hidden.
---
--- Output keeps the line shapes of the old runner (`ok    name`, `FAIL  name` + indented details,
--- `N spec(s) failed`); the transitional sentinel is printed by the CLI, last, after the JSON was
--- written and validated, and only when everything is green.
---
--- Pure orchestration: the clock, the output function and the spec list are injected; the only
--- editor APIs used are `vim.uv.hrtime`, `vim.fs` and `vim.fn.tempname`.

local result = require("testing.core.result")
local assert_mod = require("testing.core.assert")

local M = {}

---Every case carries this note: the IR's `effects` lists are empty because nothing measures them
---in M0, not because nothing happened (a consumer must not read "not collected" as "none").
local EFFECTS_NOTE = "effects: not collected (M0); the empty effects lists are not a measurement"

-- =========================================================
-- Discovery
-- =========================================================

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---Source text of a file, or nil.
---@param path string
---@return string|nil
local function read_text(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---Replace Lua comments (`-- ...` and `--[[ ... ]]`, also with `=` levels) by whitespace, leaving
---strings alone, so a commented-out spec name is not mistaken for a listed one. A small scanner,
---not a parser: good enough for a spec list, and the caller treats the result as a best effort.
---@param text string
---@return string
local function strip_lua_comments(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' or c == "'" then
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
      out[#out + 1] = text:sub(i, j)
      i = j + 1
    elseif text:sub(i, i + 1) == "--" then
      local level = text:match("^%-%-%[(=*)%[", i)
      local stop
      if level then
        local _, e = text:find("]" .. level .. "]", i, true)
        stop = e or n
      else
        stop = (text:find("\n", i, true) or n + 1) - 1
      end
      out[#out + 1] = " "
      i = stop + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

---Order hint and sentinel taken from the project's own runner (`TESTS/run.lua`), if it has one.
---The old runner hardcodes its spec list and the shared state between files depends on that order,
---so the transitional driver keeps it. Specs on disk but not in the list are appended
---alphabetically and reported (the old runner would not run them). The list is scraped from the
---runner's text (comments removed): a best effort, which is why a spec that is listed but missing
---on disk is a failing case, never a silent skip.
---@param root string
---@return string[] listed Names in runner order (may be empty)
---@return string|nil sentinel e.g. `LIB_TESTS_OK`
local function read_runner_hints(root)
  local text = read_text(root .. "/TESTS/run.lua")
  if not text then
    return {}, nil
  end
  text = strip_lua_comments(text)
  local listed, seen = {}, {}
  for name in text:gmatch('"([%w_%-%./]+_spec%.lua)"') do
    if not seen[name] then
      seen[name] = true
      listed[#listed + 1] = name
    end
  end
  local sentinel = text:match('"\\n([%u%d_]+_OK)[%s%(\\"]')
  return listed, sentinel
end

---@class Testing.Inproc.Discovery
---@field files string[] Absolute spec paths in run order (after the `only` filter; listed-but-missing ones included).
---@field total integer Number of spec files of the unfiltered run (`files` is a partial run when smaller).
---@field sentinel string|nil Sentinel the project's runner prints.
---@field notes string[] Things worth saying (unlisted specs, listed but missing).

---Find the spec files below `<root>/TESTS`.
---@param root string
---@param only? string[] Substrings of the file name; empty or nil selects everything.
---@return Testing.Inproc.Discovery
function M.discover(root, only)
  root = slashes(root):gsub("/+$", "")
  local dir = root .. "/TESTS"
  local on_disk, rel_of = {}, {}
  if vim.fn.isdirectory(dir) == 1 then
    for name, kind in vim.fs.dir(dir, { depth = 3 }) do
      if kind == "file" and name:match("_spec%.lua$") then
        local path = slashes(dir .. "/" .. name)
        on_disk[#on_disk + 1] = path
        rel_of[path] = slashes(name)
      end
    end
  end
  table.sort(on_disk)

  local listed, sentinel = read_runner_hints(root)
  local notes, ordered, taken = {}, {}, {}
  for _, name in ipairs(listed) do
    local path = slashes(dir .. "/" .. name)
    -- A listed spec that is missing stays in the list: loading it fails, which is an `error`
    -- case (the old runner `dofile`s every listed name and dies on a missing one, so a deleted or
    -- renamed spec must never turn into a quiet green run with fewer files).
    ordered[#ordered + 1] = path
    taken[path] = true
    if not rel_of[path] then
      notes[#notes + 1] = ("listed in TESTS/run.lua but not on disk: %s"):format(name)
    end
  end
  for _, path in ipairs(on_disk) do
    if not taken[path] then
      ordered[#ordered + 1] = path
      if #listed > 0 then
        notes[#notes + 1] = ("on disk but not in TESTS/run.lua (run last): %s"):format(rel_of[path])
      end
    end
  end

  local files = ordered
  if only and #only > 0 then
    files = {}
    for _, path in ipairs(ordered) do
      for _, w in ipairs(only) do
        if path:find(w, 1, true) then
          files[#files + 1] = path
          break
        end
      end
    end
  end
  return { files = files, total = #ordered, sentinel = sentinel, notes = notes }
end

-- =========================================================
-- Run
-- =========================================================

---@class Testing.Inproc.Opts
---@field root string Project root (absolute); case files are relative to it.
---@field files string[] Absolute spec paths in run order.
---@field say? fun(line: string) Output sink (default: straight to stdout).
---@field argv? string[] Effective arguments, stored in the IR header.
---@field harness? fun(a: Testing.Assert.Context): table Builds `H` (default: dialect A).
---@field timings? boolean Print the timing line before the verdict (default true).
---@field clock? Testing.Assert.Clock Case clock in ms (default `vim.uv.hrtime`).

---@class Testing.Inproc.Report
---@field result Testing.Result The finalized IR.
---@field failed integer Files that are not `pass`.
---@field total integer Files run.
---@field wall_ms number Wall time of the file loop.
---@field exit_code integer 0 green, 1 at least one file failed.

---@param s string
local function stdout_say(s)
  io.stdout:write(s, "\n")
end

---@param root string
---@param path string
---@return string
local function relative(root, path)
  local r, p = slashes(root):gsub("/+$", ""), slashes(path)
  if p:sub(1, #r + 1):lower() == (r .. "/"):lower() then
    return p:sub(#r + 2)
  end
  return p
end

---Facts for the IR header.
---@param root string
---@return table
local function run_facts(root)
  local uname = vim.uv.os_uname() or { sysname = "unknown", machine = "unknown" }
  local v = vim.version()
  local sys = uname.sysname:lower()
  local os_name = sys:match("^windows") and "windows" or (sys == "darwin" and "macos" or sys)
  return {
    nvim = ("%d.%d.%d"):format(v.major, v.minor, v.patch),
    os = os_name,
    arch = uname.machine,
    project_key = require("lib.nvim.fs.project_key")(root),
  }
end

---Abbreviated HEAD and dirty flag of `root`, nil when it is not a git checkout (or git is missing).
---@param root string
---@return Testing.Result.Git|nil
local function git_facts(root)
  local job = require("lib.nvim.system.job")
  local function git(args)
    local argv = { "-C", root }
    vim.list_extend(argv, args)
    local ok, res = pcall(job.start_blocking, { command = "git", args = argv, timeout_ms = 10000 })
    if ok and res and res.code == 0 then
      return res.stdout or ""
    end
    return nil
  end
  local sha = git({ "rev-parse", "--short", "HEAD" })
  if not sha then
    return nil
  end
  local status = git({ "status", "--porcelain" })
  return { sha = vim.trim(sha), dirty = status ~= nil and vim.trim(status) ~= "" }
end

---Details of a non-passing case, one line each, indented like the old runner's error line.
---@param root string
---@param case Testing.Result.Case
---@return string[]
local function failure_lines(root, case)
  local lines = {}
  for _, a in ipairs(case.assertions) do
    if not a.ok then
      local at = a.file and ("%s:%s: "):format(relative(root, a.file), tostring(a.line or "?"))
        or ""
      local first = (a.msg or a.kind):match("^[^\n]*")
      lines[#lines + 1] = ("      %s%s"):format(at, first)
    end
  end
  if case.error then
    lines[#lines + 1] = ("      error: %s"):format(case.error.message)
  end
  return lines
end

---Run the files and build the IR.
---@param opts Testing.Inproc.Opts
---@return Testing.Inproc.Report
function M.run(opts)
  local say = opts.say or stdout_say
  local root = slashes(opts.root):gsub("/+$", "")
  local a = assert_mod.new({ clock = opts.clock })
  local build_harness = opts.harness or require("testing.dialect.harness_a").new

  local facts = run_facts(root)
  local res = result.new({
    root = root,
    project_key = facts.project_key,
    nvim = facts.nvim,
    os = facts.os,
    arch = facts.arch,
    git = git_facts(root),
    jobs = 1,
    argv = opts.argv or {},
  })

  local hrtime = vim.uv.hrtime
  local started = hrtime()
  local failed = 0
  for _, path in ipairs(opts.files) do
    local rel = relative(root, path)
    local case = a.run_case({ file = rel, name = vim.fs.basename(rel) }, function()
      -- One `H` per file, bound to this case: a late call (timer, `vim.schedule`) after the file
      -- ended cannot land on the next file's case.
      local H = build_harness(a.scope())
      local run = dofile(path)
      run(H)
    end)
    case.notes[#case.notes + 1] = EFFECTS_NOTE
    result.add_case(res, case)
    local name = vim.fs.basename(rel)
    if case.status == "pass" then
      say(("ok    %s"):format(name))
    else
      failed = failed + 1
      say(("FAIL  %s"):format(name))
      for _, line in ipairs(failure_lines(root, case)) do
        say(line)
      end
    end
  end
  local wall_ms = (hrtime() - started) / 1e6

  -- Assertions that arrived after their file ended (before the IR is finalized) make the run red:
  -- a synthetic case lists them, never a silent drop.
  if #a.late > 0 then
    a.begin_case({ file = "<late>", name = "late assertions" })
    for _, l in ipairs(a.late) do
      a.fail(l.msg)
    end
    local lcase = a.end_case()
    lcase.notes[#lcase.notes + 1] = EFFECTS_NOTE
    result.add_case(res, lcase)
    failed = failed + 1
    say("FAIL  <late assertions>")
    for _, line in ipairs(failure_lines(root, lcase)) do
      say(line)
    end
  end

  res.run.duration_ms = math.floor(wall_ms * 1000 + 0.5) / 1000
  result.finalize(res)

  local total = #res.cases
  if opts.timings ~= false then
    say("\n" .. M.timing_line(res))
  end
  if failed > 0 then
    say(("\n%d spec(s) failed"):format(failed))
  end
  return {
    result = res,
    failed = failed,
    total = total,
    wall_ms = wall_ms,
    exit_code = failed > 0 and 1 or 0,
  }
end

---One line with the total and the slowest files (for a human reading the log).
---@param res Testing.Result
---@param n? integer How many slow files to name (default 5)
---@return string
function M.timing_line(res, n)
  local sorted = vim.deepcopy(res.cases)
  table.sort(sorted, function(x, y)
    return x.duration_ms > y.duration_ms
  end)
  local parts = {}
  for i = 1, math.min(n or 5, #sorted) do
    parts[#parts + 1] = ("%s %.0f ms"):format(
      vim.fs.basename(sorted[i].file),
      sorted[i].duration_ms
    )
  end
  return ("timings: %d file(s) in %.0f ms; slowest: %s"):format(
    #res.cases,
    res.run.duration_ms,
    table.concat(parts, ", ")
  )
end

---Path roots for the placeholders of the serialized IR.
---@param root string
---@return Testing.Result.PathRoots
function M.path_roots(root)
  return {
    repo = root,
    home = vim.uv.os_homedir(),
    tmp = vim.fs.dirname(vim.fn.tempname()),
    state = vim.fn.stdpath("state"),
  }
end

---Case-insensitive plain-text replacement.
---@param s string
---@param needle string
---@param repl string
---@return string
local function replace_plain_ci(s, needle, repl)
  local low, nlow = s:lower(), needle:lower()
  local out, pos = {}, 1
  while true do
    local i, j = low:find(nlow, pos, true)
    if not i then
      break
    end
    out[#out + 1] = s:sub(pos, i - 1)
    out[#out + 1] = repl
    pos = j + 1
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out)
end

---Scrub what `result.encode` cannot: text a spec printed itself. Spec messages interpolate runtime
---values (a `vim.inspect`ed path has DOUBLED backslashes, an environment dump names the user), and
---the validator rightly refuses such an IR. In place: the root paths in their escaped form become
---placeholders, in assertion texts and case errors. (The user name is redacted in `write_json`,
---after the kernel normalized the real paths: doing it first would break the home-path match.)
---(Open point for M1: the kernel should own a `redact` option; env values like an e-mail address
---are only partly covered by the user-name rule.)
---@param res Testing.Result
---@param root string
function M.scrub_texts(res, root)
  local needles = {}
  for name, path in pairs(M.path_roots(root)) do
    if type(path) == "string" and path ~= "" then
      local doubled = path:gsub("/", "\\"):gsub("\\", "\\\\")
      needles[#needles + 1] = { doubled, result.PLACEHOLDERS[name] }
    end
  end
  table.sort(needles, function(x, y)
    return #x[1] > #y[1]
  end)
  local function scrub(s)
    if type(s) ~= "string" then
      return s
    end
    for _, n in ipairs(needles) do
      s = replace_plain_ci(s, n[1], n[2])
    end
    return s
  end
  for _, case in ipairs(res.cases) do
    for _, a in ipairs(case.assertions) do
      a.msg, a.expected, a.actual = scrub(a.msg), scrub(a.expected), scrub(a.actual)
    end
    if case.error then
      case.error.message = scrub(case.error.message)
      case.error.traceback = scrub(case.error.traceback)
    end
  end
end

---Serialize, write and re-validate the IR: the file on disk is decoded again and checked, so what
---is validated is exactly what a reporter will read.
---@param res Testing.Result
---@param path string Output file (parents are created).
---@param root string
---@return boolean ok
---@return string|nil err
function M.write_json(res, path, root)
  M.scrub_texts(res, root)
  local ci = res.run.os == "windows"
  -- What must not reach the disk: the user name, the host name, the whole environment (specs print
  -- env dumps and, through them, e-mail addresses and machine names). The kernel redacts the free
  -- text of the cases (decoded strings, never JSON text); the validator then refuses what is left.
  local words, forbid = {}, {}
  for _, w in ipairs({
    { vim.env.USERNAME or vim.env.USER, "<USER>" },
    { vim.uv.os_gethostname(), "<HOST>" },
    { vim.env.COMPUTERNAME or vim.env.HOSTNAME, "<HOST>" },
  }) do
    if type(w[1]) == "string" and #w[1] >= 3 then
      words[#words + 1] = { text = w[1], ph = w[2] }
      forbid[#forbid + 1] = w[1]
    end
  end
  local env_names = vim.tbl_keys(vim.fn.environ())
  local json, err = result.encode(res, {
    roots = M.path_roots(root),
    case_insensitive = ci,
    redact = { env_names = env_names, words = words },
  })
  if not json then
    return false, err
  end
  local decoded, derr = require("lib.nvim.json").decode(json)
  if type(decoded) ~= "table" then
    return false, "the encoded IR does not decode again: " .. tostring(derr)
  end
  local valid, problems = result.validate(decoded, { forbid = forbid })
  if not valid then
    return false, "the IR failed validation:\n  " .. table.concat(problems, "\n  ")
  end
  -- Only a validated IR reaches the disk.
  local wrote, werr = require("lib.nvim.fs.write.atomic")(path, json, { mkdirp = true })
  if not wrote then
    return false, ("cannot write %s: %s"):format(path, tostring(werr))
  end
  return true, nil
end

return M
