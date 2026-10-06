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
--- `{ ["TESTS/x_spec.lua"] = "c", ["TESTS/hover/**"] = "busted", ["*"] = "a" }`: a key is a literal
--- project-relative path or a glob (`*` within a segment, `**` across segments, `?` one character;
--- see `M.glob_match`), the lone `*` is every other file, an entry of `"auto"` sniffs. The most
--- specific key wins: a literal path, then the glob with the most literal characters, then `*`.
--- See `testing.discover.sniff`.
---
--- Which files are specs: `opts.spec_pattern`, a list of Lua patterns matched against the
--- project-relative path (default `{ "_spec%.lua$" }`). A project whose specs lack the suffix
--- (filetree.nvim: `TESTS/units.lua`) names its own, e.g. `{ "^TESTS/[%w_]+%.lua$" }`. The files
--- `harness.lua`, `run.lua` and `minimal_init.lua` DIRECTLY in a spec root (`TESTS/run.lua`: the old
--- runner itself) are never specs, whatever the pattern says; deeper down (`TESTS/refs/run.lua`) a
--- pattern that names the file makes it one. The legacy places and the scan below `lua/` keep the
--- default suffix.
---
--- Project harness (dialect `h`): a `return function(H)` file sniffed as a, b or c runs on the
--- project's OWN `harness.lua` (dialect `h`) unless that harness is proven equivalent to the shim for
--- the helpers the file uses (`testing.discover.harness_profile`); the finding `project_harness`
--- says why. An explicit dialect (config or override) is never second-guessed.

local harness_profile = require("testing.discover.harness_profile")
local harness_project = require("testing.dialect.harness_project")
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
M.OVERRIDE_NAMES = { "auto", "testing", "a", "b", "c", "d", "busted", "h", "script" }

---Default spec file pattern (Lua patterns against the project-relative path).
---@type string[]
M.DEFAULT_SPEC_PATTERN = { "_spec%.lua$" }

---Files that are part of a test setup, never specs, whatever `spec_pattern` says (directly in a spec root).
---@type table<string, true>
M.NEVER_SPECS = { ["harness.lua"] = true, ["run.lua"] = true, ["minimal_init.lua"] = true }

---@class Testing.Discover.Opts
---@field roots? string[] Spec roots relative to the project root (default `{ "TESTS" }`).
---@field legacy? string[] Legacy places (default `M.LEGACY_DIRS`).
---@field include_legacy? boolean Legacy specs are listed too (default true); findings are reported either way.
---@field scan_lua_dir? boolean Look for busted-style `*_spec.lua` below `lua/` (default true).
---@field dialect? string|table<string, string> `"auto"`, one dialect name, or a map relative path or glob -> name (`*` = fallback).
---@field spec_pattern? string[] Lua patterns (against the relative path) that make a file a spec; default `M.DEFAULT_SPEC_PATTERN`.

---@class Testing.Discover.File
---@field path string Absolute path, forward slashes.
---@field rel string Path relative to the project root.
---@field dialect string `a`, `b`, `c`, `d`, `h`, `busted`, `script`, `testing` (override only) or `unknown`.
---@field source "sniff"|"override"|"unreadable"
---@field evidence string[] What the sniffer saw (or the override).
---@field reason? string Why the dialect is `unknown`.
---@field origin "root"|"legacy" Where the file was found.
---@field symlink boolean The file itself is a symlink (listed, and reported).
---@field harness? string Dialect `h`: absolute path of the project's `harness.lua` the file runs on.
---@field sniffed? string What the sniffer said when `h` was chosen over it (`a`, `b`, `c`, `unknown`).
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

---The token a project's runner prints when everything passed (`LIB_TESTS_OK`, `EMOJIS_TESTS_OK`,
---`TASKS_TESTS_OK (35 spec(s))`): an upper-case word ending in `_OK` inside a string literal. Every
---quoting form counts (single, double, long brackets), a leading `\n` escape and any suffix after the
---token are fine, and so is a token passed to `print`, `say(...)`, `io.write` or `io.stdout:write`.
---A token whose line (or one of the two lines before it) calls something that prints is preferred;
---otherwise the last token of the file wins. Pure text; the text should have its comments removed.
---@param text string
---@return string|nil sentinel
function M.find_sentinel(text)
  local lines = vim.split(text, "\n", { plain = true })
  ---@param line string
  ---@return boolean
  local function prints(line)
    return line:find("print", 1, true) ~= nil
      or line:find("say", 1, true) ~= nil
      or line:find("write", 1, true) ~= nil
  end
  ---The token sits on a line that prints, or on the line after one that opens the call
  ---(`print(` / `say(` / `io.write(` and then the string on its own line).
  ---@param offset integer
  ---@return boolean
  local function printed(offset)
    local _, breaks = text:sub(1, offset):gsub("\n", "")
    local line_no = breaks + 1
    if prints(lines[line_no] or "") then
      return true
    end
    local before = lines[line_no - 1] or ""
    return prints(before) and before:find("[%(,]%s*$") ~= nil
  end
  local last, last_printed
  for _, str in ipairs(lua_text.strings(text)) do
    local content = str.content:gsub("\\[ntr]", " ")
    for token in content:gmatch("%f[%w_]([%u][%u%d_]*_OK)%f[^%w_]") do
      last = token
      if printed(str.s) then
        last_printed = token
      end
    end
  end
  return last_printed or last
