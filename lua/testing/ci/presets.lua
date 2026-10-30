---@module 'testing.ci.presets'
---@brief The built-in steps of `testing ci`: what a repo names instead of copying a command line.
---@description
--- A preset brings its command (or, for the steps of testing.nvim itself, an in-process runner), the tools it
--- needs, how to ask a tool for its version and the error format of its output. A repo writes only what differs:
--- `args` replaces the preset's default arguments, `needs`/`env`/`timeout`/`when` add to it.
---
--- In-process presets (`suite`, `conformance`, `surface`, `budget`) run inside the `testing ci` process through
--- `testing.cli`, not as `nvim -l` inside `nvim -l`; their result lands in the same document.
---
--- A preset with `lint` is also a check of `testing lint` (`testing.lint`): one description of a linter for the
--- pipeline, the command line and the editor. `files = true`: the tool takes the files to check after its fixed
--- arguments (they replace the paths of `args`, its options stay); `false`: it checks the whole workspace and the
--- findings are filtered afterwards. `fix` is the command that rewrites the files (`--fix`), `ext` the file
--- extensions the check reads, `on_save = false` keeps an expensive check out of the check on save. `file_args` go
--- before named files (stylua: its ignore file applies to them too), `valued` names the options of `args` whose
--- value is the next argument (not a path), `path_option` the option that carries the path (`--check=<dir>`).

local M = {}

---@class Testing.Ci.Preset
---@field name string
---@field tool? string The executable (process presets).
---@field fixed? string[] Arguments that always come first (an output format the error format depends on).
---@field args? string[] Default arguments; a step's `args` replaces them.
---@field inprocess? string The `testing.cli` command (`run`, `stamp`, `conformance`, ...).
---@field needs string[]
---@field version_argv? string[]
---@field efm? string|string[] Error format (`testing.ci.report.compile`: %f %l %c %m); alternatives as a list.
---@field lint? Testing.Ci.PresetLint The preset is a check of `testing lint`.

---@class Testing.Ci.PresetLint
---@field files boolean The tool takes files (else it checks the whole workspace, the findings are filtered).
---@field fix? string[] The command that rewrites files (the files, or the step's args with `--all`, follow it).
---@field ext string[] File extensions the check reads (without the dot).
---@field on_save? boolean false: never on save (default true).
---@field message? string The text of a finding whose error format has no `%m`.
---@field file_args? string[] Arguments that go before named files (check and fix).
---@field valued? string[] Options of `args` that take the next argument as their value.
---@field path_option? string The prefix of the argument that names the path (`--check=`); else a path is an argument
---that is no option.

---@type table<string, Testing.Ci.Preset>
local PRESETS = {
  stylua = {
    name = "stylua",
    tool = "stylua",
    -- `--check` is fixed: `args` names what is checked, never turns the step into a formatter
    fixed = { "--check" },
    args = { "." },
    needs = { "stylua" },
    version_argv = { "stylua", "--version" },
    -- `Diff in <file>:` heads each file that is not formatted
    efm = "Diff in %f:",
    lint = {
      files = true,
      fix = { "stylua" },
      ext = { "lua" },
      message = "not formatted (stylua)",
      -- a file named on the command line is formatted even when `.styluaignore` excludes it, unless this is given
      file_args = { "--respect-ignores" },
      valued = {
        "--config-path",
        "-f",
        "--glob",
        "-g",
        "--column-width",
        "--indent-type",
        "--indent-width",
        "--line-endings",
        "--quote-style",
        "--call-parentheses",
        "--collapse-simple-statement",
        "--syntax",
        "--num-threads",
        "--stdin-filepath",
      },
    },
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
    lint = {
      files = true,
      ext = { "lua" },
      valued = {
        "--config",
        "--default-config",
        "--std",
        "--formatter",
        "--cache",
        "--jobs",
        "-j",
        "--filename",
        "--max-line-length",
        "--max-code-line-length",
        "--max-string-line-length",
        "--max-comment-line-length",
        "--max-cyclomatic-complexity",
        "--exclude-files",
        "--include-files",
      },
    },
  },
  luals = {
    name = "luals",
    tool = "lua-language-server",
    -- the level and the format the error format depends on; `args` names what is checked (`--check=<dir>`: a
    -- single file is not checked at all, it reports "no problems")
    fixed = { "--checklevel=Warning", "--check_format=pretty" },
    args = { "--check=." },
    needs = { "lua-language-server" },
    version_argv = { "lua-language-server", "--version" },
    -- `lua/a.lua:2:28 [Warning] Undefined global `x`. (undefined-global)`, coloured and after progress text: the
    -- matcher strips the escapes and the progress (testing.ci.report.normalize_line); a path may hold blanks (%F)
    efm = "%F:%l:%c %m",
    -- the whole workspace in seconds: never on save
    lint = { files = false, on_save = false, ext = { "lua" }, path_option = "--check=" },
  },
  suite = {
    name = "suite",
    inprocess = "run",
    args = {},
    needs = {},
    -- no error format: the findings come from the run's Result-IR (testing.ci.report.ir_findings)
  },
  conformance = {
    name = "conformance",
    inprocess = "conformance",
    -- a gate: without it `testing conformance` only reports and the step is always green
    args = { "--gate" },
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

---The presets that are checks of `testing lint`, sorted.
---@return string[]
function M.lint_names()
  local out = {}
  for _, name in ipairs(M.names()) do
    if PRESETS[name].lint then
      out[#out + 1] = name
    end
  end
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
---@param own { run?: string[], args?: string[], needs?: string[], env?: table<string,string>, timeout_ms: integer, os?: table<string,boolean>, stamp?: boolean, skip_exit?: integer }
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
    skip_exit = own.skip_exit,
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
