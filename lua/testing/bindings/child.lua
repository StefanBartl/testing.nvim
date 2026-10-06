---@module 'testing.bindings.child'
---@brief Runs the command-line driver in a headless child nvim for `:Testing` and shows the result.
---@description
--- A run from the editor never happens in the editor's own process: specs change globals, the
--- runtimepath and the current directory, and a crashing or hanging spec must not take the
--- session down. So the driver (`scripts/testing.lua`) is started as a child
---
---   nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua <sub> <root> [flags]
---
--- with an ARGV LIST (SEC-01/02: no shell, no string that is parsed again) and the project root as
--- the working directory. Every flag is passed as `--name=value`, so a value that starts with `--`
--- stays a value. The result IR goes to a temporary file (`--json`), is read back, and the failures
--- become a quickfix list (UI-36) plus one summary notification.
---
--- The verdict is the child's exit code (0 green, 1 failed, 2 usage/config, 3 infrastructure); a
--- summary is never `info` unless the code is 0, and a missing or unreadable IR after code 1 is
--- reported as such rather than as "0 failed".
---
--- Why `vim.system` and not `lib.nvim.system.job`: the job wrapper has neither a `cwd` nor an exit
--- callback yet, and the specs of a project look at "this repo" through the working directory.

local M = {}

---Hard limit of one child run; the driver has its own, shorter, per-file timeouts.
M.TIMEOUT_MS = 900000

---Subcommands of the driver that this module starts.
---@type string[]
M.SUBCOMMANDS = { "run", "list", "doctor" }

-- Types: lua/testing/bindings/@types/init.lua (Testing.Child.Flags, .Opts, .Verdict).

---The driver script of this checkout.
---@return string
function M.driver()
  return require("testing.deps").self_dir() .. "/scripts/testing.lua"
end

---@param argv string[]
---@param name string
---@param values string[]|string|nil
local function add_flag(argv, name, values)
  if values == nil then
    return
  end
  if type(values) == "string" then
    values = { values }
  end
  for _, v in ipairs(values) do
    argv[#argv + 1] = ("--%s=%s"):format(name, v)
  end
end

---The argument list of the child process (nothing is started).
---@param sub "run"|"list"|"doctor"
---@param opts Testing.Child.Opts
---@return string[] argv
---@return string|nil err
function M.build_argv(sub, opts)
  if not vim.tbl_contains(M.SUBCOMMANDS, sub) then
    return {}, ("unknown subcommand %s"):format(vim.inspect(sub))
  end
  if type(opts) ~= "table" or type(opts.root) ~= "string" or opts.root == "" then
    return {}, "no project root"
  end
  local argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    M.driver(),
    sub,
    opts.root,
  }
  local flags = opts.flags or {}
  add_flag(argv, "file", flags.file)
  add_flag(argv, "filter", flags.filter)
  add_flag(argv, "reporter", flags.reporter)
  add_flag(argv, "rtp", flags.rtp)
  add_flag(argv, "config", flags.config)
  if sub == "run" and opts.json then
    add_flag(argv, "json", opts.json)
  end
  return argv
end

---`<REPO>/x`, a relative path or an absolute one, as an absolute path below `root`.
---@param file string
---@param root string
---@return string
local function resolve_path(file, root)
  if file:sub(1, 6) == "<REPO>" then
    return root .. file:sub(7)
  end
  if file:sub(1, 1) == "/" or file:match("^%a:") then
    return file
  end
  return root .. "/" .. file
end

---@param s any
---@return string
local function one_line(s)
  local text = tostring(s or ""):gsub("%s+", " ")
  return #text > 300 and (text:sub(1, 297) .. "...") or text
end

---@type table<string, true>
local FAILED = { fail = true, error = true, timeout = true, crash = true, xpass = true }

---Quickfix items for the cases of an IR that did not pass.
---@param ir table Decoded `Testing.Result`.
---@param root string
---@return table[]
function M.failure_items(ir, root)
  local items = {}
  for _, case in ipairs(type(ir) == "table" and ir.cases or {}) do
    if type(case) == "table" and FAILED[case.status] then
      local file, line, why = case.file, case.line, nil
      for _, a in ipairs(type(case.assertions) == "table" and case.assertions or {}) do
        if type(a) == "table" and a.ok == false then
          why = a.msg or ("expected " .. tostring(a.expected) .. ", got " .. tostring(a.actual))
          if type(a.file) == "string" and a.file ~= "" then
            file, line = a.file, a.line or line
          end
          break
        end
      end
      if not why and type(case.error) == "table" then
        why = case.error.message
      end
      if not why then
        why = case.reason
      end
      if type(file) == "string" and file ~= "" then
        items[#items + 1] = {
          filename = resolve_path(file, root),
          lnum = type(line) == "number" and line or 1,
          text = one_line(("[%s] %s%s"):format(case.status, case.id, why and (": " .. why) or "")),
          type = "E",
        }
      end
    end
  end
  return items
end

