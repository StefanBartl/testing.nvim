---@module 'testing.migrate.analyze'
---@brief Read-only analysis of a repository for the migration to testing.nvim.
---@description
--- `M.analyze(root, opts)` answers, without writing anything and without running a spec:
---
---   * which spec files exist and in which dialect (through `testing.discover`, behind an adapter so a
---     change of its result shape degrades the report, never crashes it), which specs are self-running
---     scripts or lack the `_spec` suffix, which sit under `lua/` or in legacy places (NEW-48);
---   * the repository's own harness (`TESTS/harness.lua`, `TESTS/run.lua`: spec list, sentinel, whether the
---     harness collects failures itself);
---   * where plenary / busted is used: `scripts/test.sh`, `TESTS/minimal_init.lua` (line by line), the CI
---     workflows (job by job: timeouts, matrix, how the specs are started), `Makefile`, and `require`s of
---     plenary modules other than its test runner;
---   * the dependencies: every `require` of `lua/` and `TESTS/` mapped to a repository of the fleet (the
---     `*.nvim` directories beside the repository) or to a well-known external plugin, hard or optional,
---     plus what the old runner declared;
---   * the policy suggestions for `.testing.lua` (`isolated`, `host`, `assertions`) and the risks.
---
--- The result is plain data (JSON-encodable) except `texts`, the files that were read (the plan edits
--- exactly those bytes). Nothing here raises: a problem becomes a `risks` entry.

local fleet = require("testing.migrate.fleet")
local scaffold = require("testing.scaffold")
local text = require("testing.migrate.text")
local ci = require("testing.migrate.ci")

local uv = vim.uv or vim.loop

local M = {}

---@class Testing.Migrate.AnalyzeOpts
---@field fleet_root? string Directory with the `*.nvim` repositories (default: the parent of `root`).
---@field discover? fun(root: string, opts: table): table Seam for specs (default `testing.discover.discover`).
---@field owner? string GitHub owner of the fleet (default `StefanBartl`).
---@field format? Testing.Migrate.FormatOpts Seam for the stylua call of the plan (`M.run` hands it on).
---@field branch_exists? fun(owner: string, repo: string): boolean|nil, string|nil Seam of the plan (`M.run` hands it on): does the repository have a `ci-verified` branch?
---@field scan_cache? table Shared between calls: the `require` scans of the fleet repositories (a bulk run reads each once).

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(vim.fn.fnamemodify(p, ":p")):gsub("/+$", ""))
end

---@param path string
---@return boolean
local function is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

---@param path string
---@return boolean
local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---`url` of `[remote "origin"]` in `.git/config`, read as text (no process).
---@param root string
---@return string|nil
local function origin_url(root)
  local cfg = text.read(root .. "/.git/config")
  if not cfg then
    return nil
  end
  local in_origin = false
  for line in (cfg .. "\n"):gmatch("(.-)\n") do
    local section = line:match("^%s*%[(.-)%]")
    if section then
      in_origin = section:match('^remote%s+"origin"$') ~= nil
    elseif in_origin then
      local url = line:match("^%s*url%s*=%s*(%S+)")
      if url then
        return url
      end
    end
  end
end

---Names of the files directly in `dir` whose name matches `pat`.
---@param dir string
---@param pat string
---@return string[]
local function list_files(dir, pat)
  local out = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if (kind == "file" or kind == "link") and name:match(pat) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---Sentinel the old runner prints, in every spelling the fleet uses.
---@param src string
---@return string|nil
function M.find_sentinel(src)
  for name in src:gmatch("([%u][%u%d]*_[%u%d_]*OK)") do
    if name:match("^[%u%d_]+$") and #name <= 60 and name ~= "TESTING_OK" then
      return name
    end
  end
end

---@class Testing.Migrate.PlenaryLine
---@field lnum integer
---@field text string
---@field kind "code"|"comment"

