-- TESTS/testing/run_green_spec.lua -- testing.run.green: the last full green run of a project and what changed since
-- (the second line of a red verdict). Git is injected; the record is untrusted input when read back.

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
      ("%s: %q not in %q"):format(msg, needle, tostring(haystack))
    )
  end

  local green = require("testing.run.green")
  local result = require("testing.core.result")

  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root .. "/lua", "p")
  local state = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(state, "p")
  local function put(rel, text)
    local fh = assert(io.open(root .. "/" .. rel, "wb"))
    fh:write(text)
    fh:close()
  end
  put("lua/dirty.lua", "return 1\n")
  put("lua/other.lua", "return 2\n")

  ---A git runner that answers `git diff` with `diff` and `git ls-files` with `untracked` (NUL separated).
  ---@param diff string[]
  ---@param untracked string[]
  ---@param log? string[][]
  local function fake_git(diff, untracked, log)
    return function(argv)
      if log then
        log[#log + 1] = argv
      end
      local sub = argv[2]
      if sub == "rev-parse" then
        return { code = 0, stdout = "abc\n", stderr = "" }
      elseif sub == "diff" then
        return { code = 0, stdout = table.concat(diff, "\0") .. "\0", stderr = "" }
      elseif sub == "ls-files" then
        return { code = 0, stdout = table.concat(untracked, "\0") .. "\0", stderr = "" }
      end
      return { code = 1, stdout = "", stderr = "unexpected " .. tostring(sub) }
    end
  end

  local function run_ir(git)
    return result.new({
      id = "run-1",
      root = root,
      project_key = "k",
      nvim = "0.12.0",
      os = "linux",
      duration_ms = 1,
      git = git,
    })
  end

  -- nothing recorded --------------------------------------------------------------------------------------------------------
  local rec, note = green.load(root, { state_dir = state })
  eq(rec, nil, "nothing is recorded before the first green run")
  eq(note, nil, "and that is no problem")

  -- a clean checkout: the commit is enough -------------------------------------------------------------------------------------
  local rok = green.record(root, run_ir({ sha = "3f2a1b9", dirty = false }), {
    state_dir = state,
    time = 1000,
  })
  ok(rok, "a green run is recorded")
  rec = green.load(root, { state_dir = state })
  eq(rec, { v = 1, ts = 1000, run = "run-1", sha = "3f2a1b9", dirty = {} }, "its time, run, commit")
  local log = {}
  local files =
    green.changed_since(root, rec, { run = fake_git({ "lua/a.lua" }, { "new.lua" }, log) })
  eq(
    files,
    { "lua/a.lua", "new.lua" },
    "what git lists against that commit: tracked changes and untracked files"
  )
  local asked = false
  for _, argv in ipairs(log) do
    if argv[2] == "diff" then
      asked = vim.tbl_contains(argv, "3f2a1b9")
    end
  end
  ok(asked, "git was asked about the commit of the green run")

  -- a dirty tree at the green run: files with the same content now are not changes since -------------------------------------------
  local log2 = {}
  green.record(root, run_ir({ sha = "3f2a1b9", dirty = true }), {
    state_dir = state,
    time = 2000,
    run = fake_git({ "lua/dirty.lua" }, {}, log2),
  })
  rec = green.load(root, { state_dir = state })
  eq(
    vim.tbl_keys(rec.dirty),
    { "lua/dirty.lua" },
    "the files that were modified then are remembered by content"
  )
  eq(#rec.dirty["lua/dirty.lua"], 64, "as a sha256")
  local list = green.changed_since(root, rec, {
    run = fake_git({ "lua/dirty.lua", "lua/other.lua" }, {}),
  })
  eq(
    list,
    { "lua/other.lua" },
    "a file with the content it had at the green run is no change since"
  )
  put("lua/dirty.lua", "return 'edited after the green run'\n")
  list = green.changed_since(root, rec, {
    run = fake_git({ "lua/dirty.lua", "lua/other.lua" }, {}),
  })
  eq(list, { "lua/dirty.lua", "lua/other.lua" }, "but an edit after it is")
  -- a file that was modified at the green run and that git does not list now: back at the commit's content (or
  -- gone), which is not what the green run saw
  list = green.changed_since(root, rec, { run = fake_git({ "lua/other.lua" }, {}) })
  eq(
    list,
    { "lua/dirty.lua", "lua/other.lua" },
    "a file that was dirty at the green run and is not listed now with another content is a change since"
  )
  local same = { v = 1, ts = 1, run = "r", sha = "abc1234", dirty = {} }
  same.dirty["lua/dirty.lua"] =
    vim.fn.sha256((require("lib.nvim.fs.read")(root .. "/lua/dirty.lua")))
  ok(#same.dirty["lua/dirty.lua"] == 64, "fixture: a hash")
  eq(
    green.changed_since(root, same, { run = fake_git({}, {}) }),
    {},
    "not listed and byte-identical to the green run's content: nothing changed"
  )
  local gone =
    { v = 1, ts = 1, run = "r", sha = "abc1234", dirty = { ["lua/missing.lua"] = ("a"):rep(64) } }
  eq(
    green.changed_since(root, gone, { run = fake_git({}, {}) }),
    { "lua/missing.lua" },
    "a file that was dirty and is gone is a change since"
  )

  -- no git facts: no commit, no answer, a note ----------------------------------------------------------------------------------------
  green.record(root, run_ir(nil), { state_dir = state, time = 3000 })
  rec = green.load(root, { state_dir = state })
  eq(rec.sha, nil, "a run without git facts records no commit")
  local none, why = green.changed_since(root, rec, { run = fake_git({}, {}) })
  eq(none, nil, "so there is no list")
  has(why, "no commit", "and the note says why")

  -- git fails: a note, no list ---------------------------------------------------------------------------------------------------------------
  rec = { v = 1, ts = 1, run = "r", sha = "abc1234", dirty = {} }
  local failed, fwhy = green.changed_since(root, rec, {
    run = function()
      return { code = 128, stdout = "", stderr = "fatal: bad object" }
    end,
  })
  eq(failed, nil, "git failing gives no list")
  has(fwhy, "does not know the revision", "and its reason")

  -- the record is untrusted --------------------------------------------------------------------------------------------------------------------
  local path = green.path(root, { state_dir = state })
  local function write_raw(text)
    local fh = assert(io.open(path, "wb"))
    fh:write(text)
    fh:close()
  end
  local sha64 = ("a"):rep(64)
  for label, text in pairs({
    ["not json"] = "{{{{",
    ["wrong version"] = '{"v":9,"ts":1,"run":"r"}',
    ["bad timestamp"] = '{"v":1,"ts":"x","run":"r"}',
    ["a commit that is no hex"] = '{"v":1,"ts":1,"run":"r","sha":"--upload-pack=x"}',
    ["a commit that git would read as an option"] = '{"v":1,"ts":1,"run":"r","sha":"-abcdef"}',
    ["a control character in a path"] = '{"v":1,"ts":1,"run":"r","dirty":{"a\\u0001b":"'
      .. sha64
      .. '"}}',
    ["a hash of the wrong size"] = '{"v":1,"ts":1,"run":"r","dirty":{"a":"abc"}}',
    ["a run id with a newline"] = '{"v":1,"ts":1,"run":"r\\nx"}',
  }) do
    write_raw(text)
    local r, n = green.load(root, { state_dir = state })
    eq(r, nil, label .. ": not used")
    has(n or "", "ignored", label .. ": a note says so")
  end
  write_raw(("x"):rep(green.MAX_BYTES + 1))
  local _, big = green.load(root, { state_dir = state })
  has(big, "too large", "a file over the cap is not read")
  write_raw('{"v":1,"ts":5,"run":"r","sha":"abc1234","dirty":{"a.lua":"' .. sha64 .. '"}}')
  eq(green.load(root, { state_dir = state }).dirty, { ["a.lua"] = sha64 }, "a valid record is read")

  -- bounded: more modified files than the cap are not all remembered -----------------------------------------------------------------------------
  local many = {}
  for i = 1, green.MAX_DIRTY + 20 do
    many[i] = ("lua/m%03d.lua"):format(i)
    put(many[i], "x")
  end
  green.record(root, run_ir({ sha = "abc1234", dirty = true }), {
    state_dir = state,
    time = 4000,
    run = fake_git(many, {}),
  })
  eq(
    vim.tbl_count(green.load(root, { state_dir = state }).dirty),
    green.MAX_DIRTY,
    "the hashes are bounded"
  )

  vim.fn.delete(state, "rf")
  vim.fn.delete(root, "rf")
end
