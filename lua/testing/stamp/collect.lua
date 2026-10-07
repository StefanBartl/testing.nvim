---@module 'testing.stamp.collect'
-- @cache-allow env
---@brief What a stamp and a `verify` look at: the keys of the spec files, the environment facts, the git facts.
---@description
--- Nothing here runs a spec. The keys come from `testing.cache.key` through `testing.run.cached.key_inputs` (the
--- very function the run and `testing explain` use), so a stamp can never be about another key than the cache's.
--- git is called with argv lists only (`testing.affected.git`, no shell); nothing a stamp contains reaches git.

local M = {}

---@class Testing.Stamp.Current
---@field file string
---@field key? string
---@field uncacheable? string
---@field parts? string[] The key lines (in memory only, for the details of a changed file).
---@field kind? string Kind of the reason (`clock`, `process`, `nondeterministic`, ...).

---A reason as the stamp stores it: no control characters, the root replaced, short.
---@param text any
---@param root string
---@return string
function M.clean_reason(text, root)
  local s = tostring(text or "no key")
  if root ~= "" then
    s = s:gsub(vim.pesc(root), "<root>")
  end
  s = s:gsub("[%c\127]+", " ")
  s = vim.trim(s)
  if s == "" then
    s = "no key"
  end
  local max = require("testing.stamp").MAX_REASON
  if #s > max then
    s = s:sub(1, max - 3) .. "..."
  end
  return s
end

---The environment facts a stamp records beside the keys (so that a mismatch can be named, not only noticed).
---@param ctx Testing.Cache.Ctx
---@return Testing.Stamp.Env
function M.environment(ctx)
  local runner = (require("testing.cache").runner_version(ctx))
  if runner:sub(1, 11) == "unhashable:" then
    runner = "unhashable"
  end
  local v = vim.version()
  -- the API level is `api_info().version.api_level`; `api_info().api_level` does not exist (the stamp said `apinil`)
  local info = vim.fn.api_info()
  local level = type(info) == "table" and type(info.version) == "table" and info.version.api_level
    or nil
  local jit_os = (jit and jit.os) or "?"
  local jit_arch = (jit and jit.arch) or "?"
  return {
    runner = runner,
    nvim = ("%s|api%s"):format(tostring(v), level and tostring(level) or "?"),
    os = jit_os .. "/" .. jit_arch,
    config = tostring(ctx.config_digest or "none"),
  }
end

---The state of this process that a key reads besides the files: the runtime path, the environment and `package.path`.
---@class Testing.Stamp.Frozen
---@field rtp string[]
---@field environ table<string, string>
---@field package_path string

---Take that state now. A stamp compares the keys of before and after a run: the specs of an in-process run may
---change the runtime path or the environment of this editor (that is no input of theirs that changed), so the keys
---of after the run are computed with the state of before it, and only the files can make them differ.
---
---Reading the whole environment here is why the header says `-- @cache-allow env` (as in `testing.run.cached`): the
---copy is only handed on to the key, which adds the declared variables to it; without the directive every spec that
---loads the runner (through `testing.run.project`) would have no cache key at all.
---@return Testing.Stamp.Frozen
function M.freeze()
  local ok, rtp = pcall(vim.api.nvim_list_runtime_paths)
  return {
    rtp = ok and rtp or {},
    environ = vim.fn.environ(),
    package_path = package.path,
  }
end

