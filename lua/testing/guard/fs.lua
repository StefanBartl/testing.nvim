---@module 'testing.guard.fs'
---@brief Writes outside the run folder / temp directories: wrapped entry points plus a tree snapshot.
---@description
--- Two independent nets (D.3.5, SEC-40):
---
---   1. WRAPPERS around the write entry points while a case is open: `io.open` (write/append/update
---      modes), `io.output(path)`, `os.remove`, `os.rename`, `vim.fn.writefile` / `delete` /
---      `mkdir` / `rename`, `vim.uv.fs_open` (write flags) and the path-taking `fs_*` mutators
---      (`unlink`, `mkdir`, `rmdir`, `rename`, `copyfile`, `symlink`, `link`, `mkdtemp`, `mkstemp`,
---      `chmod`, `utime`), plus an autocmd `BufWritePre` for `:write` / `:saveas`. The path is
---      RESOLVED (`lib.nvim.fs.normkey`: relative to the cwd, symlinks and 8.3 names resolved,
---      the deepest existing ancestor for a path that does not exist yet) and compared with the
---      allowed roots; a `..` or a symlink does not get a spec out of the sandbox on paper only.
---   2. A before/after SNAPSHOT of watched trees (stdpath config/data/state/cache, the cwd, the
---      repo root): names, sizes and mtimes of a bounded number of files. It sees what the wrappers
---      cannot (a plugin writing through `vim.cmd("w")` in a nested editor, a C library, `git`), but
---      it is heavy: taken per FILE (`handle:snapshot{ heavy = true }`), not per case.
---
--- Allowed: the OS temp dir, the directory of `tempname()`, `config.run_dir`, `config.tmp`,
--- `guards.fs.allow` (directories) and `allow_patterns` (Lua patterns on the resolved path).
--- Legitimate writers (sessions, cmdlog, image calibration) are listed there, in the project's
--- config, never hard-coded.
---
--- Finding ids: `fs.write_outside` (wrapper), `fs.changed_outside` (snapshot). Ledger kind
--- `fs_outside_tmp` (IR `effects.fs_outside_tmp`). `block = true` raises instead of observing.
---
--- Limits: a write that bypasses Lua (a child process, a C library, Vimscript `:write` into a path
--- that no autocmd sees) is only caught by the snapshot, and only inside the watched, bounded
--- trees; `io.output()`/file handles opened BEFORE the window are not seen.
---
--- The tree walk is its own bounded loop (`max_files`, `max_depth`; SEC-32): `lib.nvim.fs.
--- collect_recursive` has neither bound and no stat call.

local normkey = require("lib.nvim.fs.normkey")

local M = {}

local uv = vim.uv or vim.loop
local IS_WIN = vim.fn.has("win32") == 1
local IS_CI = IS_WIN or vim.fn.has("mac") == 1

---@param p string
---@return string
local function fold(p)
  return IS_CI and p:lower() or p
end

---@param path string
---@return string|nil folded comparison key
---@return string|nil shown display form (original case)
local function resolve(path)
  if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
    return nil
  end
  local abs = path
  if not (path:match("^%a:[/\\]") or path:match("^[/\\]") or path:match("^~")) then
    abs = (uv.cwd() or ".") .. "/" .. path
  end
  local ok, k = pcall(normkey, abs, { realpath = true })
  if not ok or type(k) ~= "string" then
    return nil
  end
  return fold(k), k
end

