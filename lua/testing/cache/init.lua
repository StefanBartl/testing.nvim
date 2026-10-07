---@module 'testing.cache'
-- @cache-allow env
---@brief Content-addressed result cache (F1): a spec file whose inputs did not change does not run.
---@description
--- GRANULARITY: one entry per spec FILE (the Result-IR case list of that file). Only a file whose
--- every case passed cleanly is stored; a hit hands the cases back marked `cached = true` with the
--- note `cached from <run id>` (status stays `pass`). A cached case was not executed: it never counts
--- as "ran" for the guards and the effects ledger.
---
--- THE KEY (`M.key`) is the sha256 over
---
---   * the spec path and the content hash of the spec file,
---   * the content hash of every file it depends on, as far as that is KNOWN: the transitive closure
---     of its `require`s (literal names; a computed name `require("a." .. x)` pulls in everything
---     below `a.`, a name nobody can resolve pulls in the whole `lua/` tree of the checkout that
---     contains it), found in the project, `ctx.dep_roots` or the runtime path,
---   * the files it reads (see "Hidden inputs"),
---   * the runner version (a content digest of `lua/testing`, so a dirty checkout differs from a clean one),
---   * the Neovim version, its API level, the OS and the CPU architecture,
---   * the names AND values (hashed) of the environment variables the configuration lists, and of those a file of the
---     closure declares with `-- @cache-env` (`NAME`, `PREFIX_*`, `*_DIR`, `*`),
---   * for a file that runs in a child editor: the environment that child sees, one line per variable,
---   * a digest of the configuration (`ctx.config`) and the content of `.testing.lua`,
---   * the dialect, and the seed when the run is shuffled.
---
--- ONE CALL, ONE EXPLANATION: `key` returns the key, the reason there is none, the lines the key is the hash of
--- (`parts`) and the same reason as data (`detail`: kind, file, line). `testing explain` and the entry that `put`
--- writes (`meta.parts`) use exactly those lines; nothing is computed a second time. A key that has already given
--- different results (`ctx.flipped`, `testing.cache.keylog`) is refused with `detail.kind = "nondeterministic"`.
---
--- INCOMPLETE INPUTS MEAN NO KEY (`key` returns `nil, reason`): when in doubt, do not cache. A spec
--- that
---   * reads the clock or a random number (`os.time`, `hrtime`, `math.random`, ...),
---   * starts a process or touches the network (`vim.system`, `jobstart`, `io.popen`, `curl`, ...),
---   * reads an environment variable that the configuration does not list, or computes a name or reads the whole
---     environment without declaring the variables with `-- @cache-env`,
---   * has a `require` nobody can resolve (unknown module),
---   * has `-- @cache off` in its header, or has dependencies that are too many to hash,
--- is never cached. A spec that reads files gets those files into the key: the non-spec files of its
--- spec root (helpers, fixtures), every path-like string literal that names an existing file or
--- directory below the project root, and what it declares with `-- @cache-inputs <path> ...`.
--- A path computed at run time and not named anywhere is NOT seen: declare it, or use `-- @cache off`.
--- (Cross-repo: files of a dependency repo are covered when its `lua/` is on `ctx.dep_roots` or the
--- runtime path.)
---
--- WHAT IS NEVER STORED (`M.put`): a file with a case that is not a plain pass, was retried, has an
--- effect in the ledger (spawn, network, write outside the temp dir), carries a guard finding, is
--- flaky, timed out or crashed, or ran only part of its cases. A cached entry is validated when read
--- back (`testing.cache.store`); a corrupted or foreign entry is a miss.
---
--- `ctx.mode`: `"use"` (default; read and write), `"off"` (`--no-cache`: the cache is not touched),
--- `"refresh"` (run, write, never read).
---
--- State is per process: `M.counters` and the hashers are cleared IN PLACE by `M.reset` (PERF-47).

local scan = require("testing.affected.scan")
local hash = require("testing.cache.hash")
local store = require("testing.cache.store")

local M = {}

---Bumped when the layout of the key or of an entry changes: every old entry becomes a miss.
---@type integer
M.KEY_VERSION = 1

---Most files hashed into the closure of one spec.
---@type integer
M.MAX_CLOSURE = 3000

---A case that came from the cache: a normal IR case, flagged.
---@class Testing.Cache.Case : Testing.Result.Case
---@field cached? boolean `true`: not executed in this run; never counts as "ran" for the guards and the effects ledger.

---@class Testing.Cache.Counters
---@field hit integer
---@field miss integer
---@field put integer
---@field skipped table<string, integer> Reason -> files (uncacheable, or not stored).

---@type Testing.Cache.Counters
M.counters = { hit = 0, miss = 0, put = 0, skipped = {} }

---@class Testing.Cache.Defaults
---@field root? string
---@field cache_dir? string

---@type Testing.Cache.Defaults
local defaults = {}

---@type table<string, Testing.Cache.Hasher>
local hashers = {}
---@type table<string, boolean>
local pruned = {}
---@type { runner?: string }
local memo = {}

---@class Testing.Cache.Ctx
---@field root string Project root (absolute).
---@field mode? "use"|"off"|"refresh"
---@field cache_dir? string Replaces `stdpath('cache')` (specs, `--cache-dir`).
---@field run_id? string Id of the current run (stored in the entry, shown in the note).
---@field dialect? string Dialect of the file (also taken from `file_info.dialect`).
---@field seed? integer
---@field shuffled? boolean Whether the run is shuffled (then the seed is part of the key).
---@field config? table Effective configuration (hashed).
---@field config_digest? string Replaces the hash of `config`.
---@field env_names? string[] Environment names (or `PREFIX*`) that are part of the key.
---@field environ? fun(): table<string, string> Replaces `vim.fn.environ` (specs).
---@field env_case_insensitive? boolean Environment names are case-insensitive (default: on Windows only); specs set it.
---@field nvim? string Replaces the Neovim version string (specs).
---@field runner_version? string Replaces the runner digest (specs).
---@field dep_roots? string[] Directories whose `lua/` resolves modules outside the project (default: the runtime path).
---@field spec_pattern? string[] Lua patterns of spec files (default `_spec%.lua$`).
---@field spec_roots? string[] Spec roots relative to the root (default: the first path component of the spec).
---@field restricted? boolean A case selection (`--filter`, `--lf`, ...) is active: the file does not run completely.
---@field hasher? Testing.Cache.Hasher
---@field prune? boolean Prune once per process after the first write (default true).
---@field unresolved? "error"|"absent" A `require` that no checkout resolves: `error` (default) = the file has no key, `absent` = its absence is part of the key (right for optional plugins checked with `pcall(require, ...)`, provided the runtime path is the one the run uses).
---@field flipped? fun(file: string, key: string): { classes: string[] }|nil Key-flip lookup: the results the same key has given before when they differ (`testing.cache.keylog`); a file for which it answers is not cached.
---@field memo? table Directory listings and module lookups of THIS run; created on first use. Make a new context per run (a watch loop: per iteration), or a new file is not seen.

