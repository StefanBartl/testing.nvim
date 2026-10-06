---@module 'testing.affected.heuristic'
---@brief Built-in, conservative affected selection from the `require` graph of the project itself.
---@description
--- Used when the documentation.nvim graph is not available, and for the file kinds a graph does not
--- know (support files of the spec tree). The rule is "never fewer than needed":
---
---   * a changed SPEC selects itself;
---   * a changed `lua/<mod>.lua` (module `a.b`, or `a.b` for `a/b/init.lua`) selects every spec that
---     reaches the module or one of its PARENT modules through `require`s, transitively: the graph is
---     built from the files of the project, a literal `require("a.b")` is an edge, a computed
---     `require("a.dialect." .. name)` is an edge to every module below `a.dialect.`, and an
---     unresolvable `require(expr)` is an edge to every module;
---   * a spec that names the changed file as a path literal is selected;
---   * a spec that starts a process (`vim.system`, `jobstart`, ...) runs code the graph cannot see:
---     it is selected whenever any module changed;
---   * a changed file under the spec tree that is no spec (a helper, a fixture) selects every spec
---     below the TOPMOST directory that holds specs (or below its spec root): a helper that lies below
---     `TESTS/a/` is put on `package.path` by a spec of `TESTS/b/` as easily; a module name that a spec
---     requires and that the path of the file spells (`a.helper`, `helper`) selects that spec as well;
---   * a spec that LISTS directories or loads files by `:runtime`/`:source` can
---     see any file: it is selected whenever anything changed; a module of the project that does so
---     counts as changed whenever anything changed (the specs that require it are selected), when it
---     looks at its OWN surroundings (`debug.getinfo`, `getcwd`, the runtime path): a utility that lists what its
---     caller hands it (`collect_recursive`) is not the project;
---   * a changed file of an ignored kind (`opts.ignore`) selects nothing;
---   * a document (`README.md`, `docs/**`, `doc/*.txt`, any `*.md`) selects the specs that name it by a path
---     literal, and the ones that list directories or load files by path (see below);
---   * ANYTHING ELSE is unknown: `unknown` lists it and the caller selects ALL specs.
---
--- Cross-repo is out of scope: a change in a dependency checkout (lib.nvim) is not a changed file of
--- this project.

local scan = require("testing.affected.scan")

local M = {}

---Paths that never affect a spec (prefix match on directories, exact match on files).
---@type string[]
M.DEFAULT_IGNORE = { ".github/", "LICENSE", ".gitignore", ".gitattributes" }

