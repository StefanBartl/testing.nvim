-- TESTS/testing/ci_verify_spec.lua -- `testing ci verify`: the proof of a complete green run over the tree (a reworded
-- commit keeps it, a docs-only commit keeps the suite's stamp and reruns the rest, `--reuse`), and every way it is
-- refused: no run, a red run, a changed spec, another pipeline or Neovim, a dirty tree, an old proof.

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

  local ci = require("testing.ci")
  local verify = require("testing.ci.verify")
  local cli = require("testing.cli")

  do
    local a = verify.parse({ "--profile=fast", "--json", "--allow-dirty", "--max-age", "3d" })
    eq(a.profile, "fast", "args: --profile=")
    eq({ a.json, a.allow_dirty, a.max_age }, { true, true, "3d" }, "args: flags")
    local none, why = verify.parse({ "--max-age=soon" })
    eq(none, nil, "args: a bad duration")
    has(why, "--max-age", "args: ... is named")
    none, why = verify.parse({ "--frobnicate" })
    eq(none, nil, "args: an unknown argument")
    has(why, "--frobnicate", "args: ... is named")
  end

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-ci-verify"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"
  local cache_dir = tmp .. "/cache"
  local nvim = vim.v.progpath

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
        "-c",
        "core.autocrlf=false",
        ...,
      }, { cwd = root, text = true })
      :wait(30000)
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
  end
  local function commit(root, message)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", message)
  end

  ---@param name string
  ---@param ci_lua string The Lua text of the `ci` table.
  ---@param files table<string, string>
  ---@return string root
  local function project(name, ci_lua, files)
    local root = tmp .. "/" .. name
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' }, ci = " .. ci_lua .. " }\n"
    )
    for rel, text in pairs(files) do
      write(root .. "/" .. rel, text)
    end
    git(root, "init", "-q")
    git(root, "symbolic-ref", "HEAD", "refs/heads/main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  -- the environment the stamp code sees: nothing from the real one (on a CI runner `CI=true` makes every local stamp
  -- `untrusted`, which is the trust model, not what this spec is about)
  local function getenv()
    return nil
  end

  ---@param head string[] The leading arguments (`ci` or `ci verify`).
  ---@param root string
  ---@param ... string
  local function call(head, root, ...)
    local out, err = {}, {}
    local argv = vim.list_extend(vim.deepcopy(head), { "--root=" .. root, ... })
    local code = cli.main(argv, {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state_dir,
      cache_dir = cache_dir,
      color = false,
      affected = { getenv = getenv, provider = false },
      stamp = { getenv = getenv },
    })
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end
  local function run(root, ...)
    return call({ "ci" }, root, ...)
  end
  local function vrun(root, ...)
    return call({ "ci", "verify" }, root, ...)
  end

  local echo = "lua/proj/echo.lua"
  local ECHO =
    "io.stdout:write((_G.arg[1] or '') .. '|' .. (vim.uv.os_getenv('CI_SPEC') or '') .. '\\n')\n"
  local function nv(script, ...)
    local parts = {
      ("%q"):format(nvim),
      '"--headless"',
      '"-u"',
      '"NONE"',
      '"-i"',
      '"NONE"',
      '"-l"',
      ("%q"):format(script),
    }
    for _, a in ipairs({ ... }) do
      parts[#parts + 1] = ("%q"):format(a)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end

  local PASS = "return function(H)\n  H.ok(true, 'the module')\nend\n"
  local CFG = "{ profiles = { full = { 'suite', 'echo' } }, steps = { echo = { run = "
    .. nv("lua/proj/echo.lua", "a")
    .. " } } }"

  do
    local root = project("verify", CFG, { ["TESTS/a_spec.lua"] = PASS, [echo] = ECHO })

    local res = vrun(root)
    eq(res.code, 1, "no run yet: exit 1")
    has(res.out, "ci verify: no-stamp", "no run yet: no-stamp")
    lacks(res.out, ci.SENTINEL, "no run yet: no sentinel")

    res = run(root)
    eq(res.code, 0, "the full run is green (" .. res.err .. ")")
    res = vrun(root)
    eq(res.code, 0, "after a green run: verified (" .. res.out .. res.err .. ")")
    has(res.out, "ci verify: verified", "verified: said so")
    eq(res.last, ci.SENTINEL, "verified: the sentinel is the last line")

    local json = vim.json.decode(vrun(root, "--json").out)
    eq(
      { json.schema, json.status, json.verified, json.suite },
      { "testing-ci-verify/1", "verified", true, "verified" },
      "--json: the document"
    )

    -- a reworded commit keeps the tree: still verified
    git(root, "commit", "-q", "--amend", "-m", "reworded")
    eq(vrun(root).code, 0, "amend: the same tree is still verified")

    -- an uncommitted file: not what a commit would contain
    write(root .. "/README.md", "docs\n")
    res = vrun(root)
    eq(res.code, 1, "dirty tree: not verified")
    has(res.out, "ci verify: dirty", "dirty tree: said so")

    -- a change nobody's spec can see: the tree differs, the suite's stamp holds, only the other step reruns
    commit(root, "docs")
    res = vrun(root)
    eq(res.code, 1, "docs-only commit: not verified")
    has(res.out, "ci verify: changed", "docs-only commit: changed")
    lacks(res.out, ci.SENTINEL, "docs-only commit: no sentinel")
    json = vim.json.decode(vrun(root, "--json").out)
    eq(json.suite, "verified", "docs-only commit: the suite's stamp still verifies")
    eq(json.rerun, { "echo" }, "docs-only commit: only the other step reruns")

    -- --reuse: the suite is not run again, the proof is renewed
    res = run(root, "--reuse")
    eq(res.code, 0, "--reuse: green (" .. res.err .. ")")
    has(res.out, "reused: its stamp verifies", "--reuse: the suite is reused")
    eq(vrun(root).code, 0, "--reuse: the new tree is verified")

    -- a spec changed: the suite's stamp does not hold, everything reruns
    write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 == 1, 'changed')\nend\n")
    commit(root, "spec")
    json = vim.json.decode(vrun(root, "--json").out)
    eq(json.status, "changed", "changed spec: changed")
    eq(json.suite, "changed", "changed spec: the stamp says so")
    eq(json.rerun, { "suite", "echo" }, "changed spec: both steps rerun")
    res = run(root, "--reuse")
    eq(res.code, 0, "changed spec + --reuse: the suite runs (" .. res.err .. ")")
    lacks(res.out, "reused: its stamp verifies", "changed spec + --reuse: not reused")
    eq(vrun(root).code, 0, "changed spec: verified after the rerun")

    -- another pipeline is another proof
    local cfg = read(root .. "/.testing.lua"):gsub("{ 'suite', 'echo' }", "{ 'echo', 'suite' }", 1)
    write(root .. "/.testing.lua", cfg)
    commit(root, "pipeline")
    res = vrun(root)
    has(res.out, "ci verify: rejected", "another pipeline: rejected")
    has(res.out, "pipeline", "another pipeline: named")
  end

  -- the proof's own facts: Neovim, the system, the age, a red or partial run
  do
    local root = project("verify-facts", CFG, { ["TESTS/a_spec.lua"] = PASS, [echo] = ECHO })
    eq(run(root).code, 0, "facts: the full run is green")
    local path = require("testing.state").dir(root, { state_dir = state_dir }) .. "/ci-full.json"
    local good = read(path)

    local function with(change)
      local doc = vim.json.decode(good)
      change(doc)
      write(path, vim.json.encode(doc))
      return vrun(root)
    end
    local res = with(function(d)
      d.nvim = "0.0.1"
    end)
    eq(res.code, 1, "another Neovim: not verified")
    has(res.out, "ci verify: rejected", "another Neovim: rejected")
    has(res.out, "neovim", "another Neovim: named")
    res = with(function(d)
      d.pipeline_sha = "0000"
    end)
    has(res.out, "ci verify: rejected", "another pipeline hash: rejected")
    res = with(function(d)
      d.os = "plan9"
    end)
    has(res.out, "ci verify: rejected", "another system: rejected")
    local function two_days_old(d)
      d.time = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 2 * 86400)
    end
    res = with(two_days_old)
    eq(res.code, 0, "a proof of two days is fine for the default limit of 7d")
    write(
      path,
      vim.json.encode(
        vim.tbl_extend(
          "force",
          vim.json.decode(good),
          { time = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 2 * 86400) }
        )
      )
    )
    res = vrun(root, "--max-age=1d")
    eq(res.code, 1, "an old proof: not verified")
    has(res.out, "ci verify: expired", "an old proof: expired")
    eq(vrun(root, "--max-age=3d").code, 0, "...unless the limit is generous")
    res = with(function(d)
      d.verdict, d.exit = "red", 1
    end)
    has(res.out, "ci verify: invalid", "a red document is no proof")
    res = with(function(d)
      d.partial = true
    end)
    has(res.out, "ci verify: invalid", "a partial document is no proof")
    write(path, "not json")
    has(vrun(root).out, "ci verify: invalid", "garbage is invalid")
    write(path, good)
    eq(vrun(root).code, 0, "the good document verifies again")

    res = vrun(root, "--profile=nope")
    eq(res.code, 2, "an unknown profile is a usage error")
    has(res.err, "unknown profile", "... named")
    eq(vrun(root, "--max-age=soon").code, 2, "a bad duration is a usage error")
  end

  vim.fn.delete(tmp, "rf")
end
