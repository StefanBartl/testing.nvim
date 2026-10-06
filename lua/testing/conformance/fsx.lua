---@module 'testing.conformance.fsx'
---@brief Read-only access to the checked repository: literal paths, bounded reads, no glob (XP-01).
---@description
--- Every static check reads the repository through this object, so the safety rules live in one place:
---
---   * a path is RELATIVE to the root, with no `..`, no NUL and no drive or leading slash: a check can
---     only ask for files below the root (SEC-42);
---   * a symbolic link that leads out of the root is treated as absent (ERR-34: never walk out of the
---     tree the user pointed at);
---   * directories are listed literally (`vim.fs.dir` of a built path), never matched with
---     `vim.fn.glob`/`globpath`, which read the root itself as a pattern (XP-01);
---   * a file is read at most `M.MAX_BYTES` (SEC-32): a hostile repository cannot make the suite read a
---     multi-gigabyte `README.md`;
---   * nothing here writes (SEC-47): the checked repository is never modified.

local M = {}

---Largest file a check reads, in bytes.
M.MAX_BYTES = 2 * 1024 * 1024

---Longest line a check sees, in bytes. A line longer than that is cut (and counted: `Fs.cut`): Lua patterns
---with two adjacent `%s*` or a `[^%]]*` are quadratic on a line of a million characters, and a hostile
---repository must not be able to make `testing conformance` (and the CI around it) run for hours (SEC-30).
M.MAX_LINE = 2000

