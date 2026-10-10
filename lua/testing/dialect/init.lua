---@module 'testing.dialect'
---@brief Registry of the spec dialects: one `run_file` per dialect, same signature.
---@description
--- A dialect turns one spec file into cases of the IR:
---
---   `run_file(a, spec, opts) -> cases`
---
--- with `a` the collecting assertion context (`testing.core.assert`), `spec` the discovered file
--- (`{ path = absolute, rel = relative to the project root }`, see `testing.discover`) and `opts` the
--- optional `{ on_case = fun(case) }` progress hook (busted also takes `select` / `dry`). The returned
--- cases are finished (status computed by the kernel); the caller adds them to the result.
---
---   a, b, c  one case per file (`<rel>::<file name>`): the `H` object of the three harness families
---   d        one case per file, listening to the plugin's own `harness` module
---   h        one case per file, `return function(H)` on the project's own `harness.lua` (collecting)
---   busted   one case per `it`, ids `<rel>::<describe>::...::<it>`
---   script   a self-running script (`nvim -l file`, own counters, exit code): it can only run in its
---            own child process, so `run_file` answers a visible `error` case; the child driver
---            (`testing.run`) runs it and reads the verdict with `testing.dialect.script`
---
--- Every dialect runs its cases under the assertion policy (`testing.policy`): `opts.assertions`
--- ("error" default, or "warn") decides what a case without assertions is, and a case without
--- assertions that printed a `skip ...` line is a `skip`.
---
--- Helpers for the driver: `unrunnable` turns a file that cannot run (unknown dialect, listed but
--- missing, unreadable) into a visible `error` case instead of dropping it.

local policy = require("testing.policy")

local M = {}

---@alias Testing.Dialect.Name "a"|"b"|"c"|"d"|"h"|"busted"|"script"

---@class Testing.Dialect.Spec
---@field path string Absolute path.
---@field rel string Path relative to the project root.
---@field tests_dir? string Directory of the plugin's harness (dialect d); default: the spec's directory.
---@field harness? string Dialect h: absolute path of the project's `harness.lua` (default: searched upwards from the spec, below `root`).
---@field root? string Dialect h: the project root that ends the upward search.

---@class Testing.Dialect.RunOpts
---@field on_case? fun(case: Testing.Result.Case)
---@field select? fun(id: string): boolean busted only: run only the cases this accepts.
---@field dry? boolean busted only: run the describe bodies and list the case ids, run no `it`.
---@field assertions? "error"|"warn" What a case without assertions is (`testing.policy`); default `error`.

---@alias Testing.Dialect.RunFile fun(a: Testing.Assert.Context, spec: Testing.Dialect.Spec, opts?: Testing.Dialect.RunOpts): Testing.Result.Case[], table[]|nil

---@type Testing.Dialect.Name[]
M.NAMES = { "a", "b", "c", "d", "h", "busted", "script" }

---Dialects that cannot run in the driver's own process (they end the process or own the exit code).
---@type table<string, true>
M.CHILD_ONLY = { script = true }

---@param builder fun(a: table): table
---@return Testing.Dialect.RunFile
local function h_style(builder)
  return function(a, spec, opts)
    local case = policy.guard(opts, function()
      return a.run_case(
        { file = spec.rel, name = vim.fs.basename(spec.rel), spec_path = spec.path },
        function()
          -- One `H` per file, bound to this case: a late call (timer, `vim.schedule`) after the file
          -- ended cannot land on the next file's case.
          local H = builder(a.scope())
          local run = dofile(spec.path)
          if type(run) ~= "function" then
            error(
              ("%s must return `function(H)`, got %s"):format(
                spec.rel,
                run == nil and "nothing" or type(run)
              ),
              0
            )
          end
          run(H)
        end
      )
    end)
    if opts and opts.on_case then
      opts.on_case(case)
    end
    return { case }
  end
end

---@type table<string, fun(): Testing.Dialect.RunFile>
local LOADERS = {
  a = function()
    return h_style(require("testing.dialect.harness_a").new)
  end,
  b = function()
    return h_style(require("testing.dialect.harness_b").new)
  end,
  c = function()
    return h_style(require("testing.dialect.harness_c").new)
  end,
  d = function()
    return require("testing.dialect.harness_d").run_file
  end,
  h = function()
    return require("testing.dialect.harness_project").run_file
  end,
  script = function()
    return function(a, spec, opts)
      return M.unrunnable(
        a,
        spec,
        "dialect script runs a self-running script: it needs its own child process (isolated run), not the driver's",
        opts
      )
    end
  end,
  busted = function()
    return require("testing.dialect.busted").run_file
  end,
}

---The `run_file` of a dialect, or nil for a name that is not one (`unknown`, `testing`, typos).
---@param name string
---@return Testing.Dialect.RunFile|nil
function M.get(name)
  local load = LOADERS[name]
  if not load then
    return nil
  end
  return load()
end

---Run one file in the named dialect. A name that is no dialect is a visible `error` case, never a
---silent drop.
---@param name string
---@param a Testing.Assert.Context
---@param spec Testing.Dialect.Spec
---@param opts? Testing.Dialect.RunOpts
---@return Testing.Result.Case[] cases
---@return table[]|nil list busted: the case ids (see `Testing.Busted.Listing`).
function M.run_file(name, a, spec, opts)
  local run = M.get(name)
  if not run then
    return M.unrunnable(a, spec, ("dialect %q cannot run this file"):format(tostring(name)), opts)
  end
  return run(a, spec, opts)
end

---A file that cannot run becomes one case with status `error` and the reason as its message.
---@param a Testing.Assert.Context
---@param spec Testing.Dialect.Spec
---@param message string
---@param opts? Testing.Dialect.RunOpts
---@return Testing.Result.Case[] cases
function M.unrunnable(a, spec, message, opts)
  a.begin_case({ file = spec.rel, name = vim.fs.basename(spec.rel) })
  local case = a.current() --[[@as Testing.Result.Case]]
  case.status = "error"
  case.error = { message = message, traceback = message }
  a.end_case()
  if opts and opts.on_case then
    opts.on_case(case)
  end
  return { case }
end

return M
