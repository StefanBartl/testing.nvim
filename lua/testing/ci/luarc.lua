---@module 'testing.ci.luarc'
---@brief The configuration the `luals` preset runs `lua-language-server --check` with: the repository's own, plus
---the library the editor gives it.
---@description
--- `lua-language-server --check` reads only the `.luarc.json` of the workspace. The editor reads it too, but on top of
--- what its LSP setup injects: `$VIMRUNTIME/lua`, the `${3rd}` meta libraries and the `lua/` folder of every plugin
--- the code requires. Without that, `vim` is an undefined global and every type of a dependency is unknown: a check
--- that reports thousands of findings the editor never shows (LLS-01). So every run of the preset (a step of
--- `testing ci`, `testing lint luals`) writes a merged configuration into the state directory and passes it with
--- `--configpath=<file>`:
---
--- - the keys of the repository's `.luarc.json` (or `.luarc.jsonc`), kept as they are. Comments and trailing commas
---   are accepted; a key may be written flat (`"workspace.library"`), nested (`"workspace": { "library": ... }`),
---   with or without the `Lua.` prefix, the forms LuaLS itself reads;
--- - `workspace.library`, when the repository does not set it: `$VIMRUNTIME/lua`, `${3rd}/luv/library`,
---   `${3rd}/busted/library`, `${3rd}/luassert/library` and `<dir>/lua` of every dependency the runner resolves for
---   the project (`deps` of `.testing.lua`, and lib.nvim, which the runner always needs), never the project itself
---   (LLS-02): not its folder, and not another checkout of it (a worktree, a copy) that declares one of its `lua/<ns>`
---   namespaces; such a dependency is left out and the run says so. A repository that sets the key keeps it unchanged and the run says so: the measurement is then the
---   repository's responsibility (LLS-01);
--- - `workspace.ignoreDir`: the repository's entries and `.claude`, `.deps`, `.git` (copies of the workspace,
---   LLS-03).
---
--- A missing `$VIMRUNTIME` or a dependency that cannot be found is a problem of the run (exit 3), never a smaller
--- library; a `.luarc.json` that cannot be read is a configuration error (exit 2). Paths are written with forward
--- slashes.

local M = {}

---The file below the project's state directory.
M.FILE = "luals.luarc.json"

---The workspace's own files, in the order LuaLS looks for them.
M.SOURCES = { ".luarc.json", ".luarc.jsonc" }

---Always ignored: places that hold copies of the workspace (LLS-03).
M.IGNORE = { ".claude", ".deps", ".git" }

