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

---Replaced by a spec: the progress indicator of a run (`lib.nvim.progress`).
---@param opts table
---@return { update: fun(self, fields: table), finish: fun(self, text?: string), cancel: fun(self, text?: string) }
function M.progress(opts)
  return require("lib.nvim.progress").create(opts)
end

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
  -- `--root` goes before a `--`: what follows it belongs to the suite
  local split = #args + 1
  for i, a in ipairs(args) do
    if a == "--" then
      split = i
      break
    end
  end
  for i = 1, split - 1 do
    argv[#argv + 1] = args[i]
  end
  argv[#argv + 1] = "--root=" .. root
  for i = split, #args do
    argv[#argv + 1] = args[i]
  end
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
  if o.events and o.events ~= "" then
    -- the suite step writes its events (file n of m) there, whatever its specs print
    vim.list_extend(args, { "--", "--events", o.events })
  end
  return M.child_argv(o.root, args)
end

---Which lines of the output of a run belong in the live buffer. What a suite prints between its header `== <name>`
---and the next header is the output of the specs themselves (a spec may print anything, one line without end of
---line, a whole table): it is kept aside, and the run shows the suite through its events instead.
---@param name string The step whose output is quiet (`suite`).
---@return fun(line: string): boolean keep
---@return fun(): string[] raw The lines kept aside (the last `M.RAW_LINES`).
function M.quiet_step(name)
  local inside, raw = false, {}
  local function keep(line)
    local step = M.step_of(line)
    if step then
      inside = step == name
      return true
    end
    if inside and line:match("^%-%- " .. vim.pesc(name) .. ":") then
      inside = false
      return true
    end
    if inside then
      raw[#raw + 1] = line
      if #raw > M.RAW_LINES then
        table.remove(raw, 1)
      end
      return false
    end
    return true
  end
  return keep, function()
    return raw
  end
end

---How many lines of a quiet step are kept to show when the run is not green.
M.RAW_LINES = 40

---The longest line the live buffer shows (a progress meter that never prints a newline is one endless line).
M.MAX_LINE = 400

---Read an NDJSON events file while a child writes it (`testing run --events <file>`): every 200 ms the bytes written
---since the last read go through `testing.run.events_reader`. The returned function stops the timer and reads the
---rest.
---@param path string
---@param on_event fun(ev: table)
---@return fun() stop
function M.tail_events(path, on_event)
  local reader = require("testing.run.events_reader").new({ on_event = on_event })
  local offset = 0
  local function poll()
    local f = io.open(path, "rb")
    if not f then
      return
    end
    f:seek("set", offset)
    local data = f:read("*a")
    f:close()
    if data and data ~= "" then
      offset = offset + #data
      reader:feed(data)
    end
  end
  local timer = vim.uv.new_timer()
  timer:start(200, 200, vim.schedule_wrap(poll))
  return function()
    timer:stop()
    timer:close()
    poll()
  end
end

---@param file string
---@param root string
---@return string
local function resolve(file, root)
  if file:sub(1, 1) == "/" or file:sub(1, 2) == "\\\\" or file:match("^%a:") then
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
        local named = type(f.file) == "string" and f.file ~= "" and f.file ~= "?"
        items[#items + 1] = {
          filename = named and resolve(f.file, root) or nil,
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
  entry.at = os.time()
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

---Seconds after which the statusline component asks for a fresh document and tree again.
M.REFRESH_AFTER = 5

---The statusline component: the cached result of the project of the current buffer (or `root`); starts nothing
---except an asynchronous refresh (the first time a project is asked about, and every `REFRESH_AFTER` seconds), so
---a run in a terminal, a commit or the pre-push hook show up. `stale` compares the tree of HEAD.
---@param root? string
---@return string
function M.statusline(root)
  root = root or require("testing.bindings.usrcmds").resolve_root(nil, vim.api.nvim_buf_get_name(0))
  local entry = M.state[key(root)]
  if not entry then
    M.state[key(root)] = { at = os.time() }
    M.refresh(root)
    return ""
  end
  if not entry.running and os.time() - (entry.at or 0) >= M.REFRESH_AFTER then
    entry.at = os.time()
    M.refresh(root)
  end
  return M.status_text(entry)
end

---Name of the live buffer of a project: the directory name and a short hash of the root (two checkouts called `app`
---must not share one).
---@param root string
---@return string
function M.view_name(root)
  return ("testing-ci://%s-%s"):format(vim.fs.basename(root), vim.fn.sha256(key(root)):sub(1, 6))
end

---Show a view buffer: when a window already shows it, go there; otherwise open a split below and enter it (the output
---of a run is what the user asked for, so the cursor goes with it). Nothing in a headless editor.
---@param buf integer
function M.show_buffer(buf)
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  vim.cmd("botright 12split")
  vim.api.nvim_win_set_buf(0, buf)
end

---Show the live buffer of a project that is already there (a run in progress or the last one), without clearing it.
---@param root string
---@return boolean shown false when the project has no buffer yet
function M.show_view(root)
  local buf = vim.fn.bufnr(M.view_name(root))
  if buf == -1 then
    return false
  end
  M.show_buffer(buf)
  return true
end

---The live buffer of a project: one per root, cleared at the start of a run, shown in a split when it is not visible.
---`header(lines)` replaces a block at the top of the buffer (the table of a multi-repository run), `append` adds below.
---@param root string
---@return { buf: integer, append: fun(lines: string[]), header: fun(lines: string[]) }
function M.open_view(root)
  local name = M.view_name(root)
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
  M.show_buffer(buf)
  local header_n = 0
  ---@return boolean
  local function pristine()
    return vim.api.nvim_buf_line_count(buf) == 1
      and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  end
  return {
    buf = buf,
    header = function(lines)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, pristine() and -1 or header_n, false, lines)
      header_n = #lines
      vim.bo[buf].modifiable = false
    end,
    append = function(lines)
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, pristine() and 0 or -1, -1, false, lines)
      vim.bo[buf].modifiable = false
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
          pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
        end
      end
    end,
  }
end

---Feed the live buffer from the two pipes of a child: one unfinished line per stream (a chunk of stdout that ends
---mid-line is not glued to a chunk of stderr), a line shown as a terminal shows it (the text after the last carriage
---return). `feed(stream)` is the pipe callback, `flush()` writes what is left when the process has ended; `on_line`
---sees every line as it is shown.
---`keep(line)` (optional) decides which lines the buffer shows; `on_line` still sees all of them.
---@param view { append: fun(lines: string[]) }
---@param on_line? fun(line: string)
---@param keep? fun(line: string): boolean
---@return fun(stream: "out"|"err"): fun(_: any, data: string|nil) feed
---@return fun() flush
function M.feeder(view, on_line, keep)
  local partial = { out = "", err = "" }
  ---@param line string
  ---@return string
  local function shown(line)
    local text = line:gsub("\r+$", ""):match("[^\r]*$")
    if #text > M.MAX_LINE then
      text = text:sub(1, M.MAX_LINE) .. " ... (" .. (#text - M.MAX_LINE) .. " more characters)"
    end
    return text
  end
  ---@param lines string[]
  local function show(lines)
    local out = {}
    for _, line in ipairs(lines) do
      if not keep or keep(line) then
        out[#out + 1] = line
      end
    end
    if #out > 0 then
      view.append(out)
    end
    for _, line in ipairs(on_line and lines or {}) do
      on_line(line)
    end
  end
  local function feed(stream)
    return function(_, data)
      if not data or data == "" then
        return
      end
      vim.schedule(function()
        local lines = vim.split(partial[stream] .. data, "\n", { plain = true })
        partial[stream] = table.remove(lines)
        for i, line in ipairs(lines) do
          lines[i] = shown(line)
        end
        if #lines > 0 then
          show(lines)
        end
      end)
    end
  end
  local function flush()
    for _, stream in ipairs({ "out", "err" }) do
      if partial[stream] ~= "" then
        local line = shown(partial[stream])
        partial[stream] = ""
        show({ line })
      end
    end
  end
  return feed, flush
end

---The arguments of `testing ci --repos ...` for the settings of the editor and the flags of the command.
---@param ci_cfg Testing.CiConfig
---@param flags { force?: boolean, jobs?: string, profile?: string, refresh?: boolean, ["keep-going"]?: boolean, reuse?: boolean, ["repos-root"]?: string }
---@return string[]
function M.repos_args(ci_cfg, flags)
  local args = {}
  local roots = flags["repos-root"] and { flags["repos-root"] } or ci_cfg.repos.roots
  for _, root in ipairs(roots) do
    args[#args + 1] = "--repos-root=" .. vim.fs.normalize(root)
  end
  if #ci_cfg.repos.include > 0 then
    args[#args + 1] = "--repos-include=" .. table.concat(ci_cfg.repos.include, ",")
  end
  if #ci_cfg.repos.exclude > 0 then
    args[#args + 1] = "--repos-exclude=" .. table.concat(ci_cfg.repos.exclude, ",")
  end
  for _, name in ipairs({ "force", "refresh", "keep-going", "reuse" }) do
    if flags[name] then
      args[#args + 1] = "--" .. name
    end
  end
  if flags.jobs then
    args[#args + 1] = "--jobs=" .. flags.jobs
  end
  if flags.profile then
    args[#args + 1] = "--profile=" .. flags.profile
  end
  return args
end

---A state line of the multi-repository run (`ci repos: [<finished>/<total>] #<index> <event> <name>`), or nil.
---@param line string
---@return { finished: integer, total: integer, index: integer, event: string, name: string }|nil
function M.repos_event(line)
  local finished, total, index, event, name =
    line:match("^ci repos: %[(%d+)/(%d+)%] #(%d+) (%a+) (.+)$")
  if not finished then
    return nil
  end
  return {
    finished = tonumber(finished),
    total = tonumber(total),
    index = tonumber(index),
    event = event,
    name = name,
  }
end

---The table at the top of the multi-repository view: one row per repository seen so far (in order of appearance),
---then the ones not started yet. `rows` are `{ name, state, verify?, ms? }`.
---@param rows { name: string, state: string, verify?: string, ms?: integer }[]
---@param finished integer
---@param total integer
---@return string[]
function M.repos_table(rows, finished, total)
  local width = #"repo"
  for _, r in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(r.name))
  end
  local lines = {
    ("ci repos  %d/%d done"):format(finished, total),
    ("%-" .. width .. "s  %-8s %-11s %s"):format("repo", "state", "verify", "time"),
  }
  for _, r in ipairs(rows) do
    lines[#lines + 1] = ("%-" .. width .. "s  %-8s %-11s %s"):format(
      r.name,
      r.state,
      type(r.verify) == "string" and r.verify or "-",
      type(r.ms) == "number" and ("%.1f s"):format(r.ms / 1000) or "-"
    )
  end
  if total > #rows then
    lines[#lines + 1] = ("(%d not started yet)"):format(total - #rows)
  end
  lines[#lines + 1] = ""
  return lines
end

---Quickfix items of a `testing-ci-repos/1` document: the findings of every repository that is not green, each text
---with the repository's name in front; a repository without a document gets a text-only item.
---@param doc table
---@return table[]
function M.repos_items(doc)
  local items = {}
  for _, r in ipairs(type(doc) == "table" and type(doc.repos) == "table" and doc.repos or {}) do
    if r.state ~= "green" and r.state ~= "skipped" then
      local own = type(r.doc) == "table" and M.items(r.doc, r.dir) or {}
      for _, item in ipairs(own) do
        item.text = ("%s %s"):format(r.name, item.text)
        items[#items + 1] = item
      end
      if #own == 0 then
        items[#items + 1] = {
          text = ("%s: %s (exit %s)"):format(r.name, tostring(r.state), tostring(r.code)),
          type = "E",
        }
      end
    end
  end
  return items
end

---What the user is told when the multi-repository child has ended.
---@param doc table|nil `testing-ci-repos/1` (nil: none could be read)
---@param code integer
---@return { level: "info"|"error", message: string, items: table[] }
function M.repos_verdict(doc, code)
  if type(doc) ~= "table" or doc.schema ~= "testing-ci-repos/1" or type(doc.repos) ~= "table" then
    if code == 0 then
      return { level = "info", message = "ci repos: all green or proven", items = {} }
    end
    return {
      level = "error",
      message = ("ci repos: exit %d (see %s)"):format(code, M.view_name("/repos")),
      items = {},
    }
  end
  local proven, bad = 0, {}
  for _, r in ipairs(doc.repos) do
    if r.state == "skipped" then
      proven = proven + 1
    elseif r.state ~= "green" then
      bad[#bad + 1] = ("%s (%s)"):format(tostring(r.name), tostring(r.state))
    end
  end
  if code == 0 and #bad == 0 then
    return {
      level = "info",
      message = ("ci repos: all %d green or proven (%d proven, not run)"):format(
        #doc.repos,
        proven
      ),
      items = {},
    }
  end
  local items = M.repos_items(doc)
  return {
    level = "error",
    message = ("ci repos: %s, %d in the quickfix list (exit %d)"):format(
      #bad > 0 and table.concat(bad, ", ") or tostring(doc.verdict),
      #items,
      code
    ),
    items = items,
  }
end

---Run the pipelines of several repositories (`testing ci --repos ...`) in a child; the output streams into the view
---`testing-ci://repos`, with a table of the repositories at its top that follows the run, and a progress indicator.
---At the end the document the child wrote (`--json`) gives the verdict and the quickfix list (opened only on red).
---Returns false with a reason when one is already running or the child cannot start.
---@param o { args: string[], cwd: string, on_done?: fun(code: integer) }
---@return boolean started
---@return string|nil err
function M.run_repos(o)
  local entry = M.state["*repos*"] or {}
  M.state["*repos*"] = entry
  if entry.running then
    M.show_view("/repos")
    return false, "a multi-repository run is already going (showing its output)"
  end
  local view = M.open_view("/repos")
  -- rows by the child's index: two repositories with the same directory name stay two rows
  local rows, by_index = {}, {}
  local progress = M.progress({ title = "testing ci repos" })
  local function on_line(line)
    local ev = M.repos_event(line)
    if not ev then
      return
    end
    local row = by_index[ev.index]
    if not row then
      row = { name = ev.name }
      by_index[ev.index] = row
      rows[#rows + 1] = row
    end
    row.state = ev.event
    view.header(M.repos_table(rows, ev.finished, ev.total))
    progress:update({ text = ev.event .. " " .. ev.name, current = ev.finished, total = ev.total })
  end
  local feed, flush = M.feeder(view, on_line)
  local json = vim.fn.tempname() .. ".testing-ci-repos.json"
  local argv = M.child_argv(o.cwd, vim.list_extend({ "ci", "--json=" .. json }, o.args))
  table.remove(argv) -- the multi-repository run takes no --root: it works on the repositories it is told about
  entry.running = true
  local ok, started = pcall(M.system, argv, {
    cwd = o.cwd,
    text = true,
    -- no timeout: the run covers several repositories, and killing this child would orphan its own children
    stdout = feed("out"),
    stderr = feed("err"),
  }, function(res)
    vim.schedule(function()
      flush()
      entry.running = false
      local code = res.code or -1
      if (res.signal or 0) ~= 0 then
        code = 3 -- killed by a signal: infrastructure, whatever code the runtime reports
      end
      local doc = read_json(json)
      pcall(os.remove, json)
      if type(doc) == "table" and type(doc.repos) == "table" then
        local final = {}
        for i, r in ipairs(doc.repos) do
          final[i] = {
            name = tostring(r.name),
            state = r.state == "skipped" and "proven" or tostring(r.state),
            verify = r.verify,
            ms = r.ms,
          }
        end
        view.header(M.repos_table(final, #final, #final))
      end
      local verdict = M.repos_verdict(doc, code)
      progress:finish(verdict.level == "info" and "green" or "failed")
      require("testing.notify").get()[verdict.level](verdict.message)
      if #verdict.items > 0 then
        require("lib.nvim.ui.list").qf(
          verdict.items,
          "testing ci repos: findings",
          { open = "auto" }
        )
      end
      if o.on_done then
        o.on_done(code)
      end
    end)
  end)
  if not ok or not started then
    entry.running = false
    progress:cancel()
    return false, tostring(started)
  end
  return true
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
    M.show_view(o.root)
    return false, "a pipeline is already running for " .. o.root .. " (showing its output)"
  end
  local json = vim.fn.tempname() .. ".testing-ci.json"
  local plan = M.step_plan(o.root, o.profile, o.steps)
  local planned = plan and {} or nil
  for _, name in ipairs(plan or {}) do
    planned[name] = true
  end
  -- A suite step gets an events file: the run shows "suite 12/187" from it, and what the specs print stays out of
  -- the buffer (it is shown when the run is not green). Only when the plan says there is a step `suite`: an option
  -- after `--` for a run without a suite is an error.
  local quiet = planned and planned.suite
  local events = quiet and (vim.fn.tempname() .. ".testing-ci-events.ndjson") or nil
  local argv = M.run_argv({
    root = o.root,
    json = json,
    profile = o.profile,
    steps = o.steps,
    keep_going = o.keep_going,
    reuse = o.reuse,
    events = events,
  })
  local view = M.open_view(o.root)
  local progress = M.progress({ title = "testing ci" })
  -- a step counts once, and only a planned one when the plan is known: a step's own output can start with `== `
  local counted, seen = {}, 0
  local keep, raw
  if quiet then
    keep, raw = M.quiet_step("suite")
  end
  local feed, flush = M.feeder(view, function(line)
    local step = M.step_of(line)
    if step and not counted[step] and (not planned or planned[step]) then
      counted[step] = true
      seen = seen + 1
      progress:update({ text = step, current = seen, total = plan and #plan or nil })
    end
  end, keep)
  local stop_events
  if events then
    local files_total, files_done = nil, 0
    stop_events = M.tail_events(events, function(ev)
      if ev.event == "run_start" then
        files_total = ev.files_selected or ev.files_total
      elseif ev.event == "file_end" then
        files_done = files_done + 1
        progress:update({
          text = files_total and ("suite %d/%d"):format(files_done, files_total)
            or ("suite %d"):format(files_done),
        })
      elseif ev.event == "run_done" then
        view.append({
          ("   suite: %d file(s)%s"):format(
            files_done,
            ev.verdict and (", " .. ev.verdict) or ", stopped"
          ),
        })
      end
    end)
  end
  local function finish(res)
    vim.schedule(function()
      flush()
      if stop_events then
        stop_events()
        pcall(os.remove, events)
      end
      entry.running = false
      local doc = read_json(json)
      pcall(os.remove, json)
      local verdict = M.verdict(doc, res.code or -1, o.root, res.stderr)
      if raw and verdict.level ~= "info" and #raw() > 0 then
        local lines = { ("-- the last %d line(s) the suite printed:"):format(#raw()) }
        vim.list_extend(lines, raw())
        view.append(lines)
      end
      progress:finish(
        verdict.level == "info" and "green" or verdict.level == "warn" and "partial" or "failed"
      )
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
    stdout = feed("out"),
    stderr = feed("err"),
  }, finish)
  if not ok or not started then
    entry.running = false
    if stop_events then
      stop_events()
    end
    progress:cancel()
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

---@type table<string, { stamp: integer, list: table|nil, failed_at: integer|nil }>
local list_cache = {}
---@type table<string, true>
local loading = {}

---Seconds before a failed `testing ci list` is tried again (until `.testing.lua` changes).
M.LIST_RETRY = 30

---Profiles and steps of the project (`testing ci list`, cached until `.testing.lua` changes). Never waits: a miss
---starts the child in the background and returns what is known (the earlier list, or nil), so the next <Tab> has it.
---@param root string
---@return { default: string, profiles: table<string, string[]>, steps: string[] }|nil
function M.list(root)
  local cfg = vim.uv.fs_stat(root .. "/.testing.lua")
  if not cfg then
    return nil
  end
  local k = key(root)
  local stamp = cfg.mtime.sec * 1000000000 + cfg.mtime.nsec
  local cached = list_cache[k]
  if cached and cached.stamp == stamp then
    if cached.list or os.time() - (cached.failed_at or 0) < M.LIST_RETRY then
      return cached.list
    end
  end
  if not loading[k] then
    loading[k] = true
    local ok = pcall(
      M.system,
      M.child_argv(root, { "ci", "list", "--json" }),
      { cwd = root, text = true, timeout = 8000 },
      function(res)
        vim.schedule(function()
          loading[k] = nil
          local list
          if res.code == 0 then
            local okd, doc = pcall(vim.json.decode, res.stdout or "")
            list = okd and type(doc) == "table" and type(doc.profiles) == "table" and doc or nil
          end
          list_cache[k] =
            { stamp = stamp, list = list, failed_at = (not list) and os.time() or nil }
        end)
      end
    )
    if not ok then
      loading[k] = nil
    end
  end
  return cached and cached.list or nil
end

---The step a line of the terminal report starts (`== <step>` or `== <step>: <argv>` or `== <step> (skipped: ...)`).
---@param line string
---@return string|nil
function M.step_of(line)
  return line:match("^== ([^%s:]+)")
end

---The steps a run will report, without starting anything: the distinct steps asked for, or those of the profile as
---`testing ci list` gave them while `.testing.lua` is unchanged since; nil when not known.
---@param root string
---@param profile? string
---@param steps? string[]
---@return string[]|nil
function M.step_plan(root, profile, steps)
  if steps and #steps > 0 then
    local out, seen = {}, {}
    for _, name in ipairs(steps) do
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
    return out
  end
  local cfg = vim.uv.fs_stat(root .. "/.testing.lua")
  local cached = list_cache[key(root)]
  if not cfg or not cached or cached.stamp ~= cfg.mtime.sec * 1000000000 + cfg.mtime.nsec then
    return nil
  end
  local list = cached.list
  if type(list) ~= "table" or type(list.profiles) ~= "table" then
    return nil
  end
  local names = list.profiles[(profile and profile ~= "") and profile or list.default]
  return type(names) == "table" and names or nil
end

return M
