-- TESTS/testing/cache_keylog_spec.lua -- the key-flip memory (`keys.json`) is read when a run starts and written when
-- it ends: two runs of one project at the same time must not drop each other's observations, or a key that gave `pass`
-- in one run and `fail` in the other is never seen as a flip and the spec stays cacheable.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local keylog = require("testing.cache.keylog")
  local lock = require("testing.statelock")

  local state = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(state, "p")
  local opts = { state_dir = state }
  local root = state .. "/project"
  local K1, K2 = ("a"):rep(64), ("b"):rep(64)

  -- two runs load an empty log, observe the same key with different results, and save one after the other ---
  local run_a = keylog.load(root, opts)
  local run_b = keylog.load(root, opts)
  eq(
    run_a:observe("TESTS/x_spec.lua", K1, "pass", "run-a", 100),
    nil,
    "run a: first result of the key"
  )
  run_a:observe("TESTS/only_a_spec.lua", K2, "pass", "run-a", 101)
  eq(
    run_b:observe("TESTS/x_spec.lua", K1, "fail", "run-b", 102),
    nil,
    "run b: no flip is known to it yet"
  )
  run_b:observe("TESTS/only_b_spec.lua", K2, "pass", "run-b", 103)
  ok(run_a:save(), "run a saves")
  ok(run_b:save(), "run b saves, after run a")

  local back = keylog.load(root, opts)
  local flip = back:flipped("TESTS/x_spec.lua", K1)
  ok(flip ~= nil, "the next run sees the flip: pass in one run, fail in the other")
  eq(flip and flip.classes, { "fail", "pass" }, "with both results")
  ok(back:flipped("TESTS/only_a_spec.lua", K2) == nil, "(one result is no flip)")
  ok(
    back.files["TESTS/only_a_spec.lua"] ~= nil,
    "the file only run a saw survived the save of run b"
  )
  ok(back.files["TESTS/only_b_spec.lua"] ~= nil, "and the file only run b saw is there")
  eq(#back.files["TESTS/x_spec.lua"], 2, "two records for the key, one per result")

  -- the log of the run that saved last knows the merged state, too
  ok(
    run_b:flipped("TESTS/x_spec.lua", K1) ~= nil,
    "the saving run holds the merged log after the save"
  )
  ok(not run_b.dirty and #run_b.pending == 0, "and has nothing left to write")
  ok(run_b:save(), "a second save of a clean log is a no-op")

  -- a result seen again refreshes its record instead of adding one (bounded, as before) ----------------------
  local again = keylog.load(root, opts)
  again:observe("TESTS/x_spec.lua", K1, "pass", "run-c", 200)
  ok(again:save(), "a repeated result saves")
  local after = keylog.load(root, opts)
  eq(#after.files["TESTS/x_spec.lua"], 2, "still two records")
  local runs = {}
  for _, o in ipairs(after.files["TESTS/x_spec.lua"]) do
    runs[o.class] = o.run
  end
  eq(runs, { pass = "run-c", fail = "run-b" }, "the repeated result moved to the newest run")

  -- the files a run still knows are kept, the others go (`retain`), also after the merge --------------------
  local keeper = keylog.load(root, opts)
  keeper:retain({ ["TESTS/x_spec.lua"] = true })
  ok(keeper:save(), "retain saves")
  local kept = keylog.load(root, opts)
  ok(kept.files["TESTS/x_spec.lua"] ~= nil, "the known file stays")
  ok(
    kept.files["TESTS/only_a_spec.lua"] == nil and kept.files["TESTS/only_b_spec.lua"] == nil,
    "the files that are not known any more are gone"
  )

  -- the write is under the lock of keys.json: a held lock is a note, and the log stays dirty ----------------
  local path = keylog.path(root, opts)
  local held = assert(io.open(path .. ".lock", "wb"))
  held:close()
  local blocked = keylog.load(root, opts)
  blocked:observe("TESTS/y_spec.lua", K1, "pass", "run-d", 300)
  local before = lock.TIMEOUT_MS
  lock.TIMEOUT_MS = 100
  local saved, note = blocked:save()
  lock.TIMEOUT_MS = before
  ok(saved == false, "no write while somebody else holds the lock")
  ok(
    tostring(note):find("locked by another run", 1, true) ~= nil,
    "and the note says why: " .. tostring(note)
  )
  ok(blocked.dirty, "the log is still dirty, nothing is lost")
  os.remove(path .. ".lock")
  ok(blocked:save(), "once the lock is free the same log saves")
  ok(keylog.load(root, opts).files["TESTS/y_spec.lua"] ~= nil, "with the observation it kept")
  ok(vim.uv.fs_stat(path .. ".lock") == nil, "no lock is left behind")

  vim.fn.delete(state, "rf")
end
