---@module 'testing.cli'
---@brief Command-line entry: `nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root> [options]`.
---@description
--- Parses the arguments, runs the in-process driver over the spec files of `<root>/TESTS` and
--- returns the process exit code (the caller, `scripts/testing.lua`, passes it to `os.exit`):
---
---   0  every file passed
---   1  at least one file failed (or errored)
---   2  usage or configuration error (unknown option, no root, no spec found)
---   3  infrastructure error (cannot write or validate the JSON IR, internal error of the driver)
---
--- Options:
---   --json <file>     write the Result-IR (schema_version 1) to <file> and validate it again
---   --rtp <dir>       add <dir> to the runtimepath (repeatable); `<root>` itself is always added
---   --only <text>     run only spec files whose path contains <text> (repeatable)
---   --sentinel <name> last line printed when everything is green (default: the one the project's
---                     own TESTS/run.lua prints, e.g. LIB_TESTS_OK; else TESTING_OK)
---   --no-timings      do not print the timing line
---   -h, --help        this text

local M = {}

M.EXIT_OK = 0
M.EXIT_FAILED = 1
M.EXIT_USAGE = 2
M.EXIT_INFRA = 3

local USAGE = [[
usage: nvim -n -i NONE --headless -u NONE -l scripts/testing.lua <root> [options]

  <root>             project whose TESTS/*_spec.lua files are run (dialect A: `return function(H)`)
  --json <file>      write the Result-IR (schema_version 1) to <file>
  --rtp <dir>        add <dir> to the runtimepath (repeatable)
  --only <text>      run only spec files whose path contains <text> (repeatable)
  --sentinel <name>  last line when everything is green (default: taken from <root>/TESTS/run.lua)
  --no-timings       do not print the timing line
  -h, --help         this text

exit: 0 green, 1 failures, 2 usage/config error, 3 infrastructure error]]

---@param s string
local function out(s)
  io.stdout:write(s, "\n")
end

---@param s string
local function err(s)
  io.stderr:write(s, "\n")
end

---@class Testing.Cli.Args
---@field root? string
---@field json? string
---@field rtp string[]
---@field only string[]
---@field sentinel? string
---@field timings boolean
---@field help boolean

---Parse the arguments. Returns nil and a message on a usage error.
---@param argv string[]
---@return Testing.Cli.Args|nil
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Cli.Args
  local args = { rtp = {}, only = {}, timings = true, help = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local function value()
      i = i + 1
      return argv[i]
    end
    if a == "-h" or a == "--help" then
      args.help = true
    elseif a == "--no-timings" then
      args.timings = false
    elseif a == "--json" or a == "--rtp" or a == "--only" or a == "--sentinel" then
      local v = value()
      if v == nil or v == "" then
        return nil, ("option %s needs a value"):format(a)
      end
      if a == "--json" then
        args.json = v
      elseif a == "--sentinel" then
        args.sentinel = v
      elseif a == "--rtp" then
        args.rtp[#args.rtp + 1] = v
      else
        args.only[#args.only + 1] = v
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown option %s"):format(a)
    elseif args.root == nil then
      args.root = a
    else
      return nil, ("unexpected argument %s (the root is already %s)"):format(a, args.root)
    end
    i = i + 1
  end
  return args, nil
end

---The arguments as a plain list (`arg` also carries the interpreter at index <= 0).
---@param argv string[]
---@return string[]
local function clean_argv(argv)
  local list = {}
  for i = 1, #argv do
    list[i] = tostring(argv[i])
  end
  return list
end

---A spec must not end the run on its own: `os.exit` raises inside the spec (so that file becomes an
---`error` case and the run goes on), and quitting the editor any other way (`:qa!`, `:cquit`)
---is reported as "run did not complete" with exit code 3. Exit code 0 alone is therefore never
---the result of an aborted run. Returns the function that removes the guard again.
---@return fun() release
local function guard_exit()
  local real_exit = os.exit
  rawset(os, "exit", function(code)
    error(
      ("os.exit(%s) called by a spec while the run is active; refused"):format(tostring(code)),
      2
    )
  end)
  local group = vim.api.nvim_create_augroup("TestingRunGuard", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      io.stderr:write(
        "testing: run did not complete: the editor was quit while specs were running\n"
      )
      real_exit(M.EXIT_INFRA)
    end,
  })
  return function()
    rawset(os, "exit", real_exit)
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
end

---Run the driver. Never raises: an internal error becomes exit code 3 with a message on stderr.
---@param argv string[]
---@return integer exit_code
function M.main(argv)
  local args, problem = M.parse(argv)
  if not args then
    err("testing: " .. problem)
    err(USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    out(USAGE)
    return M.EXIT_OK
  end
  if not args.root then
    err("testing: no <root> given")
    err(USAGE)
    return M.EXIT_USAGE
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/+$", "")
  if vim.fn.isdirectory(root) ~= 1 then
    err(("testing: root is not a directory: %s"):format(root))
    return M.EXIT_USAGE
  end

  -- Paths are resolved against the caller's cwd (the specs run in the cwd the caller chose).
  local rtp_dirs = {}
  for _, dir in ipairs(args.rtp) do
    local abs = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))
    if vim.fn.isdirectory(abs) ~= 1 then
      err(("testing: --rtp is not a directory: %s"):format(dir))
      return M.EXIT_USAGE
    end
    rtp_dirs[#rtp_dirs + 1] = abs
  end
  local json_path = args.json and vim.fs.normalize(vim.fn.fnamemodify(args.json, ":p")) or nil

  -- Specs are cwd-dependent (lib.nvim's git specs look at "this repo"), and the old runner is
  -- documented as "run from the repo root". There is deliberately NO chdir here: on Windows
  -- libuv's chdir exports the `=E:` per-drive variable into the environment, which a spec that
  -- audits the environment (spawn_env_spec) then fails on. Say so instead of changing the verdict.
  local here = vim.fs.normalize(vim.fn.getcwd()):gsub("/+$", "")
  if here:lower() ~= root:lower() then
    err(
      ("testing: note: cwd is %s, not the root; specs that look at the repo expect cwd = root"):format(
        here
      )
    )
  end
  vim.opt.rtp:append(root)
  for _, dir in ipairs(rtp_dirs) do
    vim.opt.rtp:append(dir)
  end

  local inproc = require("testing.run.inproc")
  local found = inproc.discover(root, args.only)
  if #found.files == 0 then
    err(
      ("testing: no *_spec.lua file found below %s/TESTS%s"):format(
        root,
        #args.only > 0 and (" matching " .. table.concat(args.only, ", ")) or ""
      )
    )
    return M.EXIT_USAGE
  end
  for _, note in ipairs(found.notes) do
    err("testing: note: " .. note)
  end

  local release = guard_exit()
  local ok, report = pcall(inproc.run, {
    root = root,
    files = found.files,
    argv = clean_argv(argv),
    timings = args.timings,
  })
  release()
  if not ok then
    err("testing: internal error: " .. tostring(report))
    return M.EXIT_INFRA
  end

  if json_path then
    local wrote, werr = inproc.write_json(report.result, json_path, root)
    if not wrote then
      err("testing: " .. tostring(werr))
      return M.EXIT_INFRA
    end
  end
  if report.exit_code == M.EXIT_OK then
    if #found.files < found.total then
      -- A filtered run is not the project's verdict: never print the sentinel a CI or the old
      -- tooling would read as "the whole suite is green".
      out(("\npartial run: %d of %d spec files (no sentinel)"):format(#found.files, found.total))
    else
      -- Transitional sentinel: last line, exactly as lib.nvim's runner prints it (blank line first).
      out("\n" .. (args.sentinel or found.sentinel or "TESTING_OK"))
    end
  end
  return report.exit_code
end

return M
