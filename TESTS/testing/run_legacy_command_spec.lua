-- TESTS/testing/run_legacy_command_spec.lua -- the legacy workflow command `##[command]` is read by the CI runner
-- anywhere in a line, so every line the run prints (stdout and stderr) must be free of it, not only the lines that
-- start with the text of the code under test: the `--list` ids and order lines, the cases that passed without an
-- assertion, the files that registered no case, the retry notes, the `timings:` line, the findings and the IR of
-- `--reporter json` (written with the JSON escape, so a consumer decodes the original text). End to end through
-- `cli.main` on temp projects whose case and file names carry the sequence.

---@diagnostic disable: need-check-nil

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
      msg .. " (missing " .. vim.inspect(needle) .. " in " .. tostring(haystack):sub(1, 700) .. ")"
    )
  end
  local cli = require("testing.cli")
  local json = require("lib.nvim.json")

  local tmp = vim.fs.normalize(vim.fn.tempname()) .. "-legacycmd"
  local state_dir, cache_dir = tmp .. "/state", tmp .. "/cache"

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  ---@param argv string[]
  ---@return { code: integer, out: string, err: string, lines: string[] }
  local function go(argv)
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
    })
    return {
      code = code,
      out = table.concat(out, "\n"),
      err = table.concat(err, "\n"),
      lines = out,
    }
  end

  ---Nothing on either stream may hold the sequence: the runner finds it with a plain substring search.
  ---@param r { out: string, err: string }
  ---@param what string
  local function clean(r, what)
    local all = r.out .. "\n" .. r.err
    local at = all:find("##[", 1, true)
    ok(
      at == nil,
      ("%s: a `##[` is left on a log line: %s"):format(
        what,
        at and all:sub(math.max(1, at - 60), at + 60) or ""
      )
    )
  end

  -- ---------------------------------------------------------------- a project with hostile names
  local root = tmp .. "/p"
  write(
    root .. "/TESTS/a##[error]_spec.lua",
    table.concat({
      "describe('suite', function()",
      "  it('noassert ##[warning]no-assert-case', function() end)",
      "  it('asserts ##[stop-commands]fine', function() assert.is_true(true) end)",
      "end)",
      "",
    }, "\n")
  )
  -- registers no case on this platform: "registered no case" names the file
  write(
    root .. "/TESTS/p##[add-mask]_spec.lua",
    "describe('p', function()\n  if false then\n    it('never', function() end)\n  end\nend)\n"
  )
  write(root .. "/.testing.lua", 'return { assertions = "warn" }\n')

  local r = go({ root })
  eq(r.code, 0, "the project is green\n" .. r.out .. r.err)
  clean(r, "a plain run")
  has(
    r.out,
    "noassert #\\x23[warning]no-assert-case",
    "a case without assertions is named, defused"
  )
  has(r.out, "p#\\x23[add-mask]_spec.lua", "a file that registered no case is named, defused")
  has(r.out, "timings:", "the timings line is there")
  has(r.out, "a#\\x23[error]_spec.lua", "and names the slowest file, defused")

  r = go({ root, "--list" })
  eq(r.code, 0, "--list\n" .. r.out .. r.err)
  clean(r, "--list")
  has(r.out, "suite::asserts #\\x23[stop-commands]fine", "a listed id is defused")

  r = go({ root, "--list", "--order", "failed-first" })
  clean(r, "--list with an order")

  -- the json reporter: one IR line on stdout, valid JSON, the original text after decoding
  r = go({ root, "--reporter", "json" })
  clean(r, "--reporter json")
  local ir_line
  for _, l in ipairs(r.lines) do
    if l:sub(1, 1) == "{" then
      ir_line = l
    end
  end
  ok(ir_line ~= nil, "the IR is on stdout\n" .. r.out)
  has(ir_line, "#\\u0023[", "written with the JSON escape")
  local decoded = assert(json.decode(ir_line))
  local seen = false
  for _, c in ipairs(decoded.cases) do
    if c.id:find("noassert ##[warning]no-assert-case", 1, true) then
      seen = true
    end
  end
  ok(seen, "a consumer that decodes the line gets the original case id")

  -- the junit reporter on stdout is a log as well: the sequence is written as a character reference (an XML parser
  -- reads the original text), the file of `--junit <file>` keeps it
  r = go({ root, "--reporter", "junit" })
  clean(r, "--reporter junit")
  has(
    r.out,
    "a#&#35;[error]_spec.lua",
    "the junit document names the file with a character reference"
  )
  local junit_file = tmp .. "/report.xml"
  r = go({ root, "--junit", junit_file })
  clean(r, "--junit <file>")
  local jf = assert(io.open(junit_file, "rb"))
  local xml = jf:read("*a")
  jf:close()
  has(xml, "a##[error]_spec.lua", "the junit file holds the original text")

  -- the file written by --json is no log: it keeps the text as it is
  local file = tmp .. "/ir.json"
  r = go({ root, "--json", file })
  clean(r, "--json <file>")
  local f = assert(io.open(file, "rb"))
  local body = f:read("*a")
  f:close()
  has(body, "noassert ##[warning]no-assert-case", "the report file holds the original text")

  -- ---------------------------------------------------------------- the retry notes
  local flaky_root = tmp .. "/flaky"
  local counter = tmp .. "/counter"
  write(
    flaky_root .. "/TESTS/flaky##[error]_spec.lua",
    ([[
return function(H)
  local path = %q
  local n = 0
  local f = io.open(path, "rb")
  if f then
    n = tonumber(f:read("*a")) or 0
    f:close()
  end
  f = assert(io.open(path, "wb"))
  f:write(tostring(n + 1))
  f:close()
  H.ok(n + 1 >= 2, "attempt " .. (n + 1))
end
]]):format(counter)
  )
  r = go({ flaky_root, "--retry-failed", "2" })
  clean(r, "the retry notes")
  has(r.out, "flaky: 1 case(s) failed and then passed on a retry", "the flaky list is printed")
  has(r.out, "flaky#\\x23[error]_spec.lua", "and names the case, defused")

  vim.fn.delete(tmp, "rf")
end
