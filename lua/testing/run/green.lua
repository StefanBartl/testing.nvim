---@module 'testing.run.green'
---@brief The last full green run of a project, and what changed since: the second line of a red verdict.
---@description
--- After a `green` run (the one that prints the sentinel) the driver remembers when it was and, when the
--- project is a git checkout, its commit plus the content hash of the files that were already modified
--- at that moment. A red run asks `changed_since`: git lists what differs from that commit (working
--- tree and untracked files), and a file that was modified at the green run and has the very same
--- content now is not a change since. The answer is a hint for whoever has to find the cause of a red
--- run, never part of the verdict.
---
--- The file `last_green.json` lives beside `runs.jsonl` (`stdpath('state')/testing/<project>/`). It is
--- untrusted when read back (size cap, decode under `pcall`, every field validated; the commit goes to
--- git as an argv entry only after `valid_ref`), bounded, and written atomically. A failing read or write
--- is a note for the caller, never an error.

local M = {}

---@type integer
M.VERSION = 1
---@type integer
M.MAX_BYTES = 262144
---Most already-modified files whose hash is remembered.
---@type integer
M.MAX_DIRTY = 200
---A file larger than this is not hashed (it counts as changed whenever git lists it).
---@type integer
M.MAX_HASH_BYTES = 1048576

---@class Testing.Green.Record
---@field v integer
---@field ts integer
---@field run string
---@field sha? string Abbreviated commit of the run.
---@field dirty table<string, string> Files modified at that moment: path -> sha256 of the content.

---@param root string
---@param opts? { state_dir?: string }
---@return string
function M.path(root, opts)
  return require("testing.history").dir(root, opts) .. "/last_green.json"
end

---@param s any
---@return boolean
local function plain_text(s, max)
  return type(s) == "string" and s ~= "" and #s <= max and not s:find("[%c\127]")
end

---@param raw any
---@return Testing.Green.Record|nil
---@return string|nil why
function M.validate(raw)
  if type(raw) ~= "table" or raw.v ~= M.VERSION then
    return nil, "unknown version"
  end
  if type(raw.ts) ~= "number" or raw.ts ~= raw.ts or raw.ts < 0 or raw.ts > 4102444800 then
    return nil, "bad timestamp"
  end
  if not plain_text(raw.run, 100) then
    return nil, "bad run id"
  end
  local sha = raw.sha
  if sha ~= nil then
    local git = require("testing.affected.git")
    if type(sha) ~= "string" or not sha:match("^%x+$") or #sha < 4 or #sha > 64 then
      return nil, "bad commit"
    end
    if not git.valid_ref(sha) then
      return nil, "bad commit"
    end
  end
  local dirty, n = {}, 0
  if raw.dirty ~= nil then
    if type(raw.dirty) ~= "table" then
      return nil, "bad dirty map"
    end
    for path, hash in pairs(raw.dirty) do
      n = n + 1
      if n > M.MAX_DIRTY or not plain_text(path, 300) then
        return nil, "bad dirty map"
      end
      if type(hash) ~= "string" or not hash:match("^%x+$") or #hash ~= 64 then
        return nil, "bad dirty map"
      end
      dirty[path] = hash
    end
  end
  return { v = M.VERSION, ts = raw.ts, run = raw.run, sha = sha, dirty = dirty }, nil
end

---@param root string
---@param opts? { state_dir?: string }
---@return Testing.Green.Record|nil record
---@return string|nil note Why an existing file was not used.
function M.load(root, opts)
  local path = M.path(root, opts)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return nil, nil
  end
  if stat.type ~= "file" or stat.size > M.MAX_BYTES then
    return nil, ("last green record %s is not a regular file or too large: ignored"):format(path)
  end
  local text = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, ("last green record %s cannot be read: ignored"):format(path)
  end
  local ok, decoded = pcall(require("lib.nvim.json").decode, text)
  if not ok then
    return nil, ("last green record %s is not valid JSON: ignored"):format(path)
  end
  local rec, why = M.validate(decoded)
  if not rec then
    return nil, ("last green record %s is not usable (%s): ignored"):format(path, tostring(why))
  end
  return rec, nil
end

---sha256 of a file below the root; nil when it cannot be read or is too large.
---@param root string
---@param rel string
---@return string|nil
local function hash_of(root, rel)
  local stat = vim.uv.fs_stat(root .. "/" .. rel)
  if not stat or stat.type ~= "file" or stat.size > M.MAX_HASH_BYTES then
    return nil
  end
  local text = require("lib.nvim.fs.read")(root .. "/" .. rel)
  if not text then
    return nil
  end
  return vim.fn.sha256(text)
end

---Facts about the working tree at the moment of a green run (the IR header carries the commit and the
---dirty flag; the list of modified files costs one `git` call and is only asked for when the tree is dirty).
---@param root string
---@param res Testing.Result
---@param opts? { run?: fun(argv: string[], cwd: string): Testing.Affected.GitResult }
---@return string|nil sha
---@return table<string, string> dirty
local function working_tree(root, res, opts)
  local git = res.run and res.run.git
  if type(git) ~= "table" or type(git.sha) ~= "string" then
    return nil, {}
  end
  local dirty = {}
  if git.dirty == true then
    local files = require("testing.affected.git").changed(
      root,
      { mode = "since", since = git.sha, run = opts and opts.run }
    )
    if files then
      for i, rel in ipairs(files) do
        if i > M.MAX_DIRTY then
          break
        end
        local h = hash_of(root, rel)
        if h then
          dirty[rel] = h
        end
      end
    end
  end
  return git.sha, dirty
end

---Remember a full green run.
---@param root string
---@param res Testing.Result
---@param opts? { state_dir?: string, time?: integer, run?: fun(argv: string[], cwd: string): Testing.Affected.GitResult }
---@return boolean ok
---@return string|nil err
function M.record(root, res, opts)
  opts = opts or {}
  local sha, dirty = working_tree(root, res, opts)
  local rec = {
    v = M.VERSION,
    ts = opts.time or os.time(),
    run = res.run.id,
    sha = sha,
    dirty = dirty,
  }
  local text, err = require("lib.nvim.json").encode(rec)
  if not text then
    return false, "cannot encode the last green record: " .. tostring(err)
  end
  local ok, werr =
    require("lib.nvim.fs.write.atomic")(M.path(root, opts), text .. "\n", { mkdirp = true })
  if not ok then
    return false, ("cannot write the last green record: %s"):format(tostring(werr))
  end
  return true, nil
end

---What differs from the last green run: git's list against its commit, minus the files that were
---already modified then and have the same content now.
---@param root string
---@param rec Testing.Green.Record
---@param opts? { run?: fun(argv: string[], cwd: string): Testing.Affected.GitResult }
---@return string[]|nil files Sorted; nil when git cannot say.
---@return string|nil note
function M.changed_since(root, rec, opts)
  if not rec.sha then
    return nil, "the last green run has no commit (not a git checkout)"
  end
  local files, err = require("testing.affected.git").changed(
    root,
    { mode = "since", since = rec.sha, run = opts and opts.run }
  )
  if not files then
    return nil, tostring(err)
  end
  local out = {}
  for _, rel in ipairs(files) do
    local was = rec.dirty[rel]
    if not (was and hash_of(root, rel) == was) then
      out[#out + 1] = rel
    end
  end
  return out, nil
end

return M
