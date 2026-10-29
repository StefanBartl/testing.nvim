---@module 'testing.ci.list'
---@brief `testing ci list [--json] [--root=<dir>]`: the profiles and steps of the `ci` section (what the editor completes).
---@description
--- Runs in the command-line driver, never in the editor: reading the `ci` section executes `.testing.lua`, and the
--- editor does not execute the configuration of a project on a keypress. Exit 0, 2 for a missing or invalid section.

local M = {}

M.EXIT_OK, M.EXIT_USAGE = 0, 2

---@param root string
---@return table|nil list `{ default, profiles = { name = { step, ... } }, steps = { name, ... } }`
---@return string|nil problem
function M.load(root)
  local pipeline, problems = require("testing.ci.schema").load(root)
  if not pipeline then
    return nil, table.concat(problems or {}, "; ")
  end
  local steps = vim.tbl_keys(pipeline.steps)
  table.sort(steps)
  return {
    default = pipeline.default,
    profiles = pipeline.profiles,
    steps = steps,
    derived = pipeline.derived,
  }
end

---@param argv string[] The arguments after `list`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer exit_code
function M.main(argv, sv)
  local json, root = false, "."
  for _, a in ipairs(argv) do
    local value = a:match("^%-%-root=(.+)$")
    if a == "--json" then
      json = true
    elseif value then
      root = value
    else
      sv.err("testing ci list: unknown argument " .. a)
      sv.err("usage: testing ci list [--json] [--root=<dir>]")
      return M.EXIT_USAGE
    end
  end
  root = vim.fs.normalize(vim.fn.fnamemodify(root, ":p")):gsub("/$", "")
  local list, problem = M.load(root)
  if not list then
    sv.err("testing ci list: " .. tostring(problem))
    return M.EXIT_USAGE
  end
  if json then
    sv.out(require("lib.nvim.json.canonical").encode(list))
    return M.EXIT_OK
  end
  local names = vim.tbl_keys(list.profiles)
  table.sort(names)
  for _, name in ipairs(names) do
    sv.out(
      ("%s%s: %s"):format(
        name,
        name == list.default and " (default)" or "",
        table.concat(list.profiles[name], ", ")
      )
    )
  end
  -- a derived pipeline says where each step came from (no `ci` profiles in .testing.lua)
  if list.derived then
    local steps = vim.tbl_keys(list.derived)
    table.sort(steps)
    for _, step in ipairs(steps) do
      sv.out(("derived: %s (%s)"):format(step, list.derived[step]))
    end
  end
  return M.EXIT_OK
end

return M