---Lines of a Lua file that mention plenary (case-insensitive), classified.
---@param src string
---@return Testing.Migrate.PlenaryLine[]
function M.plenary_lines(src)
  local out = {}
  local lines = text.lines(src)
  for i, l in ipairs(lines) do
    if l:lower():find("plenary", 1, true) then
      out[#out + 1] = { lnum = i, text = l, kind = l:match("^%s*%-%-") and "comment" or "code" }
    end
  end
  return out
end

---Directories the old runner was pointed at: `PlenaryBustedDirectory <dir>`, `busted <dir>`.
---@param src string
---@return string[]
local function runner_dirs(src, root)
  local out, seen = {}, {}
  for d in src:gmatch("PlenaryBustedDirectory%s+([^%s{\"']+)") do
    d = d:gsub("/+$", "")
    if not seen[d] and d:match("^[%w_][%w_%./%-]*$") and is_dir(root .. "/" .. d) then
      seen[d] = true
      out[#out + 1] = d
    end
  end
  for d in src:gmatch("%f[%w]busted%s+(TESTS[%w_/%-]*)") do
    d = d:gsub("/+$", "")
    if not seen[d] and d:match("^[%w_][%w_%./%-]*$") and is_dir(root .. "/" .. d) then
      seen[d] = true
      out[#out + 1] = d
    end
  end
  return out
end

---Lua files the old runner starts directly (`-l TESTS/x.lua`, `luafile TESTS/x.lua`).
---@param src string
---@return string[]
local function invoked_scripts(src)
  local out, seen = {}, {}
  for _, pat in ipairs({
    "%-l%s+[\"']?(TESTS/[%w_%./%-]+%.lua)",
    "luafile%s+[\"']?(TESTS/[%w_%./%-]+%.lua)",
  }) do
    for f in src:gmatch(pat) do
      if not seen[f] then
        seen[f] = true
        out[#out + 1] = f
      end
    end
  end
  return out
end

---All Lua files below `TESTS/` as one text (read-only), for the heuristics that look at what the specs
---mention: environment variables, optional dependencies, host-dependent editor calls. Bounded.
---@param root string
---@return string
local function tests_text(root)
  local parts, total = {}, 0
  -- `TESTS/run.lua` is the old runner: it goes away with the migration, so what it reads (the old
  -- `LIB_NVIM_PATH` override, ...) must not be carried over into `.testing.lua`
  local dir = root .. "/TESTS"
  if not is_dir(dir) then
    return ""
  end
  for name, kind in vim.fs.dir(dir, { depth = 6 }) do
    if
      kind == "file"
      and name:match("%.lua$")
      and name ~= "run.lua"
      and total < 4 * 1024 * 1024
    then
      local src = text.read(dir .. "/" .. name)
      if src and #src <= 300 * 1024 then
        parts[#parts + 1] = src
        total = total + #src
      end
    end
  end
  return table.concat(parts, "\n")
end

---`src` without its comments: whole-line comments and trailing ones (` #` of a workflow, `--` of Lua).
---Naive on purpose (no string awareness): it is used to decide what the old runner CHECKS OUT, where a
---name only a comment mentions must not count.
---@param src string
---@param marker string Lua pattern of the comment opener (`#` or `%-%-`).
---@return string
local function strip_comments(src, marker)
  local out = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("^%s*" .. marker .. ".*$", "")
    if marker == "#" then
      line = line:gsub("%s#.*$", "")
    else
      line = line:gsub("%-%-.*$", "")
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

---@class Testing.Migrate.OrderHazard
---@field differs boolean The list of `TESTS/run.lua` is not the order discovery gives without it.
---@field first? string Spec that run.lua puts first although discovery orders it later.
---@field second? string The spec it is run before.

---Does the spec list of the old runner (`TESTS/run.lua`) order the files differently from discovery (alphabetical
---per root)? Only then does deleting run.lua change the order the specs run in. A probe run in the other order
---would need the specs to run (the planner is read-only and cheap), so this is a text-level hint.
---@param listed string[] Names run.lua lists, in its order (`name_spec.lua`, relative to TESTS/).
---@param files { rel: string }[] Discovered files in discovery order.
---@return Testing.Migrate.OrderHazard
function M.order_hazard(listed, files)
  local pos = {}
  for i, f in ipairs(files) do
    pos[f.rel] = i
  end
  local prev_rel, prev_pos
  for _, name in ipairs(listed or {}) do
    local rel = "TESTS/" .. name
    local p = pos[rel]
    if p then
      if prev_pos and p < prev_pos then
        return { differs = true, first = prev_rel, second = rel }
      end
      prev_rel, prev_pos = rel, p
    end
  end
  return { differs = false }
end

---Environment variables the specs read and the child editors would not inherit (the allowlist of
---`testing.child.env` drops everything else). A name that looks like a secret is reported, never proposed.
---@param src string
---@param skip_dirs? table<string, true> `$<NAME>_DIR` names of the repositories of the fleet (set by the driver for the resolved dependencies).
---@return string[] allow Proposed `env_allow` entries, sorted.
---@return string[] secrets Names that look like credentials (not proposed).
function M.env_needs(src, skip_dirs)
  skip_dirs = skip_dirs or {}
  local env = require("testing.child.env")
  local allowed = {}
  for _, n in ipairs(env.ALLOW) do
    allowed[n] = true
  end
  local seen, seen_count, allow, secrets = {}, 0, {}, {}
  local function consider(name)
    -- bounded: every new name costs a few scans of the text, a hostile repository must not multiply them
    if seen[name] or #name < 3 or #name > 60 or seen_count >= 200 then
      return
    end
    seen[name] = true
    seen_count = seen_count + 1
    local up = name:upper()
    if allowed[up] or up:sub(1, 3) == "LC_" or env.is_denied(name) then
      return
    end
    -- the driver sets these itself: the sandbox's temp and XDG directories, `$<NAME>_DIR` of a dependency
    if
      up == "TEMP"
      or up == "TMP"
      or up == "TMPDIR"
      or up:sub(1, 4) == "XDG_"
      or up:match("_DIR$") and skip_dirs[up]
    then
      return
    end
    -- a variable the specs set themselves does not need to arrive from outside
    local esc = name:gsub("%p", "%%%0")
    if
      src:find("vim%.env%." .. esc .. "%s*=[^=]")
      or src:find("setenv%(%s*[\"']" .. esc .. "[\"']")
      or src:find("vim%.env%[%s*[\"']" .. esc .. "[\"']%s*%]%s*=[^=]")
    then
      return
    end
    if
      up:find("TOKEN", 1, true)
      or up:find("SECRET", 1, true)
      or up:find("PASSWORD", 1, true)
      or up:find("API_KEY", 1, true)
      or up:find("CREDENTIAL", 1, true)
    then
      secrets[#secrets + 1] = name
    elseif name:match("^[%u][%u%d_]+$") and name:sub(-1) ~= "_" then -- `DOCMAP_` is a prefix of a built name
      allow[#allow + 1] = name
    end
  end
  for name in src:gmatch("vim%.env%.([%a_][%w_]*)") do
    consider(name)
  end
  for _, pat in ipairs({
    "os%.getenv%(%s*[\"']([%a_][%w_]*)[\"']",
    "vim%.fn%.getenv%(%s*[\"']([%a_][%w_]*)[\"']",
    "os_getenv%(%s*[\"']([%a_][%w_]*)[\"']",
    "vim%.env%[%s*[\"']([%a_][%w_]*)[\"']%s*%]",
  }) do
    for name in src:gmatch(pat) do
      consider(name)
    end
  end
  -- ImageMagick from a package manager that keeps its modules out of the usual places reads MAGICK_*
  if src:find("magick", 1, true) or src:find("ImageMagick", 1, true) then
    allow[#allow + 1] = "MAGICK_*"
  end
  table.sort(allow)
  table.sort(secrets)
  return vim.list_slice(allow, 1, 12), vim.list_slice(secrets, 1, 12)
end

---Does a specs text say that `name` (e.g. `ui.nvim`) is ABSENT on purpose? Such a plugin must stay off the
---runtimepath of the run, whatever the old CI checked out.
---@param src string
---@param name string
---@return boolean
function M.asserts_absence(src, name)
  local needle = name:lower()
  for line in src:lower():gmatch("[^\n]+") do
    if
      line:find(needle, 1, true)
      and (
        line:find("absent", 1, true)
        or line:find("without", 1, true)
        or line:find("not installed", 1, true)
        or line:find("missing", 1, true)
        or line:find("not on the rtp", 1, true)
        or line:find("not available", 1, true)
      )
    then
      return true
    end
  end
  return false
end

---Does a workflow COMMENT say that `name` is kept out of the run on purpose ("ui.nvim is deliberately NOT
---checked out")? The old CI chose that (a spec simulates the absence, or degrades without it), so the plan
---must not add a checkout nor list it in `deps`.
---@param ci_src string The workflows, comments included.
---@param name string
---@return boolean
function M.kept_away(ci_src, name)
  local needle = name:lower()
  for line in ci_src:lower():gmatch("[^\n]+") do
    if line:match("^%s*#") and line:find(needle, 1, true) then
      if
        line:find("not checked out", 1, true)
        or line:find("deliberately not", 1, true)
        or line:find("deliberately absent", 1, true)
        or line:find("kept off", 1, true)
        or line:find("stays off", 1, true)
        or line:find("not on the runtimepath", 1, true)
      then
        return true
      end
    end
  end
  return false
end

---@class Testing.Migrate.CleanupLine
---@field lnum integer
---@field text string

---@class Testing.Migrate.CleanupFile
---@field rel string
---@field lines Testing.Migrate.CleanupLine[] At most 12 per file.

---Lines of the documentation and the lint configuration that talk about the old runner (or name the init
---script that goes away), so the person who migrates can reword exactly those. Read-only: the migration
---never edits prose. Comments of the spec files are only counted and sampled, never proposed for a change.
---@param root string
---@param spec_files Testing.Migrate.SpecFile[]
---@param init_goes boolean `scripts/minimal_init.lua` is removed by the plan.
---@return { files: Testing.Migrate.CleanupFile[], specs: { total: integer, samples: { rel: string, lnum: integer, text: string }[] } }
function M.cleanup_hints(root, spec_files, init_goes)
  local rels = {}
  local function add(dir, pat, prefix)
    for _, n in ipairs(list_files(root .. (dir ~= "" and ("/" .. dir) or ""), pat)) do
      if not n:upper():find("^CHANGELOG") then
        rels[#rels + 1] = prefix .. n
      end
    end
  end
  add("", "%.md$", "")
  add("TESTS", "%.md$", "TESTS/")
  add("docs", "%.md$", "docs/")
  rels[#rels + 1] = ".luacheckrc"
  rels[#rels + 1] = "Makefile"
  local files = {}
  for i, rel in ipairs(rels) do
    local src = i <= 60 and text.read(root .. "/" .. rel) or nil
    if src then
      local lines = {}
      for lnum, l in ipairs((text.lines(src))) do
        if
          l:lower():find("plenary", 1, true)
          or (init_goes and l:find("scripts/minimal_init.lua", 1, true))
        then
          if #lines < 12 then
            lines[#lines + 1] = { lnum = lnum, text = text.show(l, 160) }
          end
        end
      end
      if #lines > 0 then
        files[#files + 1] = { rel = rel, lines = lines }
      end
    end
  end
  local total, samples = 0, {}
  for i, f in ipairs(spec_files) do
    local src = i <= 400 and text.is_safe_rel(f.rel) and text.read(root .. "/" .. f.rel) or nil
    if src then
      for lnum, l in ipairs((text.lines(src))) do
        if l:lower():find("plenary", 1, true) then
          total = total + 1
          if #samples < 5 then
            samples[#samples + 1] = { rel = f.rel, lnum = lnum, text = text.show(l, 160) }
          end
        end
      end
    end
  end
  return { files = files, specs = { total = total, samples = samples } }
end

---Run `discover` behind the adapter.
---@param root string
---@param opts Testing.Migrate.AnalyzeOpts
---@return table result `{ files, findings, runner }`, never nil.
---@return string|nil err
local function run_discover(root, opts)
  local fn = opts.discover or require("testing.discover").discover
  local ok, res = pcall(fn, root, { dialect = "auto", include_legacy = true })
  if not ok or type(res) ~= "table" then
    return { files = {}, findings = {}, runner = { listed = {} } }, tostring(res)
  end
  res.files = type(res.files) == "table" and res.files or {}
  res.findings = type(res.findings) == "table" and res.findings or {}
  res.runner = type(res.runner) == "table" and res.runner or { listed = {} }
  return res
end

---Collect the dependencies (see the module header).
---@param root string
---@param idx Testing.Migrate.FleetIndex
---@param declared table<string, true> `*.nvim` names the old runner mentions.
---@param cache table
---@return table deps `{ list, optional, unresolved, ambiguous, declared_only }`
local function collect_deps(root, idx, declared, cache, mention_text)
  local self_name = vim.fs.basename(root)
  ---@type table<string, { name: string, kind: string, hard_lua: boolean, hard_tests: boolean, soft: boolean, modules: table<string, true>, transitive: boolean }>
  local found = {}
  local unresolved, ambiguous = {}, {}

  ---@param reqs Testing.Migrate.Require[]
  ---@param transitive boolean
  ---@param self_dir string
  local function absorb(reqs, self_dir, transitive)
    for _, r in ipairs(reqs) do
      local res = fleet.resolve(r.module, idx, self_dir)
      if transitive and res.kind == "external" then
        -- what a dependency needs from outside the fleet is its own business, never ours to pin
        res = { kind = "builtin" }
      end
      if res.kind == "fleet" or res.kind == "external" then
        local e = found[res.repo]
        if not e then
          e = {
            name = res.repo,
            kind = res.kind,
            hard_lua = false,
            hard_tests = false,
            soft = false,
            modules = {},
            transitive = transitive,
          }
          found[res.repo] = e
        end
        if r.soft or not r.top then
          -- optional (pcall) or lazy (inside a function): not needed to load the module
          e.soft = true
        elseif r.file:sub(1, 6) == "TESTS/" then
          e.hard_tests = true
        else
          e.hard_lua = true
          if not transitive then
            e.transitive = false
          end
        end
        if vim.tbl_count(e.modules) < 6 then
          e.modules[r.module] = true
        end
      elseif res.kind == "ambiguous" and not transitive then
        ambiguous[r.module] = res.candidates
      elseif res.kind == "unknown" and not transitive then
        local top = r.module:match("^[^%.]+")
        unresolved[top] = (unresolved[top] or 0) + 1
      end
    end
  end

  absorb(fleet.scan(root, { "lua", "TESTS" }), root, false)

  -- transitive: what the fleet dependencies themselves need at load time (hard requires only)
  local queue = {}
  for name, e in pairs(found) do
    if e.kind == "fleet" and (e.hard_lua or declared[name]) then
      queue[#queue + 1] = name
    end
  end
  table.sort(queue)
  local visited = {}
  local depth = 0
  while #queue > 0 and depth < 3 do
    depth = depth + 1
    local nextq = {}
    for _, name in ipairs(queue) do
      if not visited[name] then
        visited[name] = true
        local dir = idx.root .. "/" .. name
        cache[name] = cache[name] or fleet.scan(dir, { "lua" })
        local hard = {}
        for _, r in ipairs(cache[name]) do
          if not r.soft then
            hard[#hard + 1] = r
          end
        end
        local before = vim.tbl_keys(found)
        absorb(hard, dir, true)
        for n, e in pairs(found) do
          if not vim.tbl_contains(before, n) and e.kind == "fleet" then
            nextq[#nextq + 1] = n
          end
        end
      end
    end
    table.sort(nextq)
    queue = nextq
  end

  local list, optional, declared_only = {}, {}, {}
  local names = vim.tbl_keys(found)
  table.sort(names)
  for _, name in ipairs(names) do
    local e = found[name]
    local mods = vim.tbl_keys(e.modules)
    table.sort(mods)
    local entry = {
      name = name,
      hard_lua = e.hard_lua,
      kind = e.kind == "fleet" and "fleet" or "external",
      note = e.kind == "fleet" and "fleet repository" or "external, not in fleet",
      modules = mods,
      transitive = e.transitive,
    }
    if name ~= self_name and name ~= "testing.nvim" then
      -- Hard in lua/: the plugin cannot load without it. Only in TESTS/ or behind pcall: a dependency
      -- only when the old runner put it on the runtimepath (declared), because a spec that needs it
      -- unguarded could never have passed without that.
      -- An external plugin is a dependency only when the old runner put it in place (its checkout step
      -- or rtp entry names it): nothing else could have made the specs run before.
      local needed = e.hard_lua
      if e.kind == "external" then
        needed = needed and mention_text:find(name, 1, true) ~= nil
      else
        needed = needed or (declared[name] and (e.hard_tests or e.soft))
      end
      if needed then
        list[#list + 1] = entry
      else
        optional[#optional + 1] = entry
      end
    end
  end
  for name in pairs(declared) do
    if not found[name] and name ~= self_name then
      declared_only[#declared_only + 1] = name
    end
  end
  table.sort(declared_only)
  return {
    list = list,
    optional = optional,
    unresolved = unresolved,
    ambiguous = ambiguous,
    declared_only = declared_only,
  }
end

---Analyse a repository.
---@param root string
---@param opts? Testing.Migrate.AnalyzeOpts
---@return Testing.Migrate.Report report
function M.analyze(root, opts)
  opts = opts or {}
  root = norm(root)
  ---@type Testing.Migrate.Report
  ---@diagnostic disable-next-line: missing-fields
  local report = {
    root = root,
    name = vim.fs.basename(root),
    risks = {},
    texts = {},
  }
  local function risk(msg)
    report.risks[#report.risks + 1] = msg
  end
  if not is_dir(root) then
    report.error = "not a directory"
    return report
  end

  report.is_self = is_file(root .. "/scripts/testing.lua")
    and is_file(root .. "/lua/testing/init.lua")
  local url = origin_url(root)
  report.origin = url
  local owner = opts.owner or scaffold.DEFAULT_OWNER
  if url and not url:lower():find("/" .. owner:lower() .. "/", 1, true) then
    report.third_party = true
  end
  report.plugin = scaffold.detect_plugin(root)

  -- ---------------------------------------------------------------- specs
  local disc, derr = run_discover(root, opts)
  if derr then
    risk("spec discovery failed: " .. text.show(derr, 200))
  end
  local specs = { total = #disc.files, by_dialect = {}, files = {}, legacy = {}, under_lua = {} }
  for _, f in ipairs(disc.files) do
    local d = tostring(f.dialect)
    specs.by_dialect[d] = (specs.by_dialect[d] or 0) + 1
    local rel = tostring(f.rel)
    local harness_rel
    if type(f.harness) == "string" then
      harness_rel = require("lib.nvim.fs.relpath")(f.harness, root)
    end
    specs.files[#specs.files + 1] = {
      rel = rel,
      dialect = d,
      origin = f.origin,
      harness = harness_rel,
      symlink = f.symlink == true or nil,
    }
  end
  for _, fd in ipairs(disc.findings) do
    if fd.kind == "legacy_location" then
      specs.legacy[#specs.legacy + 1] = tostring(fd.path)
    elseif fd.kind == "spec_under_lua" then
      specs.under_lua[#specs.under_lua + 1] = tostring(fd.path)
    end
  end
  report.specs = specs
  report.findings = {}
  for _, fd in ipairs(disc.findings) do
    report.findings[#report.findings + 1] = {
      kind = tostring(fd.kind),
      severity = tostring(fd.severity),
      path = fd.path and tostring(fd.path) or nil,
      message = tostring(fd.message),
    }
  end

  -- ---------------------------------------------------------------- own harness
  local run_text = text.read(root .. "/TESTS/run.lua")
  local harness_text = text.read(root .. "/TESTS/harness.lua")
  -- the harness a spec file names (`scripts/ci/harness.lua` beside `scripts/ci/specs/`): not only TESTS/harness.lua
  local own_harness = harness_text and "TESTS/harness.lua" or nil
  if not own_harness then
    for _, f in ipairs(specs.files) do
      if f.harness and f.dialect == "h" then
        own_harness = f.harness
        break
      end
    end
  end
  report.harness = {
    file = harness_text and "TESTS/harness.lua" or nil,
    path = own_harness,
    run_lua = run_text ~= nil,
    listed = disc.runner.listed or {},
    sentinel = run_text and M.find_sentinel(run_text) or disc.runner.sentinel,
    collects_failures = harness_text ~= nil
      and (
        harness_text:find("failures", 1, true) ~= nil
        and harness_text:find("FAIL", 1, true) == nil
      ),
    fail_convention = harness_text ~= nil and harness_text:find("FAIL", 1, true) ~= nil,
  }
  report.order = M.order_hazard(report.harness.listed, disc.files)
  if report.order.differs then
    risk(
      ('TESTS/run.lua lists the specs in another order than alphabetical discovery would (%s runs before %s there): deleting run.lua makes the order alphabetical, and a repository whose specs depend on the order (shared state, a spec that must run last) then breaks silently under `isolated = "none"`; check by renaming run.lua once and running the specs, then keep run.lua or set `isolated = "file"` (one fresh process per spec file)'):format(
        text.show(report.order.first, 60),
        text.show(report.order.second, 60)
      )
    )
  end
  if report.harness.collects_failures then
    risk(
      "TESTS/harness.lua collects failures itself (no `FAIL` error convention): a runner that only looks at raised errors can report green while the harness printed failures; verify the verdict against the old runner"
    )
  end
  if run_text then
    report.texts["TESTS/run.lua"] = run_text
  end

  -- ---------------------------------------------------------------- runner files
  local test_sh = text.read(root .. "/scripts/test.sh")
  local minit = text.read(root .. "/TESTS/minimal_init.lua")
  local makefile = text.read(root .. "/Makefile")
  report.texts["scripts/test.sh"] = test_sh
  report.texts["TESTS/minimal_init.lua"] = minit
  local dot = text.read(root .. "/.testing.lua")
  report.texts[".testing.lua"] = dot
  report.dot_testing = dot ~= nil

  report.test_sh = {
    exists = test_sh ~= nil,
    migrated = test_sh ~= nil and test_sh:find("testing.lua", 1, true) ~= nil,
    plenary = test_sh ~= nil and test_sh:lower():find("plenary", 1, true) ~= nil,
  }
  report.minimal_init = {
    exists = minit ~= nil,
    plenary_lines = minit and M.plenary_lines(minit) or {},
  }
  report.makefile = makefile ~= nil
      and { plenary = makefile:lower():find("plenary", 1, true) ~= nil }
    or nil

  -- ---------------------------------------------------------------- CI
  local workflows = {}
  local wf_dir = root .. "/.github/workflows"
  local sources = { test_sh or "", makefile or "" }
  for _, name in ipairs(list_files(wf_dir, "%.ya?ml$")) do
    local rel = ".github/workflows/" .. name
    local src = text.read(root .. "/" .. rel)
    if src then
      report.texts[rel] = src
      sources[#sources + 1] = src
      local summary, err = ci.summarize(src)
      workflows[#workflows + 1] = {
        rel = rel,
        jobs = summary and summary.jobs or {},
        parse_error = err,
      }
    else
      risk(("%s could not be read"):format(text.show(rel)))
    end
  end
  report.ci = { workflows = workflows }
  local ci_text = table.concat(sources, "\n")

  -- the old init script of the repository (`scripts/minimal_init.lua`): what it sets up besides the old runner
  -- must reach the new `TESTS/minimal_init.lua`
  local legacy_src = text.read(root .. "/scripts/minimal_init.lua")
  if legacy_src then
    report.texts["scripts/minimal_init.lua"] = legacy_src
    local plenary = legacy_src:lower():find("plenary", 1, true) ~= nil
    local referenced = ci_text:find("scripts/minimal_init.lua", 1, true) ~= nil
    report.legacy_init = {
      rel = "scripts/minimal_init.lua",
      -- only a script of the old runner is removed; an init nobody starts and nothing names stays
      legacy = plenary or referenced,
      blocks = require("testing.migrate.legacy_init").split(legacy_src),
    }
  end

  -- how the old runner was started
  local roots_hint = runner_dirs(ci_text, root)
  local scripts_invoked = invoked_scripts(ci_text .. "\n" .. (run_text or ""))
  -- `testing.discover` never treats a file called run.lua / harness.lua / minimal_init.lua as a spec.
  -- At the top of TESTS/ those are the old runner itself; deeper down (`TESTS/refs/run.lua`) it is a
  -- real test that a pattern CAN name (`discover` only refuses the setup names directly in a spec root).
  local setup_names = require("testing.discover").NEVER_SPECS or {}
  local no_suffix, invoked_existing, unmappable, runner_dirs_found = {}, {}, {}, {}
  for _, s in ipairs(scripts_invoked) do
    if is_file(root .. "/" .. s) then
      invoked_existing[#invoked_existing + 1] = s
      local base = vim.fs.basename(s)
      if setup_names[base] then
        -- a setup script with specs beside it is their runner (mdview's TESTS/nvim/harness.lua);
        -- without any it is a test of its own (filetree's TESTS/refs/run.lua): a pattern can name it,
        -- because only `TESTS/run.lua` itself (the old runner) is never a spec
        if s ~= "TESTS/" .. base then
          if #list_files(root .. "/" .. vim.fs.dirname(s), "_spec%.lua$") == 0 then
            no_suffix[#no_suffix + 1] = s
          else
            runner_dirs_found[#runner_dirs_found + 1] = vim.fs.dirname(s)
          end
        end
      elseif not s:match("_spec%.lua$") then
        no_suffix[#no_suffix + 1] = s
      end
    end
  end
  report.runner = {
    plenary_dirs = roots_hint,
    scripts_invoked = invoked_existing,
    scripts_no_suffix = no_suffix,
    unmappable = unmappable,
    runner_dirs = runner_dirs_found,
  }

  -- ---------------------------------------------------------------- plenary use beyond the runner
  local beyond = {}
  local plenary_hard = false
  for _, r in ipairs(fleet.scan(root, { "lua", "TESTS" })) do
    local top, sub = r.module:match("^(plenary)%.?([%w_]*)")
    if top and sub ~= "busted" and sub ~= "test_harness" then
      beyond[#beyond + 1] = { module = r.module, file = r.file, soft = r.soft }
      if not r.soft then
        plenary_hard = true
      end
    end
  end
  report.plenary = {
    beyond_runner = beyond,
    needed = plenary_hard,
    keep_ci = #beyond > 0,
  }
  if #beyond > 0 and not plenary_hard then
    risk("plenary modules are required optionally (pcall): the CI keeps its plenary checkout")
  end

  report.cleanup = M.cleanup_hints(
    root,
    specs.files,
    report.legacy_init ~= nil and report.legacy_init.legacy == true
  )

  -- ---------------------------------------------------------------- dependencies
  local idx = fleet.index(opts.fleet_root and norm(opts.fleet_root) or vim.fs.dirname(root))
  report.fleet = { root = idx.root, repos = #idx.repos }
  local declared = {}
  -- what the old runner really puts in place: a name in a COMMENT ("modelled on ui.nvim's CI") is no checkout
  -- ... and the minimal init the old CI started with (`-u scripts/minimal_init.lua`): data.nvim puts its optional
  -- siblings on the runtimepath there, in code, while its CI only talks about them in a comment
  local init_srcs = {}
  for path in ci_text:gmatch("%-u%s+[\"']?([%w_%./%-]+%.lua)") do
    if
      text.is_safe_rel(path)
      and path ~= "TESTS/minimal_init.lua"
      and is_file(root .. "/" .. path)
    then
      init_srcs[#init_srcs + 1] = strip_comments(text.read(root .. "/" .. path) or "", "%-%-")
    end
  end
  local declared_src = strip_comments(ci_text, "#")
    .. "\n"
    .. strip_comments(run_text or "", "%-%-")
    .. "\n"
    .. strip_comments(minit or "", "%-%-")
    .. "\n"
    .. table.concat(init_srcs, "\n")
  for name in declared_src:gmatch("([%w_%-]+%.nvim)") do
    if
      name ~= report.name
      and name ~= "plenary.nvim"
      and name ~= "testing.nvim"
      and vim.tbl_contains(idx.repos, name)
    then
      declared[name] = true
    end
  end
  local deps = collect_deps(root, idx, declared, opts.scan_cache or {}, declared_src)
  -- plenary: a dependency only when something other than the runner needs it
  if report.plenary.needed then
    local present = false
    for _, d in ipairs(deps.list) do
      present = present or d.name == "plenary.nvim"
    end
    if not present then
      deps.list[#deps.list + 1] = {
        name = "plenary.nvim",
        kind = "external",
        note = "external, not in fleet",
        modules = { "plenary" },
        transitive = false,
      }
    end
  else
    local kept = {}
    for _, d in ipairs(deps.list) do
      if d.name ~= "plenary.nvim" then
        kept[#kept + 1] = d
      else
        deps.optional[#deps.optional + 1] = d
      end
    end
    deps.list = kept
  end
  local tests_src = tests_text(root)
  -- telescope.nvim does not load without plenary.nvim: the old CI had it for the sake of the runner
  do
    local has_telescope, has_plenary = false, false
    for _, d in ipairs(deps.list) do
      has_telescope = has_telescope or d.name == "telescope.nvim"
      has_plenary = has_plenary or d.name == "plenary.nvim"
    end
    if has_telescope and not has_plenary then
      local moved = {}
      for i, d in ipairs(deps.optional) do
        if d.name == "plenary.nvim" then
          moved = table.remove(deps.optional, i)
          break
        end
      end
      deps.list[#deps.list + 1] = vim.tbl_extend("keep", moved, {
        name = "plenary.nvim",
        kind = "external",
        note = "external, required by telescope.nvim",
        modules = { "plenary" },
        transitive = true,
      })
    end
  end
  -- plenary in `deps` (for whatever reason) and the plan removing its CI checkout would contradict each
  -- other: scripts/test.sh requires the dependency, the workflow would not provide it any more
  do
    local in_deps = false
    for _, d in ipairs(deps.list) do
      in_deps = in_deps or d.name == "plenary.nvim"
    end
    if in_deps and not report.plenary.keep_ci then
      report.plenary.keep_ci = true
      risk(
        "plenary.nvim is a dependency (telescope.nvim does not load without it): the CI keeps its plenary checkout"
      )
    end
  end
  -- a dependency the old CI keeps away on purpose (a comment says so) is not proposed: it moves to the
  -- optional ones (the old CI is the reference: nothing needed it for the specs to pass)
  do
    local kept = {}
    for _, d in ipairs(deps.list) do
      if d.name ~= "plenary.nvim" and M.kept_away(ci_text, d.name) then
        d.note = "kept away on purpose (a CI comment says it is deliberately not checked out)"
        deps.optional[#deps.optional + 1] = d
        risk(
          ("%s is not in `deps`: a comment of the workflow says it is deliberately not checked out (the specs run without it)%s"):format(
            d.name,
            d.hard_lua
                and "; lua/ requires it at the top of a module, check that the specs reach no such module"
              or ""
          )
        )
      else
        kept[#kept + 1] = d
      end
    end
    deps.list = kept
  end
  -- a dependency the specs also mention as ABSENT (`applies directly when ui.nvim is absent`): a spec that
  -- needs the plugin missing turns red with it on the runtimepath, a spec that simulates the absence
  -- (`package.preload`) runs fewer cases without it. Nothing is guessed: it stays, and the report says so
  for _, d in ipairs(deps.list) do
    if d.kind == "fleet" and not d.hard_lua and M.asserts_absence(tests_src, d.name) then
      risk(
        ("%s is in `deps` and the specs mention it as absent: if those specs go red with it on the runtimepath, remove it from `deps`"):format(
          d.name
        )
      )
    end
  end
  report.deps = deps
  for mod, candidates in pairs(deps.ambiguous) do
    risk(
      ("module `%s` is provided by several fleet repositories (%s): choose the dependency by hand"):format(
        text.show(mod, 60),
        table.concat(candidates, ", ")
      )
    )
  end
  if #deps.declared_only > 0 then
    risk(
      "the old runner mentions "
        .. table.concat(deps.declared_only, ", ")
        .. " but no `require` of it was found: not added to `deps`, check if the specs need it"
    )
  end

  -- ---------------------------------------------------------------- policy suggestions
  local busted = (specs.by_dialect.busted or 0) > 0
  -- the old CI started each spec script from a `-c` command (`-c "lua dofile('...')"`): host `c`, where
  -- `vim.v.vim_did_enter` is 0; one process under `nvim -l` is red for specs that depend on it
  local started_from_c = false
  for line in strip_comments(ci_text, "#"):gmatch("[^\n]+") do
    if line:match("%-c%s+[\"']lua%s+dofile%s*%(") then
      started_from_c = true
      break
    end
  end
  local per_file = busted or started_from_c
  report.policy = {
    isolated = per_file and "file" or "none",
    isolated_reason = busted and "busted/plenary specs ran one nvim per file under plenary"
      or started_from_c and "the old CI started every spec script from a `-c` command in its own editor"
      or "specs ran in one process under the old runner",
    host = per_file and "c" or nil,
    assertions = "warn",
    assertions_reason = "cases without assertions pass under plenary and the old runners; counting them needs a run, so the suggestion is `warn` (use `error` once they are fixed)",
  }

  -- environment the specs read (the child editors inherit an allowlist only), and the old default of
  -- plenary: no limit per case (the child's default is 10 s per case)
  local dir_vars = {}
  for _, repo in ipairs(idx.repos) do
    dir_vars[require("testing.deps").env_name(repo)] = true
  end
  local allow, secrets = M.env_needs(tests_src, dir_vars)
  report.env = { allow = allow, secrets = secrets }
  if #secrets > 0 then
    risk(
      "the specs read "
        .. table.concat(secrets, ", ")
        .. " (credential-like names, never proposed for `env_allow`): a spec that needs one has to be given it explicitly"
    )
  end
  if busted then
    report.policy.timeouts = { case_ms = 30000 }
  end
  if
    report.policy.isolated == "none"
    and (
      tests_src:find("<cfile>", 1, true)
      or tests_src:find("<cword>", 1, true)
      or tests_src:find("vim_did_enter", 1, true)
    )
  then
    risk(
      'the specs use <cfile>/<cword>/vim_did_enter: in one process (isolated = "none", `nvim -l`) they see E446/E348 and vim_did_enter == 1; the old CI started them from a -c command. isolated = "file" (host c) reproduces that, and shows order dependencies between specs: decide per repository'
    )
  end

  -- ---------------------------------------------------------------- findings worth a risk
  local unknown = specs.by_dialect.unknown or 0
  if unknown > 0 then
    risk(
      ("%d spec file(s) have no known dialect: run `testing list` and decide per file (script, h, busted)"):format(
        unknown
      )
    )
  end
  if #specs.under_lua > 0 then
    risk(("%d spec-named file(s) under lua/ (NEW-48)"):format(#specs.under_lua))
  end
  if #specs.legacy > 0 then
    risk(
      ("specs in legacy place(s): %s (NEW-48); they stay where they are"):format(
        table.concat(specs.legacy, ", ")
      )
    )
  end
  return report
end

return M
