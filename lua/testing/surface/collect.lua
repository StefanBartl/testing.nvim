---@module 'testing.surface.collect'
---@brief Reads the surface of a project in a CHILD editor (`testing.rpc`): the project's init, its `setup()`, then `testing.surface.read`.
---@description
--- The child is an embedded, headless, sandboxed Neovim with the guards installed (`docs/CHILD.md`):
--- whatever the plugin's `setup()` does (a spawn, a write outside the sandbox) is caught and cannot
--- reach the developer's editor or files. The runner's own editor never `require`s the plugin.
---
--- What happens in the child, in this order:
---   1. the project's minimal init (`minit`) runs as the `-u` init and puts the project and its
---      dependencies on the runtimepath (plus `opts.deps`, resolved with `testing.deps`; each one is also
---      set as `$<NAME>_DIR` and `opts.env_allow` is inherited, as in a test run; `REPOS_DIR` is
---      inherited always, which a test run does only when `env_allow` lists it);
---   2. `opts.setup_chunk` (a Lua chunk) runs, or else `require(<plugin>).setup(<opts.setup>)` when
---      the module has a `setup` function (`.testing.lua` `setup` are the options);
---   3. `testing.surface.read.read` returns the surface.
---
--- A `setup()` that raises does not fail the read: its message is a note of the surface (entries that
--- were registered before the error are still listed).

local M = {}

---The chunk the child runs (constant text: nothing the project says is spliced into code).
local CHUNK = [[
local a = ...
local err
-- registry keys that exist before the plugin is set up are not its own (a registered action is filed
-- under whatever name the plugin chose: `Session`, not `sessions`)
local before = {}
local kok, km = pcall(require, "lib.nvim.bindings.keymap")
if kok then
  for k in pairs(km.registered()) do before[k] = true end
end
if type(a.setup_chunk) == "string" and a.setup_chunk ~= "" then
  local f, lerr = loadstring(a.setup_chunk, "=surface.setup")
  if not f then
    err = "setup chunk does not compile: " .. tostring(lerr)
  else
    local ok, e = pcall(f)
    if not ok then err = "setup chunk raised: " .. tostring(e) end
  end
else
  local ok, m = pcall(require, a.plugin)
  if not ok then
    err = "require('" .. a.plugin .. "') failed: " .. tostring(m)
  elseif type(m) == "table" and type(rawget(m, "setup")) == "function" then
    -- rawget: a module with a strict __index (lib.nvim) raises on a name it does not have
    local sok, e = pcall(rawget(m, "setup"), a.setup)
    if not sok then err = "setup() raised: " .. tostring(e) end
  end
end
local own = {}
if kok then
  for k in pairs(km.registered()) do
    if not before[k] then own[#own + 1] = k end
  end
end
local surface = require("testing.surface.read").read({
  plugin = a.plugin, root = a.root, kinds = a.kinds, own_keys = own,
})
if err then surface.notes[#surface.notes + 1] = err end
return surface
]]

---@class Testing.Surface.CollectOpts
---@field plugin string Lua module root.
---@field minit? string Absolute path of the project's minimal init.
---@field deps? string[] Directory names of dependencies put on the runtimepath and passed as `$<NAME>_DIR` (`testing.deps`).
---@field env_allow? string[] Extra environment names the child may inherit (`.testing.lua` `env_allow`; `REPOS_DIR` always).
---@field setup? table Options for `setup()`.
---@field setup_chunk? string Lua chunk that sets the plugin up instead of `setup()`.
---@field kinds? string[]
---@field call_timeout_ms? integer
---@field spawn? fun(opts: table): table|nil, string|nil Seam for specs (default `testing.rpc.spawn`).

---Read the surface of the project at `root` in a child editor.
---@param root string
---@param opts Testing.Surface.CollectOpts
---@return Testing.Surface.Surface|nil surface
---@return string|nil err
function M.collect(root, opts)
  local deps = require("testing.deps")
  local rtp = { root }
  local notes = {}
  -- testing.nvim and lib.nvim come from the running checkout, not from the layout around the project
  local self_dir = deps.self_dir()
  local prepend, extra_env = { self_dir }, {}
  local own = { ["testing.nvim"] = true, ["lib.nvim"] = true }
  -- every other dependency reaches the child twice: on the runtimepath and as `$<NAME>_DIR`, since the
  -- child's environment is an allowlist and a minit that asks for its dependency by the variable would
  -- otherwise find nothing (`testing.child.env`)
  local others = {}
  for _, name in ipairs(opts.deps or {}) do
    if own[name] then
      -- provided from the running checkout below; a copy around the project still goes on the rtp
      local r = deps.resolve(name, root)
      if r then
        rtp[#rtp + 1] = r.dir
      end
    else
      others[#others + 1] = name
    end
  end
  local resolved, failures = deps.resolve_all(others, root)
  for _, r in ipairs(resolved) do
    rtp[#rtp + 1] = r.dir
    extra_env[deps.env_name(r.name)] = r.dir
  end
  for _, why in ipairs(failures) do
    notes[#notes + 1] = tostring(why):match("^[^\n]*")
  end
  extra_env[deps.env_name("testing.nvim")] = self_dir
  local lib = deps.resolve("lib.nvim", self_dir)
  if lib then
    prepend[#prepend + 1] = lib.dir
    extra_env[deps.env_name("lib.nvim")] = lib.dir
  end
  -- the project's `env_allow` as in a test run, plus `REPOS_DIR` (the layout a minit falls back to) always:
  -- a test run inherits it only when `env_allow` lists it
  local env_allow = { "REPOS_DIR" }
  vim.list_extend(env_allow, opts.env_allow or {})
  local spawn = opts.spawn or require("testing.rpc").spawn
  local child, err = spawn({
    root = root,
    minit = opts.minit,
    rtp_prepend = prepend,
    extra_env = extra_env,
    env_allow = env_allow,
    rtp = rtp,
    call_timeout_ms = opts.call_timeout_ms or 30000,
    boot_timeout_ms = 30000,
  })
  if not child then
    return nil, "cannot start the child editor: " .. tostring(err)
  end
  local ok, surface = pcall(child.lua, CHUNK, {
    plugin = opts.plugin,
    root = root,
    setup = opts.setup or {},
    setup_chunk = opts.setup_chunk,
    kinds = opts.kinds,
  })
  pcall(child.kill)
  if not ok then
    return nil, "reading the surface in the child failed: " .. tostring(surface)
  end
  if type(surface) ~= "table" or type(surface.entries) ~= "table" then
    return nil, "the child returned no surface"
  end
  surface.notes = type(surface.notes) == "table" and surface.notes or {}
  for _, n in ipairs(notes) do
    surface.notes[#surface.notes + 1] = n
  end
  return surface
end

return M
