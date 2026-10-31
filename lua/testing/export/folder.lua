---@module 'testing.export.folder'
-- @cache-env NVIM_MACHINE_ROLE
---@brief `testing export --out <dir>`: write the export folder of `testing-export/1` (manifest last, atomic).
---@description
--- ```
--- testing export --out <dir> [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]
---                [--remote] [--state-dir=<dir>]
--- ```
---
--- The folder (docs/OUTPUT-FORMATS.md, "The export folder"):
---
---   testing-export.json   the manifest: files[{ path, sha256, bytes }], digest, capabilities
---   fleet.json            kind fleet, export form (no absolute path, no root)
---   repos/<key>.json      kind repo, one per exported repository
---
--- Only repositories whose data class is `public` or `internal` are exported (`testing.export.release`,
--- fail-closed: `private` and `unclassified` are counted in the fleet's `excluded_by`, never named).
---
--- Atomic: every file is first written into `<dir>/.tmp-<id>/new/`, then moved into place file by file (a file whose
--- bytes did not change is not touched), the manifest last. A file that is replaced is first moved to
--- `<dir>/.tmp-<id>/old/`; when a step fails, every file already moved is put back, so the old manifest stays valid
--- and matches the files it lists. The files of repositories that are no longer exported are moved to `old/` too,
--- right before the manifest (put back when that fails, so the old manifest still owns them): none stays next to a
--- manifest that no longer lists it. Nothing is ever deleted that the folder's manifest does not own: a folder that
--- is not empty and has no manifest is refused, and so is a manifest that names a file of another shape, or a file
--- of the shape this command writes (`fleet.json`, `repos/*.json`) that the manifest does not list.
---
--- A `.tmp-<id>/` that an earlier write left behind (a crash, or one it could not remove) may hold the documents of a
--- repository that is no longer released, and the folder may be committed as it is: the next write removes it first,
--- entry by entry and only the entries a write creates there (`new/`, `old/`, below each `fleet.json`, the manifest,
--- `repos/<key>.json`). A `.tmp-*` that holds anything else, or is no plain directory, refuses the folder (exit 2,
--- nothing removed). A folder without a manifest that holds nothing but such leftovers counts as empty.
---
--- The texts of the folder as it is are handed to `testing.export.export` as `previous`: a second export of an
--- unchanged state writes the same bytes (no git diff in a results repository).
---
--- On the workstation (`NVIM_MACHINE_ROLE=workstation`) no local result is read (`local_read = false`, the local
--- parts are `null`); nothing here starts a test run anywhere, on any machine.
---
--- Exit codes: 0 written (also unchanged, also an empty fleet), 2 usage (an unknown option, no `--out`, a directory
--- that is not there, no repository, a folder that is refused, an `NVIM_MACHINE_ROLE` that is neither `workstation`
--- nor `default`), 3 the documents could not be built (a leak, too large) or the folder could not be written.

local M = {}

M.EXIT_OK, M.EXIT_USAGE, M.EXIT_INFRA = 0, 2, 3

M.USAGE = table.concat({
  "usage: testing export --out <dir> [<repo>...] [--repos-root=<dir>] [--include=<names>] [--exclude=<names>]",
  "                      [--remote] [--state-dir=<dir>]",
  "  --out <dir>         the export folder (empty, or one this command wrote: it has testing-export.json)",
  "  --repos-root=<dir>  the repositories below <dir> (workflows or a .testing.lua; no vault; repeatable)",
  "  --include=<names>   also these directory names below --repos-root (besides lib.nvim)",
  "  --exclude=<names>   leave these directory names out",
  "  --remote            ask the CI adapter (GitHub); without it ci_remote is null",
  "  --state-dir=<dir>   the state directory (default: stdpath('state'))",
  "  only public and internal repositories (areas.json of this device) are exported; runs nothing",
  "  exit: 0 written, 2 usage or the folder refused, 3 not built or not written",
}, "\n")

---A file the manifest of an export folder may own (and so the only files this module ever replaces or removes).
---@param path any
---@return boolean
function M.owned_path(path)
  return type(path) == "string"
    and (path == "fleet.json" or path:match("^repos/[%w_.%-]+%.json$") ~= nil)
end

---The seams of a write: its file operations, the id of its temporary folder, the environment.
---@class Testing.Export.Folder.Deps
---@field write fun(path: string, text: string): boolean|nil, string|nil
---@field rename fun(from: string, to: string): boolean|nil, string|nil
---@field unlink fun(path: string): boolean|nil, string|nil
---@field rmdir fun(path: string): boolean|nil, string|nil
---@field delete fun(path: string): integer
---@field id fun(): string
---@field alive fun(pid: integer): boolean
---@field getenv fun(name: string): string|nil

---Replaced by a spec: the file operations of a write (a failure in the middle of one is simulated here).
---@type Testing.Export.Folder.Deps
M.deps = {
  ---@param path string
  ---@param text string
  ---@return boolean|nil ok
  ---@return string|nil err
  write = function(path, text)
    local f, err = io.open(path, "wb")
    if not f then
      return nil, err
    end
    local okw, werr = f:write(text)
    local okc, cerr = f:close()
    if not okw then
      return nil, werr
    end
    if not okc then
      return nil, cerr
    end
    return true
  end,
  ---@param from string
  ---@param to string
  ---@return boolean|nil ok
  ---@return string|nil err
  rename = function(from, to)
    return vim.uv.fs_rename(from, to)
  end,
  ---@param path string
  ---@return boolean|nil ok
  ---@return string|nil err
  unlink = function(path)
    return vim.uv.fs_unlink(path)
  end,
  ---Remove an empty directory (one of a leftover temporary folder).
  ---@param path string
  ---@return boolean|nil ok
  ---@return string|nil err
  rmdir = function(path)
    return vim.uv.fs_rmdir(path)
  end,
  ---Remove the temporary folder of a write (0: removed, as `vim.fn.delete`).
  ---@param path string
  ---@return integer
  delete = function(path)
    return vim.fn.delete(path, "rf")
  end,
  ---The id of the temporary folder of one write.
  ---@return string
  id = function()
    return ("%d-%s"):format(
      vim.uv.os_getpid(),
      vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random())):sub(1, 8)
    )
  end,
  ---Whether the process `pid` still runs (the write that owns a `.tmp-<pid>-<hex>` may still be busy with it).
  ---`EPERM`: it runs, as another user.
  ---@param pid integer
  ---@return boolean
  alive = function(pid)
    local okk, _, name = vim.uv.kill(pid, 0)
    return okk == 0 or name == "EPERM"
  end,
  ---@param name string
  ---@return string|nil
  getenv = function(name)
    return vim.env[name]
  end,
}

