---@module 'testing.ci.hook'
---@brief `testing ci hook install|remove`: a `pre-push` hook that asks `testing ci verify` first and runs a profile only when needed.
---@description
--- ```
--- testing ci hook install [--run=<profile>] [--verify=<profile>] [--root=<dir>]
--- testing ci hook remove [--root=<dir>]
--- ```
---
--- The hook (`<git hooks dir>/pre-push`, wherever git keeps it: a worktree, `core.hooksPath`) does two things and
--- computes no verdict of its own:
---
---   1. `testing ci verify [--profile=<verify>]`: a state that is already proven ends the hook with exit 0
---      (a tenth of a second, no step runs);
---   2. otherwise `testing ci --profile=<run> --reuse` (default `fast`): its exit code is the hook's, so a red
---      pipeline blocks the push. `git push --no-verify` skips the hook.
---
--- It finds testing.nvim without any Neovim configuration: `$TESTING_NVIM_DIR`, `<repo>/.deps/testing.nvim`,
--- `<repo>/../testing.nvim`, then the checkout the install ran from. A hook that is not ours is never overwritten
--- or removed; the hook of `:MyPlugins ci hook` (mark `# MyPlugins ci pre-push hook`) is recognised and replaced.

local M = {}

M.EXIT_OK, M.EXIT_REFUSED, M.EXIT_USAGE, M.EXIT_INFRA = 0, 1, 2, 3

---First line (after the shebang) of the hook we write; `remove` only deletes a file that carries it.
M.MARK = "# testing ci pre-push hook"
---The mark of the hook this one replaces (nvim-config, `:MyPlugins ci hook install`).
M.LEGACY_MARK = "# MyPlugins ci pre-push hook"

M.DEFAULT_RUN = "fast"

M.USAGE = table.concat({
  "usage: testing ci hook install [--run=<profile>] [--verify=<profile>] [--root=<dir>]",
  "       testing ci hook remove [--root=<dir>]",
  "  --run=<profile>     the profile the hook runs when the state is not proven (default: fast)",
  "  --verify=<profile>  the profile whose proof is asked first (default: ci.default)",
  "  --root=<dir>        the repository (default: the current directory)",
  "  `git push --no-verify` skips the hook. A pre-push hook that is not ours is never touched.",
}, "\n")

---The checkout this module was loaded from (its `scripts/testing.lua` is the driver the hook falls back to).
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  return vim.fs.normalize(vim.fn.fnamemodify(src, ":p:h:h:h:h"))
end

---A word for a shell script: only the characters a profile name or a path may have, so no quoting is needed.
---@param s string
---@return boolean
local function safe_word(s)
  return s:match("^[%w%._%-/:]+$") ~= nil and s:find("..", 1, true) == nil
end

---Text of the hook. No backslashes: it runs in Git Bash and in Linux sh alike.
---@param o { run: string, verify?: string, driver_dir: string }
---@return string
function M.text(o)
  local verify = o.verify and (" --profile=" .. o.verify) or ""
  return table.concat({
    "#!/bin/sh",
    M.MARK .. " (git push --no-verify skips it)",
    'root="$(git rev-parse --show-toplevel)" || exit 1',
    'driver=""',
    ('for dir in "${TESTING_NVIM_DIR:-}" "$root/.deps/testing.nvim" "$root/../testing.nvim" "%s"; do'):format(
      o.driver_dir
    ),
    '  if [ -n "$dir" ] && [ -f "$dir/scripts/testing.lua" ]; then driver="$dir/scripts/testing.lua"; break; fi',
    "done",
    'if [ -z "$driver" ]; then',
    "  echo 'pre-push: testing.nvim was not found ($TESTING_NVIM_DIR, .deps/testing.nvim, ../testing.nvim): not checking' >&2",
    "  exit 1",
    "fi",
    'cd "$root" || exit 1',
    "# git hands a hook the variables of the operation in progress; a spec that runs git must not inherit them",
    "unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY",
    "unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE",
    "unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE",
    'testing_ci() { nvim -n -i NONE --headless -u NONE -l "$driver" ci "$@"; }',
    ("testing_ci verify%s && exit 0"):format(verify),
    'echo "pre-push: not proven, running testing ci --profile=' .. o.run .. '"',
    ('testing_ci --profile=%s --reuse || { echo "pre-push: testing ci is red, push blocked (git push --no-verify skips it)" >&2; exit 1; }'):format(
      o.run
    ),
    "",
  }, "\n")
end

