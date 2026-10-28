---@module 'testing.ci.presets'
---@brief The built-in steps of `testing ci`: what a repo names instead of copying a command line.
---@description
--- A preset brings its command (or, for the steps of testing.nvim itself, an in-process runner), the tools it
--- needs, how to ask a tool for its version and the error format of its output. A repo writes only what differs:
--- `args` replaces the preset's default arguments, `needs`/`env`/`timeout`/`when` add to it.
---
--- In-process presets (`suite`, `conformance`, `surface`, `budget`) run inside the `testing ci` process through
--- `testing.cli`, not as `nvim -l` inside `nvim -l`; their result lands in the same document.

local M = {}

---@class Testing.Ci.Preset
---@field name string
---@field tool? string The executable (process presets).
---@field fixed? string[] Arguments that always come first (an output format the error format depends on).
---@field args? string[] Default arguments; a step's `args` replaces them.
---@field inprocess? string The `testing.cli` command (`run`, `stamp`, `conformance`, ...).
---@field needs string[]
---@field version_argv? string[]
---@field efm? string Error format, Vim's `errorformat` syntax (quickfix and annotations read it).

---@type table<string, Testing.Ci.Preset>
local PRESETS = {
  stylua = {
    name = "stylua",
    tool = "stylua",
    args = { "--check", "." },
    needs = { "stylua" },
    version_argv = { "stylua", "--version" },
    -- `Diff in <file>:` heads each file that is not formatted
    efm = "Diff in %f:",
  },
  luacheck = {
    name = "luacheck",
    tool = "luacheck",
    -- one finding per line, `file:line:col: (W211) message`, without colours
    fixed = { "--formatter", "plain", "--codes" },
    args = { "." },
    needs = { "luacheck" },
    version_argv = { "luacheck", "--version" },
    efm = "%f:%l:%c: %m",
  },
  suite = {
    name = "suite",
    inprocess = "run",
    args = {},
    needs = {},
  },
  conformance = {
    name = "conformance",
    inprocess = "conformance",
    args = {},
    needs = {},
  },
  surface = {
    name = "surface",
    inprocess = "surface",
    args = {},
    needs = {},
  },
  budget = {
    name = "budget",
    inprocess = "budget",
    args = {},
    needs = {},
  },
}

---@param name any
---@return Testing.Ci.Preset|nil
function M.get(name)
  return type(name) == "string" and PRESETS[name] or nil
end

---@return string[]
function M.names()
  local out = vim.tbl_keys(PRESETS)
  table.sort(out)
  return out
end

---@param list string[]|nil
---@param more string[]|nil
---@return string[]
local function union(list, more)
  local out, seen = {}, {}
  for _, src in ipairs({ list or {}, more or {} }) do
    for _, v in ipairs(src) do
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
  end
  return out
end

---Build a step from a preset (or nil for a repo step) and the step's own keys (already validated).
---@param name string
---@param preset Testing.Ci.Preset|nil
---@param own { run?: string[], args?: string[], needs?: string[], env?: table<string,string>, timeout_ms: integer, os?: table<string,boolean>, stamp?: boolean }
---@return Testing.Ci.Step
function M.step(name, preset, own)
  ---@type Testing.Ci.Step
  local step = {
    name = name,
    preset = preset and preset.name or nil,
    needs = union(preset and preset.needs, own.needs),
    env = vim.deepcopy(own.env or {}),
    timeout_ms = own.timeout_ms,
    os = own.os,
    stamp = false,
    efm = preset and preset.efm or nil,
    version_argv = preset and preset.version_argv or nil,
  }
  if preset and preset.inprocess then
    step.inprocess = preset.inprocess
    step.argv = vim.deepcopy(own.args or preset.args or {})
    -- the suite writes the stamp unless the step says otherwise
    step.stamp = preset.name == "suite" and own.stamp ~= false
  elseif preset then
    local argv = { preset.tool }
    vim.list_extend(argv, preset.fixed or {})
    vim.list_extend(argv, own.args or preset.args or {})
    step.argv = argv
  else
    step.argv = vim.deepcopy(own.run)
  end
  return step
end

return M
