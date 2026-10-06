-- TESTS/testing/shard_spec.lua -- `testing.run.shard`: the partition behind `--shard i/n` against a fixture
-- list: the union of all shards is the whole list, no file is in two shards, the same input always gives the
-- same shards, the balance modes balance what they promise, and the durations file is untrusted input.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local shard = require("testing.run.shard")

  -- a fixture list: 23 files in 4 directories, uneven sizes (one giant, a few big, many small)
  local items = {}
  for i = 1, 23 do
    local dir = ({ "TESTS/a", "TESTS/b", "TESTS/c", "TESTS/d" })[(i % 4) + 1]
    local weight = 10 + i
    if i == 7 then
      weight = 900
    elseif i % 5 == 0 then
      weight = 120
    end
    items[#items + 1] = { rel = ("%s/f%02d_spec.lua"):format(dir, i), weight = weight }
  end
  local all = {}
  for _, it in ipairs(items) do
    all[#all + 1] = it.rel
  end

  ---@param buckets string[][]
  ---@return string[]
  local function flatten(buckets)
    local out = {}
    for _, b in ipairs(buckets) do
      vim.list_extend(out, b)
    end
    table.sort(out)
    return out
  end
  local sorted_all = vim.list_slice(all, 1, #all)
  table.sort(sorted_all)

  for _, balance in ipairs(shard.BALANCES) do
    for _, count in ipairs({ 1, 2, 3, 4, 7, 23, 40 }) do
      local buckets = shard.partition(items, count, { balance = balance })
      eq(#buckets, count, ("%s/%d: one bucket per shard"):format(balance, count))
      -- union = full set, nothing twice: the flattened, sorted buckets are exactly the sorted input
      eq(
        flatten(buckets),
        sorted_all,
        ("%s/%d: the union of the shards is the whole list"):format(balance, count)
      )
      -- deterministic: a second computation gives the same buckets, in the same order
      eq(
        shard.partition(items, count, { balance = balance }),
        buckets,
        ("%s/%d: same input, same shards"):format(balance, count)
      )
    end
  end

  -- input order does not change who gets what (every CI job may list the files in its own order)
  local reversed = {}
  for i = #items, 1, -1 do
    reversed[#reversed + 1] = items[i]
  end
  for _, balance in ipairs(shard.BALANCES) do
    local a = shard.partition(items, 5, { balance = balance })
    local b = shard.partition(reversed, 5, { balance = balance })
    for i = 1, 5 do
      local x, y = vim.list_slice(a[i], 1, #a[i]), vim.list_slice(b[i], 1, #b[i])
      table.sort(x)
      table.sort(y)
      eq(x, y, ("%s: shard %d is the same set whatever order the list came in"):format(balance, i))
    end
  end

  -- inside a bucket the files keep the order of the input list
  local buckets = shard.partition(items, 3, { balance = "count" })
  for i, b in ipairs(buckets) do
    local position = {}
    for pos, rel in ipairs(all) do
      position[rel] = pos
    end
    local prev = 0
    for _, rel in ipairs(b) do
      ok(position[rel] > prev, ("bucket %d keeps the input order (%s)"):format(i, rel))
      prev = position[rel]
    end
  end

  -- count: file counts differ by at most one
  for _, count in ipairs({ 2, 3, 4, 5, 8 }) do
    local b = shard.partition(items, count, { balance = "count" })
    local lo, hi = math.huge, 0
    for _, bucket in ipairs(b) do
      lo, hi = math.min(lo, #bucket), math.max(hi, #bucket)
    end
    ok(hi - lo <= 1, ("count/%d: sizes differ by at most one (got %d..%d)"):format(count, lo, hi))
  end

  -- size: the giant file sits alone in its bucket, and the heaviest bucket is not worse than the
  -- classic bound of longest-processing-time-first (4/3 of the optimum, optimum >= max(total/n, giant))
  do
    local b, loads = shard.partition(items, 4, { balance = "size" })
    local total, giant = 0, 0
    for _, it in ipairs(items) do
      total = total + it.weight
      giant = math.max(giant, it.weight)
    end
    local worst = 0
    for _, l in ipairs(loads) do
      worst = math.max(worst, l)
    end
    local optimum_floor = math.max(total / 4, giant)
    ok(
      worst <= optimum_floor * 4 / 3 + 1e-9,
      ("size/4: heaviest bucket %g within 4/3 of %g"):format(worst, optimum_floor)
    )
    for _, bucket in ipairs(b) do
      if
        vim.tbl_contains(bucket, "TESTS/c/f07_spec.lua")
        or vim.tbl_contains(bucket, "TESTS/d/f07_spec.lua")
      then
        ok(#bucket <= 3, "the giant file does not share a bucket with a crowd")
      end
    end
    -- the loads add up to the total weight
    local sum = 0
    for _, l in ipairs(loads) do
      sum = sum + l
    end
    eq(sum, total, "size/4: the loads add up to the total weight")
  end

  -- a file of unknown weight weighs the median of the known ones (it must not weigh nothing)
  do
    local list = {
      { rel = "a_spec.lua", weight = 10 },
      { rel = "b_spec.lua", weight = 30 },
      { rel = "c_spec.lua", weight = 20 },
      { rel = "d_spec.lua" },
    }
    local _, loads = shard.partition(list, 1, { balance = "history" })
    eq(loads[1], 10 + 30 + 20 + 20, "unknown weight = median of the known (20)")
    local _, none = shard.partition(
      { { rel = "x_spec.lua" }, { rel = "y_spec.lua" } },
      1,
      { balance = "size" }
    )
    eq(none[1], 2, "no weight known at all: every file weighs 1")
  end

  -- hash: adding a file moves no other file (the whole point of this mode)
  do
    local before = shard.partition(items, 6, { balance = "hash" })
    local plus =
      vim.list_extend(vim.list_slice(items, 1, #items), { { rel = "TESTS/new/zz_spec.lua" } })
    local after = shard.partition(plus, 6, { balance = "hash" })
    local home = {}
    for i, b in ipairs(after) do
      for _, rel in ipairs(b) do
        home[rel] = i
      end
    end
    for i, b in ipairs(before) do
      for _, rel in ipairs(b) do
        eq(home[rel], i, "hash: " .. rel .. " stays in its shard when a file is added")
      end
    end
    -- the injected hash decides (so the spec does not depend on sha256 values)
    local forced = shard.partition({ { rel = "a" }, { rel = "b" }, { rel = "c" } }, 3, {
      balance = "hash",
      hash = function(rel)
        return rel == "a" and 0 or rel == "b" and 1 or 5
      end,
    })
    eq(forced, { { "a" }, { "b" }, { "c" } }, "hash: bucket = hash % n + 1")
  end

  -- a duplicate in the list is run once
  do
    local b = shard.partition(
      { { rel = "a" }, { rel = "a" }, { rel = "b" } },
      2,
      { balance = "count" }
    )
    eq(flatten(b), { "a", "b" }, "a duplicated path is in exactly one shard, once")
  end

  -- apply: entries keep their shape and order; info reports the shard
  do
    local entries = {}
    for _, rel in ipairs(all) do
      entries[#entries + 1] = { rel = rel, dialect = "a" }
    end
    local weights = {}
    for _, it in ipairs(items) do
      weights[it.rel] = it.weight
    end
    local seen, total = {}, 0
    for i = 1, 4 do
      local mine, info = shard.apply(
        entries,
        { index = i, count = 4 },
        { balance = "size", weights = weights }
      )
      eq(info.index, i, "info.index")
      eq(info.count, 4, "info.count")
      eq(info.total, #entries, "info.total")
      eq(info.selected, #mine, "info.selected")
      eq(info.balance, "size", "info.balance")
      local prev = 0
      for _, e in ipairs(mine) do
        ok(e.dialect == "a", "the entry itself is returned")
        ok(not seen[e.rel], e.rel .. " is in one shard only")
        seen[e.rel] = true
        total = total + 1
        local pos
        for p, rel in ipairs(all) do
          if rel == e.rel then
            pos = p
          end
        end
        ok(pos > prev, "entries keep the discovery order")
        prev = pos
      end
    end
    eq(total, #entries, "the four shards cover every entry exactly once")
  end

  -- weights: size from the file system (injected stat), at least 1
  do
    local sizes = { ["a_spec.lua"] = 0, ["b_spec.lua"] = 4096 }
    local w = shard.weights("/proj", { "a_spec.lua", "b_spec.lua", "gone_spec.lua" }, {
      balance = "size",
      stat = function(path)
        local rel = path:gsub("^/proj/", "")
        return sizes[rel] and { size = sizes[rel] } or nil
      end,
    })
    eq(
      w,
      { ["a_spec.lua"] = 1, ["b_spec.lua"] = 4096 },
      "size weights: an empty file weighs 1, a missing one is unknown"
    )
    local none = shard.weights("/proj", { "a_spec.lua" }, { balance = "count" })
    eq(none, {}, "count needs no weights")
  end

  -- durations: validation of untrusted input
  do
    local good, dropped = shard.validate_durations({
      ["TESTS/a_spec.lua"] = 12.5,
      ["TESTS/b_spec.lua"] = -1,
      ["TESTS/c_spec.lua"] = "slow",
      ["TESTS/d_spec.lua"] = 0 / 0,
      ["TESTS/e_spec.lua"] = 1e12,
      [""] = 3,
      ["bad\nname"] = 3,
      [42] = 3,
    })
    eq(good, { ["TESTS/a_spec.lua"] = 12.5 }, "only sane durations survive")
    eq(dropped, 7, "everything else is counted as dropped")
    local none, d2 = shard.validate_durations("nope")
    eq(none, {}, "not an object: empty")
    eq(d2, 1, "not an object: one problem")
  end

  -- record + read round trip, history-balanced weights, untrusted file
  do
    local state = vim.fs.normalize(vim.fn.tempname())
    local root = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    local result = require("testing.core.result")
    local function res_with(files)
      local res = result.new({ root = root })
      for rel, ms in pairs(files) do
        local c = result.new_case({ file = rel, name = "case" })
        c.assertions[1] = { ok = true, kind = "eq" }
        c.duration_ms = ms
        result.add_case(res, result.finish_case(c))
        local c2 = result.new_case({ file = rel, name = "second" })
        c2.assertions[1] = { ok = true, kind = "eq" }
        c2.duration_ms = ms
        result.add_case(res, result.finish_case(c2))
      end
      result.finalize(res)
      return res
    end
    local wrote, werr = shard.record_durations(
      root,
      res_with({ ["TESTS/a_spec.lua"] = 10, ["TESTS/b_spec.lua"] = 5 }),
      nil,
      { state_dir = state }
    )
    ok(wrote, "durations are written: " .. tostring(werr))
    local got = shard.read_durations(shard.durations_path(root, { state_dir = state }))
    eq(
      got,
      { ["TESTS/a_spec.lua"] = 20, ["TESTS/b_spec.lua"] = 10 },
      "a file's duration is the sum of its cases"
    )
    -- a second run updates what ran and keeps the rest; a file that no longer exists is dropped
    shard.record_durations(
      root,
      res_with({ ["TESTS/a_spec.lua"] = 1 }),
      { known_files = { ["TESTS/a_spec.lua"] = true } },
      { state_dir = state }
    )
    got = shard.read_durations(shard.durations_path(root, { state_dir = state }))
    eq(got, { ["TESTS/a_spec.lua"] = 2 }, "re-recorded file updated, unknown file dropped")

    local w, notes = shard.weights(
      root,
      { "TESTS/a_spec.lua", "TESTS/z_spec.lua" },
      { balance = "history", state_dir = state }
    )
    eq(w["TESTS/a_spec.lua"], 2, "history weights come from the recorded durations")
    eq(w["TESTS/z_spec.lua"], nil, "an unknown file has no weight")
    ok(
      #notes >= 1 and notes[1]:find("LOCAL history", 1, true) ~= nil,
      "the local-history hazard is said out loud"
    )

    -- an explicit durations file is read instead, and then no hazard note
    local shared = root .. "/durations.json"
    local f = assert(io.open(shared, "wb"))
    f:write('{"TESTS/z_spec.lua": 7}')
    f:close()
    w, notes = shard.weights(
      root,
      { "TESTS/a_spec.lua", "TESTS/z_spec.lua" },
      { balance = "history", durations_file = shared }
    )
    eq(w, { ["TESTS/z_spec.lua"] = 7 }, "a shared durations file wins over the local history")
    eq(notes, {}, "and says nothing: every job reads the same file")

    -- a corrupt or oversized file is ignored with a note, never an error
    f = assert(io.open(shared, "wb"))
    f:write("{not json")
    f:close()
    local d, note = shard.read_durations(shared)
    eq(d, {}, "corrupt durations: empty")
    ok(note ~= nil and note:find("not valid JSON", 1, true) ~= nil, "corrupt durations: a note")
    eq(shard.read_durations(root .. "/missing.json"), {}, "missing durations: empty, no note")
    vim.fn.delete(root, "rf")
    vim.fn.delete(state, "rf")
  end

  -- the hash itself: stable (a known sha256 prefix), independent of separators
  eq(
    shard.hash("TESTS/a_spec.lua"),
    shard.hash("TESTS\\a_spec.lua"),
    "the hash ignores the separator style"
  )
  eq(
    shard.hash("abc"),
    tonumber("ba7816bf", 16),
    "the hash is the first 32 bits of sha256 (sha256('abc') = ba7816bf...)"
  )
end