---Largest file `ctx.sources` takes (a Lua file of that size is generated or vendored, not the plugin's code).
M.MAX_SOURCE_BYTES = 512 * 1024

---Most bytes all sources of one run hold together (memory is bounded, not only each file).
M.MAX_SOURCES_TOTAL = 64 * 1024 * 1024

---Most entries a walk returns.
M.MAX_FILES = 5000

---Deepest directory a walk enters.
M.MAX_DEPTH = 12

---Directory names a walk does not enter: version control, tool state and copies of the repository's own
---code (`.claude/worktrees`, `.deps`).
---@type table<string, boolean>
M.DEFAULT_SKIP = { [".git"] = true, [".claude"] = true, [".deps"] = true, ["node_modules"] = true }

local uv = vim.uv or vim.loop

---@param p string
---@return string
local function norm(p)
  return (vim.fs.normalize(p):gsub("/+$", ""))
end

---Is `rel` a safe relative path (below the root, no traversal)?
---@param rel any
---@return boolean ok
---@return string|nil why
function M.check_rel(rel)
  if type(rel) ~= "string" or rel == "" then
    return false, "path must be a non-empty string"
  end
  if rel:find("\0", 1, true) then
    return false, "path contains a NUL byte"
  end
  local p = rel:gsub("\\", "/")
  if p:sub(1, 1) == "/" or p:match("^%a:") then
    return false, "path is absolute"
  end
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      return false, "path leaves the repository"
    end
  end
  return true
end

---@class Testing.Conformance.FsImpl : Testing.Conformance.Fs
---@field _real? string Resolved root, for the containment test.
---@field cut integer Lines that were longer than `M.MAX_LINE` and were cut.
local Fs = {}
Fs.__index = Fs

---@param root string Absolute path of the repository.
---@return Testing.Conformance.Fs
function M.new(root)
  local self = setmetatable({ root = norm(root), cut = 0 }, Fs)
  self._real = uv.fs_realpath(self.root)
  return self
end

---Split text into lines (no terminators), every line at most `M.MAX_LINE` bytes.
---@param text string
---@return string[] lines
---@return integer cut How many lines were cut.
function M.cap_lines(text)
  if text == "" then
    return {}, 0
  end
  local lines = vim.split((text:gsub("\r\n", "\n")), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  local cut = 0
  for i, line in ipairs(lines) do
    if #line > M.MAX_LINE then
      lines[i] = line:sub(1, M.MAX_LINE)
      cut = cut + 1
    end
  end
  return lines, cut
end

---Is `abs` (an existing path) inside the root once EVERY component is resolved? A symbolic link or a junction
---on an intermediate directory (`docs` -> outside) leads out as well as one on the last component.
---@param abs string
---@return boolean
function Fs:_contained(abs)
  local real = uv.fs_realpath(abs)
  if not real or not self._real then
    return false
  end
  return require("lib.nvim.fs.is_subpath")(real, self._real, {})
end

---Absolute path of `rel` below the root.
---@param rel string
---@return string|nil abs
---@return string|nil why
function Fs:abs(rel)
  local ok, why = M.check_rel(rel)
  if not ok then
    return nil, why
  end
  return self.root .. "/" .. (rel:gsub("\\", "/"):gsub("^/+", ""))
end

---`fs_stat` of `rel`, or nil when it does not exist, is unsafe or leads out of the root.
---@param rel string
---@return table|nil
function Fs:stat(rel)
  local abs = self:abs(rel)
  if not abs then
    return nil
  end
  local lst = uv.fs_lstat(abs)
  if not lst then
    return nil
  end
  -- not only a link on the last component: `lstat` follows a link on an intermediate directory and reports a
  -- plain file, so the resolved path decides (one `realpath` per call, memoized by the callers' own caches)
  if not self:_contained(abs) then
    return nil
  end
  return uv.fs_stat(abs)
end

---@param rel string
---@return boolean
function Fs:exists(rel)
  return self:stat(rel) ~= nil
end

---@param rel string
---@return boolean
function Fs:is_file(rel)
  local st = self:stat(rel)
  return st ~= nil and st.type == "file"
end

---@param rel string
---@return boolean
function Fs:is_dir(rel)
  local st = self:stat(rel)
  return st ~= nil and st.type == "directory"
end

---Read a file (bounded).
---@param rel string
---@return string|nil text
---@return string|nil err
function Fs:read(rel)
  local st = self:stat(rel)
  if not st then
    return nil, "not found"
  end
  if st.type ~= "file" then
    return nil, "not a regular file"
  end
  if st.size > M.MAX_BYTES then
    return nil, ("larger than %d bytes"):format(M.MAX_BYTES)
  end
  local abs = self:abs(rel)
  local text, err = require("lib.nvim.fs.read")(abs --[[@as string]])
  if not text then
    return nil, tostring(err)
  end
  return text
end

---The lines of a file (`\n`, `\r\n`; no terminators).
---@param rel string
---@return string[]|nil lines
---@return string|nil err
function Fs:lines(rel)
  local text, err = self:read(rel)
  if not text then
    return nil, err
  end
  local lines, cut = M.cap_lines(text)
  self.cut = self.cut + cut
  return lines
end

---The entries of a directory (sorted by name; symbolic links are listed with type `link`).
---@param rel string
---@return { name: string, type: string }[]
function Fs:list(rel)
  local out = {}
  if not self:is_dir(rel) then
    return out
  end
  local abs = self:abs(rel)
  local ok, iter = pcall(vim.fs.dir, abs)
  if not ok then
    return out
  end
  for name, kind in iter do
    out[#out + 1] = { name = name, type = kind }
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out
end

---All files below `rel` (relative to the root, forward slashes, sorted). Symbolic links are not
---followed, directories in `opts.skip` are not entered.
---@param rel string
---@param opts? Testing.Conformance.WalkOpts
---@return string[]
function Fs:walk(rel, opts)
  opts = opts or {}
  local skip = opts.skip or M.DEFAULT_SKIP
  local limit = opts.limit or M.MAX_FILES
  local ext = opts.ext and ("." .. opts.ext .. "$") or nil
  local out = {}
  if not self:is_dir(rel) then
    return out
  end
  local base = (rel:gsub("\\", "/"):gsub("/+$", ""))
  local stack = { { base, 0 } }
  while #stack > 0 and #out < limit do
    local item = table.remove(stack)
    local dir, depth = item[1], item[2]
    local subdirs = {}
    for _, e in ipairs(self:list(dir)) do
      local path = dir .. "/" .. e.name
      if e.type == "directory" then
        if not skip[e.name] and depth < M.MAX_DEPTH then
          subdirs[#subdirs + 1] = path
        end
      elseif e.type == "file" then
        if not ext or e.name:find(ext) then
          out[#out + 1] = path
        end
      end
    end
    for i = #subdirs, 1, -1 do
      stack[#stack + 1] = { subdirs[i], depth + 1 }
    end
  end
  table.sort(out)
  if #out > limit then
    return vim.list_slice(out, 1, limit)
  end
  return out
end

return M
