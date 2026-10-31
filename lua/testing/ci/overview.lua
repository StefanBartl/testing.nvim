---@module 'testing.ci.overview'
---@brief `testing ci overview`: one static HTML page of the fleet, local proof and GitHub Actions per system. Reads only.
---@description
--- ```
--- testing ci overview [<root>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>] [--out=<file.html>]
---                     [--json] [--no-remote] [--state-dir=<dir>]
--- ```
---
--- Per repository it only reads: the answer of `testing ci verify --json` (in this process, `testing.ci.verify`;
--- 'runtimepath' and the cache key are restored after it), `ci.json` and `ci-<profile>.json` of the repository's state
--- directory, and the CI adapter (`testing.ci.remote.collect`). It never starts a pipeline or a suite: not
--- `testing ci --repos-root`, which runs every repository that is not proven. The processes are git and the
--- `--version` of a profile's tools. A repository that cannot be read is unknown, the page is written all the same.
---
--- Which repositories: the roots named, and below each `--repos-root` the repositories `testing ci remote` finds
--- (`.github/workflows`; without a GitHub origin it is "no GitHub"), those `testing ci --repos-root` finds (a `ci`
--- section) and any other with a `.testing.lua`, without the vaults (a name containing "vault"); then
--- `ci_overview.include` (default lib.nvim, it has no `.testing.lua`) and
--- `--include` are taken in, `ci_overview.exclude` and `--exclude` left out (the `.testing.lua` of the current
--- directory; an included name wins over the vault rule).
---
--- The page is one self-contained file: inline CSS, no script, no font, no request (a Content-Security-Policy of
--- `default-src 'none'` says so); light and dark through `prefers-color-scheme`; the filter "nur rot" is a checkbox and
--- CSS. Every text is HTML-escaped; free texts are redacted as the IR redacts a message, and every absolute path that is
--- left becomes `<PATH>`: a repository is shown by its directory name. Links only to `https://github.com/`.
---
--- Exit codes: 0 written or (`--json` alone) printed (also with red repositories: the page is a report, not a gate),
--- 2 usage, 3 the page could not be written.

local M = {}

M.EXIT_OK, M.EXIT_USAGE, M.EXIT_INFRA = 0, 2, 3

M.SCHEMA = "testing-ci-overview/1"

M.USAGE = table.concat({
  "usage: testing ci overview [<root>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]",
  "                           [--out=<file.html>] [--json] [--no-remote] [--state-dir=<dir>]",
  "  <root>              a repository (default: the current directory)",
  "  --repos-root=<dir>  the repositories below <dir> (workflows or a .testing.lua; no vault; repeatable)",
  "  --include=<names>   also these directory names below --repos-root (added to ci_overview.include, lib.nvim)",
  "  --exclude=<names>   leave these directory names out (added to ci_overview.exclude)",
  "  --out=<file.html>   where the page goes (default: <state>/testing/overview.html)",
  "  --json              print the document testing-ci-overview/1 instead of writing the page",
  "  --no-remote         do not ask GitHub (the CI columns are unknown)",
  "  --state-dir=<dir>   the state directory (default: stdpath('state'))",
  "  reads only: never starts a pipeline or a suite",
  "  exit: 0 written or printed (also with red repositories), 2 usage, 3 the page could not be written",
}, "\n")

---The cells of the CI columns.
M.OS = { "ubuntu", "windows", "macos" }

---What the filter "nur rot" keeps of the CI states.
local CI_RED = { failure = true, rejected = true }

---Replaced by a spec: the clock and the two sources.
M.deps = {
  ---@return integer seconds since the epoch
  now = function()
    return os.time()
  end,
  ---The `testing-ci-verify/1` document of a repository, asked in this process.
  ---@param dir string
  ---@param state_dir string|nil
  ---@param sv table
  ---@return table|nil doc
  ---@return string|nil problem
  verify = function(dir, state_dir, sv)
    -- verify runs the repository's `.testing.lua`, and its suite answer (`testing verify`) puts the repository and its
    -- dependencies on 'runtimepath' and sets the cache's project key: one repository must not leave them to the next
    local store = require("testing.cache.store")
    local rtp, key = vim.o.runtimepath, store.project_key
    local doc, problem = M.ask_verify(dir, state_dir, sv)
    vim.o.runtimepath, store.project_key = rtp, key
    return doc, problem
  end,
  ---@param repos { dir: string, from_root: boolean }[]
  ---@param opts { state_dir: string }
  ---@return table[] records
  remote = function(repos, opts)
    return (require("testing.ci.remote").collect(repos, opts))
  end,
}

