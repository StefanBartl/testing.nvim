---@module 'testing.affected.git'
---@brief Changed files from git: argv only (never a shell), validated revisions, NUL-separated output.
---@description
--- Every call is an argv list handed to `vim.system` with `cwd = root` (SEC-01/02): a revision comes
--- from the command line and is validated before it reaches git (no leading `-`, a plain charset, no
--- range, no whitespace), and a `--` ends the revision part of `git diff`. Output is read with `-z`
--- (a file name with a space, a quote or a newline is one entry); renames are reported as a delete
--- plus an add (`--no-renames`), so the OLD path counts as changed as well.
---
--- Paths that come back are sanitized: an entry that is absolute, climbs out of the root (`..`) or
--- holds a control character is not trusted and is returned in `unsafe` (the caller selects
--- everything).
---
--- The git runner can be injected (`opts.run`) for specs: `fun(argv, cwd): { code, stdout, stderr }`.

local M = {}

---@type integer
M.TIMEOUT_MS = 30000
---Largest accepted revision text.
---@type integer
M.MAX_REF = 200

---@class Testing.Affected.GitResult
---@field code integer
---@field stdout string
---@field stderr string

---Run a git command; no shell is involved.
---@param argv string[]
---@param cwd string
---@return Testing.Affected.GitResult
function M.default_run(argv, cwd)
  local ok, res = pcall(function()
    return vim
      .system(argv, {
        cwd = cwd,
        text = true,
        timeout = M.TIMEOUT_MS,
        env = { GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0" },
      })
      :wait(M.TIMEOUT_MS + 1000)
  end)
  if not ok or not res then
    return { code = 127, stdout = "", stderr = "cannot run git: " .. tostring(res) }
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---Run several git commands AT ONCE (each is a process start, which costs tens of milliseconds on Windows) and
---wait for all of them. The results come back in the order of `argvs`; a command that cannot start is a result
---with code 127, never an error.
---@param argvs string[][]
---@param cwd string
---@return Testing.Affected.GitResult[]
function M.run_parallel(argvs, cwd)
  local procs, results = {}, {}
  for i, argv in ipairs(argvs) do
    local ok, proc = pcall(function()
      return vim.system(argv, {
        cwd = cwd,
        text = true,
        timeout = M.TIMEOUT_MS,
        env = { GIT_OPTIONAL_LOCKS = "0", GIT_TERMINAL_PROMPT = "0" },
      })
    end)
    if ok and proc then
      procs[i] = proc
    else
      results[i] = { code = 127, stdout = "", stderr = "cannot run git: " .. tostring(proc) }
    end
  end
  for i, proc in pairs(procs) do
    local ok, res = pcall(proc.wait, proc, M.TIMEOUT_MS + 1000)
    if ok and res then
      results[i] = { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
    else
      results[i] = { code = 127, stdout = "", stderr = "cannot run git: " .. tostring(res) }
    end
  end
  return results
end

---Is `ref` an acceptable revision text for argv use?
---@param ref any
---@return boolean ok
---@return string|nil why
function M.valid_ref(ref)
  if type(ref) ~= "string" or ref == "" then
    return false, "empty revision"
  end
  if #ref > M.MAX_REF then
    return false, "revision too long"
  end
  if ref:sub(1, 1) == "-" then
    return false, "a revision must not start with '-'"
  end
  if ref:find("..", 1, true) then
    return false, "a range is not a revision"
  end
  if not ref:match("^[%w_%./~%^@{}%-]+$") then
    return false, "revision holds characters git does not need"
  end
  return true
end

---@param path string
---@return boolean
local function safe_path(path)
  if path == "" or #path > 1024 then
    return false
  end
  if path:find("[%c]") or path:find("\\", 1, true) then
    return false
  end
  if path:sub(1, 1) == "/" or path:match("^%a:") then
    return false
  end
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      return false
    end
  end
  return true
end

---@param out string
---@return string[] paths
---@return string[] unsafe
local function split_z(out)
  local paths, unsafe, seen = {}, {}, {}
  for entry in out:gmatch("[^%z]+") do
    if not seen[entry] then
      seen[entry] = true
      if safe_path(entry) then
        paths[#paths + 1] = entry
      else
        unsafe[#unsafe + 1] = entry
      end
    end
  end
  return paths, unsafe
end

---@class Testing.Affected.ChangedOpts
---@field mode "changed"|"since"|"affected"
---@field since? string Revision for `since` (required) and `affected` (default `HEAD~1`).
---@field run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@field ignored_dirs? string[] Directories (relative) in which an IGNORED file newer than the base revision counts as changed (generated modules, built data): `lua` and the spec roots.
---@field mtime? fun(rel: string): integer|nil Modification time of a file below the root (specs).

---Most ignored files listed below the directories of `ignored_dirs`.
---@type integer
M.MAX_IGNORED = 5000

---Changed files below `root`: tracked changes against the base revision (working tree included),
---untracked files that are not ignored, and ignored files below `ignored_dirs` that are newer than the
---base revision (git cannot say what changed in a file it ignores: its time is the only evidence).
---@param root string
---@param opts Testing.Affected.ChangedOpts
---@return string[]|nil files Sorted, relative to `root`.
---@return string|nil err
---@return string[]|nil unsafe Entries git printed that were not trusted.
function M.changed(root, opts)
  local run = opts.run or M.default_run
  local base
  if opts.mode == "changed" then
    base = "HEAD"
  elseif opts.mode == "since" then
    base = opts.since
  elseif opts.mode == "affected" then
    base = opts.since or "HEAD~1"
  else
    return nil, "unknown mode " .. tostring(opts.mode)
  end
  local ok, why = M.valid_ref(base)
  if not ok then
    return nil, why
  end
  local verify_argv = { "git", "rev-parse", "--verify", "--quiet", base .. "^{commit}" }
  local diff_argv = { "git", "diff", "--name-only", "-z", "--no-renames", "--relative", base, "--" }
  local untracked_argv = { "git", "ls-files", "--others", "--exclude-standard", "-z", "--" }
  if not opts.run then
    -- the real git: every command this selection needs starts at once, the answers are read in the usual order
    local batch = { verify_argv, diff_argv, untracked_argv }
    local ignored_argv = M.ignored_argv(opts)
    if ignored_argv then
      batch[#batch + 1] = ignored_argv
      batch[#batch + 1] = M.since_argv(base)
    end
    local answers = M.run_parallel(batch, root)
    local by_key = {}
    for i, argv in ipairs(batch) do
      by_key[table.concat(argv, "\0")] = answers[i]
    end
    run = function(argv, cwd)
      return by_key[table.concat(argv, "\0")] or M.default_run(argv, cwd)
    end
  end
  local verify = run(verify_argv, root)
  if verify.code ~= 0 then
    return nil,
      ("git does not know the revision '%s'%s"):format(
        base,
        verify.stderr ~= "" and (": " .. vim.trim(verify.stderr)) or ""
      )
  end
  local diff = run(diff_argv, root)
  if diff.code ~= 0 then
    return nil, "git diff failed: " .. vim.trim(diff.stderr)
  end
  local untracked = run(untracked_argv, root)
  if untracked.code ~= 0 then
    return nil, "git ls-files failed: " .. vim.trim(untracked.stderr)
  end
  local a, ua = split_z(diff.stdout)
  local b, ub = split_z(untracked.stdout)
  local c, uc = {}, {}
  if opts.ignored_dirs and #opts.ignored_dirs > 0 then
    c, uc = M.ignored_newer(root, base --[[@as string]], opts, run)
  end
  local seen, files = {}, {}
  for _, list in ipairs({ a, b, c }) do
    for _, p in ipairs(list) do
      if not seen[p] then
        seen[p] = true
        files[#files + 1] = p
      end
    end
  end
  table.sort(files)
  return files, nil, vim.list_extend(vim.list_extend(ua, ub), uc)
end

---The command that lists the ignored files below `opts.ignored_dirs` (nil: no directory is usable).
---@param opts { ignored_dirs?: string[] }
---@return string[]|nil argv
function M.ignored_argv(opts)
  local argv = { "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--" }
  for _, d in ipairs(opts.ignored_dirs or {}) do
    if safe_path(d) then
      argv[#argv + 1] = d
    end
  end
  if #argv == 7 then
    return nil
  end
  return argv
end

---The command that gives the commit time of `base`.
---@param base string
---@return string[] argv
function M.since_argv(base)
  return { "git", "log", "-1", "--format=%ct", base, "--" }
end

---Ignored files below `opts.ignored_dirs` that are newer than the commit `base`.
---@param root string
---@param base string A revision that was verified.
---@param opts Testing.Affected.ChangedOpts
---@param run fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@return string[] files
---@return string[] unsafe
function M.ignored_newer(root, base, opts, run)
  local argv = M.ignored_argv(opts)
  if not argv then
    return {}, {}
  end
  local listed = run(argv, root)
  if listed.code ~= 0 then
    return {}, {}
  end
  local since = run(M.since_argv(base), root)
  local base_time = since.code == 0 and tonumber(vim.trim(since.stdout)) or nil
  if not base_time then
    return {}, {}
  end
  local paths, unsafe = split_z(listed.stdout)
  if #paths > M.MAX_IGNORED then
    return {}, {
      ("more than %d ignored files below %s"):format(
        M.MAX_IGNORED,
        table.concat(opts.ignored_dirs, ", ")
      ),
    }
  end
  local mtime = opts.mtime
    or function(rel)
      local st = vim.uv.fs_stat(root .. "/" .. rel)
      return st and st.mtime and st.mtime.sec or nil
    end
  local out = {}
  for _, p in ipairs(paths) do
    local t = mtime(p)
    if t and t >= base_time then
      out[#out + 1] = p
    end
  end
  return out, unsafe
end

---Unix time of the last commit that touched anything outside `exclude` (a pathspec), nil when unknown.
---@param root string
---@param exclude? string Pathspec to leave out, e.g. `docs/map`.
---@param run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@return integer|nil
function M.last_commit_time(root, exclude, run)
  run = run or M.default_run
  local argv = { "git", "log", "-1", "--format=%ct", "--", "." }
  if exclude then
    argv[#argv + 1] = ":(exclude)" .. exclude
  end
  local r = run(argv, root)
  if r.code ~= 0 then
    return nil
  end
  return tonumber(vim.trim(r.stdout))
end

return M
