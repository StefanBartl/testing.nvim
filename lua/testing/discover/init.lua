---@module 'testing.discover'
---@brief Spec discovery: which files are specs, in which dialect, and what is wrong with where they live.
---@description
--- `discover(root, opts)` answers three questions about a project and never raises on what it finds:
---
---   * `files`: every `*_spec.lua` below the spec roots (default `TESTS/`) and below the legacy
---     places (`docs/TESTS`, `tests`, `test`, `scripts`), in a deterministic order (byte-wise sorted
---     project-relative path), each with its sniffed or overridden dialect;
---   * `findings`: data, never an exception. NEW-48 (a legacy place holds specs; a busted spec sits
---     under `lua/`), ERR-34 (a symlink was found and not followed), unreadable directories and
---     files, files whose dialect is `unknown`, an invalid dialect override, no spec at all;
---   * `runner`: what the project's own `TESTS/run.lua` says (spec list order, sentinel) so the
---     dialect-A convention of lib.nvim keeps working; `M.order` applies it.
---
--- Rules:
---   * no depth limit (the M0 `depth = 3` hole is closed): the walk is `lib.nvim.fs.collect_recursive`;
---   * a symlinked DIRECTORY is not entered (ERR-34) and is reported; a symlinked spec FILE is
---     reported and still listed (`symlink = true`), a broken symlink is reported and not listed;
---   * every path is literal (XP-01): roots are joined to the project root and walked, never globbed;
---     two spellings of one directory (`TESTS` and `tests` on a case-insensitive file system) are one
---     root (compared by real path), so a spec is never listed twice;
---   * a file that cannot be read is listed with `dialect = "unknown"` and a finding, never skipped.
---
--- Dialect: `opts.dialect` is `"auto"` (sniff), a dialect name for every file, or a table
--- `{ ["TESTS/x_spec.lua"] = "c", ["*"] = "a" }` (literal project-relative paths, `*` = every other
--- file, an entry of `"auto"` sniffs). See `testing.discover.sniff`.

local lua_text = require("testing.discover.lua_text")
local sniff = require("testing.discover.sniff")

local uv = vim.uv or vim.loop

local M = {}

---Places (relative to the project root) where specs lived before `TESTS/` became the rule (NEW-48).
---@type string[]
M.LEGACY_DIRS = { "docs/TESTS", "tests", "test", "scripts" }

---@type string
M.SUFFIX = "_spec.lua"

---Dialect names an override may carry besides the sniffable ones; `testing` is the native dialect
---of testing.nvim itself and is not sniffed.
---@type string[]
M.OVERRIDE_NAMES = { "auto", "testing", "a", "b", "c", "d", "busted", "h" }

---@class Testing.Discover.Opts
---@field roots? string[] Spec roots relative to the project root (default `{ "TESTS" }`).
---@field legacy? string[] Legacy places (default `M.LEGACY_DIRS`).
---@field include_legacy? boolean Legacy specs are listed too (default true); findings are reported either way.
---@field scan_lua_dir? boolean Look for busted-style `*_spec.lua` below `lua/` (default true).
---@field dialect? string|table<string, string> `"auto"`, one dialect name, or a map relative path -> name (`*` = fallback).

---@class Testing.Discover.File
---@field path string Absolute path, forward slashes.
---@field rel string Path relative to the project root.
---@field dialect string `a`, `b`, `c`, `d`, `busted`, `testing` (override only) or `unknown`.
---@field source "sniff"|"override"|"unreadable"
---@field evidence string[] What the sniffer saw (or the override).
---@field reason? string Why the dialect is `unknown`.
---@field origin "root"|"legacy" Where the file was found.
---@field symlink boolean The file itself is a symlink (listed, and reported).
---@field harness? string Dialect `h`: absolute path of the project's `harness.lua` the file runs on.
---@field missing? boolean Set by `M.order`: named by the project's runner but not on disk.

---@class Testing.Discover.Finding
---@field rule string Rule family, e.g. `NEW-48`, `ERR-34`, `NEW-43`, `config`.
---@field kind string `legacy_location`, `project_harness`, `spec_under_lua`, `symlink_dir`, `symlink_file`, `broken_symlink`, `unreadable`, `unknown_dialect`, `bad_override`, `no_specs`, `no_root`.
---@field severity "info"|"warn"|"error"
---@field path? string Project-relative path the finding is about.
---@field message string

---@class Testing.Discover.Runner
---@field listed string[] Spec names in the order the project's `TESTS/run.lua` lists them (with `.lua`).
---@field sentinel? string Sentinel the project's runner prints, e.g. `LIB_TESTS_OK`.