---The `testing-ci-verify/1` document of a repository, asked in this process (`M.deps.verify` restores what it changes).
---@param dir string
---@param state_dir string|nil
---@param sv table
---@return table|nil doc
---@return string|nil problem
function M.ask_verify(dir, state_dir, sv)
  local lines = {}
  local errs = {}
  local argv = { "--json", "--root=" .. dir }
  if state_dir then
    argv[#argv + 1] = "--state-dir=" .. state_dir
  end
  local ok, code = pcall(
    require("testing.ci.verify").main,
    argv,
    vim.tbl_extend("force", sv, {
      out = function(s)
        lines[#lines + 1] = s
      end,
      err = function(s)
        errs[#errs + 1] = s
      end,
    })
  )
  if not ok then
    return nil, tostring(code)
  end
  local okd, doc = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not okd or type(doc) ~= "table" then
    return nil, (errs[1] or "no answer"):gsub("^testing ci verify: ", "")
  end
  return doc
end

---@class Testing.Ci.Overview.Args
---@field roots string[]
---@field repos_roots string[]
---@field include string[]
---@field exclude string[]
---@field out? string
---@field json boolean
---@field no_remote boolean
---@field state_dir? string
---@field help boolean

local VALUED =
  { ["repos-root"] = true, include = true, exclude = true, out = true, ["state-dir"] = true }

---@param argv string[] The arguments after `overview`.
---@return Testing.Ci.Overview.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Overview.Args
  local args = {
    roots = {},
    repos_roots = {},
    include = {},
    exclude = {},
    json = false,
    no_remote = false,
    help = false,
  }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "json" and value == nil then
      args.json = true
    elseif key == "no-remote" and value == nil then
      args.no_remote = true
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
      if key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "include" or key == "exclude" then
        -- a directory name below --repos-root, as `ci_overview` checks it: `..` or `../x` would leave the root
        for _, name in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
          if not require("testing.deps").is_valid_name(name) then
            return nil, ("--%s: %s is not a directory name"):format(key, name)
          end
          table.insert(args[key], name)
        end
      elseif key == "state-dir" then
        args.state_dir = value
      else
        args.out = value
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.roots[#args.roots + 1] = a
    end
    i = i + 1
  end
  return args
end

---@param dir string
---@return string
local function norm(dir)
  return (
    vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")):gsub("([^:/])/+$", "%1")
  )
end

---@param name string
---@return boolean
local function is_vault(name)
  return name:lower():find("vault", 1, true) ~= nil
end

---The `ci_overview` section of the `.testing.lua` in `cwd` (the defaults without one; a problem when it cannot be
---loaded).
---@param cwd string
---@return { include: string[], exclude: string[] } cfg
---@return string|nil problem
function M.config(cwd)
  local defaults = require("testing.config.DEFAULTS").project.ci_overview
  if not vim.uv.fs_stat(cwd .. "/.testing.lua") then
    return vim.deepcopy(defaults)
  end
  local ok, loaded = pcall(require("testing.config.project").load, cwd)
  if not ok then
    return vim.deepcopy(defaults), ".testing.lua: " .. tostring(loaded)
  end
  if loaded.error then
    return vim.deepcopy(defaults), ".testing.lua: " .. tostring(loaded.error)
  end
  return loaded.config.ci_overview
end

---The repositories of a page, sorted by directory name; the names left out (vaults and excludes) and the included
---names that no `--repos-root` has. The detection is the one of `testing ci remote` and of `testing ci --repos-root`
---(uncached), nothing of its own.
---@param args Testing.Ci.Overview.Args
---@param cfg { include: string[], exclude: string[] }
---@return string[]|nil dirs
---@return { excluded: string[], missing: string[] }|string info_or_problem
function M.resolve(args, cfg)
  local remote, repos = require("testing.ci.remote"), require("testing.ci.repos")
  local dirs, seen = {}, {}
  local function add(dir)
    dir = norm(dir)
    if not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end
  local include = vim.list_extend(vim.deepcopy(cfg.include), args.include)
  local exclude = {}
  for _, name in ipairs(vim.list_extend(vim.deepcopy(cfg.exclude), args.exclude)) do
    exclude[name] = true
  end
  for _, root in ipairs(args.roots) do
    if vim.fn.isdirectory(root) ~= 1 then
      return nil, ("%s is not a directory"):format(root)
    end
    add(root)
  end
  local left, found_include = {}, {}
  for _, parent in ipairs(args.repos_roots) do
    if vim.fn.isdirectory(parent) ~= 1 then
      return nil, ("--repos-root %s is not a directory"):format(parent)
    end
    parent = norm(parent)
    local vaults = {}
    local listed = remote.resolve({ roots = {}, repos_roots = { parent } }, vaults) or {}
    for _, r in ipairs(listed) do
      add(r.dir)
    end
    -- a `ci` section (`testing ci --repos-root`), and any `.testing.lua` (a suite without a pipeline is still one)
    local own = repos.scan(parent)
    for name, kind in vim.fs.dir(parent) do
      local dir = parent .. "/" .. name
      if
        name:sub(1, 1) ~= "."
        and (kind == "directory" or kind == "link")
        and vim.uv.fs_stat(dir .. "/.testing.lua")
      then
        own[#own + 1] = dir
      end
    end
    table.sort(own)
    for _, dir in ipairs(own) do
      if is_vault(vim.fs.basename(dir)) then
        vaults[#vaults + 1] = vim.fs.basename(dir)
      else
        add(dir)
      end
    end
    for _, name in ipairs(include) do
      if vim.fn.isdirectory(parent .. "/" .. name) == 1 then
        add(parent .. "/" .. name)
        found_include[name] = true
      end
    end
    vim.list_extend(left, vaults)
  end
  if #args.roots == 0 and #args.repos_roots == 0 then
    add(".")
  end
  local out, excluded, mark = {}, {}, {}
  local function leave(name)
    if not mark[name] then
      mark[name] = true
      excluded[#excluded + 1] = name
    end
  end
  for _, dir in ipairs(dirs) do
    local name = vim.fs.basename(dir)
    if exclude[name] then
      leave(name)
    else
      out[#out + 1] = dir
    end
  end
  for _, name in ipairs(left) do
    -- a vault that was included by name is on the page, not left out
    if not found_include[name] then
      leave(name)
    end
  end
  local missing = {}
  if #args.repos_roots > 0 then
    for _, name in ipairs(include) do
      if not found_include[name] and not exclude[name] then
        missing[#missing + 1] = name
      end
    end
  end
  table.sort(out, function(a, b)
    local na, nb = vim.fs.basename(a), vim.fs.basename(b)
    if na ~= nb then
      return na < nb
    end
    return a < b
  end)
  table.sort(excluded)
  return out, { excluded = excluded, missing = missing }
end

---A free text fit for the page and the document: redacted as the IR redacts a message (user, host, environment,
---home paths, the roots of `dir`), every absolute path that is left `<PATH>`, no control characters, bounded.
---@param s any
---@param dir string
---@param state_dir? string The state directory of the page (`--state-dir`): `<STATE>` as well.
---@return string|nil
function M.clean(s, dir, state_dir)
  if type(s) ~= "string" or s == "" then
    return nil
  end
  s = require("testing.run.inproc").redact_text(s, dir, { state = state_dir })
  s = s:gsub("%c", " ")
  -- a drive path (`E:/x`, `C:\x`) at the start of a word (not the `s:/` of `https://`), a UNC path
  s = s:gsub("%f[%w]%a:[\\/][^%s\"'<>`]*", "<PATH>")
  s = s:gsub("\\\\[^%s\"'<>`]+", "<PATH>")
  -- an absolute POSIX path after any character that is no part of a path, of a URL (`https://`) or of a placeholder
  -- (`<REPO>/x`) or of a closing tag (`</b>`): `` `/opt/x` ``, `[/srv/a]`, `error:/x`, `/x`
  s = (" " .. s):gsub("([^%w._~%-/\\<>])/[%w._%-]+[^%s\"'<>`]*", "%1<PATH>"):sub(2)
  -- a path with a space in it (`C:/My Dir/a`): the rest after the space is part of it
  for _, ph in ipairs({ "PATH", "REPO", "HOME", "TMP", "STATE" }) do
    local n
    repeat
      s, n = s:gsub("(<" .. ph .. ">[^%s\"'<>`]*) [^%s\"'<>`/\\]+[\\/][^%s\"'<>`]*", "%1")
    until n == 0
  end
  if #s > 300 then
    -- at a character boundary: a cut UTF-8 sequence would make the page invalid
    local cut = 297
    while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do
      cut = cut - 1
    end
    s = s:sub(1, cut) .. "..."
  end
  return s
end

---@param path string
---@return table|nil
local function read_json(path)
  local raw = require("lib.nvim.fs.read_bounded")(path, 8 * 1024 * 1024)
  if not raw then
    return nil
  end
  local ok, doc = pcall(vim.json.decode, raw)
  return ok and type(doc) == "table" and doc or nil
end

---@param v any
---@return string|nil
local function str(v)
  return type(v) == "string" and v or nil
end

---The local state of a repository: proven (`ci verify` says verified), red (the last run, `ci.json`, or the last
---complete run of the profile, `ci-<profile>.json`, was red), unknown (anything else), none (no `.testing.lua`).
---@param dir string
---@param state_dir string|nil
---@param sv table
---@param now integer
---@return table
local function local_state(dir, state_dir, sv, now)
  if not vim.uv.fs_stat(dir .. "/.testing.lua") then
    return { state = "none", note = "no testing.nvim" }
  end
  local vdoc, problem = M.deps.verify(dir, state_dir, sv)
  local sdir = require("testing.state").dir(dir, { state_dir = state_dir })
  local last = read_json(sdir .. "/ci.json")
  local rec =
    { verify = vdoc and str(vdoc.status) or "error", profile = vdoc and str(vdoc.profile) }
  local reason = vdoc and type(vdoc.reasons) == "table" and str(vdoc.reasons[1]) or problem
  -- the last complete run of the profile: red there is red, whatever partial run came after it
  local proof = rec.profile and read_json(sdir .. "/ci-" .. rec.profile .. ".json")
  local epoch = require("testing.ci.remote").epoch
  local red
  for _, d in ipairs({ last or false, proof or false }) do
    if
      d
      and d.verdict == "red"
      and (not red or (epoch(str(d.time)) or 0) > (epoch(str(red.time)) or 0))
    then
      red = d
    end
  end
  if rec.verify == "verified" then
    rec.state = "proven"
    rec.time = proof and str(proof.time)
  elseif red then
    rec.state = "red"
    rec.time = str(red.time)
    local note = "red: " .. (str(red.first_red) or "?")
    if red == proof then
      note = ("%s (profile %s)"):format(note, rec.profile)
    end
    -- the tree now: verify reads it only for a usable proof, so read it here when it did not
    local tree = vdoc and str(vdoc.tree)
    if not tree then
      local okf, facts = pcall(require("testing.ci").internal.git_facts, dir)
      tree = okf and type(facts) == "table" and str(facts.tree) or nil
    end
    if not tree or not str(red.tree) then
      note = note .. " (tree unknown)"
    elseif tree ~= red.tree then
      note = note .. " (an older tree)"
    end
    rec.note = note
  else
    rec.state = "unknown"
    rec.time = last and str(last.time)
    local note = rec.verify
    if last and (last.verdict == "error" or last.verdict == "infra") then
      note = note .. "; last run: " .. last.verdict
    end
    if reason then
      note = note .. ": " .. reason
    end
    rec.note = note
  end
  local t = require("testing.ci.remote").epoch(rec.time)
  rec.age_s = t and math.max(0, now - t) or nil
  rec.note = M.clean(rec.note, dir, state_dir)
  return rec
end

---@param url any
---@return string|nil
local function github_url(url)
  if type(url) == "string" and url:match("^https://github%.com/[%w%-_./]+$") then
    return url
  end
  return nil
end

---The CI part of a record from the adapter's record (nil: not asked).
---@param r table|nil
---@param dir string
---@param why string
---@param state_dir string|nil
---@return table
local function ci_state(r, dir, why, state_dir)
  if not r then
    local os_ = {}
    for _, sys in ipairs(M.OS) do
      os_[sys] = { state = "unknown" }
    end
    return { overall = "unknown", os = os_, note = why }
  end
  local os_ = {}
  for _, sys in ipairs(M.OS) do
    local cell = r.os and r.os[sys]
    if cell then
      os_[sys] = { state = cell.state, url = github_url(cell.url) }
    elseif r.os then
      -- a run with jobs, none for this system: not configured, not red
      os_[sys] = { state = "none" }
    else
      os_[sys] = { state = r.overall }
    end
  end
  return {
    overall = r.overall,
    os = os_,
    run_url = r.run and github_url(r.run.url) or nil,
    note = M.clean(r.note, dir, state_dir),
  }
end

---The records of a page.
---@param dirs string[]
---@param opts { state_dir?: string, no_remote: boolean, now: integer }
---@param sv table
---@return table[]
function M.collect(dirs, opts, sv)
  local by_dir, why = {}, nil
  if opts.no_remote then
    why = "not asked (--no-remote)"
  elseif not pcall(require, "lib.nvim.net.github") then
    why = "lib.nvim has no net.github"
  else
    local list = {}
    for i, dir in ipairs(dirs) do
      list[i] = { dir = dir, from_root = false }
    end
    local ok, records =
      pcall(M.deps.remote, list, { state_dir = opts.state_dir or vim.fn.stdpath("state") })
    if ok then
      for _, r in ipairs(records or {}) do
        by_dir[r.dir] = r
      end
    else
      why = "the CI adapter failed: " .. tostring(records)
    end
  end
  local out = {}
  for _, dir in ipairs(dirs) do
    local r = by_dir[dir]
    -- one repository that cannot be read (a broken file in its state, a throwing source) is unknown, not the page
    local okl, l = pcall(local_state, dir, opts.state_dir, sv, opts.now)
    if not okl then
      l = {
        state = "unknown",
        verify = "error",
        note = M.clean("the local state could not be read: " .. tostring(l), dir, opts.state_dir),
      }
    end
    local why_r = M.clean(why or (r and "" or "no record of the CI adapter"), dir, opts.state_dir)
    local okc, c = pcall(ci_state, r, dir, why_r, opts.state_dir)
    if not okc then
      c = ci_state(
        nil,
        dir,
        M.clean("the CI record could not be read: " .. tostring(c), dir, opts.state_dir)
      )
    end
    out[#out + 1] = { repo = vim.fs.basename(dir), ["local"] = l, ci = c }
  end
  return out
end

---@param records table[]
---@return table counts
local function counts(records)
  local c = {
    repos = #records,
    ["local"] = { proven = 0, red = 0, unknown = 0, none = 0 },
    ci = { green = 0, red = 0, other = 0 },
  }
  for _, r in ipairs(records) do
    local l = c["local"]
    l[r["local"].state] = (l[r["local"].state] or 0) + 1
    if r.ci.overall == "success" then
      c.ci.green = c.ci.green + 1
    elseif CI_RED[r.ci.overall] then
      c.ci.red = c.ci.red + 1
    else
      c.ci.other = c.ci.other + 1
    end
  end
  return c
end

---The document `testing-ci-overview/1`.
---@param records table[]
---@param info { excluded: string[], missing: string[] }
---@param now integer
---@return table
function M.document(records, info, now)
  return {
    schema = M.SCHEMA,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
    counts = counts(records),
    excluded = info.excluded,
    missing = info.missing,
    repos = records,
  }
end

---@param s any
---@return string
local function esc(s)
  return (
    tostring(s or "")
      :gsub("&", "&amp;")
      :gsub("<", "&lt;")
      :gsub(">", "&gt;")
      :gsub('"', "&quot;")
      :gsub("'", "&#39;")
  )
end
M._esc = esc

---@param s integer|nil
---@return string
local function age(s)
  if not s then
    return ""
  elseif s < 3600 then
    return ("%d min"):format(math.floor(s / 60))
  elseif s < 2 * 86400 then
    return ("%d h"):format(math.floor(s / 3600))
  end
  return ("%d d"):format(math.floor(s / 86400))
end

---@type table<string, string>
local CI_WORD = {
  success = "ok",
  failure = "FAIL",
  rejected = "rejected",
  cancelled = "cancelled",
  unknown = "?",
  waiting_runner = "no runner",
  queued = "queued",
  running = "running",
  skipped = "skip",
  no_run = "no run",
  no_github = "no GitHub",
  none = "-",
}

---@type table<string, string>
local TONE = {
  proven = "good",
  success = "good",
  red = "bad",
  failure = "bad",
  rejected = "bad",
  cancelled = "warn",
  waiting_runner = "warn",
  queued = "warn",
  running = "warn",
}

local CSS = [[
:root{color-scheme:light dark;--bg:#fbfbfa;--fg:#1d1d1b;--muted:#6b6b66;--line:#e2e1dc;--head:#f1f0ec;
--good:#1f7a3d;--good-bg:#e3f3e8;--bad:#b3261e;--bad-bg:#fbe5e3;--warn:#8a5a00;--warn-bg:#fdf0d5;--link:#1f5fbf}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#e9e8e4;--muted:#a09f99;--line:#33322f;--head:#21201e;
--good:#7fd89a;--good-bg:#173823;--bad:#ff9b92;--bad-bg:#45201d;--warn:#f2c46b;--warn-bg:#3f3115;--link:#8ab4ff}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
h1{font-size:20px;margin:0 0 4px}
.meta{color:var(--muted);margin:0 0 16px}
.filter{margin:0 6px 12px 0}
label{cursor:pointer}
.wrap{overflow-x:auto}
table{border-collapse:collapse;width:100%;min-width:720px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{background:var(--head);font-weight:600;position:sticky;top:0}
td.note{color:var(--muted);max-width:420px}
.s{display:inline-block;padding:1px 8px;border-radius:10px;font-size:12px;white-space:nowrap}
.good{background:var(--good-bg);color:var(--good)}
.bad{background:var(--bad-bg);color:var(--bad);font-weight:600}
.warn{background:var(--warn-bg);color:var(--warn)}
.age{color:var(--muted);font-size:12px;margin-left:4px}
a{color:var(--link)}
#red-only:checked~.wrap tbody tr:not(.red){display:none}
footer{color:var(--muted);margin-top:16px;font-size:12px}
]]

---@param word string
---@param state string
---@param url? string
---@return string
local function badge(word, state, url)
  local tone = TONE[state]
  local inner = ('<span class="s%s">%s</span>'):format(tone and (" " .. tone) or "", esc(word))
  if url then
    return ('<a href="%s">%s</a>'):format(esc(url), inner)
  end
  return inner
end

---The page.
---@param doc table The document `testing-ci-overview/1`.
---@return string
function M.html(doc)
  local c = doc.counts
  local parts = {
    "<!doctype html>",
    '<html lang="en"><head><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">",
    "<title>Fleet overview</title>",
    "<style>" .. CSS .. "</style></head><body>",
    "<h1>Fleet overview</h1>",
    ('<p class="meta">generated <time datetime="%s">%s</time> · %d repositories · local: %d proven, %d red, %d unknown, %d without testing.nvim · CI: %d green, %d red, %d other</p>'):format(
      esc(doc.generated_at),
      esc(doc.generated_at),
      c.repos,
      c["local"].proven,
      c["local"].red,
      c["local"].unknown,
      c["local"].none,
      c.ci.green,
      c.ci.red,
      c.ci.other
    ),
    '<input type="checkbox" id="red-only" class="filter"><label for="red-only">nur rot (red only)</label>',
    '<div class="wrap"><table><thead><tr><th>Repository</th><th>Local</th><th>ubuntu</th><th>windows</th><th>macos</th><th>CI run</th><th>Note</th></tr></thead><tbody>',
  }
  for _, r in ipairs(doc.repos) do
    local l = r["local"]
    local red = l.state == "red" or CI_RED[r.ci.overall]
    local lword = l.state == "none" and "no testing.nvim" or l.state
    local cells = {}
    for i, sys in ipairs(M.OS) do
      local cell = r.ci.os[sys]
      cells[i] = badge(CI_WORD[cell.state] or cell.state, cell.state, cell.url)
    end
    local notes = {}
    for _, n in ipairs({ l.note, r.ci.note }) do
      if n and n ~= "" and n ~= lword then
        notes[#notes + 1] = esc(n)
      end
    end
    parts[#parts + 1] = ('<tr class="%s"><td>%s</td><td>%s<span class="age">%s</span></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class="note">%s</td></tr>'):format(
      red and "red" or "rest",
      esc(r.repo),
      badge(lword, l.state),
      esc(age(l.age_s)),
      cells[1],
      cells[2],
      cells[3],
      r.ci.run_url
          and ('<a href="%s">%s</a>'):format(
            esc(r.ci.run_url),
            esc(CI_WORD[r.ci.overall] or r.ci.overall)
          )
        or esc(CI_WORD[r.ci.overall] or r.ci.overall),
      table.concat(notes, "<br>")
    )
  end
  parts[#parts + 1] = "</tbody></table></div>"
  parts[#parts + 1] = ("<footer>testing ci overview · reads only (ci verify, ci.json, GitHub Actions) · %d left out (vaults and excludes)</footer>"):format(
    #doc.excluded
  )
  parts[#parts + 1] = "</body></html>"
  return table.concat(parts, "\n") .. "\n"
end

---`testing ci overview ...`.
---@param argv string[] The arguments after `overview`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci overview: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local cfg, cfg_problem = M.config(norm("."))
  if cfg_problem then
    sv.err("testing ci overview: " .. cfg_problem .. " (the defaults are used)")
  end
  local dirs, info = M.resolve(args, cfg)
  if not dirs then
    sv.err("testing ci overview: " .. tostring(info))
    return M.EXIT_USAGE
  end
  ---@cast info { excluded: string[], missing: string[] }
  if #dirs == 0 then
    sv.err("testing ci overview: no repository found")
    return M.EXIT_USAGE
  end
  local state_dir = args.state_dir and norm(args.state_dir) or sv.state_dir
  local now = M.deps.now()
  local records =
    M.collect(dirs, { state_dir = state_dir, no_remote = args.no_remote, now = now }, sv)
  local doc = M.document(records, info, now)
  if args.json then
    sv.out(require("lib.nvim.json.canonical").encode(doc))
  end
  if not args.json or args.out then
    local out = args.out and vim.fn.fnamemodify(args.out, ":p")
      or ((state_dir or vim.fn.stdpath("state")) .. "/testing/overview.html")
    out = vim.fs.normalize(out)
    local ok_w, werr = require("lib.nvim.fs.write.atomic")(out, M.html(doc), { mkdirp = true })
    if not ok_w then
      sv.err(("testing ci overview: cannot write %s: %s"):format(out, tostring(werr)))
      return M.EXIT_INFRA
    end
    local c = doc.counts
    sv.out(
      ("ci overview: %d repositories; local %d proven, %d red, %d unknown, %d without testing.nvim; CI %d green, %d red, %d other"):format(
        c.repos,
        c["local"].proven,
        c["local"].red,
        c["local"].unknown,
        c["local"].none,
        c.ci.green,
        c.ci.red,
        c.ci.other
      )
    )
    if #info.excluded > 0 then
      sv.out("ci overview: left out: " .. table.concat(info.excluded, ", "))
    end
    sv.out("ci overview: wrote " .. out)
  end
  if #info.missing > 0 then
    sv.err(
      "testing ci overview: included but not below any --repos-root: "
        .. table.concat(info.missing, ", ")
    )
  end
  return M.EXIT_OK
end

return M
