-- TESTS/testing/run_infra_line_spec.lua -- the lines a run prints when the report cannot be built (exit 3): the first
-- line of the agent report is ONE line (`INFRA | ... | exit 3`) whatever the reason holds, and no line on stdout or
-- stderr starts a CI workflow command, not even one that follows a line break inside a message or hides behind a
-- no-break space (the runner trims Unicode whitespace before it looks for `::`).

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 600) .. ")"
    )
  end

  local cli = require("testing.cli")
  local project = require("testing.run.project")
  local real_inproc = require("testing.run.inproc")
  local result_mod = require("testing.core.result")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-infraline"
  local root = tmp .. "/p"
  vim.fn.mkdir(root .. "/TESTS", "p")
  local f = assert(io.open(root .. "/TESTS/x_spec.lua", "wb"))
  f:write('return function(H)\n  H.ok(true, "x")\nend\n')
  f:close()

  ---A driver stub: one passing case, and an IR encoder that fails with `reason`.
  ---@param reason string
  ---@return table
  local function stub(reason)
    local fake = {
      run = function()
        local res = result_mod.new({ root = root })
        local case = result_mod.new_case({ file = "TESTS/x_spec.lua", name = "x_spec.lua" })
        case.assertions[1] = { ok = true, kind = "eq" }
        result_mod.add_case(res, result_mod.finish_case(case))
        result_mod.finalize(res)
        return {
          result = res,
          failed = 0,
          failed_files = 0,
          total = 1,
          files_run = 1,
          files_unrun = 0,
          files_unselected = 0,
          skipped = 0,
          stopped = false,
          wall_ms = 0,
          exit_code = 0,
        }
      end,
      sanitize = function()
        return nil, nil, reason
      end,
    }
    return setmetatable(fake, { __index = real_inproc })
  end

  ---@param argv string[]
  ---@param reason string
  ---@return { code: integer, out: string[], err: string[] }
  local function run(argv, reason)
    local out, err = {}, {}
    local code = cli.main(vim.list_extend({ root }, argv), {
      out = function(s)
        out[#out + 1] = s
      end,
      err = function(s)
        err[#err + 1] = s
      end,
      state_dir = tmp .. "/state",
      cache_dir = tmp .. "/cache",
      color = false,
      inproc = stub(reason),
    })
    return { code = code, out = out, err = err }
  end

  -- the runner's own rule, written out: TrimStart() with char.IsWhiteSpace, then StartsWith("::")
  local runner_space = { [0xA0] = true, [0x1680] = true, [0x2028] = true, [0x2029] = true }
  runner_space[0x202F], runner_space[0x205F], runner_space[0x3000] = true, true, true
  for cp = 0x2000, 0x200A do
    runner_space[cp] = true
  end
  local function runner_reads_command(l)
    local chars = vim.fn.split(l, "\\zs")
    local i = 1
    while chars[i] and (chars[i] == " " or runner_space[vim.fn.char2nr(chars[i])]) do
      i = i + 1
    end
    return chars[i] == ":" and chars[i + 1] == ":"
  end

  -- what an IR that fails validation says: several lines, with ids of the code under test in them. `%q` keeps a line
  -- break inside an id as a backslash and a real line break, so a later line can start with whatever the id says.
  local REASON = table.concat({
    "the IR failed validation:",
    '  cases[3].id: duplicate id "a\\',
    '::error::pwned" (first at cases[1])',
    "  \194\160::stop-commands::tok",
    "  c1 \194\155[2J and bidi \226\128\174rtl",
  }, "\n")

  -- the agent reporter: one INFRA line ---------------------------------------------------------------------------------------------------
  local r = run({ "--reporter", "agent", "--json", tmp .. "/o.json" }, REASON)
  eq(r.code, 3, "an IR that cannot be built is exit 3")
  eq(#r.out, 1, "stdout is one line, not the several of the reason")
  ok(
    r.out[1]:match(
      "^INFRA | the report could not be built: the IR failed validation: %.%.%. | exit 3$"
    ) ~= nil,
    "that line is the verdict, with the exit code at its end: " .. vim.inspect(r.out[1])
  )
  ok(not r.out[1]:find("\n", 1, true), "no line break in it")
  ok(not r.out[1]:find("\194\155", 1, true), "no raw C1 character")
  ok(not table.concat(r.out, "\n"):find("TESTING_OK", 1, true), "no sentinel")

  -- the details are on stderr, line by line, none of them a workflow command
  local err_text = table.concat(r.err, "\n")
  has(err_text, "the IR failed validation:", "stderr has the details")
  has(err_text, "\\x3A:error::pwned", "a line that starts with :: after a line break is defused")
  has(err_text, "\\x3A:stop-commands::tok", "so is one behind a no-break space")
  for i, l in ipairs(r.err) do
    ok(
      not runner_reads_command(l),
      ("stderr line %d is no workflow command: %s"):format(i, vim.inspect(l))
    )
    ok(not l:find("\194\155", 1, true), ("stderr line %d has no raw C1 character"):format(i))
    ok(not l:find("\226\128\174", 1, true), ("stderr line %d has no raw bidi override"):format(i))
  end

  -- the same, jsonl
  local jl = run({ "--reporter", "agent", "--format", "jsonl", "--json", tmp .. "/o.json" }, REASON)
  eq(jl.code, 3, "jsonl: exit 3")
  eq(#jl.out, 1, "jsonl: one line")
  local obj = vim.json.decode(jl.out[1])
  eq(obj.kind, "infra", "jsonl: an infra object")
  eq(obj.exit_code, 3, "jsonl: exit_code 3")
  ok(not obj.message:find("\n", 1, true), "jsonl: the message is one line")
  has(obj.message, "the IR failed validation:", "jsonl: and starts with the reason")

  -- a reason of one line is printed as it is (no marker)
  local single =
    run({ "--reporter", "agent", "--json", tmp .. "/o.json" }, "the IR failed validation")
  eq(
    single.out,
    { "INFRA | the report could not be built: the IR failed validation | exit 3" },
    "one line stays"
  )

  -- the terminal reporter: stderr is the same, stdout carries no INFRA line --------------------------------------------------------------
  local t = run({ "--reporter", "term", "--json", tmp .. "/o.json" }, REASON)
  eq(t.code, 3, "term: exit 3")
  for i, l in ipairs(t.err) do
    ok(
      not runner_reads_command(l),
      ("term: stderr line %d is no workflow command: %s"):format(i, vim.inspect(l))
    )
  end

  -- the diagnostics lines of the run: ASCII and Unicode whitespace in front of `::` -----------------------------------------------------
  for _, prefix in ipairs({ "", "  ", "\194\160", "  \226\128\131", "\227\128\128", "\226\128\168" }) do
    local line = project.safe_line(prefix .. "::error::forged")
    ok(
      not runner_reads_command(line),
      "safe_line defuses " .. vim.inspect(prefix) .. ": " .. vim.inspect(line)
    )
    has(line, "\\x3A:error::forged", "and keeps the text readable behind " .. vim.inspect(prefix))
  end
  eq(
    project.safe_line("plain ::error::x"),
    "plain ::error::x",
    "a `::` that is not at the start stays"
  )
  -- the legacy `##[command]` form is read by the runner anywhere in a line, a line of output of a child included
  for _, text in ipairs({
    "##[error]forged",
    "spec said ##[stop-commands]tok",
    "\27[31m##[warning]x",
  }) do
    local line = project.safe_line(text)
    ok(not line:find("##[", 1, true), "safe_line defuses the legacy form: " .. vim.inspect(line))
    has(line, "#\\x23[", "and keeps the text readable: " .. vim.inspect(line))
  end

  vim.fn.delete(tmp, "rf")
end