---@param path string folded + normalized
---@param root string folded + normalized
---@return boolean
local function within(path, root)
  if path == root then
    return true
  end
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  return path:sub(1, #root) == root
end

---The directory that holds the whole sandbox of a child editor (`testing.child.env.sandbox_env`:
---`<base>/{config,data,state,cache,run,tmp}`), or `nil` in an editor that is not one. A spec that
---writes below `stdpath('data')` there writes into its own sandbox: not a write "outside". The layout
---is the test (the temp dir is `<base>/tmp` and the data and state dirs live below `<base>/data` and
---`<base>/state`), never a name.
---@return string|nil
function M.sandbox_base()
  local ok, base = pcall(function()
    local tmp = uv.os_tmpdir()
    if type(tmp) ~= "string" or tmp == "" then
      return nil
    end
    tmp = tmp:gsub("\\", "/"):gsub("/+$", "")
    local parent = tmp:match("^(.*)/tmp$")
    if not parent or parent == "" or parent:match("^%a?:?$") then
      return nil
    end
    local pk = resolve(parent)
    if not pk then
      return nil
    end
    for _, kind in ipairs({ "data", "state" }) do
      local k = resolve(vim.fn.stdpath(kind))
      local want = resolve(parent .. "/" .. kind)
      if not (k and want and within(k, want)) then
        return nil
      end
    end
    return parent
  end)
  return ok and base or nil
end

---@class Testing.Guard.Fs
---@field h Testing.Guard.Handle
---@field cfg table
---@field allowed string[] resolved allowed roots
---@field cache table<string, table> verdicts per path string
---@field seen table<string, boolean> paths the wrappers already named in this case
---@field group? integer
local G = {}
G.__index = G

---@param h Testing.Guard.Handle
---@param cfg table
---@return Testing.Guard.Fs
function M.new(h, cfg)
  return setmetatable({ h = h, cfg = cfg, allowed = {}, cache = {}, seen = {}, truncated = {} }, G)
end

---@param list any
---@return string[]
local function as_list(list)
  if type(list) == "string" then
    return { list }
  end
  return type(list) == "table" and list or {}
end

---Recompute the allowed roots (call again when `run_dir` changes).
function G:refresh_roots()
  local roots = {}
  local function add(p)
    if type(p) == "string" and p ~= "" then
      local k = resolve(p)
      if k then
        roots[#roots + 1] = k
      end
    end
  end
  add(uv.os_tmpdir())
  add(vim.fs.dirname(vim.fn.tempname()))
  for _, p in ipairs(as_list(self.h.cfg.tmp)) do
    add(p)
  end
  add(self.h.cfg.run_dir)
  add(M.sandbox_base())
  for _, p in ipairs(self.cfg.allow) do
    add(p)
  end
  if not IS_WIN then
    roots[#roots + 1] = "/dev"
  end
  self.allowed = roots
  self.cache = {}
end

---@param k string resolved key
---@return boolean
function G:is_allowed(k)
  for _, root in ipairs(self.allowed) do
    if within(k, root) then
      return true
    end
  end
  for _, pat in ipairs(self.cfg.allow_patterns) do
    local ok, hit = pcall(string.find, k, fold(pat))
    if ok and hit then
      return true
    end
  end
  local base = k:match("([^/]+)$")
  return base == "nul"
end

---Judge one write attempt on `path`.
---@param op string e.g. `io.open(w)`
---@param path any
function G:note(op, path)
  local h = self.h
  if not h:is_active() or type(path) ~= "string" then
    return
  end
  -- a relative path means something else after a `chdir`: the cwd is part of the cache key
  local ckey = path
  if not (path:match("^%a:[/\\]") or path:match("^[/\\~]")) then
    ckey = (uv.cwd() or "") .. "\0" .. path
  end
  local entry = self.cache[ckey]
  if entry == nil then
    local k, shown = resolve(path)
    entry = { k = k, shown = shown, ok = k == nil or self:is_allowed(k) }
    self.cache[ckey] = entry
  end
  if entry.ok then
    return
  end
  local k = entry.k --[[@as string]]
  self.seen[k] = true
  h:log("fs_outside_tmp", ("%s %s"):format(op, entry.shown))
  local msg =
    h.redact(("%s writes outside the allowed roots: %s (%s)"):format(h:label(), entry.shown, op))
  h:finding("fs", "fs.write_outside", msg, { mode = self.cfg.mode, stack = h:stack(4) })
  if self.cfg.block then
    error("testing.guard: " .. msg, 0)
  end
end

---@param flags any string (`w`, `a+`) or number (O_* bits)
---@return boolean
local function flags_write(flags)
  if type(flags) == "string" then
    return flags:find("[wa+]") ~= nil
  end
  if type(flags) == "number" then
    local c = uv.constants or {}
    local mask =
      bit.bor(c.O_WRONLY or 1, c.O_RDWR or 2, c.O_CREAT or 64, c.O_APPEND or 1024, c.O_TRUNC or 512)
    return bit.band(flags, mask) ~= 0
  end
  return false
end

-- path-taking mutators of luv: name -> argument positions that name a path
local UV_MUTATORS = {
  fs_unlink = { 1 },
  fs_mkdir = { 1 },
  fs_rmdir = { 1 },
  fs_rename = { 1, 2 },
  fs_copyfile = { 2 },
  fs_symlink = { 2 },
  fs_link = { 2 },
  fs_mkdtemp = { 1 },
  fs_mkstemp = { 1 },
  fs_chmod = { 1 },
  fs_utime = { 1 },
}

function G:install()
  local h, g = self.h, self
  local p = h.patcher
  self:refresh_roots()

  p:wrap(io, "open", function(orig)
    return function(path, mode, ...)
      if h.active and type(mode) == "string" and flags_write(mode) then
        g:note("io.open(" .. mode .. ")", path)
      end
      return orig(path, mode, ...)
    end
  end, "io.open")
  p:wrap(io, "output", function(orig)
    return function(file, ...)
      if h.active and type(file) == "string" then
        g:note("io.output", file)
      end
      return orig(file, ...)
    end
  end, "io.output")
  p:wrap(os, "remove", function(orig)
    return function(path, ...)
      if h.active then
        g:note("os.remove", path)
      end
      return orig(path, ...)
    end
  end, "os.remove")
  p:wrap(os, "rename", function(orig)
    return function(a, b, ...)
      if h.active then
        g:note("os.rename", a)
        g:note("os.rename", b)
      end
      return orig(a, b, ...)
    end
  end, "os.rename")

  p:wrap(vim.fn, "writefile", function(orig)
    return function(list, fname, ...)
      if h.active then
        g:note("writefile", fname)
      end
      return orig(list, fname, ...)
    end
  end, "vim.fn.writefile")
  p:wrap(vim.fn, "delete", function(orig)
    return function(name, ...)
      if h.active then
        g:note("delete", name)
      end
      return orig(name, ...)
    end
  end, "vim.fn.delete")
  p:wrap(vim.fn, "mkdir", function(orig)
    return function(name, ...)
      if h.active and type(name) == "string" and not uv.fs_stat(name) then
        g:note("mkdir", name)
      end
      return orig(name, ...)
    end
  end, "vim.fn.mkdir")
  p:wrap(vim.fn, "rename", function(orig)
    return function(a, b)
      if h.active then
        g:note("rename", a)
        g:note("rename", b)
      end
      return orig(a, b)
    end
  end, "vim.fn.rename")

  p:wrap(uv, "fs_open", function(orig)
    return function(path, flags, ...)
      if h.active and flags_write(flags) then
        g:note("uv.fs_open", path)
      end
      return orig(path, flags, ...)
    end
  end, "uv.fs_open")
  for name, positions in pairs(UV_MUTATORS) do
    p:wrap(uv, name, function(orig)
      return function(...)
        if h.active then
          for _, i in ipairs(positions) do
            local path = (select(i, ...))
            if name ~= "fs_mkdir" or type(path) ~= "string" or not uv.fs_stat(path) then
              g:note("uv." .. name, path)
            end
          end
        end
        return orig(...)
      end
    end, "uv." .. name)
  end

  self.group = vim.api.nvim_create_augroup("testing.guard.fs", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePre", {
    group = self.group,
    desc = "testing.guard: write outside the allowed roots",
    callback = function(ev)
      if h.active and vim.bo[ev.buf].buftype == "" then
        g:note("BufWritePre", ev.match ~= "" and ev.match or ev.file)
      end
    end,
  })
end

function G:uninstall()
  if self.group then
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
    self.group = nil
  end
end

-- =========================================================
-- Tree snapshot
-- =========================================================

---Names, sizes and mtimes below `root` (bounded). Symlinks are listed, never followed.
---@param root string
---@param ignore table<string, boolean>
---@param patterns string[]
---@param max_files integer
---@param max_depth integer
---@return table<string, string> files rel path -> signature
---@return boolean truncated
local function scan(root, ignore, patterns, max_files, max_depth)
  local files, n, truncated = {}, 0, false
  local function walk(dir, rel, depth)
    if truncated then
      return
    end
    if depth > max_depth then
      truncated = true
      return
    end
    local req = uv.fs_scandir(dir)
    if not req then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(req)
      if not name then
        break
      end
      local r = rel == "" and name or (rel .. "/" .. name)
      if typ == "directory" then
        if not ignore[name] then
          walk(dir .. "/" .. name, r, depth + 1)
        end
      elseif typ ~= nil and not ignore[name] then
        local skip = false
        for _, pat in ipairs(patterns) do
          if name:find(pat) then
            skip = true
            break
          end
        end
        if not skip then
          n = n + 1
          if n > max_files then
            truncated = true
            return
          end
          local st = uv.fs_lstat(dir .. "/" .. name)
          files[r] = st and ("%d:%d:%d"):format(st.size, st.mtime.sec, st.mtime.nsec) or "?"
        end
      end
    end
  end
  walk(root, "", 1)
  return files, truncated
end

---@return string[] roots resolved, unique, without roots nested in another one
function G:watch_roots()
  local list = {}
  local src = self.cfg.watch
  if src == nil then
    src = {}
    -- the real stdpath trees of a developer machine hold tens of thousands of files (plugin clones, a
    -- whole config repo): walking them twice per file cost seconds per file and the walk is cut at
    -- `max_files` anyway, i.e. mostly blind. They are opt-in (`watch_stdpath`); the wrappers still see
    -- every write that goes through Lua.
    if self.cfg.watch_stdpath then
      for _, what in ipairs({ "config", "data", "state", "cache" }) do
        src[#src + 1] = vim.fn.stdpath(what)
      end
    end
    src[#src + 1] = uv.cwd()
    src[#src + 1] = self.h.cfg.repo
  end
  src = vim.list_extend(vim.deepcopy(src), self.cfg.watch_extra or {})
  for _, p in ipairs(src) do
    local k, shown
    if type(p) == "string" and p ~= "" then
      k, shown = resolve(p)
    end
    if k and shown and uv.fs_stat(shown) then
      list[#list + 1] = { k = k, shown = shown }
    end
  end
  table.sort(list, function(a, b)
    return #a.k < #b.k
  end)
  local out, kept = {}, {}
  for _, e in ipairs(list) do
    local nested = false
    for _, o in ipairs(kept) do
      if within(e.k, o) then
        nested = true
        break
      end
    end
    if not nested then
      kept[#kept + 1] = e.k
      out[#out + 1] = e.shown
    end
  end
  return out
end

---@param opts { heavy?: boolean }
---@return table
function G:snapshot(opts)
  self:refresh_roots()
  self.seen = {}
  if not opts.heavy or not self.cfg.snapshot then
    return { trees = nil }
  end
  local ignore = {}
  for _, n in ipairs(self.cfg.ignore) do
    ignore[n] = true
  end
  local trees = {}
  for _, root in ipairs(self:watch_roots()) do
    local files, truncated =
      scan(root, ignore, self.cfg.ignore_patterns, self.cfg.max_files, self.cfg.max_depth)
    trees[root] = { files = files, truncated = truncated }
    if truncated then
      self.h.notes[#self.h.notes + 1] = ("fs guard: snapshot of %s is truncated (max_files/max_depth): changes below the cut are not seen"):format(
        self.h.redact(root)
      )
    end
  end
  return { trees = trees, ignore = ignore }
end

---@param snap? table
---@param ctx Testing.Guard.CaseCtx
function G:check(snap, ctx)
  if not snap or not snap.trees then
    return
  end
  local h = self.h
  local label = h:label(ctx)
  for root, before in pairs(snap.trees) do
    local after =
      scan(root, snap.ignore, self.cfg.ignore_patterns, self.cfg.max_files, self.cfg.max_depth)
    local changes = {}
    for rel, sig in pairs(after) do
      if before.files[rel] == nil then
        changes[#changes + 1] = { rel, "created" }
      elseif before.files[rel] ~= sig then
        changes[#changes + 1] = { rel, "modified" }
      end
    end
    for rel in pairs(before.files) do
      if after[rel] == nil then
        changes[#changes + 1] = { rel, "deleted" }
      end
    end
    table.sort(changes, function(a, b)
      return a[1] < b[1]
    end)
    local shown = 0
    for _, c in ipairs(changes) do
      local k = fold(root .. "/" .. c[1])
      if not self:is_allowed(k) and not self.seen[k] then
        shown = shown + 1
        if shown <= 10 then
          local full = root .. "/" .. c[1]
          h:log("fs_outside_tmp", ("%s %s"):format(c[2], full))
          h:finding(
            "fs",
            "fs.changed_outside",
            ("%s %s %s (seen by the tree snapshot)"):format(label, c[2], full),
            { mode = self.cfg.mode }
          )
        end
      end
    end
    if shown > 10 then
      h:finding(
        "fs",
        "fs.changed_outside",
        ("%s changed %d more files under %s (not listed)"):format(label, shown - 10, root),
        { mode = self.cfg.mode }
      )
    end
  end
end

return M
