-- TESTS/testing/shard_cli_spec.lua -- `--shard i/n` end to end through `testing.cli` on a fixture project:
-- `--list --shard` shows exactly the files of the shard, the shards of a matrix partition the whole list,
-- a shard with no file is a green no-op that says so, a path argument narrows a shard, and the durations of
-- a complete run are remembered for `shard.balance = "history"` (but not those of a filtered run).

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
      msg .. " (got " .. tostring(haystack):sub(1, 400) .. ")"
    )
  end
  local cli = require("testing.cli")
  local result_mod = require("testing.core.result")
  local real_inproc = require("testing.run.inproc")

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  local root = vim.fs.normalize(vim.fn.tempname())
  local state = vim.fs.normalize(vim.fn.tempname())
  local rels = {}
  for i = 1, 7 do
    local rel = ("TESTS/%s/f%d_spec.lua"):format(i % 2 == 0 and "even" or "odd", i)
    rels[#rels + 1] = rel
    write(
      root .. "/" .. rel,
      ('return function(H)\n  H.ok(true, "f%d")\nend\n'):format(i) .. string.rep("-- pad\n", i * 20)
    )
  end
  table.sort(rels)

  local function captured(argv, seams)
    local out, err = {}, {}
    local sv = {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = state,
      color = false,
    }
    for k, v in pairs(seams or {}) do
      sv[k] = v
    end
    local code = cli.main(argv, sv)
    return { code = code, out = table.concat(out, "\n"), err = table.concat(err, "\n") }
  end

  ---Files named by a `--list` output: the id is `<file>::<name>`.
  ---@param text string
  ---@return string[]
  local function listed_files(text)
    local files, seen = {}, {}
    for line in text:gmatch("[^\n]+") do
      local file = line:match("^(TESTS/[^:]+_spec%.lua)::")
      if file and not seen[file] then
        seen[file] = true
        files[#files + 1] = file
      end
    end
    table.sort(files)
    return files
  end

  local base = captured({ root, "--list" })
  eq(base.code, 0, "plain --list\n" .. base.err)
  eq(listed_files(base.out), rels, "--list names every fixture file")

  -- the three shards of a matrix: disjoint, and together the whole list
  local union, total = {}, 0
  for i = 1, 3 do
    local r = captured({ root, "--list", "--shard", i .. "/3" })
    eq(r.code, 0, ("--list --shard %d/3\n%s"):format(i, r.err))
    has(r.err, ("shard %d/3: "):format(i), "the stderr says which shard this is")
    has(r.err, "of 7 spec file(s) (balance size)", "and how many files it holds")
    local files = listed_files(r.out)
    ok(#files >= 1, ("shard %d/3 is not empty"):format(i))
    for _, f in ipairs(files) do
      ok(not union[f], f .. " is in one shard only")
      union[f] = true
      total = total + 1
    end
    has(
      r.out,
      ("%d of 7 spec file(s) would run"):format(#files),
      "the list summary counts the shard's files"
    )
  end
  eq(total, 7, "the three shards hold seven files together")
  local got = vim.tbl_keys(union)
  table.sort(got)
  eq(got, rels, "the union of the shards is the whole list")

  -- the same shard twice: the same files
  local a = captured({ root, "--list", "--shard=2/3" })
  local b = captured({ root, "--list", "--shard", "2/3" })
  eq(listed_files(a.out), listed_files(b.out), "a shard is reproducible")

  -- more shards than files: some shard has nothing, which is green and says so
  local empty
  for i = 1, 12 do
    local r = captured({ root, "--list", "--shard", i .. "/12" })
    if #listed_files(r.out) == 0 then
      empty = r
      break
    end
  end
  ok(empty ~= nil, "with 12 shards over 7 files one shard is empty")
  eq(empty.code, 0, "an empty shard is exit 0")
  has(empty.err, "has no spec file", "and says why")
  ok(not empty.out:find("TESTING_OK", 1, true), "an empty shard prints no sentinel")

  -- a path argument narrows the shard; the partition itself does not depend on it
  local narrowed = captured({ root, "--list", "--shard", "1/2", "TESTS/odd" })
  local whole = listed_files(captured({ root, "--list", "--shard", "1/2" }).out)
  local expect = {}
  for _, f in ipairs(whole) do
    if f:find("^TESTS/odd/") then
      expect[#expect + 1] = f
    end
  end
  if #expect == 0 then
    eq(narrowed.code, 0, "nothing of the shard under that path: green no-op")
    has(narrowed.err, "has no spec file", "and says so")
  else
    eq(listed_files(narrowed.out), expect, "a path narrows the shard to the files below it")
  end

  -- refusals are usage errors
  for _, bad in ipairs({ "0/3", "4/3", "1/0", "x", "1", "1/2/3", "-1/3", "1/1001" }) do
    local r = captured({ root, "--shard", bad })
    eq(r.code, 2, "--shard " .. bad .. " is refused")
    has(r.err, "--shard", "and the message names the option")
  end
  eq(captured({ root, "--watch", "--shard", "1/2" }).code, 2, "--watch with --shard is refused")

  -- durations: a complete run remembers them, a filtered run does not
  local function stub_run()
    return setmetatable({
      run = function(opts)
        local res = result_mod.new({ root = root })
        for _, f in ipairs(opts.files) do
          local c = result_mod.new_case({ file = f.rel, name = "case" })
          c.assertions[1] = { ok = true, kind = "eq" }
          c.duration_ms = 7
          result_mod.add_case(res, result_mod.finish_case(c))
        end
        result_mod.finalize(res)
        return {
          result = res,
          failed = 0,
          failed_files = 0,
          total = #res.cases,
          files_run = #opts.files,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 1,
          exit_code = 0,
        }
      end,
    }, { __index = real_inproc })
  end
  local shard = require("testing.run.shard")
  local dpath = shard.durations_path(root, { state_dir = state })
  vim.fn.delete(dpath)
  local r = captured({ root, "--filter", "case" }, { inproc = stub_run() })
  eq(r.code, 0, "filtered stub run\n" .. r.err)
  eq(vim.uv.fs_stat(dpath), nil, "a filtered run leaves the durations alone")
  r = captured({ root }, { inproc = stub_run() })
  eq(r.code, 0, "full stub run\n" .. r.err)
  local durations = shard.read_durations(dpath)
  eq(vim.tbl_count(durations), 7, "a full run remembers every file")
  eq(durations[rels[1]], 7, "with the sum of its cases")

  -- and they are what `balance = "history"` weighs by
  local conf = root .. "/.testing.lua"
  write(conf, 'return { shard = { balance = "history" } }\n')
  local h1 = captured({ root, "--list", "--shard", "1/2" })
  eq(h1.code, 0, "--shard with balance = history\n" .. h1.err)
  has(h1.err, "LOCAL history", "the hazard of a local history is stated")
  has(h1.err, "(balance history)", "and the mode is named")
  vim.fn.delete(root, "rf")
  vim.fn.delete(state, "rf")
end