---Read and decode the IR a run wrote; nil with a reason when there is none.
---@param path string|nil
---@return table|nil ir
---@return string|nil err
local function read_ir(path)
  if not path then
    return nil, "no IR path"
  end
  local text, rerr = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, tostring(rerr)
  end
  local ir, derr = require("lib.nvim.json").decode(text)
  if type(ir) ~= "table" or type(ir.summary) ~= "table" then
    return nil, "not a result IR: " .. tostring(derr)
  end
  return ir
end

---@param text string|nil
---@param n integer
---@return string
local function head(text, n)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
    if #lines >= n then
      break
    end
  end
  return table.concat(lines, "\n")
end

---Turn the finished child into what the user is shown. Pure apart from reading the IR file.
---@param sub "run"|"list"|"doctor"
---@param res { code: integer, signal?: integer, stdout?: string, stderr?: string }
---@param opts Testing.Child.Opts
---@return Testing.Child.Verdict
function M.interpret(sub, res, opts)
  local code = res.code or -1
  local stderr = head(res.stderr, 8)
  if res.signal and res.signal ~= 0 then
    return {
      level = "error",
      message = ("the test process was killed by signal %d (limit %d s); no verdict"):format(
        res.signal,
        math.floor(M.TIMEOUT_MS / 1000)
      ),
      items = {},
    }
  end

  if sub ~= "run" then
    local lines = vim.split(vim.trim(res.stdout or ""), "\n", { plain = true })
    if code ~= 0 then
      return {
        level = "error",
        message = ("testing %s failed (exit %d)\n%s"):format(sub, code, stderr),
        items = {},
        lines = #lines > 0 and lines[1] ~= "" and lines or nil,
      }
    end
    return { level = "info", message = ("testing %s done"):format(sub), items = {}, lines = lines }
  end

  if code == 0 then
    local ir = read_ir(opts.json)
    local s = ir and ir.summary or nil
    return {
      level = "info",
      message = s and ("all green: %d passed, %d skipped, %d expected failures"):format(
        s.pass or 0,
        s.skip or 0,
        s.xfail or 0
      ) or "all green",
      items = {},
    }
  end

  if code == 1 then
    local ir, why = read_ir(opts.json)
    if not ir then
      return {
        level = "error",
        message = ("the run failed, but its result file could not be read (%s)\n%s"):format(
          one_line(why),
          stderr
        ),
        items = {},
      }
    end
    local items = M.failure_items(ir, opts.root)
    local s = ir.summary
    local bad = (s.fail or 0) + (s.error or 0) + (s.timeout or 0) + (s.crash or 0) + (s.xpass or 0)
    return {
      level = "error",
      message = ("%d failed (%d passed, %d skipped); %d in the quickfix list"):format(
        bad,
        s.pass or 0,
        s.skip or 0,
        #items
      ),
      items = items,
    }
  end

  local kind = code == 2 and "usage or configuration error" or "infrastructure error"
  return {
    level = "error",
    message = ("no verdict: %s (exit %d)\n%s"):format(kind, code, stderr),
    items = {},
  }
end

---Apply a verdict: the notification, the quickfix list, the viewer.
---@param verdict Testing.Child.Verdict
---@param title string
function M.show(verdict, title)
  local notify = require("testing.notify").get()
  if verdict.level == "error" then
    notify.error(verdict.message)
  elseif verdict.level == "warn" then
    notify.warn(verdict.message)
  else
    notify.info(verdict.message)
  end
  if #verdict.items > 0 then
    require("lib.nvim.ui.list").qf(verdict.items, "testing: failures", { open = "auto" })
  end
  if verdict.lines and #verdict.lines > 0 then
    local prefix = require("testing.config").get().notify_prefix
    require("lib.nvim.output").create(prefix).dump(verdict.lines, title)
  end
end

---Start the child. The callback runs on the main loop with the verdict, exactly once, when the
---process has ended. When the process cannot be started, nothing is called back: the function
---returns `false` and the reason instead.
---@param sub "run"|"list"|"doctor"
---@param opts Testing.Child.Opts
---@param on_done? fun(verdict: Testing.Child.Verdict)
---@return boolean started
---@return string|nil err
function M.start(sub, opts, on_done)
  on_done = on_done or function(verdict)
    M.show(verdict, "testing " .. sub)
  end
  opts = vim.tbl_extend("force", {}, opts)
  local own_json = false
  if sub == "run" and not opts.json then
    opts.json = vim.fn.tempname() .. ".testing-ir.json"
    own_json = true
  end
  local argv, err = M.build_argv(sub, opts)
  if err then
    return false, err
  end

  local function finish(res)
    vim.schedule(function()
      local ok, verdict = pcall(M.interpret, sub, res, opts)
      if not ok then
        verdict = {
          level = "error",
          message = "cannot read the result: " .. tostring(verdict),
          items = {},
        }
      end
      if own_json then
        pcall(os.remove, opts.json)
      end
      on_done(verdict)
    end)
  end

  local system = (opts.system or vim.system) --[[@as function]]
  local ok, started =
    pcall(system, argv, { cwd = opts.root, text = true, timeout = M.TIMEOUT_MS }, finish)
  if not ok then
    return false, tostring(started)
  end
  return true
end

return M
