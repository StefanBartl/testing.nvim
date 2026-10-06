---@module 'testing.migrate.apply'
---@brief Writes a migration plan to disk, after every check has passed.
---@description
--- `M.apply(plan, opts)` is the only function of the migration that writes. Rules:
---
---   * it does nothing unless `opts.apply == true` (a dry run is the default everywhere);
---   * it refuses a repository with uncommitted changes (tracked or untracked), and a directory whose
---     state git cannot report: a migration must be one reviewable commit;
---   * every operation is validated BEFORE the first byte is written: the path stays below the root
---     (also after resolving symlinks), no symlink is followed or replaced, a `create` target does not
---     exist, and a `modify` / `delete` target still has exactly the text the plan was made from;
---   * files are written atomically (`lib.nvim.fs.write.atomic`); scripts get mode 0755;
---   * the specs, `TESTS/harness.lua` and `TESTS/run.lua` are never in a plan, so they cannot be written.
---
--- It never raises; every failure ends in `errors` and, when it happened during validation, nothing was
--- written.

local text = require("testing.migrate.text")

local uv = vim.uv or vim.loop

local M = {}

---Is the working tree of `root` dirty? `nil, err` when that cannot be told.
---@param root string
---@return boolean|nil dirty
---@return string|nil err
---@return string[]|nil paths The changed paths (at most 10).
function M.git_dirty(root)
  local ok, git = pcall(require, "lib.nvim.git")
  if not ok then
    return nil, "lib.nvim.git is not available"
  end
  if not uv.fs_stat(root .. "/.git") then
    return nil, "not a git repository"
  end
  local map, err = git.status_porcelain({ dir = root })
  if not map then
    return nil, tostring(err)
  end
  local paths = vim.tbl_keys(map)
  table.sort(paths)
  return #paths > 0, nil, vim.list_slice(paths, 1, 10)
end

---Nearest existing ancestor of `path` (a directory), resolved.
---@param path string
---@return string|nil real
local function existing_ancestor_real(path)
  local dir = path
  while dir and dir ~= "" do
    local real = uv.fs_realpath(dir)
    if real then
      return (vim.fs.normalize(real):gsub("/+$", ""))
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

---Write the plan.
---@param plan Testing.Migrate.Plan
---@param opts? Testing.Migrate.ApplyOpts
---@return Testing.Migrate.ApplyResult
function M.apply(plan, opts)
  opts = opts or {}
  ---@type Testing.Migrate.ApplyResult
  local result = { applied = {}, deleted = {}, errors = {} }
  local function fail(msg)
    result.errors[#result.errors + 1] = msg
  end
  local ok, perr = pcall(function()
    if opts.apply ~= true then
      fail("dry run: nothing was written (pass apply = true to write the plan)")
      return
    end
    if type(plan) ~= "table" or type(plan.root) ~= "string" then
      fail("not a plan")
      return
    end
    if plan.error then
      fail("the plan has an error: " .. tostring(plan.error))
      return
    end
    if plan.skipped then
      fail("not a migration target: " .. tostring(plan.skipped))
      return
    end
    if plan.empty or #plan.ops == 0 then
      return
    end
    local root = plan.root

    -- 1. a clean working tree
    local dirty, derr, paths
    if opts.is_dirty then
      dirty, derr = opts.is_dirty(root)
    else
      dirty, derr, paths = M.git_dirty(root)
    end
    if dirty == nil then
      fail(
        ("cannot tell whether %s has uncommitted changes (%s): refusing"):format(
          text.show(root, 200),
          text.show(derr or "unknown", 200)
        )
      )
      return
    end
    if dirty then
      local shown = {}
      for _, p in ipairs(paths or {}) do
        shown[#shown + 1] = text.show(p, 120)
      end
      fail(
        "the repository has uncommitted changes: commit or stash them first"
          .. (#shown > 0 and (" (" .. table.concat(shown, ", ") .. ")") or "")
      )
      return
    end

    -- 2. validate every operation
    local root_real = existing_ancestor_real(root)
    if not root_real then
      fail("the root cannot be resolved")
      return
    end
    for _, op in ipairs(plan.ops) do
      local shown = text.show(op.path, 200)
      if not text.is_safe_rel(op.path) then
        fail(("%s: unsafe path"):format(shown))
      else
        local abs = root .. "/" .. op.path
        local st = uv.fs_lstat(abs)
        local parent_real = existing_ancestor_real(vim.fs.dirname(abs))
        if
          not parent_real
          or not (parent_real == root_real or vim.startswith(parent_real, root_real .. "/"))
        then
          fail(("%s: resolves outside the repository"):format(shown))
        elseif st and st.type == "link" then
          fail(("%s: is a symbolic link, not replaced"):format(shown))
        elseif op.action == "create" and st then
          fail(("%s: exists now, the plan was made for a repository without it"):format(shown))
        elseif op.action == "modify" or op.action == "delete" then
          local current = st and text.read(abs) or nil
          if current == nil then
            fail(("%s: cannot be read or is gone"):format(shown))
          elseif current ~= op.before then
            fail(("%s: changed since the plan was made: plan again"):format(shown))
          end
        elseif op.action ~= "delete" and type(op.after) ~= "string" then
          fail(("%s: the plan has no new text"):format(shown))
        end
      end
    end
    if #result.errors > 0 then
      return
    end

    -- 3. write
    local write = require("lib.nvim.fs.write.atomic")
    for _, op in ipairs(plan.ops) do
      local abs = root .. "/" .. op.path
      if op.action == "delete" then
        local removed, rerr = uv.fs_unlink(abs)
        if not removed then
          fail(("%s: %s"):format(text.show(op.path, 200), tostring(rerr)))
          return
        end
        result.deleted[#result.deleted + 1] = op.path
      else
        local written, werr = write(abs, op.after, { mkdirp = true })
        if not written then
          fail(("%s: %s"):format(text.show(op.path, 200), tostring(werr)))
          return
        end
        if op.exec then
          -- Best effort: a file system without modes keeps what it has.
          pcall(uv.fs_chmod, abs, tonumber("755", 8))
        end
        result.applied[#result.applied + 1] = op.path
      end
    end
  end)
  if not ok then
    fail("internal error: " .. tostring(perr))
  end
  return result
end

return M