---@param path string
---@param ignore string[]
---@return boolean
local function ignored(path, ignore)
  for _, ig in ipairs(ignore) do
    if ig:sub(-1) == "/" then
      if path:sub(1, #ig) == ig then
        return true
      end
    elseif path == ig then
      return true
    end
  end
  return false
end

---Is `path` a document (prose, generated help, a page of the docs tree)?
---@param path string
---@return boolean
function M.is_doc(path)
  local lower = path:lower()
  return lower:match("%.md$") ~= nil
    or lower:match("^readme") ~= nil
    or lower:match("^docs?/.+%.[%w]+$") ~= nil
    or lower:match("^doc/.+%.txt$") ~= nil
end

---@class Testing.Heuristic.ClassifyOpts
---@field root string
---@field ignore? string[]
---@field exists? fun(rel: string): boolean
---@field config_files? string[]
---@field roots? string[] Spec roots (relative): a support file is an input of every spec below its root.

---@class Testing.Heuristic.ReachOpts
---@field root string
---@field roots? string[]
---@field read? fun(path: string): string|nil, string|nil
---@field analyze? fun(path: string): Testing.Scan.Info|nil

---@class Testing.Affected.Classified
---@field specs table<string, string> Spec -> reason (changed spec, support file below the spec tree).
---@field modules table<string, string> Changed module -> the changed file.
---@field code_changed boolean Any `lua/*.lua` changed (also a deleted one).
---@field paths string[] Changed files that are not specs, for the path-literal rule.
---@field unknown string[]
---@field why table<string, string> Unknown file -> why.
---@field ignored string[]
---@field deleted string[] Deleted or renamed-away specs (nothing to run).

---Sort changed files into kinds.
---@param changed string[]
---@param specs string[] Every spec of the project (relative).
---@param opts Testing.Heuristic.ClassifyOpts
---@return Testing.Affected.Classified
function M.classify(changed, specs, opts)
  local ignore = opts.ignore or M.DEFAULT_IGNORE
  local exists = opts.exists
    or function(rel)
      return vim.uv.fs_stat(opts.root .. "/" .. rel) ~= nil
    end
  local spec_set, spec_dirs = {}, {}
  for _, s in ipairs(specs) do
    spec_set[s] = true
    local dir = s:match("^(.*)/[^/]*$")
    while dir and dir ~= "" do
      spec_dirs[dir] = spec_dirs[dir] or {}
      table.insert(spec_dirs[dir], s)
      dir = dir:match("^(.*)/[^/]*$")
    end
  end
  local config_files = {}
  for _, c in ipairs(opts.config_files or { ".testing.lua" }) do
    config_files[c] = true
  end
  local out = {
    specs = {},
    modules = {},
    code_changed = false,
    paths = {},
    unknown = {},
    why = {},
    ignored = {},
    deleted = {},
  }
  ---@param path string
  ---@param why string
  local function unknown(path, why)
    out.unknown[#out.unknown + 1] = path
    out.why[path] = why
  end
  for _, c in ipairs(changed) do
    if spec_set[c] then
      out.specs[c] = "spec file changed"
    elseif ignored(c, ignore) then
      out.ignored[#out.ignored + 1] = c
    elseif config_files[c] then
      unknown(c, "project test configuration changed")
    elseif c:match("^lua/.+%.lua$") then
      local mod = scan.module_of(c)
      if mod then
        out.modules[mod] = c
        out.code_changed = true
        out.paths[#out.paths + 1] = c
      else
        unknown(c, "module name cannot be derived")
      end
    elseif c:match("_spec%.lua$") and not exists(c) then
      out.deleted[#out.deleted + 1] = c
    else
      local dir = c:match("^(.*)/[^/]*$")
      local found
      for _, r in ipairs(opts.roots or {}) do
        local rr = r:gsub("\\", "/"):gsub("/+$", "")
        if rr ~= "" and c:sub(1, #rr + 1) == rr .. "/" and spec_dirs[rr] then
          found = rr
          break
        end
      end
      while not found and dir and dir ~= "" do
        -- the TOPMOST directory with specs below it, not the nearest: the file may be on a `package.path`
        -- that a spec of a sibling directory sets
        if spec_dirs[dir] then
          found = dir
        end
        dir = dir:match("^(.*)/[^/]*$")
      end
      if found then
        for _, s in ipairs(spec_dirs[found]) do
          out.specs[s] = out.specs[s] or ("support file changed: " .. c)
        end
        out.paths[#out.paths + 1] = c
      elseif M.is_doc(c) then
        -- a document: it can only matter to a spec that NAMES it (a path literal), lists directories or loads
        -- files by path; those are the rules of `reach`, nothing is unknown about a README
        out.paths[#out.paths + 1] = c
      else
        unknown(c, "not a spec, a module or a support file of the spec tree")
      end
    end
  end
  table.sort(out.unknown)
  return out
end

---A string literal of a spec that names `changed` (`docs/x.md`, `/lua/a/b.lua`, `a/b.lua`).
---@param info Testing.Scan.Info
---@param changed string
---@return boolean
local function mentions(info, changed)
  for _, lit in ipairs(info.paths) do
    local l = lit:gsub("^%./", ""):gsub("^/+", ""):gsub("/+$", "")
    if l ~= "" and changed:sub(1, #l + 1) == l .. "/" then
      return true -- a directory the spec names, and the file lies below it
    end
    if l ~= "" and l:find("/", 1, true) then
      if
        l == changed
        or changed:sub(-#l - 1) == "/" .. l
        or l:sub(-#changed - 1) == "/" .. changed
      then
        return true
      end
    elseif l == changed then
      return true
    end
  end
  return false
end

---Does a spec require a module that the path of a changed support file spells? (`TESTS/a/helper.lua` is
---`a.helper` below a `TESTS/?.lua` search path and `helper` below `TESTS/a/?.lua`: every suffix counts.)
---@param info Testing.Scan.Info
---@param changed string
---@return boolean
local function requires_support(info, changed)
  local base = changed:match("^(.*)%.lua$")
  if not base then
    return false
  end
  base = base:gsub("/init$", "")
  local comps = {}
  for c in base:gmatch("[^/]+") do
    comps[#comps + 1] = c
  end
  for i = 1, #comps do
    local name = table.concat(comps, ".", i)
    for _, r in ipairs(info.requires) do
      if r == name then
        return true
      end
    end
    for _, pfx in ipairs(info.prefixes) do
      if name:sub(1, #pfx) == pfx then
        return true
      end
    end
  end
  return false
end

---Does a file name a place of the project (a path literal, or the fixed head of a glob, that exists below `root`)?
---@param info Testing.Scan.Info
---@param root string
---@return boolean
local function names_project_path(info, root)
  for _, lit in ipairs(info.paths) do
    local head = lit:gsub("^%./", ""):gsub("^/+", ""):gsub("[%*%?%[].*$", ""):gsub("/+$", "")
    if head ~= "" and not head:find("..", 1, true) and vim.uv.fs_stat(root .. "/" .. head) then
      return true
    end
  end
  return false
end

---Select specs from the `require` graph of the project.
---@param cls Testing.Affected.Classified
---@param specs string[]
---@param opts Testing.Heuristic.ReachOpts
---@return table<string, string> reason Spec -> reason (added to `cls.specs`).
function M.reach(cls, specs, opts)
  local reason = {}
  for s, r in pairs(cls.specs) do
    reason[s] = r
  end
  if next(cls.modules) == nil and #cls.paths == 0 and not cls.code_changed then
    return reason -- only specs changed: nothing to look up
  end
  local index = scan.index(opts.root, { extra = specs, read = opts.read, analyze = opts.analyze })
  local modules = index.modules
  local anything_changed = cls.code_changed or #cls.paths > 0
  -- every module that exists, its parents that exist
  local seeds = {}
  -- a module that lists directories or loads files by path can see ANY changed file: it counts as changed
  if anything_changed then
    for mod, file in pairs(modules) do
      local info = index.files[file]
      if
        info
        and (info.markers.dirscan or info.markers.dynload)
        and (info.markers.selfscan or names_project_path(info, opts.root))
        and not cls.modules[mod]
      then
        seeds[mod] =
          "lists directories or loads files by path in its own surroundings: any change can reach it"
      end
    end
  end
  for mod, file in pairs(cls.modules) do
    seeds[mod] = ("%s changed"):format(file)
    local parent = mod
    while true do
      parent = parent:match("^(.*)%.[^.]+$")
      if not parent then
        break
      end
      if modules[parent] and not seeds[parent] then
        seeds[parent] = ("parent module of %s"):format(mod)
      end
    end
  end
  local any_seed = next(seeds) ~= nil

  -- forward edges: module -> modules it depends on
  ---@param info Testing.Scan.Info
  ---@return string[] deps
  ---@return boolean all Depends on every module.
  local function deps_of(info)
    local deps, seen = {}, {}
    for _, name in ipairs(info.requires) do
      if (modules[name] or seeds[name]) and not seen[name] then
        seen[name] = true
        deps[#deps + 1] = name
      end
    end
    for _, pfx in ipairs(info.prefixes) do
      for _, set in ipairs({ modules, seeds }) do
        for name in pairs(set) do
          if not seen[name] and name:sub(1, #pfx) == pfx then
            seen[name] = true
            deps[#deps + 1] = name
          end
        end
      end
    end
    return deps, info.dynamic
  end

  local rev, dynamic_mods = {}, {}
  for mod, file in pairs(modules) do
    local info = index.files[file]
    if info then
      local deps, all = deps_of(info)
      for _, d in ipairs(deps) do
        rev[d] = rev[d] or {}
        rev[d][#rev[d] + 1] = mod
      end
      if all then
        dynamic_mods[#dynamic_mods + 1] = mod
      end
    end
  end
  for _, mod in ipairs(index.unreadable) do
    -- a module that cannot be read cannot be reasoned about: it depends on everything
    local name = scan.module_of(mod)
    if name then
      dynamic_mods[#dynamic_mods + 1] = name
    end
  end

  -- affected modules: reverse closure of the seeds, with the first predecessor kept for the reason
  local via, queue = {}, {}
  for mod in pairs(seeds) do
    via[mod] = false
    queue[#queue + 1] = mod
  end
  table.sort(queue)
  local function enqueue(mod, from)
    if via[mod] == nil then
      via[mod] = from
      queue[#queue + 1] = mod
    end
  end
  if any_seed then
    table.sort(dynamic_mods)
    for _, mod in ipairs(dynamic_mods) do
      enqueue(mod, "*dynamic")
    end
  end
  local i = 1
  while i <= #queue do
    local m = queue[i]
    i = i + 1
    local dependents = rev[m]
    if dependents then
      table.sort(dependents)
      for _, d in ipairs(dependents) do
        enqueue(d, m)
      end
    end
  end

  ---@param mod string
  ---@return string
  local function chain(mod)
    local parts, cur, guard = {}, mod, 0
    while cur and guard < 50 do
      guard = guard + 1
      if cur == "*dynamic" then
        parts[#parts + 1] = "(computed require)"
        break
      end
      parts[#parts + 1] = cur
      cur = via[cur]
    end
    return table.concat(parts, " <- ") .. " (" .. (seeds[parts[#parts]] or "changed") .. ")"
  end

  for _, s in ipairs(specs) do
    local info = index.files[s]
    if not reason[s] then
      if not info then
        -- an unreadable spec cannot be excluded
        reason[s] = "spec cannot be read (not excluded)"
      elseif anything_changed and (info.markers.dirscan or info.markers.dynload) then
        reason[s] = "lists directories or loads files by path: any change can reach it"
      elseif any_seed then
        local deps, all = deps_of(info)
        for _, d in ipairs(deps) do
          if via[d] ~= nil then
            reason[s] = "reaches " .. chain(d)
            break
          end
        end
        if not reason[s] and all then
          reason[s] = "requires modules by a computed name"
        end
        if not reason[s] and info.markers.spawn then
          reason[s] = "starts a process: the code it runs is invisible to the graph"
        end
      end
      if not reason[s] and info then
        for _, p in ipairs(cls.paths) do
          if mentions(info, p) then
            reason[s] = "names the changed file " .. p
            break
          end
          if requires_support(info, p) then
            reason[s] = "requires the support module " .. p
            break
          end
        end
      end
      if not reason[s] and info and cls.code_changed and info.markers.spawn then
        reason[s] = "starts a process: the code it runs is invisible to the graph"
      end
    end
  end
  return reason
end

return M
