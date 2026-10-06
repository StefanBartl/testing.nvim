---@module 'testing.migrate.branches'
---@brief Does a dependency repository have a `ci-verified` branch? One `git ls-remote`, never fatal.
---@description
--- The CI checkout the migration writes names `ref: ci-verified` for every dependency. A repository
--- that has only `main` (color_my_ascii.nvim) would fail its first CI run on that ref, so the plan asks
--- first. The question is a seam (`Testing.Migrate.PlanOpts.branch_exists`): specs never touch the
--- network, the command line uses `M.exists`.
---
---   git ls-remote --exit-code --heads https://github.com/<owner>/<repo> ci-verified
---
--- Exit 0: the branch exists. Exit 2 (`--exit-code`: no matching ref): it does not. Anything else
--- (no network, no git, a private repository, a timeout) is "unknown": the caller keeps `ci-verified`
--- and says so in a note. An answer is cached per repository for the process.

local M = {}

---Milliseconds one `git ls-remote` may take.
---@type integer
M.TIMEOUT_MS = 15000

---@type table<string, { [1]: boolean|nil, [2]: string|nil }>
local cache = {}

---Ask GitHub. Needs `git` on PATH and network access.
---@param owner string
---@param repo string
---@param branch? string Default `ci-verified`.
---@return boolean|nil exists nil when the answer could not be obtained.
---@return string|nil err Why it could not.
function M.exists(owner, repo, branch)
  branch = branch or "ci-verified"
  local key = ("%s/%s#%s"):format(owner, repo, branch)
  local hit = cache[key]
  if hit then
    return hit[1], hit[2]
  end
  local argv = {
    "git",
    "ls-remote",
    "--exit-code",
    "--heads",
    ("https://github.com/%s/%s"):format(owner, repo),
    branch,
  }
  local ok, res = pcall(function()
    return vim
      .system(argv, { text = true, timeout = M.TIMEOUT_MS, env = { GIT_TERMINAL_PROMPT = "0" } })
      :wait(M.TIMEOUT_MS + 1000)
  end)
  local exists, err
  if not ok then
    err = tostring(res):match("^[^\n]*")
  elseif res.code == 0 then
    exists = true
  elseif res.code == 2 then
    exists = false
  else
    err = ("git ls-remote exited with %s: %s"):format(
      tostring(res.code),
      (res.stderr or ""):match("^[^\n]*") or ""
    )
  end
  cache[key] = { exists, err }
  return exists, err
end

---Forget every cached answer (specs).
function M.reset()
  cache = {}
end

return M
