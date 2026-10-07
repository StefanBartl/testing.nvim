-- TESTS/testing/hooks_spec.lua -- the hook recipes (`:Testing init --hooks`, docs/HOOKS.md): written once and never
-- over a file that exists, free of verdict logic of their own, and (where bash is available) they do what the
-- recipe says on a real checkout: pre-push verifies or runs the suite, refuses a dirty tree and a push of something
-- other than HEAD; pre-commit passes the exit code of the fast path on; the Claude stop hook blocks with exit 2 and
-- hands testing.nvim's text to stderr.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function has(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1200) .. ")"
    )
  end

  local scaffold = require("testing.scaffold")
  local deps = require("testing.deps")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-hooks"
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function read(path)
    local f = assert(io.open(path, "rb"))
    local t = f:read("*a")
    f:close()
    return t
  end
  local function git(root, ...)
    local res = vim
      .system({
        "git",
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.invalid",
        "-c",
        "commit.gpgsign=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git: " .. tostring(res.stderr))
    return res.stdout
  end

  -- ---------------------------------------------------------------- written once, never over a file
  local root = tmp .. "/proj"
  write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
  write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'a')\nend\n")
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  local first = scaffold.init(root, { hooks = true, plugin = "proj" })
  eq(first.errors, {}, "the hooks are written")
  eq(first.created, {
    "scripts/hooks/_testing.sh",
    "scripts/hooks/pre-push",
    "scripts/hooks/pre-commit",
    "scripts/hooks/claude-stop",
  }, "four files")
  eq(vim.uv.fs_stat(root .. "/scripts/test.sh"), nil, "only the hooks: no other setup file")
  local again = scaffold.init(root, { hooks = true, plugin = "proj" })
  eq({ #again.created, #again.skipped }, { 0, 4 }, "a second time: nothing created, all kept")
  write(root .. "/scripts/hooks/pre-push", "#!/bin/sh\necho mine\n")
  local forced = scaffold.init(root, { hooks = true, force = true, plugin = "proj" })
  eq(forced.replaced, {}, "--force does not replace a hook file")
  eq(
    read(root .. "/scripts/hooks/pre-push"),
    "#!/bin/sh\necho mine\n",
    "the hook of the user is untouched"
  )
  local hostile = scaffold.init(root, { hooks = true, plugin = "../../x" })
  ok(
    #hostile.created == 0 or hostile.plugin ~= "../../x",
    "a hostile plugin name never reaches a file"
  )

  -- ---------------------------------------------------------------- no verdict logic of their own
  local scripts = {}
  for _, name in ipairs({ "_testing.sh", "pre-commit", "claude-stop" }) do
    scripts[name] = read(root .. "/scripts/hooks/" .. name)
  end
  scripts["pre-push"] = assert(scaffold.render_template("hook_pre_push.tpl", { PLUGIN = "proj" }))
  for name, text in pairs(scripts) do
    local code = text:gsub("#[^\n]*", "") -- comments may talk about it; code may not
    for _, forbidden in ipairs({ "TESTING_OK", "sentinel", "grep", "jq ", "awk", "sed ", "green" }) do
      lacks(code, forbidden, name .. " has no verdict logic: no `" .. forbidden .. "` in its code")
    end
    ok(
      text:find("testing_run", 1, true) or name == "_testing.sh",
      name .. " runs testing.nvim through testing_run"
    )
  end
  has(
    scripts["claude-stop"],
    "PRUEFPUNKTE",
    "the unverified assumptions of the stop hook are marked"
  )
  has(scripts["claude-stop"], "stop_hook_active", "and name the one that is not documented")
  has(scripts["pre-push"], "testing_require_clean_tree", "pre-push refuses a dirty tree")
  has(scripts["pre-commit"], "not the index", "pre-commit says what it cannot do")
  eq(
    select(2, scripts["pre-push"]:gsub("testing_run [a-z]", "")),
    2,
    "pre-push has exactly two ways to ask testing.nvim (verify, then the stamping run)"
  )

  -- ---------------------------------------------------------------- they do what the recipe says (needs bash)
  if vim.fn.executable("bash") ~= 1 then
    vim.fn.delete(tmp, "rf")
    return
  end
  vim.fn.delete(root .. "/scripts/hooks/pre-push")
  eq(
    scaffold.init(root, { hooks = true, plugin = "proj" }).created,
    { "scripts/hooks/pre-push" },
    "the missing one is made"
  )
  for _, name in ipairs({ "_testing.sh", "pre-push", "pre-commit", "claude-stop" }) do
    local syntax = vim
      .system({ "bash", "-n", root .. "/scripts/hooks/" .. name }, { text = true })
      :wait(10000)
    eq(syntax.code, 0, name .. " is valid bash: " .. tostring(syntax.stderr))
  end
  git(root, "init", "-q", "-b", "main")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "init")

  local self_dir = deps.self_dir()
  local lib = assert(deps.resolve("lib.nvim", self_dir))
  local env = {
    TESTING_NVIM_DIR = self_dir,
    LIB_NVIM_DIR = lib.dir,
    NVIM_APPNAME = "testing-hooks-spec",
    XDG_STATE_HOME = tmp .. "/state",
    XDG_CACHE_HOME = tmp .. "/cache",
    TESTING_AGENT = "0",
  }
  ---@param name string
  ---@param stdin? string
  local function hook(name, stdin)
    local res = vim
      .system({ "bash", root .. "/scripts/hooks/" .. name }, {
        cwd = root,
        text = true,
        stdin = stdin or "",
        env = env,
      })
      :wait(180000)
    return { code = res.code, out = (res.stdout or "") .. (res.stderr or "") }
  end
  local zero = ("0"):rep(40)
  local head = vim.trim(git(root, "rev-parse", "HEAD"))
  local push_line = ("refs/heads/main %s refs/heads/main %s\n"):format(head, zero)

  local p1 = hook("pre-push", push_line)
  eq(p1.code, 0, "a first push runs the suite and stamps it: exit 0\n" .. p1.out)
  ok(vim.uv.fs_stat(root .. "/.git/testing/stamp.json"), "the stamp is inside the git directory")
  eq(vim.trim(git(root, "status", "--porcelain")), "", "and the tree is still clean")
  local p2 = hook("pre-push", push_line)
  eq(p2.code, 0, "a second push is verified from the stamp: exit 0\n" .. p2.out)
  has(p2.out, "verified:", "with testing's own words")
  write(root .. "/lua/proj/mod.lua", "return { value = 2 }\n")
  local p3 = hook("pre-push", push_line)
  eq(p3.code, 1, "a dirty tree: refused")
  has(p3.out, "uncommitted changes", "with a clear message")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "change")
  local p4 = hook("pre-push", push_line)
  eq(p4.code, 1, "a push of something other than HEAD: refused\n" .. p4.out)
  has(p4.out, "tree that would be tested is HEAD", "says why")
  local head2 = vim.trim(git(root, "rev-parse", "HEAD"))
  local p5 = hook("pre-push", ("refs/heads/main %s refs/heads/main %s\n"):format(head2, head))
  eq(p5.code, 0, "after a change the suite runs again and the push goes through\n" .. p5.out)

  -- a red suite blocks the push; the stop hook blocks with exit 2 and passes testing's text on
  write(root .. "/TESTS/f_spec.lua", "return function(H)\n  H.ok(false, 'fails')\nend\n")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "red")
  local head3 = vim.trim(git(root, "rev-parse", "HEAD"))
  local red = hook("pre-push", ("refs/heads/main %s refs/heads/main %s\n"):format(head3, head2))
  eq(red.code, 1, "a red suite blocks the push with testing's exit code\n" .. red.out)
  local stop = hook("claude-stop", '{"hook_event_name":"Stop","stop_hook_active":false}')
  eq(stop.code, 2, "a red suite blocks the stop\n" .. stop.out)
  has(stop.out, "RED", "and testing's own text reaches stderr")
  local loop = hook("claude-stop", '{"hook_event_name":"Stop","stop_hook_active": true}')
  eq(
    loop.code,
    0,
    "the guard against a loop lets a second stop through (an assumption, see the check point)"
  )
  local nothing = hook("pre-commit")
  eq(nothing.code, 0, "pre-commit with nothing changed: exit 0 and nothing ran" .. nothing.out)
  has(nothing.out, "nothing ran", "testing says it is not a green run")
  write(
    root .. "/TESTS/f_spec.lua",
    "-- touched" .. string.char(10) .. read(root .. "/TESTS/f_spec.lua")
  )
  local commit = hook("pre-commit")
  eq(
    commit.code,
    1,
    "pre-commit passes the exit code of the fast path on (the touched red spec) " .. commit.out
  )
  has(commit.out, "not staged", "and warns that the working tree is what it checks")

  vim.fn.delete(tmp, "rf")
end
