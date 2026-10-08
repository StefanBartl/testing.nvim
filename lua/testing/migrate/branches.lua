---@module 'testing.migrate.branches'
---@brief Does a dependency repository have a `ci-verified` branch? One `git ls-remote`, never fatal.
---@description
--- The CI checkout the migration writes names `ref: ci-verified` for every dependency. A repository
--- that has only `main` (color_my_ascii.nvim) would fail its first CI run on that ref, so the plan asks
--- first. The question is a seam (`Testing.Migrate.PlanOpts.branch_exists`): specs never touch the
--- network, the command line uses `M.exists`.
---
---   git ls-remote --exit-code --heads https://github.com/<owner>/<repo> refs/heads/ci-verified
---
--- The ref is spelled out: git matches a short pattern against the end of every ref name, so `ci-verified` alone
--- would also find `release/ci-verified`.
---
--- Exit 0: the branch exists. Exit 2 (`--exit-code`: no matching ref): it does not. Anything else
--- (no network, no git, a private repository, a timeout) is "unknown": the caller keeps `ci-verified`
--- and says so in a note. An answer is cached per repository for the process. The editor waits for each
--- question (`:Testing migrate` asks once per dependency, one after the other), so after the first TIMEOUT
--- the others are not asked at all: a network that drops packets would otherwise cost the full timeout per
--- dependency.

local M = {}

---Milliseconds one `git ls-remote` may take.
---@type integer
M.TIMEOUT_MS = 15000

---@type table<string, { [1]: boolean|nil, [2]: string|nil }>
local cache = {}

---Set by the first question that ran into the timeout: why nothing is asked any more.
---@type string|nil
local gave_up

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
  if gave_up then
    return nil, gave_up
  end
  -- a short pattern is matched against the END of a ref name: `ci-verified` finds `release/ci-verified`, too
  local ref = branch:find("^refs/") and branch or ("refs/heads/" .. branch)
  local argv = {
    "git",
    "ls-remote",
    "--exit-code",
    "--heads",
    ("https://github.com/%s/%s"):format(owner, repo),
    ref,
  }
  local ok, res = pcall(function()
    return vim
      .system(argv, { text = true, timeout = M.TIMEOUT_MS, env = { GIT_TERMINAL_PROMPT = "0" } })
      :wait(M.TIMEOUT_MS + 1000)
  end)
  local exists, err
  if not ok then
    err = tostring(res):match("^[^\n]*")
  elseif type(res) ~= "table" or res.code == 124 then
    -- no answer in time (nil: the process was killed and a child of it held its pipes open; 124: the code
    -- Neovim gives a command it had to kill)
    err = ("git ls-remote did not answer within %d ms"):format(M.TIMEOUT_MS)
    gave_up = ("%s; not asking again in this run"):format(err)
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
  gave_up = nil
end

return M
