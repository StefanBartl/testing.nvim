---@module 'testing.ci.editor'
---@brief `:Testing ci`: the pipeline from the editor (live view, quickfix, statusline), without ever blocking it.
---@description
--- Like every run from the editor, the pipeline runs in a headless child (`testing ci --no-agent --json=<tmp>`,
--- `testing.bindings.child`): a step that hangs or a suite that changes globals cannot take the session down. What the
--- child prints is appended to a live buffer (one `== <step>` section per step); when it ends, the document
--- `testing-ci/1` it wrote is read back: the verdict is notified, the findings of the red steps become a quickfix list
--- (opened only on red), and the statusline component is refreshed.
---
--- The statusline component (`M.statusline`) reads the cached document only and starts nothing; `M.refresh` re-reads the
--- document and asks git (asynchronously) for the tree to tell whether the result is `stale`.
---
--- Names for completion (`M.list`) come from `testing ci list`, run in a child: the editor never executes `.testing.lua`.

local M = {}

---Hard limit of one pipeline run in the editor.
M.TIMEOUT_MS = 1800000

---Per project root: `{ doc?, tree?, running?, profile? }`; what the statusline reads.
---@type table<string, table>
M.state = {}

---Replaced by a spec: `vim.system`.
---@type function
M.system = vim.system

---@param root string
---@return string
local function key(root)
  return (vim.fs.normalize(root):gsub("/+$", ""))
end