---Hook folder of a checkout, as git sees it (a worktree's `.git` is a file, `core.hooksPath` may move it).
---@param dir string
---@return string|nil
function M.hooks_dir(dir)
  local ok, obj = pcall(
    vim.system,
    { "git", "-C", dir, "rev-parse", "--git-path", "hooks" },
    { text = true }
  )
  local res = ok and obj:wait(10000) or nil
  local out = res and vim.trim(res.stdout or "") or ""
  if not res or res.code ~= 0 or out == "" then
    return nil
  end
  if out:match("^%a:[/\\]") or out:sub(1, 1) == "/" then
    return out
  end
  return dir .. "/" .. out
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---Does a hook carry the mark as its second line (right after the shebang)? A foreign hook that merely mentions it does not.
---@param text string|nil
---@param mark string
---@return boolean
function M.marked(text, mark)
  if not text then
    return false
  end
  local second = text:match("^[^\n]*\n([^\n]*)")
  return second ~= nil and second:sub(1, #mark) == mark
end

---@class Testing.Ci.Hook.Args
---@field action "install"|"remove"|nil
---@field run string
---@field verify? string
---@field root string
---@field help boolean

---@param argv string[] The arguments after `hook`.
---@return Testing.Ci.Hook.Args|nil args
---@return string|nil problem
function M.parse(argv)
  ---@type Testing.Ci.Hook.Args
  local args = { run = M.DEFAULT_RUN, root = ".", help = false }
  for i, a in ipairs(argv) do
    local key, value = a:match("^%-%-([%w%-]+)=(.*)$")
    if a == "-h" or a == "--help" then
      args.help = true
    elseif i == 1 and (a == "install" or a == "remove") then
      args.action = a
    elseif key == "run" or key == "verify" or key == "root" then
      if value == "" then
        return nil, ("--%s needs a value"):format(key)
      end
      if key ~= "root" and not safe_word(value) then
        return nil, ("--%s: '%s' is not a profile name"):format(key, value)
      end
      args[key] = value
    else
      return nil, ("unknown argument %s"):format(a)
    end
  end
  if not args.action and not args.help then
    return nil, "say install or remove"
  end
  return args
end

---@param argv string[] The arguments after `hook`.
---@param sv { out: fun(s: string), err: fun(s: string) }
---@return integer exit_code
function M.main(argv, sv)
  local args, problem = M.parse(argv)
  if not args then
    sv.err("testing ci hook: " .. tostring(problem))
    sv.err(M.USAGE)
    return M.EXIT_USAGE
  end
  if args.help then
    sv.out(M.USAGE)
    return M.EXIT_OK
  end
  local root = vim.fs.normalize(vim.fn.fnamemodify(args.root, ":p")):gsub("/$", "")
  local hooks = vim.fn.isdirectory(root) == 1 and M.hooks_dir(root) or nil
  if not hooks then
    sv.err(("testing ci hook: %s is not a git checkout"):format(root))
    return M.EXIT_USAGE
  end
  local path = hooks .. "/pre-push"
  local existing = read(path)
  local ours = M.marked(existing, M.MARK)
  local legacy = M.marked(existing, M.LEGACY_MARK)

  if args.action == "remove" then
    if not existing then
      sv.out("testing ci hook: no pre-push hook")
      return M.EXIT_OK
    elseif not (ours or legacy) then
      sv.err("testing ci hook: the pre-push hook is not ours, left alone")
      return M.EXIT_REFUSED
    end
    local removed, why = os.remove(path)
    if not removed then
      sv.err(("testing ci hook: cannot remove %s: %s"):format(path, tostring(why)))
      return M.EXIT_INFRA
    end
    sv.out("testing ci hook: pre-push hook removed")
    return M.EXIT_OK
  end

  if existing and not (ours or legacy) then
    sv.err("testing ci hook: a pre-push hook that is not ours exists, left alone")
    return M.EXIT_REFUSED
  end
  -- the profiles must exist, or the first push would fail with a usage error
  local pipeline, problems = require("testing.ci.schema").load(root)
  if not pipeline then
    sv.err("testing ci hook: " .. table.concat(problems or {}, "; "))
    return M.EXIT_USAGE
  end
  for _, name in ipairs({ args.run, args.verify or pipeline.default }) do
    if not pipeline.profiles[name] then
      sv.err(("testing ci hook: unknown profile %s"):format(name))
      return M.EXIT_USAGE
    end
  end
  local driver_dir = plugin_root()
  if not safe_word(driver_dir) then
    sv.err(
      ("testing ci hook: the path %s has characters a hook script cannot take"):format(driver_dir)
    )
    return M.EXIT_USAGE
  end
  local atomic = require("lib.nvim.fs.write.atomic")
  local ok, err = atomic(
    path,
    M.text({ run = args.run, verify = args.verify, driver_dir = driver_dir }),
    { mkdirp = true }
  )
  if not ok then
    sv.err(("testing ci hook: cannot write %s: %s"):format(path, tostring(err)))
    return M.EXIT_INFRA
  end
  local chmod_ok, chmod_err = vim.uv.fs_chmod(path, tonumber("755", 8))
  if not chmod_ok then
    sv.err(("testing ci hook: cannot make %s executable: %s"):format(path, tostring(chmod_err)))
    return M.EXIT_INFRA
  end
  sv.out(
    ("testing ci hook: pre-push hook installed%s (git push --no-verify skips it)"):format(
      legacy and ", replacing the one of :MyPlugins ci" or ""
    )
  )
  return M.EXIT_OK
end

M._plugin_root = plugin_root

return M