---The meta libraries LuaLS ships (what the editor's LSP setup adds besides the runtime).
M.THIRD = { "${3rd}/luv/library", "${3rd}/busted/library", "${3rd}/luassert/library" }

---JSON with comments (`//`, `/* */`) and trailing commas as plain JSON: both are dropped outside strings.
---@param text string
---@return string
function M.lenient(text)
  local out, i, n = {}, 1, #text
  local in_string = false
  while i <= n do
    local c = text:sub(i, i)
    if in_string then
      out[#out + 1] = c
      if c == "\\" then
        out[#out + 1] = text:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_string = false
      end
      i = i + 1
    elseif c == '"' then
      in_string = true
      out[#out + 1] = c
      i = i + 1
    elseif text:sub(i, i + 1) == "//" then
      local nl = text:find("\n", i, true)
      i = nl or (n + 1)
    elseif text:sub(i, i + 1) == "/*" then
      local close = text:find("*/", i + 2, true)
      i = close and (close + 2) or (n + 1)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  -- a comma before a closing bracket (only blanks between; strings were left intact above, and a string never
  -- ends in `,` followed by `]` outside of it)
  local plain = table.concat(out)
  local cleaned = {}
  in_string = false
  i = 1
  n = #plain
  while i <= n do
    local c = plain:sub(i, i)
    if in_string then
      cleaned[#cleaned + 1] = c
      if c == "\\" then
        cleaned[#cleaned + 1] = plain:sub(i + 1, i + 1)
        i = i + 1
      elseif c == '"' then
        in_string = false
      end
    elseif c == '"' then
      in_string = true
      cleaned[#cleaned + 1] = c
    elseif not (c == "," and plain:find("^%s*[%]}]", i + 1)) then
      -- a trailing comma is dropped, everything else kept
      cleaned[#cleaned + 1] = c
    end
    i = i + 1
  end
  return table.concat(cleaned)
end

---The repository's own configuration: the decoded table (`{}` when there is none) and the file it came from.
---@param root string
---@return table|nil config
---@return string|nil file The name of the file that was read (nil: none).
---@return string|nil problem The file is there but is no JSON object.
function M.read(root)
  for _, name in ipairs(M.SOURCES) do
    local path = root .. "/" .. name
    local f = io.open(path, "rb")
    if f then
      local text = f:read("*a") or ""
      f:close()
      -- a BOM is no JSON
      text = text:gsub("^\239\187\191", "")
      local ok, decoded = pcall(vim.json.decode, M.lenient(text))
      if not ok then
        return nil, name, ("%s is not valid JSON: %s"):format(name, tostring(decoded))
      end
      if type(decoded) ~= "table" or (vim.islist(decoded) and next(decoded) ~= nil) then
        return nil, name, ("%s is no JSON object"):format(name)
      end
      return decoded, name
    end
  end
  return {}, nil
end

---@class Testing.Ci.Luarc.Place
---@field t table The table that holds the key.
---@field k string The key in it.

---Collect every place of a setting below `t`: each prefix of `parts` may be one flat key or one level of nesting.
---@param t table
---@param parts string[]
---@param out Testing.Ci.Luarc.Place[]
local function find(t, parts, out)
  for i = 1, #parts do
    local k = table.concat(parts, ".", 1, i)
    local v = t[k]
    if v ~= nil then
      if i == #parts then
        out[#out + 1] = { t = t, k = k }
      elseif type(v) == "table" and not vim.islist(v) then
        find(v, vim.list_slice(parts, i + 1), out)
      end
    end
  end
end

---Every place of the setting `key` (`workspace.library`) in a configuration: flat, nested, with `Lua.` or without.
---@param config table
---@param key string
---@return Testing.Ci.Luarc.Place[]
function M.places(config, key)
  local out = {}
  local parts = vim.split(key, ".", { plain = true })
  find(config, parts, out)
  find(config, vim.list_extend({ "Lua" }, parts), out)
  return out
end

---@param s string
---@return string
local function slashes(s)
  return (s:gsub("\\", "/"))
end

---@param s string
---@return string
local function path_key(s)
  local p = slashes(vim.fs.normalize(s)):gsub("/+$", "")
  return require("testing.platform").is_case_insensitive() and p:lower() or p
end

---The real path of a folder (links, junctions resolved), as a comparable key; the path itself when it does not exist.
---@param s string
---@return string
local function real_key(s)
  return path_key(vim.uv.fs_realpath(s) or s)
end

---The module namespaces of a checkout: the folders and `.lua` files directly below its `lua/`.
---@param dir string
---@return table<string, boolean>
local function namespaces(dir)
  local out = {}
  local handle = vim.uv.fs_scandir(dir .. "/lua")
  while handle do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" then
      out[name] = true
    elseif kind == "file" and name:match("%.lua$") then
      out[name:sub(1, -5)] = true
    end
  end
  return out
end

---Whether a dependency is the project itself: the same folder (also through a link), or another checkout of it (a
---worktree, a copy beside it) that declares one of the project's module namespaces. A library that holds the
---project's own modules declares every class twice (LLS-02, LLS-04).
---@param root string
---@param own table<string, boolean> The project's namespaces.
---@param dir string The dependency's checkout.
---@return string|nil why nil: a different project.
local function same_project(root, own, dir)
  if real_key(dir) == real_key(root) or path_key(dir) == path_key(root) then
    return "the project's own folder"
  end
  local shared = {}
  for ns in pairs(namespaces(dir)) do
    if own[ns] then
      shared[#shared + 1] = "lua/" .. ns
    end
  end
  if #shared == 0 then
    return nil
  end
  table.sort(shared)
  return "another checkout: " .. table.concat(shared, ", ")
end

---@class Testing.Ci.Luarc.Opts
---@field deps? string[] The project's `deps` (`.testing.lua`); nil: read from the project's configuration.
---@field vimruntime? string Replaces `$VIMRUNTIME` (specs); `""` is a missing one.
---@field resolve? fun(name: string, base: string): (Testing.Deps.Resolved|nil, string|nil) Replaces
---`testing.deps.resolve` (specs).
---@field self_dir? string The runner's checkout (where lib.nvim is looked up first); default `testing.deps.self_dir`.

---@class Testing.Ci.Luarc.Built
---@field config table The merged configuration.
---@field own_library boolean The repository sets `workspace.library` itself (kept unchanged).
---@field source? string The repository's file (`.luarc.json`), nil when it has none.
---@field library string[] The library the run checks against (the repository's own when `own_library`).
---@field note string What the run checks with, one line for the step output.

---Build the merged configuration of a project.
---@param root string Absolute, normalised.
---@param o? Testing.Ci.Luarc.Opts
---@return Testing.Ci.Luarc.Built|nil built
---@return string[] problems
---@return boolean infra A problem of the machine (no runtime, a dependency missing), not of the configuration.
function M.build(root, o)
  o = o or {}
  local own, source, bad = M.read(root)
  if not own then
    return nil, { tostring(bad) }, false
  end
  local config = vim.deepcopy(own)
  local problems, infra = {}, false

  -- ignoreDir: the repository's entries (wherever they are written) and the copies of the workspace
  local ignore, seen = {}, {}
  for _, place in ipairs(M.places(config, "workspace.ignoreDir")) do
    local v = place.t[place.k]
    if type(v) == "table" then
      for _, d in ipairs(v) do
        if type(d) == "string" and not seen[d] then
          seen[d] = true
          ignore[#ignore + 1] = d
        end
      end
    elseif type(v) == "string" and not seen[v] then
      seen[v] = true
      ignore[#ignore + 1] = v
    end
    place.t[place.k] = nil
  end
  for _, d in ipairs(M.IGNORE) do
    if not seen[d] then
      seen[d] = true
      ignore[#ignore + 1] = d
    end
  end
  config["workspace.ignoreDir"] = ignore

  local set = M.places(config, "workspace.library")
  if #set > 0 then
    local library = {}
    for _, place in ipairs(set) do
      local v = place.t[place.k]
      for _, entry in ipairs(type(v) == "table" and v or { v }) do
        library[#library + 1] = tostring(entry)
      end
    end
    return {
      config = config,
      own_library = true,
      source = source,
      library = library,
      note = ("%s sets workspace.library itself: it is kept as it is, and what the check sees is the repository's responsibility (LLS-01)"):format(
        tostring(source)
      ),
    },
      problems,
      infra
  end

  local library = {}
  local vr = o.vimruntime
  if vr == nil then
    vr = vim.env.VIMRUNTIME
  end
  if not vr or vr == "" then
    problems[#problems + 1] =
      "$VIMRUNTIME is not set: the check would not know `vim` (run it from Neovim: testing lint, testing ci)"
    infra = true
  else
    local lua_dir = slashes(vim.fs.normalize(vr)):gsub("/+$", "") .. "/lua"
    if vim.fn.isdirectory(lua_dir) ~= 1 then
      problems[#problems + 1] = ("$VIMRUNTIME/lua (%s) is not a directory"):format(lua_dir)
      infra = true
    end
    library[#library + 1] = lua_dir
  end
  vim.list_extend(library, M.THIRD)

  -- the dependencies the runner resolves for the project, lib.nvim first (beside the runner, as the runner finds
  -- it), never the project itself
  local deps = require("testing.deps")
  local resolve = o.resolve or deps.resolve
  local self_dir = o.self_dir or deps.self_dir()
  local names = { "lib.nvim" }
  for _, name in ipairs(o.deps or {}) do
    if not vim.tbl_contains(names, name) then
      names[#names + 1] = name
    end
  end
  local here = path_key(root)
  local own_ns = namespaces(root)
  local added = {}
  local dep_names, left_out = {}, {}
  for _, name in ipairs(names) do
    local r, why
    if name == "lib.nvim" then
      r, why = resolve(name, self_dir)
      if not r then
        r = resolve(name, root)
      end
    else
      r, why = resolve(name, root)
      if not r and path_key(self_dir) ~= here then
        r = resolve(name, self_dir)
      end
    end
    if not r then
      problems[#problems + 1] = ("the library needs the dependency %s: %s"):format(
        name,
        tostring(why or "not found")
      )
      infra = true
    else
      local key = real_key(r.dir)
      local self_why = same_project(root, own_ns, r.dir)
      if self_why then
        left_out[#left_out + 1] = ("%s is this project (%s), left out"):format(name, self_why)
      elseif not added[key] then
        added[key] = true
        library[#library + 1] = slashes(vim.fs.normalize(r.dir)):gsub("/+$", "") .. "/lua"
        dep_names[#dep_names + 1] = name
      end
    end
  end
  if #problems > 0 then
    return nil, problems, infra
  end
  config["workspace.library"] = library
  return {
    config = config,
    own_library = false,
    source = source,
    library = library,
    note = ("library: $VIMRUNTIME/lua, ${3rd} luv busted luassert%s; ignoreDir: %s%s"):format(
      #dep_names > 0 and (", " .. table.concat(dep_names, ", ")) or "",
      table.concat(ignore, ", "),
      #left_out > 0 and ("; " .. table.concat(left_out, "; ")) or ""
    ),
  },
    problems,
    infra
end

---The text of the merged configuration (canonical JSON: sorted keys, forward slashes, no escaped `/`).
---@param config table
---@return string
function M.encode(config)
  return require("lib.nvim.json.canonical").encode(config) .. "\n"
end

---Where the merged configuration of a project goes.
---@param root string
---@param state_dir? string
---@return string
function M.path(root, state_dir)
  local dir = require("testing.history").dir(root, { state_dir = state_dir })
  return slashes(vim.fs.normalize(dir)) .. "/" .. M.FILE
end

---Write a configuration file (its folder is created).
---@param path string
---@param text string
---@return boolean ok
---@return string|nil problem
function M.write(path, text)
  local ok, werr = require("lib.nvim.fs.write.atomic")(path, text, { mkdirp = true })
  if not ok then
    return false, ("cannot write the LuaLS configuration %s: %s"):format(path, tostring(werr))
  end
  return true
end

return M