---The argument list of a child that runs `testing <args...>` in `root`.
---@param root string
---@param args string[]
---@return string[]
function M.child_argv(root, args)
  local argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-l",
    require("testing.bindings.child").driver(),
  }
  vim.list_extend(argv, args)
  argv[#argv + 1] = "--root=" .. root
  return argv
end

---The argument list of a pipeline run.
---@param o { root: string, json: string, profile?: string, steps?: string[], keep_going?: boolean, reuse?: boolean }
---@return string[]
function M.run_argv(o)
  local args = { "ci", "--no-agent", "--json=" .. o.json }
  if o.profile and o.profile ~= "" then
    args[#args + 1] = "--profile=" .. o.profile
  end
  if o.steps and #o.steps > 0 then
    args[#args + 1] = "--step=" .. table.concat(o.steps, ",")
  end
  if o.keep_going then
    args[#args + 1] = "--keep-going"
  end
  if o.reuse then
    args[#args + 1] = "--reuse"
  end
  return M.child_argv(o.root, args)
end

---@param file string
---@param root string
---@return string
local function resolve(file, root)
  if file:sub(1, 1) == "/" or file:match("^%a:") then
    return file
  end
  return root .. "/" .. file
end

---Quickfix items of a document: every finding of a step, and a text-only item for a red step without one.
---@param doc table `testing-ci/1`
---@param root string
---@return table[] items
function M.items(doc, root)
  local items = {}
  for _, step in ipairs(type(doc) == "table" and doc.steps or {}) do
    if step.state ~= "green" and step.state ~= "skipped" then
      local findings = type(step.findings) == "table" and step.findings or {}
      for _, f in ipairs(findings) do
        items[#items + 1] = {
          filename = resolve(f.file, root),
          lnum = type(f.line) == "number" and f.line or 1,
          col = type(f.col) == "number" and f.col or 1,
          text = ("[%s] %s"):format(step.name, tostring(f.text)),
          type = "E",
        }
      end
      if #findings == 0 then
        local why = type(step.reason) == "string" and step.reason
          or (type(step.errors) == "table" and step.errors[#step.errors])
          or step.state
        items[#items + 1] = { text = ("[%s] %s"):format(step.name, tostring(why)), type = "E" }
      end
    end
  end
  return items
end

---What the user is told when the child has ended.
---@param doc table|nil The document it wrote (nil: none could be read).
---@param code integer The child's exit code.
---@param root string
---@param stderr? string
---@return { level: "info"|"warn"|"error", message: string, items: table[] }
function M.verdict(doc, code, root, stderr)
  if type(doc) ~= "table" or doc.schema ~= "testing-ci/1" then
    return {
      level = "error",
      message = ("testing ci: no result document (exit %d)%s"):format(
        code,
        stderr and stderr ~= "" and ("\n" .. stderr) or ""
      ),
      items = {},
    }
  end
  local steps = type(doc.steps) == "table" and doc.steps or {}
  local ran = 0
  for _, s in ipairs(steps) do
    ran = ran + ((s.state == "green" or s.state == "red") and 1 or 0)
  end
  if doc.verdict == "green" then
    return {
      level = "info",
      message = ("ci %s: all %d steps green"):format(tostring(doc.profile), #steps),
      items = {},
    }
  elseif doc.verdict == "green-partial" then
    return {
      level = "warn",
      message = ("ci %s: green, but partial (%s)"):format(
        tostring(doc.profile),
        tostring(doc.partial_why)
      ),
      items = {},
    }
  elseif doc.verdict == "red" then
    local items = M.items(doc, root)
    return {
      level = "error",
      message = ("ci %s: %s failed, %d in the quickfix list"):format(
        tostring(doc.profile),
        tostring(doc.deciding ~= vim.NIL and doc.deciding or doc.first_red),
        #items
      ),
      items = items,
    }
  end
  local problems = type(doc.problems) == "table" and table.concat(doc.problems, "; ") or ""
  return {
    level = "error",
    message = ("ci: no verdict (%s, exit %d)%s"):format(
      tostring(doc.verdict),
      code,
      problems ~= "" and (": " .. problems) or ""
    ),
    items = {},
  }
end

---The statusline text of one cached entry; "" when there is nothing to say.
---@param entry table|nil `{ doc?, tree?, running?, profile? }`
---@return string
function M.status_text(entry)
  if not entry then
    return ""
  end
  if entry.running then
    return "ci: … " .. tostring(entry.profile or "")
  end
  local doc = entry.doc
  if type(doc) ~= "table" or doc.schema ~= "testing-ci/1" then
    return ""
  end
  local text
  if doc.verdict == "green" then
    local sha = type(doc.commit) == "string" and (" @" .. doc.commit:sub(1, 7)) or ""
    text = ("ci: ✓ %s%s"):format(tostring(doc.profile), sha)
  elseif doc.verdict == "green-partial" then
    text = ("ci: ~ %s"):format(tostring(doc.profile))
  elseif doc.verdict == "red" then
    local step = doc.deciding ~= vim.NIL and doc.deciding or doc.first_red
    text = ("ci: ✗ %s"):format(tostring(step ~= vim.NIL and step or doc.profile))
  else
    text = ("ci: ! %s"):format(tostring(doc.verdict))
  end
  if entry.tree and type(doc.tree) == "string" and doc.tree ~= entry.tree then
    text = text .. " stale"
  end
  return text
end

---Path of the last document of a project (the state directory the child uses by default).
---@param root string
---@return string
function M.doc_path(root)
  return require("testing.state").dir(root, {}) .. "/ci.json"
end

---@param path string
---@return table|nil
local function read_json(path)
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil
  end
  local ok, doc = pcall(vim.json.decode, text)
  return ok and type(doc) == "table" and doc or nil
end

---Re-read the last document of `root` and ask git for its tree (asynchronously), then call `on_done`.
---@param root string
---@param on_done? fun(entry: table)
function M.refresh(root, on_done)
  local k = key(root)
  local entry = M.state[k] or {}
  M.state[k] = entry
  entry.doc = read_json(M.doc_path(root))
  local function done()
    if on_done then
      on_done(entry)
    end
  end
  local ok, obj = pcall(
    M.system,
    { "git", "-C", root, "rev-parse", "HEAD^{tree}" },
    { text = true },
    function(res)
      vim.schedule(function()
        entry.tree = res.code == 0 and vim.trim(res.stdout or "") or nil
        done()
      end)
    end
  )
  if not ok or not obj then
    done()
  end
end

---The statusline component: the cached result of the project of the current buffer (or `root`); starts nothing
---except one asynchronous refresh the first time a project is asked about.
---@param root? string
---@return string
function M.statusline(root)
  root = root or require("testing.bindings.usrcmds").resolve_root(nil, vim.api.nvim_buf_get_name(0))
  local entry = M.state[key(root)]
  if not entry then
    M.state[key(root)] = {}
    M.refresh(root)
    return ""
  end
  return M.status_text(entry)
end

---The live buffer of a project: one per root, cleared at the start of a run, shown in a split when it is not visible.
---@param root string
---@return { buf: integer, append: fun(lines: string[]) }
function M.open_view(root)
  local name = "testing-ci://" .. vim.fs.basename(root)
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "testing-ci"
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.bo[buf].modifiable = false
  local shown = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    shown = shown or vim.api.nvim_win_get_buf(win) == buf
  end
  if not shown and #vim.api.nvim_list_uis() > 0 then
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright 12split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_set_current_win(prev)
  end
  return {
    buf = buf,
    append = function(lines)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.bo[buf].modifiable = true
      local first = vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
      vim.api.nvim_buf_set_lines(buf, first and 0 or -1, -1, false, lines)
      vim.bo[buf].modifiable = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
        end
      end
    end,
  }
end

---Start a pipeline run. Returns false with a reason when one is already running or the child cannot start.
---@param o { root: string, profile?: string, steps?: string[], keep_going?: boolean, reuse?: boolean, on_done?: fun(verdict: table) }
---@return boolean started
---@return string|nil err
function M.run(o)
  local k = key(o.root)
  local entry = M.state[k] or {}
  M.state[k] = entry
  if entry.running then
    return false, "a pipeline is already running for " .. o.root
  end
  local json = vim.fn.tempname() .. ".testing-ci.json"
  local argv = M.run_argv({
    root = o.root,
    json = json,
    profile = o.profile,
    steps = o.steps,
    keep_going = o.keep_going,
    reuse = o.reuse,
  })
  local view = M.open_view(o.root)
  local partial = ""
  ---@param data string|nil
  local function feed(data)
    if not data or data == "" then
      return
    end
    vim.schedule(function()
      local text = partial .. data:gsub("\r", "")
      local lines = vim.split(text, "\n", { plain = true })
      partial = table.remove(lines)
      if #lines > 0 then
        view.append(lines)
      end
    end)
  end
  local function finish(res)
    vim.schedule(function()
      if partial ~= "" then
        view.append({ partial })
        partial = ""
      end
      entry.running = false
      local doc = read_json(json)
      pcall(os.remove, json)
      local verdict = M.verdict(doc, res.code or -1, o.root, res.stderr)
      local notify = require("testing.notify").get()
      notify[verdict.level](verdict.message)
      if #verdict.items > 0 then
        require("lib.nvim.ui.list").qf(verdict.items, "testing ci: findings", { open = "auto" })
      end
      M.refresh(o.root)
      if o.on_done then
        o.on_done(verdict)
      end
    end)
  end
  entry.running, entry.profile = true, o.profile or "default"
  local ok, started = pcall(M.system, argv, {
    cwd = o.root,
    text = true,
    timeout = M.TIMEOUT_MS,
    stdout = function(_, data)
      feed(data)
    end,
    stderr = function(_, data)
      feed(data)
    end,
  }, finish)
  if not ok or not started then
    entry.running = false
    return false, tostring(started)
  end
  return true
end

---Run `testing ci <args...>` in a child and hand its output to `cb` (scheduled).
---@param root string
---@param args string[]
---@param cb fun(res: { code: integer, stdout: string, stderr: string })
---@return boolean started
---@return string|nil err
function M.capture(root, args, cb)
  local ok, started = pcall(M.system, M.child_argv(root, vim.list_extend({ "ci" }, args)), {
    cwd = root,
    text = true,
    timeout = 120000,
  }, function(res)
    vim.schedule(function()
      cb({ code = res.code or -1, stdout = res.stdout or "", stderr = res.stderr or "" })
    end)
  end)
  if not ok or not started then
    return false, tostring(started)
  end
  return true
end

---@type table<string, { stamp: integer|nil, list: table|nil }>
local list_cache = {}

---Profiles and steps of the project (`testing ci list`, cached until `.testing.lua` changes); nil when unknown.
---@param root string
---@return { default: string, profiles: table<string, string[]>, steps: string[] }|nil
function M.list(root)
  local cfg = vim.uv.fs_stat(root .. "/.testing.lua")
  if not cfg then
    return nil
  end
  local stamp = cfg.mtime.sec * 1000000000 + cfg.mtime.nsec
  local cached = list_cache[key(root)]
  if cached and cached.stamp == stamp then
    return cached.list
  end
  local ok, obj = pcall(
    M.system,
    M.child_argv(root, { "ci", "list", "--json" }),
    { cwd = root, text = true, timeout = 8000 }
  )
  local res = ok and obj and obj:wait(10000) or nil
  local list
  if res and res.code == 0 then
    local okd, doc = pcall(vim.json.decode, res.stdout or "")
    list = okd and type(doc) == "table" and type(doc.profiles) == "table" and doc or nil
  end
  list_cache[key(root)] = { stamp = stamp, list = list }
  return list
end

return M
