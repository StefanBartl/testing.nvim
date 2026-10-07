-- TESTS/testing/cache_store_spec.lua -- the result cache end to end: hit and miss, what is never stored, an
-- entry that is untrusted input when read back (corrupted, foreign, forged, oversized), the size / age /
-- count bounds, `clear` in place, `wrap_file` with `--no-cache` and `--cache-refresh`, and the hash index.

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
      msg .. " (got " .. tostring(haystack):sub(1, 300) .. ")"
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/fixtures/cache/support.lua")
  local cache = require("testing.cache")
  local store = require("testing.cache.store")
  local hash = require("testing.cache.hash")
  local result = require("testing.core.result")
  local json = require("lib.nvim.json")

  local root = S.project()
  local cdir = vim.fs.normalize(vim.fn.tempname())
  local o = { root = root, cache_dir = cdir }
  local sdir = store.dir(root, { cache_dir = cdir })
  local FILE = "TESTS/proj/a_spec.lua"

  local function key(n)
    return vim.fn.sha256("key-" .. n)
  end
  local function fresh()
    cache.reset()
    store.clear(sdir)
  end
  local function entries()
    return #store.list(sdir)
  end
  ---@param file string
  ---@param names? string[]
  local function cases(file, names)
    local out = {}
    for _, n in ipairs(names or { "one" }) do
      out[#out + 1] = S.case(file, n)
    end
    return out
  end
  local function put(k, frag, meta, opts)
    return cache.put(
      k,
      frag or cases(FILE),
      vim.tbl_extend("force", { file = FILE, run = "run-1" }, meta or {}),
      opts or o
    )
  end
  ---Write an entry file by hand (what a forged or corrupted cache holds).
  local function forge(k, text)
    vim.fn.mkdir(sdir .. "/entries", "p")
    local f = assert(io.open(store.entry_path(sdir, k), "wb"))
    f:write(text)
    f:close()
  end
  local function valid_entry(k, mut)
    local e = {
      v = 1,
      key = k,
      file = FILE,
      run = "run-forged",
      ts = os.time(),
      nvim = "0.12.0",
      cases = cases(FILE),
    }
    if mut then
      mut(e)
    end
    return e
  end

  -- ---------------------------------------------------------------- flags
  eq(cache.resolve_mode({}), "off", "off unless asked for")
  eq(cache.resolve_mode({ cached = true }), "use", "--cached")
  eq(cache.resolve_mode({ config_cached = true }), "use", "a project that switched it on")
  eq(cache.resolve_mode({ refresh = true }), "refresh", "--cache-refresh")
  eq(cache.resolve_mode({ cached = true, no_cache = true }), "off", "--no-cache wins over --cached")
  eq(
    cache.resolve_mode({ config_cached = true, no_cache = true }),
    "off",
    "--no-cache wins over the config"
  )
  eq(
    cache.resolve_mode({ refresh = true, no_cache = true }),
    "off",
    "--no-cache wins over a refresh"
  )

  -- ---------------------------------------------------------------- roundtrip
  fresh()
  local k1 = key(1)
  local stored, why = put(k1, cases(FILE, { "one", "two" }))
  ok(stored, "a clean pass is stored: " .. tostring(why))
  eq(entries(), 1, "one entry on disk")
  has(sdir, "/testing/", "below stdpath('cache')/testing")
  local got = cache.get(k1, vim.tbl_extend("force", o, { file = FILE }))
  ok(got ~= nil and #got == 2, "a hit gives the case list back")
  got = got or {}
  for _, c in ipairs(got) do
    eq(c.cached, true, "marked cached")
    eq(c.status, "pass", "the status stays pass")
    eq(c.notes[#c.notes], "cached from run-1", "the note names the run that produced the entry")
    eq(c.effects, { spawned = {}, network = {}, fs_outside_tmp = {} }, "no effects are claimed")
  end
  local res = result.new({ id = "run-2" })
  for _, c in ipairs(got) do
    result.add_case(res, c)
  end
  result.finalize(res)
  local valid, problems = result.validate(res)
  ok(valid, "a cached case list is a valid IR: " .. tostring(problems[1]))
  -- the fragment without a file name is read from the entry's own file
  ok(cache.get(k1, o) ~= nil, "get without a file")
  eq(select(2, cache.get(key(99), o)), "absent", "a miss names its reason")
  eq(cache.counters.hit, 2, "hits are counted")
  eq(cache.counters.miss, 1, "misses are counted")

  -- ---------------------------------------------------------------- never stored
  fresh()
  local failing = cases(FILE)
  failing[1].status = "fail"
  local retried = cases(FILE)
  retried[1].retries = 1
  local effect = cases(FILE)
  effect[1].effects.spawned[1] = "git status"
  local fs_effect = cases(FILE)
  fs_effect[1].effects.fs_outside_tmp[1] = "/etc/x"
  local guarded = cases(FILE)
  guarded[1].guards = { { guard = "state", severity = "warn", message = "leak" } }
  local was_cached = cases(FILE)
  was_cached[1].cached = true
  local skipped_case = cases(FILE)
  skipped_case[1].status = "skip"
  local foreign = cases("TESTS/proj/c_spec.lua")
  local not_stored = {
    { "a failing case", failing, {}, "fail" },
    { "a retried case", retried, {}, "retried" },
    { "a spawned process", effect, {}, "effects" },
    { "a write outside tmp", fs_effect, {}, "effects" },
    { "a guard finding", guarded, {}, "guard" },
    { "an already cached case", was_cached, {}, "cached" },
    { "a skipped case", skipped_case, {}, "skip" },
    { "a flaky file", cases(FILE), { flaky = true }, "flaky" },
    { "a timeout", cases(FILE), { timed_out = true }, "timed out" },
    { "a crash", cases(FILE), { crashed = true }, "crashed" },
    { "a partial run", cases(FILE), { partial = true }, "part" },
    { "no cases", {}, {}, "no cases" },
    { "a case of another file", foreign, {}, "another file" },
  }
  for _, c in ipairs(not_stored) do
    local s, w = put(key(2), c[2], c[3])
    eq(s, false, c[1] .. " is not stored")
    has(w, c[4], c[1] .. " names the reason")
  end
  eq(entries(), 0, "nothing was written")
  eq(put("not-a-key", cases(FILE)), false, "a bad key")
  ---@diagnostic disable-next-line: missing-fields
  eq(cache.put(key(3), cases(FILE), {}, o), false, "meta.file is required")
  ok(next(cache.counters.skipped) ~= nil, "what was not stored is counted by reason")

  -- ---------------------------------------------------------------- untrusted input when read back
  fresh()
  ---@param k string
  ---@param mut? fun(e: table)
  ---@return string
  local function enc(k, mut)
    return assert(json.encode(valid_entry(k, mut)))
  end
  -- { name, key number, entry text, reason that must be named }
  local bad = {
    { "garbage", 10, "this is not json {{{", "corrupt" },
    { "an empty file", 11, "", "corrupt" },
    {
      "another version",
      12,
      enc(key(12), function(e)
        e.v = 2
      end),
      "version",
    },
    { "a key that is not the name", 13, enc(key(99)), "key mismatch" },
    {
      "another file",
      14,
      enc(key(14), function(e)
        e.file = "TESTS/proj/c_spec.lua"
      end),
      "file mismatch",
    },
    {
      "a forged failing case",
      15,
      enc(key(15), function(e)
        e.cases[1].status = "fail"
      end),
      "not a pass",
    },
    {
      "a forged effect",
      16,
      enc(key(16), function(e)
        e.cases[1].effects.network = { "curl x" }
      end),
      "effects",
    },
    {
      "a case of another file",
      17,
      enc(key(17), function(e)
        e.cases[1].id = "TESTS/proj/c_spec.lua::x"
        e.cases[1].file = "TESTS/proj/c_spec.lua"
      end),
      "another file",
    },
    {
      "no cases",
      18,
      enc(key(18), function(e)
        e.cases = {}
      end),
      "case list",
    },
    {
      "a verdict that contradicts its assertions",
      19,
      enc(key(19), function(e)
        e.cases[1].assertions = { { ok = false, kind = "eq", msg = "no" } }
      end),
      "invalid IR",
    },
    {
      "a bad timestamp",
      20,
      enc(key(20), function(e)
        e.ts = -5
      end),
      "timestamp",
    },
    {
      "a case that is no object",
      21,
      enc(key(21), function(e)
        e.cases = { 5 }
      end),
      "not an object",
    },
    {
      "an error on a case",
      22,
      enc(key(22), function(e)
        e.cases[1].error = { message = "x", traceback = "y" }
      end),
      "error",
    },
  }
  for _, b in ipairs(bad) do
    local k = key(b[2])
    forge(k, b[3])
    local frag, w = cache.get(k, vim.tbl_extend("force", o, { file = FILE }))
    eq(frag, nil, b[1] .. " is a miss")
    has(w, b[4], b[1] .. " names the reason")
  end
  -- a good entry among them is still a hit
  local kg = key(40)
  forge(kg, json.encode(valid_entry(kg)))
  ok(
    cache.get(kg, vim.tbl_extend("force", o, { file = FILE })) ~= nil,
    "a well-formed forged entry validates"
  )
  -- too big: refused by size before decoding
  local kbig = key(41)
  forge(kbig, string.rep("a", store.MAX_ENTRY_BYTES + 10))
  has(
    select(2, cache.get(kbig, vim.tbl_extend("force", o, { file = FILE }))),
    "too large",
    "oversized entry"
  )
  -- a directory where the file should be
  local kdir = key(42)
  vim.fn.mkdir(store.entry_path(sdir, kdir), "p")
  has(
    select(2, cache.get(kdir, vim.tbl_extend("force", o, { file = FILE }))),
    "regular file",
    "a directory"
  )
  -- ... and a put of that key replaces the directory instead of failing for good
  eq(select(1, put(kdir)), true, "a directory in place of the entry does not block the key")
  eq(
    select(1, cache.get(kdir, vim.tbl_extend("force", o, { file = FILE }))) ~= nil,
    true,
    "and the entry is a hit afterwards"
  )
  -- `clear` removes such a directory too
  local kdir2 = key(43)
  vim.fn.mkdir(store.entry_path(sdir, kdir2) .. "/inner", "p")
  store.clear(sdir)
  eq(
    vim.uv.fs_stat(store.entry_path(sdir, kdir2)),
    nil,
    "clear removes a directory named like an entry"
  )
  -- a key that is no key never touches the file system
  eq(select(1, cache.get("../../etc/passwd", o)), nil, "a path as a key")

  -- ---------------------------------------------------------------- bounds
  fresh()
  local now = os.time()
  for i = 1, 6 do
    ok(put(key(100 + i)), "entry " .. i)
    -- entry i is (7 - i) days old: 1 is the oldest
    local t = now - (7 - i) * 86400
    vim.uv.fs_utime(store.entry_path(sdir, key(100 + i)), t, t)
  end
  eq(entries(), 6, "six entries")
  local stray = sdir .. "/entries/notes.txt"
  S.write(stray, "keep me")
  local stale_tmp = sdir .. "/entries/" .. key(1) .. ".json.atomic-tmp.1.2"
  S.write(stale_tmp, "half")
  vim.uv.fs_utime(stale_tmp, now - 7200, now - 7200)
  local r = cache.prune(vim.tbl_extend("force", o, { max_age_days = 3.5, now = now }))
  eq(r.removed_age, 3, "the three oldest are older than 3.5 days")
  eq(r.kept, 3, "three are kept")
  eq(vim.uv.fs_stat(stale_tmp), nil, "an old temp file of an interrupted write is swept")
  ok(vim.uv.fs_stat(stray) ~= nil, "a file that is not an entry is never touched")
  local one = store.list(sdir)[1].size
  local r2 = cache.prune(vim.tbl_extend("force", o, { max_bytes = one * 2 + 1, now = now }))
  eq(r2.removed_size, 1, "the byte cap removes the oldest")
  eq(r2.kept, 2, "two are kept")
  ok(vim.uv.fs_stat(store.entry_path(sdir, key(106))) ~= nil, "the newest stays")
  local r3 = cache.prune(vim.tbl_extend("force", o, { max_entries = 1, now = now }))
  eq(r3.kept, 1, "the entry cap")
  ok(vim.uv.fs_stat(store.entry_path(sdir, key(106))) ~= nil, "the newest is the one that stays")
  -- a hit renews the age
  local old = now - 20 * 86400
  vim.uv.fs_utime(store.entry_path(sdir, key(106)), old, old)
  ok(cache.get(key(106), vim.tbl_extend("force", o, { file = FILE })) ~= nil, "still readable")
  eq(
    cache.prune(vim.tbl_extend("force", o, { max_age_days = 10, now = now })).removed_age,
    0,
    "a hit refreshed the age"
  )

  -- ---------------------------------------------------------------- stats and clear in place
  fresh()
  put(key(200))
  put(key(201))
  cache.get(key(200), vim.tbl_extend("force", o, { file = FILE }))
  cache.get(key(202), vim.tbl_extend("force", o, { file = FILE }))
  local st = cache.stats(o)
  eq(st.entries, 2, "stats: entries")
  ok(st.bytes > 0, "stats: bytes")
  eq({ st.hit, st.miss, st.put }, { 1, 1, 2 }, "stats: counters")
  eq(st.dir, sdir, "stats: directory")
  S.write(sdir .. "/foreign.txt", "not ours")
  local counters, skipped_tbl = cache.counters, cache.counters.skipped
  eq(cache.clear(o), 2, "clear reports what it removed")
  eq(entries(), 0, "no entries left")
  ok(
    vim.uv.fs_stat(sdir .. "/foreign.txt") ~= nil,
    "clear touches nothing but entries and the index"
  )
  cache.reset()
  ok(counters == cache.counters and skipped_tbl == cache.counters.skipped, "reset mutates in place")
  eq({ counters.hit, counters.miss, counters.put }, { 0, 0, 0 }, "and zeroes the counters")

  -- ---------------------------------------------------------------- wrap_file
  fresh()
  local runs = 0
  local function runner()
    runs = runs + 1
    return cases(FILE, { "x", "y" })
  end
  local function ctx(over)
    return vim.tbl_extend("force", {
      root = root,
      cache_dir = cdir,
      dep_roots = {},
      runner_version = "r1",
      nvim = "0.12.0",
      config_digest = "c1",
      dialect = "a",
      run_id = "run-A",
      hasher = hash.new(),
    }, over or {})
  end
  local fi = { file = FILE }
  local c1, i1 = cache.wrap_file(runner, fi, ctx())
  eq(i1.status, "miss", "first run: a miss")
  eq(i1.stored, true, "stored")
  eq(runs, 1, "the file ran")
  ok(not c1[1].cached, "a fresh case is not marked")
  local c2, i2 = cache.wrap_file(runner, fi, ctx({ run_id = "run-B" }))
  eq(i2.status, "hit", "second run: a hit")
  eq(runs, 1, "the runner did not run")
  eq(c2[1].cached, true, "cached")
  eq(c2[1].notes[#c2[1].notes], "cached from run-A", "from the run that stored it")
  -- --no-cache: neither read nor written
  local _, i3 = cache.wrap_file(runner, fi, ctx({ mode = "off" }))
  eq(i3.status, "off", "mode off")
  eq(runs, 2, "--no-cache runs the file")
  eq(cache.counters.hit, 1, "--no-cache did not count a hit")
  -- refresh: runs, writes, never reads
  local _, i4 = cache.wrap_file(runner, fi, ctx({ mode = "refresh", run_id = "run-C" }))
  eq(i4.status, "refreshed", "mode refresh")
  eq(runs, 3, "refresh runs the file")
  eq(
    cache.get(i4.key, vim.tbl_extend("force", o, { file = FILE }))[1].notes[1] ~= nil,
    true,
    "and stores"
  )
  has(
    cache.get(i4.key, vim.tbl_extend("force", o, { file = FILE }))[1].notes[1],
    "run-C",
    "the refreshed entry belongs to the new run"
  )
  -- a changed spec is a miss
  S.edit(
    root,
    FILE,
    'local a = require("proj.a")\nreturn function(H) H.eq(a.v, 1, "changed") end\n'
  )
  local _, i5 = cache.wrap_file(runner, fi, ctx())
  eq(i5.status, "miss", "a changed spec runs again")
  eq(runs, 4, "ran")
  -- an uncacheable file runs every time and says why
  local pr = { file = "TESTS/proj/proc_spec.lua" }
  local runs_p = 0
  local function runner_p()
    runs_p = runs_p + 1
    return cases(pr.file)
  end
  local _, i6 = cache.wrap_file(runner_p, pr, ctx())
  eq(i6.status, "uncacheable", "a process starter is not cached")
  has(i6.reason, "process", "names the reason")
  cache.wrap_file(runner_p, pr, ctx())
  eq(runs_p, 2, "it ran twice")
  -- a result that must not be stored is still returned
  local function flaky()
    return cases(FILE), { flaky = true }
  end
  S.edit(root, FILE, 'local a = require("proj.a")\nreturn function(H) H.eq(a.v, 1, "flaky") end\n')
  local cf, i7 = cache.wrap_file(flaky, fi, ctx())
  eq(i7.stored, false, "flaky is not stored")
  eq(#cf, 1, "but returned")
  local function red()
    local c = cases(FILE)
    c[1].status = "fail"
    return c
  end
  local _, i8 = cache.wrap_file(red, fi, ctx())
  eq(i8.stored, false, "a red file is not stored")
  local _, i9 = cache.wrap_file(runner, fi, ctx({ restricted = true }))
  eq(i9.status, "uncacheable", "a case selection is never cached")
  has(i9.reason, "selection", "names the reason")
  -- a hit never carries over effects: the cached cases have an empty, truthful ledger and a cached flag
  S.edit(root, FILE, 'local a = require("proj.a")\nreturn function(H) H.eq(a.v, 1, "final") end\n')
  cache.wrap_file(runner, fi, ctx())
  local hit = cache.wrap_file(runner, fi, ctx())
  eq(hit[1].cached, true, "a hit is flagged for the guard and effects aggregation")

  -- ---------------------------------------------------------------- hash index: written, validated, bounded
  local ipath = vim.fs.normalize(vim.fn.tempname()) .. "/index.json"
  local hx = hash.new(ipath)
  S.write(root .. "/lua/proj/b.lua", "return { v = 11 }\n")
  local sha = hx:file(root .. "/lua/proj/b.lua")
  eq(#sha, 64, "file hash")
  eq(sha, vim.fn.sha256("return { v = 11 }\n"), "the hash is the sha256 of the bytes")
  ok(hx:flush(), "the index is written")
  local hx2 = hash.new(ipath)
  hx2:file(root .. "/lua/proj/b.lua")
  eq(hx2.hashed, 0, "a later process takes the hash from the index")
  eq(hx2.reused, 1, "reused")
  -- a corrupted index is ignored, everything is hashed again
  S.write(ipath, "{{{ not json", false)
  local hx3 = hash.new(ipath)
  eq(hx3:file(root .. "/lua/proj/b.lua"), sha, "same hash without the index")
  eq(hx3.hashed, 1, "hashed again")
  -- an index entry with a forged hash shape is dropped, a valid one stays
  S.write(
    ipath,
    json.encode({
      v = 1,
      files = {
        [vim.fs.normalize(root .. "/lua/proj/b.lua")] = { m = 1, n = 0, s = 3, h = "zz", t = 5 },
      },
    }),
    false
  )
  local hx4 = hash.new(ipath)
  eq(hx4:file(root .. "/lua/proj/b.lua"), sha, "a forged entry is not trusted")
  -- a stale stat entry (size differs) is not trusted either
  local real = assert(vim.uv.fs_stat(root .. "/lua/proj/b.lua"))
  S.write(
    ipath,
    json.encode({
      v = 1,
      files = {
        [vim.fs.normalize(root .. "/lua/proj/b.lua")] = {
          m = real.mtime.sec,
          n = real.mtime.nsec,
          s = real.size + 1,
          h = string.rep("a", 64),
          t = real.mtime.sec + 100,
        },
      },
    }),
    false
  )
  local hx5 = hash.new(ipath)
  eq(hx5:file(root .. "/lua/proj/b.lua"), sha, "an entry whose size does not match is rehashed")
  -- a missing file has no hash
  eq(select(2, hx5:file(root .. "/nope.lua")), "missing", "missing file")
  -- clear mutates in place
  local entries_tbl = hx5.entries
  hx5:clear()
  ok(entries_tbl == hx5.entries and next(entries_tbl) == nil, "hasher clear is in place")

  -- a symlinked fixture directory is part of the tree digest (the walker lists a link but never enters it)
  do
    local tdir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(tdir .. "/real/sub", "p")
    vim.fn.mkdir(tdir .. "/tree", "p")
    S.write(tdir .. "/real/sub/a.txt", "one", false)
    S.write(tdir .. "/tree/plain.txt", "plain", false)
    local linked =
      vim.uv.fs_symlink(tdir .. "/real", tdir .. "/tree/link", { dir = true, junction = true })
    if linked then
      local d1 = hash.new(nil):tree(tdir .. "/tree")
      S.write(tdir .. "/real/sub/a.txt", "two", false)
      local d2 = hash.new(nil):tree(tdir .. "/tree")
      ok(
        d1 ~= nil and d2 ~= nil and d1 ~= d2,
        "a file below a symlinked directory changes the digest"
      )
      -- a link that points back at an ancestor ends (each real directory is followed once)
      vim.uv.fs_symlink(tdir .. "/tree", tdir .. "/tree/real/loop", { dir = true, junction = true })
      local d3 = hash.new(nil):tree(tdir .. "/tree")
      ok(type(d3) == "string", "a symlink loop does not hang the digest")
    end
    S.remove(tdir)
  end

  cache.reset()
  S.remove(root)
  S.remove(cdir)
  S.remove(vim.fs.dirname(ipath))
end
