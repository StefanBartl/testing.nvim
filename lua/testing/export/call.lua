---@module 'testing.export.call'
---@brief `testing call fleet|repo`: print a document of the contract `testing-export/1` on stdout.
---@description
--- ```
--- testing call fleet [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]
---                    [--export] [--remote] [--state-dir=<dir>]
--- testing call repo [<dir>] [--export] [--remote] [--state-dir=<dir>]
--- ```
---
--- One line of canonical JSON (keys sorted, no whitespace) on stdout, nothing else; a problem is one line on stderr.
--- The local form (default) carries the absolute `root` of the repositories, for a process on this machine;
--- `--export` gives the form of an export folder: no absolute path, refused when the leak detector still finds one,
--- and only the repositories the data classes of this device release (`public`, `internal`; `lib.nvim.data_classes`,
--- fail-closed as `testing export --out`): `fleet` counts the others in `excluded_by` without naming them, `repo` of
--- a repository that is not released prints nothing and exits 2.
--- `--remote` asks the CI adapter (`testing ci remote`: GitHub, network, a read-only token); without it `ci_remote`
--- is `null` (not asked); asked without a record it is `state = "unknown"`. Runs nothing: no suite, no pipeline, no `.testing.lua`; it writes nothing
--- either, except the CI adapter's ETag cache in the state directory with `--remote`.
---
--- Exit codes: 0 the document was printed, 2 usage (an unknown method or option, a root that is not a directory, no
--- repository) or `repo --export` of a repository the data classes do not release, 3 the document could not be built
--- (it would leak a path, it is too large, an internal error).

local M = {}

M.EXIT_OK, M.EXIT_USAGE, M.EXIT_INFRA = 0, 2, 3

M.METHODS = { fleet = true, repo = true }

M.USAGE = table.concat({
  "usage: testing call fleet [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]",
  "                          [--export] [--remote] [--state-dir=<dir>]",
  "       testing call repo [<dir>] [--export] [--remote] [--state-dir=<dir>]",
  "  fleet               one row per repository (document testing-export/1, kind fleet)",
  "  repo                one repository with its red cases (kind repo; <dir> defaults to the current directory)",
  "  --repos-root=<dir>  the repositories below <dir> (workflows or a .testing.lua; no vault; repeatable)",
  "  --include=<names>   also these directory names below --repos-root (besides lib.nvim)",
  "  --exclude=<names>   leave these directory names out",
  "  --export            the export form: no absolute path, only the repositories the data classes of this",
  "                      device release (default: the local form with root, all repositories)",
  "  --remote            ask the CI adapter (GitHub); without it ci_remote is null",
  "  --state-dir=<dir>   the state directory (default: stdpath('state'))",
  "  stdout: one line of canonical JSON; runs nothing (--remote: the adapter's ETag cache)",
  "  exit: 0 printed, 2 usage or a repository not released (repo --export), 3 the document could not be built",
}, "\n")

---@class Testing.Export.Call.Args
---@field method string
---@field roots string[]
---@field repos_roots string[]
---@field include string[]
---@field exclude string[]
---@field export boolean
---@field remote boolean
---@field state_dir? string
---@field help boolean

local VALUED = { ["repos-root"] = true, include = true, exclude = true, ["state-dir"] = true }
local FLEET_ONLY = { ["repos-root"] = true, include = true, exclude = true }

---@param argv string[] The arguments after `call`.
---@return Testing.Export.Call.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Export.Call.Args
  local args = {
    method = "",
    roots = {},
    repos_roots = {},
    include = {},
    exclude = {},
    export = false,
    remote = false,
    help = false,
  }
  local first = argv[1]
  if first == nil or first == "-h" or first == "--help" then
    args.help = true
    return args
  end
  if not M.METHODS[first] then
    return nil, ("unknown method %s (fleet, repo)"):format(first)
  end
  args.method = first
  local i = 2
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif (key == "export" or key == "remote") and value == nil then
      args[key] = true
    elseif key and VALUED[key] then
      if FLEET_ONLY[key] and args.method ~= "fleet" then
        return nil, ("--%s is an option of fleet, not of %s"):format(key, args.method)
      end
      if value == nil then
        i = i + 1
        value = argv[i]
        if value ~= nil and value:sub(1, 1) == "-" then
          return nil, ("--%s needs a value (got the option %s)"):format(key, value)
        end
      end
      if value == nil or value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "state-dir" then
        args.state_dir = value
      else
        -- the one VALUED key left: include or exclude
        local list = key == "include" and args.include or args.exclude
        for _, name in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
          if not require("testing.deps").is_valid_name(name) then
            return nil, ("--%s: %s is not a directory name"):format(key, name)
          end
          list[#list + 1] = name
        end
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.roots[#args.roots + 1] = a
    end
    i = i + 1
  end
  if args.method == "repo" and #args.roots > 1 then
    return nil, "repo takes one directory"
  end
  return args
end

---`testing call ...`.
---@param argv string[] The arguments after `call`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing call: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local export = require("testing.export")
  local state_dir = args.state_dir
      and vim.fs.normalize(vim.fn.fnamemodify(args.state_dir, ":p")):gsub("([^:/])/+$", "%1")
    or sv.state_dir
  ---@type Testing.Export.Opts
  local opts = {
    roots = args.roots,
    repos_roots = args.repos_roots,
    include = args.include,
    exclude = args.exclude,
    form = args.export and "export" or "local",
    state_dir = state_dir,
    remote = args.remote,
  }
  -- what is a usage problem (a directory that is not there, nothing found) is told apart from a build failure
  if args.method == "fleet" then
    for _, dir in ipairs(vim.list_extend(vim.list_slice(args.roots, 1), args.repos_roots)) do
      if vim.fn.isdirectory(dir) ~= 1 then
        sv.err(("testing call: %s is not a directory"):format(dir))
        return M.EXIT_USAGE
      end
    end
    local dirs, info = export.resolve(opts)
    if not dirs or #dirs == 0 then
      sv.err("testing call: " .. (dirs and "no repository found" or tostring(info)))
      return M.EXIT_USAGE
    end
    ---@cast info { excluded: string[], missing: string[] }
    if #info.missing > 0 then
      sv.err(
        "testing call: included but not below any --repos-root: "
          .. table.concat(info.missing, ", ")
      )
    end
  else
    local dir = args.roots[1] or "."
    if vim.fn.isdirectory(dir) ~= 1 then
      sv.err(("testing call: %s is not a directory"):format(dir))
      return M.EXIT_USAGE
    end
  end
  local doc, err, kind
  if args.method == "fleet" then
    doc, err = export.fleet(opts)
  else
    doc, err, kind = export.repo(args.roots[1] or ".", opts)
  end
  if not doc then
    sv.err("testing call: " .. tostring(err))
    return kind == export.REFUSED and M.EXIT_USAGE or M.EXIT_INFRA
  end
  local text, eerr = export.encode(doc)
  if not text then
    sv.err("testing call: " .. tostring(eerr))
    return M.EXIT_INFRA
  end
  -- as `testing export`: an export form that released less than asked for says why (no areas.json, an unusable one)
  if type(doc.classes) == "table" and type(doc.classes.problem) == "string" then
    sv.err("testing call: note: " .. doc.classes.problem)
  end
  sv.out(text)
  return M.EXIT_OK
end

return M
