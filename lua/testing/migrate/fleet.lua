---@module 'testing.migrate.fleet'
---@brief Which Lua modules does a repository `require`, and which repository of the fleet provides them?
---@description
--- Read-only. The fleet is the set of `*.nvim` directories next to the analysed repository (default:
--- its parent directory). A repository provides a module when `lua/<module path>.lua`,
--- `lua/<module path>/init.lua` or the directory `lua/<module path>` exists in it.
---
--- Resolution order of one module (`M.resolve`):
---
---   1. builtin: `vim.*`, LuaJIT's own modules, and `luassert`/`say`/`busted` (testing.nvim's dialect
---      provides those, so no plugin is needed for them);
---   2. self: provided by the analysed repository (`lua/`) or a helper next to its specs (`TESTS/`);
---   3. fleet, exact: another repository provides the whole module path (one repository: `fleet`;
---      several: `ambiguous`, nothing is chosen);
---   4. external, known: the first segment is a well-known plugin (`M.EXTERNALS`), recorded as
---      "external, not in fleet" even when a fleet repository ships a same-named top directory such as
---      `lua/telescope/_extensions`;
---   5. fleet by first segment, when exactly one repository has that top directory (dynamic submodules);
---   6. otherwise `unknown`.
---
--- `require` is read from source text with comments removed. A `pcall(require, ...)` / `pcall(function()
--- ... require ... end)` on the same line makes the occurrence `soft`: a plugin that is only used when
--- present is an optional dependency, never a hard one.

local lua_text = require("testing.discover.lua_text")
local text = require("testing.migrate.text")

local uv = vim.uv or vim.loop

local M = {}

---Well-known plugins outside the fleet: first segment of the module -> directory name of the repository.
---@type table<string, string>
M.EXTERNALS = {
  plenary = "plenary.nvim",
  telescope = "telescope.nvim",
  nui = "nui.nvim",
  snacks = "snacks.nvim",
  ["neo-tree"] = "neo-tree.nvim",
  ["nvim-tree"] = "nvim-tree.lua",
  ["nvim-web-devicons"] = "nvim-web-devicons",
  ["nvim-treesitter"] = "nvim-treesitter",
  cmp = "nvim-cmp",
  blink = "blink.cmp",
  lspconfig = "nvim-lspconfig",
  dap = "nvim-dap",
  dapui = "nvim-dap-ui",
  mini = "mini.nvim",
  ["which-key"] = "which-key.nvim",
  gitsigns = "gitsigns.nvim",
  lualine = "lualine.nvim",
  oil = "oil.nvim",
  luasnip = "LuaSnip",
  conform = "conform.nvim",
  lazy = "lazy.nvim",
  ["fzf-lua"] = "fzf-lua",
  image = "image.nvim",
  notify = "nvim-notify",
  noice = "noice.nvim",
  trouble = "trouble.nvim",
  harpoon = "harpoon",
  toggleterm = "toggleterm.nvim",
  dressing = "dressing.nvim",
  ["markdown-preview"] = "markdown-preview.nvim",
  mason = "mason.nvim",
}

---Top-level modules that need no plugin.
---@type table<string, string>
M.BUILTIN = {
  vim = "neovim",
  ffi = "luajit",
  bit = "luajit",
  jit = "luajit",
  string = "luajit",
  table = "luajit",
  math = "luajit",
  os = "luajit",
  io = "luajit",
  coroutine = "luajit",
  package = "luajit",
  utf8 = "luajit",
  luv = "neovim",
  lpeg = "neovim",
  luassert = "testing.nvim",
  say = "testing.nvim",
  busted = "testing.nvim",
}

---Limits of one scan (a hostile or huge tree must not stall the analysis).
M.MAX_FILES = 4000
M.MAX_FILE_BYTES = 1024 * 1024

---@class Testing.Migrate.Require
---@field module string Dotted module name as written.
---@field soft boolean A `pcall` opens on the same line or one of the two lines above.
---@field top boolean The statement starts in column 0: it runs when the file is loaded, not when a function is called.
---@field file string Path relative to the scanned root.
---@field line integer

---@param path string
---@return string[] names Entries below `path`, sorted; empty when it cannot be read.
local function list_dir(path)
  local out = {}
  local handle = uv.fs_scandir(path)
  if not handle then
    return out
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---@param path string
---@return boolean
local function exists(path)
  return uv.fs_stat(path) ~= nil
end