---The name of the temporary folder of a write starts with this (`<dir>/.tmp-<id>/`).
M.TMP_PREFIX = ".tmp-"

---The name of a temporary folder as a write makes it (`M.deps.id`: `<pid>-<hex>`); the capture is the pid. Only a
---name of this shape is ever taken for a leftover (a `.tmp-review/` of the user's is not the export's).
M.TMP_PATTERN = "^%.tmp%-(%d+)%-%x+$"

---The temporary folders of the writes of this process that are running now (one waits in `vim.wait`, say): never
---a leftover, although their pid is this process's.
---@type table<string, true>
local active = {}

---The pid of the write that made the temporary folder `name`, or nil when the name is not of the shape a write makes.
---@param name string
---@return integer|nil
local function tmp_pid(name)
  local pid = tonumber(name:match(M.TMP_PATTERN) or "")
  if pid and pid > 0 and pid < 2 ^ 31 then
    return math.floor(pid)
  end
  return nil
end

---Whether the temporary folder `name` in `dir` belongs to a write that may still be running: one of this process
---that is not done, or one of another process that still runs. A folder of this process's pid that no running write
---of it owns is a leftover (one write at a time per process, and a pid of a dead process may come back).
---@param dir string Absolute.
---@param name string
---@return integer|nil pid The pid of the running write.
local function in_use(dir, name)
  local pid = tmp_pid(name)
  if not pid then
    return nil
  end
  if active[dir .. "/" .. name] then
    return pid
  end
  if pid ~= vim.uv.os_getpid() and M.deps.alive(pid) then
    return pid
  end
  return nil
end

---Why the leftover `name` is refused: it is no plain directory (`foreign == ""`) or holds `foreign`.
---@param out string As the user named it.
---@param name string
---@param foreign string Relative to the leftover, or "".
---@return string
local function refusal(out, name, foreign)
  if foreign == "" then
    return ("%s/%s is no plain directory, an export never makes it: refused (nothing is removed; remove it by hand)"):format(
      out,
      name
    )
  end
  return ("%s/%s/%s is nothing an export writes there: refused (nothing is removed; remove it by hand)"):format(
    out,
    name,
    foreign
  )
