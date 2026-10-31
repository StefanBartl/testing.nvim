-- TESTS/testing/ci_runner_guard_spec.lua -- `testing ci runner-guard` and `testing ci trust`: the protection of the
-- local self-hosted runner from foreign code. The decision (pull request, foreign actor, private/public, reviewed
-- commit), the hook entry through an injected environment and a fake `gh`, the list of reviewed commits (read as
-- untrusted data), `trust` (record, show, revoke, mode, flagged files) and the wiring in the `.env` of the runners
-- (idempotent, a foreign hook is left alone, remove restores). No network, no real runner.

---@diagnostic disable: need-check-nil, param-type-mismatch, missing-fields

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1500) .. ")"
    )
  end

  local guard = require("testing.ci.runner_guard")
  local ci = require("testing.ci")

  local SHA = ("a"):rep(40)
  local SHA2 = ("b"):rep(40)

  local function sink()
    local o = { out = {}, err = {} }
    o.sv = {
      out = function(s)
        o.out[#o.out + 1] = s
      end,
      err = function(s)
        o.err[#o.err + 1] = s
      end,
    }
    return o
  end
  local function joined(o)
    return table.concat(o.out, "\n") .. "\n" .. table.concat(o.err, "\n")
  end
  local function tmp()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (vim.fs.normalize(d))
  end
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end
  local function slurp(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local t = f:read("*a")
    f:close()
    return t
  end

  -- ------------------------------------------------------------------ the decision

  local function facts(over)
    return vim.tbl_extend("force", {
      event = "push",
      actor = "WKDSteve",
      triggering_actor = "WKDSteve",
      repo = "WKDSteve/tasks.nvim",
      owner = "WKDSteve",
      sha = SHA,
      is_private = false,
      entry = { mode = "auto", shas = {} },
    }, over or {})
  end
  do
    local run, why = guard.decide(facts())
    eq(run, false, "decide: a public repository with an unreviewed commit is refused")
    has(why, "not reviewed", "decide: ... and says why")

    run = guard.decide(facts({ entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } } }))
    eq(run, true, "decide: a reviewed commit runs")

    run = guard.decide(facts({ entry = { mode = "auto", shas = { { sha = SHA2, at = 1 } } } }))
    eq(run, false, "decide: another commit on the list does not cover this one")

    run, why = guard.decide(facts({ event = "pull_request" }))
    eq(run, false, "decide: a pull request is refused")
    has(why, "pull request", "decide: ... named")
    run = guard.decide(facts({ event = "pull_request_target" }))
    eq(run, false, "decide: pull_request_target as well")
    run = guard.decide(facts({
      event = "pull_request",
      is_private = true,
      entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } },
    }))
    eq(run, false, "decide: a reviewed commit does not let a pull request through")

    run, why = guard.decide(
      facts({ actor = "mallory", entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } } })
    )
    eq(run, false, "decide: a foreign actor is refused even for a reviewed commit")
    has(why, "mallory", "decide: ... named")
    run = guard.decide(facts({
      triggering_actor = "mallory",
      is_private = true,
      entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } },
    }))
    eq(run, false, "decide: a foreign triggering actor (re-run by someone else)")
    run = guard.decide(
      facts({ actor = "wkdsteve", entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } } })
    )
    eq(run, true, "decide: the owner compares without regard to case")

    run = guard.decide(facts({ is_private = true }))
    eq(run, true, "decide: a private repository runs for the maintainer")
    run = guard.decide(facts({ is_private = true, entry = { mode = "always", shas = {} } }))
    eq(run, false, "decide: mode always guards a private repository too")
    run = guard.decide(facts({ is_private = nil }))
    eq(run, false, "decide: unknown visibility counts as public")

    run = guard.decide(facts({ event = "pull_request", entry = { mode = "off", shas = {} } }))
    eq(run, true, "decide: mode off switches the guard off")

    for _, k in ipairs({ "event", "actor", "repo", "sha" }) do
      run = guard.decide(facts({
        [k] = "",
        is_private = true,
        entry = { mode = "auto", shas = { { sha = SHA, at = 1 } } },
      }))
      eq(run, false, "decide: no " .. k .. " in the environment refuses (fail closed)")
    end
  end

  eq({
    guard.repo_key("a/.."),
    guard.repo_key("a/."),
    guard.repo_key("../x"),
    guard.repo_key("a/b/c"),
  }, {}, "repo_key: no path segments")
  eq(guard.repo_key("A-b/C_d.e"), "a-b/c_d.e", "repo_key: a usual name, lower case")

  -- ------------------------------------------------------------------ the list is untrusted data

  do
    local root = tmp()
    local path = guard.store_path(root)
    local repos, note = guard.read(path)
    eq({ vim.tbl_count(repos), note }, { 0, nil }, "read: no file is an empty list without a note")

    write(path, "this is not json")
    repos, note = guard.read(path)
    eq(vim.tbl_count(repos), 0, "read: garbage trusts nothing")
    has(note, "nothing is trusted", "read: ... and says so")

    write(path, vim.json.encode({ v = 99, repos = {} }))
    local _, _, keep = guard.read(path)
    eq(keep, true, "read: a list of another version is kept (a writer must not replace it)")

    write(
      path,
      vim.json.encode({
        v = 1,
        repos = {
          ["WKDSteve/Tasks.nvim"] = {
            mode = "bogus",
            shas = {
              { sha = SHA, at = 5, note = "a\nb" },
              { sha = "short" },
              { sha = SHA:upper() },
              7,
            },
          },
          ["../evil"] = { shas = { { sha = SHA } } },
        },
      })
    )
    repos = guard.read(path)
    eq(
      vim.tbl_keys(repos),
      { "wkdsteve/tasks.nvim" },
      "read: keys are lower case, a bad key is dropped"
    )
    eq(repos["wkdsteve/tasks.nvim"].mode, "auto", "read: an unknown mode is auto")
    eq(#repos["wkdsteve/tasks.nvim"].shas, 1, "read: only a full lower-case commit id counts")
    eq(
      repos["wkdsteve/tasks.nvim"].shas[1].note,
      "a b",
      "read: control characters in a note become blanks"
    )
  end

  -- ------------------------------------------------------------------ the hook entry

  local function env(over)
    return vim.tbl_extend("force", {
      GITHUB_EVENT_NAME = "push",
      GITHUB_ACTOR = "WKDSteve",
      GITHUB_TRIGGERING_ACTOR = "WKDSteve",
      GITHUB_REPOSITORY = "WKDSteve/tasks.nvim",
      GITHUB_REPOSITORY_OWNER = "WKDSteve",
      GITHUB_SHA = SHA,
    }, over or {})
  end
  local function fake_gh(private)
    return function(args)
      if args[1] == "api" and args[2] == "repos/WKDSteve/tasks.nvim" and args[4] == ".private" then
        return private == nil and nil or tostring(private) .. "\n"
      end
      return nil, "unexpected " .. table.concat(args, " ")
    end
  end

  do
    local root = tmp()
    local function run_check(e, private)
      local o = sink()
      local code = guard.main({ "check" }, o.sv, { env = e, root = root, gh = fake_gh(private) })
      return code, joined(o)
    end

    local code, text = run_check(env(), false)
    eq(code, 1, "check: an unreviewed commit of a public repository refuses the job")
    has(text, "JOB REFUSED", "check: ... loudly")
    has(
      text,
      "testing ci trust WKDSteve/tasks.nvim " .. SHA,
      "check: ... with the command to release it"
    )

    code = run_check(env(), true)
    eq(code, 0, "check: a private repository of the maintainer runs")

    code, text = run_check(env({ GITHUB_EVENT_NAME = "pull_request" }), true)
    eq(code, 1, "check: a pull request is refused")
    lacks(text, "testing ci trust", "check: ... and no trust is offered for it")

    code = run_check(env({ GITHUB_ACTOR = "mallory" }), true)
    eq(code, 1, "check: a foreign actor is refused")

    code = run_check({}, false)
    eq(code, 1, "check: an empty environment refuses")

    code = run_check(env(), nil)
    eq(code, 1, "check: gh without an answer counts as public")

    -- trust it, then it runs
    local o = sink()
    local tcode = guard.trust_main({ "WKDSteve/tasks.nvim", SHA }, o.sv, {
      root = root,
      now = 1700000000,
      gh = function(args)
        if args[2] == "repos/WKDSteve/tasks.nvim/commits/" .. SHA then
          return SHA .. "\n"
        end
        return nil, "unexpected " .. table.concat(args, " ")
      end,
    })
    eq(tcode, 0, "trust: records the commit")
    has(joined(o), "reviewed: wkdsteve/tasks.nvim " .. SHA, "trust: ... and says so")
    code = run_check(env(), false)
    eq(code, 0, "check: the reviewed commit runs")
    code = run_check(env({ GITHUB_SHA = SHA2 }), false)
    eq(code, 1, "check: the next commit does not")

    -- mode always / off
    o = sink()
    eq(
      guard.trust_main({ "--mode=off", "WKDSteve/tasks.nvim" }, o.sv, { root = root }),
      0,
      "mode: off"
    )
    code = run_check(env({ GITHUB_SHA = SHA2, GITHUB_EVENT_NAME = "pull_request" }), false)
    eq(code, 0, "check: mode off lets everything through")
    guard.trust_main({ "--mode=auto", "WKDSteve/tasks.nvim" }, sink().sv, { root = root })

    -- revoke
    o = sink()
    eq(guard.trust_main({ "--revoke", "WKDSteve/tasks.nvim" }, o.sv, { root = root }), 0, "revoke")
    code = run_check(env(), false)
    eq(code, 1, "check: after the revoke the commit is unreviewed again")
  end

  -- ------------------------------------------------------------------ trust: the review aid and the arguments

  do
    local root = tmp()
    local calls = {}
    local compare = vim.json.encode({
      status = "ahead",
      total_commits = 2,
      commits = {
        { sha = SHA2, commit = { message = "add feature\n\nbody", author = { name = "Mallory" } } },
        { sha = SHA, commit = { message = "tweak", author = { name = "Alice" } } },
      },
      files = {
        { filename = "lua/x.lua", status = "modified" },
        { filename = ".github/workflows/ci.yml", status = "modified" },
        { filename = "scripts/test.sh", status = "added" },
        { filename = "docs/a.md", status = "modified" },
        { filename = "package-lock.json", status = "modified" },
      },
    })
    local function gh(args)
      calls[#calls + 1] = table.concat(args, " ")
      local a = args[2]
      if a == "repos/o/r" then
        return "main\n"
      elseif a == "repos/o/r/commits/main" then
        return SHA2 .. "\n"
      elseif a == "repos/o/r/commits/" .. SHA then
        return SHA .. "\n"
      elseif a == ("repos/o/r/compare/%s...%s"):format(SHA, SHA2) then
        return compare
      end
      return nil, "unexpected " .. a
    end
    local ctx = { root = root, gh = gh, now = 1 }

    local o = sink()
    eq(guard.trust_main({ "o/r", SHA }, o.sv, ctx), 0, "trust: first release")
    has(joined(o), "review the whole tree", "trust: ... the first one has nothing to compare with")

    o = sink()
    eq(guard.trust_main({ "o/r", "--show" }, o.sv, ctx), 0, "trust --show: default branch head")
    local text = joined(o)
    has(text, "2 commit(s)", "show: counts the commits")
    has(text, "Mallory", "show: names the author")
    has(text, "add feature", "show: first line of the message")
    lacks(text, "body", "show: not the body")
    has(text, "look closely [.github] .github/workflows/ci.yml", "show: flags the workflow")
    has(text, "look closely [scripts] scripts/test.sh", "show: flags a script")
    has(text, "[lockfile] package-lock.json", "show: flags a lock file")
    lacks(text, "docs/a.md", "show: does not list ordinary files")
    has(text, "nothing recorded", "show: records nothing")
    local repos = guard.read(guard.store_path(root))
    eq(#repos["o/r"].shas, 1, "show: the list is unchanged")

    o = sink()
    eq(
      guard.trust_main({ "o/r", "--note=reviewed by me" }, o.sv, ctx),
      0,
      "trust: the default is the head"
    )
    repos = guard.read(guard.store_path(root))
    eq(#repos["o/r"].shas, 2, "trust: two commits on the list")
    eq(repos["o/r"].shas[2].note, "reviewed by me", "trust: the note is kept")

    o = sink()
    eq(guard.trust_main({ "--list" }, o.sv, ctx), 0, "list")
    has(joined(o), "o/r  mode=auto  2 reviewed", "list: shows the repository")

    o = sink()
    eq(guard.trust_main({ "--revoke", "o/r", SHA:sub(1, 8) }, o.sv, ctx), 0, "revoke one by prefix")
    repos = guard.read(guard.store_path(root))
    eq(#repos["o/r"].shas, 1, "revoke: one left")
    eq(repos["o/r"].shas[1].sha, SHA2, "revoke: the right one")

    -- arguments
    o = sink()
    eq(guard.trust_main({ "--frobnicate" }, o.sv, ctx), 2, "args: unknown option")
    o = sink()
    eq(
      guard.trust_main({ "o/r", "nonsense!" }, o.sv, ctx),
      2,
      "args: neither repository nor commit"
    )
    o = sink()
    eq(guard.trust_main({ "--mode=weird", "o/r" }, o.sv, ctx), 2, "args: unknown mode")
    o = sink()
    eq(
      guard.trust_main({ "o/r", ("c"):rep(40) }, o.sv, {
        root = root,
        gh = function()
          return nil, "Not Found"
        end,
      }),
      3,
      "trust: a commit that GitHub does not know in this repository is refused"
    )
    has(joined(o), "Not Found", "trust: ... with the reason")

    -- a list of another version is never overwritten
    local other = tmp()
    write(guard.store_path(other), vim.json.encode({ v = 99, repos = {} }))
    o = sink()
    eq(
      guard.trust_main({ "o/r", SHA }, o.sv, { root = other, gh = gh, now = 1 }),
      3,
      "trust: a list of another version is left as it is"
    )
    has(slurp(guard.store_path(other)), '"v":99', "trust: ... untouched")
  end

  -- ------------------------------------------------------------------ the wiring

  do
    local root = tmp()
    write(root .. "/tasks.nvim/run.cmd", "@echo off\r\n")
    write(root .. "/tasks.nvim/.env", "FOO=bar\r\n")
    write(root .. "/rules.nvim/run.cmd", "@echo off\r\n")
    write(root .. "/other.nvim/run.cmd", "@echo off\r\n")
    write(root .. "/other.nvim/.env", guard.HOOK_VAR .. "=C:\\mine\\hook.ps1\r\n")
    write(root .. "/_work/run.cmd", "must be ignored")
    local ctx = { root = root, nvim = "C:/n vim/nvim.exe", script = "E:/it's/testing.lua" }

    local o = sink()
    eq(guard.main({ "status" }, o.sv, ctx), 0, "status: before")
    has(joined(o), ("%-16s %s"):format("tasks.nvim", "not guarded"), "status: not guarded yet")
    has(
      joined(o),
      ("%-16s %s"):format("other.nvim", "foreign hook"),
      "status: a foreign hook is recognised"
    )
    lacks(joined(o), "_work", "status: only runner folders count")

    o = sink()
    local code = guard.main({ "install" }, o.sv, ctx)
    eq(code, 1, "install: exit 1 because one runner has a hook of its own")
    local hook = (root .. "/_guard/job-started.ps1")
    local script = slurp(hook)
    has(script, "$nvim = 'C:/n vim/nvim.exe'", "hook script: absolute nvim, quoted")
    has(script, "$script = 'E:/it''s/testing.lua'", "hook script: a quote is doubled")
    has(script, "ci runner-guard check", "hook script: calls the check")
    has(script, "exit 1", "hook script: a missing tool refuses the job")
    has(script, "exit $LASTEXITCODE", "hook script: hands the exit code on")
    local env_tasks = slurp(root .. "/tasks.nvim/.env")
    has(env_tasks, "FOO=bar", "install: other lines of .env stay")
    has(env_tasks, guard.HOOK_VAR .. "=" .. hook:gsub("/", "\\"), "install: the hook line is set")
    has(
      slurp(root .. "/rules.nvim/.env"),
      guard.HOOK_VAR .. "=",
      "install: a runner without .env gets one"
    )
    eq(
      slurp(root .. "/other.nvim/.env"),
      guard.HOOK_VAR .. "=C:\\mine\\hook.ps1\r\n",
      "install: a foreign hook is left alone"
    )
    has(joined(o), "has a hook of its own", "install: ... and reported")

    guard.main({ "install" }, sink().sv, ctx)
    local _, count = slurp(root .. "/tasks.nvim/.env"):gsub(guard.HOOK_VAR, "")
    eq(count, 1, "install: twice sets one line")

    o = sink()
    guard.main({ "status" }, o.sv, ctx)
    has(joined(o), ("%-16s %s"):format("tasks.nvim", "guarded"), "status: guarded")

    o = sink()
    guard.main({ "remove" }, o.sv, ctx)
    eq(slurp(root .. "/tasks.nvim/.env"), "FOO=bar\r\n", "remove: only our line goes")
    eq(slurp(hook), nil, "remove: the hook script goes")
    eq(
      slurp(root .. "/other.nvim/.env"),
      guard.HOOK_VAR .. "=C:\\mine\\hook.ps1\r\n",
      "remove: a foreign hook stays"
    )

    o = sink()
    eq(
      guard.main({ "install", "--runners=" .. root .. "/nope" }, o.sv, ctx),
      2,
      "install: no such folder"
    )
    o = sink()
    eq(guard.main({ "bogus" }, o.sv, ctx), 2, "main: unknown action")
    o = sink()
    eq(guard.main({ "check", "extra" }, o.sv, ctx), 2, "main: check takes no argument")
  end

  -- ------------------------------------------------------------------ the entry through `testing ci`

  do
    local o = sink()
    local code = ci.main({ "trust", "--bogus" }, o.sv)
    eq(code, 2, "ci: trust is dispatched")
    has(joined(o), "unknown option", "ci: ... to this module")
    o = sink()
    code = ci.main({ "runner-guard" }, o.sv)
    eq(code, 2, "ci: runner-guard is dispatched")
    has(ci.USAGE, "runner-guard", "ci: the usage names it")
  end
end
