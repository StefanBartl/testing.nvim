-- TESTS/testing/trust_spec.lua -- workspace trust (`testing.trust`, docs/CONFIG.md "Workspace trust"): the store is
-- untrusted data (SEC-33: every hostile shape is no trust and never an error), a changed `.testing.lua` is a new
-- question, roots are compared resolved (SEC-40), CI / TESTING_TRUST / TESTING_TRUST_ROOTS decide as documented, the
-- gate is armed by the entry only and `--trust` stores, and `testing trust list|check|add|revoke` behave as documented.

---@diagnostic disable: missing-fields

return function(H)
  local trust = require("testing.trust")
  local eq, ok, has = H.eq, H.ok, H.has

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-trust"
  vim.fn.mkdir(base, "p")
  local store = base .. "/state/trust.json"
  local proj = base .. "/proj"
  vim.fn.mkdir(proj, "p")
  local cfg_file = proj .. "/.testing.lua"
  -- a spec, so that `list` has something to list (it never runs it)
  local spec_file = proj .. "/TESTS/a_spec.lua"

  ---@param path string
  ---@param text string
  local function put(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param extra? table
  ---@return Testing.Trust.Ctx
  local function ctx(extra)
    return vim.tbl_extend("force", { env = {}, store = store }, extra or {})
  end

  -- the list separator of TESTING_TRUST_ROOTS on this OS (like PATH)
  local sep = vim.fn.has("win32") == 1 and ";" or ":"

  local ok_all, err = pcall(function()
    -- --------------------------------------------------------------- nothing trusted: unknown
    local d = trust.decide(proj, ctx())
    eq(d.trusted, false, "an empty store trusts nothing")
    eq(d.why, "unknown", "an empty store: unknown")

    -- --------------------------------------------------------------- environment
    eq(trust.decide(proj, ctx({ env = { CI = "true" } })).how, "ci", "CI=true trusts")
    eq(trust.decide(proj, ctx({ env = { CI = "1" } })).how, "ci", "CI=1 trusts")
    eq(trust.decide(proj, ctx({ env = { CI = "false" } })).trusted, false, "CI=false does not")
    eq(trust.decide(proj, ctx({ env = { CI = "0" } })).trusted, false, "CI=0 does not")
    eq(trust.decide(proj, ctx({ env = { CI = "" } })).trusted, false, "an empty CI does not")
    eq(trust.decide(proj, ctx({ env = { TESTING_TRUST = "1" } })).how, "env", "TESTING_TRUST=1")
    eq(
      trust.decide(proj, ctx({ env = { TESTING_TRUST = "yes" } })).trusted,
      false,
      "only TESTING_TRUST=1 trusts"
    )
    eq(
      trust.decide(proj, ctx({ env = { TESTING_TRUST_ROOTS = "/nowhere" .. sep .. base } })).how,
      "root",
      "a directory of TESTING_TRUST_ROOTS trusts what is below it"
    )
    local rel =
      trust.decide(proj, ctx({ env = { TESTING_TRUST_ROOTS = "." .. sep .. "relative/dir" } }))
    eq(rel.trusted, false, "relative entries of TESTING_TRUST_ROOTS never trust (cwd-dependent)")
    eq(#rel.notes, 2, "each dropped relative entry is named")
    eq(
      trust.split_roots("C:/a;D:/b", { is_win = true }),
      { "C:/a", "D:/b" },
      "Windows separates TESTING_TRUST_ROOTS with ';' (a drive colon stays)"
    )
    eq(
      trust.decide(proj, ctx({ env = { TESTING_TRUST_ROOTS = base .. "-sibling" } })).trusted,
      false,
      "a sibling with the same prefix is not below the root"
    )

    -- --------------------------------------------------------------- add, hash, changed, revoke
    put(cfg_file, "return { plugin = 'p' }\n")
    local added, key = trust.add(proj, ctx())
    ok(added, "add: " .. tostring(key))
    d = trust.decide(proj, ctx())
    eq(d.how, "store", "a stored root with the same .testing.lua is trusted")
    put(cfg_file, "return { plugin = 'q' }\n")
    d = trust.decide(proj, ctx())
    eq(d.trusted, false, "a changed .testing.lua is a new question")
    eq(d.why, "changed", "the reason is the change")
    has(trust.refusal(proj, d), "changed since it was trusted", "the refusal names the change")
    os.remove(cfg_file)
    eq(trust.decide(proj, ctx()).why, "changed", "a removed .testing.lua is a change too")
    ok(trust.add(proj, ctx()), "trusted without a .testing.lua")
    eq(trust.decide(proj, ctx()).how, "store", "trusted as 'none'")
    put(cfg_file, "return {}\n")
    eq(trust.decide(proj, ctx()).why, "changed", "a .testing.lua that appears later is a change")
    ok(trust.add(proj, ctx()), "re-add")
    eq(#trust.read(store), 1, "add replaces the entry of the same root, never a second one")
    local rok, n = trust.revoke(proj, ctx())
    eq({ rok, n }, { true, 1 }, "revoke removes the entry")
    eq(trust.decide(proj, ctx()).why, "unknown", "revoked: not trusted any more")
    eq(select(2, trust.revoke(proj, ctx())), 0, "revoking again removes nothing")

    -- --------------------------------------------------------------- resolved paths (SEC-40)
    local link = base .. "/link"
    if vim.uv.fs_symlink(proj, link, { junction = true }) then
      ok(trust.add(link, ctx()), "trusted through a link")
      eq(trust.decide(proj, ctx()).how, "store", "the real path is trusted: the key is resolved")
      eq(trust.read(store)[1].root, trust.key(proj), "the stored key is the resolved root")
      trust.revoke(proj, ctx())
    end

    -- --------------------------------------------------------------- hostile store contents (SEC-33)
    local real_hash = trust.hash(proj)
    local real_key = trust.key(proj)
    local hostile = {
      { "not JSON", "{{{" },
      { "an array", "[1,2,3]" },
      { "a string", '"x"' },
      { "null", "null" },
      {
        "another version",
        vim.json.encode({ v = 2, entries = { { root = real_key, hash = real_hash } } }),
      },
      { "no version", vim.json.encode({ entries = { { root = real_key, hash = real_hash } } }) },
      { "entries a string", vim.json.encode({ v = 1, entries = "all" }) },
      {
        "a wildcard hash",
        vim.json.encode({ v = 1, entries = { { root = real_key, hash = "*" } } }),
      },
      {
        "an upper-case hash",
        vim.json.encode({ v = 1, entries = { { root = real_key, hash = real_hash:upper() } } }),
      },
      {
        "a short hash",
        vim.json.encode({ v = 1, entries = { { root = real_key, hash = "abc" } } }),
      },
      {
        "a relative root",
        vim.json.encode({ v = 1, entries = { { root = ".", hash = real_hash } } }),
      },
      {
        "a root with a newline",
        vim.json.encode({ v = 1, entries = { { root = real_key .. "\n", hash = real_hash } } }),
      },
      {
        "a root that is a list",
        vim.json.encode({ v = 1, entries = { { root = { real_key }, hash = real_hash } } }),
      },
      {
        "a negative time",
        vim.json.encode({ v = 1, entries = { { root = real_key, hash = real_hash, added = -1 } } }),
      },
      {
        "a huge root",
        vim.json.encode({
          v = 1,
          entries = { { root = "/" .. ("a"):rep(5000), hash = real_hash } },
        }),
      },
    }
    for _, case in ipairs(hostile) do
      put(store, case[2])
      local hok, hd = pcall(trust.decide, proj, ctx())
      ok(hok, case[1] .. ": decide never raises: " .. tostring(hd))
      eq(hd.trusted, false, case[1] .. ": no trust")
    end
    -- one good entry among bad ones survives, the bad ones are counted
    put(
      store,
      vim.json.encode({
        v = 1,
        entries = {
          { root = ".", hash = real_hash },
          { root = real_key, hash = real_hash, added = 1 },
          5,
        },
      })
    )
    local entries, note = trust.read(store)
    eq(#entries, 1, "the valid entry is kept")
    has(note, "2 unusable entries ignored", "the dropped entries are counted")
    eq(trust.decide(proj, ctx()).how, "store", "the valid entry still trusts")
    -- too large / not a file
    put(store, ("x"):rep(trust.MAX_BYTES + 1))
    eq(trust.decide(proj, ctx()).trusted, false, "an oversized store is no trust")
    os.remove(store)
    vim.fn.mkdir(store, "p")
    local dd = trust.decide(proj, ctx())
    eq(dd.trusted, false, "a directory in place of the store is no trust")
    has(table.concat(dd.notes, "\n"), "not a regular file", "and is named")
    vim.fn.delete(store, "d")
    -- a broken store is replaced by a good one on the next add, never merged with garbage
    put(store, "{{{")
    ok(trust.add(proj, ctx()), "add over a broken store")
    eq(#trust.read(store), 1, "the new store holds the one entry")
    os.remove(store)

    -- --------------------------------------------------------------- the gate: armed only by the entry
    eq(trust.check(proj), nil, "not armed: the library is not gated")
    local prev = trust.arm(ctx())
    local refused = trust.check(proj)
    has(refused, trust.REFUSED, "armed: an untrusted root is refused")
    has(refused, "testing trust add", "the refusal names the way out")
    eq(refused:find("\n"), nil, "the refusal is one line")
    trust.arm(ctx({ save = true, note = function() end }))
    eq(trust.check(proj), nil, "--trust: the root goes on")
    trust.arm(ctx())
    eq(trust.check(proj), nil, "--trust stored it: the next run is trusted without the flag")
    trust.arm(prev)
    os.remove(store)

    -- the CLI: services.trust arms, `--trust` is taken out of the arguments and stores
    local cli = require("testing.cli")
    put(spec_file, "return function() end\n")
    local lines = {}
    local sv = {
      out = function(s)
        lines[#lines + 1] = s
      end,
      err = function(s)
        lines[#lines + 1] = s
      end,
      trust = ctx(),
    }
    eq(cli.main({ "list", proj }, sv), 2, "cli: an untrusted root is exit 2")
    has(table.concat(lines, "\n"), trust.REFUSED, "cli: the refusal is printed")
    eq(trust.armed(), nil, "cli: the gate is disarmed after the call")
    lines = {}
    eq(cli.main({ "list", proj, "--trust" }, sv), 0, "cli: --trust runs")
    has(table.concat(lines, "\n"), "trusted from now on", "cli: --trust says it stored the root")
    eq(cli.main({ "list", proj }, sv), 0, "cli: stored, the next call runs")

    -- `testing trust ...`
    lines = {}
    eq(cli.main({ "trust", "list" }, sv), 0, "trust list")
    has(table.concat(lines, "\n"), real_key, "trust list names the stored root")
    has(table.concat(lines, "\n"), "ok", "trust list: the file is unchanged")
    lines = {}
    eq(cli.main({ "trust", "check", proj }, sv), 0, "trust check: trusted")
    eq(cli.main({ "trust", "revoke", proj }, sv), 0, "trust revoke")
    eq(cli.main({ "trust", "revoke", proj }, sv), 1, "trust revoke: nothing to revoke is 1")
    eq(cli.main({ "trust", "check", proj }, sv), 1, "trust check: not trusted is 1")
    eq(cli.main({ "trust", "add", proj }, sv), 0, "trust add")
    eq(cli.main({ "trust", "check", proj }, sv), 0, "trust check after add")
    eq(cli.main({ "trust", "bogus" }, sv), 2, "an unknown subcommand is 2")
    eq(cli.main({ "trust", "add", base .. "/nope" }, sv), 2, "a missing directory is 2")
    eq(cli.main({ "trust" }, sv), 2, "no subcommand is 2")
  end)
  trust.arm(nil)
  vim.fn.delete(base, "rf")
  if not ok_all then
    error(err, 0)
  end
end