---The key (or the reason there is none) of every spec file.
---@param plan Testing.Cli.RunPlan
---@param sv Testing.Run.Services
---@param run_opts Testing.Run.Options
---@param ordered Testing.Discover.File[]
---@param disc? { findings?: { path?: string }[] }
---@param frozen? Testing.Stamp.Frozen Compute with this state instead of the live one (`M.freeze`).
---@return Testing.Stamp.Current[] records Sorted by byte order of the file name.
---@return Testing.Stamp.Env env
function M.records(plan, sv, run_opts, ordered, disc, frozen)
  local cached = require("testing.run.cached")
  local cache = sv.cache or require("testing.cache")
  local inputs = cached.key_inputs(plan, run_opts, {
    mode = "use",
    cache_dir = sv.cache_dir,
    seed = plan.args.seed,
    environ = frozen and frozen.environ or nil,
  })
  if frozen then
    inputs.ctx.dep_roots = frozen.rtp
    inputs.ctx.environ = function()
      return frozen.environ
    end
  end
  local keylog = require("testing.cache.keylog").load(plan.root, { state_dir = sv.state_dir })
  -- a key that gave different results is no proof of anything (`testing.cache.keylog`)
  inputs.ctx.flipped = function(file, key)
    return keylog:flipped(file, key)
  end
  local with_finding = {}
  for _, f in ipairs((disc and disc.findings) or {}) do
    if f.path then
      with_finding[f.path] = true
    end
  end
  local records = {}
  local function compute()
    for _, f in ipairs(ordered) do
      if with_finding[f.rel] then
        records[#records + 1] = {
          file = f.rel,
          uncacheable = "the discovery has a finding for this file",
          kind = "discovery",
        }
      else
        local key, why, parts, detail = cache.key(inputs.info_of(f), inputs.ctx)
        if key then
          records[#records + 1] = { file = f.rel, key = key, parts = parts }
        else
          records[#records + 1] = {
            file = f.rel,
            uncacheable = M.clean_reason(why, plan.root),
            kind = detail and detail.kind or nil,
          }
        end
      end
    end
  end
  -- a module that is on no runtime path is looked up on `package.path` too
  local live_path = package.path
  if frozen then
    package.path = frozen.package_path
  end
  local ok, err = pcall(compute)
  package.path = live_path
  if not ok then
    error(err, 0)
  end
  require("testing.stamp").sort_records(records)
  return records, M.environment(inputs.ctx)
end

---@class Testing.Stamp.GitFacts
---@field git boolean A git checkout that answered.
---@field commit? string
---@field tree? string Tree of the project directory at HEAD.
---@field dirty? boolean Uncommitted changes below the project directory (untracked files count).
---@field changes? string[] The first changed paths.
---@field changed_count? integer

---@param s any
---@return string|nil
local function object_id(s)
  s = vim.trim(tostring(s or ""))
  if (#s == 40 or #s == 64) and s:match("^[0-9a-f]+$") then
    return s
  end
  return nil
end

---The git facts of the working tree. `run` is the git runner (default: the real git, three commands at once).
---`.deps/` (the checkouts of the dependencies below the project directory, as CI makes them) is not a change of
---the project: its content is part of the key of every spec that reaches it, so a changed dependency is `changed`,
---never lost, and a `.deps/` that is not ignored would otherwise make every tree `dirty`.
---@param root string
---@param run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@return Testing.Stamp.GitFacts
function M.git_facts(root, run)
  local git = require("testing.affected.git")
  local argvs = {
    { "git", "rev-parse", "HEAD" },
    { "git", "rev-parse", "HEAD:./" },
    {
      "git",
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=normal",
      "--",
      ".",
      ":(exclude).deps",
    },
  }
  local answers
  if run then
    answers = {}
    for i, argv in ipairs(argvs) do
      answers[i] = run(argv, root)
    end
  else
    answers = git.run_parallel(argvs, root)
  end
  local status = answers[3]
  if status.code ~= 0 then
    return { git = false }
  end
  local facts = { git = true }
  if answers[1].code == 0 then
    facts.commit = object_id(answers[1].stdout)
  end
  if answers[2].code == 0 then
    facts.tree = object_id(answers[2].stdout)
  end
  local changes = {}
  for entry in status.stdout:gmatch("[^%z]+") do
    if #entry > 3 then
      changes[#changes + 1] = entry:sub(4)
    end
  end
  facts.dirty = #changes > 0
  facts.changed_count = #changes
  facts.changes = vim.list_slice(changes, 1, 5)
  return facts
end

---Attach the stamp file to the tree object as a git note under `refs/notes/testing`. A tree is content-addressed:
---the same tree under another commit (a rebase, a squash, a revert to an earlier state) finds the same note.
---The note holds the whole stamp. Pushing and fetching `refs/notes/testing` is the job of the caller.
---@param root string
---@param tree string Tree id (validated here).
---@param file string The stamp file to attach.
---@param run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@return boolean ok
---@return string|nil err
function M.note_write(root, tree, file, run)
  local git = require("testing.affected.git")
  if not (object_id(tree) and git.valid_ref(tree)) then
    return false, "no tree to attach the note to (not a git checkout, or no commit yet)"
  end
  local r = (run or git.default_run)(
    -- a note is a commit: without a configured identity (a CI checkout) git refuses, so name one
    {
      "git",
      "-c",
      "user.name=testing.nvim",
      "-c",
      "user.email=testing@localhost",
      "notes",
      "--ref=testing",
      "add",
      "-f",
      "-F",
      file,
      tree,
    },
    root
  )
  if r.code ~= 0 then
    return false, "git notes failed: " .. vim.trim(r.stderr)
  end
  return true, nil
end

---Read the stamp note of a tree.
---@param root string
---@param tree string
---@param run? fun(argv: string[], cwd: string): Testing.Affected.GitResult
---@return string|nil text
---@return string|nil err
function M.note_read(root, tree, run)
  local git = require("testing.affected.git")
  if not (object_id(tree) and git.valid_ref(tree)) then
    return nil, "no tree to look a note up for (not a git checkout, or no commit yet)"
  end
  local r = (run or git.default_run)({ "git", "notes", "--ref=testing", "show", tree }, root)
  if r.code ~= 0 then
    return nil, "no stamp note on this tree (refs/notes/testing)"
  end
  return r.stdout, nil
end

return M