---Every `*.lua` file below `dir` as paths relative to `base` (no symlinked directory is entered,
---`.git`, `.deps` and `node_modules` are skipped), bounded by `M.MAX_FILES`.
---@param base string
---@param dir_rel string
---@return string[]
local function lua_files(base, dir_rel)
  local out = {}
  local function walk(rel)
    if #out >= M.MAX_FILES then
      return
    end
    local abs = base .. "/" .. rel
    local handle = uv.fs_scandir(abs)
    if not handle then
      return
    end
    local names = {}
    while true do
      local name, kind = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      names[#names + 1] = { name = name, kind = kind }
    end
    table.sort(names, function(a, b)
      return a.name < b.name
    end)
    for _, e in ipairs(names) do
      local child = rel .. "/" .. e.name
      if e.kind == "directory" then
        if e.name ~= ".git" and e.name ~= ".deps" and e.name ~= "node_modules" then
          walk(child)
        end
      elseif e.kind == "file" and e.name:sub(-4) == ".lua" then
        out[#out + 1] = child
      end
    end
  end
  walk(dir_rel)
  return out
end

---`require` calls of one source text. A `require` inside a comment or a string literal is not a call:
---the scan runs on `lua_text.code_only` (positions are kept) and reads the module name from the original.
---@param src string
---@return { module: string, soft: boolean, top: boolean, line: integer }[]
function M.requires_of(src)
  local out = {}
  local code = lua_text.code_only(src)
  local code_lines = vim.split(code, "\n", { plain = true })
  local line, last = 1, 1
  for found in code:gmatch("()%f[%w_]require%f[^%w_]") do
    local pos = found --[[@as integer]]
    -- `x.require(...)` / `x:require(...)` is somebody else's function
    local before = code:sub(1, pos - 1):match("([%.:])%s*$")
    if not before then
      local _, nl = src:sub(last, pos):gsub("\n", "")
      line = line + nl
      last = pos
      local tail = src:sub(pos + 7, pos + 7 + 200)
      local mod = tail:match("^%s*%(?%s*[\"']([%w_%.%-]+)[\"']")
        or tail:match("^%s*,%s*[\"']([%w_%.%-]+)[\"']")
      if mod then
        -- optional when a pcall opens on this line or one of the two lines above it
        local soft = false
        for l = math.max(1, line - 2), line do
          if (code_lines[l] or ""):find("pcall", 1, true) then
            soft = true
          end
        end
        -- load-time: a statement of the file's top level (column 0), not inside a function body
        local top = (code_lines[line] or ""):match("^%S") ~= nil
        out[#out + 1] = { module = mod, soft = soft, top = top, line = line }
      end
    end
  end
  return out
end

---All `require`s below the given directories of `root`.
---@param root string
---@param dirs string[] Directories relative to the root (missing ones are skipped).
---@return Testing.Migrate.Require[]
function M.scan(root, dirs)
  local out = {}
  for _, dir in ipairs(dirs) do
    if uv.fs_stat(root .. "/" .. dir) then
      for _, rel in ipairs(lua_files(root, dir)) do
        local stat = uv.fs_stat(root .. "/" .. rel)
        if stat and stat.size <= M.MAX_FILE_BYTES then
          local src = text.read(root .. "/" .. rel)
          if src then
            for _, r in ipairs(M.requires_of(src)) do
              out[#out + 1] =
                { module = r.module, soft = r.soft, top = r.top, file = rel, line = r.line }
            end
          end
        end
      end
    end
  end
  return out
end

---@class Testing.Migrate.FleetIndex
---@field root string Directory that holds the repositories.
---@field repos string[] Directory names of the `*.nvim` repositories that have a `lua/` directory, sorted.
---@field tops table<string, table<string, true>> repo -> top-level names below its `lua/` (without `.lua`).

---Index the fleet directory.
---@param fleet_root string
---@return Testing.Migrate.FleetIndex
function M.index(fleet_root)
  local idx = { root = fleet_root, repos = {}, tops = {} }
  for _, name in ipairs(list_dir(fleet_root)) do
    if name:match("%.nvim$") and exists(fleet_root .. "/" .. name .. "/lua") then
      idx.repos[#idx.repos + 1] = name
      local tops = {}
      for _, entry in ipairs(list_dir(fleet_root .. "/" .. name .. "/lua")) do
        tops[(entry:gsub("%.lua$", ""))] = true
      end
      idx.tops[name] = tops
    end
  end
  return idx
end

---Does `repo_dir` provide the module `mod` (the whole dotted path)?
---@param repo_dir string
---@param mod string
---@return boolean
local function provides(repo_dir, mod)
  local p = repo_dir .. "/lua/" .. mod:gsub("%.", "/")
  -- a bare directory is a namespace, not a module (`lua/telescope/_extensions/` is not `require("telescope")`)
  return exists(p .. ".lua") or exists(p .. "/init.lua")
end

---@class Testing.Migrate.Resolution
---@field kind "builtin"|"self"|"fleet"|"external"|"ambiguous"|"unknown"
---@field repo? string Directory name of the repository (fleet, external).
---@field candidates? string[] Several fleet repositories (ambiguous).

---Resolve one module.
---@param mod string
---@param idx Testing.Migrate.FleetIndex
---@param self_root string Absolute directory of the analysed repository.
---@return Testing.Migrate.Resolution
function M.resolve(mod, idx, self_root)
  local top = mod:match("^[^%.]+") or mod
  if M.BUILTIN[top] then
    return { kind = "builtin" }
  end
  local path = mod:gsub("%.", "/")
  if provides(self_root, mod) then
    return { kind = "self" }
  end
  -- A helper next to the specs: `require("harness")` of TESTS/harness.lua.
  if exists(self_root .. "/TESTS/" .. path .. ".lua") or exists(self_root .. "/TESTS/" .. path) then
    return { kind = "self" }
  end
  local self_name = vim.fs.basename(self_root)
  local exact = {}
  for _, repo in ipairs(idx.repos) do
    if repo ~= self_name and provides(idx.root .. "/" .. repo, mod) then
      exact[#exact + 1] = repo
    end
  end
  if #exact == 1 then
    return { kind = "fleet", repo = exact[1] }
  elseif #exact > 1 then
    return { kind = "ambiguous", candidates = exact }
  end
  if M.EXTERNALS[top] then
    return { kind = "external", repo = M.EXTERNALS[top] }
  end
  local by_top = {}
  for _, repo in ipairs(idx.repos) do
    if repo ~= self_name and idx.tops[repo][top] then
      by_top[#by_top + 1] = repo
    end
  end
  if #by_top == 1 then
    return { kind = "fleet", repo = by_top[1] }
  end
  return { kind = "unknown" }
end

return M
