-- TESTS/testing/stamp_run_spec.lua -- `testing stamp` and `testing verify` on real projects (a git checkout in a
-- temporary directory, real keys): a stamp only after a complete green run; `verify` answers from the keys and says
-- `verified` (exit 0, sentinel) ONLY when every file is proven; a partial proof, a changed file, an old stamp, a dirty
-- tree, a forged or foreign stamp are never green.

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type, redundant-parameter

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

  local cli = require("testing.cli")
  local stamp = require("testing.stamp")
  local SENTINEL = "TESTING_OK"

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-stamprun"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"
  local cache_dir = tmp .. "/cache"

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
  ---@param root string
  ---@param ... string
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
    ok(res.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. tostring(res.stderr))
    return res.stdout
  end

  -- the environment the stamp code sees: nothing from the real one (a CI run of this spec must not change it)
  local E = {}
  local function getenv(name)
    return E[name]
  end
  local clock = { now = nil, git = nil }

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string, last: string }
  local function run(argv)
    local out, err = {}, {}
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
      stamp = { getenv = getenv, now = clock.now, run = clock.git },
    })
    package.loaded["proj.mod"] = nil
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end
  local function verify_json(argv)
    local res = run(argv)
    local good, doc = pcall(vim.json.decode, res.out)
    ok(
      good and type(doc) == "table",
      "verify --json prints one JSON document: " .. res.out:sub(1, 300)
    )
    return good and doc or {}, res
  end

  local PURE = "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n"
  local USES_MOD = "return function(H)\n  H.ok(require('proj.mod').value >= 1, 'the module')\nend\n"
  local CLOCK = "return function(H)\n  H.ok(os.time() > 0, 'the clock')\nend\n"
  local CFG = "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"

  ---@param name string
  ---@param specs table<string, string>
  ---@param cfg? string The text of `.testing.lua`.
  ---@return string root
  local function project(name, specs, cfg)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(root .. "/.testing.lua", cfg or CFG)
    for rel, text in pairs(specs) do
      write(root .. "/TESTS/" .. rel, text)
    end
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end
  local function commit_all(root, msg)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", msg)
  end
  ---@param root string
  ---@return Testing.Stamp
  local function stamp_of(root)
    local st, why = stamp.decode(read(stamp.path(root, { state_dir = state_dir })))
    ok(st, "the stamp on disk is valid: " .. tostring(why))
    return st
  end
  ---Every file below the directories, with its modification time: what a command left behind.
  local function snapshot()
    local out = {}
    for _, dir in ipairs({ state_dir, cache_dir }) do
      for name, kind in vim.fs.dir(dir, { depth = 8 }) do
        local p = dir .. "/" .. name
        if kind == "file" then
          local st = vim.uv.fs_stat(p)
          out[p] = st.size .. ":" .. st.mtime.sec .. "." .. st.mtime.nsec
        end
      end
    end
    return out
  end

  -- ================================================================ a project that can be proven in full
  local root = project("p", { ["a_spec.lua"] = PURE, ["c_spec.lua"] = USES_MOD })

  -- no stamp yet
  local none = verify_json({ "verify", root, "--json" })
  eq(none.status, "no-stamp", "nothing written yet: no-stamp")
  eq(none.verified, false, "and not verified")
  local none_text = run({ "verify", root })
  eq(none_text.code, 1, "no stamp: exit 1")
  ok(none_text.last ~= SENTINEL, "no stamp: no sentinel")
  has(none_text.out, "testing stamp", "and the way to make one")

  -- a stamp needs a full run
  for _, bad in ipairs({
    { "--changed" },
    { "--filter", "arith" },
    { "--maxfail", "1" },
    { "--shuffle" },
    { "--list" },
  }) do
    local r = run(vim.list_extend({ "stamp", root }, bad))
    eq(r.code, 2, "stamp " .. bad[1] .. ": a usage error")
    ok(
      not vim.uv.fs_stat(stamp.path(root, { state_dir = state_dir })),
      "stamp " .. bad[1] .. ": nothing written"
    )
  end
  eq(
    run({ "stamp", root, "TESTS/a_spec.lua" }).code,
    2,
    "a path argument selects part of the suite"
  )
  local nosecret = run({ "stamp", root })
  eq(nosecret.code, 0, "a full green run: exit 0\n" .. nosecret.err)
  eq(nosecret.last, SENTINEL, "and the sentinel, as any full green run")
  has(nosecret.err, "stamp: written", "the stamp is announced")
  local st = stamp_of(root)
  eq(#st.files, 2, "both spec files are listed")
  ok(st.files[1].key and st.files[2].key, "both have a key")
  eq(st.origin, { kind = "local", trusted = false }, "written locally")
  eq(#st.head.commit, 40, "the commit is recorded")
  eq(
    vim.trim(git(root, "rev-parse", "HEAD:./")),
    st.head.tree,
    "and the tree (what a note or a later check can compare)"
  )
  ok(st.head.dirty ~= true, "from a clean tree")
  local text = read(stamp.path(root, { state_dir = state_dir }))
  ok(
    not text:find(vim.pesc(tmp:gsub("/", "\\")), 1) and not text:find(tmp, 1, true),
    "no absolute path in the stamp"
  )

  -- ---------------------------------------------------------------- verified: the only green answer
  local before = snapshot()
  local v = run({ "verify", root })
  eq(v.code, 0, "unchanged: exit 0\n" .. v.out .. v.err)
  has(
    v.out,
    "verified: unchanged since the green stamp of run",
    "verified, with the run it is based on"
  )
  has(v.out, "2 of 2 files proven", "and the count")
  eq(v.last, SENTINEL, "the sentinel is the last line")
  eq(snapshot(), before, "verify writes nothing (no cache entry, no history, no stamp)")
  local vj = verify_json({ "verify", root, "--json" })
  eq({ vj.status, vj.verified, vj.exit_code }, { "verified", true, 0 }, "the JSON says the same")
  eq(vj.counts, { files = 2, proven = 2, not_provable = 0, changed = 0 }, "with the counts")
  eq(vj.same_tree, true, "the tree is the stamp's tree")
  local vjr = run({ "verify", root, "--json" })
  eq(vjr.code, 0, "--json: the exit code is the verdict's")
  lacks(vjr.out, SENTINEL, "--json prints a document, not a sentinel")

  -- ---------------------------------------------------------------- git that does not answer is never green
  clock.git = function()
    return { code = 128, stdout = "", stderr = "fatal: broken" }
  end
  local nogit = verify_json({ "verify", root, "--json" })
  ok(nogit.status ~= "verified", "git failing while the stamp names a tree: never verified")
  eq(nogit.verified, false, "and not green")
  eq(nogit.status, "rejected", "rejected, with a clear message")
  has(nogit.reason, "git did not answer", "says why")
  ok(run({ "verify", root }).last ~= SENTINEL, "git failing: no sentinel")
  clock.git = nil

  -- ---------------------------------------------------------------- age
  clock.now = st.head.ts + 8 * 86400
  local old = verify_json({ "verify", root, "--json" })
  eq(old.status, "expired", "older than 7 days: expired")
  eq(old.exit_code, 1, "expired is not green")
  ok(run({ "verify", root }).last ~= SENTINEL, "expired: no sentinel")
  eq(
    verify_json({ "verify", root, "--json", "--max-age", "30d" }).status,
    "verified",
    "--max-age 30d lets it pass"
  )
  clock.now = st.head.ts + 3600
  eq(
    verify_json({ "verify", root, "--json", "--max-age", "30m" }).status,
    "expired",
    "--max-age 30m: an hour is too old"
  )
  eq(run({ "verify", root, "--max-age", "soon" }).code, 2, "a bad duration is a usage error")
  clock.now = st.head.ts - 10000
  local future = verify_json({ "verify", root, "--json" })
  eq(future.status, "invalid", "a stamp from the future is not believed")
  has(future.reason, "future", "and says so")
  clock.now = nil

  -- ---------------------------------------------------------------- dirty tree
  write(root .. "/lua/proj/mod.lua", "return { value = 1, extra = true }\n")
  local dirty = verify_json({ "verify", root, "--json" })
  eq(dirty.status, "dirty", "uncommitted changes: dirty")
  has(dirty.reason, "mod.lua", "names the change")
  has(dirty.reason, "--allow-dirty", "and the explicit way to overrule")
  ok(run({ "verify", root }).last ~= SENTINEL, "dirty: no sentinel")
  local over = verify_json({ "verify", root, "--json", "--allow-dirty" })
  eq(over.status, "changed", "--allow-dirty checks the working tree: the module changed")
  eq(#over.changed, 1, "one file changed")
  eq(over.changed[1].file, "TESTS/c_spec.lua", "the spec that loads the module, not the pure one")
  eq(over.counts.proven, 1, "the other file is still proven")
  local over_text = run({ "verify", root, "--allow-dirty" })
  eq(over_text.code, 1, "changed: exit 1")
  ok(over_text.last ~= SENTINEL, "changed: no sentinel")
  has(over_text.out, "changed:", "changed is said first")
  has(over_text.out, "TESTS/c_spec.lua", "and names the file")
  git(root, "checkout", "--", "lua/proj/mod.lua")
  eq(
    verify_json({ "verify", root, "--json" }).status,
    "verified",
    "the change undone: verified again"
  )
  -- an untracked file is a change of the tree as well
  write(root .. "/notes.txt", "x\n")
  eq(
    verify_json({ "verify", root, "--json" }).status,
    "dirty",
    "an untracked file makes the tree dirty"
  )
  vim.fn.delete(root .. "/notes.txt")

  -- ---------------------------------------------------------------- a changed file of the closure, with the explanation
  local cached_stamp = run({ "stamp", root, "--cached" })
  local base = vim.trim(git(root, "rev-parse", "HEAD"))
  eq(cached_stamp.code, 0, "a cached stamp run is green\n" .. cached_stamp.err)
  write(root .. "/lua/proj/mod.lua", "return { value = 2 }\n")
  commit_all(root, "change the module")
  local changed = verify_json({ "verify", root, "--json" })
  eq(
    changed.status,
    "changed",
    "a committed change of a required module: changed (no --allow-dirty needed)"
  )
  eq(changed.changed[1].file, "TESTS/c_spec.lua", "the spec that loads it")
  eq(changed.changed[1].change, "changed", "its key changed")
  local named = false
  for _, d in ipairs(changed.changed[1].details or {}) do
    named = named or d.name == "lua/proj/mod.lua"
  end
  ok(named, "the explanation names the module: " .. vim.inspect(changed.changed[1].details))
  ok(
    changed.rerun and changed.rerun.command:find("--file TESTS/c_spec.lua", 1, true),
    "and the command to run it"
  )
  eq(changed.same_tree, false, "and the tree is not the stamp's tree")
  -- verify says "changed" for a stamp whose tree is no longer HEAD's; the key decides, not the tree
  git(root, "revert", "--no-edit", "HEAD")
  eq(
    verify_json({ "verify", root, "--json" }).status,
    "verified",
    "reverted: the keys are the stamp's again, verified"
  )

  -- a new file and a vanished file
  write(root .. "/TESTS/d_spec.lua", PURE)
  commit_all(root, "add d")
  local added = verify_json({ "verify", root, "--json" })
  eq(added.status, "changed", "a spec file the stamp does not know: changed")
  eq(
    { added.changed[1].file, added.changed[1].change },
    { "TESTS/d_spec.lua", "new" },
    "named as new"
  )
  git(root, "rm", "-q", "TESTS/a_spec.lua")
  git(root, "commit", "-q", "-m", "drop a")
  local gone = verify_json({ "verify", root, "--json" })
  eq(gone.status, "changed", "a spec file of the stamp that is gone: changed")
  eq(
    { gone.changed[1].file, gone.changed[1].change },
    { "TESTS/a_spec.lua", "gone" },
    "named as gone"
  )
  git(root, "reset", "-q", "--hard", base)
  eq(
    verify_json({ "verify", root, "--json" }).status,
    "verified",
    "back at the stamped state: verified"
  )

  -- ---------------------------------------------------------------- a key that gave different results proves nothing
  do
    local a_key
    for _, f in ipairs(stamp_of(root).files) do
      if f.file == "TESTS/a_spec.lua" then
        a_key = f.key
      end
    end
    local keylog = require("testing.cache.keylog")
    local log = keylog.load(root, { state_dir = state_dir })
    log:observe("TESTS/a_spec.lua", a_key, "pass", "r1", 1700000000)
    log:observe("TESTS/a_spec.lua", a_key, "fail", "r2", 1700000100)
    ok(log:save(), "the key log is saved")
    local flip = verify_json({ "verify", root, "--json" })
    eq(
      flip.status,
      "partial",
      "a key that has given different results is not a proof: partial, never verified"
    )
    eq(flip.not_provable[1].file, "TESTS/a_spec.lua", "it names the file")
    has(flip.not_provable[1].reason, "nondeterministic", "and why")
    eq(flip.not_provable[1].from, "now", "found now, not at the stamp")
    keylog.clear(root, { state_dir = state_dir })
    eq(
      verify_json({ "verify", root, "--json" }).status,
      "verified",
      "the log forgotten: verified again"
    )
  end

  -- ---------------------------------------------------------------- foreign and forged stamps
  local path = stamp.path(root, { state_dir = state_dir })
  local good = stamp_of(root)
  local forged_path = tmp .. "/forged.json"
  ---@param mutate fun(raw: table)
  ---@return table doc
  local function forged(mutate)
    local raw = vim.json.decode(read(path))
    mutate(raw)
    write(forged_path, vim.json.encode(raw))
    return (verify_json({ "verify", root, "--json", "--stamp", forged_path }))
  end
  local doc = forged(function(r)
    r.files[1].key = ("0"):rep(64)
  end)
  eq(doc.status, "invalid", "a key edited without a new digest: invalid")
  has(doc.reason, "digest", "the digest gives it away")
  write(forged_path, ("x"):rep(stamp.MAX_BYTES + 1))
  doc = verify_json({ "verify", root, "--json", "--stamp", forged_path })
  eq(doc.status, "invalid", "an over-size file: invalid")
  has(doc.reason, "larger than", "says why")
  write(forged_path, "{ not json")
  eq(
    verify_json({ "verify", root, "--json", "--stamp", forged_path }).status,
    "invalid",
    "not JSON: invalid"
  )
  write(forged_path, vim.json.encode({ schema = "testing-stamp/9", v = 9 }))
  eq(
    verify_json({ "verify", root, "--json", "--stamp", forged_path }).status,
    "invalid",
    "another schema: invalid"
  )

  -- a forger who recomputes the digest: the HMAC is what stops him
  ---@param mutate fun(rec: table)
  ---@param secret? string
  local function resigned(mutate, secret)
    local copy = vim.deepcopy(good)
    mutate(copy)
    local rebuilt = stamp.build({
      head = copy.head,
      origin = copy.origin,
      env = copy.env,
      records = copy.files,
      secret = secret,
    })
    write(forged_path, (stamp.encode(rebuilt)))
    return (verify_json({ "verify", root, "--json", "--stamp", forged_path }))
  end
  doc = resigned(function() end)
  eq(
    doc.status,
    "verified",
    "an honest rebuild of the same facts verifies (no secret: the digest is all there is)"
  )
  local SECRET = ("s3cret-"):rep(4)
  E.TESTING_STAMP_SECRET = SECRET
  eq(
    resigned(function() end).status,
    "untrusted",
    "a secret is set, the stamp has no HMAC: untrusted"
  )
  has(resigned(function() end).reason, "no HMAC", "says so")
  eq(
    resigned(function() end, ("other-secret-"):rep(2)).status,
    "untrusted",
    "another secret's HMAC: untrusted"
  )
  eq(resigned(function() end, SECRET).status, "verified", "the right secret: verified")
  doc = resigned(function() end, SECRET)
  eq(doc.hmac, "checked", "and it says the HMAC was checked")
  lacks(vim.json.encode(doc), SECRET, "the secret is nowhere in the answer")
  -- a real signed stamp, then an edit that keeps the old HMAC
  local signed = run({ "stamp", root, "--out", tmp .. "/signed.json" })
  eq(signed.code, 0, "stamp --out under a secret: green\n" .. signed.err)
  lacks(signed.err .. signed.out, SECRET, "the secret is never printed")
  ok(vim.json.decode(read(tmp .. "/signed.json")).hmac, "and the stamp carries an HMAC")
  eq(
    verify_json({ "verify", root, "--json", "--stamp", tmp .. "/signed.json" }).status,
    "verified",
    "a signed stamp verifies under its secret"
  )
  E.TESTING_STAMP_SECRET = nil
  doc = verify_json({ "verify", root, "--json", "--stamp", tmp .. "/signed.json" })
  eq(
    doc.status,
    "verified",
    "without the secret the HMAC is not checked, the stamp still verifies by its keys"
  )
  eq(doc.hmac, "unchecked", "and the answer says the HMAC was not checked")
  eq(
    verify_json({ "verify", root, "--json", "--require-hmac", "--stamp", tmp .. "/signed.json" }).status,
    "untrusted",
    "--require-hmac without a secret: untrusted"
  )
  E.TESTING_STAMP_SECRET = "tiny"
  eq(run({ "verify", root }).code, 2, "a too short secret is refused (usage), not silently ignored")
  eq(run({ "stamp", root }).code, 2, "also for stamp, before the run")
  E.TESTING_STAMP_SECRET = nil

  -- other conditions: the cause is named
  doc = resigned(function(r)
    r.env.os = "Plan9/mips"
  end)
  eq(doc.status, "rejected", "a stamp of another OS: rejected")
  has(table.concat(doc.causes, "\n"), "OS/architecture: Plan9/mips ->", "with the cause")
  doc = resigned(function(r)
    r.env.nvim = "v0.1.0|api1"
  end)
  eq(doc.status, "rejected", "another Neovim: rejected")
  has(table.concat(doc.causes, "\n"), "Neovim: v0.1.0|api1 ->", "with the versions")
  -- two builds of a nightly differ at the END of the text: the cause shows it whole, not cut to the first twelve characters
  local nvim_now = require("testing.stamp.collect").environment({ config_digest = "x" }).nvim
  doc = resigned(function(r)
    r.env.nvim = "0.13.0-dev+g1a2b3c4d5e6f|api15"
  end)
  has(
    table.concat(doc.causes, "\n"),
    "Neovim: 0.13.0-dev+g1a2b3c4d5e6f|api15 -> " .. nvim_now,
    "a long Neovim text is shown whole, on both sides"
  )
  doc = resigned(function(r)
    r.env.config = ("9"):rep(64)
  end)
  eq(doc.status, "rejected", "another configuration: rejected")
  has(table.concat(doc.causes, "\n"), "configuration", "with the cause")
  doc = resigned(function(r)
    r.env.runner = ("8"):rep(64)
  end)
  eq(doc.status, "rejected", "another runner: rejected")
  has(table.concat(doc.causes, "\n"), "runner", "with the cause")
  ok(run({ "verify", root, "--stamp", forged_path }).last ~= SENTINEL, "rejected: no sentinel")
  -- the options of the run are part of the configuration digest
  local cfg_run = run({ "verify", root, "--json", "--isolated", "file" })
  local cfg_doc = vim.json.decode(cfg_run.out)
  ok(
    cfg_doc.status == "rejected" or cfg_doc.status == "verified",
    "options of the run are accepted by verify"
  )

  -- ---------------------------------------------------------------- trust: where a stamp counts
  E.CI = "true"
  doc = verify_json({ "verify", root, "--json" })
  eq(doc.status, "untrusted", "in CI a local stamp is not accepted")
  has(doc.reason, "local stamp", "says why")
  E.GITHUB_EVENT_NAME, E.GITHUB_REF = "pull_request", "refs/pull/1/merge"
  local ci_pr = run({ "stamp", root, "--out", tmp .. "/ci-pr.json" })
  eq(ci_pr.code, 0, "a CI stamp run is green\n" .. ci_pr.err)
  eq(
    vim.json.decode(read(tmp .. "/ci-pr.json")).origin.trusted,
    false,
    "from a pull request: not trusted"
  )
  doc = verify_json({ "verify", root, "--json", "--stamp", tmp .. "/ci-pr.json" })
  eq(doc.status, "untrusted", "a stamp a pull request wrote is not accepted in CI")
  has(doc.reason, "pull_request", "names the event")
  E.GITHUB_EVENT_NAME, E.GITHUB_REF = "push", "refs/heads/main"
  local ci_main = run({ "stamp", root, "--out", tmp .. "/ci-main.json" })
  eq(ci_main.code, 0, "a push to main writes a stamp\n" .. ci_main.err)
  eq(vim.json.decode(read(tmp .. "/ci-main.json")).origin.trusted, true, "trusted")
  doc = verify_json({ "verify", root, "--json", "--stamp", tmp .. "/ci-main.json" })
  eq(doc.status, "untrusted", "in CI an unsigned stamp is never green, even a trusted-origin one")
  has(doc.reason, "--allow-unsigned", "and the explicit way out is named")
  local own_ci = vim.deepcopy(good)
  own_ci.origin = { kind = "ci", trusted = true, event = "push", ref = "refs/heads/main" }
  write(tmp .. "/self-ci.json", (stamp.encode(stamp.build({
    head = own_ci.head,
    origin = own_ci.origin,
    env = own_ci.env,
    records = own_ci.files,
  }))))
  eq(
    verify_json({ "verify", root, "--json", "--stamp", tmp .. "/self-ci.json" }).status,
    "untrusted",
    "a self-built CI/trusted stamp without an HMAC is not green"
  )
  doc =
    verify_json({ "verify", root, "--json", "--allow-unsigned", "--stamp", tmp .. "/ci-main.json" })
  eq(
    doc.status,
    "verified",
    "a stamp CI wrote on a trusted ref is accepted in CI with --allow-unsigned"
  )
  has(
    table.concat(doc.notes, "\n"),
    "authenticity",
    "with the note that without an HMAC the transport is what is trusted"
  )
  -- a forged CI stamp: edited to say trusted, digest recomputed, HMAC required: refused
  E.TESTING_STAMP_SECRET = SECRET
  doc = verify_json({ "verify", root, "--json", "--stamp", tmp .. "/ci-main.json" })
  eq(doc.status, "untrusted", "with a secret set an unsigned CI stamp is refused")
  E.TESTING_STAMP_SECRET = nil
  E.CI, E.GITHUB_EVENT_NAME, E.GITHUB_REF = nil, nil, nil
  doc = verify_json({ "verify", root, "--json", "--stamp", tmp .. "/ci-main.json" })
  eq(doc.status, "untrusted", "a CI stamp is not accepted on a developer machine")

  -- ---------------------------------------------------------------- git notes: the stamp on the tree
  local noted = run({ "stamp", root, "--note" })
  eq(noted.code, 0, "stamp --note: green\n" .. noted.err)
  has(noted.err, "git note refs/notes/testing", "the note is announced")
  local tree = vim.trim(git(root, "rev-parse", "HEAD:./"))
  ok(
    vim.trim(git(root, "notes", "--ref=testing", "list", tree)) ~= "",
    "a note is listed for the tree"
  )
  eq(
    verify_json({ "verify", root, "--json", "--from-note" }).status,
    "verified",
    "verify --from-note reads it back"
  )
  vim.fn.delete(path)
  eq(
    verify_json({ "verify", root, "--json", "--from-note" }).status,
    "verified",
    "(the file is not needed any more)"
  )
  -- the git facts (three git processes) are asked once, not once for the note and once for the tree comparison
  do
    local real_git = require("testing.affected.git").default_run
    local head_calls = 0
    clock.git = function(argv, cwd)
      if argv[2] == "rev-parse" and argv[3] == "HEAD" then
        head_calls = head_calls + 1
      end
      return real_git(argv, cwd)
    end
    eq(
      verify_json({ "verify", root, "--json", "--from-note" }).status,
      "verified",
      "verify --from-note with a counting git"
    )
    clock.git = nil
    eq(
      head_calls,
      1,
      "the facts of the tree are asked once (the note lookup and the comparison share them)"
    )
  end
  write(root .. "/lua/proj/mod.lua", "return { value = 3 }\n")
  commit_all(root, "another tree")
  doc = verify_json({ "verify", root, "--json", "--from-note" })
  eq(doc.status, "no-stamp", "another tree has no note: no-stamp")
  git(root, "reset", "-q", "--hard", "HEAD~1")

  -- ================================================================ a partial proof is never green
  local clock_root =
    project("clk", { ["a_spec.lua"] = PURE, ["b_spec.lua"] = CLOCK, ["c_spec.lua"] = USES_MOD })
  local clk = run({ "stamp", clock_root })
  eq(clk.code, 0, "a suite with a clock spec still earns a stamp\n" .. clk.err)
  has(clk.err, "1 file(s) have no cache key", "and is told what verify will say")
  local cst = stamp_of(clock_root)
  eq(#cst.files, 3, "all three files are listed")
  local unc = {}
  for _, f in ipairs(cst.files) do
    if f.uncacheable then
      unc[#unc + 1] = f.file
    end
  end
  eq(unc, { "TESTS/b_spec.lua" }, "the clock spec is listed with its reason, not with a key")
  local part = verify_json({ "verify", clock_root, "--json" })
  eq(part.status, "partial", "a partial proof: partial")
  eq(part.verified, false, "never verified")
  eq(part.exit_code, 1, "exit 1")
  eq(part.counts, { files = 3, proven = 2, not_provable = 1, changed = 0 }, "2 of 3 proven")
  eq(part.not_provable[1].file, "TESTS/b_spec.lua", "names the file")
  has(part.not_provable[1].reason, "clock", "and why")
  ok(
    part.rerun and part.rerun.command:find("--file TESTS/b_spec.lua", 1, true),
    "and the command to run it"
  )
  local part_text = run({ "verify", clock_root })
  eq(part_text.code, 1, "partial: exit 1")
  ok(part_text.last ~= SENTINEL, "partial: no sentinel")
  lacks(part_text.out, SENTINEL, "partial: the sentinel is nowhere")
  has(part_text.out, "partial: 2 of 3 files proven", "the first line says how much")
  has(part_text.out, "(not green)", "and that it is not green")
  -- a change on top of a partial proof: changed wins
  write(clock_root .. "/lua/proj/mod.lua", "return { value = 5 }\n")
  commit_all(clock_root, "change")
  eq(
    verify_json({ "verify", clock_root, "--json" }).status,
    "changed",
    "changed is said before partial"
  )

  -- ================================================================ no stamp without a complete green run
  local red_root = project("red", {
    ["a_spec.lua"] = PURE,
    ["f_spec.lua"] = "return function(H)\n  H.ok(false, 'fails')\nend\n",
  })
  local red = run({ "stamp", red_root })
  eq(red.code, 1, "a red run: exit 1")
  has(red.err, "stamp: not written", "says no stamp")
  ok(not vim.uv.fs_stat(stamp.path(red_root, { state_dir = state_dir })), "and writes none")
  local skip_root = project("skp", {
    ["a_spec.lua"] = PURE,
    ["s_spec.lua"] = "describe('s', function()\n  it('later')\n  it('now', function() assert.is_true(true) end)\nend)\n",
  })
  local skipped = run({ "stamp", skip_root, "--isolated", "none" })
  eq(skipped.code, 1, "a skipped case is green-partial: no stamp, so exit 1 (asked for, not given)")
  has(skipped.err, "not a complete green run", "says why")
  ok(not vim.uv.fs_stat(stamp.path(skip_root, { state_dir = state_dir })), "and writes none")
  -- an old stamp is not overwritten by a failed attempt
  local keep = project("keep", { ["a_spec.lua"] = PURE })
  eq(run({ "stamp", keep }).code, 0, "(a stamp for keep)")
  local keep_before = read(stamp.path(keep, { state_dir = state_dir }))
  write(keep .. "/TESTS/f_spec.lua", "return function(H)\n  H.ok(false, 'fails')\nend\n")
  eq(run({ "stamp", keep }).code, 1, "a red run after it")
  eq(
    read(stamp.path(keep, { state_dir = state_dir })),
    keep_before,
    "the earlier stamp is untouched"
  )

  -- ================================================================ an input that changes while the run goes
  -- the spec passes against the old content of a module and rewrites it: the run was green for content that is gone,
  -- and a stamp of the NEW content would let `verify` call a tree proven that never ran
  do
    local toctou_root = tmp .. "/toctou"
    local rewriter = (
      "return function(H)\n"
      .. "  H.ok(require('proj.mod').value == 1, 'the module as it was')\n"
      .. "  local f = assert(io.open(%q, 'wb'))\n"
      .. "  f:write('return { value = 999 }\\n')\n"
      .. "  f:close()\n"
      .. "end\n"
    ):format(toctou_root .. "/lua/proj/mod.lua")
    local troot = project("toctou", { ["a_spec.lua"] = PURE, ["c_spec.lua"] = rewriter })
    eq(troot, toctou_root, "(the path the spec rewrites)")
    local moved = run({ "stamp", troot })
    eq(moved.code, 1, "an input changed while the run was going: no stamp, exit 1\n" .. moved.err)
    has(moved.err, "stamp: not written: an input changed while the run was going", "says why")
    has(moved.err, "TESTS/c_spec.lua", "and names the file")
    ok(moved.last ~= SENTINEL, "no sentinel")
    ok(not vim.uv.fs_stat(stamp.path(troot, { state_dir = state_dir })), "and writes none")
    eq(
      read(troot .. "/lua/proj/mod.lua"),
      "return { value = 999 }\n",
      "(the module is the new one now)"
    )
    -- the change is committed: nothing can be called verified, there is no stamp for any content
    commit_all(troot, "the rewritten module")
    local after = verify_json({ "verify", troot, "--json" })
    eq(after.status, "no-stamp", "verify has nothing to prove the rewritten tree with")
    eq(after.verified, false, "and says not verified")
    -- with --out the same: no file
    local out_file = tmp .. "/toctou-out.json"
    write(troot .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    commit_all(troot, "back")
    eq(run({ "stamp", troot, "--out", out_file }).code, 1, "--out: the same refusal")
    ok(not vim.uv.fs_stat(out_file), "--out: no file either")
  end

  -- ================================================================ keys are computed after the minit of the project
  -- a minit puts a directory on the runtime path that no `deps` entry names; the keys of a run look at that path, so
  -- `verify` and `explain` have to run the minit too, or they compute other keys than the run (always `changed`)
  do
    local ext = tmp .. "/extdep"
    write(ext .. "/lua/extmod.lua", "return { value = 7 }\n")
    local minit_cfg =
      "return { plugin = 'proj', minit = 'TESTS/minit.lua', guards = { fs = 'off' } }\n"
    local mroot = project("minit", {
      ["minit.lua"] = ("vim.opt.runtimepath:append(%q)\n"):format(ext),
      ["a_spec.lua"] = "return function(H)\n  H.ok(require('extmod').value == 7, 'a module of the minit')\nend\n",
    }, minit_cfg)
    ---A fresh process does not have what the minit of an earlier command put on the runtime path.
    local function fresh_process()
      vim.opt.runtimepath:remove(ext)
      package.loaded.extmod = nil
    end
    local made = run({ "stamp", mroot })
    eq(made.code, 0, "a spec that needs a module of the minit's runtime path: green\n" .. made.err)
    fresh_process()
    local mv = verify_json({ "verify", mroot, "--json" })
    eq(
      mv.status,
      "verified",
      "verify in a fresh process gets the same keys: " .. vim.inspect(mv.changed)
    )
    eq(mv.exit_code, 0, "exit 0")
    fresh_process()
    local mx = run({ "explain", mroot, "a_spec", "--json" })
    local mdoc = vim.json.decode(mx.out)
    eq(mx.code, 0, "explain works\n" .. mx.err)
    eq(
      mdoc.specs[1].key,
      stamp_of(mroot).files[1].key,
      "and explains the key of the run, not another one"
    )
    fresh_process()
    local mtext = run({ "explain", mroot, "a_spec", "--parts" })
    lacks(mtext.out, "absent extmod", "the module of the minit is found, not 'absent'")
    -- a minit that fails: the keys cannot be computed the way a run computes them
    write(mroot .. "/TESTS/minit.lua", "error('boom of the minit')\n")
    commit_all(mroot, "a broken minit")
    fresh_process()
    local broken = verify_json({ "verify", mroot, "--json" })
    eq(broken.status, "rejected", "a minit that fails: rejected, never green")
    has(broken.reason, "boom of the minit", "with its message")
    eq(broken.verified, false, "not verified")
    local broken_explain = run({ "explain", mroot, "a_spec" })
    eq(broken_explain.code, 3, "explain: an internal failure, as a run with a broken minit")
    has(broken_explain.err, "boom of the minit", "with its message")
    fresh_process()
  end

  -- ================================================================ a spec that changes the runtime path of the editor
  -- an in-process spec shares the editor with the runner: what it adds to the runtime path is no input that moved, so
  -- the keys of after the run are computed with the runtime path of before it (else no such project gets a stamp)
  do
    local ext = tmp .. "/extdep2"
    write(ext .. "/lua/extmod2.lua", "return { value = 1 }\n")
    local leaker = (
      "return function(H)\n"
      .. "  vim.opt.runtimepath:append(%q)\n"
      .. "  H.ok(pcall(require, 'extmod2'), 'the module of the path the spec added')\n"
      .. "end\n"
    ):format(ext)
    local lroot = project("leak", { ["a_spec.lua"] = leaker })
    local lres = run({ "stamp", lroot })
    vim.opt.runtimepath:remove(ext)
    package.loaded.extmod2 = nil
    eq(lres.code, 0, "a spec that appends to the runtime path still earns a stamp\n" .. lres.err)
    eq(
      verify_json({ "verify", lroot, "--json" }).status,
      "verified",
      "and a fresh process verifies it (the keys are the keys of before the run)"
    )
  end

  -- ================================================================ many changed key lines of one file stay short
  do
    local big_files = {}
    local requires = {}
    for i = 1, 60 do
      big_files["lua/proj/big/m" .. i .. ".lua"] = "return { n = " .. i .. " }\n"
      requires[#requires + 1] = "require('proj.big.m" .. i .. "')"
    end
    local big_root = project("big", {
      ["a_spec.lua"] = "return function(H)\n  "
        .. table.concat(requires, "\n  ")
        .. "\n  H.ok(true, 'loaded')\nend\n",
    })
    for rel, body in pairs(big_files) do
      write(big_root .. "/" .. rel, body)
    end
    commit_all(big_root, "the closure")
    eq(
      run({ "stamp", big_root, "--cached" }).code,
      0,
      "(a cached stamp of a spec with a big closure)"
    )
    -- the spec no longer loads any of them: 60 key lines are gone
    write(big_root .. "/TESTS/a_spec.lua", PURE)
    commit_all(big_root, "no closure")
    local no_closure = verify_json({ "verify", big_root, "--json" })
    eq(no_closure.status, "changed", "the closure is gone: changed")
    local json_details = no_closure.changed[1].details or {}
    ok(#json_details >= 60, "the JSON lists every key line: " .. #json_details)
    local text_out = run({ "verify", big_root })
    local lines = vim.split(text_out.out, "\n", { plain = true })
    local detail_lines = 0
    for _, l in ipairs(lines) do
      if l:find("^      %S") then
        detail_lines = detail_lines + 1
      end
    end
    ok(
      detail_lines <= 10,
      "at most a handful of key lines for one file, plus the line that counts the rest: "
        .. detail_lines
    )
    ok(#lines < 20, "the whole answer is short: " .. #lines .. " lines")
    has(text_out.out, "more key line(s)", "the rest is counted")
    has(text_out.out, "testing explain TESTS/a_spec.lua --parts", "and where to find them")
  end

  -- ================================================================ .deps/ is no change of the project
  do
    local deps_root = project("depsdirty", { ["a_spec.lua"] = PURE })
    eq(run({ "stamp", deps_root }).code, 0, "(a stamp)")
    -- the checkout of a dependency, as CI makes it below the project directory, not ignored
    local dep = deps_root .. "/.deps/lib.nvim"
    write(dep .. "/lua/lib.lua", "return {}\n")
    git(dep, "init", "-q", "-b", "main")
    git(dep, "add", "-A")
    git(dep, "commit", "-q", "-m", "dep")
    eq(
      vim.trim(git(deps_root, "status", "--porcelain")),
      "?? .deps/",
      "(git does see it as untracked)"
    )
    eq(
      verify_json({ "verify", deps_root, "--json" }).status,
      "verified",
      ".deps/ does not make the tree dirty"
    )
    write(deps_root .. "/notes.txt", "x\n")
    eq(
      verify_json({ "verify", deps_root, "--json" }).status,
      "dirty",
      "any other untracked file still does"
    )
  end

  vim.fn.delete(tmp, "rf")
end
