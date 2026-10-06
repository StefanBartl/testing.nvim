-- TESTS/testing/child_fragment_spec.lua -- the fragment a child writes and the parent merges: cases are
-- appended one line at a time (a kill keeps what was finished), a torn last line is dropped and
-- counted, and the parent refuses what the IR validator or the "only this file" rule refuses.

return function(H)
  local ok = H.ok
  local function eq(actual, expected, msg)
    return ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
  local S = dofile(dir .. "/child_support.lua")
  local fragment = require("testing.child.fragment")
  local result = require("testing.core.result")

  local base = vim.fs.normalize(vim.fn.tempname()) .. "-frag"
  vim.fn.mkdir(base, "p")
  local path = base .. "/result.ndjson"

  ---@param rel string
  ---@param name string
  ---@param status? string
  ---@return table
  local function case(rel, name, status)
    local c = result.new_case({ file = rel, name = name })
    c.status = status or "pass"
    if c.status == "pass" then
      c.assertions[1] = { ok = true, kind = "eq" }
    elseif c.status == "fail" then
      c.assertions[1] = { ok = false, kind = "eq", msg = 'no\nsecond "line" \\ backslash' }
    end
    return c
  end

  -- missing file
  local none = fragment.read(path)
  eq(none.missing, true, "a fragment that was never written is reported as missing")
  eq(#none.cases, 0, "and has no cases")

  -- append + read keep order, content and the done record
  ok(fragment.append(path, { k = "case", case = case("TESTS/a_spec.lua", "one") }), "append 1")
  ok(
    fragment.append(path, { k = "case", case = case("TESTS/a_spec.lua", "two", "fail") }),
    "append 2"
  )
  local mid = fragment.read(path)
  eq(#mid.cases, 2, "both cases are readable before the child is done")
  eq(mid.done, nil, "no done record yet")
  eq(mid.cases[1].id, "TESTS/a_spec.lua::one", "order: first")
  eq(mid.cases[2].id, "TESTS/a_spec.lua::two", "order: second")
  eq(mid.cases[2].assertions[1].msg, 'no\nsecond "line" \\ backslash', "text survives the JSON")
  eq(mid.cases[2].tags, {}, "an empty list stays a list")
  ok(fragment.append(path, { k = "done", files_run = 1, files_unselected = 0 }), "append done")
  local full = fragment.read(path)
  eq(full.done.files_run, 1, "the done record is read")
  eq(full.bad_lines, 0, "and nothing is bad")

  -- progress records (streamed while the file runs) are kept apart from the final ones
  S.write(path, "")
  ok(
    fragment.append(path, { k = "progress", case = case("TESTS/a_spec.lua", "early") }),
    "progress"
  )
  local streamed = fragment.read(path)
  eq(#streamed.cases, 0, "a progress record is not a final case")
  eq(#streamed.progress, 1, "it is a progress case")
  eq(streamed.progress[1].id, "TESTS/a_spec.lua::early", "with its content")

  -- a torn last line (the child was killed in the middle of a write) is dropped and counted
  S.write(path, "")
  ok(fragment.append(path, { k = "case", case = case("TESTS/a_spec.lua", "one") }), "append 1")
  ok(
    fragment.append(path, { k = "case", case = case("TESTS/a_spec.lua", "two", "fail") }),
    "append 2"
  )
  ok(fragment.append(path, { k = "done", files_run = 1, files_unselected = 0 }), "append done")
  local f = assert(io.open(path, "ab"))
  f:write('{"k":"case","case":{"id":"TESTS/a_sp')
  f:close()
  local torn = fragment.read(path)
  eq(#torn.cases, 2, "the finished cases survive a torn last line")
  eq(torn.bad_lines, 1, "the torn line is counted")

  -- garbage and unknown records are bad lines, not cases
  S.write(path, 'not json\n{"k":"mystery"}\n[1,2]\n')
  local junk = fragment.read(path)
  eq(#junk.cases, 0, "garbage yields no case")
  eq(junk.bad_lines, 3, "every garbage line is counted")

  -- check: the IR rules
  local good = { case("TESTS/a_spec.lua", "one"), case("TESTS/a_spec.lua", "two", "fail") }
  local vok, problems = fragment.check(good, "TESTS/a_spec.lua")
  ok(vok, "a valid fragment passes: " .. vim.inspect(problems))

  local foreign = { case("TESTS/other_spec.lua", "x") }
  local fok, fprob = fragment.check(foreign, "TESTS/a_spec.lua")
  eq(fok, false, "a case of another file is refused")
  ok(fprob[1]:find("asked to run", 1, true) ~= nil, "and the message says why: " .. fprob[1])

  local dup = { case("TESTS/a_spec.lua", "one"), case("TESTS/a_spec.lua", "one") }
  eq((fragment.check(dup, "TESTS/a_spec.lua")), false, "duplicate ids are refused")

  local badstatus = case("TESTS/a_spec.lua", "s")
  badstatus.status = "great"
  eq((fragment.check({ badstatus }, "TESTS/a_spec.lua")), false, "an unknown status is refused")

  local forged = case("TESTS/a_spec.lua", "f")
  forged.assertions = {}
  eq(
    (fragment.check({ forged }, "TESTS/a_spec.lua")),
    false,
    "a pass without an assertion is refused"
  )

  local lying = case("TESTS/a_spec.lua", "l", "pass")
  lying.assertions = { { ok = false, kind = "eq", msg = "x" } }
  eq(
    (fragment.check({ lying }, "TESTS/a_spec.lua")),
    false,
    "a pass with a failed assertion is refused"
  )

  eq((fragment.check({}, "TESTS/a_spec.lua")), true, "no cases at all is a valid (empty) fragment")

  -- a fragment above the size limit is not read
  local old = fragment.MAX_BYTES
  fragment.MAX_BYTES = 4
  S.write(path, "0123456789\n")
  local big = fragment.read(path)
  fragment.MAX_BYTES = old
  eq(#big.cases, 0, "an oversized fragment yields no case")
  eq(big.bad_lines, 1, "and is counted bad")

  vim.fn.delete(base, "rf")
end