end

---Why the folder is refused while the write that owns `name` runs.
---@param out string
---@param name string
---@param pid integer
---@return string
local function busy(out, name, pid)
  return ("%s/%s is the temporary folder of a write that is still running (process %d): refused, one write at a time per folder (try again when it is done; nothing is removed)"):format(
    out,
    name,
    pid
  )
end

---What a write creates inside its temporary folder, by depth: `new/` and `old/`, below each the files of the folder
---(`fleet.json`, the manifest, `repos/`), below `repos/` only `<key>.json`.
---@param parts string[] The path below `.tmp-<id>`, split at `/`.
---@param kind string The type of the entry (`vim.uv.fs_lstat`).
---@return boolean
local function tmp_entry(parts, kind)
  local depth, name = #parts, parts[#parts]
  if depth == 1 then
    return (name == "new" or name == "old") and kind == "directory"
  end
  if depth == 2 then
    if name == "repos" then
      return kind == "directory"
    end
    return (name == "fleet.json" or name == require("testing.export").MANIFEST) and kind == "file"
  end
  return depth == 3 and parts[2] == "repos" and M.owned_path("repos/" .. name) and kind == "file"
end

---Every entry of a leftover temporary folder, the deepest first (the order of removal), or the first one that a write
---never creates there (nothing is then removed: it is someone else's).
---@param tmp string The `.tmp-<id>` folder, absolute.
---@return { path: string, dir: boolean }[]|nil entries
---@return string|nil foreign Relative to `tmp`.
local function tmp_entries(tmp)
  local st = vim.uv.fs_lstat(tmp)
  if not st or st.type ~= "directory" then
    return nil, ""
  end
  local out = {}
  ---@param rel string[]
  ---@return string|nil foreign
  local function scan(rel)
    local here = #rel == 0 and tmp or (tmp .. "/" .. table.concat(rel, "/"))
    local handle = vim.uv.fs_scandir(here)
    if not handle then
      return table.concat(rel, "/")
    end
    local names = {}
    while true do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local parts = vim.list_extend(vim.list_slice(rel, 1), { name })
      local path = here .. "/" .. name
      local est = vim.uv.fs_lstat(path)
      local kind = est and est.type or "unknown"
      if not tmp_entry(parts, kind) then
        return table.concat(parts, "/")
      end
      if kind == "directory" then
        local foreign = scan(parts)
        if foreign then
          return foreign
        end
      end
      out[#out + 1] = { path = path, dir = kind == "directory" }
    end
    return nil
  end
  local foreign = scan({})
  if foreign then
    return nil, foreign
  end
  out[#out + 1] = { path = tmp, dir = true }
  return out
end

---The temporary folders an earlier write left behind in `dir` (a crash, or one it could not remove): their names,
---sorted, or why the folder is refused (a `.tmp-<pid>-<hex>` of a write that still runs, that holds something a write
---never creates there, or is no plain directory). Only names of the shape a write makes (`M.TMP_PATTERN`) are looked
---at: a `.tmp-review` is someone else's and never touched. Reads only.
---@param dir string Absolute.
---@param out string As the user named it (for the message).
---@return string[]|nil names
---@return string|nil problem
function M.leftovers(dir, out)
  local names = {}
  local handle = vim.uv.fs_scandir(dir)
  while handle do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if tmp_pid(name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local pid = in_use(dir, name)
    if pid then
      return nil, busy(out, name, pid)
    end
    local _, foreign = tmp_entries(dir .. "/" .. name)
    if foreign then
      return nil, refusal(out, name, foreign)
    end
  end
  return names
end

---Remove the leftover temporary folders of earlier writes, entry by entry and only the entries a write creates (a
---leftover may hold the documents of a repository that is no longer released). An entry that appeared since the check
---makes its directory fail to go: an error, nothing unknown is removed. Each one removed gets a warning (it may be the
---one a failed write named as the place of the old files).
---@param dir string Absolute.
---@param out string
---@param names string[] From `M.leftovers`.
---@return string[]|nil warnings
---@return { code: integer, message: string }|nil err
local function remove_leftovers(dir, out, names)
  local warnings = {}
  for _, name in ipairs(names) do
    -- it may have changed since `M.leftovers` looked: the same refusals
    local pid = in_use(dir, name)
    if pid then
      return nil, { code = M.EXIT_USAGE, message = busy(out, name, pid) }
    end
    local entries, foreign = tmp_entries(dir .. "/" .. name)
    if not entries then
      return nil, { code = M.EXIT_USAGE, message = refusal(out, name, foreign or "") }
    end
    for _, e in ipairs(entries) do
      local okr, rerr
      if e.dir then
        okr, rerr = M.deps.rmdir(e.path)
      else
        okr, rerr = M.deps.unlink(e.path)
      end
      if not okr then
        return nil,
          {
            code = M.EXIT_INFRA,
            message = ("cannot remove %s/%s, the temporary folder of an earlier write (%s): remove it by hand"):format(
              out,
              name,
              tostring(rerr)
            ),
          }
      end
    end
    warnings[#warnings + 1] = ("removed %s/%s, the temporary folder an earlier write left behind (with the files in its old/, if a failed write named it as their place)"):format(
      out,
      name
    )
  end
  return warnings
end

---@param path string
---@return string|nil
local function read(path)
  return require("lib.nvim.fs.read_bounded")(path, require("testing.export").MAX_DOC_BYTES + 1)
end

---@param dir string
---@return string
local function norm(dir)
  return (
    vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(dir), ":p")):gsub("([^:/])/+$", "%1")
  )
end

---Whether this machine is the workstation (no local runs: the local parts are not read). An unknown value is refused,
---as `testing sheets run` refuses it (a typo must not decide what a document says).
---@param getenv? fun(name: string): string|nil
---@return boolean|nil workstation
---@return string|nil problem
function M.workstation(getenv)
  local role = vim.trim((getenv or M.deps.getenv)("NVIM_MACHINE_ROLE") or ""):lower()
  if role == "" or role == "default" then
    return false
  end
  if role == "workstation" then
    return true
  end
  return nil,
    ("NVIM_MACHINE_ROLE=%q is neither workstation nor default (a typo?): refused until it is set right"):format(
      role
    )
end

---@class Testing.Export.Folder.State
---@field dir string Absolute.
---@field exists boolean
---@field owned table<string, true> The files the current manifest lists.
---@field manifest? boolean The folder has a manifest of this command (which lists every file but itself).
---@field leftovers? string[] The `.tmp-<id>` folders of earlier writes (`M.leftovers`), removed by the next write.

---What the folder holds now, or why it is refused: not a directory, not empty without a manifest (the leftover
---temporary folders of earlier writes do not count), a manifest that is none or names a file this command never
---writes, a `repos` that is a link, a `.tmp-*` that holds anything a write never creates there. Reads only.
---@param out string
---@return Testing.Export.Folder.State|nil state
---@return string|nil problem
function M.inspect(out)
  local dir = norm(out)
  local st = vim.uv.fs_stat(dir)
  if not st then
    return { dir = dir, exists = false, owned = {} }
  end
  if st.type ~= "directory" then
    return nil, ("%s is not a directory"):format(out)
  end
  local export = require("testing.export")
  -- what an earlier write left behind (a crash): removed by the next write, unless it holds anything else
  local leftovers, lproblem = M.leftovers(dir, out)
  if not leftovers then
    return nil, lproblem
  end
  local mpath = dir .. "/" .. export.MANIFEST
  if not vim.uv.fs_lstat(mpath) then
    -- a first export whose folder holds only the leftover of an earlier write is an empty one
    local handle = vim.uv.fs_scandir(dir)
    while handle do
      local name = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if not tmp_pid(name) then
        return nil,
          ("%s is not empty and has no %s: refused (only an empty folder or one this command wrote)"):format(
            out,
            export.MANIFEST
          )
      end
    end
    return { dir = dir, exists = true, owned = {}, leftovers = leftovers }
  end
  local text = read(mpath)
  local doc = text and export.read(text)
  if not doc or doc.kind ~= "manifest" or doc.form ~= "export" or type(doc.files) ~= "table" then
    return nil,
      ("%s/%s is no manifest of %s: refused (nothing in the folder is touched)"):format(
        out,
        export.MANIFEST,
        export.SCHEMA
      )
  end
  local owned = {}
  for _, f in ipairs(doc.files) do
    local path = type(f) == "table" and f.path or nil
    if type(path) ~= "string" or not M.owned_path(path) then
      return nil,
        ("%s/%s names a file this command never writes (%s): refused"):format(
          out,
          export.MANIFEST,
          tostring(path):sub(1, 80)
        )
    end
    owned[path] = true
  end
  local repos = vim.uv.fs_lstat(dir .. "/repos")
  if repos and repos.type ~= "directory" then
    return nil, ("%s/repos is not a plain directory (a link?): refused"):format(out)
  end
  -- a file of a shape this command writes that the manifest does not list is someone else's (or one a former write
  -- could not clean up): any export that names it would be refused, so the folder is refused now, before anything
  -- runs (`testing ci --export` asks here before an hour of pipelines)
  local candidates = { "fleet.json" }
  local handle = repos and vim.uv.fs_scandir(dir .. "/repos")
  while handle do
    local name = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    candidates[#candidates + 1] = "repos/" .. name
  end
  table.sort(candidates)
  for _, path in ipairs(candidates) do
    if M.owned_path(path) and not owned[path] and vim.uv.fs_lstat(dir .. "/" .. path) then
      return nil,
        ("%s/%s is in the way and not listed in %s: refused (remove it by hand if it is no one's)"):format(
          out,
          path,
          export.MANIFEST
        )
    end
  end
  return { dir = dir, exists = true, owned = owned, manifest = true, leftovers = leftovers }
end

---@param path string
---@return boolean|nil ok
---@return string|nil err
local function mkdir(path)
  if vim.fn.isdirectory(path) == 1 then
    return true
  end
  if vim.fn.mkdir(path, "p") ~= 1 then
    return nil, "cannot create " .. path
  end
  return true
end

---@class Testing.Export.Folder.Result
---@field dir string
---@field written integer Files moved into place (changed or new).
---@field unchanged integer Files whose bytes were already there.
---@field removed integer Files of repositories no longer exported.
---@field warnings string[]
---@field bundle Testing.Export.Bundle

---Write the export folder: the documents of `testing.export.export`, the manifest last.
---@param out string
---@param opts Testing.Export.Opts
---@return Testing.Export.Folder.Result|nil result
---@return { code: integer, message: string }|nil err
function M.write(out, opts)
  local export = require("testing.export")
  local state, problem = M.inspect(out)
  if not state then
    return nil, { code = M.EXIT_USAGE, message = tostring(problem) }
  end
  local dir = state.dir
  -- fail closed: a leftover of an earlier write may hold the documents of a repository that is no longer released
  -- (and the folder is committed as it is); it goes before anything else happens
  local warnings, lerr = remove_leftovers(dir, out, state.leftovers or {})
  if not warnings then
    return nil, lerr
  end
  local o = vim.tbl_extend("force", {}, opts, {
    previous = function(path)
      if state.owned[path] or (path == export.MANIFEST and state.manifest) then
        return read(dir .. "/" .. path)
      end
      return nil
    end,
  })
  local bundle, berr = export.export(o)
  if not bundle then
    return nil, { code = M.EXIT_INFRA, message = tostring(berr) }
  end
  local files = vim.list_extend(vim.list_slice(bundle.files, 1), { bundle.manifest })
  local new = {}
  for _, f in ipairs(files) do
    new[f.path] = true
    -- a file in the way that the manifest does not own is someone else's: never replaced
    if
      not state.owned[f.path]
      and f.path ~= export.MANIFEST
      and vim.uv.fs_lstat(dir .. "/" .. f.path)
    then
      return nil,
        {
          code = M.EXIT_USAGE,
          message = ("%s/%s is in the way and not listed in %s: refused"):format(
            out,
            f.path,
            export.MANIFEST
          ),
        }
    end
  end

  local created = not state.exists
  local okm, merr = mkdir(dir)
  if not okm then
    return nil, { code = M.EXIT_INFRA, message = tostring(merr) }
  end
  local tmp = dir .. "/" .. M.TMP_PREFIX .. M.deps.id()
  -- a write of this process that waits meanwhile (`vim.wait`) never takes this one for a leftover
  active[tmp] = true
  local function fail(message, keep)
    active[tmp] = nil
    if not keep then
      vim.fn.delete(tmp, "rf")
      if created then
        vim.uv.fs_rmdir(dir) -- only when this write created it and it is empty again
      end
    end
    return nil, { code = M.EXIT_INFRA, message = message }
  end

  -- 1. every file into the temporary folder
  for _, f in ipairs(files) do
    local path = tmp .. "/new/" .. f.path
    local okd, derr = mkdir(vim.fs.dirname(path))
    local okw, werr = okd, derr
    if okd then
      okw, werr = M.deps.write(path, f.text)
    end
    if not okw then
      return fail(("cannot write %s: %s"):format(f.path, tostring(werr)))
    end
  end

  -- 2. file by file into place, the manifest last; what was replaced is kept until the manifest is in place
  local placed, unchanged = {}, 0
  local made_repos = vim.fn.isdirectory(dir .. "/repos") ~= 1
  local function rollback()
    local bad = {}
    for i = #placed, 1, -1 do
      local p = placed[i]
      if p.backup then
        local okr, rerr = M.deps.rename(p.backup, p.dest)
        if not okr then
          bad[#bad + 1] = ("%s: %s"):format(p.path, tostring(rerr))
        end
      else
        local oku, uerr = M.deps.unlink(p.dest)
        if not oku then
          bad[#bad + 1] = ("%s: %s"):format(p.path, tostring(uerr))
        end
      end
    end
    if made_repos then
      vim.uv.fs_rmdir(dir .. "/repos")
    end
    return bad
  end
  -- the files of repositories that are no longer exported (owned by the old manifest only), moved aside
  local stale = {}
  for _, path in ipairs(vim.tbl_keys(state.owned)) do
    local st = not new[path] and vim.uv.fs_lstat(dir .. "/" .. path)
    if st and st.type == "file" then
      stale[#stale + 1] = path
    end
  end
  table.sort(stale)
  for _, f in ipairs(files) do
    local dest = dir .. "/" .. f.path
    if f.path == export.MANIFEST then
      -- 2b. before the manifest: a stale file is moved into the temporary folder, so it never stays next to a manifest
      -- that no longer owns it (a private repository's data would be published and a later export refused); when
      -- one cannot be moved, everything is put back and the old manifest still owns it
      for _, path in ipairs(stale) do
        local from, backup = dir .. "/" .. path, tmp .. "/old/" .. path
        local okd, derr = mkdir(vim.fs.dirname(backup))
        if okd then
          okd, derr = M.deps.rename(from, backup)
        end
        if not okd then
          local bad = rollback()
          if #bad > 0 then
            return fail(
              ("cannot move %s aside (%s), and the folder could not be put back (%s): the old files are in %s"):format(
                path,
                tostring(derr),
                table.concat(bad, "; "),
                tmp .. "/old"
              ),
              true
            )
          end
          return fail(
            ("cannot move %s aside, it is no longer exported (%s): the folder is as it was"):format(
              path,
              tostring(derr)
            )
          )
        end
        placed[#placed + 1] = { path = path, dest = from, backup = backup, stale = true }
      end
    end
    if read(dest) == f.text then
      unchanged = unchanged + 1
    else
      local backup
      local okd, derr = mkdir(vim.fs.dirname(dest))
      if okd and vim.uv.fs_lstat(dest) then
        backup = tmp .. "/old/" .. f.path
        okd, derr = mkdir(vim.fs.dirname(backup))
        if okd then
          okd, derr = M.deps.rename(dest, backup)
          if not okd then
            backup = nil
          end
        end
      end
      if okd then
        okd, derr = M.deps.rename(tmp .. "/new/" .. f.path, dest)
        if not okd and backup then
          -- this one is put back before the others
          local okr = M.deps.rename(backup, dest)
          if not okr then
            placed[#placed + 1] = { path = f.path, dest = dest, backup = backup }
          end
        end
      end
      if not okd then
        local bad = rollback()
        if #bad > 0 then
          return fail(
            ("cannot move %s into place (%s), and the folder could not be put back (%s): the old files are in %s"):format(
              f.path,
              tostring(derr),
              table.concat(bad, "; "),
              tmp .. "/old"
            ),
            true
          )
        end
        return fail(
          ("cannot move %s into place (%s): the folder is as it was"):format(f.path, tostring(derr))
        )
      end
      placed[#placed + 1] = { path = f.path, dest = dest, backup = backup }
    end
  end

  -- 3. the temporary folder, with the replaced and the stale files in its old/
  active[tmp] = nil
  if M.deps.delete(tmp) ~= 0 then
    warnings[#warnings + 1] = ("%s could not be removed (it holds replaced files and those of repositories no longer exported): remove it by hand"):format(
      tmp
    )
  end
  return {
    dir = dir,
    written = #placed - #stale,
    unchanged = unchanged,
    removed = #stale,
    warnings = warnings,
    bundle = bundle,
  }
end

---The line that says what a write did.
---@param res Testing.Export.Folder.Result
---@return string
function M.summary(res)
  local fleet = res.bundle.docs["fleet.json"]
  local by = fleet.excluded_by or {}
  local function n(v)
    return type(v) == "number" and tostring(v) or "-"
  end
  return ("export: %d repositories to %s (%d written, %d unchanged, %d removed); left out %d (selection %s, private %s, unclassified %s)%s"):format(
    #fleet.repos,
    res.dir,
    res.written,
    res.unchanged,
    res.removed,
    fleet.excluded or 0,
    n(by.selection),
    n(by.private),
    n(by.unclassified),
    fleet.local_read == false and "; local results not read (workstation)" or ""
  )
end

---@class Testing.Export.Folder.Args
---@field out? string
---@field roots string[]
---@field repos_roots string[]
---@field include string[]
---@field exclude string[]
---@field remote boolean
---@field state_dir? string
---@field help boolean

local VALUED = {
  out = true,
  ["repos-root"] = true,
  include = true,
  exclude = true,
  ["state-dir"] = true,
}

---@param argv string[] The arguments after `export`.
---@return Testing.Export.Folder.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Export.Folder.Args
  local args =
    { roots = {}, repos_roots = {}, include = {}, exclude = {}, remote = false, help = false }
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    key = key or a:match("^%-%-([%w%-]+)$")
    if a == "-h" or key == "help" then
      args.help = true
    elseif key == "remote" and value == nil then
      args.remote = true
    elseif key and VALUED[key] then
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
      if key == "out" then
        args.out = value
      elseif key == "repos-root" then
        args.repos_roots[#args.repos_roots + 1] = value
      elseif key == "state-dir" then
        args.state_dir = value
      else
        for _, name in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
          if not require("testing.deps").is_valid_name(name) then
            return nil, ("--%s: %s is not a directory name"):format(key, name)
          end
          table.insert(args[key], name)
        end
      end
    elseif a:sub(1, 1) == "-" then
      return nil, ("unknown argument %s"):format(a)
    else
      args.roots[#args.roots + 1] = a
    end
    i = i + 1
  end
  if not args.help and not args.out then
    return nil, "--out <dir> is required"
  end
  return args
end

---`testing export ...`.
---@param argv string[] The arguments after `export`.
---@param sv { out: fun(s: string), err: fun(s: string), state_dir?: string }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing export: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local workstation, role_problem = M.workstation()
  if workstation == nil then
    sv.err("testing export: " .. tostring(role_problem))
    return M.EXIT_USAGE
  end
  for _, dir in ipairs(vim.list_extend(vim.list_slice(args.roots, 1), args.repos_roots)) do
    if vim.fn.isdirectory(dir) ~= 1 then
      sv.err(("testing export: %s is not a directory"):format(dir))
      return M.EXIT_USAGE
    end
  end
  local export = require("testing.export")
  ---@type Testing.Export.Opts
  local opts = {
    roots = args.roots,
    repos_roots = args.repos_roots,
    include = args.include,
    exclude = args.exclude,
    state_dir = args.state_dir and norm(args.state_dir) or sv.state_dir,
    remote = args.remote,
    no_local = workstation,
  }
  local dirs, info = export.resolve(opts)
  if not dirs or #dirs == 0 then
    sv.err("testing export: " .. (dirs and "no repository found" or tostring(info)))
    return M.EXIT_USAGE
  end
  ---@cast info { excluded: string[], missing: string[] }
  if #info.missing > 0 then
    sv.err(
      "testing export: included but not below any --repos-root: "
        .. table.concat(info.missing, ", ")
    )
  end
  local res, err = M.write(args.out, opts)
  if not res then
    ---@cast err { code: integer, message: string }
    sv.err("testing export: " .. err.message)
    return err.code
  end
  local classes = res.bundle.docs["fleet.json"].classes
  if type(classes) == "table" and type(classes.problem) == "string" then
    sv.err("testing export: note: " .. classes.problem)
  end
  for _, w in ipairs(res.warnings) do
    sv.err("testing export: warning: " .. w)
  end
  sv.out(M.summary(res))
  return M.EXIT_OK
end

return M
