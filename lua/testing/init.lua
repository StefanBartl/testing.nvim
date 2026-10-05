---@module 'testing'
---@brief Public facade of testing.nvim.
---@description
--- `setup(opts)` merges the options (see `testing.config`), registers `:Testing` and the keymap
--- actions. The test runner itself is not implemented yet; this is the skeleton it will grow in.

local M = {}

---Merge options, register the command and the keymaps. Safe to call twice.
---@param opts? Testing.ConfigOptions
---@return Testing.Module
function M.setup(opts)
  local config = require("testing.config")
  local problems = config.setup(opts)
  if #problems > 0 then
    require("testing.notify").get().warn("setup(): " .. table.concat(problems, "; "))
  end
  require("testing.bindings.usrcmds").register()
  require("testing.bindings.keymaps").register(config.get())
  return M
end

---The effective configuration (a reference, do not mutate).
---@return Testing.Config
function M.get_config()
  return require("testing.config").get()
end

---Generate the test setup of a plugin repository (what `:Testing init` does): `.testing.lua`,
---`TESTS/minimal_init.lua`, `scripts/test.sh`, a CI workflow. Never overwrites unless `opts.force`.
---@param root string
---@param opts? Testing.Scaffold.Opts
---@return Testing.Scaffold.Result
function M.scaffold(root, opts)
  return require("testing.scaffold").init(root, opts)
end

---Run the specs of a project in a headless child nvim and show the result (notification and a
---quickfix list of the failures). Returns at once; `on_done` receives the verdict.
---@param opts? { root?: string, flags?: Testing.Child.Flags }
---@param on_done? fun(verdict: Testing.Child.Verdict)
---@return boolean started
---@return string|nil err
function M.run(opts, on_done)
  opts = opts or {}
  local usrcmds = require("testing.bindings.usrcmds")
  local child_opts = { root = usrcmds.resolve_root(opts.root), flags = opts.flags }
  local ok, err = require("testing.bindings.child").start("run", child_opts, on_done)
  if ok then
    usrcmds.last_run = { sub = "run", opts = child_opts }
  end
  return ok, err
end

---@type Testing.Module
return M
