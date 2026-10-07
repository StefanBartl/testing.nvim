-- TESTS/testing/stamp_report_spec.lua -- what a `testing stamp` run PRINTS when it exits 1 without a red case: the
-- stamp was asked for and not written (an `--out` that cannot be written, a partial run). The first line of the agent
-- report says `exit 0` and `GREEN` only where the process exits 0 and prints the sentinel, so it must agree with the
-- exit code; the terminal report says `verdict: red`. A failed report file (exit 3) writes no stamp at all.

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

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-stampreport"
  vim.fn.mkdir(tmp, "p")
  local state_dir = tmp .. "/state"
  local cache_dir = tmp .. "/cache"

  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
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
  end

  -- the environment the stamp code sees: nothing from the real one
  local function getenv()
    return nil
  end

  ---@param argv string[]
  ---@return { code: integer, lines: string[], out: string, err: string, last: string }
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
      stamp = { getenv = getenv },
    })
    package.loaded["proj.mod"] = nil
    return {
      code = code,
      lines = out,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      last = vim.trim(out[#out] or ""),
    }
  end

  local PURE = "return function(H)\n  H.ok(1 + 1 == 2, 'arithmetic')\nend\n"
  local SKIPS =
    "describe('s', function()\n  it('later')\n  it('now', function() assert.is_true(true) end)\nend)\n"
  local CFG = "return { plugin = 'proj', minit = false, guards = { fs = 'off' } }\n"

  ---@param name string
  ---@param specs table<string, string>
  ---@return string root
  local function project(name, specs)
    local root = tmp .. "/" .. name
    write(root .. "/lua/proj/mod.lua", "return { value = 1 }\n")
    write(root .. "/.testing.lua", CFG)
    for rel, text in pairs(specs) do
      write(root .. "/TESTS/" .. rel, text)
    end
    git(root, "init", "-q", "-b", "main")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "init")
    return root
  end

  ---The exit code the first line of an agent report claims.
  ---@param line string
  ---@return integer|nil
  local function claimed_exit(line)
    return tonumber(line:match("| exit (%d+)$"))
  end

  -- a regular file where a directory is needed: nothing can be written below it
  local blocker = tmp .. "/blocker"
  write(blocker, "not a directory\n")

  -- ================================================================ the stamp is written: GREEN, exit 0
  local good = project("good", { ["a_spec.lua"] = PURE })
  local good_stamp = tmp .. "/good-stamp.json"
  local g = run({ "stamp", good, "--reporter", "agent", "--out", good_stamp })
  eq(g.code, 0, "a complete green run with a stamp exits 0\n" .. g.err)
  eq(g.lines[1]:match("^%u+"), "GREEN", "and says GREEN")
  eq(claimed_exit(g.lines[1]), 0, "with exit 0")
  ok(vim.uv.fs_stat(good_stamp) ~= nil, "the stamp is on disk")

  -- ================================================================ the stamp cannot be written: exit 1 says exit 1
  local bad_out = blocker .. "/x.json"
  local agent = run({ "stamp", good, "--reporter", "agent", "--out", bad_out })
  eq(agent.code, 1, "an --out that cannot be written: exit 1 (asked for, not given)")
  has(agent.err, "stamp: not written", "and stderr says so")
  eq(agent.lines[1]:match("^%u+"), "RED", "the first line of the agent report is not GREEN")
  eq(claimed_exit(agent.lines[1]), 1, "and it says exit 1, the exit code of the process")
  lacks(agent.out, "GREEN", "GREEN is nowhere")
  lacks(agent.out, "exit 0", "nor exit 0")
  lacks(agent.out, SENTINEL, "no sentinel")
  has(agent.lines[2], "no case failed", "the second line says the cases are not the reason")
  has(agent.lines[2], "stamp not written", "and names the stamp")
  lacks(agent.lines[2], "last green run", "it does not claim a last green run")
  ok(vim.uv.fs_stat(bad_out) == nil, "nothing was written")

  -- the same, jsonl
  local jl = run({ "stamp", good, "--reporter", "agent", "--format", "jsonl", "--out", bad_out })
  eq(jl.code, 1, "jsonl: exit 1")
  local head = vim.json.decode(jl.lines[1])
  eq(head.kind, "verdict", "jsonl: the first object is the verdict")
  eq(head.verdict, "red", "jsonl: red")
  eq(head.exit_code, 1, "jsonl: exit_code 1")
  ok(vim.tbl_contains(head.reasons or {}, "stamp not written"), "jsonl: the reason is in `reasons`")

  -- the terminal reporter: `verdict: red`, never `verdict: green` for a run that exits 1
  local term = run({ "stamp", good, "--reporter", "term", "--out", bad_out })
  eq(term.code, 1, "term: exit 1")
  has(term.out, "verdict: red", "term: the verdict line says red")
  lacks(term.out, "verdict: green", "term: not green")
  has(term.out, "no case failed; stamp not written", "term: and says why")
  lacks(term.out, SENTINEL, "term: no sentinel")

  -- ================================================================ a partial run is refused its stamp: exit 1 says exit 1
  local part = project("part", { ["a_spec.lua"] = PURE, ["s_spec.lua"] = SKIPS })
  local skipped = run({ "stamp", part, "--reporter", "agent", "--isolated", "none" })
  eq(skipped.code, 1, "a skipped case: no stamp, exit 1")
  eq(skipped.lines[1]:match("^%u+"), "RED", "the first line is RED, not PARTIAL with exit 0")
  eq(claimed_exit(skipped.lines[1]), 1, "exit 1")
  lacks(skipped.out, "exit 0", "exit 0 is nowhere")
  has(skipped.out, "skipped", "the partial reason is still named")
  has(skipped.out, "stamp not written", "next to the refusal")
  ok(vim.uv.fs_stat(stamp.path(part, { state_dir = state_dir })) == nil, "no stamp")

  -- ================================================================ a red run is untouched
  local red = project("red", {
    ["a_spec.lua"] = PURE,
    ["f_spec.lua"] = "return function(H)\n  H.ok(false, 'fails')\nend\n",
  })
  local reds = run({ "stamp", red, "--reporter", "agent" })
  eq(reds.code, 1, "a red run: exit 1")
  eq(reds.lines[1]:match("^%u+"), "RED", "RED")
  eq(claimed_exit(reds.lines[1]), 1, "exit 1")
  lacks(reds.out, "no case failed", "a case did fail: no stamp line about the cases")

  -- ================================================================ a failed report file writes no stamp
  local infra_stamp = tmp .. "/infra-stamp.json"
  local infra = run({
    "stamp",
    good,
    "--reporter",
    "agent",
    "--junit",
    blocker .. "/j.xml",
    "--out",
    infra_stamp,
  })
  eq(infra.code, 3, "a report file that cannot be written: exit 3")
  eq(infra.lines[1]:match("^%u+"), "INFRA", "the first line says INFRA")
  eq(claimed_exit(infra.lines[1]), 3, "exit 3")
  ok(vim.uv.fs_stat(infra_stamp) == nil, "and no stamp is written after an infrastructure error")

  vim.fn.delete(tmp, "rf")
end
