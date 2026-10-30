---@module 'testing.lint.editor'
---@brief `:Testing lint` and the check on save: the lint checks in a child, findings as quickfix and diagnostics.
---@description
--- Like `:Testing ci`, the checks run in a headless child (`testing lint --json`, started with the argv of
--- `testing.ci.editor.child_argv`): the editor never executes `.testing.lua` and never waits for a linter. When the child
--- ends, its document `testing-lint/1` is read back:
---
---   * the findings become the quickfix list "testing lint" (opened only when there are findings);
---   * every loaded buffer gets the findings of its file as `vim.diagnostic`, one namespace per check
---     (`testing.lint.<check>`); a checked file without findings has that check's diagnostics cleared;
---   * the verdict is notified (`testing.notify`).
---
--- On save (`lint = { on_save = true }` in setup): BufWritePost on a file a check reads starts `testing lint
--- --on-save --file=<that file>` after a short quiet time, one run per buffer at a time (a newer save stops the older
--- run and its result is dropped). Only the diagnostics are updated: no quickfix list, and a message only when a
--- check could not run (exit 3: a missing tool). "Nothing to lint here" is silent: no child starts for a file outside
--- a project (no `.testing.lua` and no `lua/` folder at the root found for it, or a file that is not below that root),
--- and an exit 2 (no pipeline, an untrusted root, a broken `.testing.lua`) says nothing on save. The default set on
--- save leaves out the expensive checks (`on_save = false` in a preset: luals).
---
--- Every run gets a sequence number when it starts; the diagnostics of a check for a file are only replaced by a run
--- that started after the run that set them (a slow `:Testing lint` never overwrites a newer save's result). A check
--- whose findings were cut at the cap clears nothing (a file without a listed finding may have been cut off).
--- `--fix` is refused while a buffer of a file in its scope has unsaved changes (save first).

local M = {}

---Hard limit of one lint run in the editor.
M.TIMEOUT_MS = 600000

---Quiet time after a save before the check starts (several writes in a row start one check).
M.DEBOUNCE_MS = 300

M.TITLE = "testing lint"

M.AUGROUP = "testing.lint"

---Replaced by a spec: `vim.system`.
---@type function
M.system = vim.system

---@param check string
---@return string
function M.namespace_name(check)
  return "testing.lint." .. check
end

---The key two spellings of one file share: its real path, case-insensitive on Windows.
---@param path string
---@return string
local function key(path)
  local p = require("testing.lint").real_path(path)
  return require("testing.platform").is_windows() and p:lower() or p
end

---@param file string
---@param root string
---@return string
local function resolve(file, root)
  if file:sub(1, 1) == "/" or file:sub(1, 2) == "\\\\" or file:match("^%a:") then
    return vim.fs.normalize(file)
  end
  return vim.fs.normalize(root .. "/" .. file)
end

---@param v any
---@return any
local function val(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---@param message string
---@return integer severity
local function severity(message)
  -- luacheck `(E011)`, LuaLS `[Error]`: an error; everything else (warnings, an unformatted file) a warning
  if message:match("^%(E%d+%)") or message:match("^%[Error%]") then
    return vim.diagnostic.severity.ERROR
  end
  return vim.diagnostic.severity.WARN
end

---@param doc any
---@return boolean
local function valid(doc)
  return type(doc) == "table" and doc.schema == "testing-lint/1" and type(doc.checks) == "table"
end

---The argument list of a child that runs `testing lint`.
---@param o { root: string, checks?: string[], scope?: "changed"|"file"|"all", files?: string[], fix?: boolean, on_save?: boolean }
---@return string[]
function M.argv(o)
  local args = { "lint", "--json" }
  vim.list_extend(args, o.checks or {})
  if o.scope == "all" then
    args[#args + 1] = "--all"
  elseif o.scope == "file" then
    -- one --file per file: a file name may hold a comma
    for _, f in ipairs(o.files or {}) do
      args[#args + 1] = "--file=" .. f
    end
  elseif o.scope == "changed" then
    args[#args + 1] = "--changed"
  end
  if o.fix then
    args[#args + 1] = "--fix"
  end
  if o.on_save then
    args[#args + 1] = "--on-save"
  end
  return require("testing.ci.editor").child_argv(o.root, args)
end

---Quickfix items of a document: one per finding.
---@param doc table testing-lint/1
---@return table[] items
function M.items(doc)
  local items = {}
  if not valid(doc) then
    return items
  end
  local root = tostring(doc.root)
  for _, c in ipairs(doc.checks) do
    for _, f in ipairs(type(c.findings) == "table" and c.findings or {}) do
      local message = tostring(val(f.message) or "")
      items[#items + 1] = {
        filename = resolve(tostring(f.file), root),
        lnum = val(f.line) or 1,
        col = val(f.col) or 1,
        text = ("[%s] %s"):format(c.name, message),
        type = severity(message) == vim.diagnostic.severity.ERROR and "E" or "W",
      }
    end
  end
  return items
end

---@class Testing.Lint.Editor.CheckDiagnostics
---@field check string
---@field namespace string
---@field by_file table<string, vim.Diagnostic.Set[]> Keyed by `key(absolute path)`.
---@field checked table<string, true>|nil Files checked (`key(absolute path)`); nil: every file below the root with one of `ext`.
---@field ext string[]
---@field truncated boolean Findings were cut at the cap: nothing is cleared.

---The diagnostics of a document per check, without touching the editor. A check that did not run (skipped, a tool
---missing, an error) or that is red without a single finding says nothing about any file and is left out.
---@param doc table testing-lint/1
---@return Testing.Lint.Editor.CheckDiagnostics[]
function M.diagnostics(doc)
  local out = {}
  if not valid(doc) then
    return out
  end
  local root = tostring(doc.root)
  for _, c in ipairs(doc.checks) do
    local findings = type(c.findings) == "table" and c.findings or {}
    if c.state == "green" or (c.state == "red" and #findings > 0) then
      local by_file = {}
      for _, f in ipairs(findings) do
        local k = key(resolve(tostring(f.file), root))
        local message = tostring(val(f.message) or "")
        by_file[k] = by_file[k] or {}
        table.insert(by_file[k], {
          lnum = math.max((val(f.line) or 1) - 1, 0),
          col = math.max((val(f.col) or 1) - 1, 0),
          message = message,
          severity = severity(message),
          source = c.name,
        })
      end
      local checked
      if type(c.files) == "table" then
        checked = {}
        for _, f in ipairs(c.files) do
          checked[key(resolve(f, root))] = true
        end
      end
      out[#out + 1] = {
        check = c.name,
        namespace = M.namespace_name(c.name),
        by_file = by_file,
        checked = checked,
        ext = type(c.ext) == "table" and c.ext or {},
        truncated = (tonumber(c.findings_total) or 0) > #findings,
      }
    end
  end
  return out
end

---The sequence number of the last run that started (every run, manual and on save).
M.seq = 0

---Per check namespace and file: the sequence number of the run whose diagnostics are shown.
---@type table<string, integer>
M.applied = {}

---Set the diagnostics of a document in the loaded buffers. `seq`: the run's sequence number; a file whose
---diagnostics of a check came from a later run is left alone.
---@param doc table testing-lint/1
---@param seq? integer nil: applied whatever ran before, nothing recorded.
---@return integer set Buffers that got diagnostics.
function M.apply(doc, seq)
  local per_check = M.diagnostics(doc)
  if #per_check == 0 then
    return 0
  end
  local root = key(tostring(doc.root)) .. "/"
  local set = 0
  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if name ~= "" then
      buffers[#buffers + 1] = { buf = buf, key = key(name) }
    end
  end
  for _, d in ipairs(per_check) do
    local ns = vim.api.nvim_create_namespace(d.namespace)
    local wanted = {}
    for _, e in ipairs(d.ext) do
      wanted[e:lower()] = true
    end
    for _, b in ipairs(buffers) do
      local diags = d.by_file[b.key]
      local slot = d.namespace .. "\0" .. b.key
      -- a run that started later already set this check's diagnostics of this file: they stay
      local newer = seq ~= nil and (M.applied[slot] or -1) > seq
      if diags and not newer then
        M.applied[slot] = seq or M.applied[slot]
        vim.diagnostic.set(ns, b.buf, diags)
        set = set + 1
      elseif not diags and not newer and not d.truncated then
        local checked
        if d.checked then
          checked = d.checked[b.key] == true
        else
          local e = b.key:match("%.([^./]+)$")
          checked = b.key:sub(1, #root) == root and e ~= nil and wanted[e] == true
        end
        if checked then
          M.applied[slot] = seq or M.applied[slot]
          vim.diagnostic.reset(ns, b.buf)
        end
      end
    end
  end
  return set
end

---What the user is told when the child has ended.
---@param doc table|nil The document (nil: none could be read).
---@param code integer The child's exit code.
---@param stderr? string
---@return { level: "info"|"warn"|"error", message: string, items: table[] }
function M.verdict(doc, code, stderr)
  if not valid(doc) then
    return {
      level = "error",
      message = ("testing lint: no result (exit %d)%s"):format(
        code,
        stderr and stderr ~= "" and ("\n" .. vim.trim(stderr)) or ""
      ),
      items = {},
    }
  end
  ---@cast doc table
  local lines = { require("testing.lint").verdict_line(doc) }
  for _, c in ipairs(doc.checks) do
    if c.missing or c.state == "error" or c.state == "infra" then
      lines[#lines + 1] = ("%s: %s"):format(c.name, tostring(val(c.reason) or c.state))
    end
    if type(c.fixed) == "table" and #c.fixed > 0 then
      lines[#lines + 1] = ("%s fixed: %s"):format(c.name, table.concat(c.fixed, ", "))
    end
    if c.no_fix then
      lines[#lines + 1] = c.name .. ": no --fix"
    end
  end
  for _, p in ipairs(type(doc.problems) == "table" and doc.problems or {}) do
    lines[#lines + 1] = tostring(p)
  end
  local level = doc.exit == 0 and "info" or doc.exit == 1 and "warn" or "error"
  return { level = level, message = table.concat(lines, "\n"), items = M.items(doc) }
end

---The names of the modified buffers of files in a scope (`files` nil: every file below the root).
---@param root string
---@param files? string[] Absolute or relative to the root.
---@return string[]
function M.unsaved(root, files)
  local wanted
  if files then
    wanted = {}
    for _, f in ipairs(files) do
      wanted[key(resolve(f, root))] = true
    end
  end
  local base = key(root) .. "/"
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if name ~= "" and vim.bo[buf].modified then
      local k = key(name)
      if (wanted and wanted[k]) or (not wanted and k:sub(1, #base) == base) then
        out[#out + 1] = vim.fs.normalize(name)
      end
    end
  end
  return out
end

---@param stdout string
---@return table|nil
local function decode(stdout)
  local ok, doc = pcall(vim.json.decode, vim.trim(stdout or ""))
  return ok and valid(doc) and doc or nil
end

---@class Testing.Lint.RunOpts
---@field root string
---@field checks? string[]
---@field scope? "changed"|"file"|"all"
---@field files? string[]
---@field fix? boolean
---@field on_save? boolean
---@field quiet? boolean
---@field current? fun(): boolean
---@field on_done? fun(doc: table|nil, verdict: table)
---@field trust_asked? boolean

---Start a lint run in a child. `quiet`: diagnostics only (the check on save), a message only when a check could not
---run; `current`: asked when the child ends, false drops the result (a newer save took over).
---@param o Testing.Lint.RunOpts
---@return table|nil proc The `vim.SystemObj` (to stop it), nil when it could not start.
---@return string|nil err
function M.run(o)
  if o.fix then
    -- the fix rewrites the file on disk: a buffer with changes of its own would then conflict with it (W12)
    local unsaved = M.unsaved(o.root, o.scope == "file" and o.files or nil)
    if #unsaved > 0 then
      return nil, ("--fix: save first (unsaved changes in %s)"):format(table.concat(unsaved, ", "))
    end
  end
  M.seq = M.seq + 1
  local seq = M.seq
  local function finish(res)
    vim.schedule(function()
      if o.current and not o.current() then
        return
      end
      local code = res.code or -1
      local doc = decode(res.stdout)
      local function report()
        if doc and o.fix then
          -- the files the fix rewrote: buffers without changes of their own are reloaded
          -- the closure form: `vim.cmd` is a callable table, no function (LLS-32)
          pcall(function()
            vim.cmd("silent! checktime")
          end)
        end
        if doc then
          M.apply(doc, seq)
        end
        local verdict = M.verdict(doc, code, res.stderr)
        local notify = require("testing.notify").get()
        if not o.quiet then
          notify[verdict.level](verdict.message)
          if #verdict.items > 0 then
            require("lib.nvim.ui.list").qf(verdict.items, M.TITLE, { open = "auto" })
          end
        elseif code == 3 or (doc and doc.exit == 3) then
          -- on save only what the user must act on: a check that could not run. An exit 2 is "nothing to lint
          -- here" (no pipeline, an untrusted root, a file outside the root) and stays silent
          notify.error(verdict.message)
        end
        if o.on_done then
          o.on_done(doc, verdict)
        end
      end
      -- an untrusted root: ask once (never from a save), and on yes run again
      local prompt = require("testing.bindings.trust_prompt")
      if not o.quiet and not o.trust_asked and prompt.refused(code, res.stderr or "") then
        prompt.ask(o.root, function(trusted)
          if trusted and M.run(vim.tbl_extend("force", {}, o, { trust_asked = true })) then
            return
          end
          report()
        end)
        return
      end
      report()
    end)
  end
  local ok, proc = pcall(M.system, M.argv(o), {
    cwd = o.root,
    text = true,
    timeout = M.TIMEOUT_MS,
  }, finish)
  if not ok or not proc then
    return nil, tostring(proc)
  end
  return proc
end

---Per buffer: the pending timer, the running child and the generation of the last save.
---@type table<integer, { timer?: uv.uv_timer_t, proc?: table, gen: integer }>
M.pending = {}

---@param buf integer
local function forget(buf)
  local st = M.pending[buf]
  if not st then
    return
  end
  M.pending[buf] = nil
  if st.timer and not st.timer:is_closing() then
    st.timer:stop()
    st.timer:close()
  end
  if st.proc then
    pcall(st.proc.kill, st.proc, 15)
  end
end

---A buffer was written: check its file after the quiet time, superseding a check of an earlier save.
---@param buf integer
function M.on_save(buf)
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    return
  end
  local st = M.pending[buf] or { gen = 0 }
  M.pending[buf] = st
  st.gen = st.gen + 1
  local gen = st.gen
  if not st.timer or st.timer:is_closing() then
    st.timer = vim.uv.new_timer()
  end
  st.timer:stop()
  st.timer:start(
    M.DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      if M.pending[buf] ~= st or st.gen ~= gen or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if st.proc then
        pcall(st.proc.kill, st.proc, 15)
        st.proc = nil
      end
      local root = require("testing.bindings.usrcmds").resolve_root(nil, file)
      if not M.lintable(root, file) then
        return
      end
      st.proc = M.run({
        root = root,
        scope = "file",
        files = { vim.fs.normalize(file) },
        on_save = true,
        quiet = true,
        current = function()
          return M.pending[buf] == st and st.gen == gen
        end,
        on_done = function()
          if M.pending[buf] == st and st.gen == gen then
            st.proc = nil
          end
        end,
      })
    end)
  )
end

---Whether a save of `file` is worth a child: the root is a project (a `.testing.lua`, or a `lua/` folder a pipeline
---can be derived from) and the file lies below it. Reads the file system only.
---@param root string
---@param file string
---@return boolean
function M.lintable(root, file)
  if not vim.uv.fs_stat(root .. "/.testing.lua") and vim.fn.isdirectory(root .. "/lua") ~= 1 then
    return false
  end
  return require("testing.lint").relative(root, vim.fs.normalize(file)) ~= nil
end

---The file patterns the check on save reacts to: every extension of a lint preset that may run on save.
---@return string[]
function M.save_patterns()
  local presets = require("testing.ci.presets")
  local out, seen = {}, {}
  for _, name in ipairs(presets.lint_names()) do
    local lint = presets.get(name).lint --[[@as Testing.Ci.PresetLint]]
    if lint.on_save ~= false then
      for _, e in ipairs(lint.ext) do
        if not seen[e] then
          seen[e] = true
          out[#out + 1] = "*." .. e
        end
      end
    end
  end
  return out
end

---Install (or remove) the check on save, from the `lint` options of setup(). Safe to call again.
---@param cfg Testing.LintConfig
function M.setup(cfg)
  for buf in pairs(M.pending) do
    forget(buf)
  end
  if not (type(cfg) == "table" and cfg.on_save) then
    pcall(vim.api.nvim_del_augroup_by_name, M.AUGROUP)
    return
  end
  local group = vim.api.nvim_create_augroup(M.AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = M.save_patterns(),
    desc = "testing.nvim: lint the written file (lint.on_save)",
    callback = function(ev)
      M.on_save(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    desc = "testing.nvim: forget the pending lint of a wiped buffer",
    callback = function(ev)
      forget(ev.buf)
    end,
  })
end

return M
