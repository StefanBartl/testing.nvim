-- TESTS/testing/cache_audit_spec.lua -- the cache proves itself: `--cache-audit` runs a share of the cache hits
-- anyway and compares (a difference is `cache.stale_pass`, the measured stale-pass rate is in the IR and on the
-- terminal), and the key-flip detection (the same key that gave two results marks the file nondeterministic).

---@diagnostic disable: need-check-nil, inject-field, undefined-field, param-type-mismatch, missing-fields, cast-local-type

-- @cache-allow time
-- (ages are built relative to now (a stray temp file older than an hour): the result does not depend on the time of day)
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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1800) .. ")"
    )
  end
  local function lacks(haystack, needle, msg)
    return ok(
      type(haystack) == "string" and haystack:find(needle, 1, true) == nil,
      msg .. " (found " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 1800) .. ")"
    )
  end

  local cli = require("testing.cli")
  local cache = require("testing.cache")
  local keylog = require("testing.cache.keylog")
  local store = require("testing.cache.store")
  local hash = require("testing.cache.hash")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-auditspec"
  vim.fn.mkdir(tmp, "p")
  local seq = 0

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
  ---@param argv string[]
  ---@param more? table
  local function run(root, argv, more)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = root .. "-state",
      cache_dir = root .. "-cache",
      color = false,
      affected = { getenv = function() end, provider = false },
      audit_salt = "fixed",
    }
    for k, v in pairs(more or {}) do
      sv[k] = v
    end
    local args = { root }
    if argv[1] == "explain" then
      args = { "explain", root }
      argv = vim.list_slice(argv, 2)
    end
    vim.list_extend(args, argv)
    local code = cli.main(args, sv)
    package.loaded["proj.mod"] = nil
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end
  local function entries(root)
    return cache.stats({ root = root, cache_dir = root .. "-cache" }).entries
  end
  local function ir_of(root, argv)
    seq = seq + 1
    local path = ("%s/ir%d.json"):format(tmp, seq)
    local res = run(root, vim.list_extend(vim.deepcopy(argv), { "--json", path }))
    return vim.json.decode(read(path)), res
  end

  ---A project of pure specs: `a` and `c` (loads proj.mod).
  local function clean_project()
    seq = seq + 1
    local root = ("%s/clean%d"):format(tmp, seq)
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(
      root .. "/TESTS/a_spec.lua",
      "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n"
    )
    write(
      root .. "/TESTS/c_spec.lua",
      "return function(H)\n  H.ok(require('proj.mod').value == 1, 'the module')\nend\n"
    )
    write(
      root .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    return root
  end

  -- ---------------------------------------------------------------- a clean suite: rate 0, nothing else changes
  local clean = clean_project()
  local cold = run(clean, { "--cached" })
  eq(cold.code, 0, "cold run is green\n" .. cold.err)
  eq(entries(clean), 2, "two entries stored")

  local warm = run(clean, { "--cached" })
  eq(warm.code, 0, "warm run is green")
  has(warm.out, "2 of 2 spec file(s) were not run", "everything from the cache")
  lacks(warm.out, "audit", "no audit asked for: the cache line does not mention it")

  local audited_ir, audited = ir_of(clean, { "--cache-audit", "all" })
  eq(audited.code, 0, "an audit of a clean suite is green\n" .. audited.err)
  has(
    audited.out,
    "audit: 2 of 2 hit(s) ran again, 0 differ (stale-pass rate 0.0%)",
    "the terminal line"
  )
  has(audited.out, "TESTING_OK", "a green audited run keeps the sentinel")
  eq(audited_ir.run.cache.audited, 2, "run.cache.audited")
  eq(audited_ir.run.cache.stale_pass, 0, "run.cache.stale_pass")
  eq(audited_ir.run.cache.stale_pass_rate, 0, "the measured stale-pass rate is 0")
  eq(audited_ir.run.cache.audit_rate, 1, "the rate that was asked for")
  eq(audited_ir.run.cache.files_cached, 0, "an audited hit ran: it is not a cached file")
  for _, c in ipairs(audited_ir.cases) do
    ok(c.cached ~= true, "an audited case really ran: " .. c.id)
  end
  eq(entries(clean), 2, "an audit of a clean suite writes nothing new")

  -- audit share 0: the output is the output of a plain cached run (timings aside)
  local function normalized(text)
    return (text:gsub("%d+%.?%d* ?m?s%f[%A]", "T"))
  end
  local plain = run(clean, { "--cached" })
  local zero = run(clean, { "--cache-audit", "0" })
  eq(zero.code, plain.code, "share 0: same exit code")
  eq(
    normalized(zero.out),
    normalized(plain.out),
    "share 0: the output is byte for byte the plain one"
  )
  eq(normalized(zero.err), normalized(plain.err), "share 0: and so is stderr")
  local zero_ir = ir_of(clean, { "--cache-audit", "0" })
  local plain_ir = ir_of(clean, { "--cached" })
  eq(zero_ir.run.cache, plain_ir.run.cache, "share 0: run.cache is the plain one (no audit fields)")

  -- a fraction is reproducible for a salt
  local half1 = ir_of(clean, { "--cache-audit", "0.5" })
  local half2 = ir_of(clean, { "--cache-audit", "0.5" })
  eq(half1.run.cache.audited, half2.run.cache.audited, "the same salt picks the same hits")
  -- a fraction must really pick SOME of the hits (0 < share < 1): look for a salt that picks exactly one of the two,
  -- and check the line says "1 of 2" with the true denominator
  local picked_one
  for i = 1, 40 do
    local path = ("%s/half%d.json"):format(tmp, i)
    local res_half = run(
      clean,
      { "--cache-audit", "0.5", "--json", path },
      { audit_salt = "salt" .. i }
    )
    local ir_half = vim.json.decode(read(path))
    if ir_half.run.cache.audited == 1 then
      picked_one = { ir = ir_half, res = res_half }
      break
    end
  end
  ok(picked_one ~= nil, "some salt picks exactly one of the two hits at a share of 0.5")
  if picked_one then
    has(
      picked_one.res.out,
      "audit: 1 of 2 hit(s) ran again, 0 differ",
      "the denominator counts the hit that was not picked"
    )
    eq(picked_one.ir.run.cache.files_cached, 1, "the hit that was not picked came from the cache")
    eq(picked_one.ir.run.cache.audit_skipped, 0, "nothing was picked and skipped")
  end
  -- the pick itself: a share is a share (an inverted comparison would audit 90% where 10% was asked for)
  do
    local picks = require("testing.run.cached").audit_picks
    local function count(rate)
      local n = 0
      for i = 1, 400 do
        if picks(rate, vim.fn.sha256("key" .. i), "salt") then
          n = n + 1
        end
      end
      return n
    end
    eq(count(0), 0, "share 0 picks nothing")
    eq(count(1), 400, "share 1 picks everything")
    local low, mid, high = count(0.1), count(0.5), count(0.9)
    ok(low >= 15 and low <= 70, "share 0.1 picks about a tenth: " .. low)
    ok(mid >= 150 and mid <= 250, "share 0.5 picks about half: " .. mid)
    ok(high >= 330 and high <= 385, "share 0.9 picks about nine tenths: " .. high)
    ok(low < mid and mid < high, "and it grows with the share")
    eq(picks(0.5, "k", "a"), picks(0.5, "k", "a"), "the same key and salt pick the same way")
  end

  -- a hit that was picked but did not run (a stopped run) is counted and shown, not hidden in the denominator
  do
    local sroot = clean_project()
    run(sroot, { "--cached" })
    write(
      sroot .. "/TESTS/0_fail_spec.lua",
      "return function(H)\n  H.ok(false, 'stops the run')\nend\n"
    )
    local sir, sres = ir_of(sroot, { "--cached", "--cache-audit", "all", "-x" })
    eq(sir.run.cache.audited, 0, "a stopped run audits nothing")
    eq(sir.run.cache.audit_skipped, 2, "the two picked hits are counted as skipped")
    has(sres.out, "audit: 0 of 2 hit(s) ran again (2 picked but skipped", "and the line says so")
  end

  -- many findings: the IR and the terminal list the first 20 and count the rest
  do
    seq = seq + 1
    local mroot = ("%s/many%d"):format(tmp, seq)
    for i = 1, 22 do
      write(
        ("%s/TESTS/m%02d_spec.lua"):format(mroot, i),
        table.concat({
          "return function(H)",
          "  local base = debug.getinfo(1, 'S').source:match('^@?(.*)/TESTS/')",
          "  local dir = 'da' .. 'ta'",
          "  local f = assert(io.open(base .. '/' .. dir .. '/value.txt', 'rb'))",
          "  local v = f:read('*a')",
          "  f:close()",
          "  H.ok(v == '1\\n', 'the data is 1')",
          "end",
          "",
        }, "\n")
      )
    end
    write(mroot .. "/data/value.txt", "1\n")
    write(
      mroot .. "/.testing.lua",
      "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
    )
    eq(run(mroot, { "--cached" }).code, 0, "many: cold run is green")
    write(mroot .. "/data/value.txt", "2\n")
    local mir, mres = ir_of(mroot, { "--cached", "--cache-audit", "all" })
    eq(mres.code, 1, "many: the audit finds the stale passes")
    eq(mir.run.cache.stale_pass, 22, "many: 22 stale passes")
    eq(#mir.run.cache.findings, 20, "many: the IR lists the first 20 findings")
    eq(mir.run.cache.findings_total, 22, "many: and counts all of them")
    has(
      mres.out,
      "... 2 more finding(s) of --cache-audit",
      "many: the terminal says how many are not listed"
    )
  end

  -- usage
  eq(run(clean, { "--cache-audit", "2" }).code, 2, "a share above 1 is a usage error")
  eq(run(clean, { "--cache-audit", "x" }).code, 2, "so is a word that is not 'all'")
  eq(
    run(clean, { "--cache-audit", "all", "--cache-refresh" }).code,
    2,
    "refresh never reads: they exclude each other"
  )
  local off = run(clean, { "--cache-audit", "all", "--no-cache" })
  eq(off.code, 0, "--no-cache wins")
  lacks(off.out, "audit", "and nothing is audited")

  -- ---------------------------------------------------------------- a built-in stale pass and a flaky spec
  seq = seq + 1
  local root = ("%s/dirty%d"):format(tmp, seq)
  write(root .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n")
  -- reads a file by a PATH IT COMPUTES: the key cannot see it (the documented limit of the scanner)
  write(
    root .. "/TESTS/s_spec.lua",
    table.concat({
      "return function(H)",
      "  local base = debug.getinfo(1, 'S').source:match('^@?(.*)/TESTS/')",
      "  local dir = 'da' .. 'ta'",
      "  local f = assert(io.open(base .. '/' .. dir .. '/value.txt', 'rb'))",
      "  local v = f:read('*a')",
      "  f:close()",
      "  H.ok(v == '1\\n', 'the data is 1')",
      "end",
      "",
    }, "\n")
  )
  write(root .. "/data/value.txt", "1\n")
  -- passes every other run, whatever the key says
  write(
    root .. "/TESTS/f_spec.lua",
    table.concat({
      "return function(H)",
      "  local base = debug.getinfo(1, 'S').source:match('^@?(.*)/TESTS/')",
      "  local path = base .. '/' .. 'st' .. 'ate.txt'",
      "  local f = io.open(path, 'rb')",
      "  local n = f and tonumber(f:read('*a')) or 0",
      "  if f then f:close() end",
      "  local w = assert(io.open(path, 'wb'))",
      "  w:write(tostring(n + 1))",
      "  w:close()",
      "  H.ok(n % 2 == 0, 'passes on every other run')",
      "end",
      "",
    }, "\n")
  )
  write(
    root .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  local first = run(root, { "--cached" })
  eq(first.code, 0, "cold: green\n" .. first.out .. first.err)
  eq(entries(root), 3, "a, s and f are stored")

  -- without an audit the cache lies: the data changed, the key did not
  write(root .. "/data/value.txt", "2\n")
  local lie = run(root, { "--cached" })
  has(lie.out, "3 of 3 spec file(s) were not run", "the stale hits are taken from the cache")
  eq(lie.code, 0, "and the run is green: the stale pass the key cannot see")

  -- with an audit it is found
  local stale_ir, stale = ir_of(root, { "--cached", "--cache-audit", "all" })
  eq(stale.code, 1, "an audit that finds a difference exits 1\n" .. stale.out)
  has(
    stale.out,
    "audit: 3 of 3 hit(s) ran again, 2 differ (stale-pass rate 66.7%)",
    "the measured rate is on the terminal"
  )
  has(stale.out, "cache.stale_pass TESTS/s_spec.lua", "the finding names the file")
  has(stale.out, "an input the key cannot see", "and the first possible cause")
  has(stale.out, "not deterministic", "and the second")
  has(stale.out, "key part: file TESTS/s_spec.lua", "and shows the key lines")
  lacks(stale.out, "TESTING_OK", "no sentinel")
  eq(stale_ir.run.cache.audited, 3, "IR: audited")
  eq(stale_ir.run.cache.stale_pass, 2, "IR: stale_pass")
  ok(math.abs(stale_ir.run.cache.stale_pass_rate - 2 / 3) < 1e-9, "IR: the rate is stale / audited")
  local findings = {}
  for _, f in ipairs(stale_ir.run.cache.findings) do
    findings[f.file] = f
    eq(f.code, "cache.stale_pass", "IR: the code of a finding")
    ok(#f.key == 64 and #f.parts > 5, "IR: key and key lines of " .. f.file)
  end
  ok(findings["TESTS/s_spec.lua"] and findings["TESTS/f_spec.lua"], "IR: both files are named")
  ok(findings["TESTS/a_spec.lua"] == nil, "and the file that did not differ is not")
  eq(
    entries(root),
    1,
    "the stored entries of the files that differ are discarded, nothing new is written for them"
  )
  local latest = cache.latest({ root = root, cache_dir = root .. "-cache" })
  ok(latest["TESTS/a_spec.lua"] ~= nil, "the entry of the clean file is kept")
  eq(latest["TESTS/s_spec.lua"], nil, "no entry for s")
  eq(latest["TESTS/f_spec.lua"], nil, "no entry for f")

  -- key flip: the same key gave pass, then fail: never cached again, and it says so
  local flipped = run(root, { "--cached" })
  has(
    flipped.out,
    "2 nondeterministic (same key, different result: not cached)",
    "the run line counts them"
  )
  has(
    flipped.out,
    "nondeterministic: the same key gave different results (fail, pass)",
    "and names the reason"
  )
  eq(entries(root), 1, "nothing is stored for them")
  local log = keylog.load(root, { state_dir = root .. "-state" })
  eq(#log.files["TESTS/s_spec.lua"], 2, "the history of the key holds the two results")

  local ex = run(root, { "explain", "s_spec", "--json" })
  local rec = vim.json.decode(ex.out).specs[1]
  eq(rec.status, "uncacheable", "explain: s has no key")
  eq(rec.kind, "nondeterministic", "explain: because it is nondeterministic")
  has(rec.reason, "fail, pass", "explain: the results the key gave")
  has(rec.way_out, "-- @cache-allow nondeterministic", "explain: and the way out")
  eq(#rec.key, 64, "explain: the key that flipped")
  ok(#rec.parts > 5, "explain: with its lines")

  -- an unusable key-flip memory is not ignored silently: the run says that the detection is blind
  do
    local nroot = clean_project()
    write(keylog.path(nroot, { state_dir = nroot .. "-state" }), "{ not json")
    local noisy = run(nroot, { "--cached" })
    has(noisy.err, "key log", "a corrupt keys.json is a note of the run")
    has(noisy.err, "not usable", "and it says why")
  end

  -- --cache-clear starts from nothing: the key-flip memory goes too
  local cleared = run(root, { "--cache-clear" })
  eq(cleared.code, 0, "--cache-clear\n" .. cleared.err)
  eq(keylog.load(root, { state_dir = root .. "-state" }).files, {}, "the key-flip memory is gone")
  eq(entries(root), 0, "and so are the entries")
  run(root, { "--cached" })

  -- the audit never invents: a hit that did not differ and one that was not sampled leave the cache as it was
  local again = run(root, { "--cached", "--cache-audit", "all" })
  has(again.out, "audit: 1 of 1 hit(s) ran again, 0 differ", "only the clean file is a hit now")

  -- the flip that shows only after the run: first red, then green under one key. Nothing is stored for it.
  seq = seq + 1
  local froot = ("%s/flaky%d"):format(tmp, seq)
  write(
    froot .. "/TESTS/g_spec.lua",
    table.concat({
      "return function(H)",
      "  local base = debug.getinfo(1, 'S').source:match('^@?(.*)/TESTS/')",
      "  local path = base .. '/' .. 'st' .. 'ate.txt'",
      "  local f = io.open(path, 'rb')",
      "  local n = f and tonumber(f:read('*a')) or 0",
      "  if f then f:close() end",
      "  local w = assert(io.open(path, 'wb'))",
      "  w:write(tostring(n + 1))",
      "  w:close()",
      "  H.ok(n % 2 == 0, 'passes on every other run')",
      "end",
      "",
    }, "\n")
  )
  write(froot .. "/state.txt", "1")
  write(
    froot .. "/.testing.lua",
    "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"
  )
  local red = run(froot, { "--cached" })
  eq(red.code, 1, "first run: red (and a red file is never stored)")
  eq(entries(froot), 0, "nothing stored")
  local green = run(froot, { "--cached" })
  eq(green.code, 0, "second run: green\n" .. green.out)
  eq(entries(froot), 0, "same key, other result: not stored (the key flipped in this very run)")
  has(green.out, "1 nondeterministic", "and the run says so")
  has(
    green.out,
    "not stored: 1 nondeterministic: the same key gave different results",
    "with the reason"
  )
  local after = run(froot, { "--cached" })
  has(after.out, "not cacheable: 1 nondeterministic", "from then on it has no key")

  -- ---------------------------------------------------------------- the key-flip memory and its declaration
  local lroot = tmp .. "/keylog"
  local lopts = { state_dir = lroot }
  eq(keylog.class_of({ { status = "pass" }, { status = "pass" } }), "pass", "class of a green file")
  eq(
    keylog.class_of({ { status = "pass" }, { status = "fail" } }),
    "fail",
    "a failed case makes the file fail"
  )
  eq(keylog.class_of({ { status = "pass" }, { status = "timeout" } }), "fail", "so does a timeout")
  eq(keylog.class_of({ { status = "pass" }, { status = "skip" } }), "skip", "a skip is not a pass")
  eq(keylog.class_of({}), nil, "no cases: nothing to remember")
  eq(
    keylog.class_of({ { status = "pass" }, { status = "pass", flaky = true, retries = 1 } }),
    "flaky",
    "a case that passed after a retry (--allow-flaky) makes the file flaky, not pass"
  )
  eq(keylog.class_of({ { status = "pass", retries = 2 } }), "flaky", "retries > 0 alone is enough")
  eq(
    keylog.class_of({ { status = "pass", retries = 0 } }),
    "pass",
    "retries = 0 is an ordinary pass"
  )
  eq(
    keylog.class_of({ { status = "fail", flaky = true }, { status = "pass" } }),
    "fail",
    "a red case wins over a flaky one"
  )
  eq(
    keylog.class_of({ { status = "skip" }, { status = "pass", flaky = true } }),
    "flaky",
    "flaky wins over a skip"
  )

  local k1, k2 = ("1"):rep(64), ("2"):rep(64)
  local l = keylog.load(tmp .. "/nolog", { state_dir = tmp .. "/nolog" })
  eq(l.files, {}, "no file: an empty log")
  eq(l:observe("TESTS/x_spec.lua", k1, "pass", "r1", 10), nil, "one result is no flip")
  eq(
    l:observe("TESTS/x_spec.lua", k1, "pass", "r2", 11),
    nil,
    "the same result again is none either"
  )
  eq(#l.files["TESTS/x_spec.lua"], 1, "and it refreshes the record instead of growing the log")
  eq(l:observe("TESTS/x_spec.lua", k2, "fail", "r3", 12), nil, "another key is another question")
  local flip = l:observe("TESTS/x_spec.lua", k1, "fail", "r4", 13)
  eq(flip and flip.classes, { "fail", "pass" }, "the same key with another result is a flip")
  eq(l:flipped("TESTS/x_spec.lua", k2), nil, "the other key is clean")
  eq(l:flipped("TESTS/other_spec.lua", k1), nil, "and so is another file")
  for i = 1, 40 do
    l:observe("TESTS/y_spec.lua", ("%064x"):format(i), "pass", "r" .. i, i)
  end
  eq(#l.files["TESTS/y_spec.lua"], keylog.MAX_OBS, "the log is bounded per file")
  -- when the list is full the record that was used LONGEST AGO goes, not the one that was written first
  do
    local lru = keylog.load(tmp .. "/lru", { state_dir = tmp .. "/lru" })
    local keys = {}
    for i = 1, keylog.MAX_OBS do
      keys[i] = ("%064x"):format(i)
      lru:observe("TESTS/z_spec.lua", keys[i], "pass", "r" .. i, i)
    end
    lru:observe("TESTS/z_spec.lua", keys[1], "pass", "again", 100) -- the oldest record is used again
    lru:observe("TESTS/z_spec.lua", ("%064x"):format(999), "pass", "new", 101) -- the list is full: one goes
    local left = {}
    for _, o in ipairs(lru.files["TESTS/z_spec.lua"]) do
      left[o.key] = true
    end
    ok(left[keys[1]], "the record that was used again stays")
    ok(not left[keys[2]], "the record nobody used for longest goes")
    eq(#lru.files["TESTS/z_spec.lua"], keylog.MAX_OBS, "and the list stays at its bound")
  end
  -- stray temp files of an interrupted write of keys.json are removed when load looks at the directory
  do
    local sweep_opts = { state_dir = tmp .. "/sweep" }
    local d = vim.fs.dirname(keylog.path(tmp .. "/sweep-project", sweep_opts))
    vim.fn.mkdir(d, "p")
    local old_tmp, new_tmp = d .. "/keys.json.atomic-tmp.1.2", d .. "/keys.json.atomic-tmp.3.4"
    write(old_tmp, "x")
    write(new_tmp, "x")
    local t = os.time() - 7200
    vim.uv.fs_utime(old_tmp, t, t)
    keylog.load(tmp .. "/sweep-project", sweep_opts)
    eq(vim.uv.fs_stat(old_tmp), nil, "an old temp file of keys.json is swept")
    ok(vim.uv.fs_stat(new_tmp) ~= nil, "a young one stays (a write may be going on)")
  end
  ok(l:save(), "saved")
  local back = keylog.load(tmp .. "/nolog", { state_dir = tmp .. "/nolog" })
  eq(back.files, l.files, "and read back unchanged")

  -- the file is untrusted input
  local kpath = keylog.path(lroot, lopts)
  write(kpath, "{ not json")
  local junk = keylog.load(lroot, lopts)
  eq(junk.files, {}, "garbage: an empty log")
  eq(#junk.notes, 1, "with a note")
  write(
    kpath,
    vim.json.encode({
      v = 1,
      files = {
        ["TESTS/a_spec.lua"] = {
          { key = k1, class = "pass", run = "r1", ts = 1 },
          { key = "../../etc/passwd", class = "pass", run = "r1", ts = 1 },
          { key = k1, class = "evil", run = "r1", ts = 1 },
          { key = k1, class = "fail", run = "r\1", ts = 1 },
          { key = k1, class = "fail", run = "r2", ts = -5 },
        },
        ["bad\nname"] = { { key = k1, class = "pass", run = "r1", ts = 1 } },
      },
    })
  )
  local mixed = keylog.load(lroot, lopts)
  eq(#mixed.files["TESTS/a_spec.lua"], 1, "only the valid record is kept")
  eq(mixed.files["bad\nname"], nil, "a file name with a control character is dropped")
  ok(#mixed.notes == 1 and mixed.notes[1]:find("unusable"), "and counted")
  write(kpath, (" "):rep(keylog.MAX_BYTES * 2 + 10))
  eq(keylog.load(lroot, lopts).files, {}, "a huge file is ignored unread")

  -- `-- @cache-allow nondeterministic` caches a flipped key anyway; without it there is no key
  seq = seq + 1
  local kroot = ("%s/flip%d"):format(tmp, seq)
  write(kroot .. "/TESTS/a_spec.lua", "return function(H)\n  H.ok(true, 'a')\nend\n")
  write(
    kroot .. "/TESTS/b_spec.lua",
    "-- @cache-allow nondeterministic\nreturn function(H)\n  H.ok(true, 'b')\nend\n"
  )
  local function ctx_of(f)
    return {
      root = kroot,
      cache_dir = kroot .. "-cache",
      dep_roots = {},
      runner_version = "r",
      nvim = "n",
      config_digest = "c",
      dialect = "a",
      env_names = {},
      environ = function()
        return {}
      end,
      hasher = hash.new(),
      flipped = f,
    }
  end
  local plain_a = cache.key({ file = "TESTS/a_spec.lua" }, ctx_of())
  local plain_b = cache.key({ file = "TESTS/b_spec.lua" }, ctx_of())
  ok(plain_a and plain_b, "both have a key without a flip")
  local always = function()
    return { classes = { "fail", "pass" }, runs = {} }
  end
  local nk, nwhy, nparts, ndetail = cache.key({ file = "TESTS/a_spec.lua" }, ctx_of(always))
  eq(nk, nil, "a flipped key is not a key")
  has(nwhy, "nondeterministic: the same key gave different results (fail, pass)", "with the reason")
  eq(ndetail.kind, "nondeterministic", "kind")
  eq(ndetail.key, plain_a, "the key it would have is handed back for the explanation")
  ok(nparts ~= nil, "and so are its lines")
  local bk, _, _, bdetail = cache.key({ file = "TESTS/b_spec.lua" }, ctx_of(always))
  eq(bk, plain_b, "a spec that declares it is cached all the same")
  eq(bdetail.allow_nondeterministic, true, "and says it declared it")
  eq(bdetail.flipped, { "fail", "pass" }, "and that its key flipped")

  -- the lines kept in an entry are bounded and clean
  eq(store.clean_parts({ "a", "b=c" }), { "a", "b=c" }, "key lines are kept")
  eq(store.clean_parts({ "a\nb" }), nil, "a control character: no lines at all")
  eq(store.clean_parts({ ("x"):rep(store.MAX_PART_BYTES + 1) }), nil, "a line too long")
  local many = {}
  for i = 1, store.MAX_PARTS + 1 do
    many[i] = "l"
  end
  eq(store.clean_parts(many), nil, "too many lines")
  eq(store.clean_parts({}), nil, "none")
  eq(store.clean_parts({ a = "x" }), nil, "not a list")

  vim.fn.delete(tmp, "rf")
end