end

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
  return { listed = listed, sentinel = M.find_sentinel(text) }
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
---@param is_spec? fun(path: string): boolean Which files are specs (default: the `_spec.lua` suffix).
---@return Testing.Discover.Walk
local function walk(dir, is_spec)
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
    local wanted
    if is_spec then
      wanted = is_spec(p)
    else
      wanted = p:sub(-#M.SUFFIX) == M.SUFFIX
    end
    if wanted and not is_dir(p) then
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

---@alias Testing.Discover.GlobToken { [1]: "lit"|"one"|"seg"|"any", [2]?: integer }

---@type table<string, Testing.Discover.GlobToken[]>
local glob_cache = {}

---Tokens of a glob: `**` (any run of characters, slashes included), `*` (any run within one path
---segment), `?` (one character within a segment), every other byte literal. A run of stars is ONE
---token (`***` is `**`), so a key cannot multiply the work of a match.
---@param glob string
---@return Testing.Discover.GlobToken[]
local function glob_tokens(glob)
  local cached = glob_cache[glob]
  if cached then
    return cached
  end
  local tokens = {}
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      local j = i
      while glob:sub(j + 1, j + 1) == "*" do
        j = j + 1
      end
      tokens[#tokens + 1] = { j > i and "any" or "seg" }
      i = j
    elseif c == "?" then
      tokens[#tokens + 1] = { "one" }
    else
      tokens[#tokens + 1] = { "lit", glob:byte(i) }
    end
    i = i + 1
  end
  glob_cache[glob] = tokens
  return tokens
end

---Does the glob of a dialect override match `text` (a project-relative path with `/`)? `**` matches
---anything (slashes included), `*` anything within one path segment, `?` one character within a
---segment; every other character is literal. Whole-string match.
---
---Not a Lua pattern on purpose: translated to `.*` runs, a key such as `**a**a**a**b` makes
---`string.find` backtrack for ever (SEC-30/32). This is a sweep over the tokens, O(tokens x length)
---whatever the key looks like.
---@param glob string
---@param text string
---@return boolean
function M.glob_match(glob, text)
  local tokens = glob_tokens(glob)
  local n = #text
  -- reach[i]: the tokens so far can have consumed exactly the first i characters
  local reach = { [0] = true }
  for _, token in ipairs(tokens) do
    local kind = token[1]
    local nxt = {}
    if kind == "lit" then
      for i in pairs(reach) do
        if i < n and text:byte(i + 1) == token[2] then
          nxt[i + 1] = true
        end
      end
    elseif kind == "one" then
      for i in pairs(reach) do
        if i < n and text:byte(i + 1) ~= 47 then
          nxt[i + 1] = true
        end
      end
    else
      local run = false
      for i = 0, n do
        if i > 0 and kind == "seg" and text:byte(i) == 47 then
          run = false
        end
        if reach[i] then
          run = true
        end
        if run then
          nxt[i] = true
        end
      end
    end
    reach = nxt
    if next(reach) == nil then
      return false
    end
  end
  return reach[n] == true
end

---@param key string
---@return boolean
local function is_glob(key)
  return key ~= "*" and key:find("[%*%?]") ~= nil
end

---@param opts Testing.Discover.Opts
---@return fun(rel: string): string|nil, string|nil
local function override_resolver(opts)
  local want = opts.dialect
  local valid = {}
  for _, n in ipairs(M.OVERRIDE_NAMES) do
    valid[n] = true
  end
  -- globs, most specific (most literal characters) first; ties by key for a deterministic answer
  ---@type { key: string, weight: integer }[]
  local globs = {}
  if type(want) == "table" then
    for key in pairs(want) do
      if type(key) == "string" and is_glob(key) then
        globs[#globs + 1] = { key = key, weight = #(key:gsub("[%*%?]", "")) }
      end
    end
    table.sort(globs, function(x, y)
      if x.weight ~= y.weight then
        return x.weight > y.weight
      end
      return x.key < y.key
    end)
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
        for _, g in ipairs(globs) do
          if M.glob_match(g.key, rel) then
            name = want[g.key]
            break
          end
        end
      end
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

---The spec patterns of the options: the given non-empty list, else the default.
---@param opts Testing.Discover.Opts
---@return string[]
local function spec_patterns_of(opts)
  local given = opts.spec_pattern
  if type(given) == "table" and #given > 0 then
    return given
  end
  return M.DEFAULT_SPEC_PATTERN
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
  local patterns = spec_patterns_of(opts)
  local root_set = {}
  for _, r in ipairs(roots) do
    root_set[slashes(r):gsub("/+$", ""):lower()] = true
  end
  ---Is `dir_rel` (project-relative) a spec root itself? (Case-insensitive: `TESTS` and `tests`.)
  ---@param dir_rel string
  ---@return boolean
  local function is_root_dir(dir_rel)
    return root_set[dir_rel:lower()] == true
  end
  ---Which files below a spec root are specs: a pattern matches the relative path, setup files never.
  ---@param path string
  ---@return boolean
  local function is_root_spec(path)
    path = slashes(path)
    local rel = rel_of(root, path)
    if M.NEVER_SPECS[vim.fs.basename(path)] and is_root_dir(vim.fs.dirname(rel)) then
      return false
    end
    for _, pattern in ipairs(patterns) do
      local ok, found = pcall(string.find, rel, pattern)
      if ok and found then
        return true
      end
    end
    return false
  end

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
  ---@type table<string, Testing.HarnessProfile|false>
  local profiles = {}
  ---The static profile of a harness file, read once; nil when it cannot be read.
  ---@param harness string
  ---@return Testing.HarnessProfile|nil
  local function harness_profile_of(harness)
    if profiles[harness] == nil then
      local text = read_text(harness)
      profiles[harness] = text and harness_profile.profile(text) or false
    end
    return profiles[harness] or nil
  end

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
    local found = walk(dir, origin == "root" and is_root_spec or nil)
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
      -- the same file under two spellings (`tests/` is `TESTS/` on a case-insensitive file system, a root
      -- `TESTS/sandbox` lies below the legacy `tests/`): the directory is compared by its real path
      local dir_key = uv.fs_realpath(vim.fs.dirname(path)) or vim.fs.dirname(path)
      local key = slashes(dir_key) .. "/" .. vim.fs.basename(path)
      if not seen_path[key] then
        seen_path[key] = true
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
            ---Run this file on the project's own harness (dialect h).
            ---@param harness string Absolute path of `harness.lua`.
            ---@param why string
            local function use_harness(harness, why)
              if verdict.dialect ~= "h" then
                entry.sniffed = verdict.dialect
              end
              verdict.dialect, verdict.reason = "h", nil
              entry.dialect, entry.reason = "h", nil
              entry.harness = harness
              verdict.evidence[#verdict.evidence + 1] = "project harness: "
                .. rel_of(root, harness)
                .. " ("
                .. why
                .. ")"
              if not seen_harness[harness] then
                seen_harness[harness] = true
                report({
                  rule = "NEW-43",
                  kind = "project_harness",
                  severity = "info",
                  path = rel_of(root, harness),
                  message = ("specs run on the project's own harness (%s), not on a fixed shim (dialect h, failures collected): %s"):format(
                    rel_of(root, harness),
                    why
                  ),
                })
              end
            end
            if verdict.source == "sniff" then
              if verdict.dialect == "unknown" and verdict.h_style then
                -- helpers of the project's own harness: run on that harness (dialect h)
                local harness = harness_project.find_harness(path, root)
                if harness then
                  use_harness(harness, "the spec uses helpers no fixed shim implements")
                end
              elseif verdict.dialect == "a" or verdict.dialect == "b" or verdict.dialect == "c" then
                -- a shim only stands in for the project's harness when it provably behaves the same
                local harness = harness_project.find_harness(path, root)
                local profile = harness and harness_profile_of(harness)
                if harness and profile then
                  local v, why =
                    harness_profile.verdict(profile, verdict.dialect, verdict.keys, verdict.escapes)
                  if v == "differs" then
                    use_harness(harness, why)
                  else
                    verdict.evidence[#verdict.evidence + 1] = ("project harness %s: %s"):format(
                      rel_of(root, harness),
                      v == "equivalent"
                          and "equivalent to the dialect-" .. verdict.dialect .. " shim"
                        or why
                    )
                  end
                end
              end
            end
            if verdict.dialect == "h" and not entry.harness then
              entry.harness = harness_project.find_harness(path, root)
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