---@class Testing.Cache.FileInfo
---@field file string Spec file relative to the root, `/` separators.
---@field dialect? string
---@field deps? string[] Dependencies known from a graph (project-relative); with `deps_complete` they replace the scan.
---@field deps_complete? boolean
---@field child_env? string|string[] The environment a child editor of this file sees from the parent (lines `NAME=<sha256 of the value>`, or one digest; see `testing.run.cached.child_env_lines`): the file runs in a child, so EVERY variable it can read is part of the key and none is judged by name.
---@field extra? string[] Files that decide what the spec does without being required by it (the project's `minit`, the harness of a dialect-h spec): relative to the root or absolute, hashed into the key.

---@class Testing.Cache.Flags
---@field cached? boolean `--cached`: reuse results (and store new ones).
---@field no_cache? boolean `--no-cache`: the cache is not touched. Wins over everything else, always.
---@field refresh? boolean `--cache-refresh`: run everything, store the results, never read.
---@field config_cached? boolean `.testing.lua` switched the cache on by default.

---The mode of a run from the command-line flags: `off` unless asked for, `--no-cache` always wins.
---@param flags Testing.Cache.Flags
---@return "use"|"off"|"refresh" mode
function M.resolve_mode(flags)
  if flags.no_cache then
    return "off"
  end
  if flags.refresh then
    return "refresh"
  end
  if flags.cached or flags.config_cached then
    return "use"
  end
  return "off"
end

---Reset the per-process state in place (specs, `--cache-clear`).
function M.reset()
  M.counters.hit, M.counters.miss, M.counters.put = 0, 0, 0
  for k in pairs(M.counters.skipped) do
    M.counters.skipped[k] = nil
  end
  for k in pairs(hashers) do
    hashers[k] = nil
  end
  for k in pairs(pruned) do
    pruned[k] = nil
  end
  memo.runner = nil
  for k in pairs(defaults) do
    defaults[k] = nil
  end
end

---Set the defaults of `get`/`put`/`stats`/`prune`/`clear` when they are called without a context.
---@param opts Testing.Cache.Defaults
function M.configure(opts)
  defaults.root = opts.root
  defaults.cache_dir = opts.cache_dir
end

---@param ctx? { root?: string, cache_dir?: string, dir?: string }
---@return string dir
local function dir_of(ctx)
  ctx = ctx or {}
  if ctx.dir then
    return ctx.dir
  end
  local root = ctx.root or defaults.root or (vim.uv.cwd() or ".")
  return store.dir(root, { cache_dir = ctx.cache_dir or defaults.cache_dir })
end

---@param ctx { root?: string, cache_dir?: string, dir?: string, hasher?: Testing.Cache.Hasher }
---@return Testing.Cache.Hasher
local function hasher_of(ctx)
  if ctx.hasher then
    return ctx.hasher
  end
  local dir = dir_of(ctx)
  local h = hashers[dir]
  if not h then
    h = hash.new(dir .. "/index.json")
    hashers[dir] = h
  end
  return h
end

---@param reason string
local function skipped(reason)
  local key = reason:gsub("'[^']*'", "'*'"):gsub("%d+", "N")
  M.counters.skipped[key] = (M.counters.skipped[key] or 0) + 1
end

---The version of the runner: a content digest of `lua/testing` (a dirty checkout differs from a clean one).
---@param ctx { hasher?: Testing.Cache.Hasher }
---@return string
function M.runner_version(ctx)
  if memo.runner then
    return memo.runner
  end
  local here = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
  local runner_dir = vim.fs.dirname(vim.fs.dirname(here)) -- .../lua/testing
  local digest = hasher_of(ctx):tree(runner_dir)
  memo.runner = digest or ("unhashable:" .. runner_dir)
  return memo.runner
end

---@param ctx Testing.Cache.Ctx
---@return string
local function nvim_version(ctx)
  if ctx.nvim then
    return ctx.nvim
  end
  local v = vim.version()
  local jit_os = (jit and jit.os) or "?"
  local jit_arch = (jit and jit.arch) or "?"
  -- `api_info().version.api_level` is the API level; `api_info().api_level` does not exist (it was nil, and
  -- the key carried the word "apinil")
  local info = vim.fn.api_info()
  local level = type(info) == "table" and type(info.version) == "table" and info.version.api_level
    or nil
  return ("%s|api%s|%s|%s"):format(tostring(v), level and tostring(level) or "?", jit_os, jit_arch)
end

---Are environment variable names case-insensitive here? On Windows they are (the system reports them in upper
---case, and `os.getenv("MyVar")` finds `MYVAR`), elsewhere not. `ctx.env_case_insensitive` overrides (specs).
---@param ctx Testing.Cache.Ctx
---@return boolean
local function env_ci(ctx)
  if ctx.env_case_insensitive ~= nil then
    return ctx.env_case_insensitive == true
  end
  return vim.fn.has("win32") == 1
end

---Environment part of the key: `NAME=sha256(value)` for every listed name (a `PREFIX*` entry expands
---over the names that are set). Where names are case-insensitive (Windows) the name is looked up and written in
---upper case: a listed `MyVar` must see the value of `MYVAR` (the system's spelling), or a changed value would
---read as `<unset>` before and after and the key would not change.
---@param ctx Testing.Cache.Ctx
---@param extra? table<string, true> More names (read by modules of the project).
---@return string[] lines
---@return table<string, true> names
local function env_lines(ctx, extra)
  local environ = (ctx.environ or vim.fn.environ)()
  local ci = env_ci(ctx)
  local function norm(n)
    return ci and n:upper() or n
  end
  local names = {}
  ---One listed name or pattern: a plain name, `PREFIX*`, or a pattern with `*` anywhere (`*_DIR`, `A*B`; `*`
  ---alone is the whole environment). The pattern itself is part of the key (`*<pattern>`): a new variable that
  ---it matches changes the key.
  ---@param entry string
  local function list(entry)
    if not entry:find("*", 1, true) then
      names[norm(entry)] = true
      return
    end
    local pat = norm(entry)
    local head = pat:sub(1, -2)
    local lua_pat
    if pat:sub(-1) == "*" and not head:find("*", 1, true) then
      lua_pat = "^" .. vim.pesc(head)
      names["*" .. head] = true
    else
      lua_pat = "^" .. vim.pesc(pat):gsub("%%%*", ".*") .. "$"
      names["*" .. pat] = true
    end
    for name in pairs(environ) do
      -- `=C:` and friends: Windows keeps the per-drive working directory in hidden variables that no `getenv`
      -- returns and that move with every `chdir` of the run (the key would never survive its own run)
      if name:sub(1, 1) ~= "=" and norm(name):find(lua_pat) then
        names[norm(name)] = true
      end
    end
  end
  for name in pairs(extra or {}) do
    list(name)
  end
  for _, entry in ipairs(ctx.env_names or {}) do
    if type(entry) == "string" then
      list(entry)
    end
  end
  local sorted = {}
  for n in pairs(names) do
    sorted[#sorted + 1] = n
  end
  table.sort(sorted)
  local upper
  if ci then
    upper = {}
    for k, v in pairs(environ) do
      upper[k:upper()] = v
    end
  end
  local lines = {}
  for _, n in ipairs(sorted) do
    local v = environ[n]
    if v == nil and upper then
      v = upper[n]
    end
    lines[#lines + 1] = ("env %s=%s"):format(n, v and vim.fn.sha256(v) or "<unset>")
  end
  return lines, names
end

---Is `name` listed (exactly or by prefix) in the environment names of the context?
---@param ctx Testing.Cache.Ctx
---@param name string
---@return boolean
local function env_listed(ctx, name)
  local ci = env_ci(ctx)
  if ci then
    name = name:upper()
  end
  for _, entry in ipairs(ctx.env_names or {}) do
    if type(entry) == "string" then
      if ci then
        entry = entry:upper()
      end
      if entry == name then
        return true
      end
      if entry:sub(-1) == "*" and name:sub(1, #entry - 1) == entry:sub(1, -2) then
        return true
      end
    end
  end
  return false
end

---Does a `-- @cache-env` declaration of the file name the variable? (an exact name, `PREFIX_*`, `*_DIR`, `*`)
---@param declared string[]
---@param name string
---@param ci boolean Names are case-insensitive here.
---@return boolean
local function env_declared(declared, name, ci)
  if ci then
    name = name:upper()
  end
  for _, d in ipairs(declared) do
    if ci then
      d = d:upper()
    end
    if
      d == name
      or (d:find("*", 1, true) and name:find("^" .. vim.pesc(d):gsub("%%%*", ".*") .. "$"))
    then
      return true
    end
  end
  return false
end

---Lua files below `<base>/lua/<dir>` whose base name starts with `stem` (relative to `<base>`).
---@param listings table<string, any>
---@param base string
---@param dir string `a/b` ('' = all)
---@param stem string
---@return string[]
local function list_lua(listings, base, dir, stem)
  local ck = base .. "|" .. dir .. "|" .. stem
  if listings[ck] then
    return listings[ck]
  end
  local out = {}
  local top = base .. "/lua" .. (dir ~= "" and ("/" .. dir) or "")
  if vim.fn.isdirectory(top) == 1 then
    for _, p in ipairs(require("lib.nvim.fs.collect_recursive").files(top)) do
      p = vim.fs.normalize(p)
      if p:sub(-4) == ".lua" then
        local name = p:match("([^/]+)$")
        if stem == "" or name:sub(1, #stem) == stem or p:sub(#top + 2):find("/", 1, true) then
          out[#out + 1] = p
        end
      end
    end
  end
  table.sort(out)
  listings[ck] = out
  return out
end

---Bases (project root, then the dependency roots) in resolution order.
---@param ctx Testing.Cache.Ctx
---@return string[]
local function bases_of(ctx)
  local first = vim.fs.normalize(ctx.root):gsub("/+$", "")
  local bases, seen = { first }, { [first] = true }
  local extra = ctx.dep_roots
  if extra == nil then
    local ok, rtp = pcall(vim.api.nvim_list_runtime_paths)
    extra = ok and rtp or {}
  end
  for _, b in ipairs(extra) do
    b = vim.fs.normalize(b):gsub("/+$", "")
    if not seen[b] then
      seen[b] = true
      bases[#bases + 1] = b
    end
  end
  return bases
end

---@param listings table<string, any>
---@param name string
---@param bases string[]
---@param ctx? Testing.Cache.Ctx
---@return string|nil abs
---@return string|nil base
local function resolve_module(listings, name, bases, ctx)
  local ck = "resolve|" .. name .. "|" .. table.concat(bases, ";")
  local hit = listings[ck]
  if hit ~= nil then
    return hit[1] or nil, hit[2]
  end
  for _, base in ipairs(bases) do
    for _, rel in ipairs(scan.candidates(name)) do
      local st = vim.uv.fs_stat(base .. "/" .. rel)
      if st and st.type == "file" then
        listings[ck] = { base .. "/" .. rel, base }
        return base .. "/" .. rel, base
      end
    end
  end
  -- helpers of the spec tree (`TESTS/harness.lua` for `require("harness")`): the specs put their root on
  -- `package.path`, which is not a runtime-path entry
  local path = name:gsub("%.", "/")
  for _, sr in ipairs((ctx and ctx.spec_roots) or {}) do
    sr = sr:gsub("\\", "/"):gsub("/+$", "")
    for _, rel in ipairs({ sr .. "/" .. path .. ".lua", sr .. "/" .. path .. "/init.lua" }) do
      local st = vim.uv.fs_stat(bases[1] .. "/" .. rel)
      if st and st.type == "file" then
        listings[ck] = { bases[1] .. "/" .. rel, bases[1] }
        return bases[1] .. "/" .. rel, bases[1]
      end
    end
  end
  -- a rock or any other `package.path` entry of this process
  local found = package.searchpath(name, package.path)
  if found then
    found = vim.fs.normalize(found)
    listings[ck] = { found, vim.fs.dirname(found) }
    return found, vim.fs.dirname(found)
  end
  listings[ck] = {}
  return nil, nil
end

---Is `abs` a file of the project itself (not of a dependency checkout that happens to live below the root)?
---@param root string
---@param abs string
---@return boolean
local function is_project_file(root, abs)
  return abs:sub(1, #root + 1) == root .. "/"
    and abs:sub(#root + 2, #root + 7) ~= ".deps/"
    and abs:sub(#root + 2, #root + 14) ~= "node_modules/"
end

---A table of this run's memo (`ctx.memo`): hashes, analyses and directory digests are computed once per run.
---@param ctx Testing.Cache.Ctx
---@param name string
---@return table
local function memo_table(ctx, name)
  ctx.memo = ctx.memo or {}
  local t = ctx.memo[name]
  if not t then
    t = {}
    ctx.memo[name] = t
  end
  return t
end

---`hasher:analyzed` once per file and run (two `stat` calls and a normalization are the cost of a key).
---@param ctx Testing.Cache.Ctx
---@param hasher Testing.Cache.Hasher
---@param abs string
---@return string|nil sha
---@return Testing.Scan.Info|string info
local function analyzed(ctx, hasher, abs)
  local t = memo_table(ctx, "#analyzed")
  local hit = t[abs]
  if hit then
    return hit[1], hit[2]
  end
  local sha, info = hasher:analyzed(abs)
  t[abs] = { sha, info }
  return sha, info
end

---`hasher:file` once per file and run.
---@param ctx Testing.Cache.Ctx
---@param hasher Testing.Cache.Hasher
---@param abs string
---@return string|nil sha
---@return string|nil why
local function sha_of(ctx, hasher, abs)
  local t = memo_table(ctx, "#sha")
  local hit = t[abs]
  if hit then
    return hit[1], hit[2]
  end
  local sha, why = hasher:file(abs)
  t[abs] = { sha, why }
  return sha, why
end

---`hasher:tree` once per directory and run.
---@param ctx Testing.Cache.Ctx
---@param hasher Testing.Cache.Hasher
---@param dir string
---@param variant string Names the `opts` (the memo key).
---@param opts? table
---@return string|nil digest
---@return string|nil why
local function tree_of(ctx, hasher, dir, variant, opts)
  local t = memo_table(ctx, "#tree")
  local k = variant .. "|" .. dir
  local hit = t[k]
  if hit then
    return hit[1], hit[2]
  end
  local dig, why = hasher:tree(dir, opts)
  t[k] = { dig, why }
  return dig, why
end

---Closure of the files a spec depends on. Returns a sorted list of absolute paths and the digest
---lines, or nil and why (incomplete).
---@param file_info Testing.Cache.FileInfo
---@param spec_info Testing.Scan.Info
---@param ctx Testing.Cache.Ctx
---@param hasher Testing.Cache.Hasher
---@return string[]|nil lines
---@return string|nil why
---@return boolean|nil absent_any A `require` was unresolved and its absence is part of the key.
---@return Testing.Cache.Member[]|nil members The files of the closure (not the spec) with their analysis.
---@return Testing.Cache.Detail|nil detail The structured form of `why`.
local function closure_lines(file_info, spec_info, ctx, hasher)
  local root = vim.fs.normalize(ctx.root):gsub("/+$", "")
  local lines = {}
  if file_info.deps_complete and type(file_info.deps) == "table" then
    local deps = vim.deepcopy(file_info.deps) or {}
    table.sort(deps)
    for _, rel in ipairs(deps) do
      local sha = sha_of(ctx, hasher, root .. "/" .. rel)
      lines[#lines + 1] = ("dep %s=%s"):format(rel, sha or "<absent>")
    end
    return lines, nil, false, {}
  end
  local bases = bases_of(ctx)
  local listings = memo_table(ctx, "#listings")
  local files, order = {}, {}
  local members = {}
  local queue = {}
  local absent = {}
  ---@type Testing.Cache.Detail|nil
  local fail_detail
  ---@param abs string
  ---@param base string
  local function visit(abs, base)
    if not files[abs] then
      files[abs] = base
      order[#order + 1] = abs
      queue[#queue + 1] = abs
    end
  end
  ---@param info Testing.Scan.Info
  ---@param base string
  ---@return string|nil why
  local function expand(info, base)
    for _, name in ipairs(info.requires) do
      local top = name:match("^[^.]+")
      local abs, from = resolve_module(listings, name, bases, ctx)
      if abs and from then
        visit(abs, from)
      elseif not (scan.BUILTIN[top] or top == "vim" or top == "testing") then
        if ctx.unresolved ~= "absent" then
          fail_detail = { kind = "unresolved", name = name }
          return ("unresolved module '%s'"):format(name)
        end
        absent[name] = true -- its absence is part of the key: installing it changes the key
      end
    end
    for _, pfx in ipairs(info.prefixes) do
      local dir, stem = pfx:match("^(.*)%.([^.]*)$")
      dir, stem = dir or "", stem or pfx
      for _, b in ipairs(bases) do
        for _, abs in ipairs(list_lua(listings, b, (dir:gsub("%.", "/")), stem)) do
          visit(abs, b)
        end
      end
    end
    if info.dynamic then
      for _, abs in ipairs(list_lua(listings, base, "", "")) do
        visit(abs, base)
      end
    end
    return nil
  end
  local why = expand(spec_info, root)
  if why then
    return nil, why, nil, nil, fail_detail
  end
  local i = 1
  while i <= #queue do
    local abs = queue[i]
    i = i + 1
    if #order > M.MAX_CLOSURE then
      return nil,
        ("more than %d dependency files"):format(M.MAX_CLOSURE),
        nil,
        nil,
        { kind = "closure" }
    end
    local sha, info = analyzed(ctx, hasher, abs)
    if not sha then
      return nil,
        ("dependency %s: %s"):format(abs, tostring(info)),
        nil,
        nil,
        { kind = "dependency", name = abs:match("([^/]+)$") }
    end
    ---@cast info Testing.Scan.Info
    members[#members + 1] = { abs = abs, info = info, inside = is_project_file(root, abs) }
    local w = expand(info, files[abs])
    if w then
      -- a module of a dependency that the runtime path cannot resolve: the dependency is incomplete
      return nil,
        w .. " (required by " .. abs:match("([^/]+)$") .. ")",
        nil,
        nil,
        fail_detail and vim.tbl_extend("force", fail_detail, { file = abs:match("([^/]+)$") })
    end
  end
  local absent_names = vim.tbl_keys(absent)
  table.sort(absent_names)
  local absent_any = #absent_names > 0
  for _, name in ipairs(absent_names) do
    lines[#lines + 1] = "absent " .. name
  end
  table.sort(order)
  for _, abs in ipairs(order) do
    local sha = sha_of(ctx, hasher, abs)
    local shown
    if abs:sub(1, #root + 1) == root .. "/" then
      shown = abs:sub(#root + 2)
    else
      shown = "ext:"
        .. (abs:match("([^/]+/[^/]+/[^/]+)$") or abs)
        .. ":"
        .. vim.fn.sha256(abs):sub(1, 8)
    end
    lines[#lines + 1] = ("dep %s=%s"):format(shown, sha or "<absent>")
  end
  return lines, nil, absent_any, members
end

---Why a file has no key, in a form a program can read (`testing explain`): `kind` is one of `clock`, `random`,
---`process`, `network`, `env`, `env_dynamic`, `off` (`-- @cache off`), `unresolved` (a `require` nobody resolves),
---`closure` (too many files), `outside` (reads a file outside the project), `inputs` (cannot hash what it reads),
---`nondeterministic` (the key-flip detection), `spec` (the file cannot be read), `path` (the path leaves the project).
---@class Testing.Cache.Detail
---@field kind string
---@field file? string The file that has it: nil is the spec itself.
---@field line? integer Line of the hit in that file (clock, random, process, network).
---@field name? string An environment variable, a module, a path.
---@field key? string `nondeterministic`: the key that gave different results.
---@field classes? string[] `nondeterministic`: the results it gave.
---@field allow_nondeterministic? boolean With a key: the spec declares `-- @cache-allow nondeterministic`.
---@field flipped? string[] With a key: the results the key has given when they differ.
---@field vouched? Testing.Cache.Vouched[] With a key: the directives of the closure (`-- @cache-allow ...`, `-- @cache-env ...`) that vouch for what the scanner cannot see.

---A directive the author wrote to vouch for an input: `testing explain` and the audit say so.
---@class Testing.Cache.Vouched
---@field directive string `@cache-allow time`, `@cache-env *`, ...
---@field file string The file that carries it (relative to the root where possible).

---@class Testing.Cache.Member
---@field abs string
---@field info Testing.Scan.Info
---@field inside boolean The file belongs to the project (not to a dependency checkout).

---What the files of a closure do together: a hidden input of ANY file the spec loads is a hidden input of the
---spec (the clock read by a helper makes the spec's verdict depend on the clock).
---@class Testing.Cache.Aggregate
---@field io boolean Some file of the closure reads files.
---@field dirscan boolean Some file lists directories.
---@field dynload boolean Project code loads files by ex command or runtime-path lookup.
---@field pathmod boolean Project code changes the module search path or the runtime path.
---@field outside boolean Project code names a place outside the project.
---@field outside_literals { lit: string, dir: string }[] What it names, and the directory of the file that names it (a relative literal is read from there as well as from the root).
---@field readers Testing.Cache.Member[] Project files of the closure that read files.
---@field vouched Testing.Cache.Vouched[] The directives of the project files of the closure.
---@field env table<string, true> Environment variables that modules of the project read by a literal name and the configuration does not list: their values join the key.

---Directory names a digest of the whole project does not enter.
---@type table<string, true>
local PROJECT_IGNORE = {
  [".git"] = true,
  [".deps"] = true,
  [".cache"] = true,
  ["node_modules"] = true,
}

---Does a literal that names a place outside the project name a file that EXISTS there? A string like `"../x"` is
---often a test of a path function and no read at all; one that resolves to a real file outside the root, read from the
---root or from the directory of the file that names it, is a hidden input the key cannot see. A literal that names
---nothing yet is part of the key as absent: creating the file changes the key.
---@param root string
---@param literals { lit: string, dir: string }[]
---@return string|nil present The literal that names an existing file or directory outside the project.
---@return string[] lines Key lines for the literals that name nothing.
local function outside_files(root, literals)
  local lines, seen = {}, {}
  local real_root = vim.uv.fs_realpath(root) or root
  local is_subpath = require("lib.nvim.fs.is_subpath")
  for _, item in ipairs(literals) do
    local lit = item.lit
    -- an absolute spelling names that place; a relative one (and one with a leading slash, which specs write
    -- as `root .. "/../x"`) is read from the root and from the directory of the file that names it
    local candidates = {}
    local stripped = lit:gsub("^[/\\]+", "")
    if lit:find("^%a:[/\\]") or lit:find("^[/\\]") then
      candidates[#candidates + 1] = lit
    end
    if lit:find("^~") then
      candidates[#candidates + 1] = vim.fn.expand(lit)
    else
      candidates[#candidates + 1] = root .. "/" .. stripped
      candidates[#candidates + 1] = item.dir .. "/" .. stripped
    end
    local any = false
    for _, cand in ipairs(candidates) do
      local real = vim.uv.fs_realpath(cand)
      if real then
        any = true
        if not is_subpath(vim.fs.normalize(real), vim.fs.normalize(real_root), {}) then
          return lit, {}
        end
      end
    end
    if not any and not seen[lit] then
      seen[lit] = true
      lines[#lines + 1] = ("outside-absent %s"):format(lit)
    end
  end
  table.sort(lines)
  return nil, lines
end

---Check the hidden inputs of the spec AND of every file it loads.
---@param spec_info Testing.Scan.Info
---@param spec_abs string Absolute path of the spec file.
---@param members Testing.Cache.Member[]
---@param ctx Testing.Cache.Ctx
---@param env_covered boolean The environment the file sees is in the key as a whole (a child editor).
---@return Testing.Cache.Aggregate|nil agg
---@return string|nil reason No key: why.
---@return Testing.Cache.Detail|nil detail The structured form of the reason.
local function aggregate(spec_info, spec_abs, members, ctx, env_covered)
  ---@type Testing.Cache.Detail|nil
  local detail
  local agg = {
    io = false,
    dirscan = false,
    dynload = false,
    pathmod = false,
    outside = false,
    outside_literals = {},
    readers = {},
    vouched = {},
    env = {},
  }
  local root_prefix = ctx.root and (vim.fs.normalize(ctx.root):gsub("/+$", "") .. "/") or nil
  ---@param abs string
  ---@return string
  local function shown(abs)
    abs = abs:gsub("\\", "/")
    if root_prefix and abs:sub(1, #root_prefix):lower() == root_prefix:lower() then
      return abs:sub(#root_prefix + 1)
    end
    return abs:match("([^/]+)$") or abs
  end
  ---@param info Testing.Scan.Info
  ---@param who string|nil Nil for the spec itself.
  ---@param inside boolean
  ---@param abs? string
  ---@return string|nil reason
  local function take(info, who, inside, abs, dir)
    local function say(what)
      if who then
        return ("a file the spec loads %s ('%s')"):format(what, who)
      end
      return what
    end
    ---The reason and its structured form (`kind`, the file that has it, the line of the hit).
    ---@param kind string
    ---@param what string
    ---@param marker? string Key of `info.where`.
    ---@param name? string
    ---@return string
    local function no(kind, what, marker, name)
      detail = {
        kind = kind,
        file = who,
        line = marker and info.where and info.where[marker] or nil,
        name = name,
      }
      return say(what)
    end
    local m = info.markers
    if info.directives.off then
      detail = { kind = "off", file = who }
      return who and say("has `-- @cache off`") or "`-- @cache off`"
    end
    -- only the files of the PROJECT contribute hidden inputs. A dependency checkout (`lib.nvim`: clock for
    -- timers and log stamps, `vim.system` for helpers nobody calls in this spec) is hashed as a whole and
    -- tested in its own repository; judging its every helper would leave nothing cacheable.
    local allow = {}
    for _, w in ipairs(info.directives.allow or {}) do
      allow[w] = true
    end
    if inside then
      local at = shown(abs or spec_abs)
      for _, w in ipairs(info.directives.allow or {}) do
        agg.vouched[#agg.vouched + 1] = { directive = "@cache-allow " .. w, file = at }
      end
      if #(info.directives.env or {}) > 0 then
        agg.vouched[#agg.vouched + 1] =
          { directive = "@cache-env " .. table.concat(info.directives.env, " "), file = at }
      end
      -- the clock and random numbers count for the spec itself only: in a module they are timers, throttles
      -- and log stamps far more often than the value a spec asserts on (a KNOWN LIMIT, see docs/CACHE.md)
      if not who and m.time and not allow.time then
        return no("clock", "reads the clock", "time")
      end
      if not who and m.random and not allow.random then
        return no("random", "uses random numbers", "random")
      end
      -- a process or a connection that a module of the project really starts is seen by the effects ledger of the
      -- run (`put` refuses a file with such an effect); only the spec's own calls are judged statically
      if not who and m.spawn and not allow.spawn then
        return no("process", "starts a process", "spawn")
      end
      if not who and m.net and not allow.net then
        return no("network", "may use the network", "net")
      end
      if not env_covered then
        -- `-- @cache-env <names|patterns|*>`: the author names the variables a computed read can reach (`*`: the
        -- whole environment): their values join the key, so the read is no hidden input any more
        local declared = info.directives.env or {}
        local whole_declared = false
        for _, d in ipairs(declared) do
          agg.env[d] = true
          whole_declared = whole_declared or d == "*"
        end
        -- `-- @cache-allow env`: the author vouches that what a spec sees does not depend on the outer values of the
        -- variables this file reads by a computed name or as a whole (a snapshot that is compared with itself, a
        -- redaction of the user name): declared names still join the key
        if allow.env then
          whole_declared = true
        elseif m.env_computed and #declared == 0 then
          return no("env_dynamic", "reads the environment by a computed name")
        end
        if m.env_whole and not whole_declared then
          return no("env_dynamic", "reads the whole environment")
        end
        for _, name in ipairs(m.env) do
          if not env_listed(ctx, name) and not env_declared(declared, name, env_ci(ctx)) then
            if who then
              agg.env[name] = true -- a module of the project: the value joins the key
            else
              return no(
                "env",
                ("reads environment variable '%s' that is not part of the key"):format(name),
                nil,
                name
              )
            end
          end
        end
      end
    end
    if m.io and inside then
      agg.io = true
      if abs then
        agg.readers[#agg.readers + 1] = { abs = abs, info = info, inside = true }
      end
    end
    if inside then
      agg.dirscan = agg.dirscan or m.dirscan
      agg.dynload = agg.dynload or m.dynload
      agg.pathmod = agg.pathmod or m.pathmod
      -- `-- @cache-allow outside`: the author vouches that the places outside the project this file names
      -- (`".."` in path arithmetic, a sibling-checkout lookup) are not read for what a spec sees
      if not allow.outside then
        agg.outside = agg.outside or m.outside
        for _, lit in ipairs(info.outside_paths or {}) do
          agg.outside_literals[#agg.outside_literals + 1] = { lit = lit, dir = dir }
        end
      end
    end
    return nil
  end
  local why = take(spec_info, nil, true, nil, vim.fs.dirname(spec_abs))
  if why then
    return nil, why, detail
  end
  for _, mem in ipairs(members) do
    local w =
      take(mem.info, mem.abs:match("([^/]+)$"), mem.inside, mem.abs, vim.fs.dirname(mem.abs))
    if w then
      return nil, w, detail
    end
  end
  return agg, nil
end

---Files and directories a spec reads: the support files of its spec root, path literals that exist
---below the root, the directories of project modules that read files, declared inputs, and (when the spec
---loads code by a path the scanner cannot follow) the whole project.
---@param file_info Testing.Cache.FileInfo
---@param spec_info Testing.Scan.Info
---@param ctx Testing.Cache.Ctx
---@param hasher Testing.Cache.Hasher
---@param agg Testing.Cache.Aggregate
---@param force_tree? boolean Take the spec root in as the spec reads files (a module nobody resolved may live there).
---@return string[]|nil lines
---@return string|nil why
local function input_lines(file_info, spec_info, ctx, hasher, agg, force_tree)
  local root = vim.fs.normalize(ctx.root):gsub("/+$", "")
  local lines = {}
  local patterns = ctx.spec_pattern or { "_spec%.lua$" }
  local function is_spec(rel)
    for _, p in ipairs(patterns) do
      if rel:find(p) then
        return true
      end
    end
    return false
  end
  local declared = spec_info.directives.inputs
  local reads = spec_info.markers.io or agg.io
  if not (reads or #declared > 0 or force_tree) then
    return lines
  end
  -- a spec that lists directories may be looking at the other specs (a lint spec): they are inputs then
  local skip_specs = not agg.dirscan
  local tree_opts = {
    skip = skip_specs and function(r)
      return is_spec(r)
    end or nil,
  }
  local variant = skip_specs and "noskip" or "all"
  -- code that is loaded by a path nobody can follow (`:runtime`, `:source`, a module found through a path the
  -- spec itself sets): every file of the project is an input
  local whole_project = agg.dynload or (agg.pathmod and force_tree)
  if whole_project then
    local dig, why = tree_of(ctx, hasher, root, "project", { ignore_dirs = PROJECT_IGNORE })
    if not dig then
      return nil,
        "loads files the key cannot follow, and the project is too large to hash: " .. tostring(why)
    end
    lines[#lines + 1] = "input <project>/=" .. dig
  end
  -- support files of the spec root
  local spec_root = file_info.file:match("^([^/]+)/")
  for _, r in ipairs(ctx.spec_roots or {}) do
    local rr = r:gsub("\\", "/"):gsub("/+$", "")
    if file_info.file:sub(1, #rr + 1) == rr .. "/" then
      spec_root = rr
      break
    end
  end
  local seen = {}
  ---@param rel string
  ---@param strict boolean A declared input that is missing is an error, a guessed one is skipped.
  ---@return string|nil why
  local function add(rel, strict)
    if seen[rel] then
      return nil
    end
    seen[rel] = true
    local abs = root .. "/" .. rel
    local st = vim.uv.fs_stat(abs)
    if not st then
      if strict then
        lines[#lines + 1] = ("input %s=<absent>"):format(rel)
      end
      return nil
    end
    if st.type == "file" then
      local sha, why = sha_of(ctx, hasher, abs)
      if not sha then
        return ("input %s: %s"):format(rel, tostring(why))
      end
      lines[#lines + 1] = ("input %s=%s"):format(rel, sha)
    elseif st.type == "directory" then
      local dig, why = tree_of(ctx, hasher, abs, variant, tree_opts)
      if not dig then
        return ("input %s: %s"):format(rel, tostring(why))
      end
      lines[#lines + 1] = ("input %s/=%s"):format(rel, dig)
    end
    return nil
  end
  if (reads or force_tree) and spec_root then
    local w = add(spec_root, false)
    if w then
      return nil, w
    end
  end
  ---@param info Testing.Scan.Info
  ---@return string|nil why
  local function add_literals(info)
    for _, lit in ipairs(info.paths) do
      if not lit:find("^%.%.") then
        local rel = lit:gsub("^/+", ""):gsub("^%./", "")
        local standard = rel:find("^lua/.*%?") ~= nil -- `lua/?.lua`: the closure resolves modules
        rel = rel:gsub("[%*%?%[].*$", "") -- a glob: its fixed head
        rel = rel:gsub("/+$", "")
        -- a partial name (`a/b_`): the directory it lives in
        if
          rel ~= ""
          and not rel:find("..", 1, true)
          and vim.uv.fs_stat(root .. "/" .. rel) == nil
        then
          rel = rel:match("^(.*)/[^/]*$") or ""
        end
        if not standard and rel ~= "" and rel ~= "." and not rel:find("..", 1, true) then
          local w = add(rel, false)
          if w then
            return w
          end
        end
      end
    end
    return nil
  end
  if spec_info.markers.io or agg.io then
    local w = add_literals(spec_info)
    if w then
      return nil, w
    end
    -- the literals of project modules that read files, and the data that lies next to them
    for _, rd in ipairs(agg.readers) do
      w = add_literals(rd.info)
      if w then
        return nil, w
      end
      local dir = vim.fs.dirname(rd.abs)
      local rel = dir:sub(#root + 2)
      if rel ~= "" and not seen[rel] then
        seen[rel] = true
        local dig, why = tree_of(ctx, hasher, dir, "data", {
          skip = function(r)
            return r:sub(-4) == ".lua" -- code is covered by the closure
          end,
        })
        if not dig then
          return nil, ("input %s: %s"):format(rel, tostring(why))
        end
        lines[#lines + 1] = ("data %s/=%s"):format(rel, dig)
      end
    end
  end
  for _, rel in ipairs(declared) do
    if rel:find("..", 1, true) or rel:find("^/") or rel:find("^%a:") then
      return nil, ("declared input '%s' is outside the project"):format(rel)
    end
    local w = add((rel:gsub("/+$", "")), true)
    if w then
      return nil, w
    end
  end
  table.sort(lines)
  return lines
end

---The key of a spec file, or nil and the reason why it cannot be cached.
---@param file_info Testing.Cache.FileInfo
---@param ctx Testing.Cache.Ctx
---@return string|nil key
---@return string|nil reason
---@return string[]|nil parts The lines the key is the hash of: the ONE source of the explanation (`testing explain`, the entry's `parts`). Also returned with a `nondeterministic` refusal (then the key is in `detail.key`); nil for every other refusal.
---@return Testing.Cache.Detail|nil detail Why there is no key, in a form a program can read; with a key: `allow_nondeterministic` (the spec declares `-- @cache-allow nondeterministic`) and `flipped` (the results the key has given when they differ, and the spec may be cached all the same).
function M.key(file_info, ctx)
  if
    type(file_info) ~= "table"
    or type(file_info.file) ~= "string"
    or type(ctx) ~= "table"
    or not ctx.root
  then
    return nil, "no file or root", nil, { kind = "input" }
  end
  local root = vim.fs.normalize(ctx.root):gsub("/+$", "")
  local rel = file_info.file:gsub("\\", "/")
  if rel:find("..", 1, true) or rel:find("^/") or rel:find("^%a:") then
    return nil, "spec path leaves the project", nil, { kind = "path" }
  end
  local hasher = hasher_of(ctx)
  local sha, info = analyzed(ctx, hasher, root .. "/" .. rel)
  if not sha then
    return nil, "spec file: " .. tostring(info), nil, { kind = "spec" }
  end
  ---@cast info Testing.Scan.Info

  local dep_lines, why, absent_any, members, why_detail =
    closure_lines(file_info, info, ctx, hasher)
  if not dep_lines then
    return nil, why, nil, why_detail or { kind = "dependency" }
  end
  ---@cast members Testing.Cache.Member[]
  -- the hidden inputs of the spec AND of everything it loads
  local agg, why_agg, agg_detail =
    aggregate(info, root .. "/" .. rel, members, ctx, file_info.child_env ~= nil)
  if not agg then
    return nil, why_agg, nil, agg_detail
  end
  local outside_lines = {}
  if agg.io and agg.outside then
    local present, lines = outside_files(root, agg.outside_literals)
    if present then
      return nil,
        ("reads a file outside the project ('%s'), which the key cannot see"):format(present),
        nil,
        { kind = "outside", name = present }
    end
    outside_lines = lines
  end
  local in_lines, why2 = input_lines(file_info, info, ctx, hasher, agg, absent_any)
  if not in_lines then
    return nil, why2, nil, { kind = "inputs" }
  end
  -- files that decide what the spec does without being required by it: the harness a dialect-h spec runs on,
  -- the project's `minit`
  for _, extra in ipairs(file_info.extra or {}) do
    local abs = extra:gsub("\\", "/")
    if not (abs:find("^/") or abs:find("^%a:")) then
      abs = root .. "/" .. abs
    end
    local esha = sha_of(ctx, hasher, abs)
    local shown = abs:sub(1, #root + 1) == root .. "/" and abs:sub(#root + 2) or "<outside>"
    in_lines[#in_lines + 1] = ("extra %s=%s"):format(shown, esha or "<absent>")
  end
  table.sort(in_lines)

  local cfg_digest = ctx.config_digest
  if not cfg_digest then
    cfg_digest = ctx.config ~= nil and vim.fn.sha256(vim.inspect(ctx.config)) or "<none>"
  end
  local project_cfg = sha_of(ctx, hasher, root .. "/.testing.lua") or "<absent>"
  local env, _ = env_lines(ctx, agg.env)

  local parts = {
    ("key-version %d"):format(M.KEY_VERSION),
    "file " .. rel,
    "spec " .. sha,
    "runner " .. (ctx.runner_version or M.runner_version(ctx)),
    "nvim " .. nvim_version(ctx),
    "dialect " .. tostring(file_info.dialect or ctx.dialect or "?"),
    "config " .. cfg_digest,
    "project-config " .. project_cfg,
    "seed " .. (ctx.shuffled and tostring(ctx.seed) or "-"),
  }
  vim.list_extend(parts, env)
  if type(file_info.child_env) == "table" then
    -- one line per variable (`NAME=<sha256 of the value>`): `testing explain` names the one that changed
    for _, line in ipairs(file_info.child_env) do
      parts[#parts + 1] = "child-env " .. line
    end
  elseif file_info.child_env then
    parts[#parts + 1] = "child-env " .. file_info.child_env
  end
  vim.list_extend(parts, dep_lines)
  vim.list_extend(parts, in_lines)
  vim.list_extend(parts, outside_lines)
  local key = vim.fn.sha256(table.concat(parts, "\n"))
  -- KEY-FLIP (`testing.cache.keylog`): the same key has given different results before. The key is still computed
  -- (and handed back in `detail`), but nothing is cached for it unless the spec declares `-- @cache-allow nondeterministic`
  local allowed = false
  for _, w in ipairs(info.directives.allow or {}) do
    allowed = allowed or w == "nondeterministic"
  end
  local flip = ctx.flipped and ctx.flipped(rel, key) or nil
  if flip and not allowed then
    return nil,
      ("nondeterministic: the same key gave different results (%s)"):format(
        table.concat(flip.classes, ", ")
      ),
      parts,
      { kind = "nondeterministic", key = key, classes = flip.classes }
  end
  return key,
    nil,
    parts,
    {
      allow_nondeterministic = allowed,
      flipped = flip and flip.classes or nil,
      vouched = #agg.vouched > 0 and agg.vouched or nil,
    }
end

---@class Testing.Cache.Meta
---@field file string Spec file relative to the root.
---@field run? string Run id.
---@field ts? integer
---@field flaky? boolean
---@field timed_out? boolean
---@field crashed? boolean
---@field partial? boolean The file ran only some of its cases.
---@field parts? string[] The key lines (third result of `key`), kept in the entry for `testing explain`.

---Is this case list storable? Returns the reason when it is not.
---@param cases any
---@param meta Testing.Cache.Meta
---@return string|nil why
local function unstorable(cases, meta)
  if meta.flaky then
    return "flaky"
  end
  if meta.timed_out then
    return "timed out"
  end
  if meta.crashed then
    return "crashed"
  end
  if meta.partial then
    return "ran only part of the cases"
  end
  if type(cases) ~= "table" or #cases == 0 then
    return "no cases"
  end
  for _, c in ipairs(cases) do
    if type(c) ~= "table" then
      return "malformed case"
    end
    if c.cached then
      return "case was itself cached"
    end
    if c.status ~= "pass" then
      return "a case is " .. tostring(c.status)
    end
    if (c.retries or 0) > 0 then
      return "a case was retried"
    end
    if store.blocking_guards(c) then
      return "a guard reported a finding"
    end
    local ef = c.effects
    if type(ef) ~= "table" then
      return "effects were not recorded"
    end
    for _, k in ipairs({ "spawned", "network", "fs_outside_tmp" }) do
      if type(ef[k]) ~= "table" or next(ef[k]) ~= nil then
        return "the file has effects (" .. k .. ")"
      end
    end
  end
  return nil
end

---Store the cases of a spec file under `key`. Returns false and the reason when it does not.
---@param key string
---@param fragment Testing.Result.Case[]
---@param meta Testing.Cache.Meta
---@param opts? { root?: string, cache_dir?: string, dir?: string, prune?: boolean }
---@return boolean stored
---@return string|nil why
function M.put(key, fragment, meta, opts)
  opts = opts or {}
  if not store.is_key(key) then
    return false, "bad key"
  end
  if type(meta) ~= "table" or type(meta.file) ~= "string" then
    return false, "meta.file is required"
  end
  local file = meta.file:gsub("\\", "/")
  local why = unstorable(fragment, meta)
  if why then
    skipped("not stored: " .. why)
    return false, why
  end
  for _, c in ipairs(fragment) do
    if c.file ~= file then
      skipped("not stored: case of another file")
      return false, "case of another file"
    end
  end
  local dir = dir_of(opts)
  local ok, err = store.write(dir, {
    v = store.VERSION,
    key = key,
    file = file,
    run = meta.run or "unknown",
    ts = meta.ts or os.time(),
    nvim = tostring(vim.version()),
    cases = fragment,
    parts = store.clean_parts(meta.parts),
  })
  if not ok then
    skipped("not stored: " .. tostring(err))
    return false, err
  end
  M.counters.put = M.counters.put + 1
  if opts.prune ~= false and not pruned[dir] then
    pruned[dir] = true
    pcall(store.prune, dir)
  end
  return true
end

---Delete the entry of a key (a file whose stored result proved wrong or unstable).
---@param key string
---@param opts? { root?: string, cache_dir?: string, dir?: string }
---@return boolean removed
function M.discard(key, opts)
  return store.remove(dir_of(opts or {}), key)
end

---The most recently stored entry of every spec file (key, run, key lines): what `testing explain` compares against.
---@param opts? { root?: string, cache_dir?: string, dir?: string }
---@return table<string, Testing.Cache.Latest>
function M.latest(opts)
  return store.latest_by_file(dir_of(opts or {}))
end

---Would `key` hit? Looks at the entry like `get` does (the same validation) but changes nothing: no counter, no
---refreshed age, no marked cases. For `testing explain`.
---@param key string
---@param opts { root?: string, cache_dir?: string, dir?: string, file: string }
---@return Testing.Cache.Entry|nil entry
---@return string|nil why
function M.peek(key, opts)
  local file = opts.file:gsub("\\", "/")
  return store.read(dir_of(opts), key, { file = file, touch = false })
end

---A cached case list, marked. Nil on a miss (the reason is the second result).
---@param key string
---@param opts? { root?: string, cache_dir?: string, dir?: string, file?: string }
---@return Testing.Cache.Case[]|nil fragment
---@return string|nil why
function M.get(key, opts)
  opts = opts or {}
  local dir = dir_of(opts)
  local file = opts.file and (opts.file:gsub("\\", "/")) or nil
  if not file then
    -- the file is read from the entry itself (the key already binds it); wrap_file always passes it
    local path = store.entry_path(dir, key)
    local text = store.is_key(key) and require("lib.nvim.fs.read")(path) or nil
    local ok, raw = pcall(require("lib.nvim.json").decode, text or "")
    if not (ok and type(raw) == "table" and type(raw.file) == "string") then
      M.counters.miss = M.counters.miss + 1
      return nil, "absent"
    end
    file = raw.file
  end
  local entry, why = store.read(dir, key, { file = file })
  if not entry then
    M.counters.miss = M.counters.miss + 1
    return nil, why
  end
  local note = "cached from " .. entry.run
  for _, c in ipairs(entry.cases) do
    ---@cast c Testing.Cache.Case
    c.cached = true
    c.notes = c.notes or {}
    c.notes[#c.notes + 1] = note
  end
  M.counters.hit = M.counters.hit + 1
  return entry.cases, nil
end

---Bound the store (age, bytes, entries) and write the hash index.
---@param opts? Testing.Cache.PruneOpts & { root?: string, cache_dir?: string, dir?: string }
---@return Testing.Cache.PruneResult
function M.prune(opts)
  opts = opts or {}
  return store.prune(dir_of(opts), opts)
end

---A function `abs -> Testing.Scan.Info|nil` backed by the persistent hash index of the project's cache:
---a file whose size and mtime did not change is not read and scanned again.
---@param ctx { root?: string, cache_dir?: string, dir?: string, hasher?: Testing.Cache.Hasher }
---@return fun(abs: string): Testing.Scan.Info|nil
function M.analyzer(ctx)
  local h = hasher_of(ctx --[[@as table]])
  return function(abs)
    local sha, info = h:analyzed(abs)
    if sha and type(info) == "table" then
      return info
    end
    return nil
  end
end

---Write the hash index of every hasher (call once at the end of a run).
---@return boolean ok
---@return string|nil err
function M.flush()
  local all_ok, first_err = true, nil
  for _, h in pairs(hashers) do
    local ok, err = h:flush()
    if not ok then
      all_ok = false
      first_err = first_err or err
    end
  end
  return all_ok, first_err
end

---Delete every entry of the project's cache (`--cache-clear`). Per-process state is reset in place.
---@param opts? { root?: string, cache_dir?: string, dir?: string }
---@return integer removed
function M.clear(opts)
  local dir = dir_of(opts)
  local n = store.clear(dir)
  local h = hashers[dir]
  if h then
    h:clear()
  end
  memo.runner = nil
  return n
end

---@class Testing.Cache.Stats
---@field dir string
---@field entries integer
---@field bytes integer
---@field oldest? integer
---@field newest? integer
---@field hit integer
---@field miss integer
---@field put integer
---@field skipped table<string, integer>
---@field hashed integer Files hashed by this process.
---@field reused integer Hashes answered from the stat pre-check.

---Disk state and the counters of this process.
---@param opts? { root?: string, cache_dir?: string, dir?: string }
---@return Testing.Cache.Stats
function M.stats(opts)
  local dir = dir_of(opts)
  local s = store.disk_stats(dir)
  local h = hashers[dir]
  return {
    dir = dir,
    entries = s.entries,
    bytes = s.bytes,
    oldest = s.oldest,
    newest = s.newest,
    hit = M.counters.hit,
    miss = M.counters.miss,
    put = M.counters.put,
    skipped = vim.deepcopy(M.counters.skipped),
    hashed = h and h.hashed or 0,
    reused = h and h.reused or 0,
  }
end

---@class Testing.Cache.WrapInfo
---@field status "hit"|"miss"|"uncacheable"|"off"|"refreshed"
---@field key? string
---@field reason? string Why uncacheable, or why a miss was not stored.
---@field stored? boolean

---Run a spec file through the cache.
---
--- `runner_fn()` runs the file and returns its case list (`Testing.Result.Case[]`) and optionally a
--- second table `{ flaky?, timed_out?, crashed?, partial? }` that keeps the result out of the cache.
--- On a hit `runner_fn` is not called and the returned cases carry `cached = true`.
---@param runner_fn fun(): Testing.Result.Case[], table|nil
---@param file_info Testing.Cache.FileInfo
---@param ctx Testing.Cache.Ctx
---@return Testing.Cache.Case[] cases
---@return Testing.Cache.WrapInfo info
function M.wrap_file(runner_fn, file_info, ctx)
  local mode = ctx.mode or "use"
  if mode == "off" then
    local cases = runner_fn()
    return cases, { status = "off" }
  end
  if ctx.restricted then
    local cases = runner_fn()
    skipped("case selection is active")
    return cases, { status = "uncacheable", reason = "case selection is active" }
  end
  local key, why, parts = M.key(file_info, ctx)
  if not key then
    skipped(why or "no key")
    local cases = runner_fn()
    return cases, { status = "uncacheable", reason = why }
  end
  local dir_opts = { root = ctx.root, cache_dir = ctx.cache_dir, hasher = ctx.hasher }
  if mode == "use" then
    local frag = M.get(key, vim.tbl_extend("force", dir_opts, { file = file_info.file }))
    if frag then
      return frag, { status = "hit", key = key }
    end
  end
  local cases, extra = runner_fn()
  extra = type(extra) == "table" and extra or {}
  local ok, why_not = M.put(key, cases, {
    file = file_info.file,
    run = ctx.run_id,
    flaky = extra.flaky,
    timed_out = extra.timed_out,
    crashed = extra.crashed,
    partial = extra.partial,
    parts = parts,
  }, { root = ctx.root, cache_dir = ctx.cache_dir, prune = ctx.prune })
  return cases,
    {
      status = mode == "refresh" and "refreshed" or "miss",
      key = key,
      stored = ok,
      reason = why_not,
    }
end

return M