---@class Testing.Discover.Result
---@field root string
---@field files Testing.Discover.File[] Sorted by `rel`.
---@field findings Testing.Discover.Finding[]
---@field runner Testing.Discover.Runner
---@field notes string[] Things worth saying that are not findings (filled by `M.order`).

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---@param path string
---@return string|nil
local function read_text(path)
  local content = require("lib.nvim.fs.read")(path)
  return content
end

---@param path string
---@return boolean
local function is_dir(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "directory"
end

---@param path string
---@return boolean
local function is_link(path)
  local st = uv.fs_lstat(path)
  return st ~= nil and st.type == "link"
end

-- =========================================================
-- The project's own runner (dialect-A convention)
-- =========================================================

---Order hint and sentinel taken from the project's own runner (`TESTS/run.lua`), if it has one.
---The old runner hardcodes its spec list and state shared between files depends on that order. The
---list is scraped from the runner's text with comments removed (a best effort: a name that is
---listed but missing on disk becomes a failing case in `M.order`, never a silent skip). Both
---spellings of the fleet are read: `"name_spec.lua"` (lib.nvim style) and `"name_spec"` (a
---`require`-based runner such as spotlight.nvim's).
---@param root string
---@return Testing.Discover.Runner
function M.runner_hints(root)
  local text = read_text(slashes(root):gsub("/+$", "") .. "/TESTS/run.lua")
  if not text then
    return { listed = {} }
  end
  text = lua_text.strip_comments(text)
  local listed, seen = {}, {}
  ---@param name string
  local function add(name)
    if not name:match("%.lua$") then
      name = name .. ".lua"
    end
    if not seen[name] then
      seen[name] = true
      listed[#listed + 1] = name
    end
  end
  -- one pass in source order over both spellings
  local pos = 1
  while true do
    local s, e, name = text:find("[\"']([%w_%-%./]+_spec%.lua)[\"']", pos)
    local s2, e2, name2 = text:find("[\"']([%w_%-%./]+_spec)[\"']", pos)
    if not s and not s2 then
      break
    end
    if s and (not s2 or s <= s2) then
      add(name)
      pos = e + 1
    else
      add(name2)
      pos = e2 + 1
    end
  end
  local sentinel = text:match('"\\n([%u%d_]+_OK)[%s%(\\"]')
  return { listed = listed, sentinel = sentinel }
end

---Put the files in the order the project's own runner uses: its list first (in its order, entries
---that are not on disk stay as `missing` placeholders), then every other spec in discovery order.
---@param result Testing.Discover.Result
---@return Testing.Discover.File[] ordered
---@return string[] notes
function M.order(result)
  local listed = result.runner.listed
  if #listed == 0 then
    return vim.list_slice(result.files, 1, #result.files), {}
  end
  local by_rel = {}
  for _, f in ipairs(result.files) do
    by_rel[f.rel] = f
  end
  local first_root = result.root .. "/TESTS/"
  local notes, ordered, taken = {}, {}, {}
  for _, name in ipairs(listed) do
    local rel = "TESTS/" .. name
    local f = by_rel[rel]
    if f then
      taken[f] = true
      ordered[#ordered + 1] = f
    else
      -- A listed spec that is missing stays in the list: running it fails, which is an `error`
      -- case (the old runner `dofile`s every listed name and dies on a missing one, so a deleted or
      -- renamed spec must never turn into a quiet green run with fewer files).
      ordered[#ordered + 1] = {
        path = first_root .. name,
        rel = rel,
        dialect = "unknown",
        source = "unreadable",
        evidence = {},
        reason = "listed in TESTS/run.lua but not on disk",
        origin = "root",
        symlink = false,
        missing = true,
      }
      notes[#notes + 1] = ("listed in TESTS/run.lua but not on disk: %s"):format(name)
    end
  end
  for _, f in ipairs(result.files) do
    if not taken[f] then
      ordered[#ordered + 1] = f
      notes[#notes + 1] = ("on disk but not in TESTS/run.lua (run last): %s"):format(f.rel)
    end
  end
  return ordered, notes
end

-- =========================================================
-- Walking
-- =========================================================

---@class Testing.Discover.Walk
---@field specs string[] Absolute paths of `*_spec.lua` files.
---@field symlink_dirs string[] Absolute paths of symlinked directories (listed, not entered).
---@field errors string[] `<dir>: <reason>` of directories that could not be read.

---Walk one directory without a depth limit and without entering symlinked directories (ERR-34).
---@param dir string
---@return Testing.Discover.Walk
local function walk(dir)
  local collect = require("lib.nvim.fs.collect_recursive")
  local symlink_dirs = {}
  local paths, errors = collect.collect(dir, {
    kind = "all",
    ignore = function(abs, as_dir)
      if as_dir and is_link(abs) then
        symlink_dirs[#symlink_dirs + 1] = abs
      end
      return false
    end,
  })
  local specs = {}
  for _, p in ipairs(paths) do
    if p:sub(-#M.SUFFIX) == M.SUFFIX and not is_dir(p) then
      specs[#specs + 1] = p
    end
  end
  table.sort(specs)
  table.sort(symlink_dirs)
  return { specs = specs, symlink_dirs = symlink_dirs, errors = errors or {} }
end

---@param root string
---@param path string
---@return string
local function rel_of(root, path)
  return slashes(require("lib.nvim.fs.relpath")(path, root))
end

---@param opts Testing.Discover.Opts
---@return fun(rel: string): string|nil, string|nil
local function override_resolver(opts)
  local want = opts.dialect
  local valid = {}
  for _, n in ipairs(M.OVERRIDE_NAMES) do
    valid[n] = true
  end
  ---@param name any
  ---@return string|nil
  local function usable(name)
    if name == nil or name == "auto" then
      return nil
    end
    return name
  end
  ---@param rel string
  ---@return string|nil override
  ---@return string|nil bad
  return function(rel)
    local name
    if type(want) == "string" then
      name = want
    elseif type(want) == "table" then
      name = want[rel]
      if name == nil then
        name = want["*"]
      end
    end
    if name ~= nil and not valid[name] then
      return nil, tostring(name)
    end
    return usable(name), nil
  end
end

-- =========================================================
-- discover
-- =========================================================

---Find the specs of a project.
---@param root string Absolute project root.
---@param opts? Testing.Discover.Opts
---@return Testing.Discover.Result
function M.discover(root, opts)
  opts = opts or {}
  root = slashes(vim.fs.normalize(root)):gsub("/+$", "")
  local roots = opts.roots
  if type(roots) ~= "table" or #roots == 0 then
    roots = { "TESTS" }
  end
  local legacy = opts.legacy or M.LEGACY_DIRS
  local include_legacy = opts.include_legacy ~= false
  local override_for = override_resolver(opts)

  ---@type Testing.Discover.Finding[]
  local findings = {}
  ---@param f Testing.Discover.Finding
  local function report(f)
    findings[#findings + 1] = f
  end

  ---@type Testing.Discover.File[]
  local files = {}
  local seen_path = {}
  local seen_dir = {}
  local seen_harness = {}

  ---Add the specs of one directory.
  ---@param dir_rel string
  ---@param origin "root"|"legacy"
  ---@return integer count
  local function add_dir(dir_rel, origin)
    local dir = root .. "/" .. dir_rel
    local real = uv.fs_realpath(dir) or dir
    if seen_dir[real] then
      return 0
    end
    seen_dir[real] = true
    if is_link(dir) then
      report({
        rule = "ERR-34",
        kind = "symlink_dir",
        severity = "warn",
        path = dir_rel,
        message = ("%s is a symlink to a directory: its specs are listed, the links below it are not followed"):format(
          dir_rel
        ),
      })
    end
    local found = walk(dir)
    for _, err in ipairs(found.errors) do
      report({
        rule = "ERR-34",
        kind = "unreadable",
        severity = "error",
        path = dir_rel,
        message = "cannot read a directory: " .. slashes(err),
      })
    end
    for _, link in ipairs(found.symlink_dirs) do
      local rel = rel_of(root, link)
      report({
        rule = "ERR-34",
        kind = "symlink_dir",
        severity = "warn",
        path = rel,
        message = ("%s is a symlink to a directory: it was not entered, specs below it are not run"):format(
          rel
        ),
      })
    end
    local count = 0
    for _, path in ipairs(found.specs) do
      path = slashes(path)
      if not seen_path[path] then
        seen_path[path] = true
        local rel = rel_of(root, path)
        local link = is_link(path)
        if link and not uv.fs_stat(path) then
          report({
            rule = "ERR-34",
            kind = "broken_symlink",
            severity = "error",
            path = rel,
            message = ("%s is a symlink whose target does not exist: not run"):format(rel),
          })
        else
          if link then
            report({
              rule = "ERR-34",
              kind = "symlink_file",
              severity = "warn",
              path = rel,
              message = ("%s is a symlink: listed, but the file it points to may lie outside the project"):format(
                rel
              ),
            })
          end
          local override, bad = override_for(rel)
          if bad then
            report({
              rule = "config",
              kind = "bad_override",
              severity = "error",
              path = rel,
              message = ("invalid dialect override %q (valid: %s); sniffing instead"):format(
                bad,
                table.concat(M.OVERRIDE_NAMES, ", ")
              ),
            })
          end
          local text, read_err = read_text(path)
          ---@type Testing.Discover.File
          local entry
          if not text then
            report({
              rule = "ERR-34",
              kind = "unreadable",
              severity = "error",
              path = rel,
              message = ("cannot read %s: %s"):format(rel, tostring(read_err)),
            })
            entry = {
              path = path,
              rel = rel,
              dialect = override or "unknown",
              source = "unreadable",
              evidence = {},
              reason = tostring(read_err),
              origin = origin,
              symlink = link,
            }
          else
            local verdict
            if override == "testing" then
              verdict = {
                dialect = "testing",
                source = "override",
                evidence = { "override: testing" },
              }
            else
              verdict = sniff.resolve(text, override)
            end
            entry = {
              path = path,
              rel = rel,
              dialect = verdict.dialect,
              source = verdict.source,
              evidence = verdict.evidence,
              reason = verdict.reason,
              origin = origin,
              symlink = link,
            }
            local harness
            if verdict.dialect == "unknown" and verdict.h_style then
              -- helpers of the project's own harness: run on that harness (dialect h)
              harness = require("testing.dialect.harness_project").find_harness(path, root)
              if harness then
                verdict.dialect = "h"
                verdict.reason = nil
                verdict.evidence[#verdict.evidence + 1] = "project harness: "
                  .. rel_of(root, harness)
                entry.dialect, entry.reason = "h", nil
                entry.harness = harness
                if not seen_harness[harness] then
                  seen_harness[harness] = true
                  report({
                    rule = "NEW-43",
                    kind = "project_harness",
                    severity = "info",
                    path = rel_of(root, harness),
                    message = ("specs use helpers of the project's own harness (%s): they run on it (dialect h), failures collected"):format(
                      rel_of(root, harness)
                    ),
                  })
                end
              end
            end
            if verdict.dialect == "h" and not entry.harness then
              entry.harness = require("testing.dialect.harness_project").find_harness(path, root)
            end
            if verdict.dialect == "unknown" then
              report({
                rule = "NEW-43",
                kind = "unknown_dialect",
                severity = "error",
                path = rel,
                message = ("dialect of %s is unknown: %s"):format(rel, tostring(verdict.reason)),
              })
            end
          end
          if origin == "root" or include_legacy then
            files[#files + 1] = entry
          end
          count = count + 1
        end
      end
    end
    return count
  end

  -- 1. the spec roots
  local any_root = false
  for _, dir_rel in ipairs(roots) do
    dir_rel = slashes(dir_rel):gsub("^%./", ""):gsub("/+$", "")
    if is_dir(root .. "/" .. dir_rel) then
      any_root = true
      add_dir(dir_rel, "root")
    end
  end
  if not any_root then
    report({
      rule = "NEW-39",
      kind = "no_root",
      severity = "warn",
      message = ("none of the spec roots exists: %s"):format(table.concat(roots, ", ")),
    })
  end

  -- 2. legacy places: found, listed, and reported (NEW-48)
  for _, dir_rel in ipairs(legacy) do
    local dir = root .. "/" .. dir_rel
    if is_dir(dir) then
      local count = add_dir(dir_rel, "legacy")
      if count > 0 then
        report({
          rule = "NEW-48",
          kind = "legacy_location",
          severity = "warn",
          path = dir_rel,
          message = ("%d spec file(s) in the legacy location %s/: specs belong in TESTS/"):format(
            count,
            dir_rel
          ),
        })
      end
    end
  end

  -- 3. specs under lua/<plugin>/ (NEW-48: a busted spec there ships with the plugin)
  if opts.scan_lua_dir ~= false and is_dir(root .. "/lua") then
    local found = walk(root .. "/lua")
    for _, err in ipairs(found.errors) do
      report({
        rule = "ERR-34",
        kind = "unreadable",
        severity = "error",
        path = "lua",
        message = "cannot read a directory: " .. slashes(err),
      })
    end
    for _, path in ipairs(found.specs) do
      path = slashes(path)
      local rel = rel_of(root, path)
      local text = read_text(path)
      local verdict = text and sniff.sniff(text) or nil
      if verdict and verdict.dialect == "busted" then
        report({
          rule = "NEW-48",
          kind = "spec_under_lua",
          severity = "warn",
          path = rel,
          message = ("%s is a busted spec below lua/: test files belong in TESTS/, not in the shipped plugin"):format(
            rel
          ),
        })
      else
        report({
          rule = "NEW-48",
          kind = "spec_under_lua",
          severity = "info",
          path = rel,
          message = ("%s is named like a spec and sits below lua/; it is not busted syntax and is not run"):format(
            rel
          ),
        })
      end
    end
  end

  table.sort(files, function(x, y)
    return x.rel < y.rel
  end)
  if #files == 0 then
    report({
      rule = "NEW-43",
      kind = "no_specs",
      severity = "error",
      message = "no spec file found: a project without specs must not look green",
    })
  end

  return {
    root = root,
    files = files,
    findings = findings,
    runner = M.runner_hints(root),
    notes = {},
  }
end

return M
