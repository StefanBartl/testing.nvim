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
  if vim.fn.has("win32") ~= 1 then
    -- git runs a hook that is not executable: never (it only prints a hint), so the bit is the whole recipe
    for _, name in ipairs({ "pre-push", "pre-commit", "claude-stop" }) do
      local st = vim.uv.fs_stat(root .. "/scripts/hooks/" .. name)
      ok(
        st and bit.band(st.mode, tonumber("111", 8)) == tonumber("111", 8),
        name .. " is executable"
      )
    end
  end
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
    "CHECKPOINTS",
    "the unverified assumptions of the stop hook are marked"
  )
  -- the recipes are source text that lands in other repositories: English only (the repository rule), no German word
  for name, text in pairs(scripts) do
    for _, german in ipairs({ "PRUEFPUNKT", "Pruefpunkt", "pruefpunkt", "Prüfpunkt" }) do
      lacks(text, german, name .. " is English: no `" .. german .. "`")
    end
  end
  has(scripts["claude-stop"], "stop_hook_active", "and name the one that is not documented")
  has(scripts["pre-push"], "testing_require_clean_tree", "pre-push refuses a dirty tree")
  has(scripts["pre-commit"], "not the index", "pre-commit says what it cannot do")
  eq(
    select(2, scripts["pre-push"]:gsub("testing_run [a-z]", "")),
    2,
    "pre-push has exactly two ways to ask testing.nvim (verify, then the stamping run)"
  )

  -- git on Windows records the hooks as 100644 and a clone elsewhere skips a hook that is not executable: the
  -- command that sets the bit is where a reader looks (the install lines of the docs, the templates, the notification)
  local CHMOD = "git update-index --chmod=+x scripts/hooks/pre-push scripts/hooks/pre-commit"
  local steps = table.concat(scaffold.hook_next_steps(), "\n")
  has(steps, CHMOD, "the notification after init --hooks names the executable bit")
  has(steps, "git config core.hooksPath scripts/hooks", "and the hooks path")
  has(read(deps.self_dir() .. "/docs/HOOKS.md"), CHMOD, "docs/HOOKS.md names it")
  has(scripts["pre-push"], "update-index --chmod=+x", "the pre-push template names it")
  has(scripts["pre-commit"], "update-index --chmod=+x", "the pre-commit template names it")

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
  git(root, "update-index", "--chmod=+x", "scripts/hooks/pre-push", "scripts/hooks/pre-commit")
  local modes = git(root, "ls-files", "-s", "scripts/hooks")
  for _, name in ipairs({ "pre-push", "pre-commit" }) do
    local mode
    for line in modes:gmatch("[^\n]+") do
      if line:find("scripts/hooks/" .. name, 1, true) then
        mode = line:sub(1, 6)
      end
    end
    eq(mode, "100755", name .. " is executable in the index after the command of the docs")
  end
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
  -- the hooks stamp and verify locally: a CI marker of the machine this spec runs on would make an unsigned
  -- stamp untrusted (that rule has its own spec), so blank all of them
  for _, name in ipairs(require("testing.affected").CI_ENV) do
    env[name] = ""
  end
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

  -- tags: git hands the hook the object name of an ANNOTATED tag (the tag object, not the commit it points to)
  git(root, "-c", "tag.gpgsign=false", "tag", "-a", "v1", "-m", "release")
  local tag_sha = vim.trim(git(root, "rev-parse", "v1"))
  ok(tag_sha ~= head2, "an annotated tag is an object of its own: " .. tag_sha)
  local pt = hook("pre-push", ("refs/tags/v1 %s refs/tags/v1 %s\n"):format(tag_sha, zero))
  eq(pt.code, 0, "an annotated tag on HEAD is a push of HEAD: exit 0\n" .. pt.out)
  git(root, "tag", "v2")
  local pl = hook("pre-push", ("refs/tags/v2 %s refs/tags/v2 %s\n"):format(head2, zero))
  eq(pl.code, 0, "a lightweight tag on HEAD: exit 0\n" .. pl.out)
  git(root, "-c", "tag.gpgsign=false", "tag", "-a", "v0", "-m", "old", head)
  local old_tag = vim.trim(git(root, "rev-parse", "v0"))
  local po = hook("pre-push", ("refs/tags/v0 %s refs/tags/v0 %s\n"):format(old_tag, zero))
  eq(po.code, 1, "a tag on another commit is still refused: the run would test HEAD\n" .. po.out)
  has(po.out, "tree that would be tested is HEAD", "with the usual message")
  local pm = hook(
    "pre-push",
    ("refs/tags/v1 %s refs/tags/v1 %s\nrefs/tags/v0 %s refs/tags/v0 %s\n"):format(
      tag_sha,
      zero,
      old_tag,
      zero
    )
  )
  eq(pm.code, 1, "one tag that is not HEAD among several refs refuses the push\n" .. pm.out)

  -- notes: `git push origin refs/notes/testing` (the transport of `testing stamp --note`, docs/CACHE.md) pushes a
  -- notes commit that is never HEAD and carries no code: there is nothing to test, so the hook lets it through
  git(root, "notes", "--ref=testing", "add", "-m", "stamp", "HEAD")
  local notes_sha = vim.trim(git(root, "rev-parse", "refs/notes/testing"))
  ok(notes_sha ~= head2, "fixture: the notes commit is not HEAD")
  local notes_line = ("refs/notes/testing %s refs/notes/testing %s\n"):format(notes_sha, zero)
  local pn = hook("pre-push", notes_line)
  eq(pn.code, 0, "a push of the notes ref to the notes ref is not checked: exit 0\n" .. pn.out)
  lacks(pn.out, "tree that would be tested", "no complaint about HEAD for a notes ref")
  lacks(pn.out, "verified", "and no run for it")
  write(root .. "/marker.txt", "untracked\n")
  local pn_dirty = hook("pre-push", notes_line)
  eq(pn_dirty.code, 0, "also with a dirty tree: no tree check for a notes push\n" .. pn_dirty.out)
  lacks(pn_dirty.out, "uncommitted changes", "nothing to say about the tree")
  local pn_update =
    hook("pre-push", ("refs/notes/testing %s refs/notes/testing %s\n"):format(notes_sha, notes_sha))
  eq(pn_update.code, 0, "an update of a notes ref on the remote: exit 0\n" .. pn_update.out)
  local pn_mixed =
    hook("pre-push", notes_line .. ("refs/heads/main %s refs/heads/main %s\n"):format(head2, head))
  eq(
    pn_mixed.code,
    1,
    "a notes ref next to a real ref: the real one is still checked\n" .. pn_mixed.out
  )
  has(pn_mixed.out, "uncommitted changes", "(the dirty tree)")
  vim.fn.delete(root .. "/marker.txt")
  -- the notes commit pushed onto a branch is a push of something that is not HEAD, whatever the local name says
  local pn_branch =
    hook("pre-push", ("refs/notes/testing %s refs/heads/main %s\n"):format(notes_sha, head))
  eq(pn_branch.code, 1, "a notes commit pushed onto a branch is refused\n" .. pn_branch.out)
  has(pn_branch.out, "tree that would be tested is HEAD", "with the usual message")
  local pn_evil =
    hook("pre-push", ("refs/notes/testing --evil refs/notes/testing %s\n"):format(zero))
  eq(pn_evil.code, 1, "a notes line with a name that is not hex is refused too\n" .. pn_evil.out)
  has(pn_evil.out, "unexpected object name", "says why")
  has(
    scripts["pre-push"],
    "refs/notes/",
    "the pre-push template names the notes refs it lets through"
  )

  -- a push with nothing to test ends the hook: a deletion, or no ref at all (everything up to date), even when the
  -- tree is dirty (no run is started for it)
  write(root .. "/marker.txt", "untracked\n")
  local delete_line = ("(delete) %s refs/heads/old %s\n"):format(zero, head)
  local del = hook("pre-push", delete_line)
  eq(
    del.code,
    0,
    "deleting a remote branch with a dirty tree: nothing to test, exit 0\n" .. del.out
  )
  lacks(del.out, "uncommitted changes", "no tree check for a deletion")
  lacks(del.out, "verified", "and no run for it")
  local up_to_date = hook("pre-push", "")
  eq(up_to_date.code, 0, "no ref to push (empty stdin): exit 0\n" .. up_to_date.out)
  lacks(up_to_date.out, "uncommitted changes", "no tree check without a ref")
  local mixed =
    hook("pre-push", delete_line .. ("refs/heads/main %s refs/heads/main %s\n"):format(head2, head))
  eq(mixed.code, 1, "a deletion next to a real ref: the real one is still checked\n" .. mixed.out)
  has(mixed.out, "uncommitted changes", "(the dirty tree)")
  vim.fn.delete(root .. "/marker.txt")
  -- a last line without a newline is still a line
  local no_newline = hook("pre-push", ("refs/heads/main %s refs/heads/main %s"):format(head2, head))
  eq(no_newline.code, 0, "a last line without a newline is checked: exit 0\n" .. no_newline.out)
  has(no_newline.out, "verified:", "and it was verified")
  -- a name that is no object name is refused, never handed to git
  local evil = hook("pre-push", ("refs/heads/main --evil refs/heads/main %s\n"):format(zero))
  eq(evil.code, 1, "an object name that is not hex: refused\n" .. evil.out)
  has(evil.out, "unexpected object name", "says why")
  -- the checkouts of the dependencies below the project are no change of the project
  write(root .. "/.deps/lib.nvim/lua/lib.lua", "return {}\n")
  git(root .. "/.deps/lib.nvim", "init", "-q", "-b", "main")
  git(root .. "/.deps/lib.nvim", "add", "-A")
  git(root .. "/.deps/lib.nvim", "commit", "-q", "-m", "dep")
  eq(vim.trim(git(root, "status", "--porcelain")), "?? .deps/", "(git sees .deps/ as untracked)")
  local deps_push =
    hook("pre-push", ("refs/heads/main %s refs/heads/main %s\n"):format(head2, head))
  eq(deps_push.code, 0, ".deps/ is no uncommitted change: the push goes through\n" .. deps_push.out)
  lacks(deps_push.out, "uncommitted changes", "and says nothing of it")
  vim.fn.delete(root .. "/.deps", "rf")

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
  local later = hook(
    "claude-stop",
    '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"all true"}'
  )
  eq(
    later.code,
    2,
    'stop_hook_active:false with a later "true" still runs the suite\n' .. later.out
  )
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

  -- git hands the hook GIT_INDEX_FILE (the index of the commit being made, for `git commit -a` and `git commit <path>`).
  -- A spec that runs git in a temporary repository inherits it from the runner and writes into that index: the commit
  -- breaks ("invalid object ... Error building trees") although the run says green
  do
    local groot = tmp .. "/gitproj"
    local marker = tmp .. "/git-spec-ran.txt"
    local git_spec = (
      "return function(H)\n"
      .. "  local d = vim.fn.tempname()\n"
      .. "  vim.fn.mkdir(d, 'p')\n"
      .. "  local function git(...)\n"
      .. "    local r = vim.system({ 'git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ... }, { cwd = d, text = true }):wait(30000)\n"
      .. "    H.ok(r.code == 0, 'git ' .. table.concat({ ... }, ' ') .. ': ' .. tostring(r.stderr))\n"
      .. "  end\n"
      .. "  git('init', '-q', '-b', 'main')\n"
      .. "  local f = assert(io.open(d .. '/a.txt', 'wb'))\n"
      .. "  f:write('a\\n')\n"
      .. "  f:close()\n"
      .. "  git('add', '-A')\n"
      .. "  git('commit', '-q', '-m', 'inner')\n"
      .. "  vim.fn.delete(d, 'rf')\n"
      .. "  local m = assert(io.open(%q, 'ab'))\n"
      .. "  m:write('ran\\n')\n"
      .. "  m:close()\n"
      .. "end\n"
    ):format(marker)
    write(groot .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(groot .. "/TESTS/g_spec.lua", git_spec)
    write(
      groot .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    eq(
      scaffold.init(groot, { hooks = true, plugin = "proj" }).errors,
      {},
      "(hooks of the git project)"
    )
    git(groot, "init", "-q", "-b", "main")
    git(groot, "add", "-A")
    git(groot, "commit", "-q", "-m", "init")
    git(groot, "config", "core.hooksPath", "scripts/hooks")
    ---git commit with the hooks of the project, in the environment of the hook specs.
    ---@param ... string
    local function commit_with_hook(...)
      local res = vim
        .system({
          "git",
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.invalid",
          "-c",
          "commit.gpgsign=false",
          "commit",
          "-q",
          ...,
        }, { cwd = groot, text = true, env = env })
        :wait(180000)
      return { code = res.code, out = (res.stdout or "") .. (res.stderr or "") }
    end
    local function ran_count()
      local f = io.open(marker, "rb")
      if not f then
        return 0
      end
      local t = f:read("*a")
      f:close()
      return select(2, t:gsub("ran", ""))
    end
    ---@param label string
    ---@param args string[]
    local function change_and_commit(label, args)
      local spec_path = groot .. "/TESTS/g_spec.lua"
      write(spec_path, "-- " .. label .. string.char(10) .. read(spec_path))
      local before = ran_count()
      local c = commit_with_hook(unpack(args))
      eq(c.code, 0, label .. ": the commit is made\n" .. c.out)
      lacks(c.out, "invalid object", label .. ": nothing is written into the index of the commit")
      eq(vim.trim(git(groot, "log", "-1", "--format=%s")), label, label .. ": the commit is there")
      eq(vim.trim(git(groot, "status", "--porcelain")), "", label .. ": nothing is left over")
      ok(ran_count() > before, label .. ": the spec that runs git ran under the hook")
    end
    change_and_commit("commit-a", { "-a", "-m", "commit-a" })
    change_and_commit("commit-path", { "-m", "commit-path", "--", "TESTS/g_spec.lua" })
  end

  vim.fn.delete(tmp, "rf")
end
