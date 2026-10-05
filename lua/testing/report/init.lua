---@module 'testing.report'
---@brief Reporter registry: reporter names to modules, and `run_reporters` which renders a result.
---@description
--- A reporter is a module with `render(result, opts) -> string[]` (lines, no trailing newlines) and,
--- optionally, `finish(result, opts) -> ok|nil, err|nil` for a side output (the GitHub step
--- summary). Reporters consume the Result-IR only (guard rail L1) and never print: the caller
--- prints the returned lines of the reporters that have no `path`, so the run driver owns stdout.
---
--- `run_reporters` never raises. An unknown reporter name, a reporter that throws, or a path that
--- cannot be written is an `err` on that entry; the other reporters still run, and the caller turns
--- an `err` into exit code 3 (infrastructure error), never into a pass.

local M = {}

---@type table<string, string>
M.REPORTERS = {
  term = "testing.report.term",
  github = "testing.report.github",
  junit = "testing.report.junit",
}

---Reporter names in a stable order (for `--help`, `:checkhealth`, docs).
---@return string[]
function M.names()
  local names = {}
  for name in pairs(M.REPORTERS) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Resolve a reporter name to its module.
---@param name any
---@return table|nil module
---@return string|nil err
function M.resolve(name)
  if type(name) ~= "string" or not M.REPORTERS[name] then
    return nil,
      ("unknown reporter %s (known: %s)"):format(vim.inspect(name), table.concat(M.names(), ", "))
  end
  local ok, mod = pcall(require, M.REPORTERS[name])
  if not ok then
    return nil, ("reporter %q cannot be loaded: %s"):format(name, tostring(mod))
  end
  return mod, nil
end

---@class Testing.Report.Spec
---@field name string Reporter name (`term`, `github`, `junit`).
---@field path? string Write the lines to this file (atomically) instead of returning them for stdout.
---@field opts? table Options of that reporter (see its module).

---@class Testing.Report.Output
---@field reporter string
---@field lines string[] The rendered lines (also when written, for tests and `--json`-style reuse).
---@field path? string Set when the lines were written to this file.
---@field written? boolean True when `path` was written successfully.
---@field extra? { ok: boolean|nil, err: string|nil } Result of the reporter's `finish` hook.
---@field err? string Why this reporter produced nothing (the others are unaffected).

---@class Testing.Report.RunOpts
---@field reporters (string|Testing.Report.Spec)[] Names or specs; default `{ "term" }`.
---@field defaults? table<string, table> Per-reporter default options (a spec's own `opts` win).

---@param path any
---@return boolean ok
---@return string|nil err
local function check_path(path)
  if type(path) ~= "string" or path == "" then
    return false, "report path must be a non-empty string"
  end
  if path:find("\0", 1, true) or path:find("[\r\n]") then
    return false, "report path contains a control character"
  end
  return true, nil
end

---Render a result through the requested reporters.
---@param result Testing.Result
---@param opts? Testing.Report.RunOpts
---@return Testing.Report.Output[] outputs In request order, one per reporter.
---@return string[] errors One message per failed reporter (empty when everything worked).
function M.run_reporters(result, opts)
  opts = opts or {}
  local requested = opts.reporters
  if type(requested) ~= "table" or #requested == 0 then
    requested = { "term" }
  end
  ---@type Testing.Report.Output[]
  local outputs, errors = {}, {}

  for _, entry in ipairs(requested) do
    local spec = type(entry) == "string" and { name = entry } or entry
    local name = type(spec) == "table" and spec.name or nil
    ---@type Testing.Report.Output
    local out = { reporter = tostring(name), lines = {} }
    outputs[#outputs + 1] = out

    local mod, rerr = M.resolve(name)
    if not mod then
      out.err = rerr
    else
      local ropts =
        vim.tbl_extend("force", (opts.defaults and opts.defaults[name]) or {}, spec.opts or {})
      local ok, lines = pcall(mod.render, result, ropts)
      if not ok then
        out.err = ("reporter %q failed: %s"):format(name, tostring(lines))
      elseif type(lines) ~= "table" then
        out.err = ("reporter %q returned no lines"):format(name)
      else
        out.lines = lines
        if type(mod.finish) == "function" then
          local fok, fres, ferr = pcall(mod.finish, result, ropts)
          out.extra = fok and { ok = fres, err = ferr } or { ok = false, err = tostring(fres) }
          if out.extra.ok == false then
            out.err = ("reporter %q: %s"):format(name, tostring(out.extra.err))
          end
        end
        if spec.path ~= nil then
          out.path = spec.path
          local pok, perr = check_path(spec.path)
          if pok then
            local text = table.concat(lines, "\n") .. "\n"
            pok, perr = require("lib.nvim.fs.write.atomic")(spec.path, text, { mkdirp = true })
          end
          out.written = pok == true
          if not pok then
            out.err = ("reporter %q: cannot write %s: %s"):format(
              name,
              tostring(spec.path),
              tostring(perr)
            )
          end
        end
      end
    end
    if out.err then
      errors[#errors + 1] = out.err
    end
  end
  return outputs, errors
end

return M
